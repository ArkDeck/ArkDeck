#!/bin/bash
# Lays out and signs the helper pair whose main programs are the Rust CLI and
# daemon (CHG-2026-074 M5, G5 slice 20a), and keeps the Swift helper it
# replaces beside it for one cycle. Its two callers own everything around it:
# build-helpers.sh with ARKDECK_HELPER_RUNTIME=rust is the release (validated
# provisioning profiles, Developer ID with a secure timestamp, notarization,
# stapling and Gatekeeper assessment), and build-unsigned-rust-helpers.sh is a
# structure check signed ad hoc that is never distributed. This script builds
# nothing, validates no profile and notarizes nothing.
#
# The layout is the Swift helpers' less what only Swift reads:
#   ArkDeckCLI.app/Contents/{Info.plist,embedded.provisionprofile,MacOS/arkdeck}
#   ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app/Contents/{Info.plist,
#     embedded.provisionprofile,MacOS/arkdeck-agentd,Resources/...}
# The Rust CLI renders the LaunchAgent plist in code and carries the Catalog
# in its binary, so it needs no SwiftPM resource bundle. The Rust daemon needs
# one resource: the OpenHarmony code-sign helper, which it looks for where
# Swift's resource bundle puts it (rust/crates/arkdeck-agentd/src/
# code_sign_helper.rs). A Rust daemon bundle carries no facade: the Rust
# CLI's `runtime service update` refuses one that does.
#
# Usage: package-rust-helpers.sh <binaries> <staging> <cli-profile>
#          <daemon-profile> <identity> <--timestamp|--timestamp=none>
#          <rollback-helper|none>
set -euo pipefail
if [[ "$#" != 7 ]]; then
  echo "usage: package-rust-helpers.sh <binaries> <staging> <cli-profile> <daemon-profile>" \
    "<identity> <--timestamp|--timestamp=none> <rollback-helper|none>" >&2
  exit 64
fi
binaries="$1"
staging_root="$2"
cli_profile="$3"
daemon_profile="$4"
identity="$5"
timestamp="$6"
rollback_helper="$7"
case "$timestamp" in --timestamp | --timestamp=none) ;; *) exit 64 ;; esac
if [[ -z "$identity" || ("$identity" == - && "$timestamp" != --timestamp=none) ]]; then
  echo "an ad hoc signature carries no secure timestamp; a signing identity must be named" >&2
  exit 64
fi

distribution_root="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$distribution_root/../.." && pwd)"
team_identifier="8AQTYW5FKR"
code_sign_helper="$package_root/Sources/ArkDeckWorkflows/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable"
# The production requirement the Rust CLI's helper validator and the App's XPC
# peer check hold the daemon to; an ad hoc signature can only be held to the
# identifier.
if [[ "$identity" == - ]]; then
  anchor=""
else
  anchor="anchor apple generic and certificate leaf[subject.OU] = \"$team_identifier\" and "
fi

for executable in arkdeck arkdeck-agentd; do
  if [[ ! -f "$binaries/$executable" || -L "$binaries/$executable" || ! -x "$binaries/$executable" ]]; then
    echo "$binaries/$executable must be an executable regular file" >&2
    exit 66
  fi
  # Host helpers ship for Apple silicon only, as the Swift helpers do.
  if [[ "$(lipo -archs "$binaries/$executable")" != arm64 ]]; then
    echo "$executable must be a thin arm64 executable" >&2
    exit 65
  fi
done
for input in "$cli_profile" "$daemon_profile" "$code_sign_helper"; do
  if [[ ! -f "$input" || -L "$input" ]]; then
    echo "$input must be a regular file" >&2
    exit 66
  fi
done
if [[ ! -d "$staging_root" || -L "$staging_root" || -e "$staging_root/ArkDeckCLI.app" \
  || -e "$staging_root/rollback" ]]; then
  echo "the staging root must be an existing directory that holds no helper yet" >&2
  exit 73
fi

