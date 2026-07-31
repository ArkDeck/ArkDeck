#!/usr/bin/env bash
#
# GJ-5 device window crib (CHG-2026-054, TASK-HTP-006).
#
# One human step: `task submit`. Everything after it is the product's own
# auto-drive loop, and this script only *reads* - it never calls
# `task reconcile`, so "the loop converged" cannot be an artefact of the
# operator turning the crank. That is the whole claim HTP-AC-18 makes, so the
# script is written to be unable to fake it.
#
# What it does not do, on purpose:
#   * it never reads or exports artifact bytes. HiLog is privacy-sensitive;
#     the run needs the harness to *measure* it on this host, not to print it.
#     Only names, sizes and digests are shown;
#   * it never issues a device command itself. Discovery, adoption, observation
#     and capture all go through the product, which is what "no person ran an
#     HDC command" means in the GJ-1 record;
#   * it masks the device serial in everything it prints, so a transcript can
#     be pasted into review without serial bytes entering the repository.
#
# Usage:
#   crib-gj5-window-r1.sh --self-test                    # host plumbing check, no device
#   crib-gj5-window-r1.sh [--hdc <path>] [--goal <text>] [--crash-signature <sig>]
#                         [--interval <seconds>] [--deadline <seconds>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)"
BIN_DIR="${REPO_ROOT}/Packages/ArkDeckKit/.build/debug"
HDC_PATH="${ARKDECK_HDC_PATH:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
GOAL="No new fatal signature and a live application across five bounded captures"
CRASH_SIGNATURE=""
AUTODRIVE_INTERVAL=5
POLL_SECONDS=10
DEADLINE_SECONDS=1800
SELF_TEST=0
SERIAL=""

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

say() { printf '\n=== %s ===\n' "$1"; }

# Everything printed goes through this: the serial never reaches a transcript.
mask() {
  if [[ -n "${SERIAL}" ]]; then
    sed -e "s/${SERIAL}/<serial-masked>/g"
  else
    cat
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --hdc) HDC_PATH="${2:?--hdc needs a path}"; shift 2 ;;
    --goal) GOAL="${2:?--goal needs text}"; shift 2 ;;
    --crash-signature) CRASH_SIGNATURE="${2:?--crash-signature needs a value}"; shift 2 ;;
    --interval) AUTODRIVE_INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    --deadline) DEADLINE_SECONDS="${2:?--deadline needs seconds}"; shift 2 ;;
    -h|--help) sed -n '3,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -x "${BIN_DIR}/arkdeck-agentd" ]] \
  || fail "build first: swift build --package-path Packages/ArkDeckKit"
[[ -x "${BIN_DIR}/arkdeck" ]] || fail "missing ${BIN_DIR}/arkdeck"
[[ -x "${HDC_PATH}" ]] || fail "hdc is not executable at ${HDC_PATH} (pass --hdc)"

PY="${REPO_ROOT}/.venv-sdd/bin/python"
[[ -x "${PY}" ]] || PY="$(command -v python3)"
[[ -x "${PY}" ]] || fail "no python3 available for reading JSON replies"

STATE_DIR="$(mktemp -d /private/tmp/arkdeck-gj5-window.XXXXXX)"
chmod 700 "${STATE_DIR}"
SOCKET="${STATE_DIR}/agentd.sock"
DAEMON_LOG="${STATE_DIR}/daemon.log"

