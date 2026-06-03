# Compiler & VM Implementation Plan

Target: match QuickJS performance and memory characteristics on the DS engine benchmarks.
Current gap: **74× slower, ~4000× more memory** (fib 35: 47.8s / 9.8 GB vs 0.65s / 2.5 MB).
Root cause: tree-walking interpreter with a pool allocator that never reclaims intermediate allocations.

All five steps are independent and stackable. Implement in order — each one improves the
benchmark on its own, and they compose without conflict.

---

## Step 1 — NaN-boxed Value

**Why:** The current `Value` struct is 40 bytes (type tag + bool + double + String slice + void\*).
The VM's value stack holds one per slot; fewer values per cache line means more cache misses.
NaN-boxing encodes all 7 types in a single `ulong` (8 bytes) — a 5× size reduction.

**How it works:** IEEE-754 quiet NaN has 13 bits of payload in the exponent + the top mantissa bit.
Any bit pattern with `0x7FF8000000000000` set is a NaN; on arm64/x86-64, virtual addresses
fit in 48 bits, leaving the upper 16 bits for a type tag.

```c3
typedef Value = ulong;

const ulong NAN_BITS    = 0x7FF8000000000000UL;
const ulong TAG_MASK    = 0xFFFF000000000000UL;
const ulong PTR_MASK    = 0x0000FFFFFFFFFFFFUL;

const ulong TAG_NIL     = 0x7FFC000000000000UL;
const ulong TAG_BOOL    = 0x7FFD000000000000UL;
const ulong TAG_STR     = 0x7FFE000000000000UL;  // ptr in low 48 bits
const ulong TAG_ARRAY   = 0x7FFF000000000000UL;
const ulong TAG_RECORD  = 0x8000000000000000UL;
const ulong TAG_CLOSURE = 0x8001000000000000UL;
const ulong TAG_PRIM    = 0x8002000000000000UL;  // prim index in low bits

fn Value val_num(double d)   => bitcast(d, ulong);
fn Value val_nil()           => TAG_NIL;
fn Value val_bool(bool b)    => TAG_BOOL | (ulong)b;
fn Value val_str(String* p)  => TAG_STR    | ((ulong)(uptr)p & PTR_MASK);
fn Value val_arr(Array* p)   => TAG_ARRAY  | ((ulong)(uptr)p & PTR_MASK);
fn Value val_rec(Record* p)  => TAG_RECORD | ((ulong)(uptr)p & PTR_MASK);

fn bool   is_num(Value v)    => (v & NAN_BITS) != NAN_BITS;
fn bool   is_nil(Value v)    => v == TAG_NIL;
fn bool   is_bool(Value v)   => (v & TAG_MASK) == TAG_BOOL;
fn bool   is_str(Value v)    => (v & TAG_MASK) == TAG_STR;
fn bool   is_arr(Value v)    => (v & TAG_MASK) == TAG_ARRAY;
fn bool   is_rec(Value v)    => (v & TAG_MASK) == TAG_RECORD;
fn bool   is_closure(Value v) => (v & TAG_MASK) == TAG_CLOSURE;

fn double   as_num(Value v)    => bitcast(v, double);
fn bool     as_bool(Value v)   => (bool)(v & 1);
fn String*  as_str(Value v)    => (String*)(uptr)(v & PTR_MASK);
fn Array*   as_arr(Value v)    => (Array*)(uptr)(v & PTR_MASK);
fn Record*  as_rec(Value v)    => (Record*)(uptr)(v & PTR_MASK);
fn Closure* as_closure(Value v) => (Closure*)(uptr)(v & PTR_MASK);
```

`bitcast` is a C3 builtin — no union, no pointer cast.

**Platform note:** `env::ARCH_64_BIT` confirms 64-bit; arm64 macOS virtual addresses are
guaranteed 48-bit, so the low-48-bit pointer packing is safe.

**Effort:** ~1 day. Purely mechanical — replace the struct, update all construction and
inspection sites, tests pass unchanged.

---

## Step 2 — Interned field name atoms

**Why:** Record `GET` does a linear scan over `String[]` keys — each iteration is a string
comparison. Replacing keys with `uint` atom IDs makes the scan an integer comparison, which
is 3–4× faster per element and smaller per record.

**How:** A global `HashMap{String, uint}` assigns a compact ID to each distinct field name at
parse time. The hot path never touches strings again for field access.

