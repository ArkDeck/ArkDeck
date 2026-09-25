#!/bin/bash
set -euo pipefail

# Lays out the Rust helper pair exactly as the Rust release does
# (package-rust-helpers.sh) but signs it ad hoc, so check-rust-helpers.py can
# check its structure without any signing identity (CHG-2026-074 M5, G5 slice
# 20a). NOT FOR DISTRIBUTION: an ad hoc signature, placeholder provisioning
# profiles, no secure timestamp and no notarization. The helper validator of
# `runtime service update` refuses it for lack of the Developer ID anchor, so
# it can never be installed; the output root says so in
# UNSIGNED-STRUCTURE-CHECK-ONLY.txt. Releases come only from build-helpers.sh.
#
# ARKDECK_RUST_HELPER_BINARIES names a directory holding already built
# `arkdeck` and `arkdeck-agentd` (CI passes the ones its tests built); without
# it the release profile is built as the release builds it.
# ARKDECK_ROLLBACK_HELPER optionally names a Swift helper to retain, as the
# release requires; here it is checked by identifier only.
distribution_root="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$distribution_root/../.." && pwd)"
rust_root="$(cd "$package_root/../../rust" && pwd)"
output_root="${ARKDECK_UNSIGNED_HELPER_OUTPUT:-$package_root/.build/arkdeck-macos-unsigned-rust-helpers}"
binaries="${ARKDECK_RUST_HELPER_BINARIES:-}"
rollback_helper="${ARKDECK_ROLLBACK_HELPER:-none}"

if [[ "$output_root" != /* ]]; then
  echo "ARKDECK_UNSIGNED_HELPER_OUTPUT must be an absolute path" >&2
  exit 64
fi
if [[ -e "$output_root" || -L "$output_root" ]]; then
  echo "output already exists: $output_root" >&2
  exit 73
fi
if [[ -n "$binaries" && "$binaries" != /* ]]; then
  echo "ARKDECK_RUST_HELPER_BINARIES must be an absolute directory" >&2
  exit 64
fi

work_root="$(mktemp -d "${TMPDIR:-/tmp}/arkdeck-unsigned-rust-helpers.XXXXXX")"
cleanup() {
  rm -rf "$work_root"
}
trap cleanup EXIT

if [[ -z "$binaries" ]]; then
  (cd "$rust_root" && cargo build --locked --release --target aarch64-apple-darwin \
    -p arkdeck-cli -p arkdeck-agentd --bins)
  target_directory="$(cd "$rust_root" && cargo metadata --locked --format-version 1 --no-deps \
    | plutil -extract target_directory raw -o - -)"
  binaries="$target_directory/aarch64-apple-darwin/release"
fi

# Where the release embeds each helper's provisioning profile. These authorize
# nothing; the checker recognizes them by their exact bytes.
for identifier in com.arkdeck.cli com.arkdeck.agentd; do
  printf 'ArkDeck unsigned structure check: placeholder for the %s provisioning profile; it authorizes nothing\n' \
    "$identifier" > "$work_root/$identifier.provisionprofile"
done
staging_root="$work_root/output"
mkdir "$staging_root"
bash "$distribution_root/package-rust-helpers.sh" "$binaries" "$staging_root" \
  "$work_root/com.arkdeck.cli.provisionprofile" "$work_root/com.arkdeck.agentd.provisionprofile" \
  - --timestamp=none "$rollback_helper"
printf '%s\n' \
  "UNSIGNED STRUCTURE CHECK ONLY: signed ad hoc with placeholder provisioning profiles, no timestamp and no notarization. Never distribute or install it." \
  > "$staging_root/UNSIGNED-STRUCTURE-CHECK-ONLY.txt"
mkdir -p "$(dirname "$output_root")"
mv "$staging_root" "$output_root"

echo "unsigned structure check; not for distribution" >&2
echo "$output_root/ArkDeckCLI.app"