cleanup() {
  if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
    kill "${DAEMON_PID}" 2>/dev/null || true
    wait "${DAEMON_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

jsonq() { "${PY}" -c "$1"; }

say "run identity"
printf 'repo HEAD:        %s\n' "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
printf 'hdc:              %s\n' "${HDC_PATH}"
printf 'hdc sha256:       %s\n' "$(shasum -a 256 "${HDC_PATH}" | cut -d' ' -f1)"
printf 'state dir:        %s (0700, discarded after the window)\n' "${STATE_DIR}"
printf 'auto-drive:       every %ss\n' "${AUTODRIVE_INTERVAL}"
printf 'sensitive opt-in: hilog.txt (measured on this host, never exported)\n'

# The one place this script talks to hdc: counting attached devices, so it can
# refuse to start an unattended run against an ambiguous or absent target.
# It is a availability probe, not part of the journey - the product does every
# device step that the run records.
if [[ "${SELF_TEST}" -eq 0 ]]; then
  say "attached devices (probe only)"
  mapfile -t TARGETS < <("${HDC_PATH}" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | grep -v '^$' || true)
  [[ "${#TARGETS[@]}" -eq 1 ]] \
    || fail "expected exactly one attached device, found ${#TARGETS[@]}; a window runs against one target"
  SERIAL="${TARGETS[0]}"
  printf 'one device attached: %s\n' "${SERIAL}" | mask
fi

say "starting the daemon"
ARKDECK_HDC_PATH="${HDC_PATH}" \
ARKDECK_HARNESS_AUTODRIVE_SECONDS="${AUTODRIVE_INTERVAL}" \
ARKDECK_HARNESS_SENSITIVE_EVIDENCE="hilog.txt" \
  "${BIN_DIR}/arkdeck-agentd" --state-dir "${STATE_DIR}" >"${DAEMON_LOG}" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 20); do
  [[ -S "${SOCKET}" ]] && break
  sleep 1
done
[[ -S "${SOCKET}" ]] || { cat "${DAEMON_LOG}" >&2; fail "daemon did not start"; }
grep -E 'auto-drive|sensitive evidence|listening' "${DAEMON_LOG}" | mask

say "runtime identity"
"${BIN_DIR}/arkdeck" doctor --socket "${SOCKET}" --json | mask

say "operation availability"
"${BIN_DIR}/arkdeck" operation list --socket "${SOCKET}" --json \
  | jsonq 'import json,sys
for o in json.load(sys.stdin):
    print("%-40s %-12s %s" % (o["reference"], o["availability"], (o.get("reasons") or [])[:1]))' \
  | mask

if [[ "${SELF_TEST}" -eq 1 ]]; then
  say "self-test result"
  printf 'plumbing OK: daemon started, socket served, doctor and operation list parsed.\n'
  printf 'device legs (adopt / submit / poll) are not exercised without a device.\n'
  exit 0
fi

say "adopting the attached device (product-driven, GJ-1 leg)"
# `device adopt` with no candidate lets the product decide: it either adopts
# outright, asks which candidate (one line per candidate), or asks a person for
# something. Each reply shape is handled explicitly rather than assumed.
ADOPT_JSON="$("${BIN_DIR}/arkdeck" device adopt --socket "${SOCKET}" --json)"
printf '%s\n' "${ADOPT_JSON}" | mask
OUTCOME="$(printf '%s' "${ADOPT_JSON}" | jsonq 'import json,sys; print(json.load(sys.stdin).get("outcome",""))')"
if [[ "${OUTCOME}" == "needsSelection" ]]; then
  CANDIDATE="$(printf '%s' "${ADOPT_JSON}" | jsonq 'import json,sys
rows=json.load(sys.stdin).get("candidates") or []
keys=[r.get("candidate") for r in rows if r.get("candidate")]
print(keys[0] if len(keys)==1 else "")')"
  [[ -n "${CANDIDATE}" ]] || fail "the product offered more than one candidate; a window runs against one"
  ADOPT_JSON="$("${BIN_DIR}/arkdeck" device adopt --socket "${SOCKET}" --candidate "${CANDIDATE}" --json)"
  printf '%s\n' "${ADOPT_JSON}" | mask
  OUTCOME="$(printf '%s' "${ADOPT_JSON}" | jsonq 'import json,sys; print(json.load(sys.stdin).get("outcome",""))')"
fi
if [[ "${OUTCOME}" == "waitingForHuman" ]]; then
  printf '%s\n' "${ADOPT_JSON}" \
    | jsonq 'import json,sys; d=json.load(sys.stdin); print(d.get("humanActionKind"), "->", d.get("prompt"))' \
    | mask
  fail "the product asked a person for something before adoption; resolve it and re-run"
fi
[[ "${OUTCOME}" == "adopted" ]] || fail "adoption outcome was ${OUTCOME:-<none>}"

