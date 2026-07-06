#!/usr/bin/env bash
# bench/run.sh — measure wall time for each (runtime, benchmark) pair.
#
# Usage:  bench/run.sh                    # full sweep
#         bench/run.sh fib_iter           # one benchmark
#         bench/run.sh fib_iter fact      # subset
#
# Output: bench/results.csv (appended) and printed table.
# Each row: benchmark,runtime,time_s
#
# RSS sampling via `ps` is skipped: the shell sandbox doesn't permit it.
# Use Activity Monitor / `top` for a one-off RSS check.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=bench/results.csv
echo "benchmark,runtime,time_s" > "$OUT"

# Discover benchmarks
if [ $# -gt 0 ]; then
  BENS=("$@")
else
  BENS=()
  for f in bench/sources/*.ds; do
    BENS+=("$(basename "$f" .ds)")
  done
fi

# Runtime entries: "label|arg0 arg1 arg2"
# We split the part after the first ':' on whitespace into an array.
RUNTIMES=(
  "tw|./build/engine run"
  "vm|./build/engine vm"
  "node|node"
  "qjs|qjs"
  "python|python3"
  "lua|lua"
  "luajit|luajit"
  "wren|wren_cli"
)
EXT=( ".ds"  ".ds"  ".js"  ".js"  ".py"  ".lua"  ".lua"  ".wren" )
SUBDIR=( ""     ""     "js"   "qjs"  "py"   "lua"   "luajit" "wren" )

run_one() {
  local bench=$1 rt=$2 cmdline=$3 ext=$4 sub=$5
  # cmdline may have multiple words — split into argv array
  local -a argv
  # shellcheck disable=SC2206
  argv=( $cmdline )
  local src
  if [ -n "$sub" ]; then
    src="bench/refs/$sub/${bench}${ext}"
  else
    src="bench/sources/${bench}${ext}"
  fi
  [ -f "$src" ] || { echo "  ! missing $src"; return; }

  local start end t
  start=$(date +%s.%N)
  if ! "${argv[@]}" "$src" > /dev/null 2>&1; then
    echo "  $rt FAILED (${argv[*]} $src)"
    return
  fi
  end=$(date +%s.%N)
  t=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e - s}')
  printf "%s,%s,%s\n" "$bench" "$rt" "$t" >> "$OUT"
  printf "  %-7s %8ss\n" "$rt" "$t"
}

sweep() {
  for b in "${BENS[@]}"; do
    echo "=== $b ==="
    for i in "${!RUNTIMES[@]}"; do
      local entry="${RUNTIMES[$i]}"
      local rt="${entry%%|*}"
      local cmdline="${entry#*|}"
      run_one "$b" "$rt" "$cmdline" "${EXT[$i]}" "${SUBDIR[$i]}"
    done
  done
}

sweep

echo
echo "wrote $OUT"
column -ts, < "$OUT"
