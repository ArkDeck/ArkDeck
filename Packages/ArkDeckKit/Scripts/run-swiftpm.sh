#!/bin/sh
# Run ArkDeckKit SwiftPM commands through one stable, user-level build path.
#
# SwiftPM keys parts of its build graph by source path and file identity.
# Pointing multiple physical worktrees at one scratch directory can therefore
# leave the graph watching the wrong checkout. This runner checksum-syncs Git-
# visible source into a stable cache-owned mirror, then serializes the mirror
# update plus the whole build/test invocation.

set -eu

lock_held=0
if [ "${1:-}" = '--arkdeck-internal-lock-held' ]; then
  lock_held=1
  shift
fi

usage() {
  cat <<'EOF'
usage: sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh {build|test} [swiftpm options]

Default cache root:
  ~/Library/Caches/com.arkdeck.ArkDeck/SwiftPM/ArkDeckKit

Environment overrides:
  ARKDECK_SWIFTPM_CACHE_ROOT  Absolute cache root owned by this runner.
  ARKDECK_SWIFT_EXECUTABLE    Absolute Swift executable path.

The runner builds only arm64 and owns --arch and --triple; callers cannot
override the architecture. It also owns --package-path, --scratch-path, and
--cache-path so every worktree sees the same logical source and build paths.
The source mirror contains tracked and non-ignored untracked files; ignored
files stay local.
The cache root is the only build state this runner creates, and it persists
on purpose: every worktree on the machine shares it, and deleting it costs a
cold build of the whole package. Point ARKDECK_SWIFTPM_CACHE_ROOT elsewhere
only for isolation you will delete afterwards; a root left in a scratch
directory nobody cleans is a stranded copy of the whole build. Running swift
build or swift test --package-path directly in a worktree bypasses this
runner and leaves a private .build of one to two gigabytes in that worktree.
Every target treats Swift's DeprecatedDeclaration diagnostic group as an
error so local and CI test runs enforce the current SDK surface.
EOF
}

fail() {
  printf 'run-swiftpm: ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
  build|test)
    swift_command=$1
    shift
    ;;
  '')
    usage >&2
    exit 64
    ;;
  *)
    fail "unsupported command '$1' (expected build or test)" 64
    ;;
esac

for argument in "$@"; do
  case $argument in
    --package-path|--package-path=*|--scratch-path|--scratch-path=*|--cache-path|--cache-path=*|--arch|--arch=*|--triple|--triple=*)
      fail "'$argument' is managed by this runner" 64
      ;;
  esac
done

script_dir=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
script_path=$script_dir/$(basename -- "$0")
repo_root=$(CDPATH= cd -P -- "$script_dir/../../.." && pwd)

if [ -n "${ARKDECK_SWIFTPM_CACHE_ROOT:-}" ]; then
  cache_root=$ARKDECK_SWIFTPM_CACHE_ROOT
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  cache_root=$XDG_CACHE_HOME/com.arkdeck.ArkDeck/SwiftPM/ArkDeckKit
elif [ -n "${HOME:-}" ]; then
  cache_root=$HOME/Library/Caches/com.arkdeck.ArkDeck/SwiftPM/ArkDeckKit
else
  fail 'HOME and XDG_CACHE_HOME are unset; set ARKDECK_SWIFTPM_CACHE_ROOT' 78
fi

