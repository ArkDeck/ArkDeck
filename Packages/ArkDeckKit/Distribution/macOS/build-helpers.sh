#!/bin/bash
set -euo pipefail

distribution_root="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$distribution_root/../.." && pwd)"
output_root="${ARKDECK_HELPER_OUTPUT:-$package_root/.build/arkdeck-macos-helpers}"
identity="${ARKDECK_CODESIGN_IDENTITY:-Developer ID Application: Hanfeng Fu (8AQTYW5FKR)}"
cli_profile="${ARKDECK_CLI_PROVISIONING_PROFILE:-}"
daemon_profile="${ARKDECK_DAEMON_PROVISIONING_PROFILE:-}"
notary_profile="${ARKDECK_NOTARY_KEYCHAIN_PROFILE:-}"
notary_keychain="${ARKDECK_NOTARY_KEYCHAIN:-}"
notary_key="${ARKDECK_NOTARY_API_KEY_PATH:-}"
notary_key_id="${ARKDECK_NOTARY_API_KEY_ID:-}"
notary_issuer="${ARKDECK_NOTARY_API_ISSUER_ID:-}"
team_identifier="8AQTYW5FKR"
keychain_group="$team_identifier.com.arkdeck.shared"
# CHG-2026-074 M5: the helper pair's main programs are the Rust CLI and
# daemon, laid out by package-rust-helpers.sh. It retains no Swift helper: by
# the maintainer's 2026-09-28 ruling (P8) there is no Swift rollback build, and
# the rollback is the installed helper itself, which `runtime service update`
# keeps in Helpers/.rollback and the maintainer copies aside before the first
# cutover. The Swift helper build and its Rust transport facade are retired
# (TASK-XPA-017). scripts/release/build_macos_release.py calls this script for
# the release DMG.

if [[ -z "$cli_profile" || -z "$daemon_profile" ]]; then
  echo "CLI/daemon provisioning profiles are required" >&2
  exit 64
fi
# Notary credentials: a stored Keychain profile, or an App Store Connect API
# key (the release-rc workflow's), exactly one of the two. Only the key's path
# is ever an argument; nothing here prints the key, its ID or the issuer.
if [[ -n "$notary_profile" && -n "$notary_key$notary_key_id$notary_issuer" ]]; then
  echo "notary credentials are ARKDECK_NOTARY_KEYCHAIN_PROFILE or the API key, not both" >&2
  exit 64
elif [[ -n "$notary_profile" ]]; then
  notary_arguments=(--keychain-profile "$notary_profile")
  if [[ -n "$notary_keychain" ]]; then
    notary_arguments+=(--keychain "$notary_keychain")
  fi
elif [[ -n "$notary_key" && -n "$notary_key_id" && -n "$notary_issuer" ]]; then
  if [[ -n "$notary_keychain" ]]; then
    echo "ARKDECK_NOTARY_KEYCHAIN names where a Keychain profile is stored; an API key has none" >&2
    exit 64
  fi
  if [[ "$notary_key" != /* || ! -f "$notary_key" || -L "$notary_key" ]]; then
    echo "ARKDECK_NOTARY_API_KEY_PATH must be an absolute path to the .p8 key file" >&2
    exit 66
  fi
  notary_arguments=(--key "$notary_key" --key-id "$notary_key_id" --issuer "$notary_issuer")
else
  echo "notary credentials are required: ARKDECK_NOTARY_KEYCHAIN_PROFILE, or" \
    "ARKDECK_NOTARY_API_KEY_PATH, ARKDECK_NOTARY_API_KEY_ID and ARKDECK_NOTARY_API_ISSUER_ID" >&2
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

# Developer ID with hardened runtime and a secure timestamp, strict
# verification, then notarization, stapling and Gatekeeper assessment of the
# pair. ARKDECK_CODESIGN_KEYCHAIN, when set, reaches package-rust-helpers.sh
# through the environment and names the keychain that holds the identity.
rust_root="$(cd "$package_root/../../rust" && pwd)"
(cd "$rust_root" && cargo build --locked --release --target aarch64-apple-darwin \
  -p arkdeck-cli -p arkdeck-agentd --bins)
target_directory="$(cd "$rust_root" && cargo metadata --locked --format-version 1 --no-deps \
  | plutil -extract target_directory raw -o - -)"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-helper-build.XXXXXX")"
bash "$distribution_root/package-rust-helpers.sh" \
  "$target_directory/aarch64-apple-darwin/release" "$staging_root" \
  "$cli_profile" "$daemon_profile" "$identity" --timestamp
cli_bundle="$staging_root/ArkDeckCLI.app"
archive="$staging_root/ArkDeckCLI-notarization.zip"
ditto -c -k --keepParent "$cli_bundle" "$archive"
xcrun notarytool submit "$archive" "${notary_arguments[@]}" --wait
xcrun stapler staple "$cli_bundle"
spctl --assess --type execute --verbose=2 "$cli_bundle"
rm "$archive"
mkdir -p "$(dirname "$output_root")"
mv "$staging_root" "$output_root"
staging_root=""
rm -rf "$profile_root"
trap - EXIT
echo "$output_root/ArkDeckCLI.app"
