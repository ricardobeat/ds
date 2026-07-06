#!/usr/bin/env bash
# bench/run.sh — measure wall time for each (runtime, benchmark) pair.
#
# Usage:  bench/run.sh                    # full sweep
#         bench/run.sh fib_iter           # one benchmark
#         bench/run.sh fib_iter fact      # subset
#
# Writes:
#   bench/results.json — raw timings
# Prints a pivoted table (rendered via jtbl if installed, else fallback).
#
# RSS sampling via `ps` is skipped: the shell sandbox doesn't permit it.
set -euo pipefail
cd "$(dirname "$0")/.."

JSON=bench/results.json

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

# Stable runtime order for output columns
RUNTIME_ORDER=( tw vm node qjs python lua luajit wren )

run_one() {
  local bench=$1 rt=$2 cmdline=$3 ext=$4 sub=$5
  local -a argv
  # shellcheck disable=SC2206
  argv=( $cmdline )
  local src
  if [ -n "$sub" ]; then
    src="bench/refs/$sub/${bench}${ext}"
  else
    src="bench/sources/${bench}${ext}"
  fi
  [ -f "$src" ] || { echo "  ! missing $src"; return 1; }

  local start end t
  start=$(date +%s.%N)
  if ! "${argv[@]}" "$src" > /dev/null 2>&1; then
    echo "  $rt FAILED (${argv[*]} $src)"
    return 1
  fi
  end=$(date +%s.%N)
  t=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e - s}')
  echo "  $rt ${t}s"
  printf '%s\t%s\t%s\n' "$bench" "$rt" "$t" >> "$JSON.tsv"
}

sweep() {
  for b in "${BENS[@]}"; do
    echo "=== $b ==="
    for i in "${!RUNTIMES[@]}"; do
      local entry="${RUNTIMES[$i]}"
      local rt="${entry%%|*}"
      local cmdline="${entry#*|}"
      run_one "$b" "$rt" "$cmdline" "${EXT[$i]}" "${SUBDIR[$i]}" || true
    done
  done
}

# Run all benchmarks, accumulating a TSV (benchmark, runtime, time)
: > "$JSON.tsv"
sweep

# Build the JSON document
{
  echo "{"
  printf '  "benchmarks": ['
  first=1
  for b in "${BENS[@]}"; do
    [ $first -eq 0 ] && printf ", "
    first=0
    printf '"%s"' "$b"
  done
  echo "],"
  printf '  "runtimes": ['
  first=1
  for r in "${RUNTIME_ORDER[@]}"; do
    [ $first -eq 0 ] && printf ", "
    first=0
    printf '"%s"' "$r"
  done
  echo "],"
  echo '  "times": {'
  first=1
  for b in "${BENS[@]}"; do
    [ $first -eq 0 ] && printf ",\n"
    first=0
    printf '    "%s": {' "$b"
    inner=1
    for r in "${RUNTIME_ORDER[@]}"; do
      t=$(awk -F'\t' -v b="$b" -v r="$r" '$1==b && $2==r {print $3; exit}' "$JSON.tsv")
      [ $inner -eq 0 ] && printf ", "
      inner=0
      if [ -n "$t" ]; then
        printf '"%s": %s' "$r" "$t"
      else
        printf '"%s": null' "$r"
      fi
    done
    printf "}"
  done
  echo ""
  echo "  }"
  echo "}"
} | jq . > "$JSON"
rm -f "$JSON.tsv"

# Render pivoted table.
echo
echo "─── table ───"
jq --arg dash '—' -r '
  .runtimes as $rs |
  (["benchmark"] + $rs | join("\t")),
  (.benchmarks[] as $b |
    ([$b] + [ $rs[] as $r | (.times[$b][$r] // $dash) ] | join("\t"))
  )
' "$JSON" | column -ts $'\t'
