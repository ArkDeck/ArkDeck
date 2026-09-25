#!/bin/bash
set -euo pipefail

distribution_root="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$distribution_root/../.." && pwd)"
output_root="${ARKDECK_HELPER_OUTPUT:-$package_root/.build/arkdeck-macos-helpers}"
identity="${ARKDECK_CODESIGN_IDENTITY:-Developer ID Application: Hanfeng Fu (8AQTYW5FKR)}"
cli_profile="${ARKDECK_CLI_PROVISIONING_PROFILE:-}"
daemon_profile="${ARKDECK_DAEMON_PROVISIONING_PROFILE:-}"
notary_profile="${ARKDECK_NOTARY_KEYCHAIN_PROFILE:-}"
team_identifier="8AQTYW5FKR"
keychain_group="$team_identifier.com.arkdeck.shared"
# CHG-2026-074 M5 (G5 slice 20a): ARKDECK_HELPER_RUNTIME=rust releases the same
# helper pair with the Rust CLI and daemon as its main programs, and keeps the
# current Swift helper, named by ARKDECK_ROLLBACK_HELPER, beside it for one
# cycle. Swift stays the default until the cutover window changes it.
helper_runtime="${ARKDECK_HELPER_RUNTIME:-swift}"
rollback_helper="${ARKDECK_ROLLBACK_HELPER:-}"
case "$helper_runtime" in
  swift) ;;
  rust)
    if [[ "$rollback_helper" != /* || ! -d "$rollback_helper" ]]; then
      echo "ARKDECK_ROLLBACK_HELPER must name the current Swift ArkDeckAgent.app to keep for one cycle" >&2
      exit 64
    fi
    ;;
  *)
    echo "ARKDECK_HELPER_RUNTIME must be swift or rust" >&2
    exit 64
    ;;
esac

if [[ -z "$cli_profile" || -z "$daemon_profile" || -z "$notary_profile" ]]; then
  echo "CLI/daemon provisioning profiles and ARKDECK_NOTARY_KEYCHAIN_PROFILE are required" >&2
  exit 64
fi
if [[ ! -f "$cli_profile" || ! -f "$daemon_profile" ]]; then
  echo "both helper provisioning profiles must be existing regular files" >&2
  exit 66
fi
if [[ -e "$output_root" ]]; then
  echo "output already exists: $output_root" >&2
  exit 73
fi

profile_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-helper-profiles.XXXXXX")"
staging_root=""
cleanup() {
  rm -rf "$profile_root"
  if [[ -n "$staging_root" && -d "$staging_root" ]]; then
    rm -rf "$staging_root"
  fi
}
trap cleanup EXIT

validate_profile() {
  label="$1"
  path="$2"
  expected_application_identifier="$3"
  decoded="$profile_root/$label.plist"
  security cms -D -i "$path" > "$decoded"
  actual_team="$(/usr/libexec/PlistBuddy -c \
    "Print :Entitlements:com.apple.developer.team-identifier" "$decoded")"
  if actual_application_identifier="$(/usr/libexec/PlistBuddy -c \
    "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null)"; then
    :
  else
    actual_application_identifier="$(/usr/libexec/PlistBuddy -c \
      "Print :Entitlements:application-identifier" "$decoded")"
  fi
  if [[ "$actual_team" != "$team_identifier" \
    || "$actual_application_identifier" != "$expected_application_identifier" ]]; then
    echo "$label provisioning profile does not authorize its exact ArkDeck application identity" >&2
    exit 78
  fi
  access_groups="$(/usr/libexec/PlistBuddy -c \
    "Print :Entitlements:keychain-access-groups" "$decoded")"
  if ! grep -Fq "$keychain_group" <<< "$access_groups" \
    && ! grep -Fq "$team_identifier.*" <<< "$access_groups"; then
    echo "$label provisioning profile does not authorize the ArkDeck shared Keychain group" >&2
    exit 78
  fi
}

validate_profile "cli" "$cli_profile" "$team_identifier.com.arkdeck.cli"
validate_profile "daemon" "$daemon_profile" "$team_identifier.com.arkdeck.agentd"

if [[ "$helper_runtime" == rust ]]; then
  # The same gates as the Swift release below: Developer ID with hardened
  # runtime and a secure timestamp, strict verification, then notarization,
  # stapling and Gatekeeper assessment of the pair and of the retained helper.
  rust_root="$(cd "$package_root/../../rust" && pwd)"
  (cd "$rust_root" && cargo build --locked --release --target aarch64-apple-darwin \
    -p arkdeck-cli -p arkdeck-agentd --bins)
  target_directory="$(cd "$rust_root" && cargo metadata --locked --format-version 1 --no-deps \
    | plutil -extract target_directory raw -o - -)"
  staging_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-helper-build.XXXXXX")"
  bash "$distribution_root/package-rust-helpers.sh" \
    "$target_directory/aarch64-apple-darwin/release" "$staging_root" \
    "$cli_profile" "$daemon_profile" "$identity" --timestamp "$rollback_helper"
  cli_bundle="$staging_root/ArkDeckCLI.app"
  archive="$staging_root/ArkDeckCLI-notarization.zip"
  ditto -c -k --keepParent "$cli_bundle" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$cli_bundle"
  spctl --assess --type execute --verbose=2 "$cli_bundle"
  rm "$archive"
  rollback_archive="$staging_root/ArkDeckAgent-rollback-notarization.zip"
  ditto -c -k --keepParent "$staging_root/rollback/ArkDeckAgent.app" "$rollback_archive"
  xcrun notarytool submit "$rollback_archive" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$staging_root/rollback/ArkDeckAgent.app"
  spctl --assess --type execute --verbose=2 "$staging_root/rollback/ArkDeckAgent.app"
  rm "$rollback_archive"
  mkdir -p "$(dirname "$output_root")"
  mv "$staging_root" "$output_root"
  staging_root=""
  rm -rf "$profile_root"
  trap - EXIT
  echo "$output_root/ArkDeckCLI.app"
  exit 0
fi

# Host helpers ship for Apple silicon only, including when Swift runs under Rosetta.
swift build --package-path "$package_root" --arch arm64 -c release --product arkdeck
swift build --package-path "$package_root" --arch arm64 -c release --product arkdeck-agentd
bin_root="$(swift build --package-path "$package_root" --arch arm64 -c release --show-bin-path)"
workflows_resource_bundle="$bin_root/ArkDeckKit_ArkDeckWorkflows.bundle"
launch_agent_resource_bundle="$bin_root/ArkDeckKit_ArkDeckLaunchAgent.bundle"
if [[ ! -d "$workflows_resource_bundle" || ! -d "$launch_agent_resource_bundle" ]]; then
  echo "required SwiftPM resource bundles are missing from the release products" >&2
  exit 66
fi
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-helper-build.XXXXXX")"
cli_bundle="$staging_root/ArkDeckCLI.app"
daemon_bundle="$cli_bundle/Contents/Helpers/ArkDeckAgent.app"
mkdir -p \
  "$cli_bundle/Contents/MacOS" "$cli_bundle/Contents/Resources" \
  "$daemon_bundle/Contents/MacOS" "$daemon_bundle/Contents/Resources"
cp "$distribution_root/ArkDeckCLI-Info.plist" "$cli_bundle/Contents/Info.plist"
cp "$distribution_root/ArkDeckAgent-Info.plist" "$daemon_bundle/Contents/Info.plist"
cp "$cli_profile" "$cli_bundle/Contents/embedded.provisionprofile"
cp "$daemon_profile" "$daemon_bundle/Contents/embedded.provisionprofile"
cp "$bin_root/arkdeck" "$cli_bundle/Contents/MacOS/arkdeck"
cp "$bin_root/arkdeck-agentd" "$daemon_bundle/Contents/MacOS/arkdeck-agentd"
cp -R "$workflows_resource_bundle" "$cli_bundle/Contents/Resources/"
cp -R "$workflows_resource_bundle" "$daemon_bundle/Contents/Resources/"
cp -R "$launch_agent_resource_bundle" "$cli_bundle/Contents/Resources/"
chmod 700 "$cli_bundle/Contents/MacOS/arkdeck" "$daemon_bundle/Contents/MacOS/arkdeck-agentd"

bash "$package_root/../../rust/scripts/package-macos-facade.sh" release \
  "$daemon_bundle" "$staging_root/rollback/ArkDeckAgent.app" "$identity" \
  "$distribution_root/ArkDeckAgent.entitlements"

codesign --force --sign "$identity" --options runtime --timestamp \
  --entitlements "$distribution_root/ArkDeckAgent.entitlements" "$daemon_bundle"
codesign --force --sign "$identity" --options runtime --timestamp \
  --entitlements "$distribution_root/ArkDeckCLI.entitlements" "$cli_bundle"
codesign --verify --strict --deep --verbose=2 "$cli_bundle"
archive="$staging_root/ArkDeckCLI-notarization.zip"
ditto -c -k --keepParent "$cli_bundle" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$cli_bundle"
spctl --assess --type execute --verbose=2 "$cli_bundle"
rm "$archive"
rollback_archive="$staging_root/ArkDeckAgent-rollback-notarization.zip"
ditto -c -k --keepParent "$staging_root/rollback/ArkDeckAgent.app" "$rollback_archive"
xcrun notarytool submit "$rollback_archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$staging_root/rollback/ArkDeckAgent.app"
spctl --assess --type execute --verbose=2 "$staging_root/rollback/ArkDeckAgent.app"
rm "$rollback_archive"
mkdir -p "$(dirname "$output_root")"
mv "$staging_root" "$output_root"
staging_root=""
rm -rf "$profile_root"
trap - EXIT
echo "$output_root/ArkDeckCLI.app"
