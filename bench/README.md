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

## Output

`bench/run.sh` writes:
- `bench/results.csv` — long format (one row per measurement)
- `bench/results.md` — pivoted Markdown table (benchmarks × runtimes)

`—` in the table = not run / not ported / stack overflow.


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
