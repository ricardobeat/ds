#!/usr/bin/env bash
set -uo pipefail

ENGINE="${DS_ENGINE:-$(dirname "$0")/../build/release}"
WREN="${WREN_CLI:-$(command -v wren_cli 2>/dev/null || echo /opt/homebrew/bin/wren_cli)}"
QJS="${QJS_BIN:-$(command -v qjs 2>/dev/null || echo /opt/homebrew/bin/qjs)}"

for bin in "$ENGINE" "$WREN" "$QJS"; do
  [ -x "$bin" ] || { echo "error: $bin not found or not executable" >&2; exit 1; }
done

BENCHDIR="/tmp/bench_$$"
mkdir -p "$BENCHDIR"
trap 'rm -rf "$BENCHDIR"' EXIT

# ── High-precision timer ──────────────────────────────────────────

now_sec() { date +%s%N; }

timer_start() { _t0=$(now_sec); }

timer_stop() {
  local t1=$(now_sec)
  awk "BEGIN {printf \"%.3f\", ($t1 - $_t0) / 1000000000.0}"
}

# ── Formatting ─────────────────────────────────────────────────────

W=71
TOP='  ┌────────────────────┬───────────┬──────────┬────────┬──────────────┐'
HDR='  │ %-18s │ %9s │ %8s │ %6s │ %12s │'
SEP='  ├────────────────────┼───────────┼──────────┼────────┼──────────────┤'
BOT='  └────────────────────┴───────────┴──────────┴────────┴──────────────┘'

print_header() {
  printf '\n'
  printf '%*s\n' "$W" '' | tr ' ' '═'
  printf '  DS Engine vs Wren vs QuickJS\n'
  printf '  %s · %s %s\n' "$(date '+%a %e %b %Y')" "$(uname -m)" "$(uname -s)"
  printf '%*s\n' "$W" '' | tr ' ' '═'
}

print_section() {
  local sec="$1"
  local sec_line="── ${sec} "
  local pad=$((W - ${#sec_line}))
  [ "$pad" -lt 0 ] && pad=0
  printf '\n'
  printf '%s' "$sec_line"
  printf '%*s' "$pad" '' | tr ' ' '─'
  printf '\n\n'
  printf '%s\n' "$TOP"
  printf "$HDR\n" "Benchmark" "Time" "RSS" "vs QJS" "Result"
  printf '%s\n' "$SEP"
}

print_row() {
  local name="$1" raw_time="$2" raw_mem="$3" ratio="$4" out="$5" ec="$6"

  local fmt_t
  if [ -z "$raw_time" ]; then fmt_t="—"; else fmt_t="${raw_time} s"; fi

  local fmt_m
  if [ -z "$raw_mem" ]; then
    fmt_m="—"
  else
    local kb=$(($raw_mem / 1024))
    if [ "$kb" -ge 1024 ]; then
      fmt_m=$(awk "BEGIN {printf \"%.1f MB\", $kb / 1024.0}")
    else
      fmt_m="${kb} KB"
    fi
  fi

  printf "$HDR\n" "$name" "$fmt_t" "$fmt_m" "$ratio" "$out"
  [ "$ec" -ne 0 ] && printf "  ⚠ exit %d\n" "$ec"
}

# ── Time lookup (for ratio computation) ────────────────────────────

declare -A QJS_TIMES=()

find_qjs_time() { echo "${QJS_TIMES[$1]:-}"; }

compute_ratio() {
  local this_time="$1" qjs_time="$2"
  if [ -n "$this_time" ] && [ -n "$qjs_time" ]; then
    r=$(awk "BEGIN { v = $this_time / $qjs_time; if (v > 0) printf \"%.1f\", v; else print \"ERR\" }")
    if [ "$r" != "ERR" ] && [ "$r" != "inf" ] && [ "$r" != "nan" ]; then
      printf "%5sx" "$r"
      return
    fi
  fi
  printf "    —"
}

# ── Run a single benchmark and print its row immediately ───────────

run_one() {
  local label="$1" base="$2" lang="$3" file="$4"
  local cmd
  case "$lang" in
    ds)   cmd="$ENGINE run $file" ;;
    wren) cmd="$WREN $file" ;;
    js)   cmd="$QJS $file" ;;
  esac

  local tf="$BENCHDIR/time.txt" pf="$BENCHDIR/prog.txt"

  local ec=0
  timer_start
  { /usr/bin/time -l $cmd 1>"$pf" 2>"$tf"; } 2>/dev/null || ec=$?
  local elapsed=$(timer_stop)

  local raw_mem=$(awk '/maximum resident/ {print $1}' "$tf")
  local out=$(tr -d '\n' < "$pf")

  local ratio
  if [[ "$label" == *"QJS"* ]]; then
    QJS_TIMES["$base"]="$elapsed"
    ratio=" 1.0x"
  else
    ratio=$(compute_ratio "$elapsed" "$(find_qjs_time "$base")")
  fi

  print_row "$label" "$elapsed" "$raw_mem" "$ratio" "$out" "$ec"
}

