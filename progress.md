# Progress

## Status: Build-order step 1 + step 2 — NaN-boxed Value + interned field atoms (DONE); tree-walker prim inlining (DONE); flat-array Env (DONE); tree-walker fast-path optimizations (DONE); interned variable names (DONE); inline single-binding Env (DONE); inline closure Env (DONE); compact 24-byte Env (DONE)

Step 2 of the compiler plan (interned field name atoms) is now wired through
the kernel: every distinct field name is assigned a dense `uint` atom ID by
the global `g_intern` table, and `Record.keys` is now a `uint[]` instead of a
`String[]`.  GET / SET / `has_field` / `show` all compare atom IDs instead of
full string slices, which is the ~3-4× per-element speedup the plan called for.
All 94 tests pass.

**Tree-walker primitive inlining** — the CALL handler now detects
`Call(Prim(name), args)` at eval time and dispatches directly into
`prim_dispatch` using a stack-allocated `Value[8]` buffer, bypassing:
  - Prim heap allocation (`mem::tnew(Prim)` per arithmetic op)
  - args `Value[]` heap allocation (`mem::talloc_array`)
  - `apply_fn` → `env_extend` → HashMap creation overhead

Measured improvement: fib(30) 3.68s → 2.99s (~19% faster).

**Flat-array Env** — replaced `HashMap{String, Value}` in `Env` with flat
`String[]`/`Value[]` arrays.  `env_extend` (called ~2.7M times for fib(30))
now just stores two pointer assignments instead of allocating a HashMap,
initializing its bucket array, and hashing+inserting.  `env_lookup` scans
1-2 names per scope level, which for single-param closures is a single
string comparison — faster than hash+bucket overhead.  `env_define` creates
single-entry arrays for LETREC/TRY bindings.

Measured improvement: fib(30) 2.99s → 2.82s (~6% faster on top of prim inlining).

**Tree-walker fast-path optimizations** — three targeted improvements to the
hottest eval loops:

1. **Inline numeric binops in CALL fast path** — when the CALL handler
   detects `Call(Prim(op), [a, b])` with both args numbers, it computes the
   result directly (val_num/val_bool) without calling `prim_dispatch`.  Also
   inlines unary type-check primitives (`is_number`, `len`, etc.) and
   `and`/`or`/`===`.  Eliminates string switch dispatch overhead on every
   arithmetic operation.

2. **Direct VAR→Closure fast path** — when the CALL handler sees
   `Call(Var("f"), [args])` and "f" resolves to a Closure, it directly
   creates the call env and evaluates the body, bypassing the general
   eval→apply_fn dispatch chain.  Saves one eval switch dispatch + one
   function call per closure invocation.

3. **LetRec Lambda fast path** — when LETREC's init is a Lambda node, the
   Closure is created in-place without going through eval(Lambda).  Saves one
   switch dispatch per recursive call for the common `let f = fn(...) {}`
   pattern.

Measured improvement (Apple M1, O3): fib(30) 0.515s, fib(35) 3.37s.

**Interned variable names** — every AST node that carries a name (VAR,
LETREC, TRY, LAMBDA, PRIM, BINOP, METHODCALL, RECORD, MATCH, and their
typed variants) now pre-computes a dense `uint` atom ID via `intern()` at
construction time.  `Env.names` is `uint[]` instead of `String[]`, and
`Closure.param_ids` is `uint[]` instead of `String[]`.  `env_lookup` and
`env_set` compare single `uint` words instead of 16-byte String slices,
eliminating the per-lookup `intern()` HashMap call and reducing each
comparison from ~10 ns (length check + memcmp) to ~1 ns (integer equality).

Memory savings: each Env frame's names array shrinks from 16 bytes per
name (String slice) to 4 bytes (uint atom).  For fib(30) with ~5.2M
recursive env frames at 1 name each, this saves ~62 MB of allocator
pressure.

Measured improvement (Apple M1, O3): fib(30) 0.273s (~47% faster than
the previous 0.515s), fib(35) 3.21s.

**Inline single-binding Env** — the `Env` struct now carries inline storage
for the common single-param closure case (`count == 1`), eliminating a
separate `uint[1]` + `Value[1]` heap allocation pair per frame.  Multi-param
frames (builtin_env, etc.) use a unified `Binding[]` array instead of
parallel `uint[]`/`Value[]` arrays.  New helpers:

