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

- [ ] B. Port the reference test cases to C3 unit tests  *(done for kernel; desugarer tests still missing)*
- [ ] C. Arrays + records dispatch  *(done in eval)*
- [ ] D. **Method-call desugaring (front-end only)** ← *next*
- [ ] E. Rung 1 type-check desugaring
- [ ] F. Rung 2 type table, Construct, match
- [ ] G. Bytecode compiler + VM (upvalue closing, TAILCALL)
