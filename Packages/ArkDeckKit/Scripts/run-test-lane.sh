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
  started=$(date +%s)
  /usr/bin/time -l "$@"
  finished=$(date +%s)
  printf 'ArkDeck test lane: %s; durationSeconds=%s\n' "$label" "$((finished - started))"
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