```c3
import std::collections::map;

struct InternTable {
    HashMap{String, uint} map;
    uint next_id;
}

InternTable g_intern;

fn void intern_init() {
    g_intern.map.init(mem, 64);
    g_intern.next_id = 0;
}

fn uint intern(String s) {
    if (try id = g_intern.map.get(s)) return id;
    uint id = g_intern.next_id++;
    g_intern.map.set(s.copy(mem), id);
    return id;
}
```

`Record` and `Array` field storage changes:

```c3
struct Record {
    uint   refcount;   // for step 5
    uint   len;
    uint*  keys;       // atom IDs, not String[]
    Value* values;     // NaN-boxed (step 1)
}
```

`GET` and `SET` AST nodes store a `uint atom` instead of a `String key`. Intern every field
name in the parser the moment it is lexed; intern builtin names at startup.

`HashMap` from `std::collections` handles the intern table — it calls `.hash()` on `String`
keys natively. The copy `s.copy(mem)` is necessary because the key must outlive the parse.

**Effort:** ~half a day. Parser change + `Record` struct change + update GET/SET eval paths.

---

## Step 3 — Bytecode compiler + VM

**Why:** Every operation in the tree-walker incurs a C function call per AST node plus
pointer-chasing through heap-allocated `AstNode*` structs. A bytecode VM dispatches a
`switch` over a flat `char[]` — one array index per operation, no pointer chasing,
predictable branch pattern. This is the largest single speedup: expected 20–50×.

### 3a — Bytecode chunk

```c3
import std::collections::list;

struct Chunk {
    List{char}  code;       // opcodes + inline operands
    List{Value} constants;  // constant pool (NaN-boxed)
    List{int}   lines;      // source line per instruction (for error messages)
}

fn void chunk_init(Chunk* c) {
    c.code.init(mem, 256);
    c.constants.init(mem, 32);
    c.lines.init(mem, 256);
}

fn void emit(Chunk* c, char byte, int line) {
    c.code.push(byte);
    c.lines.push(line);
}

fn int add_constant(Chunk* c, Value v) {
    c.constants.push(v);
    return (int)c.constants.len() - 1;
}
```

### 3b — Opcode set

```c3
enum Op : char {
    // stack
    PUSH_CONST,      // [Op, u8 const_idx]
    PUSH_NIL,
    POP,
    // locals / upvalues
    LOAD_LOCAL,      // [Op, u8 slot]
    STORE_LOCAL,
    LOAD_UPVAL,      // [Op, u8 upval_idx]
    STORE_UPVAL,
    // functions
    MAKE_CLOSURE,    // [Op, u8 proto_idx, u8 upval_count, <upval descriptors>...]
    CALL,            // [Op, u8 argc]
    TAILCALL,        // [Op, u8 argc]  — reuses current frame
    RETURN,
    // control
    JUMP,            // [Op, i16 offset]  little-endian
    JUMP_IF_FALSE,   // [Op, i16 offset]  — does not pop
    // aggregates
    NEW_RECORD,      // [Op, u8 nfields]  — pops 2*nfields (key atoms + values)
    GET_FIELD,       // [Op, u8 atom_idx] — pops record, pushes value
    SET_FIELD,       // [Op, u8 atom_idx] — pops value + record, pushes value
    NEW_ARRAY,       // [Op, u8 n]        — pops n values
    GET_INDEX,       // pops index + array
    SET_INDEX,       // pops value + index + array
    // exceptions
    PUSH_HANDLER,    // [Op, i16 offset]  — points past the handler
    POP_HANDLER,
    THROW,
    // arithmetic / comparison (inline, no function call)
    ADD, SUB, MUL, DIV,
    EQ, LT, GT, LE, GE,
}
```

All surface forms (SEQ, BINOP, METHODCALL, typed annotations, CONSTRUCT, MATCH) are already
desugared to kernel nodes before compilation. The compiler never sees them.

### 3c — Compiler

The compiler is a single recursive pass over the kernel `AstNode*` tree. It resolves variable
names to slot indices at compile time, eliminating all runtime HashMap lookups.

