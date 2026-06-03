#!/usr/bin/env bash
set -uo pipefail

ENGINE="$(dirname "$0")/../build/engine"
WREN="/tmp/wren-cli-mac-0.4.0/wren_cli"
QJS="/tmp/qjs-darwin"

BS="========================================================="
echo "+${BS}+"
printf "|  %-55s  |\n" "DS Engine vs Wren vs QuickJS"
printf "|  %-55s  |\n" "$(date)"
printf "|  %-55s  |\n" "Host: $(uname -m) macOS"
echo "+${BS}+"
echo ""

TMPDIR="/tmp/bench_$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

run_bench() {
  local label="$1"
  local lang="$2"
  local file="$3"
  local tout="${4:-30}"

  local time_file="$TMPDIR/time.txt"
  local prog_file="$TMPDIR/prog.txt"

  if [ "$lang" = "ds" ]; then
    /usr/bin/time -l "$ENGINE" run "$file" 1>"$prog_file" 2>"$time_file"
  elif [ "$lang" = "wren" ]; then
    /usr/bin/time -l "$WREN" "$file" 1>"$prog_file" 2>"$time_file"
  elif [ "$lang" = "js" ]; then
    /usr/bin/time -l "$QJS" "$file" 1>"$prog_file" 2>"$time_file"
  fi

  local ec=$?
  local elapsed=$(awk '/real/ {print $1}' "$time_file")
  local mem=$(awk '/maximum resident/ {print $1}' "$time_file")
  local out=$(tr -d '\n' < "$prog_file")

  printf "  %-20s  %10s  %10s KB" "$label" "$elapsed" "$mem"
  if [ -n "$out" ]; then
    printf "  [%s]" "$out"
  fi
  printf "\n"
  if [ $ec -ne 0 ]; then
    printf "  ⚠ exit code %d\n" $ec
  fi
}

printf "  %-20s  %10s  %s\n" "Benchmark" "Time" "Max RSS"
printf "  %-20s  %10s  %s\n" "---------" "----" "-------"
echo ""

# ============================================================
echo "--- fib(N) tree-recursive ---"
for n in 20 25 30 35; do
  cat > "$TMPDIR/fib_n.ds" <<EOF
let f = fn(n) { if n < 2 then n else f(n - 1) + f(n - 2) };
f($n)
EOF
  cat > "$TMPDIR/fib_n.wren" <<EOF
var f
f = Fn.new { |n| if (n < 2) return n; return f.call(n - 1) + f.call(n - 2) }
System.print(f.call($n))
EOF
  cat > "$TMPDIR/fib_n.js" <<EOF
function f(n) { return n < 2 ? n : f(n - 1) + f(n - 2); }
console.log(f($n));
EOF

  run_bench "fib($n) DS"    ds   "$TMPDIR/fib_n.ds"   120
  run_bench "fib($n) Wren"  wren "$TMPDIR/fib_n.wren"  10
  run_bench "fib($n) QJS"   js   "$TMPDIR/fib_n.js"    10
  echo ""
done

# ============================================================
echo "--- sum(N) tail-recursive ---"
for n in 100 200; do
  cat > "$TMPDIR/sum_n.ds" <<EOF
let s = fn(n, a) { if n === 0 then a else s(n - 1, a + n) };
s($n, 0)
EOF
  run_bench "sum($n) DS" ds "$TMPDIR/sum_n.ds"
done

for n in 100 200 1000000; do
  cat > "$TMPDIR/sum_n.wren" <<EOF
var s
s = Fn.new { |n, a| if (n == 0) return a; return s.call(n - 1, a + n) }
System.print(s.call($n, 0))
EOF
  cat > "$TMPDIR/sum_n.js" <<EOF
function s(n, a) { return n === 0 ? a : s(n - 1, a + n); }
console.log(s($n, 0));
EOF
  run_bench "sum($n) Wren" wren "$TMPDIR/sum_n.wren"
  run_bench "sum($n) QJS"  js   "$TMPDIR/sum_n.js"
  echo ""
done

# ============================================================
echo "--- record field tail-recursive ---"
for n in 100 200; do
  cat > "$TMPDIR/rec_n.ds" <<EOF
let g = fn(n, a) { if n === 0 then a else g(n - 1, {x: n, y: n + 1}.x + a) };
g($n, 0)
EOF
  run_bench "rec($n) DS" ds "$TMPDIR/rec_n.ds"
done

for n in 100 200 100000; do
  cat > "$TMPDIR/rec_n.wren" <<EOF
var g
g = Fn.new { |n, a|
  if (n == 0) return a
  return g.call(n - 1, {x: n, y: n + 1}.x + a)
}
System.print(g.call($n, 0))
EOF
  cat > "$TMPDIR/rec_n.js" <<EOF
function g(n, a) { return n === 0 ? a : g(n - 1, ({x: n, y: n + 1}).x + a); }
console.log(g($n, 0));
EOF
  run_bench "rec($n) Wren" wren "$TMPDIR/rec_n.wren"
  run_bench "rec($n) QJS"  js   "$TMPDIR/rec_n.js"
  echo ""
done

echo ""
echo "--- done ---"
