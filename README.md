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
- **Sum/match**: `type Shape = Circle(Int) | Rectangle({w,h})`,
  `Construct(tag, v)`, `match s { Circle(c) => ..., Rectangle(r) => ... }`
- **Element syntax** (JSX-like): `<Tag attr=val ... />` and
  `<Tag>child, child, ...</Tag>` desugar to plain function calls (see
  below)

## A tour by example

The fastest way to learn the language is to read a handful of small
programs. Every snippet below is a complete file — run it with
`./build/engine run <file>`. The whole set lives in `resources/` and
`examples/`.

### Bindings, records, functions

A program is an expression. `let` binds a name for the rest of the
program; the final expression is the value the program evaluates to.
Records are the one keyed aggregate, with dot access and explicit-`self`
methods.

```js
let person = {
  name: "Alice",
  age: 30,
  address: { city: "Portland", zip: "97201" }
}

// records double as objects: methods take self explicitly
let counter = {
  count: 0,
  inc: fn(self, n) { { ...self, count: self.count + n } }
}

let c = counter.inc(5).inc(3)     // receiver is passed as self

{ city: person.address.city, total: c.count }   // => { city: "Portland", total: 8 }
```

The last expression has no semicolon and becomes the program's result.
See `resources/records.ds`.

### Closures and higher-order functions

Functions are values and close over their lexical scope, so the usual
combinators fall out for free.

```js
fn make_adder(base) { fn(x) { base + x } }

fn compose(f, g) { fn(x) { f(g(x)) } }
fn curry(f)      { fn(a) { fn(b) { f(a, b) } } }

let add10  = make_adder(10)
let curried = curry(fn(a, b) { a + b })

{ added: add10(7), curried: curried(7)(3) }   // => { added: 17, curried: 10 }
```

Full version with composition and partial application in
`resources/closures.ds`.

### Loops are recursion

There is no `while` or `for`. A tail-recursive function *is* the loop,
and the accumulator pattern keeps every call in tail position.

```js
fn fact(n, acc) {
  if n === 0 then acc
  else fact(n - 1, acc * n)
}

fn fib(n, a, b) {
  if n === 0 then a
  else fib(n - 1, b, a + b)
}

{ fact_10: fact(10, 1), fib_20: fib(20, 0, 1) }   // => { fact_10: 3628800, fib_20: 6765 }
```

### Types as boundary checks

Annotations are optional. They desugar to a runtime `if`/`throw` at the
function boundary — zero cost when the contract holds, a catchable error
when it doesn't.

```js
fn double(x: Number) -> Number { x * 2 }

let ok  = double(21)                          // 42
let bad = try double("hello") catch e e       // catches the type error
```

See `resources/types.ds`.

### Sum types and match

Tagged unions plus `match` give you exhaustive, value-carrying
dispatch — the same shape you'll see drive the TUI examples below.

```js
type Shape = Circle(Number) | Rectangle({ w: Number, h: Number })

fn area(s) {
  match s {
    Circle(r)    -> 3 * r * r
    Rectangle(d) -> d.w * d.h
  }
}

{ a: area(Circle(2)), b: area(Rectangle({ w: 3, h: 4 })) }   // => { a: 12, b: 12 }
```

## Building TUIs with milktea

The `examples/` directory is where the language earns its keep: a small
Elm-style TUI framework, `milktea`, built on top of the engine. An app is
three things — a `state` record, an `update` that turns a message into the
next state, and a `view` that renders state to elements. Wire them up with
`run`.

```js
from milktea import { run }
from keys import { UP, DOWN }

let state = { value: 0 }

fn update(state, msg) {
  match msg {
    Key(k) ->
      match k.code {
        UP   -> { ...state, value: state.value + 1 }
        DOWN -> { ...state, value: state.value - 1 }
        _    -> match k.rune { "q" -> { ...state, quit: true }  _ -> state }
      }
    _ -> state
  }
}

fn view(state) {
  <Box border="rounded" fg="#00d7ff" bold=true padding_x=3 padding_y=1>
    <VStack gap=1>
      <Text value=("Counter: " + num_to_str(state.value)) bold=true />
      <Text value="Use ↑↓ to change, q to quit" dim=true />
    </VStack>
  </Box>
}

run({ state, update, view })
```

That's the whole app (`examples/counter.ds`). State is a plain record,
`update` is pure — it returns a *new* state via record spread (`...state`)
rather than mutating — and `view` is the JSX-like element syntax described
below. Setting `quit: true` ends the program.

### Reacting to time

Beyond keys, `update` receives `Tick` messages. An animation is just a
frame counter you advance on each tick:

```js
let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

let state = { frame: 0 }

fn update(state, msg) {
  match msg {
    Key(k)   -> match k.rune { "q" -> { ...state, quit: true }  _ -> state }
    Tick(_)  -> { ...state, frame: (state.frame + 1) % len(frames) }
    _ -> state
  }
}

fn view(state) {
  <VStack gap=1>
    <Text bold=true fg="#00d7ff" value=(frames[state.frame] + "  Loading...") />
    <Text dim=true value="Press q to quit" />
  </VStack>
}

run({ state, update, view })
```

