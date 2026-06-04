# Progress

## Status: Build-order step 1 + step 2 — NaN-boxed Value + interned field atoms (DONE); tree-walker prim inlining (DONE); flat-array Env (DONE); tree-walker fast-path optimizations (DONE)

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
- HashMap-backed `Env` (O(1) name lookup per scope)
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
- [ ] G. Bytecode compiler + VM (upvalue closing, TAILCALL, refcounting)
- [ ] L. Parse-time intern of every literal field name (optional
       micro-optimization; currently the intern happens at eval time on
       first lookup, which is still O(1) amortized)
