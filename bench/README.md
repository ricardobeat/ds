# DS benchmark suite

Eight small programs exercising the major language features:
fibonacci (TCO), factorial (TCO), sum (TCO), array build/sum, record
build/fold, string concat, higher-order function, Ackermann (deep
recursion). Each has identical semantics across runtimes — the same
input produces the same output.

```
bench/
├── sources/         # DS source
├── refs/{js,py,lua,luajit,qjs,wren}/   # hand-ported equivalents
├── run.sh           # sweep script
└── results.csv      # machine-readable timings
```

## Run

```sh
c3c build release                 # engine
bench/run.sh                      # all 8 × 8 runtimes
bench/run.sh fib_iter             # one
bench/run.sh fib_iter fact        # subset
```

## Last sweep (Apple M-series, wall time in seconds)

| benchmark         | tw    | vm    | node  | qjs   | python | lua   | luajit | wren  |
|-------------------|-------|-------|-------|-------|--------|-------|--------|-------|
| fib_iter          | 0.005 | 0.004 | 0.034 | 0.006 | 0.020  | 0.005 | 0.004  | 0.006 |
| fact              | 0.004 | 0.005 | 0.034 | 0.006 | 0.019  | 0.005 | 0.005  | 0.006 |
| sum_loop          | 0.112 | 0.026 | stack | stack | stack  | 0.030 | 0.010  | 0.037 |
| array_ops         | 0.007 | 0.007 | 0.041 | —     | —      | 0.006 | 0.006  | 0.007 |
| record_ops        | 0.005 | 0.005 | 0.036 | 0.010 | 0.020  | 0.005 | 0.005  | 0.006 |
| string_concat     | 0.004 | 0.004 | 0.034 | 0.006 | 0.019  | 0.005 | 0.004  | 0.006 |
| closure_higher    | 0.005 | 0.005 | 0.036 | 0.006 | 0.020  | 0.006 | 0.005  | 0.007 |
| nested_recursion  | 0.349 | 0.084 | 0.051 | —     | 0.155  | 0.046 | 0.009  | 0.948 |

`stack` = host stack overflow at 1M recursions; `—` = not ported.

Wren is iterative-only, so its `nested_recursion` is a hand-written
trampolined version. DS is the only runtime in the table that gets
TCO for free in both interpreter (tw) and bytecode (vm) modes.

## Output equivalence

| benchmark         | expected  | ds |
|-------------------|-----------|----|
| fib_iter          | 9227465   | ✓  |
| fact              | 1307674368000 | ✓ |
| sum_loop          | 500000500000 | ✓ |
| array_ops         | 999000    | ✓  |
| record_ops        | 124750    | ✓  |
| string_concat     | 100 chars | ✓  |
| closure_higher    | 385       | ✓  |
| nested_recursion  | 2045      | ✓  |
