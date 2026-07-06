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
└── results.json     # timings: { benchmarks, runtimes, times }
```

## Run

```sh
c3c build release                 # engine
bench/run.sh                      # all 8 × 8 runtimes
bench/run.sh fib_iter             # one
bench/run.sh fib_iter fact        # subset
```

`bench/run.sh` writes `bench/results.json` and prints a pivoted table
(benchmarks × runtimes). `—` cells = no measurement (stack overflow or
not ported).

## Output

`results.json` shape:

```json
{
  "benchmarks": ["array_ops", "closure_higher", ...],
  "runtimes":   ["tw", "vm", "node", "qjs", "python", "lua", "luajit", "wren"],
  "times": {
    "array_ops": { "tw": 0.007, "vm": 0.006, "node": 0.039, "qjs": null, ... },
    ...
  }
}
```


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
