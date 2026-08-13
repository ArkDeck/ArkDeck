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

swift build --package-path "$package_root" -c release --product arkdeck
swift build --package-path "$package_root" -c release --product arkdeck-agentd
bin_root="$(swift build --package-path "$package_root" -c release --show-bin-path)"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-helper-build.XXXXXX")"
cli_bundle="$staging_root/ArkDeckCLI.app"
daemon_bundle="$cli_bundle/Contents/Helpers/ArkDeckAgent.app"
mkdir -p "$cli_bundle/Contents/MacOS" "$daemon_bundle/Contents/MacOS"
cp "$distribution_root/ArkDeckCLI-Info.plist" "$cli_bundle/Contents/Info.plist"
cp "$distribution_root/ArkDeckAgent-Info.plist" "$daemon_bundle/Contents/Info.plist"
cp "$cli_profile" "$cli_bundle/Contents/embedded.provisionprofile"
cp "$daemon_profile" "$daemon_bundle/Contents/embedded.provisionprofile"
cp "$bin_root/arkdeck" "$cli_bundle/Contents/MacOS/arkdeck"
cp "$bin_root/arkdeck-agentd" "$daemon_bundle/Contents/MacOS/arkdeck-agentd"
chmod 700 "$cli_bundle/Contents/MacOS/arkdeck" "$daemon_bundle/Contents/MacOS/arkdeck-agentd"

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
mkdir -p "$(dirname "$output_root")"
mv "$staging_root" "$output_root"
staging_root=""
rm -rf "$profile_root"
trap - EXIT
echo "$output_root/ArkDeckCLI.app"
