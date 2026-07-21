#!/usr/bin/env bash

set -euo pipefail

readonly TASK_UD_EXPECTED_BRANCH="agent/task-ud-r2-decision-001"
readonly TASK_UD_R10_OID="a2c095cd087ebacc1072353f147f9af903856775"
readonly TASK_UD_EXPECTED_RAW_SHA256="ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077"
readonly TASK_UD_EXPECTED_RAW_SIZE="866256"
readonly TASK_UD_PYTHON_SHA256="b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf"
readonly TASK_UD_REDACTOR_SHA256="938cc117da97304b5ede66ff55c84dd9ce0a987600d4a1ecec2c3e01351f53e1"
readonly TASK_UD_MANIFEST_SHA256="a75778fdf525050c4c0bcf11579e5f09f99a6fa70697bcf79026656a71f20185"
readonly TASK_UD_ALLOWLIST_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
readonly TASK_UD_RECEIPT_SCHEMA_SHA256="f4bffe70a51dc3f6228f24d41b814dc47cc2d6f0cde5f00445070f86cd1ec4b6"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: operator-redact.sh

Human-maintainer-only Phase A R2 raw -> derived transform.

The script accepts no raw path argument so that the controlled path does not
enter shell history. It prompts for the path with terminal echo disabled,
runs only the pinned offline redactor, and leaves derived/receipt output in a
fresh 0700 directory under /private/tmp for human review.

Do not paste the raw path, raw/derived bytes, or exact component token into
chat, repository evidence, or the decision record.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ "$#" -eq 0 ]] || fail "no positional arguments are accepted"
[[ -t 0 && -t 1 ]] || fail "run this script from an interactive terminal"

