#!/usr/bin/env bash
#
# GJ-1 + GJ-2 + GJ-5 device window crib (CHG-2026-054, TASK-HTP-006).
#
# One window, four legs, in an order a product fact dictates:
#
#   L1  adopt + observe on the *current* catalog digest        (GJ-1 re-take)
#   L2  import a signed HAP and run debug.hap@1 with           (GJ-2 re-take)
#       cleanupPolicy=retain, so the package stays installed
#   L3  harness task with the application live and no crash    (GJ-5 pass path)
#   L4  harness task after the WaterFlow crash is reproduced   (GJ-5 fail path)
#
# L3 must run *before* the crash is triggered. `capture.diagnostics@1` lowers
# HiLog to `hilog -x`, which dumps the whole rolling buffer rather than tailing
# a window - so once a fault block is in the buffer it appears in *every*
# later capture, and a clean five-sample pass becomes unreachable until the
# buffer rolls. Reversing these two legs would cost the window.
#
# Human steps, all of them before a handover rather than inside a loop:
#   * starting the application on the device (no product operation leaves an
#     ability running: debug.hap@1 always runs its stop-ability step);
#   * performing the gesture that reproduces the WaterFlow crash;
#   * the two `task submit` calls, which *are* the handovers.
# After each submit this script only reads. It never calls `task reconcile`,
# so "the loop converged" cannot be an artefact of the operator turning the
# crank - which is the whole claim HTP-AC-18 makes.
#
# It also never reads or exports artifact bytes (HiLog is privacy-sensitive:
# the run needs the harness to *measure* it on this host, not to print it),
# issues no device command of its own beyond counting attached devices, and
# masks the serial in everything it prints.
#
# The E1 leg needs a capability, and a capability cannot be pre-written: it
# pins `exactPlanDigest` and an exact value per input, including the artifact
# lease that only exists once the HAP is imported against this target. So the
# window runs in two passes:
#
#   pass 1  --hap <signed.hap>            -> L1, import, `capability draft`,
#                                            then stops. The draft's
#                                            issuer.reference is
#                                            PENDING-MAINTAINER-PR and the
#                                            daemon refuses to install it.
#   maintainer                             -> commit the draft under this
#                                            change's evidence/capabilities/,
#                                            set issuer.reference to "PR#<n>",
#                                            merge. The merge is the issuance.
#   pass 2  --hap … --capability <file>   -> L1..L4 end to end.
#
# Usage:
#   crib-gj5-window-r1.sh --self-test [--hdc <path>]
#   crib-gj5-window-r1.sh --hap <signed.hap> [--capability <CAP-RT-...json>]
#                         [--hdc <path>] [--bundle <name>] [--ability <name>]
#                         [--crash-signature <SIGx+Symbol>]
#                         [--interval <seconds>] [--deadline <seconds>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)"
BIN_DIR="${REPO_ROOT}/Packages/ArkDeckKit/.build/debug"
HDC_PATH="${ARKDECK_HDC_PATH:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
HAP_PATH=""
CAPABILITY_FILE=""
BUNDLE="com.example.waterflowdemo"
ABILITY="EntryAbility"
# The signature the demo's built-in crash probe produces
# (entry/src/main/ets/crashprobe/CrashProbe.ets). Declaring it makes DC-1, the
# "this exact crash is absent" criterion, the one that decides L4 - not merely
# DC-3's "some new fatal signature appeared".
CRASH_SIGNATURE="SIGABRT+WaterFlowCrashProbe_RecoverBack"
AUTODRIVE_INTERVAL=5
POLL_SECONDS=10
DEADLINE_SECONDS=1200
SELF_TEST=0
SERIAL=""
PHASE="all"
REQUESTED_STATE_DIR=""

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
say() { printf '\n=== %s ===\n' "$1"; }
mask() { if [[ -n "${SERIAL}" ]]; then sed -e "s/${SERIAL}/<serial-masked>/g"; else cat; fi; }

