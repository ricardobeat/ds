# DS Language Manual

DS is a small, expression-oriented scripting language with JSX-like element syntax, reactive signals, and pattern matching. Every construct is an expression and returns a value.

---

## Comments

```ds
// Single-line comment — everything from // to end of line

/* Multi-line
   block comment */
```

---

## Values and Literals

| Type    | Example                         |
|---------|---------------------------------|
| Number  | `42`, `3.14`, `-1`              |
| String  | `"hello"`, `"line\nnewline"`    |
| Raw string | `` `no escapes here` ``      |
| Boolean | `true`, `false`                 |
| Nil     | `nil`                           |

String escape sequences: `\"`, `\\`, `\n`, `\r`, `\t`, `\0`.

---

## Variables

```ds
let x = 42
let name = "Alice"
let point = { x: 3, y: 4 }
```

`let` bindings are immutable. The name is in scope for the rest of the program (or the enclosing block).

Optional type annotation:

```ds
let count: Number = 0
```

---

## Functions

Anonymous function:

```ds
let add = fn(a, b) { a + b }
```

Named function declaration (shorthand):

```ds
fn double(x) { x * 2 }
```

Both forms are equivalent. The `fn` shorthand is syntactic sugar for `let name = fn(...)`.

### Type Annotations

Parameters and return types can be annotated. Annotations are checked at runtime (boundary guards).

```ds
fn distance(p: { x: Number, y: Number }) -> Number {
  p.x * p.x + p.y * p.y
}
```

Supported type names: `Number`, `String`, `Bool`, `Array`, `Record`, `Nil`.
Record type shapes: `{ key: Type, ... }`.

### Closures

Functions close over their enclosing scope:

```ds
fn make_adder(base) {
  fn(x) { base + x }
}
let add10 = make_adder(10)
add10(5)  // → 15
```

### Recursion

Functions can call themselves by name. Mutual recursion uses `let`:

```ds
fn factorial(n) {
  if n <= 1 then 1
  else n * factorial(n - 1)
}
```

---

## Operators

### Arithmetic

```ds
a + b    // add (also string concatenation)
a - b
a * b
a / b
a % b    // modulo
-a       // unary negation
```

### Comparison

```ds
a === b   // strict equality (same type and value)
a !== b   // strict inequality
a < b
a > b
a <= b
a >= b
```

### Logical

```ds
a and b   // short-circuit AND
a or b    // short-circuit OR
!a        // logical NOT
```

### Nullish coalescing

```ds
a ?? b    // b if a is nil or throws, otherwise a
```

### Spread

```ds
{ ...record, key: value }   // record spread — copies all fields then overrides
```

### Range

```ds
a..b    // used in slice expressions and some builtins
```

---

## Control Flow

### If / Then / Else

`if` is an expression — it always returns a value.

```ds
let abs = if x < 0 then -x else x

// Multi-branch
let grade =
  if score >= 90 then "A"
  else if score >= 80 then "B"
  else if score >= 70 then "C"
  else "F"
```

`else` is required when `if` is used as a value. Omitting it returns `nil`.

---

## Records

Records are key-value maps with static field access.

```ds
let person = {
  name: "Alice",
  age: 30,
  address: { city: "Portland" }
}

person.name           // → "Alice"
person.address.city   // → "Portland"
```

### Functional Update (spread)

```ds
let older = { ...person, age: 31 }
```

All fields from `person` are copied, then `age` is overridden.

### has_field

```ds
has_field(person, "name")   // → true
has_field(person, "zzz")    // → false
```

---

## Arrays

```ds
let a = [1, 2, 3, 4, 5]

a[0]             // indexing — 0-based
a[len(a) - 1]   // last element
```

### Builtin Array Functions

| Function | Description |
|----------|-------------|
| `len(arr)` | Length |
| `push(arr, val)` | Append in-place (returns `nil`) |
| `slice(arr, from, to)` | Sub-array `[from, to)` |
| `map(arr, fn)` | Transform each element |
| `mapi(arr, fn)` | Like `map` but `fn(elem, index)` |
| `filter(arr, fn)` | Keep elements where `fn(elem)` is truthy |
| `filteri(arr, fn)` | Like `filter` but `fn(elem, index)` |
| `reduce(arr, fn, init)` | Fold with accumulator |
| `array_all(arr, fn)` | True if `fn(elem)` is truthy for all elements |

```ds
let doubled = map([1, 2, 3], fn(x) { x * 2 })   // → [2, 4, 6]
let evens   = filter([1,2,3,4], fn(x) { x % 2 === 0 })
let sum     = reduce([1,2,3,4,5], fn(acc, x) { acc + x }, 0)
```

---

## Pattern Matching

### Tagged Union Match

`match` dispatches on the `__tag` field of a record. Each arm binds the `__val` field to its variable.

```ds
fn mk_num(n) { { __tag: "Num", __val: { value: n } } }
fn mk_add(l, r) { { __tag: "Add", __val: { left: l, right: r } } }

fn eval(e) {
  match e {
    Num(n) -> n.value
    Add(a) -> eval(a.left) + eval(a.right)
  }
}
```

Arms use `->` (not `=>`). Commas between arms are optional.

### Primitive Match (value match)

Match on plain values with a nested `match`:

```ds
match key.rune {
  "h" -> move_left()
  "l" -> move_right()
  "q" -> { ...state, quit: true }
  _   -> state   // wildcard arm
}
```

The wildcard `_` matches anything and must come last.

### Variable Arms

Arms can bind to a variable identifier instead of a constructor:

