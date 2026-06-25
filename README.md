# new-engine

A small interpreter for a JS-shaped language, written in C3 (0.8.0). The
engine is a tree-walker over a kernel of ~12 AST nodes. Every surface
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

The desugaring adds no new AST nodes. Elements are plain `Call` nodes
the moment the parser is done with them.  The element-vs-comparison
ambiguity (`<` is both) is resolved by looking at the next token:
`<` followed by an identifier is an element, anything else is a
comparison.

## Signals (reactivity)

Signals are mutable cells that remember who is reading them, so anything
derived from them can re-run when they change.  Think of them as the
spreadsheet model: cells hold values, formulas recompute when a cell they
reference changes.

```text
let count = signal(0)          // a cell holding 0
signal_set(count, 42)          // update it
signal_get(count)              // => 42

let doubled = derived(fn() { signal_get(count) * 2 })
signal_get(doubled)            // => 84

effect(fn() { ... })           // side-effecting watcher
```

- **`signal(v)`** creates a cell starting at `v`.  Read it with
  `signal_get(s)`, write it with `signal_set(s, v)` (which returns `nil`).
  A cell can hold any value: numbers, strings, records, anything.
- **`derived(fn() { ... })`** is a lazy computed value.  Whatever signals
  its function reads become its dependencies, tracked automatically, so you
  never declare them.  It caches its result and only recomputes after a
  dependency changes, so reading it twice in a row is free.  Deriveds can
  read other deriveds, and changes propagate down the whole chain.
- **`effect(fn() { ... })`** runs its function immediately, then re-runs it
  every time any signal it read changes.  This is where side effects live
  (logging, updating the outside world).

The point of dependency tracking is that you describe *what* a value is in
terms of others, and the engine works out *when* to recompute it.

## Referentially-stable elements

UI is rebuilt by re-running render code over and over.  If each render
produced brand-new objects, nothing downstream could tell "the same button
as last frame" from "a new button."  The stable-ref primitives give each
element a durable identity tied to its *position* in the render, not to the
object produced.

```text
__begin_render()                          // start a render pass; slots reset to 0
let a = __element(Div, {id: "header"})    // slot 0
let b = __element(Div, {id: "body"})      // slot 1

__begin_render()                          // next pass; slots reset to 0 again
let c = __element(Div, {id: "header"})    // slot 0 again, same identity as `a`
```

- **`__begin_render()`** starts a render pass and resets the slot counter
  to 0.
- **`__element(fn, props, ...children)`** calls the component `fn` and
  records the result in the next slot.  The slot number is assigned by call
  order, so the Nth `__element` call in every pass refers to the same
  logical element.

Because identity comes from slot position, the second render's slot 0 *is*
the first render's slot 0, even though the props record is a fresh object.
That stable mapping is what lets a renderer diff passes, reuse work when the
inputs match, and reconcile props onto the element that was already there
instead of recreating it.

See `resources/signals_demo.ds` for a runnable program exercising both.

## Formatter

The formatter (`engine fmt <file.ds>`) is round-trip: it parses the
source, then re-emits the AST in a canonical 2-space, K&R style.
Comments are dropped (the lexer discards them).  The output is
idempotent: `engine fmt x.ds | engine fmt -` is a no-op.  Style:

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

- `test/kernel_test.c3`: kernel evaluator + desugarer (port of
  `reference/test.py` sections 1, 2, 3, 5, 7, plus surface/rung1/rung2)
- `test/parser_test.c3`: surface parser (24 tests)
- `test/element_test.c3`: element syntax (13 tests)
- `test/formatter_test.c3`: round-trip + style (13 tests)

`--test-noleak` is required: the current build heap-allocates everything,
and refcounting lands with the bytecode VM (step G of the build order).
Until then the policy is "alloc and let the OS reclaim on exit".

## Layout

```
src/
  main.c3        Value, AST, Env, desugarer, evaluator, CLI
  parser.c3      Lexer + parser (surface)
  formatter.c3   round-trip formatter
test/
  kernel_test.c3
  parser_test.c3
  element_test.c3
  formatter_test.c3
resources/
  sample.ds            programs/methods/HOFs/conditionals
  element_sample.ds    JSX-like element syntax
reference/
  engine.py            Python source of truth for semantics
  test.py              ported test cases
docs/
  high-level-plan.md   language spec and design invariants
```

## Status

Build-order steps A to F (kernel, arrays/records, method-call sugar,
Rung 1, Rung 2, parser, CLI, formatter, element syntax) are all
landed.  Step G is next: bytecode compiler + VM with upvalue closing
and TAILCALL, plus refcounting.