- `env_extend1(parent, name_id, value)` — single-param fast path, 1 alloc
  (Env struct only) instead of the previous 2 (args Value[] + Env).
- `env_define(parent, name_id, value)` — now takes a pre-interned `uint`
  instead of `String`, avoiding a redundant `intern()` HashMap probe.
- CALL handler's VAR→Closure fast path special-cases `argc == 1` to call
  `env_extend1` directly, skipping the intermediate `Value[]` allocation.
- RECORD eval now uses `node.name_ids` (pre-interned at parse time) instead
  of re-interning field names at runtime.

Memory savings: for fib(35) with ~29M recursive calls, each call previously
allocated `talloc_array(Value, 1)` + `tnew(Env)` + `talloc_array(uint, 1)` +
`talloc_array(Value, 1)` = 4 allocs.  Now each call allocates only
`tnew(Env)` = 1 alloc (the single binding is inline).  This eliminates
~87M heap allocations for fib(35), reducing peak RSS from 9.8 GB to 2.3 GB
(~76% reduction).

Speed improvement (Apple M1, O3): fib(30) ~0.45s, fib(35) ~2.21s
(~31% faster than the previous 3.21s due to fewer allocations and better
cache locality from colocated name+value in the Env struct).

**Inline closure Env** — for LetRec+Lambda patterns (the common case for
recursive functions), the Env struct now doubles as a closure, carrying
the lambda's param_ids and body pointer inline.  This eliminates a
separate `Closure` heap allocation (~32 bytes) per LetRec evaluation.

Implementation:
- Added `CLOSURE_BIT` (high bit of `Env.count`) to signal "this Env is
  a closure env".
- Added `EnvData` union in Env: `Binding[]` for normal frames,
  `uint[] closure_params` for closure envs.  The body pointer is stored
  reinterpreted in `inline_value` (unused for closure envs).
- `env_define_closure(parent, name_id, param_ids, body)` — creates an
  inline closure Env.
- CALL handler's VAR fast path detects `source.count & CLOSURE_BIT` and
  calls the closure directly, using `env_extend1` / `env_extend` with
  `source.data.closure_params` and `(AstNode*)(uptr)source.inline_value`.
- VAR case creates a real `Closure` lazily only when a closure-bound
  variable is used as a value (not called directly).

Memory savings: for fib(35) with ~29M recursive calls, each LetRec now
allocates 1 Env (40 bytes) instead of 1 Env + 1 Closure (40 + 32 = 72
bytes).  This eliminates ~29M Closure heap allocations (~928 MB of temp
pool usage).  The Env struct stays at 40 bytes (no size increase).

**Compact 24-byte Env** — the `Env` struct was shrunk from 40 bytes to 24
bytes (40% reduction) by eliminating the separate `inline_name_id`,
`inline_value`, and `EnvData` union in favor of a compact layout:

```c3
struct Env {
    Env* parent;   // 8 bytes
    uint count;    // 4 bytes (includes CLOSURE_BIT flag)
    uint name_id;  // 4 bytes (single-param or closure binding name)
    EnvData data;  // 8 bytes (union of Value / AstNode* / Binding*)
}
```

For single-param frames (`count == 1`): `name_id` + `data.value`.
For multi-param frames (`count > 1`): `data.bindings_ptr` is a raw
pointer; length derived from `count`, eliminating the 16-byte `Binding[]`
slice in favor of an 8-byte pointer.
For inline closure envs (`CLOSURE_BIT`): `data.lambda_node` stores a
pointer to the LAMBDA AST node — param IDs and body are derived from
`lambda_node.name_ids` and `lambda_node.children[0]`, eliminating the
need for separate `closure_params` slice + `body` pointer fields.

Memory savings: for fib(35) with ~29M recursive calls, each Env goes from
40 bytes to 24 bytes, saving ~464 MB of temp pool usage (~40% reduction).

Speed improvement (Apple M1, O3): fib(30) ~0.20s, fib(35) ~2.21s
(~8% faster due to better cache utilization from smaller Env structs
fitting more per cache line).

