#!/bin/sh
# Exercise the native adapter using the SDK already admitted by the App build.
set -eu
script_dir=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -P -- "$script_dir/../.." && pwd)
if [ -n "${ARKDECK_XCODE_CACHE_ROOT:-}" ]; then
  cache_root=$ARKDECK_XCODE_CACHE_ROOT
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  cache_root=$XDG_CACHE_HOME/com.arkdeck.ArkDeck/Xcode/Shared
else
  cache_root=$HOME/Library/Caches/com.arkdeck.ArkDeck/Xcode/Shared
fi
ARKTRACE_RUST_XCFRAMEWORK=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["source"]+"/"+r["relativeSDK"])' "$cache_root/native-trace-preparation.json")
export ARKTRACE_RUST_XCFRAMEWORK
exec sh "$repo_root/apple/Packages/ArkDeckKit/Scripts/run-swiftpm.sh" test \
  --filter 'ArkDeckTraceNativeRuntimeTests|ArkDeckTraceBootstrapTests|ArkDeckTraceConfigurationTests'