read -r TARGET_ID BINDING_REVISION < <(printf '%s' "${ADOPT_JSON}" | jsonq 'import json,sys
d=json.load(sys.stdin); print(d["targetId"], d["bindingRevision"])')
[[ -n "${TARGET_ID:-}" && -n "${BINDING_REVISION:-}" ]] \
  || fail "adoption did not yield a durable target and binding revision"
printf 'target %s at binding revision %s\n' "${TARGET_ID}" "${BINDING_REVISION}" | mask
say "adopted targets (target.list projection)"
"${BIN_DIR}/arkdeck" device list --socket "${SOCKET}" --json | mask

say "THE ONE HUMAN STEP: task submit"
SUBMIT_ARGS=(task submit --socket "${SOCKET}" --target "${TARGET_ID}" --goal "${GOAL}"
  --expected-binding-revision "${BINDING_REVISION}" --json)
[[ -n "${CRASH_SIGNATURE}" ]] && SUBMIT_ARGS+=(--crash-signature "${CRASH_SIGNATURE}")
HTASK="$("${BIN_DIR}/arkdeck" "${SUBMIT_ARGS[@]}" | jsonq 'import json,sys; print(json.load(sys.stdin)["htaskId"])')"
[[ -n "${HTASK}" ]] || fail "submit returned no task id"
printf 'submitted %s\n' "${HTASK}"
printf 'from here on this script only reads. Reconcile calls issued: 0.\n'

say "watching (read-only) until the task reaches a terminal state"
ELAPSED=0
LAST=""
while :; do
  LINE="$("${BIN_DIR}/arkdeck" task status --socket "${SOCKET}" --task "${HTASK}" --json \
    | jsonq 'import json,sys
d=json.load(sys.stdin)
print("%s %s round=%s job=%s v=%s" % (d["status"], d["phase"], d["activeRound"], d.get("activeJobId"), d.get("version")))')"
  if [[ "${LINE}" != "${LAST}" ]]; then
    printf '[%4ss] %s\n' "${ELAPSED}" "${LINE}" | mask
    LAST="${LINE}"
  fi
  case "${LINE}" in
    succeeded*|failed*|cancelled*) break ;;
    humanRequired*) printf 'task is waiting on a person; auto-drive does not drive it further.\n'; break ;;
  esac
  (( ELAPSED >= DEADLINE_SECONDS )) && { printf 'deadline reached at %ss\n' "${ELAPSED}"; break; }
  sleep "${POLL_SECONDS}"
  ELAPSED=$((ELAPSED + POLL_SECONDS))
done

for surface in status result events evaluations memory humanActions; do
  say "task ${surface}"
  "${BIN_DIR}/arkdeck" task "${surface}" --socket "${SOCKET}" --task "${HTASK}" --json \
    | tee "${STATE_DIR}/task-${surface}.json" | mask
done

say "jobs the harness dispatched"
"${BIN_DIR}/arkdeck" job list --socket "${SOCKET}" --json | tee "${STATE_DIR}/jobs.json" | mask

say "artifact metadata per job (names, sizes, digests - never bytes)"
"${BIN_DIR}/arkdeck" job list --socket "${SOCKET}" --json \
  | jsonq 'import json,sys
rows=json.load(sys.stdin)
rows=rows if isinstance(rows,list) else (rows.get("jobs") or [])
for r in rows:
    print(r.get("jobId") or r.get("jobID") or "")' \
  | while read -r job; do
      [[ -n "${job}" ]] || continue
      printf -- '--- %s\n' "${job}"
      "${BIN_DIR}/arkdeck" artifact list --job "${job}" --socket "${SOCKET}" 2>&1 | mask
    done

say "capabilities (an E0 run must consume none)"
"${BIN_DIR}/arkdeck" capability list --socket "${SOCKET}" --json | mask

say "daemon log"
grep -E 'auto-drive|harness|sensitive' "${DAEMON_LOG}" | tail -40 | mask

say "window summary"
printf 'task:              %s\n' "${HTASK}"
printf 'reconcile calls:   0 (auto-drive only)\n'
printf 'human steps after handover: 0 (submit was the handover)\n'
printf 'json dumps kept in: %s\n' "${STATE_DIR}"
printf 'paste this transcript for review; it contains no serial and no artifact bytes.\n'
