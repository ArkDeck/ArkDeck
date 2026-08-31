#!/bin/sh
# Build ArkDeck through one stable, cache-owned source path.
#
# Xcode and Swift key incremental state by absolute source paths and file
# identity. A cache per physical worktree makes every new Codex worktree pay a
# cold build. This runner checksum-syncs Git-visible files into one stable
# mirror, then serializes the mirror update and build that share its caches.

set -eu

lock_held=0
if [ "${1:-}" = '--arkdeck-internal-lock-held' ]; then
  lock_held=1
  shift
fi

usage() {
  cat <<'EOF'
usage: sh scripts/ci/run-xcodebuild.sh [--release]

Default: unsigned Debug build-for-testing (does not execute tests).
--release: signed Release app build using the project's signing settings.

Default cache root:
  ~/Library/Caches/com.arkdeck.ArkDeck/Xcode/Shared

Environment overrides:
  ARKDECK_XCODE_CACHE_ROOT       Absolute cache root owned by this runner.
  ARKDECK_XCODEBUILD_EXECUTABLE  Absolute xcodebuild executable path.
  ARKDECK_XCODE_JOBS            Optional build task limit (1–64).

The runner owns the project, scheme, arm64 architecture, destination,
DerivedData, package caches, module cache, and build action. Both configurations
reuse the same stable source mirror; Xcode separates their build products.
The source mirror contains tracked
and non-ignored untracked files; ignored files stay local.
EOF
}

fail() {
  printf 'run-xcodebuild: ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

configuration=Debug
case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
  --release)
    configuration=Release
    shift
    ;;
  '') ;;
  *)
    fail "unexpected argument '$1'" 64
    ;;
esac
[ "$#" -eq 0 ] || fail "unexpected argument '$1'" 64

build_jobs=${ARKDECK_XCODE_JOBS:-}
if [ -n "$build_jobs" ]; then
  case $build_jobs in
    *[!0-9]*|0|0*) fail 'ARKDECK_XCODE_JOBS must be an integer from 1 to 64' 64 ;;
  esac
  [ "${#build_jobs}" -le 2 ] && [ "$build_jobs" -le 64 ] ||
    fail 'ARKDECK_XCODE_JOBS must be an integer from 1 to 64' 64
fi

script_dir=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
script_path=$script_dir/$(basename -- "$0")
repo_root=$(CDPATH= cd -P -- "$script_dir/../.." && pwd)

if [ -n "${ARKDECK_XCODE_CACHE_ROOT:-}" ]; then
  cache_root=$ARKDECK_XCODE_CACHE_ROOT
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  cache_root=$XDG_CACHE_HOME/com.arkdeck.ArkDeck/Xcode/Shared
elif [ -n "${HOME:-}" ]; then
  cache_root=$HOME/Library/Caches/com.arkdeck.ArkDeck/Xcode/Shared
else
  fail 'HOME and XDG_CACHE_HOME are unset; set ARKDECK_XCODE_CACHE_ROOT' 78
fi

case $cache_root in
  /*) ;;
  *) fail "cache root must be absolute: $cache_root" 64 ;;
esac
case $cache_root/ in
  "$repo_root"/*) fail "cache root must be outside the worktree: $cache_root" 64 ;;
esac

xcodebuild_executable=${ARKDECK_XCODEBUILD_EXECUTABLE:-$(command -v xcodebuild || true)}
[ -n "$xcodebuild_executable" ] || fail 'xcodebuild executable not found' 69
case $xcodebuild_executable in
  /*) ;;
  *) fail "xcodebuild executable must be absolute: $xcodebuild_executable" 64 ;;
esac
[ -x "$xcodebuild_executable" ] || fail "xcodebuild executable is not executable: $xcodebuild_executable" 69

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
derived_data=$cache_root/DerivedData
source_packages=$cache_root/SourcePackages
package_cache=$cache_root/PackageCache
module_cache=$cache_root/ModuleCache
lock_path=$cache_root/build.lock
ignored_paths=$cache_root/ignored-paths
mkdir -p "$derived_data" "$source_packages" "$package_cache" "$module_cache"

if [ "$lock_held" -eq 0 ]; then
  if [ "$configuration" = Release ]; then
    set -- --release
  fi
  exec /usr/bin/lockf -k "$lock_path" \
    /bin/sh "$script_path" --arkdeck-internal-lock-held "$@"
fi

if [ -L "$workspace_path" ]; then
  rm "$workspace_path"
elif [ -e "$workspace_path" ] && [ ! -d "$workspace_path" ]; then
  fail "cache workspace exists and is not a directory: $workspace_path" 73
fi
mkdir -p "$workspace_path"

# --checksum + --no-times preserves the stable mirror's inode and mtime when a
# different physical worktree has identical bytes. Only real content changes
# invalidate Xcode's incremental graph. Git-ignored products are excluded and
# deleted from the mirror so local build state cannot leak into the build.
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

printf 'ArkDeck Xcode cache: %s\n' "$cache_root" >&2
printf 'ArkDeck Xcode worktree: %s\n' "$repo_root" >&2

# Package targets have their own projects: the App's ARCHS does not constrain
# their Release defaults. Pass arm64 at invocation scope so dependencies cannot
# silently build an unused Intel slice. Do not override Release signing here:
# the App and SwiftPM resource bundles intentionally have different settings.
if [ "$configuration" = Release ]; then
  set -- -onlyUsePackageVersionsFromResolvedFile build
else
  set -- CODE_SIGNING_ALLOWED=NO \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    SWIFT_COMPILATION_MODE=singlefile \
    build-for-testing
fi
if [ -n "$build_jobs" ]; then
  set -- -jobs "$build_jobs" "$@"
fi

exec env \
  CLANG_MODULE_CACHE_PATH="$module_cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
  "$xcodebuild_executable" \
  -project "$workspace_path/ArkDeck.xcodeproj" \
  -scheme ArkDeck \
  -configuration "$configuration" \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -packageCachePath "$package_cache" \
  -showBuildTimingSummary \
  -hideShellScriptEnvironment \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES \
  "$@"
