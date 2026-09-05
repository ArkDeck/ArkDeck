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
# leftover runner processes from that same DerivedData, which otherwise make
# the next launch time out "while enabling automation mode". Only that
# DerivedData: a live runner under another path is another session's run in
# progress, not a leftover.
#
# That timeout can still happen on the first run against a DerivedData path the
# system has not seen before: automation has to be granted to a runner nobody
# has answered a prompt for yet. Running the same command again succeeds. If it
# persists across a reboot, `pkill -f testmanagerd` resets the daemon that
# brokers automation mode; launchd restarts it on demand.
#
# Keyboard isolation must start before xcodebuild launches testmanagerd. The
# host helper selects an enabled plain layout and temporarily turns off
# per-document input-source switching, then restores the user's settings after
# xcodebuild exits. A test-class setUp is too late to protect automation startup.

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

Test runs temporarily use an enabled U.S./ABC (or other ASCII keyboard) layout
and turn off automatic switching to a document's input source. The wrapper
restores the previous settings when the run ends or is interrupted; an input
source that is no longer enabled is not re-enabled. `--build-once` does not
change input settings. Use this entry point for every suite, including a
single case; direct Xcode runs do not have the host-level protection.

Default DerivedData:
  ~/Library/Caches/com.arkdeck.ArkDeck/Xcode/UITests

Environment overrides:
  ARKDECK_UI_TEST_DERIVED_DATA   Absolute DerivedData path for this runner.
  ARKDECK_XCODEBUILD_EXECUTABLE  Absolute xcodebuild executable path.

These tests drive the real App: they open windows and take over the keyboard
while they run. They are not part of any merge gate. The UI stack is
host-global, so concurrent sessions must take turns; give each worktree its
own ARKDECK_UI_TEST_DERIVED_DATA so cleanup and build state stay separate.
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

# Architecture is owned by the runner, just like the app/Release build entry.
# Validate before creating DerivedData or cleaning up any previous UI runner.
for argument in "$@"; do
  case $argument in
    ARCHS=*|ONLY_ACTIVE_ARCH=*|-arch|-arch=*)
      fail "architecture is managed by this runner: $argument" 64
      ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  fail 'not inside a Git checkout'
[ -d "$repo_root/ArkDeck.xcodeproj" ] ||
  fail "no ArkDeck.xcodeproj under $repo_root"

# Own the host keyboard before any cleanup, including when another invocation
# uses this same DerivedData. The helper serializes test runs and re-enters
# here with the flag set; its child ultimately execs xcodebuild below.
if [ "$action" != build-for-testing ] &&
   [ "${ARKDECK_UI_TEST_INPUT_SOURCE_GUARDED:-}" != 1 ]; then
  if [ "$action" = test-without-building ]; then
    set -- --no-build "$@"
  fi
  exec python3 "$repo_root/scripts/ci/ui_test_input_source.py" \
    /bin/sh "$repo_root/scripts/ci/run-ui-tests.sh" "$@"
fi

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
# the next launch time out. Neither is a service; killing them loses nothing —
# when they are ours. Killing by bare process name was how one session's
# invocation tore down another session's run mid-flight on the same host
# ("Test crashed with signal term while preparing to run tests" on the
# victim's side), so the sweep is scoped to this DerivedData: what another
# session has in the air is its run, not our leftover. The path is escaped
# so pkill's regex reads it literally.
derived_data_pattern=$(printf '%s' "$derived_data" | sed 's/[][\.*^$+?(){}|]/\\&/g')
pkill -f "$derived_data_pattern/Build/Products/Debug/ArkDeckHDCUITests-Runner\.app" 2>/dev/null || true
pkill -f "$derived_data_pattern/Build/Products/Debug/ArkDeck\.app/Contents/MacOS/ArkDeck" 2>/dev/null || true

# Scoping the sweep does not make concurrent runs work: the UI stack is
# host-global (one testmanagerd, one foreground), and a second run times out
# enabling automation mode for both sides. A runner still alive after our own
# sweep is almost certainly another session mid-run — say so up front. A
# stale foreign runner looks the same from here, which is why this warns
# instead of failing.
foreign_runner=$(pgrep -f 'ArkDeckHDCUITests-Runner\.app/Contents/MacOS/ArkDeckHDCUITests-Runner' | head -1 || true)
if [ -n "$foreign_runner" ]; then
  printf 'run-ui-tests: WARNING: a runner outside this DerivedData is alive (pid %s) — another session is likely mid-run. The UI stack is host-global; coordinate a window or expect "Timed out while enabling automation mode" on both sides.\n' \
    "$foreign_runner" >&2
fi

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

set -- "$xcodebuild_executable" \
  -project "$repo_root/ArkDeck.xcodeproj" \
  -scheme ArkDeck \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  "$@" \
  "$action"

exec "$@"