case $cache_root in
  /*) ;;
  *) fail "cache root must be absolute: $cache_root" 64 ;;
esac
case $cache_root/ in
  "$repo_root"/*) fail "cache root must be outside the worktree: $cache_root" 64 ;;
esac

swift_executable=${ARKDECK_SWIFT_EXECUTABLE:-$(command -v swift || true)}
[ -n "$swift_executable" ] || fail 'swift executable not found' 69
case $swift_executable in
  /*) ;;
  *) fail "Swift executable must be absolute: $swift_executable" 64 ;;
esac
[ -x "$swift_executable" ] || fail "Swift executable is not executable: $swift_executable" 69

umask 077
cache_root_created=0
if [ ! -d "$cache_root" ]; then
  mkdir -p "$cache_root"
  cache_root_created=1
fi
cache_root=$(CDPATH= cd -P -- "$cache_root" && pwd)

case $cache_root/ in
  "$repo_root"/*)
    if [ "$cache_root_created" -eq 1 ]; then
      rmdir "$cache_root" 2>/dev/null || true
    fi
    fail "cache root must be outside the worktree: $cache_root" 64
    ;;
esac

workspace_path=$cache_root/workspace
scratch_path=$cache_root/build
dependency_cache=$cache_root/dependencies
lock_path=$cache_root/build.lock
ignored_paths=$cache_root/ignored-paths
mkdir -p "$scratch_path" "$dependency_cache"

if [ "$lock_held" -eq 0 ]; then
  exec /usr/bin/lockf -k "$lock_path" \
    /bin/sh "$script_path" --arkdeck-internal-lock-held "$swift_command" "$@"
fi

if [ -L "$workspace_path" ]; then
  # Migrate the original symlink-based cache layout. A real mirror is required
  # because llbuild also notices inode changes across physical worktrees.
  rm "$workspace_path"
elif [ -e "$workspace_path" ] && [ ! -d "$workspace_path" ]; then
  fail "cache workspace exists and is not a directory: $workspace_path" 73
fi
mkdir -p "$workspace_path"

# Keep the mirror small and private: Git-ignored build products and local-only
# files are neither copied nor retained. --checksum + --no-times means a fresh
# worktree with identical bytes leaves the mirror's inode and mtime untouched,
# while real edits, additions, and deletions update the mirror before SwiftPM.
# Git prints repo-relative paths; the leading slash anchors each rsync pattern
# to the transfer root. Without it a single-segment ignored name (say a
# root-only `/cache-dir/` in .gitignore) matches at every depth, excluding and
# then deleting an identically named tracked directory inside the mirror.
git -C "$repo_root" ls-files --others --ignored --exclude-standard --directory -z \
  > "$ignored_paths"
if [ -s "$ignored_paths" ]; then
  /usr/bin/xargs -0 /usr/bin/printf '/%s\0' < "$ignored_paths" \
    > "$ignored_paths.anchored"
  mv -f "$ignored_paths.anchored" "$ignored_paths"
fi
/usr/bin/rsync -ac --no-times --delete --delete-excluded --from0 \
  --exclude=.git --exclude-from="$ignored_paths" \
  "$repo_root/" "$workspace_path/"

stable_package=$workspace_path/Packages/ArkDeckKit
# Some contract fixtures deliberately resolve executables through
# #filePath -> PackageRoot/.build/debug. Keep that compatibility path while
# the real scratch directory remains outside every source worktree.
ln -sfn "$scratch_path" "$stable_package/.build"

# The API-baseline gate compiles an out-of-package consumer with its own
# SwiftPM scratch. Inside the mirror that scratch is a Git-ignored name, so
# the next sync's --delete-excluded would erase it and the gate would
# cold-build its entire dependency graph — the whole package again, through
# the path dependency — on every run. Give it the package's own treatment:
# a stable scratch outside every worktree, recreated after each sync.
api_baseline=$stable_package/APIBaseline
if [ -d "$api_baseline" ]; then
  mkdir -p "$cache_root/api-baseline-build"
  ln -sfn "$cache_root/api-baseline-build" "$api_baseline/.build"
  # Cache effectiveness is observable, not assumed: a warm gate resolves to
  # a populated stable scratch, while ~0MB here means the previous run's
  # products never reached the cache and the gate cold-builds again.
  printf 'ArkDeck API-baseline scratch: %s (%sMB)\n' \
    "$(readlink "$api_baseline/.build")" \
    "$(du -sm "$cache_root/api-baseline-build" | cut -f1)" >&2
fi

# lockf owns the lock while this inner runner and SwiftPM execute. Keeping the
# lock descriptor out of the test process prevents a detached child from
# accidentally retaining the cache lock after SwiftPM exits.
printf 'ArkDeck SwiftPM cache: %s\n' "$cache_root" >&2
printf 'ArkDeck SwiftPM worktree: %s\n' "$repo_root" >&2

exec "$swift_executable" "$swift_command" \
  --arch arm64 \
  --package-path "$stable_package" \
  --scratch-path "$scratch_path" \
  --cache-path "$dependency_cache" \
  -Xswiftc -Werror \
  -Xswiftc DeprecatedDeclaration \
  "$@"
