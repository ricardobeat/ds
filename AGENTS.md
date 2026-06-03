# AGENTS.md

## Project Overview

A JS variant interpreter written in C3. The design follows a minimal expression-oriented approach with a tiny kernel (~12 AST nodes) and surface features that desugar into it.

## Build Commands

```bash
c3c build                       # Build debug target
c3c build release               # Build release target
c3c test --test-noleak          # Build + run all 81 tests
./build/engine run <file.ds>    # Parse + desugar + evaluate, print the value
./build/engine fmt <file.ds>    # Print the source re-formatted in canonical style
./build/engine <file.ds>        # Same as `run` (legacy form)
```

Output binary: `build/engine`

## Syntax

Javascript-like. No ASI. Surface features (let, seq, binop, method calls,
typed functions, sum types, pattern matching, and JSX-like elements) all
desugar to the small kernel before the evaluator runs.

## Project Structure

```
src/main.c3            - Entry point, Value, AST, Env, desugarer, evaluator, CLI
src/parser.c3          - Lexer + surface parser
src/formatter.c3       - Round-trip formatter (canonical 2-space, K&R style)
reference/engine.py    - Python source of truth for semantics
reference/test.py      - Test cases showing expected behavior
docs/high-level-plan.md - Full language specification and design invariants
test/                  - @test functions (kernel, parser, element, formatter)
resources/             - Standalone .ds scripts (sample, element_sample)
```

## Key Design Decisions (from reference)

### Lambda annotations desugar to runtime boundary checks

Type annotations on Lambdas are stripped during desugaring and replaced with `If(Call(Prim is_*, [x]), x, Throw(...))` wrappers. The evaluator never sees types.

### `===` is strict equality

`===` checks type equality first, then value equality. No `==` coercion operator exists.

### Set is an expression

`Set` returns the value being assigned, like Rust. Loops-for-effect return `Nil`.

### Element syntax (JSX-like) is sugar for function calls

`<Foo bar="x" />` desugars to `Foo({bar: "x"})`; `<Foo>a, b</Foo>`
desugars to `Foo({}, a, b)`. The element-vs-comparison `<` ambiguity is
resolved in `parse_postfix` by peeking the next token: `< IDENT` is an
element, anything else is a comparison. `parse_cmp` also has a guard so
it doesn't consume `<` when followed by `/` (the element closing tag).

### Parser uses the lexer's peek cache

`parser_advance` adopts the cached peek as the new current and updates
the cache by one more `lex_next`. This is required for `lex_peek` results
(e.g. the element check) to survive a subsequent `parser_advance`.

## Value Universe

| Language | C3 type | Notes |
|----------|---------|-------|
| Number   | `double` | IEEE-754 double |
| String   | `String` | Immutable UTF-8 |
| Bool     | `bool`   | |
| Nil      | (Value with type=NIL) | Zero value |
| Array    | `void*`  | Points to Array struct |
| Record   | `void*`  | Points to Record struct |
| Closure  | `void*`  | Points to Closure struct |

## Reference Implementation

The Python reference (`reference/engine.py`) is the source of truth for semantics. When implementing features:
1. Read the reference implementation
2. Understand the desugaring rules
3. Port to C3 with appropriate memory management

## What's Explicitly Out of Scope

- `var`/hoisting, ASI, `with`, `==`/coercion, prototypes
- `this`, `arguments`, sloppy mode
- Host/web APIs (embedder provides those)
- `Date`, `Intl`, regex, `Promise`