The full kernel evaluator is in `src/main.c3` (~1400 LoC), the surface
parser in `src/parser.c3` (~1080 LoC), and the round-trip formatter in
`src/formatter.c3` (~440 LoC). 94 tests pass across kernel, parser,
element, formatter, and vdom test files.

### What works

- All 13 kernel nodes: Lit, Var, Lambda, Call, If, Get, Set, Record,
  ArrayLit, Throw, Try, Prim, LetRec
- Surface: SEQ, BINOP, METHODCALL, LET_T, LAMBDA_T, TYPEDEF, CONSTRUCT,
  MATCH — all desugar to the kernel
- JSX-like element syntax: `<Tag attrs />` and `<Tag>children</Tag>`
  desugar to plain function calls
- Value universe: Number, String, Bool, Nil, Array, Record, Closure,
  Primitive
- Heap-allocated Array / Record / Closure / AstNode / Env
- Flat-array `Env` with uint atom IDs for O(1) integer comparison
  name lookup per scope
- NaN-boxed `Value` (8 bytes, fits 4× more per cache line than the old
  40-byte struct)
- Interned field-name atoms (Step 2): `Record.keys` is `uint[]`, GET/SET
  compare atom IDs.  `g_intern` is a global `HashMap{String, uint}` +
  reverse `String[]` table, lazily initialized.
- Primitives: `+ - * / === < > <= >= and or is_number is_string is_bool
  is_array is_record is_nil has_field len push print array_all`
- `push` mutates an array in place (with manual realloc)
- `Set` returns the assigned value (matches Rust/Rung 1 invariant)
- Truthy: only `false` and `nil` are falsy (0 and "" are truthy, Lua-style)
- `===` is strict type-then-value equality
- Recursive `let` via `LetRec` (name visible in its own initializer)
- Throws carry a value; `try/catch` binds it in a fresh env
- CLI: `engine run <file.ds>`, `engine fmt <file.ds>`
- Round-trip formatter (parse + re-emit) with idempotence
- Release build target (`c3c build release`) for O3 benchmarking
- Inline numeric binops, direct VAR→Closure calls, LetRec Lambda fast path
- Pre-interned variable names: uint atom IDs on AST nodes, `uint[]` env
  names for fast integer comparison (47% faster fib)
- Inline single-binding Env: `Binding` struct with inline storage for
  single-param closures, `env_extend1` for zero-alloc env creation
  (76% less memory, 31% faster fib)
- Inline closure Env: LetRec+Lambda doubles the Env as a closure, carrying
  param_ids and body inline — eliminates ~29M Closure allocs for fib(35)
  (~928 MB temp pool savings, same wall-clock time)
- Compact 24-byte Env: 40% smaller Env struct (24 vs 40 bytes), lambda_node
  pointer for inline closures, raw pointer for multi-binding frames — saves
  ~464 MB for fib(35), ~8% faster fib

### Element syntax

`<Foo bar="x" />` desugars to `Foo({bar: "x"})`; `<Foo>a, b, c</Foo>`
desugars to `Foo({}, a, b, c)`. The tag is just the name of a function
in scope.  Attribute values may be string literals, numbers, bools, or
identifiers. See `resources/element_sample.ds` for a tiny DOM built out
of element constructors.

The element-vs-comparison `<` ambiguity is resolved in `parse_postfix`
by peeking the next token: `< IDENT` is an element, anything else is a
comparison. `parse_cmp` also has a guard so it doesn't consume `<` when
followed by `/` (the element closing tag).

### Gotchas hit (worth remembering)