pause_for_human() {
  printf '\n--- HUMAN STEP: %s\n' "$1"
  read -r -p '    press Enter when done (Ctrl-C to abandon the window): ' _
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --phase) PHASE="${2:?--phase needs l1l2|l3|l4|all}"; shift 2 ;;
    --state-dir) REQUESTED_STATE_DIR="${2:?--state-dir needs a path}"; shift 2 ;;
    --hdc) HDC_PATH="${2:?--hdc needs a path}"; shift 2 ;;
    --hap) HAP_PATH="${2:?--hap needs a path}"; shift 2 ;;
    --capability) CAPABILITY_FILE="${2:?--capability needs a path}"; shift 2 ;;
    --bundle) BUNDLE="${2:?--bundle needs a name}"; shift 2 ;;
    --ability) ABILITY="${2:?--ability needs a name}"; shift 2 ;;
    --crash-signature) CRASH_SIGNATURE="${2:?--crash-signature needs a value}"; shift 2 ;;
    --interval) AUTODRIVE_INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    --deadline) DEADLINE_SECONDS="${2:?--deadline needs seconds}"; shift 2 ;;
    -h|--help) sed -n '3,58p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -x "${BIN_DIR}/arkdeck-agentd" ]] \
  || fail "build first: swift build --package-path Packages/ArkDeckKit"
[[ -x "${BIN_DIR}/arkdeck" ]] || fail "missing ${BIN_DIR}/arkdeck"
[[ -x "${HDC_PATH}" ]] || fail "hdc is not executable at ${HDC_PATH} (pass --hdc)"
if [[ "${SELF_TEST}" -eq 0 && ( "${PHASE}" == "all" || "${PHASE}" == "l1l2" ) ]]; then
  [[ -f "${HAP_PATH}" ]] || fail "--hap <signed.hap> is required for the l1l2 phase"
  if [[ -n "${CAPABILITY_FILE}" ]]; then
    [[ -f "${CAPABILITY_FILE}" ]] || fail "--capability points at no file: ${CAPABILITY_FILE}"
  fi
fi

case "${PHASE}" in
  all|l1l2|l3|l4) ;;
  *) fail "--phase must be one of: all l1l2 l3 l4" ;;
esac

PY="${REPO_ROOT}/.venv-sdd/bin/python"
[[ -x "${PY}" ]] || PY="$(command -v python3)"
[[ -x "${PY}" ]] || fail "no python3 available for reading JSON replies"
jsonq() { "${PY}" -c "$1"; }

if [[ -n "${REQUESTED_STATE_DIR}" ]]; then
  # Phases share one daemon-owned directory: adoption, the imported artifact
  # and the installed capability all live in it, so a later phase must reuse
  # it rather than start clean.
  STATE_DIR="${REQUESTED_STATE_DIR}"
  mkdir -p "${STATE_DIR}"
else
  [[ "${PHASE}" == "all" ]] \
    || fail "--phase ${PHASE} needs --state-dir <the directory the earlier phase used>"
  STATE_DIR="$(mktemp -d /private/tmp/arkdeck-gj5-window.XXXXXX)"
fi
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

say "run identity"
printf 'repo HEAD:        %s\n' "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
printf 'hdc:              %s\n' "${HDC_PATH}"
printf 'hdc sha256:       %s\n' "$(shasum -a 256 "${HDC_PATH}" | cut -d' ' -f1)"
if [[ -n "${HAP_PATH}" ]]; then
  printf 'hap:              %s (%s bytes)\n' "$(basename "${HAP_PATH}")" "$(wc -c <"${HAP_PATH}" | tr -d ' ')"
  printf 'hap sha256:       %s\n' "$(shasum -a 256 "${HAP_PATH}" | cut -d' ' -f1)"
