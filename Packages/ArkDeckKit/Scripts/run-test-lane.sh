#!/bin/sh
# macOS Runtime test lanes.  The full suite remains the merge gate; this
# runner gives local development and future CI explicit fast/medium/slow
# feedback without hiding a slow durability check behind a larger timeout.

set -eu

lane=${1:-}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
package="$root/Packages/ArkDeckKit"

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
  test_count=$(sed -n -E \
    -e 's/.*Executed ([0-9]+) tests?.*/\1/p' \
    -e 's/.*Test run with ([0-9]+) tests?.*/\1/p' \
    "$log" | awk '$1 > 0 { count = $1 } END { if (count != "") print count }')
  maximum_resident_set=$(sed -n -E \
    's/^[[:space:]]*([0-9]+)  maximum resident set size$/\1/p' "$log" | tail -n 1)
  peak_memory_footprint=$(sed -n -E \
    's/^[[:space:]]*([0-9]+)  peak memory footprint$/\1/p' "$log" | tail -n 1)
  rm -f "$log"
  printf \
    'ArkDeck test lane: %s; exitCode=%s; testCount=%s; durationSeconds=%s; maximumResidentSetBytes=%s; peakMemoryFootprintBytes=%s; slowTest=%s\n' \
    "$label" "$status" "${test_count:-unavailable}" "$((finished - started))" \
    "${maximum_resident_set:-unavailable}" "${peak_memory_footprint:-unavailable}" "$label"
  return "$status"
}

case "$lane" in
  fast)
    run_lane fast swift test --package-path "$package" --filter ArkDeckCoreTests
    ;;
  medium)
    run_lane medium-runtime swift test --package-path "$package" --filter RuntimeJobEngineContractTests
    run_lane medium-daemon swift test --package-path "$package" --filter AgentDaemonContractTests
    ;;
  slow)
    ARKDECK_RUN_SLOW_ARTIFACT_TESTS=1 \
      run_lane slow-artifact swift test --package-path "$package" \
      --filter RuntimeArtifactContractTests/testLargeTextFilePublicationStreamsRedactionAcrossReadBoundaries
    ARKDECK_RUN_LONG_RUNTIME_TESTS=1 \
      run_lane slow-runtime swift test --package-path "$package" \
      --filter RuntimeJobEngineContractTests/testLongRunSimulationKeepsTerminalHistoryOutOfRecoveryMemory
    ARKDECK_RUN_TEN_THOUSAND_HISTORY_TESTS=1 \
      run_lane slow-history swift test --package-path "$package" \
      --filter RuntimeJobEngineContractTests/testTenThousandTerminalHistoryDoesNotExpandRestartRecovery
    ARKDECK_RUN_LONG_JOURNAL_TESTS=1 \
      run_lane slow-journal swift test --package-path "$package" \
      --filter JournalRecoveryContractTests/testIncrementalJournalCursorScalesPastTenThousandDurableEvents
    ;;
  full)
    run_lane full swift test --package-path "$package" --parallel --num-workers 8
    ;;
  *)
    echo "usage: sh Packages/ArkDeckKit/Scripts/run-test-lane.sh {fast|medium|slow|full}" >&2
    exit 64
    ;;
esac