```ds
match msg {
  Key(k) ->
    match k.code {
      k_left  -> go_left(state)
      k_right -> go_right(state)
      _       -> state
    }
  WindowSize(sz) -> { ...state, width: sz.width, height: sz.height }
  Tick(_)        -> state
}
```

---

## Error Handling

```ds
throw "something went wrong"   // throw any value
```

```ds
let result = try risky_call() catch e {
  "caught: " + e
}
```

`try … catch e body` — if the `try` expression throws, `e` is bound to the thrown value and `body` is evaluated. Both `try` and `catch` are expressions.

```ds
// Nullish coalescing as a soft alternative
let val = might_throw() ?? "default"
```

---

## Imports

```ds
from "./build/libterm" import *           // import everything from a plugin
from signals import { signal, derived }   // selective import from a module
```

Imports are resolved at startup. Plugin paths are relative to the working directory.

---

## Signals (Reactive State)

Signals provide mutable reactive cells. They can be used standalone or with the `$` sugar.

### Explicit API

```ds
let count = signal(0)
signal_set(count, 42)
let v = signal_get(count)

let doubled = derived(fn() { signal_get(count) * 2 })

effect(fn() {
  print("count changed to", signal_get(count))
})
```

### Sugar Syntax

Prefix a variable name with `$` to implicitly call `signal_get`:

```ds
let $count = signal(0)
let $name  = signal("Alice")

// Reading: $count expands to signal_get(count)
let msg = "Hello " + $name

// Writing: still requires signal_set explicitly
signal_set(count, $count + 1)
```

`derived` creates a lazily-evaluated computed signal that recomputes when its dependencies change.
`effect` runs a side-effectful function whenever its signal dependencies change.

---

## JSX / Elements

Elements call registered component functions and support memoization by render slot.

```ds
<Text value="Hello" />

<Box border="rounded" padding_x=2>
  <Text value="content" />
</Box>

<VStack gap=1>
  <Text value="first" />,
  <Text value="second" />
</VStack>
```

Attribute values can be strings (`"..."`) or bare expressions (numbers, variables, booleans).

Children can include computed arrays — a variable holding an array of nodes is spread automatically:

```ds
let items = mapi(names, fn(name, idx) { <Text value=name /> })

<VStack gap=0>
  items
</VStack>
```

### Built-in Components

| Component | Description |
|-----------|-------------|
| `<Text value=... />` | Styled text. Supports `fg`, `bold`, `dim`, `italic`, `width`, `reverse`. |
| `<Box>` | Container with border, padding, colors. Supports `border`, `border_fg`, `fg`, `bg`, `bold`, `padding_x`, `padding_y`, `pt/pr/pb/pl`, `width`, `height`, `align_h`, `align_v`. |
| `<VStack gap=N>` | Vertical stack of children with optional gap lines. |
| `<HStack gap=N>` | Horizontal stack of children. Supports `width` + `constraints` for proportional layout. |
| `<Divider width=N char="─" />` | Horizontal rule. |
| `<StatusBar>` | Status bar widget. |
| `<TextInput>` | Single-line text input widget. |
| `<List>` | Scrollable list widget. |

---

## TUI Model (run_model)

The Elm-style model/update/view loop for terminal UIs:

```ds
let init = fn() { { count: 0, quit: false } }

let update = fn(state, msg) {
  match msg {
    Key(k) ->
      match k.rune {
        "q" -> { ...state, quit: true }
        _   -> state
      }
    Tick(_) -> state
    None(_) -> state
  }
}

let view = fn(state) {
  <VStack gap=1>
    <Text value=num_to_str(state.count) />
  </VStack>
}

run_model({ init: init, update: update, view: view })
```

### Messages

| Constructor | Payload |
|-------------|---------|
| `Key(k)` | `k.code` (key constant), `k.rune` (string) |
| `WindowSize(sz)` | `sz.width`, `sz.height` |
| `Tick(_)` | Timer tick |
| `None(_)` | No-op |

### Key Constants

```ds
KEY_ENTER()      KEY_BACKSPACE()   KEY_ESC()
KEY_UP()         KEY_DOWN()
KEY_LEFT()       KEY_RIGHT()
KEY_DELETE()     KEY_CTRL_C()
KEY_RUNE("a")    // match a specific character
```

---

## String Utilities

| Function | Description |
|----------|-------------|
| `num_to_str(n)` | Number to string |
| `str_repeat(s, n)` | Repeat string n times |
| `str_pad_left(s, w, ch)` | Left-pad to width |
| `str_pad_right(s, w, ch)` | Right-pad to width |
| `str_slice(s, from, to)` | Substring |
| `str_concat(a, b)` | Concatenate (same as `a + b`) |
| `string_width(s)` | Visual width (handles ANSI and Unicode) |

---

## Math Utilities

```ds
floor(3.7)   // → 3
ceil(3.2)    // → 4
round(3.5)   // → 4
abs(-5)      // → 5
max(a, b)    // larger of two
min(a, b)    // smaller of two
```

---

## Rendering Utilities

These produce styled terminal strings (ANSI).

```ds
style_render("text", { fg: "#ff0000", bold: true, width: 20 })
join_vertical([str1, str2, str3])
join_horizontal([str1, str2, str3], gap)
```

---

## Type Predicates

```ds
is_number(v)   is_string(v)   is_bool(v)
is_array(v)    is_record(v)   is_nil(v)
```

---

## Semicolons

Semicolons are optional between statements and may be used to separate expressions on the same line.

---

## Scoping Rules

- `let` bindings are lexically scoped to the rest of the program (or block).
- Functions create a new scope for their parameters.
- Closures capture their enclosing environment by reference.
- There is no mutable reassignment for `let` bindings — use signals for mutable state.
