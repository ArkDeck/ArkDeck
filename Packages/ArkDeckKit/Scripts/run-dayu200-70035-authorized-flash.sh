#!/usr/bin/env bash

set -euo pipefail

# Closed convenience entry for the already-published typed Rockchip executor.
# A current supervised chat or interactive confirmation is the one-shot E2 authority. The script
# submits only a closed digest assertion to ArkDeck's product-owned typed executor; it never builds
# or dispatches raw Rockchip argv and never fabricates standing-authorization provenance.

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
readonly PACKAGE_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly ARKDECK_BIN="$PACKAGE_DIR/.build/release/arkdeck"
readonly ARCHIVE="/Users/fuhanfeng/Downloads/version-Daily_Version-OpenHarmony_7.0.0.35-20260728_180253-dayu200_img.tar.gz"
readonly TOOL="/Users/fuhanfeng/dayu200-rehearsal/rkdeveloptool/rkdeveloptool"
readonly BINDING="/Users/fuhanfeng/Library/Application Support/ArkDeck/rockchip-binding.json"

readonly EXPECTED_ARCHIVE_SHA256="6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e"
readonly EXPECTED_TOOL_SHA256="038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"
readonly EXPECTED_PLAN_SHA256="3922f6a22401a624dd393932bbfc7d3774953be79aaece08961a8bbfb77dc2b8"
readonly EXPECTED_STEP_SET_SHA256="c8bdce2a137690081c1dd5ca38f91f25399c63778ab18b4f94000b127382fa14"

usage() {
  printf 'Usage:\n' >&2
  printf '  %s --check\n' "$0" >&2
  printf '  %s --interactive-trigger\n' "$0" >&2
  printf '  %s --chat-trigger --confirm-plan-sha256 SHA256 --confirmation-digest-sha256 SHA256\n' "$0" >&2
}

fail() {
  printf 'BLOCKED: %s\n' "$1" >&2
  exit 2
}

sha256_file() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

mode=""
confirmed_plan_sha256=""
confirmation_digest_sha256=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--interactive-trigger|--chat-trigger)
      [[ -z "$mode" ]] || fail "exactly one execution mode is required"
      mode="$1"
      shift
      ;;
    --confirm-plan-sha256)
      [[ $# -ge 2 && -z "$confirmed_plan_sha256" ]] || fail "--confirm-plan-sha256 requires one value"
      confirmed_plan_sha256="$2"
      shift 2
      ;;
    --confirmation-digest-sha256)
      [[ $# -ge 2 && -z "$confirmation_digest_sha256" ]] || fail "--confirmation-digest-sha256 requires one value"
      confirmation_digest_sha256="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$mode" ]] || {
  usage
  exit 64
}

case "$mode" in
  --check)
    [[ -z "$confirmed_plan_sha256" && -z "$confirmation_digest_sha256" ]] || fail "--check does not accept confirmation values"
    ;;
  --interactive-trigger)
    [[ -z "$confirmed_plan_sha256" && -z "$confirmation_digest_sha256" ]] || fail "interactive mode creates its assertion from the TTY confirmation"
    [[ "${CI:-}" != "true" && "${GITHUB_ACTIONS:-}" != "true" ]] || fail "CI cannot trigger real Flash"
    [[ -t 0 && -t 1 ]] || fail "interactive trigger requires stdin and stdout attached to a TTY"
    ;;
  --chat-trigger)
    [[ "${CI:-}" != "true" && "${GITHUB_ACTIONS:-}" != "true" ]] || fail "CI cannot trigger real Flash"
    [[ "$confirmed_plan_sha256" == "$EXPECTED_PLAN_SHA256" ]] || fail "chat trigger does not confirm the exact pinned plan digest"
    [[ "$confirmation_digest_sha256" =~ ^[a-f0-9]{64}$ ]] || fail "chat confirmation digest must be full lowercase SHA-256"
    ;;
esac

[[ -f "$ARCHIVE" ]] || fail "pinned 7.0.0.35 archive is missing"
[[ -f "$TOOL" && -x "$TOOL" ]] || fail "pinned rkdeveloptool is missing or not executable"
[[ -f "$BINDING" ]] || fail "durable Rockchip binding is missing: $BINDING"

archive_sha256="$(sha256_file "$ARCHIVE")"
[[ "$archive_sha256" == "$EXPECTED_ARCHIVE_SHA256" ]] || fail "archive SHA-256 drift"
tool_sha256="$(sha256_file "$TOOL")"
[[ "$tool_sha256" == "$EXPECTED_TOOL_SHA256" ]] || fail "rkdeveloptool SHA-256 drift"

if /usr/bin/xattr -p com.apple.quarantine "$TOOL" >/dev/null 2>&1; then
  fail "rkdeveloptool is quarantined; the maintainer must personally decide whether to trust it"
