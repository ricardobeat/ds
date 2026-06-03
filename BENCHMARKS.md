# DS Engine Benchmarks

Comparison against [Wren](https://wren.io/) (v0.4.0, bytecode VM) and
[QuickJS](https://github.com/quickjs-ng/quickjs) (v0.15.0, bytecode VM) across
a fib(35) microbenchmark.  The DS engine is a tree-walking interpreter with a
pool allocator and no tail-call optimisation — these results are a **baseline**
for the planned bytecode compiler (step **G**).

## Environment

|          |                         |
|----------|------------------------|
| Host     | Apple M1 (arm64) macOS |
| DS       | C3 0.8.0 tree-walker   |
| Wren     | 0.4.0 (CLI)            |
| QuickJS  | 0.15.0 (quickjs-ng)    |
| Date     | 2026-06-03             |

## Fibonacci (tree recursion)

```
let fib = fn(n) { if n < 2 then n else fib(n - 1) + fib(n - 2) };
fib(N)
```

| N  | Recursive calls | DS        | Wren     | QuickJS  | Ratio (DS/Wren) | Ratio (DS/QJS) |
|----|-----------------|-----------|----------|----------|-----------------|----------------|
| 20 |         21,891  | 0.04 s    | 0.01 s   | 0.00 s   | 4×              | —              |
| 25 |        242,785  | 0.33 s    | 0.02 s   | 0.00 s   | 16×             | —              |
| 30 |      2,692,537  | 3.68 s    | 0.13 s   | 0.06 s   | 28×             | 61×            |
| 35 |     29,860,703  | 47.81 s   | 1.32 s   | 0.65 s   | 36×             | 74×            |

DS scales **O(φ<sup>n</sup>)** as expected.  Wren and QuickJS are within 2× of
each other for this benchmark.

### Memory (fib(35))

| Runtime  | Peak RSS  |
|----------|-----------|
| DS       | **9.8 GB** |
| Wren     | 3.7 MB    |
| QuickJS  | 2.5 MB    |

The pool allocator (`@pool` / `tnew`) never reclaims intermediate allocations
until the scope exits.  fib(35) allocates ~9.8 GB over 29M recursive calls
because every `tnew` for values, environments, and closures stays live.  This
is the primary motivation for step **G** (bytecode + GC / refcounting).

## Tail-recursive sum

```
let sum = fn(n, acc) { if n === 0 then acc else sum(n - 1, acc + n) };
sum(N, 0)
```

DS and QuickJS lack TCO and hit the C/JS stack limit:

| N         | DS                    | Wren                 | QuickJS               |
|-----------|-----------------------|----------------------|-----------------------|
| 100       | 0.00 s / 5.6 MB       | 0.01 s / 3.7 MB      | 0.00 s / 2.6 MB      |
| 200       | 0.00 s / 9.1 MB       | 0.01 s / 3.7 MB      | 0.00 s / 2.7 MB      |
| 1,000     | **stack overflow**    | —                    | 0.00 s / 3.5 MB      |
| 5,000     | —                     | —                    | **stack overflow**   |
| 1,000,000 | —                     | 0.08 s / 77 MB       | —                    |

- DS stack limit: **~200** recursive calls (C3 default ~1 MB C stack)
- QuickJS limit: **~1000** recursive calls (JS engine limit)
- Wren: **unlimited** (proper TCO via fiber frames)

## Record field access

```
let g = fn(n, a) { if n === 0 then a else g(n - 1, {x: n, y: n + 1}.x + a) };
g(N, 0)
```

| N         | DS                    | Wren                 | QuickJS               |
|-----------|-----------------------|----------------------|-----------------------|
| 100       | 0.00 s / 5.7 MB       | 0.01 s / 3.7 MB      | 0.00 s / 2.6 MB      |
| 200       | 0.00 s / 9.2 MB       | 0.01 s / 3.7 MB      | 0.00 s / 2.7 MB      |
| 1,000     | **stack overflow**    | —                    | 0.00 s / 3.5 MB      |
| 100,000   | —                     | 0.05 s / 40 MB       | **stack overflow**   |

## Summary

| Metric                     | DS (tree-walk) | Wren (bytecode) | QuickJS (bytecode) |
|----------------------------|----------------|-----------------|--------------------|
| Tree recursion (fib 35)    | 1× (47.8 s)    | 36× faster      | 74× faster         |
| Tail recursion (max depth) | ~200           | unlimited       | ~1 000             |
| Memory (fib 35)            | 9.8 GB         | 3.7 MB          | 2.5 MB             |
| Implementation             | Tree walker    | Bytecode VM     | Bytecode VM        |
| TCO                        | No             | Yes (fiber)     | No                 |

**Takeaway**: DS is ~40–75× slower than mature bytecode VMs on tree-recursive
workloads and has a severe memory overhead from the pool allocator.  A bytecode
compiler with a proper GC (step **G** of the plan) is the most impactful
improvement.

## Running the benchmarks

```bash
cd benchmarks
bash run.sh
```

Requires [`wren-cli`](https://github.com/wren-lang/wren-cli) and
[`quickjs-ng`](https://github.com/quickjs-ng/quickjs) on `$PATH`.

## Raw data

All measurements using `/usr/bin/time -l` (real wall clock, max RSS).
