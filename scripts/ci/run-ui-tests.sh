#!/bin/sh
# Run the App's XCUITest target locally.
#
# CI only builds this target (`build-for-testing`), so nothing executes these
# tests unless a person does. Running them by hand fails in two ways that look
# like a broken machine and are not:
#
#   1. An unsigned UI-test runner is killed on launch. arm64 refuses to execute
#      a bundle without at least an ad-hoc signature, and xcodebuild reports it
#      as "Test crashed with signal kill before establishing connection" or
#      "The test runner hung before establishing connection" — never as a
#      signing problem. The CI lane's CODE_SIGNING_ALLOWED=NO is correct for
#      building and wrong for running, so this runner signs ad hoc instead.
#
#   2. A runner binary that has already executed cannot be relinked in place.
#      The next run dies in `ld` with "can't write output file", pointing at a
#      path that exists and is writable. Removing the runner bundle first is
#      the fix; cleaning all of DerivedData is not needed.
#
# It also uses its own DerivedData so a UI run and the build lanes in
# `run-xcodebuild.sh` do not fight over one Products directory, and it clears
# leftover runner processes, which otherwise make the next launch time out
# "while enabling automation mode".
#
# That timeout can still happen on the first run against a DerivedData path the
# system has not seen before: automation has to be granted to a runner nobody
# has answered a prompt for yet. Running the same command again succeeds. If it
# persists across a reboot, `pkill -f testmanagerd` resets the daemon that
# brokers automation mode; launchd restarts it on demand.

set -eu

usage() {
  cat <<'EOF'
usage: sh scripts/ci/run-ui-tests.sh [--build-once | --no-build] [xcodebuild arguments...]

Runs the ArkDeckHDCUITests target against the App. Extra arguments are passed
to xcodebuild, so a single suite or case is selected the usual way:

  sh scripts/ci/run-ui-tests.sh \
    -only-testing:ArkDeckHDCUITests/OverviewRecordUITests

Iteration mode. `test` pays a full build check and a runner relink on every
invocation. When only test selection changes between runs, build once and
then run without building:

  sh scripts/ci/run-ui-tests.sh --build-once      # build-for-testing only
  sh scripts/ci/run-ui-tests.sh --no-build ...    # test-without-building

`--no-build` also skips the stale-runner removal: nothing relinks, so the
"can't write output file" failure that removal works around cannot happen.

Default DerivedData:
  ~/Library/Caches/com.arkdeck.ArkDeck/Xcode/UITests

Environment overrides:
  ARKDECK_UI_TEST_DERIVED_DATA   Absolute DerivedData path for this runner.
  ARKDECK_XCODEBUILD_EXECUTABLE  Absolute xcodebuild executable path.

These tests drive the real App: they open windows and take over the keyboard
while they run. They are not part of any merge gate.
EOF
}

fail() {
  printf 'run-ui-tests: ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

action=test
case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
  --build-once)
    action=build-for-testing
    shift
    ;;
  --no-build)
    action=test-without-building
    shift
    ;;
esac

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  fail 'not inside a Git checkout'
[ -d "$repo_root/ArkDeck.xcodeproj" ] ||
  fail "no ArkDeck.xcodeproj under $repo_root"

xcodebuild_executable=${ARKDECK_XCODEBUILD_EXECUTABLE:-}
if [ -z "$xcodebuild_executable" ]; then
  xcodebuild_executable=$(command -v xcodebuild) || fail 'xcodebuild is not on PATH'
fi

derived_data=${ARKDECK_UI_TEST_DERIVED_DATA:-"$HOME/Library/Caches/com.arkdeck.ArkDeck/Xcode/UITests"}
case $derived_data in
  /*) ;;
  *) fail 'ARKDECK_UI_TEST_DERIVED_DATA must be an absolute path' ;;
esac
mkdir -p "$derived_data" || fail "cannot create DerivedData at $derived_data"

# A runner or App left behind by an interrupted run holds automation and makes
# the next launch time out. Neither is a service; killing them loses nothing.
pkill -f 'ArkDeckHDCUITests-Runner' 2>/dev/null || true
pkill -f 'ArkDeck.app/Contents/MacOS/ArkDeck' 2>/dev/null || true

# A runner binary that has already executed cannot be relinked in place, so
# remove it before any action that builds. test-without-building never links,
# which is exactly why the removal must not run there: it would delete the
# products this mode exists to reuse.
if [ "$action" != test-without-building ]; then
  runner_bundle="$derived_data/Build/Products/Debug/ArkDeckHDCUITests-Runner.app"
  if [ -e "$runner_bundle" ]; then
    rm -rf "$runner_bundle" || fail "cannot remove the stale runner at $runner_bundle"
  fi
fi

# xcodebuild unions every -only-testing it is given, so the whole-target
# default is added only when the caller narrowed nothing. Adding both would
# quietly widen a request for one case back to the entire suite.
selection_given=0
for argument in "$@"; do
  case $argument in
    -only-testing*) selection_given=1 ;;
  esac
done
if [ "$selection_given" -eq 0 ] && [ "$action" != build-for-testing ]; then
  set -- "$@" -only-testing:ArkDeckHDCUITests
fi

printf 'ArkDeck UI tests: DerivedData %s\n' "$derived_data" >&2
printf 'ArkDeck UI tests: these drive the real App and are not a merge gate\n' >&2

exec "$xcodebuild_executable" \
  -project "$repo_root/ArkDeck.xcodeproj" \
  -scheme ArkDeck \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath "$derived_data" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  "$@" \
  "$action"