# The helper retained for rollback is the one the current release installs:
# the Swift daemon behind its Rust facade. Nothing about it is rebuilt or
# re-signed here; it is checked, then copied as it is.
if [[ "$rollback_helper" != none ]]; then
  if [[ "$rollback_helper" != /*.app || ! -d "$rollback_helper" || -L "$rollback_helper" ]]; then
    echo "the rollback helper must be an ArkDeckAgent.app bundle at an absolute physical path" >&2
    exit 66
  fi
  rollback_info="$rollback_helper/Contents/Info.plist"
  if [[ "$(plutil -extract CFBundleIdentifier raw -o - "$rollback_info" 2>/dev/null)" != com.arkdeck.agentd \
    || "$(plutil -extract CFBundleExecutable raw -o - "$rollback_info" 2>/dev/null)" != arkdeck-agentd ]]; then
    echo "the rollback helper is not an ArkDeck daemon bundle" >&2
    exit 65
  fi
  if [[ ! -x "$rollback_helper/Contents/MacOS/arkdeck-agentd" \
    || ! -x "$rollback_helper/Contents/MacOS/arkdeck-facade" ]]; then
    echo "the rollback helper must be the current Swift daemon behind its facade" >&2
    exit 65
  fi
  codesign --verify --strict --deep -R "=${anchor}identifier \"com.arkdeck.agentd\"" \
    "$rollback_helper"
  codesign --verify --strict -R "=${anchor}identifier \"com.arkdeck.agentd.facade\"" \
    "$rollback_helper/Contents/MacOS/arkdeck-facade"
fi

cli_bundle="$staging_root/ArkDeckCLI.app"
daemon_bundle="$cli_bundle/Contents/Helpers/ArkDeckAgent.app"
helper_resources="$daemon_bundle/Contents/Resources/ArkDeckKit_ArkDeckWorkflows.bundle/OpenHarmonyNativeCodeSign"
mkdir -p "$cli_bundle/Contents/MacOS" "$daemon_bundle/Contents/MacOS" "$helper_resources"
cp "$distribution_root/ArkDeckCLI-Info.plist" "$cli_bundle/Contents/Info.plist"
cp "$distribution_root/ArkDeckAgent-Info.plist" "$daemon_bundle/Contents/Info.plist"
cp "$cli_profile" "$cli_bundle/Contents/embedded.provisionprofile"
cp "$daemon_profile" "$daemon_bundle/Contents/embedded.provisionprofile"
cp "$binaries/arkdeck" "$cli_bundle/Contents/MacOS/arkdeck"
cp "$binaries/arkdeck-agentd" "$daemon_bundle/Contents/MacOS/arkdeck-agentd"
cp "$code_sign_helper" "$helper_resources/arkdeck-code-sign-enable"
chmod 700 "$cli_bundle/Contents/MacOS/arkdeck" "$daemon_bundle/Contents/MacOS/arkdeck-agentd"

# Nested code first. Each bundle's identifier is its Info.plist's
# CFBundleIdentifier, and its entitlements the ones the Swift helper of the
# same identity carries: the daemon reads the OpenHarmony signing envelope from
# the Data Protection Keychain under the shared access group, and the helper
# validator requires both entitlements.
codesign --force --sign "$identity" --options runtime "$timestamp" \
  --entitlements "$distribution_root/ArkDeckAgent.entitlements" "$daemon_bundle"
codesign --force --sign "$identity" --options runtime "$timestamp" \
  --entitlements "$distribution_root/ArkDeckCLI.entitlements" "$cli_bundle"
codesign --verify --strict --deep --verbose=2 "$cli_bundle"
codesign --verify --strict -R "=${anchor}identifier \"com.arkdeck.agentd\"" "$daemon_bundle"
codesign --verify --strict -R "=${anchor}identifier \"com.arkdeck.cli\"" "$cli_bundle"

if [[ "$rollback_helper" != none ]]; then
  mkdir "$staging_root/rollback"
  ditto "$rollback_helper" "$staging_root/rollback/ArkDeckAgent.app"
  codesign --verify --strict --deep -R "=${anchor}identifier \"com.arkdeck.agentd\"" \
    "$staging_root/rollback/ArkDeckAgent.app"
fi
