# Progress

## Status: Build-order step 1 — kernel tree-walker (DONE)

The full kernel evaluator is in `src/main.c3` (single file, ~700 LoC) and
`test/kernel_test.c3` has 20 passing tests, ported from `reference/test.py`
sections 1, 2, 3, 5, 7 (the ones the kernel can answer directly).

### What works

- All 13 kernel nodes: Lit, Var, Lambda, Call, If, Get, Set, Record,
  ArrayLit, Throw, Try, Prim, LetRec
- Value universe: Number, String, Bool, Nil, Array, Record, Closure, Primitive
- Heap-allocated Array / Record / Closure / AstNode / Env
- Primitives: `+ - * / === < > <= >= and or is_number is_string is_bool
  is_array is_record is_nil has_field len push print`
- `push` mutates an array in place (with manual realloc)
- `Set` returns the assigned value (matches Rust/Rung 1 invariant)
- Truthy: only `false` and `nil` are falsy (0 and "" are truthy, Lua-style)
- `===` is strict type-then-value equality
- Recursive `let` via `LetRec` (name visible in its own initializer)
- Throws carry a value; `try/catch` binds it in a fresh env

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

### Next (in build order)

- [x] B. Port the reference test cases to C3 unit tests  *(done for kernel)*
- [x] C. Arrays + records dispatch  *(done in eval)*
- [x] D. **Method-call desugaring (front-end only)** ← landed
- [x] E. **Rung 1 type-check desugaring** ← just landed (30 tests, all pass)
- [x] F. **Rung 2 type table, Construct, match** ← just landed (30 tests, all pass)
- [ ] G. Bytecode compiler + VM (upvalue closing, TAILCALL) ← *next*

### Step D details

- New surface node types: `SEQ`, `BINOP`, `METHODCALL`
- `BinOp(op, a, b)`           → `Call(Prim(op), [a, b])`
- `Seq([a, b, ...])`          → `Call(Lambda(["_"], rest), [a])` (right-fold)
- `MethodCall(r, m, args)`    → `Call(Lambda(["r"], Call(Get(r, m), [r, ...args])), [r])`
  (receiver bound once, field lookup runs once, receiver passed as explicit self)
- The desugarer descends into children of every node — **including `LAMBDA`**
  (its body might itself be a `SEQ`).

### New gotcha (Step D)

- **Slice literal as function argument that the function stores.**
  `make_lambda({ "x" }, body)` makes a `String[]` stack temp; the temp
  lives only until `make_lambda` returns. If `make_lambda` copies the
  slice's (ptr, len) into a heap struct field (which it must, since the
  AST outlives the call), the copy points at freed stack. The same trap
  applies to `make_record({...}, ...)`. **Both now heap-copy their slice
  argument on entry.**

### Memory note

- Switched `mem::tnew` → `mem::new` everywhere in the kernel because the
  temp arena reallocates on growth, which invalidates every pointer that
  lives in it. We pay for the leak detection (run with `c3c test --test-noleak`)
  until refcounting lands with the bytecode VM.