fi
printf 'state dir:        %s (0700, discarded after the window)\n' "${STATE_DIR}"
printf 'auto-drive:       every %ss\n' "${AUTODRIVE_INTERVAL}"
printf 'sensitive opt-in: hilog.txt (measured on this host, never exported)\n'

# The only place this script talks to hdc: refusing to run unattended against
# an ambiguous or absent target. An availability probe, not part of any leg -
# every device step the record claims is performed by the product.
#
# Written for bash 3.2, which is what macOS ships as /bin/bash: no `mapfile`,
# no associative arrays. The first attempt used `mapfile` and died here with
# "command not found" - on the real window run, because --self-test skipped
# this block. The parser is now a function the self-test exercises.
parse_targets() {
  tr -d '\r' | grep -v '^\[Empty\]$' | grep -v '^[[:space:]]*$' || true
}

count_lines() {
  local text="$1"
  if [[ -z "${text}" ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "${text}" | grep -c . || true
}

if [[ "${SELF_TEST}" -eq 1 ]]; then
  say "probe parser self-check (fixtures, no device needed)"
  one="$(printf '150100424a544434520325874bbf4900\r\n' | parse_targets)"
  [[ "$(count_lines "${one}")" -eq 1 ]] || fail "parser lost a target line"
  [[ "${one}" == "150100424a544434520325874bbf4900" ]] || fail "parser mangled the target"
  [[ "$(count_lines "$(printf '[Empty]\n' | parse_targets)")" -eq 0 ]] \
    || fail "parser counted [Empty] as a device"
  [[ "$(count_lines "$(printf 'a\nb\n' | parse_targets)")" -eq 2 ]] \
    || fail "parser miscounted two devices"
  printf 'parser: one target, [Empty], and two targets all counted correctly\n'
else
  say "attached devices (probe only)"
  TARGET_LIST="$("${HDC_PATH}" list targets 2>/dev/null | parse_targets)"
  TARGET_COUNT="$(count_lines "${TARGET_LIST}")"
  [[ "${TARGET_COUNT}" -eq 1 ]] \
    || fail "expected exactly one attached device, found ${TARGET_COUNT}; a window runs against one target"
  SERIAL="${TARGET_LIST}"
  printf 'one device attached: %s\n' "${SERIAL}" | mask
fi

say "starting the daemon"
ARKDECK_HDC_PATH="${HDC_PATH}" \
ARKDECK_HARNESS_AUTODRIVE_SECONDS="${AUTODRIVE_INTERVAL}" \
ARKDECK_HARNESS_SENSITIVE_EVIDENCE="hilog.txt" \
  "${BIN_DIR}/arkdeck-agentd" --state-dir "${STATE_DIR}" >"${DAEMON_LOG}" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 20); do [[ -S "${SOCKET}" ]] && break; sleep 1; done
[[ -S "${SOCKET}" ]] || { cat "${DAEMON_LOG}" >&2; fail "daemon did not start"; }
grep -E 'auto-drive|sensitive evidence|listening' "${DAEMON_LOG}" | mask

say "runtime identity (catalog digest must be the one under review)"
"${BIN_DIR}/arkdeck" doctor --socket "${SOCKET}" --json | tee "${STATE_DIR}/doctor.json" | mask

say "operation availability"
"${BIN_DIR}/arkdeck" operation list --socket "${SOCKET}" --json \
  | tee "${STATE_DIR}/operations.json" \
  | jsonq 'import json,sys
for o in json.load(sys.stdin):
    print("%-40s %-12s %s" % (o["reference"], o["availability"], (o.get("reasons") or [])[:1]))' \
  | mask

if [[ "${SELF_TEST}" -eq 1 ]]; then
  say "self-test result"
  printf 'plumbing OK: daemon started, socket served, doctor and operation list parsed.\n'
  printf 'legs L1..L4 need a device, a signed HAP and an issued capability.\n'
  exit 0
fi

############################ L1 — GJ-1 re-take ################################

if [[ "${PHASE}" == "all" || "${PHASE}" == "l1l2" ]]; then

say "L1: adopting the attached device (product-driven)"
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
    | jsonq 'import json,sys; d=json.load(sys.stdin); print(d.get("humanActionKind"), "->", d.get("prompt"))' | mask
  fail "the product asked a person for something before adoption; resolve it and re-run"
fi
[[ "${OUTCOME}" == "adopted" ]] || fail "adoption outcome was ${OUTCOME:-<none>}"
read -r TARGET_ID BINDING_REVISION < <(printf '%s' "${ADOPT_JSON}" \
  | jsonq 'import json,sys; d=json.load(sys.stdin); print(d["targetId"], d["bindingRevision"])')
printf 'target %s at binding revision %s\n' "${TARGET_ID}" "${BINDING_REVISION}" | mask

say "L1: observe.device@1 (E0, product-driven)"
# The revision is pinned explicitly: admission requires it for every
# device-bound operation, and pinning what adoption just reported keeps a
# rebind between these two lines a refusal rather than a surprise.
"${BIN_DIR}/arkdeck" job submit --socket "${SOCKET}" --target "${TARGET_ID}" \
  --operation observe.device@1 --expected-binding-revision "${BINDING_REVISION}" \
  --wait --json | tee "${STATE_DIR}/l1-observe.json" | mask

############################ L2 — GJ-2 re-take ################################

say "L2: importing the signed HAP into the daemon-owned artifact store"
"${BIN_DIR}/arkdeck" artifact import-hap --socket "${SOCKET}" --target "${TARGET_ID}" \
  --file "${HAP_PATH}" --json | tee "${STATE_DIR}/l2-hap-lease.json" | mask
# `hapArtifactLease` takes the *lease*, not the artifact id: the import reply
# carries both, and the lease is the ID-only reference bound to this target.
LEASE="$(jsonq 'import json,sys
d=json.load(open("'"${STATE_DIR}"'/l2-hap-lease.json"))
print(d.get("lease") or "")')"
[[ -n "${LEASE}" ]] || {
  cat "${STATE_DIR}/l2-hap-lease.json" | mask
  fail "the import returned no artifact lease"
}

# The typed inputs are fixed here and never edited afterwards: a capability
# pins `exactPlanDigest` and an exact value per input, so changing any input
# after the draft invalidates the authorization.
cat >"${STATE_DIR}/l2-inputs.json" <<JSON
{
  "hapArtifactLease": "${LEASE}",
  "bundleName": "${BUNDLE}",
  "abilityName": "${ABILITY}",
  "installPolicy": "installOrReplace",
  "cleanupPolicy": "retain",
  "postRunAbilityState": "running",
  "captureDiagnostics": true,
  "diagnosticsDurationSeconds": 5
}
JSON
"${PY}" -c 'import json,sys; json.load(open(sys.argv[1]))' "${STATE_DIR}/l2-inputs.json" \
  || fail "the generated L2 inputs file is not valid JSON"

if [[ -z "${CAPABILITY_FILE}" ]]; then
  say "L2: drafting the capability the E1 leg needs (the product computes it)"
  # A draft cannot authorize anything: the daemon writes
  # issuer.reference = PENDING-MAINTAINER-PR, and `capability install` refuses
  # any reference that is not `PR#<number>`. That refusal is what makes
  # issuance a maintainer act rather than an agent one.
  "${BIN_DIR}/arkdeck" capability draft --socket "${SOCKET}" --target "${TARGET_ID}" \
    --operation debug.hap@1 --inputs-file "${STATE_DIR}/l2-inputs.json" \
    --output-directory "${STATE_DIR}/drafts" --validity-seconds 14400 --maximum-uses 1 --json \
    | tee "${STATE_DIR}/l2-capability-draft.json" | mask
  printf '\n'
  printf 'MAINTAINER STEP (issuance):\n'
  printf '  1. copy this draft to openspec/changes/chg-2026-054-agent-harness-task-plane/\n'
  printf '     evidence/capabilities/<capabilityID>.json\n'
  printf '  2. set issuer.reference to the PR that carries it, exactly "PR#<number>"\n'
  printf '  3. merge that PR - the merge is the issuance\n'
  printf '  4. re-run this script with --capability <that file> (the lease and plan digest\n'
  printf '     are recomputed identically as long as the HAP and target are unchanged)\n'
  fail "no issued capability yet; the window pauses here by design"
fi

# A capability pins the exact lease, which encodes the exact HAP bytes. If the
# application was rebuilt since the draft, the kernel denies the request with
# `inputConstraintViolated` - correct, but only after a round trip. Measured on
# the 2026-07-31 window: the demo app was rebuilt ten minutes after the draft
# was taken, and the denial was the first sign of it. Say it here instead.
CAP_PINNED_LEASE="$(jsonq 'import json,sys
d=json.load(open("'"${CAPABILITY_FILE}"'"))
print(((d.get("inputConstraints") or {}).get("hapArtifactLease") or {}).get("value") or "")')"
if [[ -n "${CAP_PINNED_LEASE}" && "${CAP_PINNED_LEASE}" != "${LEASE}" ]]; then
  printf 'capability pins lease: %s\n' "${CAP_PINNED_LEASE}"
  printf 'this run imported:     %s\n' "${LEASE}"
  fail "the HAP on disk is not the one this capability authorizes (it was rebuilt); \
re-run --phase l1l2 without --capability to draft against the current bytes"
fi

say "L2: installing the maintainer-issued capability"
CAP_ISSUER="$(jsonq 'import json,sys; print(json.load(open("'"${CAPABILITY_FILE}"'"))["issuer"]["reference"])')"
[[ "${CAP_ISSUER}" == PR#* ]] \
  || fail "issuer.reference is ${CAP_ISSUER}; the daemon only installs a merged-PR reference"
"${BIN_DIR}/arkdeck" capability install --socket "${SOCKET}" --file "${CAPABILITY_FILE}" --json | mask
"${BIN_DIR}/arkdeck" capability list --socket "${SOCKET}" --json \
  | tee "${STATE_DIR}/l2-capabilities-before.json" | mask

say "L2: debug.hap@1 with cleanupPolicy=retain (E1, maintainer-authorized)"
CAP_ID="$(jsonq 'import json,sys; print(json.load(open("'"${CAPABILITY_FILE}"'"))["capabilityID"])')"
# The document shape is the engine's, not an invented one: documentType /
# schemaVersion / requestId / idempotencyKey / target / operation / inputs /
# authorization.capabilityId (see RuntimeOperationRequest).
WINDOW_STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
"${PY}" - "${STATE_DIR}" "${TARGET_ID}" "${BINDING_REVISION}" "${WINDOW_STAMP}" "${CAP_ID}" <<'PYEOF'
import json, sys
state, target, revision, stamp, capability = sys.argv[1:6]
inputs = json.load(open(f"{state}/l2-inputs.json"))
document = {
    "documentType": "runtime-operation-request",
    "schemaVersion": "2.0.0",
    "requestId": f"req-gj5-window-{stamp}",
    "idempotencyKey": f"idem-gj5-window-{stamp}",
    "target": {"targetId": target, "expectedBindingRevision": int(revision)},
    "operation": {"id": "debug.hap", "version": 1},
    "inputs": inputs,
    "authorization": {"capabilityId": capability},
}
json.dump(document, open(f"{state}/l2-request.json", "w"), indent=2, sort_keys=True)
PYEOF
"${BIN_DIR}/arkdeck" job submit --socket "${SOCKET}" --request-file "${STATE_DIR}/l2-request.json" \
  --wait --json | tee "${STATE_DIR}/l2-debug-hap.json" | mask
printf 'the package is retained and, with postRunAbilityState=running, the ability is left running.\n'

  if [[ "${PHASE}" == "l1l2" ]]; then
    say "phase l1l2 complete"
    printf 'state dir (pass it to the next phase): %s\n' "${STATE_DIR}"
    printf '\nthe application is already running (postRunAbilityState=running), so --phase l3\n'
    printf 'can follow immediately. Do not reproduce the crash until L3 has passed.\n'
    exit 0
  fi
else
  say "reusing the adopted target from ${STATE_DIR}"
  read -r TARGET_ID BINDING_REVISION < <("${BIN_DIR}/arkdeck" device list --socket "${SOCKET}" --json \
    | jsonq 'import json,sys
rows=json.load(sys.stdin)
rows=rows if isinstance(rows,list) else (rows.get("targets") or [])
if len(rows) != 1:
    raise SystemExit("expected exactly one adopted target, found %d" % len(rows))
print(rows[0]["targetId"], rows[0]["bindingRevision"])')
  [[ -n "${TARGET_ID:-}" && -n "${BINDING_REVISION:-}" ]] \
    || fail "no adopted target in ${STATE_DIR}; run --phase l1l2 first"
  printf 'target %s at binding revision %s\n' "${TARGET_ID}" "${BINDING_REVISION}" | mask
fi

############################ L3 — GJ-5, clean #################################

if [[ "${PHASE}" == "all" ]]; then
  pause_for_human "start ${BUNDLE} on the device and leave it on the WaterFlow screen WITHOUT reproducing the crash"
fi

watch_task() {
  local htask="$1" elapsed=0 last="" line
  while :; do
    line="$("${BIN_DIR}/arkdeck" task status --socket "${SOCKET}" --task "${htask}" --json \
      | jsonq 'import json,sys
d=json.load(sys.stdin)
print("%s %s round=%s job=%s v=%s" % (d["status"], d["phase"], d["activeRound"], d.get("activeJobId"), d.get("version")))')"
    if [[ "${line}" != "${last}" ]]; then
      printf '[%4ss] %s\n' "${elapsed}" "${line}" | mask
      last="${line}"
    fi
    case "${line}" in
      succeeded*|failed*|cancelled*|humanRequired*) break ;;
    esac
    if (( elapsed >= DEADLINE_SECONDS )); then
      printf 'deadline reached at %ss\n' "${elapsed}"
      break
    fi
    sleep "${POLL_SECONDS}"
    elapsed=$((elapsed + POLL_SECONDS))
  done
}

dump_task() {
  local htask="$1" tag="$2" surface
  for surface in status result events evaluations memory humanActions; do
    say "${tag}: task ${surface}"
    "${BIN_DIR}/arkdeck" task "${surface}" --socket "${SOCKET}" --task "${htask}" --json \
      | tee "${STATE_DIR}/${tag}-task-${surface}.json" | mask
  done
  say "${tag}: jobs and artifact metadata (names, sizes, digests - never bytes)"
  "${BIN_DIR}/arkdeck" job list --socket "${SOCKET}" --json | tee "${STATE_DIR}/${tag}-jobs.json" \
    | jsonq 'import json,sys
rows=json.load(sys.stdin)
rows=rows if isinstance(rows,list) else (rows.get("jobs") or [])
for r in rows:
    print("%s %s %s" % (r.get("jobId",""), r.get("operation",""), r.get("state","")))' | mask
  "${BIN_DIR}/arkdeck" job list --socket "${SOCKET}" --json \
    | jsonq 'import json,sys
rows=json.load(sys.stdin)
rows=rows if isinstance(rows,list) else (rows.get("jobs") or [])
for r in rows:
    print(r.get("jobId") or "")' \
    | while read -r job; do
        [[ -n "${job}" ]] || continue
        printf -- '--- %s\n' "${job}"
        "${BIN_DIR}/arkdeck" artifact list --job "${job}" --socket "${SOCKET}" 2>&1 | mask
      done
}

if [[ "${PHASE}" == "l4" ]]; then
  say "skipping L3 (already run in its own phase)"
else
say "L3: THE HANDOVER — one task submit, application live, no crash yet"
HTASK_CLEAN="$("${BIN_DIR}/arkdeck" task submit --socket "${SOCKET}" --target "${TARGET_ID}" \
  --goal "No fatal signature and a live application across five bounded captures" \
  --expected-binding-revision "${BINDING_REVISION}" --json \
  | jsonq 'import json,sys; print(json.load(sys.stdin)["htaskId"])')"
printf 'submitted %s. Reconcile calls from here: 0.\n' "${HTASK_CLEAN}"
watch_task "${HTASK_CLEAN}"
printf 'expected: succeeded, via five clean captures and an evaluator PASS.\n'
dump_task "${HTASK_CLEAN}" "l3-clean"
if [[ "${PHASE}" == "l3" ]]; then
  say "phase l3 complete"
  printf 'state dir (pass it to the next phase): %s\n' "${STATE_DIR}"
  printf '\nHUMAN STEP before --phase l4: reproduce the WaterFlow crash on the device.\n'
  exit 0
fi
fi

############################ L4 — GJ-5, crash present #########################

if [[ "${PHASE}" == "all" ]]; then
  pause_for_human "make sure the WaterFlow crash has been reproduced (with the launch crash probe built in, the application aborts itself ~12s after start and nothing needs doing)"
fi

say "L4: THE SECOND HANDOVER — one task submit, crash present"
SUBMIT_ARGS=(task submit --socket "${SOCKET}" --target "${TARGET_ID}"
  --goal "The declared WaterFlow crash must be absent across five bounded captures"
  --expected-binding-revision "${BINDING_REVISION}" --json)
if [[ -n "${CRASH_SIGNATURE}" ]]; then
  SUBMIT_ARGS+=(--crash-signature "${CRASH_SIGNATURE}")
fi
HTASK_CRASH="$("${BIN_DIR}/arkdeck" "${SUBMIT_ARGS[@]}" \
  | jsonq 'import json,sys; print(json.load(sys.stdin)["htaskId"])')"
printf 'submitted %s. Reconcile calls from here: 0.\n' "${HTASK_CRASH}"
watch_task "${HTASK_CRASH}"
printf 'expected: humanRequired with criteriaFailedNoRepairCapability - a real crash judged\n'
printf 'from real device bytes, handed back because the repair leg is not wired yet.\n'
dump_task "${HTASK_CRASH}" "l4-crash"

############################ teardown ########################################

say "capabilities after the window (an E0 harness task must consume none)"
"${BIN_DIR}/arkdeck" capability list --socket "${SOCKET}" --json | tee "${STATE_DIR}/capabilities-after.json" | mask

say "daemon log (auto-drive decisions)"
grep -E 'auto-drive|harness|sensitive' "${DAEMON_LOG}" | tail -60 | mask

say "window summary"
printf 'target:            %s at binding revision %s\n' "${TARGET_ID}" "${BINDING_REVISION}"
printf 'L3 clean task:     %s\n' "${HTASK_CLEAN:-<its own phase>}"
printf 'L4 crash task:     %s\n' "${HTASK_CRASH}"
printf 'reconcile calls:   0 (auto-drive only)\n'
printf 'human steps:       app start, crash gesture, two submits - all before a handover\n'
printf 'json dumps kept in: %s\n' "${STATE_DIR}"
printf '\nSTILL TO DO BY HAND: uninstall %s (debug.hap@1 with cleanupPolicy=uninstall needs\n' "${BUNDLE}"
printf 'another authorized use) so the device returns to its pre-window state.\n'
printf 'Paste this transcript for review; it contains no serial and no artifact bytes.\n'
