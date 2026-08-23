#!/bin/bash
set -euo pipefail

# Builds a provisioned helper pair for this Mac only. Release distribution
# remains exclusively owned by build-helpers.sh, which requires timestamping,
# notarization, stapling and Gatekeeper assessment.
distribution_root="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$distribution_root/../.." && pwd)"
output_root="${ARKDECK_LOCAL_HELPER_OUTPUT:-$package_root/.build/arkdeck-macos-local-helpers}"
identity="${ARKDECK_CODESIGN_IDENTITY:-Developer ID Application: Hanfeng Fu (8AQTYW5FKR)}"
cli_profile="${ARKDECK_CLI_PROVISIONING_PROFILE:-}"
daemon_profile="${ARKDECK_DAEMON_PROVISIONING_PROFILE:-}"
team_identifier="8AQTYW5FKR"
keychain_group="$team_identifier.com.arkdeck.shared"

if [[ -z "$cli_profile" || -z "$daemon_profile" ]]; then
  echo "ARKDECK_CLI_PROVISIONING_PROFILE and ARKDECK_DAEMON_PROVISIONING_PROFILE are required" >&2
  exit 64
fi
for profile in "$cli_profile" "$daemon_profile"; do
  if [[ "$profile" != /* || ! -f "$profile" || -L "$profile" ]]; then
    echo "helper provisioning profiles must be physical regular files at absolute paths" >&2
    exit 66
  fi
done
if [[ "$output_root" != /* ]]; then
  echo "ARKDECK_LOCAL_HELPER_OUTPUT must be an absolute path" >&2
  exit 64
fi
if [[ -e "$output_root" || -L "$output_root" ]]; then
  echo "output already exists: $output_root" >&2
  exit 73
fi
if [[ -z "$identity" ]]; then
  echo "ARKDECK_CODESIGN_IDENTITY must not be empty" >&2
  exit 64
fi
if ! security find-identity -v -p codesigning | grep -Fq "$identity"; then
  echo "the requested Developer ID signing identity is unavailable" >&2
  exit 78
fi

profile_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-local-helper-profiles.XXXXXX")"
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

swift build --package-path "$package_root" -c debug --product arkdeck
swift build --package-path "$package_root" -c debug --product arkdeck-agentd
bin_root="$(swift build --package-path "$package_root" -c debug --show-bin-path)"
workflows_resource_bundle="$bin_root/ArkDeckKit_ArkDeckWorkflows.bundle"
launch_agent_resource_bundle="$bin_root/ArkDeckKit_ArkDeckLaunchAgent.bundle"
if [[ ! -d "$workflows_resource_bundle" || ! -d "$launch_agent_resource_bundle" ]]; then
  echo "required SwiftPM resource bundles are missing from the debug products" >&2
  exit 66
fi

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-local-helper-build.XXXXXX")"
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

codesign --force --sign "$identity" --options runtime --timestamp=none \
  --entitlements "$distribution_root/ArkDeckAgent.entitlements" "$daemon_bundle"
codesign --force --sign "$identity" --options runtime --timestamp=none \
  --entitlements "$distribution_root/ArkDeckCLI.entitlements" "$cli_bundle"
codesign --verify --strict --deep --verbose=2 "$cli_bundle"

printf '%s\n' \
  "LOCAL DEVELOPMENT BUILD — not notarized, not stapled, and not for distribution." \
  > "$staging_root/LOCAL-DEVELOPMENT-BUILD.txt"
mkdir -p "$(dirname "$output_root")"
mv "$staging_root" "$output_root"
staging_root=""
rm -rf "$profile_root"
trap - EXIT

echo "local development helper; do not distribute" >&2
echo "$output_root/ArkDeckCLI.app"
