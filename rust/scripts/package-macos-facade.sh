#!/bin/bash
# Build and sign the transport helper before the enclosing Swift bundle is signed.
# A same-release standalone Swift bundle is retained as the rollback installation.
set -euo pipefail
[ "$#" = 5 ] || exit 64
mode="$1"
daemon_bundle="$2"
rollback_bundle="$3"
identity="$4"
entitlements="$5"
case "$mode" in debug|release) ;; *) exit 64 ;; esac
rust_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$mode" = release ]; then
  (cd "$rust_root" && cargo build --locked --release -p arkdeck-agentd)
else
  (cd "$rust_root" && cargo build --locked -p arkdeck-agentd)
fi
mkdir -p "$(dirname "$rollback_bundle")"
cp -R "$daemon_bundle" "$rollback_bundle"
stamp=--timestamp
if [ "$mode" = debug ]; then stamp=--timestamp=none; fi
codesign --force --sign "$identity" --options runtime "$stamp" \
  --entitlements "$entitlements" "$rollback_bundle"
cp "$rust_root/target/$mode/arkdeck-agentd" "$daemon_bundle/Contents/MacOS/arkdeck-facade"
chmod 700 "$daemon_bundle/Contents/MacOS/arkdeck-facade"
codesign --force --sign "$identity" --identifier com.arkdeck.agentd.facade \
  --options runtime "$stamp" "$daemon_bundle/Contents/MacOS/arkdeck-facade"
