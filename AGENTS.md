# AGENTS.md

## Project Overview

A JS variant interpreter written in C3 (systems language by Christoffer Lernö). The design follows a minimal expression-oriented approach with a tiny kernel (~12 AST nodes) and surface features that desugar into it.

**Language**: C3 0.8.0 (LLVM backend)  
**Build system**: `c3c` (C3 compiler)

## Build Commands

```bash
c3c build           # Build debug target
c3c build release   # Build release target  
c3c run             # Build and run
c3c test            # Run @test functions
c3c compile-run src/main.c3  # Compile and run single file
```

Output binary: `build/engine`

## Architecture

Two-layer pipeline (matching reference implementation):

```
Surface AST  →  desugar()  →  Kernel AST  →  eval()
```

**Surface nodes** (~17): Lit, Var, Lambda, Call, If, Let, Seq, BinOp, Record, ArrayLit, Get, Set, MethodCall, Throw, Try, TypeDef, Construct, Match

**Kernel nodes** (~13): Lit, Var, Lambda, Call, If, Get, Set, Record, ArrayLit, Throw, Try, Prim, LetRec

## Project Structure

```
src/main.c3          - Entry point, Value types, AST nodes, Env, evaluator skeleton
reference/engine.py  - Python reference implementation (read for design intent)
reference/test.py    - Test cases showing expected behavior
docs/high-level-plan.md - Full language specification and design invariants
```

## Key Design Decisions (from reference)

### LetRec, not Call-of-Lambda

The plan says `Let` lowers to `Call(Lambda(...), ...)`, but the implementation uses `LetRec`. This is because `Call-of-Lambda` evaluates the initializer in the outer env, so a function can't see itself (no recursion). `LetRec` defines the name first (as placeholder), evaluates init in that env, then patches the binding.

### Lambda annotations desugar to runtime boundary checks

Type annotations on Lambdas are stripped during desugaring and replaced with `If(Call(Prim is_*, [x]), x, Throw(...))` wrappers. The evaluator never sees types.

### Construct/Match use record fields `__tag` and `__val`

Tagged unions are records: `Construct("Circle", expr)` → `Record([("__tag", "Circle"), ("__val", expr)])`. Match generates an If-chain comparing `Get(s, "__tag")` against each branch tag.

### Primitives are callable values

`Prim` nodes wrap into `("__prim__", name)` tuples when evaluated. `apply_fn` checks for this prefix to dispatch to `PRIMS` dict.

### Truthiness

`_truthy(v)` = `v is not None and v is not False`. Everything else is truthy (including `0`, `""`, `[]`). Matches Lua, not Python.

### `===` is strict equality

`===` checks type equality first, then value equality. No `==` coercion operator exists.

### Set is an expression

`Set` returns the value being assigned, like Rust. Loops-for-effect return `Nil`.

## C3-Specific Patterns

### Enum values

When the type is known from context (struct field, function parameter), use bare enum value:
```c3
return { .type = NIL };  // NOT ValueType::NIL
```

### Struct initialization
```c3
Value v = { .type = NIL, .num_val = 0.0 };
```

### Memory management

Manual with three tiers:
1. Stack (default for local fixed-size)
2. Heap: `mem::new(T)`, `mem::free(p)`
3. Temp allocator: `@pool() { ... }` block

### Error handling

Use Optional types (`T?`) with faults, not exceptions:
```c3
faultdef UNBOUND_VAR;
fn Value? env_lookup(Env* env, String name) { ... return UNBOUND_VAR~; }
```

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

Key functions in reference:
- `desugar(e, tenv)` - Surface → Kernel transformation
- `eval_kernel(e, env)` - Kernel evaluator
- `apply_fn(fn, args)` - Function application (closure or primitive)

## What's Explicitly Out of Scope

- Type inference, unification, generics
- `var`/hoisting, ASI, `with`, `==`/coercion, prototypes
- `this`, `arguments`, sloppy mode
- Host/web APIs (embedder provides those)
- `Date`, `Intl`, regex, `Promise`