The full spinner is `examples/spinner.ds`; `examples/timer.ds` is a
countdown that pauses, resets, and stops at zero, all from the same
match-on-message shape.

### A real app

Once you're comfortable with the loop, the pattern scales without new
machinery. `examples/todo.ds` is a complete todo app — a list mode and an
add mode, cursor movement, toggling, deletion, and live text input —
factored into small pure helpers over the same `state`/`update`/`view`
skeleton:

```js
let toggle_done = fn(item) { { ...item, done: !item.done } }

let map_todos = fn(todos, i, f) {
  map(todos, fn(item, j) { if j === i then f(item) else item })
}

fn update_list(state, k) {
  match k.rune {
    " " -> { ...state, todos: map_todos(state.todos, state.cursor, toggle_done) }
    "a" -> { ...state, mode: MODE_ADD, input: "" }
    "d" -> { ...state, todos: remove_at(state.todos, state.cursor) }
    _   -> state   // ...arrow keys move the cursor
  }
}
```

Read the file for the rest — components (`Star`, `render_todo`), an input
mode driven by `RUNE`/`BACKSPACE`/`ENTER` messages, and a status bar — but
there's nothing new in it. It's the same three functions, scaled up.

See the full source: [`examples/todo.ds`](examples/todo.ds).

## Element syntax (JSX-like)

HTML-ish tags are sugar for a function call.  The tag is just the name of
a function in scope; the first argument is a record of attributes, and any
children become additional arguments.

```jsx
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

Signals are mutable cells that track who reads them, so values built from
them recompute when they change. It's the spreadsheet model: cells hold
values, formulas recompute when a referenced cell changes.

A `$` sigil is sugar for the whole API: `let $x = v` creates a signal,
`$x` reads it, and `$x = v` writes it.

```js
let $count = 0                 // a cell holding 0  (let count = signal(0))
$count = 42                    // update it         ($count → signal_set)
$count                         // => 42             ($count → signal_get)

let doubled = derived(fn() { $count * 2 })
$doubled                       // => 84

effect(fn() { ... })           // side-effecting watcher
```

- **`signal(v)`** creates a cell starting at `v`. The `$` forms above
  desugar to it: `let $x = v` → `let x = signal(v)`, `$x` → `signal_get(x)`,
  `$x = v` → `signal_set(x, v)`. A cell can hold any value: numbers,
  strings, records, anything.
- **`derived(fn() { ... })`** is a lazy computed value. The signals its
  function reads become its dependencies, tracked automatically. It caches
  the result and recomputes only after a dependency changes, so re-reading is
  free. Deriveds can read other deriveds; changes propagate down the chain.
- **`effect(fn() { ... })`** runs its function once, then re-runs it whenever
  a signal it read changes. Side effects go here (logging, IO).

### How the tracking works

Signals and deriveds share one struct, `Signal`, split by a `kind` tag. A
plain signal stores a value; a derived stores a cached result plus its
closure. Both track subscribers; deriveds also track their dependencies.

```c3
struct Signal {
    uint refcount;
    SignalKind kind;   // SIG_PLAIN or SIG_DERIVED
    Value current;     // plain: the stored value; derived: cached result
    bool dirty;        // derived: result is stale, recompute on next read
    bool running;      // derived: circular-dependency guard
    Closure* closure;  // derived: the 0-arg computation
    DepNode* deps;     // derived: signals I read
    DepNode* subs;     // both: who reads me
}
```

A global pointer, `g_active_subscriber`, holds whoever is computing right now.
When a derived or effect runs its closure, it points the global at itself
first. Every `signal_get` during the run calls `reactive_track`, which links
the two: the signal goes into the subscriber's `deps`, the subscriber into the
signal's `subs`. After the closure returns, the global is restored, so a
derived reading another derived nests fine.

The dep list is cleared before each run (`d.deps = null`), so dependencies are
exactly the signals read on the last run. Skip a `signal_get` behind a branch
and you're unsubscribed from it until a run takes that branch again.

`signal_set` walks the signal's `subs`:

- **deriveds** get marked dirty (`mark_dirty`, which also dirties deriveds
  downstream). Recompute is deferred: the next `signal_get` on a dirty derived
  re-runs its closure via `derived_evaluate` and caches the result. A clean
  derived just returns `current`.
- **effects** re-run immediately, via `effect_rerun`.

Both carry a `running` flag while their closure is on the stack, so a
computation that triggers itself returns the cached value instead of looping.

## Referentially-stable elements

Render code runs repeatedly, so the same logical element needs to keep its
identity across passes. These primitives tie identity to an element's
*position* in the render rather than to the object produced.

```js
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

Since identity comes from slot position, the second render's slot 0 is the
first render's slot 0, even with a fresh props record. That mapping lets a
renderer diff passes, reuse work when inputs match, and reconcile props onto
the existing element instead of recreating it.

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

`--test-noleak` is required: the current build heap-allocates everything,
and the policy is "alloc and let the OS reclaim on exit".

## Status

The kernel, surface syntax, parser, CLI, formatter, element
syntax, signals, and the bytecode compiler + VM are all landed. The
`milktea` TUI framework and its example apps run on top of the engine.
