# new-engine

A small interpreter for a JS-shaped language, written in C3 (0.8.0). The
engine is a tree-walker over a tiny kernel (~12 AST nodes); every surface
feature (let, seq, binop, method calls, type annotations, sum/match)
desugars into the kernel before the evaluator runs.

## Quick start

```bash
c3c build                       # build the engine
./build/engine run resources/sample.ds
./build/engine fmt resources/sample.ds
./build/engine fmt resources/element_sample.ds
```

## CLI

```text
engine run <file.ds>   parse + desugar + evaluate, print the final value
engine fmt <file.ds>   parse + re-emit in canonical 2-space, K&R style
engine <file.ds>       same as `run <file.ds>` (legacy form)
```

`run` is the program; `fmt` is the formatter; without a subcommand the
engine defaults to `run`.

## Language at a glance

Surface syntax (full grammar lives in `src/parser.c3`):

- **Literals**: `42`, `3.14`, `"hi"`, `true`, `false`, `nil`
- **Bindings**: `let name = expr;` chains into a body expression
- **Records**: `{ name: "Alice", age: 30 }` with field access via `.name`
- **Arrays**: `[1, 2, 3]`, indexed with `[i]`
- **Functions**: `fn(x) { x + 1 }`, with optional `-> ReturnType` annotation
- **Calls**: `f(a, b, c)`, methods `r.greet(a, b)` (desugared; receiver
  evaluated once and passed as the explicit `self` argument)
- **If**: `if cond then a else b`
- **Errors**: `throw v` caught by `try e catch name handler`
- **Sum/match** (Rung 2): `type Shape = Circle(Int) | Rectangle({w,h})`,
  `Construct(tag, v)`, `match s { Circle(c) => ..., Rectangle(r) => ... }`
- **Element syntax** (JSX-like): `<Tag attr=val ... />` and
  `<Tag>child, child, ...</Tag>` desugar to plain function calls (see
  below)

## Element syntax (JSX-like)

HTML-ish tags are sugar for a function call.  The tag is just the name of
a function in scope; the first argument is a record of attributes, and any
children become additional arguments.

```text
<Foo bar="x" />              =>  Foo({bar: "x"})
<Foo bar="x">a, b, c</Foo>    =>  Foo({bar: "x"}, a, b, c)
```

Attribute values may be string literals, numbers, bools, or identifiers
(variables).  See `resources/element_sample.ds` for a tiny DOM built out
of element constructors.

The desugaring adds no new AST nodes — elements are plain `Call` nodes
the moment the parser is done with them.  The element-vs-comparison
ambiguity (`<` is both) is resolved by looking at the next token:
`<` followed by an identifier is an element, anything else is a
comparison.

## Formatter

The formatter (`engine fmt <file.ds>`) is round-trip: it parses the
source, then re-emits the AST in a canonical 2-space, K&R style.
Comments are dropped (the lexer discards them).  The output is
idempotent — `engine fmt x.ds | engine fmt -` is a no-op.  Style:

- 2-space indent, K&R braces (`{` on the same line as the parent)
- Records and arrays: one element per line, trailing comma
- Function bodies: single-line if short, block if long
- If/else breaks across lines when the inline form is over 50 chars
- The last expression of a program has no trailing semicolon

## Build

```bash
c3c build              # debug build (default)
c3c build release      # release build
c3c test --test-noleak # run all tests
```

Tests are split into:

- `test/kernel_test.c3` — kernel evaluator + desugarer (port of
  `reference/test.py` sections 1, 2, 3, 5, 7, plus surface/rung1/rung2)
- `test/parser_test.c3` — surface parser (24 tests)
- `test/element_test.c3` — element syntax (13 tests)
- `test/formatter_test.c3` — round-trip + style (13 tests)

`--test-noleak` is required: the current build heap-allocates everything
and the refcounting lands with the bytecode VM (step G of the build
order).  Until then, "alloc and let the OS reclaim on exit" is the
policy.

## Layout

```
src/
  main.c3        — Value, AST, Env, desugarer, evaluator, CLI
  parser.c3      — Lexer + parser (surface)
  formatter.c3   — round-trip formatter
test/
  kernel_test.c3
  parser_test.c3
  element_test.c3
  formatter_test.c3
resources/
  sample.ds            — programs/methods/HOFs/conditionals
  element_sample.ds    — JSX-like element syntax
reference/
  engine.py            — Python source of truth for semantics
  test.py              — ported test cases
docs/
  high-level-plan.md   — language spec and design invariants
```

## Status

Build-order steps A–F (kernel, arrays/records, method-call sugar,
Rung 1, Rung 2, parser, CLI, formatter, element syntax) are all
landed.  Step G — bytecode compiler + VM with upvalue closing and
TAILCALL, plus refcounting — is the next big push.