# ── Header ────────────────────────────────────────────────────────

print_header

# ── fib(N) tree-recursive ─────────────────────────────────────────

print_section "fib(N) tree-recursive"
for n in 20 25 30; do
  cat > "$BENCHDIR/fib.ds" <<EOF
let f = fn(n) { if n < 2 then n else f(n - 1) + f(n - 2) };
f($n)
EOF
  cat > "$BENCHDIR/fib.wren" <<EOF
var f
f = Fn.new { |n|
  if (n < 2) return n
  return f.call(n - 1) + f.call(n - 2)
}
System.print(f.call($n))
EOF
  cat > "$BENCHDIR/fib.js" <<EOF
function f(n) { return n < 2 ? n : f(n - 1) + f(n - 2); }
console.log(f($n));
EOF

  base="fib($n)"
  run_one "$base QJS"   "$base" js   "$BENCHDIR/fib.js"
  run_one "$base Wren"  "$base" wren "$BENCHDIR/fib.wren"
  run_one "$base DS"    "$base" ds   "$BENCHDIR/fib.ds"
done

# ── sum(N) tail-recursive ─────────────────────────────────────────
# DS now has TCO — can run at any depth.  QJS has no TCO.

print_section "sum(N) tail-recursive"
for n in 100 10000 100000; do
  cat > "$BENCHDIR/sum.ds" <<EOF
let s = fn(n, a) { if n === 0 then a else s(n - 1, a + n) };
s($n, 0)
EOF
  cat > "$BENCHDIR/sum.wren" <<EOF
var s
s = Fn.new { |n, a|
  if (n == 0) return a
  return s.call(n - 1, a + n)
}
System.print(s.call($n, 0))
EOF
  cat > "$BENCHDIR/sum.js" <<EOF
function s(n, a) { return n === 0 ? a : s(n - 1, a + n); }
console.log(s($n, 0));
EOF

  base="sum($n)"
  run_one "$base QJS"   "$base" js   "$BENCHDIR/sum.js"
  run_one "$base Wren"  "$base" wren "$BENCHDIR/sum.wren"
  run_one "$base DS"    "$base" ds   "$BENCHDIR/sum.ds"
done

# ── record field tail-recursive ───────────────────────────────────

print_section "record field tail-recursive"
for n in 100 200; do
  cat > "$BENCHDIR/rec.ds" <<EOF
let g = fn(n, a) { if n === 0 then a else g(n - 1, {x: n, y: n + 1}.x + a) };
g($n, 0)
EOF
  cat > "$BENCHDIR/rec.wren" <<EOF
var g
g = Fn.new { |n, a|
  if (n == 0) return a
  var r = {"x": n, "y": n + 1}
  return g.call(n - 1, r["x"] + a)
}
System.print(g.call($n, 0))
EOF
  cat > "$BENCHDIR/rec.js" <<EOF
function g(n, a) { return n === 0 ? a : g(n - 1, ({x: n, y: n + 1}).x + a); }
console.log(g($n, 0));
EOF

  base="rec($n)"
  run_one "$base QJS"   "$base" js   "$BENCHDIR/rec.js"
  run_one "$base Wren"  "$base" wren "$BENCHDIR/rec.wren"
  run_one "$base DS"    "$base" ds   "$BENCHDIR/rec.ds"
done

printf '%s\n' "$BOT"
printf '\n'
