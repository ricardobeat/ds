# Progress

## Status: Build-order step 1 — kernel tree-walker (DONE) + parser + CLI + formatter + element syntax

The full kernel evaluator is in `src/main.c3` (~1370 LoC), the surface
parser in `src/parser.c3` (~1080 LoC), and the round-trip formatter in
`src/formatter.c3` (~440 LoC). 81 tests pass across kernel, parser,
element, and formatter test files.

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

### Next (in build order)

- [x] B. Port the reference test cases to C3 unit tests
- [x] C. Arrays + records dispatch
- [x] D. Method-call desugaring (front-end only)
- [x] E. Rung 1 type-check desugaring
- [x] F. Rung 2 type table, Construct, match
- [x] H. Surface parser + CLI
- [x] I. Round-trip formatter
- [x] J. JSX-like element syntax
- [ ] G. Bytecode compiler + VM (upvalue closing, TAILCALL, refcounting)