TASK_UD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TASK_UD_REPO="$(git -C "$TASK_UD_SCRIPT_DIR" rev-parse --show-toplevel)"
TASK_UD_COMMON_GIT_DIR="$(git -C "$TASK_UD_REPO" rev-parse --git-common-dir)"
if [[ "$TASK_UD_COMMON_GIT_DIR" != /* ]]; then
  TASK_UD_COMMON_GIT_DIR="$TASK_UD_REPO/$TASK_UD_COMMON_GIT_DIR"
fi
TASK_UD_COMMON_GIT_DIR="$(cd "$TASK_UD_COMMON_GIT_DIR" && pwd -P)"
TASK_UD_PRIMARY_ROOT="$(cd "$TASK_UD_COMMON_GIT_DIR/.." && pwd -P)"
TASK_UD_PYTHON="$TASK_UD_PRIMARY_ROOT/.venv-sdd/bin/python"
readonly TASK_UD_SCRIPT_DIR TASK_UD_REPO TASK_UD_COMMON_GIT_DIR TASK_UD_PRIMARY_ROOT TASK_UD_PYTHON
cd "$TASK_UD_REPO"

readonly TASK_UD_REDACTOR="$TASK_UD_REPO/scripts/ui_dump_redaction/redact.py"
readonly TASK_UD_MANIFEST="$TASK_UD_REPO/scripts/ui_dump_redaction/algorithm-v1.json"
readonly TASK_UD_ALLOWLIST="$TASK_UD_REPO/scripts/ui_dump_redaction/safe-literals-v1.txt"
readonly TASK_UD_RECEIPT_SCHEMA="$TASK_UD_REPO/scripts/ui_dump_redaction/redaction-receipt.schema.json"

verify_sha256() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$path")"
  actual="${actual%% *}"
  [[ "$actual" == "$expected" ]] || fail "pinned SHA-256 mismatch: $(basename "$path")"
}

TASK_UD_BRANCH="$(git -C "$TASK_UD_REPO" branch --show-current)"
[[ "$TASK_UD_BRANCH" == "$TASK_UD_EXPECTED_BRANCH" ]] \
  || fail "expected branch $TASK_UD_EXPECTED_BRANCH"
git -C "$TASK_UD_REPO" merge-base --is-ancestor "$TASK_UD_R10_OID" HEAD \
  || fail "r10 merge OID is not an ancestor of HEAD"

[[ -x "$TASK_UD_PYTHON" ]] || fail "readiness-pinned Python is unavailable"
verify_sha256 "$TASK_UD_PYTHON_SHA256" "$TASK_UD_PYTHON"
verify_sha256 "$TASK_UD_REDACTOR_SHA256" "$TASK_UD_REDACTOR"
verify_sha256 "$TASK_UD_MANIFEST_SHA256" "$TASK_UD_MANIFEST"
verify_sha256 "$TASK_UD_ALLOWLIST_SHA256" "$TASK_UD_ALLOWLIST"
verify_sha256 "$TASK_UD_RECEIPT_SCHEMA_SHA256" "$TASK_UD_RECEIPT_SCHEMA"

"$TASK_UD_PYTHON" -c \
  'import platform, yaml; assert platform.python_version() == "3.14.6"; assert yaml.__version__ == "6.0.3"'
"$TASK_UD_PYTHON" -m unittest -q scripts/ui_dump_redaction/test_redact.py

printf '%s\n' \
  'Preflight PASS: r10 ancestry, branch, Python, PyYAML, policy hashes, and 21 redactor tests.' \
  'No HDC, device, network, GUI, or destructive command was dispatched.'
printf 'Controlled R2 sidecar absolute path (input hidden): ' >&2
IFS= read -r -s TASK_UD_R2_RAW
printf '\n' >&2
[[ -n "$TASK_UD_R2_RAW" ]] || fail "controlled raw path is empty"

umask 077
TASK_UD_STAGE="$(/usr/bin/mktemp -d /private/tmp/task-ud-r2-decision-001.XXXXXX)"
/bin/chmod 700 "$TASK_UD_STAGE"
readonly TASK_UD_STAGE
readonly TASK_UD_DERIVED="$TASK_UD_STAGE/r2-element-tree-v1.derived.bin"
readonly TASK_UD_RECEIPT="$TASK_UD_STAGE/r2-element-tree-v1.redaction-receipt.json"

TASK_UD_REDACTOR_ARGV=(
  "$TASK_UD_PYTHON"
  "$TASK_UD_REDACTOR"
  --algorithm-manifest "$TASK_UD_MANIFEST"
  --safe-literals "$TASK_UD_ALLOWLIST"
  --input "$TASK_UD_R2_RAW"
  --expected-input-sha256 "$TASK_UD_EXPECTED_RAW_SHA256"
  --output "$TASK_UD_DERIVED"
  --receipt "$TASK_UD_RECEIPT"
)

set +e
"${TASK_UD_REDACTOR_ARGV[@]}"
TASK_UD_REDACTOR_EXIT="$?"
set -e
TASK_UD_R2_RAW=''
unset TASK_UD_R2_RAW TASK_UD_REDACTOR_ARGV

if [[ "$TASK_UD_REDACTOR_EXIT" -ne 0 ]]; then
  printf 'Redactor FAILED with stable exit code %s.\n' "$TASK_UD_REDACTOR_EXIT" >&2
  printf 'Staging directory retained for human inspection: %s\n' "$TASK_UD_STAGE" >&2
  exit "$TASK_UD_REDACTOR_EXIT"
fi

[[ -f "$TASK_UD_DERIVED" && ! -L "$TASK_UD_DERIVED" ]] \
  || fail "derived output is missing or is a symlink"
[[ -f "$TASK_UD_RECEIPT" && ! -L "$TASK_UD_RECEIPT" ]] \
  || fail "receipt output is missing or is a symlink"
[[ "$(/usr/bin/stat -f '%Lp' "$TASK_UD_DERIVED")" == "600" ]] \
  || fail "derived output mode is not 0600"
[[ "$(/usr/bin/stat -f '%Lp' "$TASK_UD_RECEIPT")" == "600" ]] \
  || fail "receipt output mode is not 0600"

"$TASK_UD_PYTHON" -c '
import hashlib
import json
import pathlib
import sys

receipt_path = pathlib.Path(sys.argv[1])
derived_path = pathlib.Path(sys.argv[2])
expected_raw_hash = sys.argv[3]
expected_raw_size = int(sys.argv[4])
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
derived = derived_path.read_bytes()
actual_derived = {"sha256": hashlib.sha256(derived).hexdigest(), "size": len(derived)}
if receipt.get("raw") != {"sha256": expected_raw_hash, "size": expected_raw_size}:
    raise SystemExit("receipt raw origin does not match the merged capture evidence")
if receipt.get("derived") != actual_derived:
    raise SystemExit("receipt/derived byte parity failed")
if receipt.get("outputSideCheck", {}).get("passed") is not True:
    raise SystemExit("receipt output-side check did not pass")
print("receipt_chain=PASS")
print("derived_sha256=" + actual_derived["sha256"])
print("derived_size=" + str(actual_derived["size"]))
print("receipt_sha256=" + hashlib.sha256(receipt_path.read_bytes()).hexdigest())
' "$TASK_UD_RECEIPT" "$TASK_UD_DERIVED" \
  "$TASK_UD_EXPECTED_RAW_SHA256" "$TASK_UD_EXPECTED_RAW_SIZE"

printf '\n%s\n' \
  'Redaction and mechanical receipt/hash checks PASS.' \
  "Staging directory: $TASK_UD_STAGE" \
  '' \
  'Required human steps:' \
  "  1. Review receipt: $TASK_UD_RECEIPT" \
  "  2. Review every derived byte/line: $TASK_UD_DERIVED" \
  '  3. Decide positive only if the fixture is repo-safe and the deterministic' \
  '     locator yields exactly one candidate with a non-secret format rule.' \
  '  4. Do not copy anything into the repository until that review is complete.' \
  '' \
  'Convenience commands:'
printf '  %q -m json.tool %q | /usr/bin/less\n' "$TASK_UD_PYTHON" "$TASK_UD_RECEIPT"
printf '  /usr/bin/less -- %q\n' "$TASK_UD_DERIVED"
printf '\nReply without raw/derived literals or the exact token:\n%s\n' \
  '  result=positive|negative' \
  '  privacy_review=pass|fail' \
  '  structural_family=<repo-safe description>' \
  '  locator_basis=<repo-safe structural rule>' \
  '  candidate_count=<number>' \
  '  candidate_format=<format only, no literal>'