```c3
struct Local {
    String name;
    int    slot;
    bool   is_captured;  // true once a nested closure references this local
}

struct Compiler {
    Chunk*         chunk;
    Local[256]     locals;
    int            local_count;
    int            scope_depth;
    Compiler*      enclosing;  // for upvalue resolution
}

fn void compile_expr(Compiler* c, AstNode* node, bool tail_pos) {
    switch (node.type) {
        case LIT:
            int idx = add_constant(c.chunk, node.literal);
            emit(c.chunk, (char)PUSH_CONST, 0);
            emit(c.chunk, (char)idx, 0);
        case VAR:
            int slot = resolve_local(c, node.name);
            if (slot >= 0) {
                emit(c.chunk, (char)LOAD_LOCAL, 0);
                emit(c.chunk, (char)slot, 0);
            } else {
                int upval = resolve_upvalue(c, node.name);
                emit(c.chunk, (char)LOAD_UPVAL, 0);
                emit(c.chunk, (char)upval, 0);
            }
        case CALL:
            compile_expr(c, node.children[0], false);
            for (int i = 1; i < node.children.len; i++) {
                compile_expr(c, node.children[i], false);
            }
            int argc = node.children.len - 1;
            Op call_op = tail_pos ? TAILCALL : CALL;
            emit(c.chunk, (char)call_op, 0);
            emit(c.chunk, (char)argc, 0);
        case IF:
            compile_expr(c, node.children[0], false);
            int then_jump = emit_jump(c.chunk, JUMP_IF_FALSE);
            emit(c.chunk, (char)POP, 0);
            compile_expr(c, node.children[1], tail_pos);
            int else_jump = emit_jump(c.chunk, JUMP);
            patch_jump(c.chunk, then_jump);
            emit(c.chunk, (char)POP, 0);
            compile_expr(c, node.children[2], tail_pos);
            patch_jump(c.chunk, else_jump);
        // ... LAMBDA, LETREC, GET, SET, RECORD, ARRAY_LIT, THROW, TRY, PRIM
    }
}
```

`tail_pos` propagates into `IF` branches and the body of `LETREC` — anywhere the result
of the subexpression is directly returned. `CALL` in tail position emits `TAILCALL`.

### 3d — VM

```c3
struct CallFrame {
    Chunk*   chunk;
    int      ip;
    int      base;    // index into vm.stack where this frame's slot 0 is
    Closure* closure;
}

struct Vm {
    Value[2048]    stack;
    int            sp;           // stack pointer (index of next free slot)
    CallFrame[256] frames;
    int            fc;           // frame count
    // exception handler stack
    int[64]        handlers;
    int            handler_top;
}

fn EvalResult vm_run(Vm* vm) {
    CallFrame* frame = &vm.frames[vm.fc - 1];
    while (true) {
        Op op = (Op)frame.chunk.code.get(frame.ip++);
        switch (op) {
            case PUSH_CONST:
                int idx = (char)frame.chunk.code.get(frame.ip++);
                vm.stack[vm.sp++] = frame.chunk.constants.get(idx);
            case LOAD_LOCAL:
                int slot = (char)frame.chunk.code.get(frame.ip++);
                vm.stack[vm.sp++] = vm.stack[frame.base + slot];
            case ADD:
                Value b = vm.stack[--vm.sp];
                Value a = vm.stack[--vm.sp];
                // fast path: both numbers (most common case)
                if (is_num(a) && is_num(b)) {
                    vm.stack[vm.sp++] = val_num(as_num(a) + as_num(b));
                } else if (is_str(a) && is_str(b)) {
                    // string concat
                } else {
                    return type_error("+");
                }
            case TAILCALL:
                int argc = (char)frame.chunk.code.get(frame.ip++);
                // copy new args over old base slots, reset ip
                for (int i = 0; i < argc; i++) {
                    vm.stack[frame.base + i] = vm.stack[vm.sp - argc + i];
                }
                vm.sp = frame.base + argc;
                frame.ip = 0;
                // do NOT push a new frame
            case RETURN:
                Value result = vm.stack[--vm.sp];
                vm.fc--;
                if (vm.fc == 0) return { .value = result };
                vm.sp = frame.base - 1;  // -1 for the function slot itself
                frame = &vm.frames[vm.fc - 1];
                vm.stack[vm.sp++] = result;
            // ...
        }
    }
}
```

**No allocations in the hot path.** `CallFrame` is a slot in a fixed array. Local variables
are indexed into `vm.stack`. The only allocations are `MAKE_CLOSURE` (one `Closure*` per
closure creation) and `NEW_RECORD` / `NEW_ARRAY`.

The tree-walker (`eval()`) is kept alive until the bytecode VM passes all tests. Then remove it.

---

## Step 4 — Tail-call optimization (TAILCALL)

**Why:** Loops in DS are recursion. Without TCO, `sum(n, acc)` at n=1000 overflows the C
stack. With `TAILCALL`, it runs at any depth using constant stack space.