fi

bookmark_type="$(/usr/bin/defaults read-type arkdeck ArkDeck.Rockchip.ToolOrdinaryBookmarkV1 2>/dev/null || true)"
[[ "$bookmark_type" == "Type is data" ]] || fail "ordinary tool bookmark is not installed"
quarantine_fact="$(/usr/bin/defaults read arkdeck ArkDeck.Rockchip.ToolQuarantinePresent 2>/dev/null || true)"
[[ "$quarantine_fact" == "0" ]] || fail "recorded quarantine assessment is absent or not false"
code_trust="$(/usr/bin/defaults read arkdeck ArkDeck.Rockchip.ToolCodeTrust 2>/dev/null || true)"
[[ "$code_trust" == "adHoc" || "$code_trust" == "developerID" ]] || fail "recorded code trust is not permitted"

binding_mode="$(/usr/bin/stat -f '%Lp' "$BINDING")"
[[ "$binding_mode" == "600" ]] || fail "binding permissions must be 0600"
binding_revision="$(/usr/bin/plutil -extract revision raw -o - "$BINDING" 2>/dev/null || true)"
target_location_id="$(/usr/bin/plutil -extract usbTopology raw -o - "$BINDING" 2>/dev/null || true)"
binding_serial="$(/usr/bin/plutil -extract serial raw -o - "$BINDING" 2>/dev/null || true)"
[[ "$binding_revision" =~ ^[1-9][0-9]*$ ]] || fail "binding revision is missing or invalid"
[[ "$target_location_id" =~ ^(0|[1-9][0-9]*)$ ]] || fail "binding USB topology is missing or invalid"
[[ -n "$binding_serial" ]] || fail "binding serial is missing"
binding_serial_sha256="$(printf '%s' "$binding_serial" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
target_digest_sha256="$(printf '%s' "dayu200|${binding_serial_sha256}|${binding_revision}|${target_location_id}|8711|13578" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
unset binding_serial

if [[ ! -x "$ARKDECK_BIN" ]]; then
  /usr/bin/swift build --package-path "$PACKAGE_DIR" -c release --product arkdeck
fi

printf 'READY: host-only checks passed\n'
printf '  authority: chatConfirmation (one-shot; no AUTH-ID)\n'
printf '  execution authority: authorizedAgent\n'
printf '  profile: dayu200@2 / OpenHarmony 7.0.0.35-20260728_180253\n'
printf '  archive sha256: %s\n' "$EXPECTED_ARCHIVE_SHA256"
printf '  plan sha256: %s\n' "$EXPECTED_PLAN_SHA256"
printf '  step-set sha256: %s\n' "$EXPECTED_STEP_SET_SHA256"
printf '  binding revision: %s\n' "$binding_revision"
printf '  USB topology: %s\n' "$target_location_id"
printf '  target sha256: %s\n' "$target_digest_sha256"
printf '  impact: all 9 mapped partitions, including userdata, will be overwritten\n'

if [[ "$mode" == "--check" ]]; then
  printf 'CHECK ONLY: no device command was dispatched\n'
  exit 0
fi

if [[ "$mode" == "--interactive-trigger" ]]; then
  readonly CONFIRMATION="FLASH DAYU200 ${EXPECTED_PLAN_SHA256:0:12} ERASE-USERDATA"
  printf '\nType exactly to trigger the protected-main authorized typed executor:\n%s\n> ' "$CONFIRMATION"
  IFS= read -r response
  [[ "$response" == "$CONFIRMATION" ]] || fail "destructive confirmation did not match; dispatch remains zero"
  confirmation_nonce="$(/usr/bin/uuidgen)"
  confirmation_digest_sha256="$(printf '%s' "${response}|${confirmation_nonce}|${EXPECTED_PLAN_SHA256}|${target_digest_sha256}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  unset response confirmation_nonce
else
  printf 'CHAT TRIGGER: current exact-plan confirmation will be consumed as one-shot E2 authority\n'
fi

command=(
  "$ARKDECK_BIN" flash execute
  --images "$ARCHIVE"
  --target-location-id "$target_location_id"
  --chat-confirmation-digest-sha256 "$confirmation_digest_sha256"
  --chat-confirmed-plan-sha256 "$EXPECTED_PLAN_SHA256"
  --chat-confirmed-archive-sha256 "$EXPECTED_ARCHIVE_SHA256"
  --chat-confirmed-step-set-sha256 "$EXPECTED_STEP_SET_SHA256"
  --chat-confirmed-target-sha256 "$target_digest_sha256"
  --chat-confirmed-binding-revision "$binding_revision"
)

exec /usr/bin/env ARKDECK_EXECUTION_AUTHORITY=standardAgent \
  ARKDECK_CHAT_CONFIRMATION_CONTEXT=supervisedInteractiveAgent "${command[@]}"
