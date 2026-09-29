#!/bin/sh
# ArkDeckKit test lanes.  The full suite remains the merge gate; this runner
# gives local development explicit fast/medium feedback. The Swift Runtime and
# its slow durability lanes were deleted with it (CHG-2026-074); the Rust
# Runtime's own lanes run in rust-ci.yml and rust-perf.yml.

set -eu

# Every lane writes its output to a mktemp file that run_lane removes once it
# has read the numbers back. An interrupted lane never reached that line and
# left the file in $TMPDIR, so the removal is tied to the shell's exit, and a
# signal is turned into an exit that still runs it.
trap 'rm -f "${log:-}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

lane=${1:-}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
swiftpm="$root/Packages/ArkDeckKit/Scripts/run-swiftpm.sh"
workers=${ARKDECK_TEST_WORKERS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '8')}

case $workers in
  ''|0|*[!0-9]*)
    echo "ARKDECK_TEST_WORKERS must be a positive integer" >&2
    exit 64
    ;;
esac

run_lane() {
  label=$1
  shift
  log=$(mktemp -t arkdeck-test-lane.XXXXXX)
  started=$(date +%s)
  set +e
  /usr/bin/time -l "$@" >"$log" 2>&1
  status=$?
  set -e
  cat "$log"
  finished=$(date +%s)
  # A run can mix XCTest and Swift Testing, and SwiftPM runs each test bundle
  # as its own process per framework, so no single line carries the total:
  # it is XCTest's count plus Swift Testing's.
  #   - Swift Testing ends every bundle's run with "Test run with N tests";
  #     those are summed.
  #   - Parallel XCTest numbers each test "[i/N] Testing" against one N for
  #     the whole run, so the last N is its total. It also replays the serial
  #     output of a failing test, which must not be counted again.
  #   - Serial XCTest ends every bundle's run with its top-level suite ('All
  #     tests' or 'Selected tests') and "Executed N tests"; those are summed.
  # A framework that printed no count adds nothing; if neither printed one,
  # the count is unavailable rather than zero.
  test_count=$(awk '
    /Test run with [0-9]+ tests?/ {
      value = $0
      sub(/.*Test run with /, "", value)
      sub(/[^0-9].*/, "", value)
      swift_testing += value
      counted = 1
    }
    /^\[[0-9]+\/[0-9]+\] Testing / {
      value = $0
      sub(/^\[[0-9]+\//, "", value)
      sub(/\].*/, "", value)
      xctest_parallel = value + 0
      parallel = 1
      counted = 1
    }
    top_level_suite_ended && /Executed [0-9]+ tests?/ {
      value = $0
      sub(/.*Executed /, "", value)
      sub(/[^0-9].*/, "", value)
      xctest_serial += value
      counted = 1
    }
    { top_level_suite_ended = /^Test Suite .(All|Selected) tests. (passed|failed) at / }
    END {
      if (counted) print swift_testing + (parallel ? xctest_parallel : xctest_serial)
    }' "$log")
  maximum_resident_set=$(sed -n -E \
    's/^[[:space:]]*([0-9]+)  maximum resident set size$/\1/p' "$log" | tail -n 1)
  peak_memory_footprint=$(sed -n -E \
    's/^[[:space:]]*([0-9]+)  peak memory footprint$/\1/p' "$log" | tail -n 1)
  rm -f "$log"
  # `filter` is printed because the lane name is not a statement of coverage.
  # `medium` used to run fewer tests than `fast`, and nothing in the output
  # said so — the reader had to know the case statement to tell.
  printf \
    'ArkDeck test lane: %s; exitCode=%s; testCount=%s; durationSeconds=%s; maximumResidentSetBytes=%s; peakMemoryFootprintBytes=%s; slowTest=%s; filter=%s\n' \
    "$label" "$status" "${test_count:-unavailable}" "$((finished - started))" \
    "${maximum_resident_set:-unavailable}" "${peak_memory_footprint:-unavailable}" "$label" \
    "${lane_filter:-<whole suite>}"
  return "$status"
}

case "$lane" in
  fast)
    lane_filter='ArkDeckCoreTests'
    run_lane fast "$swiftpm" test --parallel --num-workers "$workers" \
      --filter "$lane_filter"
    ;;
  medium)
    # A superset of `fast`: the shared Core values plus the App's client.
    lane_filter='ArkDeckCoreTests|ArkDeckClientKitTests'
    run_lane medium "$swiftpm" test --parallel --num-workers "$workers" \
      --filter "$lane_filter"
    ;;
  focus)
    [ "$#" -eq 2 ] || {
      echo "usage: sh Packages/ArkDeckKit/Scripts/run-test-lane.sh focus <test-filter>" >&2
      exit 64
    }
    lane_filter=$2
    run_lane focus "$swiftpm" test --parallel --num-workers "$workers" --filter "$lane_filter"
    ;;
  full)
    # Wall-clock growth ratios are meaningful only when their two samples are
    # not competing with unrelated subprocess-heavy tests. Keep the merge gate
    # complete, but run its microbenchmarks serially after the parallel suite.
    lane_filter='<whole suite except serialized timing tests>'
    run_lane full-parallel "$swiftpm" test --parallel --num-workers "$workers" \
      --skip ViewerScalePerformanceTests
    lane_filter='ViewerScalePerformanceTests'
    run_lane full-viewer-scale "$swiftpm" test --filter "$lane_filter"
    ;;
  *)
    echo "usage: sh Packages/ArkDeckKit/Scripts/run-test-lane.sh {fast|medium|full|focus <test-filter>}" >&2
    exit 64
    ;;
esac
