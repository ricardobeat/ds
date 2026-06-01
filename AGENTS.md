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

## Syntax

Javascript-like. No ASI. 

## Project Structure

```
src/main.c3          - Entry point, Value types, AST nodes, Env, evaluator skeleton
reference/engine.py  - Python reference implementation (read for design intent)
reference/test.py    - Test cases showing expected behavior
docs/high-level-plan.md - Full language specification and design invariants
```

## Key Design Decisions (from reference)

### Lambda annotations desugar to runtime boundary checks

Type annotations on Lambdas are stripped during desugaring and replaced with `If(Call(Prim is_*, [x]), x, Throw(...))` wrappers. The evaluator never sees types.

### `===` is strict equality

`===` checks type equality first, then value equality. No `==` coercion operator exists.

### Set is an expression

`Set` returns the value being assigned, like Rust. Loops-for-effect return `Nil`.

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