This is not a separate step from the VM — `TAILCALL` is one opcode in the set above, emitted
by the compiler whenever a `CALL` appears in tail position. The VM case (shown in step 3d)
copies args over the current frame's base slots and resets `ip = 0`.

**Tail position rules:**
- The body of a `LAMBDA` is in tail position.
- Both branches of `IF` inherit tail position from the parent.
- The body of `LETREC` is in tail position.
- The function being called in a `CALL` is never in tail position.
- Argument expressions are never in tail position.

The `tail_pos` flag threads through `compile_expr` automatically. No additional analysis needed.

---

## Step 5 — Reference counting

**Why:** The pool allocator (`mem::tnew`, `@pool`) never reclaims allocations until the scope
exits. fib(35) allocates ~9.8 GB because every `Env`, `Closure`, and `Value[]` created during
the 29M recursive calls stays live. Reference counting reclaims objects immediately when they
go out of scope, keeping memory flat.

**Intrusive refcount fields** on heap objects (integrates with the NaN-boxed pointer scheme):

```c3
struct Array {
    uint   refcount;
    uint   len;
    Value* items;
}

struct Record {
    uint   refcount;
    uint   len;
    uint*  keys;    // atom IDs
    Value* values;
}

struct Closure {
    uint   refcount;
    Chunk* proto;   // shared, not owned — chunks are immutable after compilation
    Value* upvals;
    uint   upval_count;
}
```

**Inc/dec helpers** called at VM push/pop:

```c3
fn void rc_inc(Value v) {
    if (is_arr(v))     { as_arr(v).refcount++;     return; }
    if (is_rec(v))     { as_rec(v).refcount++;     return; }
    if (is_closure(v)) { as_closure(v).refcount++; return; }
    // numbers, bools, nil: no heap object, nothing to do
    // strings: handled separately if strings become heap-owned
}

fn void rc_dec(Value v) {
    if (is_arr(v)) {
        Array* a = as_arr(v);
        if (--a.refcount == 0) {
            for (uint i = 0; i < a.len; i++) rc_dec(a.items[i]);
            mem::free(a.items);
            mem::free(a);
        }
        return;
    }
    if (is_rec(v)) {
        Record* r = as_rec(v);
        if (--r.refcount == 0) {
            for (uint i = 0; i < r.len; i++) rc_dec(r.values[i]);
            mem::free(r.keys);
            mem::free(r.values);
            mem::free(r);
        }
        return;
    }
    if (is_closure(v)) {
        Closure* c = as_closure(v);
        if (--c.refcount == 0) {
            for (uint i = 0; i < c.upval_count; i++) rc_dec(c.upvals[i]);
            mem::free(c.upvals);
            mem::free(c);
            // c.proto (Chunk*) is not freed here — chunks are arena-owned
        }
        return;
    }
}
```

**Where to call:**
- `PUSH_CONST`, `LOAD_LOCAL`, `LOAD_UPVAL`: `rc_inc` the value being pushed.
- `POP`, `STORE_LOCAL`, `STORE_UPVAL`: `rc_dec` the value being replaced or discarded.
- `RETURN`: `rc_dec` everything in the frame's local slots before unwinding.
- `NEW_ARRAY`, `NEW_RECORD`: new object starts with `refcount = 1`.
- `MAKE_CLOSURE`: new closure starts with `refcount = 1`.

**Cycles:** `let f = fn() { f() }` creates a closure that captures itself — a refcount cycle.
Plain refcounting leaks it. For now: detect the self-referential `LETREC` pattern in the
compiler and emit a `BREAK_CYCLE` cleanup at the end of the enclosing scope that nulls the
upvalue. A full cycle collector (mark-and-sweep over the object graph) is a later addition
if real programs create non-trivial cycles.

`@pool` and `mem::tnew` stay for parse-time and desugar-time work (AST nodes, type check
expressions) — that allocation is bounded by source size and freed when parsing completes.
Only VM runtime objects (closures, arrays, records) use `mem::new` + refcounting.

---

## Expected outcomes

| Metric | Tree-walker now | After all 5 steps |
|---|---|---|
| fib(35) speed | 47.8s | ~1–2s (est.) |
| fib(35) memory | 9.8 GB | ~5–20 MB |
| Max recursion depth | ~200 | Unlimited (TCO) |
| Value size | 40 bytes | 8 bytes |

Steps 1+2 are low-risk refactors with immediate measurable gains. Step 3 is the main event.
Steps 4+5 are additive on top of the VM and do not require revisiting steps 1+2.