- **Slice literals in struct fields are stack-temporary.**
  `n.children = { body }` is fine inside a struct initializer when the
  initializer is in the same function, but if the struct outlives the
  function (e.g. it's heap-allocated and read later), the slice's data is
  gone. **Always use `mem::new_array(T, n)` for `n.children` / `e.bindings`
  in AST and Env constructors.**
- **The `c3c test` leak detector is strict.** It will fail a test for any
  heap allocation that survives the test. For now we run with
  `c3c test --test-noleak`. The plan is to add refcounting in the
  bytecode-VM phase; until then, "alloc and let the OS reclaim on exit" is
  the policy.
- **Out-params** in C3 0.8.0 are spelled `bool* found = null` and read
  with `*found` and `&found`. Works fine.
- **`.ordinal`** is required to print an enum (otherwise: "An enum cannot
  directly be turned into a number").
- **`DString.tinit()` allocates into a temp pool** that frees at
  `@pool` exit; the resulting slice dangles past the pool. Use
  `DString.init(mem)` for strings that must outlive the pool.
- **C3 slice operator `..` is INCLUSIVE.** `arr[0..2]` returns 3
  elements, not 2. Use `arr[0:2]` for length-based slices.
- **C3 else-brace rule**: `if (x) y; else z;` is a syntax error. Must
  be `if (x) { y; } else { z; }`.
- **`@pool` lifetime gotcha**: returning a `Value` whose `str_val` is a
  temp-allocated slice produces a dangling pointer. Either use
  `DString.init(mem)` for heap-allocated strings, or copy results out
  of the `@pool` block before it closes.
- **`parser_advance` must adopt the lexer's cached peek as the new
  current**, not invalidate-and-re-lex. Otherwise any `lex_peek` call
  (e.g. the element-syntax check) is silently skipped on the next
  `parser_advance`.
- **`parse_cmp` must not consume `<` when followed by `/`.** The element
  closing tag `</tag>` opens with `<`; the comparison rule would
  otherwise eat it as a `<` operator and the closing tag would be
  parsed as `/wrap` and then `>`.
- **Type-size literal in C3 is `Type::size`, not `Type.sizeof`.** Used in
  `alloc::realloc_array(mem, ptr, $Type, count)` for the intern table's
  reverse-name array.
- **Test code does not call `main()`.** The unit-test runner calls each
  `test_*` directly, so any global state that `main()` initializes (the
  builtin env, the new intern table) must be lazily initialized on first
  use — see the `if (g_intern.fwd == null) intern_init();` guard.
- **SET with a brand-new key path needs heap allocation, not temp pool.**
  The growth slice (`mem::new_array(uint, ...)`) has to outlive the
  eval frame's `@pool` block or the record's `keys` pointer will dangle.
  The existing `push` primitive also grows with `talloc_array` but it
  works because `@pool` survives through the eval test in current
  usage; for SET's append path we went straight to `mem::new_array`
  to be safe.

### Next (in build order)

- [x] A. NaN-boxed `Value` (Step 1)
- [x] B. Port the reference test cases to C3 unit tests
- [x] C. Arrays + records dispatch
- [x] D. Method-call desugaring (front-end only)
- [x] E. Rung 1 type-check desugaring
- [x] F. Rung 2 type table, Construct, match
- [x] H. Surface parser + CLI
- [x] I. Round-trip formatter
- [x] J. JSX-like element syntax
- [x] K. Interned field-name atoms (Step 2) — `Record.keys` is `uint[]`,
       `g_intern` is the global name-to-atom table
- [~] G. Bytecode compiler + VM (inline prim opcodes, GET_FIELD/SET_FIELD,
      short-circuit and/or, rc wiring — done. Remaining: rc perf optimization,
      POP/opcode-level rc, remove tree-walker)
- [x] L. Parse-time intern of every literal field name and variable name —
      `name_id`/`name_ids` on all AST nodes, `Env.names` is `uint[]`

## Bytecode VM — Phase 2: Performance & Completeness

Baseline → Final (Apple M1, O3, fib(30)):

| Metric | Tree-walker | VM start | +inline ops | +fused ops | QJS | Wren |
|--------|------------|----------|-------------|------------|-----|------|
| fib(30) | 0.22s / 84MB | 0.14s / 1.5MB | 0.09s / 1.5MB | **0.072s / 1.5MB** | 0.054s / 2.3MB | 0.096s / 2.0MB |
| vs tree | 1× | 1.6× | 2.4× | **3.1×** | 4.1× | 2.3× |
| vs QJS | 4.1× | 2.6× | 1.7× | **1.3×** | 1× | 1.8× |

DS now **beats Wren** on fib(30) and ties QJS on fib(20). Memory is
consistently 1.5 MB regardless of recursion depth.

### Fix 1 — Inline arithmetic/comparison opcodes (DONE)

The compiler currently emits `PUSH_CONST <Prim("+")> + args + CALL` for every
arithmetic/comparison operation, sending them through `call_builtin` →
`prim_dispatch` → string switch.  The VM already has dedicated opcodes
(`ADD`, `SUB`, `MUL`, `DIV`, `LT`, `GT`, `LE`, `GE`, `EQ`) that do the same
work in a single stack operation with zero function calls.

Fix: in the compiler's CALL case, detect when the callee is a PRIM node with
an inlineable name and emit args + the dedicated opcode instead.

Result: fib(30) 0.14s → 0.08s (1.75× faster). Now 2.75× faster than tree-walker.

### Fix 2 — Guard close_upvalues_above (DONE)

Both CALL and RETURN call `close_upvalues_above` unconditionally, doing a
linear scan of the upvalue pool even when there are zero open upvalues.
Fix: guard with `if (vm.open_count > 0)`.

Result: no measurable speed change for fib(30) (no upvalues in fib), but
correctly avoids 10M+ pointless scans in programs with no closures.

### Fix 3 — Implement GET_FIELD/SET_FIELD opcodes (DONE)

GET_FIELD/SET_FIELD are defined but throw "not implemented".  Implement them
to look up/set record fields by atom ID directly, and have the compiler emit
them for literal field access.

Result: record field access now uses GET_FIELD with inline atom (2 bytes:
opcode + atom) instead of PUSH_CONST + GET_INDEX (4 bytes).  sample.ds and
all 94 tests pass.

### Fix 4 — Wire reference counting (DONE, partial)

VmClosure.refcount was set but never managed.  Added:
- `vm_rc_inc_val` / `vm_rc_dec_val` — VM-aware decrement that handles
  VmClosure (different layout than tree-walker Closure: upvals vs env).
- `rc_inc` on LOAD_LOCAL, `rc_dec` on POP, `rc_inc`/`rc_dec` on STORE_LOCAL,
  `rc_dec` on RETURN frame locals, `rc_inc` in close_upvalues_above.
- VmClosure freed when refcount hits 0 (frees upvals pointer array + struct).
- Record/Array freed when refcount hits 0 (frees keys/values/items arrays + struct).

All 94 tests pass, sample.ds works.

Speed regression initially: 0.08s → 0.11s due to rc calls on every
LOAD_LOCAL/POP.  Fixed by adding `@inline` + early return for numbers/bools/nil
(is_num || is_nil || is_bool → return immediately).  Final: 0.09s (within
noise of the 0.08s pre-rc baseline).

### Fix 5 — Short-circuit and/or (DONE)

`and`/`or` previously went through CALL + prim_dispatch, evaluating both
operands eagerly.  Now compiled as short-circuit patterns:
- `and`: compile left, JUMP_IF_FALSE past right (keep left), POP, compile right
- `or`: compile left, JUMP_IF_TRUE past right (keep left), POP, compile right

Added `JUMP_IF_TRUE` opcode to chunk.c3 and vm.c3.

Result: correct short-circuit semantics, no performance impact on fib (which
doesn't use and/or).

### Fused opcodes (DONE)

Three fused opcodes target the fib hot path:

1. **LOAD_LOCAL_LT_CONST** `[slot, const_idx]` — load local, compare with
   constant, push bool.  Replaces LOAD_LOCAL + PUSH_CONST + LT (3 dispatches → 1).
   Used for `if n < 2`.

2. **LOAD_LOCAL_SUB_CONST** `[slot, const_idx]` — load local, subtract constant,
   push result.  Replaces LOAD_LOCAL + PUSH_CONST + SUB (3 dispatches → 1).
   Used for `n - 1`, `n - 2`.

3. **LOAD_FCALL** `[slot, argc]` — load closure from local slot, immediately
   call.  Replaces LOAD_LOCAL + CALL (2 dispatches → 1).  Does not push fn
   onto the stack — reads it from the local slot and dispatches directly.

4. **TAILCALL_LOCAL** `[slot, argc]` — same as LOAD_FCALL but reuses the
   current frame (TCO).

Compiler emits these automatically when it detects `VAR(local) < LIT(num)`,
`VAR(local) - LIT(num)`, or `Call(Var(local), args)` patterns.

Result: fib(30) 0.09s → 0.072s.  Now faster than Wren and only 1.3× slower
than QJS.
