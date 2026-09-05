# TASK-SVC-003 execution record

Status: local implementation and required unified verification complete.
TASK-SVC-003 is marked done in this delivery for maintainer review. No
protected-main approval, change verification or hardware acceptance is claimed.

Base: `a4cdda44c14751b7533947d8004fd3388d95df16` (SVC-002 merged, #1739).
Branch: `agent/task-svc-003-single-v1-formats-20260905`. The working tree was
clean at the start; every change travels in one vertical commit.

## Delivered behavior

- **Hardware evidence record (SVC-AC-07).** `HardwareEvidenceV6Record` is now
  `HardwareEvidenceRecord`, labelled exactly `1.0.0` through one constant the
  writer uses. Every safety correlation of the previous complete layout is
  retained unchanged: executor and admission authority, fresh
  `machineReadback` target confirmation, reservation and use ordinal, actual
  typed step kinds, plan/step-set/target-binding/Artifact digests, and the
  complete-overwrite recovery lineage with uncertain effects, coverage,
  supersession, postflight and the `recovered` terminal disposition.
  `openspec/contracts/hardware-evidence.schema.json` carries the same label
  (`$id` `.../hardware-evidence/1.0.0`, `schemaVersion` const `1.0.0`) and is
  otherwise the same closed shape. The test-only six-version discriminator
  (`HardwareEvidenceDocumentReader`, V1..V6) is deleted. A strict reader
  (`HardwareEvidenceRecord.decode`) accepts only the current complete record:
  another label is refused by version; the same `1.0.0` label over the
  historical human-operator layout, an undeclared member, or a duplicated
  member is refused by shape; refused bytes are never rewritten. Retired
  authority labels cannot publish evidence (named refusal, see below), and the
  historical campaign correlation fields the daemon no longer emits
  (`campaignId`, `attemptId`, `attemptOrdinal`, `candidateDigest`,
  `reviewDigest`, `brokerDigest`) are removed from the client authority model.
  The `job.evidence` wire result is unchanged.
- **Debug invocation and permit (SVC-AC-08).** `RuntimeDebugInvocationDocument`
  and `RuntimeDebugAttemptPermitRecord` are labelled `1.0.0` and are read
  through the current strict durable decoder: the retired `2.0.0` label, a
  `1.0.0` label over the retired tuning-record layout, and any undeclared member
  are refused with a named `persistenceFailure`, and the stored bytes stay as
  written. Epoch budgets, exact request fingerprints, active-window checks and
  the `recovery.flash-invocation.list` projection are unchanged.
- **Manual developer tool formats (SVC-AC-08).** The manual UI Flash driver's
  candidate program and debug-session record are labelled `1.0.0`
  (`manual-ui-flash-candidate-program`, `manual-ui-flash-debug-session`); the
  published candidate JSON carries the label, a candidate with another label is
  refused before any UI action is interpreted, and a stored session with
  another label cannot be resumed. The driver remains a development tool and is
  not a real-device acceptance path.
- **Internal bound Rockchip descriptors (SVC-AC-08).**
  `rockchip.hdc.wait-bound-reconnect` and `rockchip.hdc.verify-bound-build`
  carry the `.v1` label like every other host-managed action. Lowering,
  `operation.effect`, profiles, partition plans and Provider coverage are
  unchanged; the validating host still derives the expected identifier from the
  one catalog table and refuses a descriptor carrying the retired `.v2` label
  before preparation or execution. `rockchip.verifyBuild` (retired unbound
  verification) and the pre-CHG-2026-059 direct flash intents remain refused by
  name; the bound identity cannot degrade into either.
- **Naming and comments.** The `JobState` vocabulary comment no longer
  describes a versioned recovery writer; the `PersistedTypedProviderAction`
  comment no longer names a `.v2` verification; the invocation-list design note
  states that only the current `1.0.0` document is readable.

## Scope

Every changed path is inside the TASK-SVC-003 Allowed paths; no scope
supplement was needed. One single-v1 cleanup could not be completed inside the
allowlist and is recorded, with its exact diff, in [scope-review.md](scope-review.md):
the two retired authority labels remain in `RuntimeHardwareEvidenceAuthorityKind`
as named refusals because removing them touches
`HeadlessRuntimeVerifier.swift`. Nothing under `Catalog/**`,
`openspec/specs/**`, `spec/control/methods/**`, generated CLI contracts or
`runtime-control-plane.schema.json` changed: this Task changes no wire shape.

## Verification

Commands ran from the repository root on 2026-09-05. Logs under the session
scratch directory are development logs, not hardware evidence.

| Command / check | Result |
| --- | --- |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build --build-tests` | PASS after two compile fixes in the new test (missing `await` on the actor-isolated `status(invocationID:)`). |
| Focused suites: `HardwareEvidenceProjectionContractTests`, `RuntimeDebugInvocationContractTests`, `RuntimeCandidateDecisionContractTests`, `ManualUIFlashDriverContractTests`, `RockchipRuntimeCompositionContractTests`, `ArkForgeControlPerformerContractTests`, `DeviceProviderContractTests`, `ArchitectureBoundaryContractTests`, `JobStateMachineTests`, `ControlMethodSchemaContractTests`, `AgentRuntimeExecutorContractTests`, `HeadlessRuntimeVerifierContractTests` | First run: two failures, both genuine and fixed (below). Rerun of the two affected suites: PASS, exit 0, zero failures. |
| `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | PASS, exit 0: no generated contract drift; `spec/control/methods` untouched. |
| `git diff --check` | PASS. |
| `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local` | **PASS**, exit 0. Public checks (planner tests, Agent PR workflow tests, `check_sdd` 0 errors, guard suites): PASS. Design-system lane: `npm ci` + `npm test`, 83 passing, 0 failing. Swift lanes: full-parallel 2,434 cases (exit 0, 85 s), process-identity race 1 case, Viewer scale 5 cases, all exit 0. App lane: `TEST BUILD SUCCEEDED`. The gate started before the two evidence documents were written; `sh scripts/check-sdd.sh` was rerun on the final tree afterwards (0 errors, 0 warnings). Log: session scratch `svc003-unified-gate.log`. |
| `python3 scripts/check_pr_paths.py --repo-root . --preflight --base-revision origin/main --head-revision HEAD --expected-head-ref agent/task-svc-003-single-v1-formats-20260905 --allow-bootstrap --infer-task` | **PASS**: resolves exactly `TASK-SVC-003`, exit 0, on the committed diff (17 changed paths, all inside the Task's base-tree Allowed paths). Rerun after the final documentation amend. |

Development failures resolved before the final run:

- `DeviceProviderContractTests.testRockchipMaterializesEveryPublishedRuntimeStepWithoutLegacyAuthorization`
  carried the historical positive matrix requiring the two bound descriptors to
  end in `.v2`. The matrix now requires `.v1` for every Rockchip host-managed
  descriptor, refuses `.v2`, and pins the two bound identifiers exactly.
- The new invocation-document test first relabelled every `schemaVersion` in the
  stored document, including the nested seed request, so the refusal it observed
  came from the request decoder. It now rewrites only the document-level label
  (the key the canonical writer places before `seedRequest`), which proves the
  document's own refusal.

No UI assertion or device operation was executed: this Task changes host
formats and their readers. Hardware acceptance of the published product remains
SVC-005; no `REAL_DEVICE_PASS` is claimed, and no historical Catalog result is
relabelled.

## Acceptance results

| Acceptance | Result and evidence |
| --- | --- |
| SVC-AC-07 evidence integrity | PASS on host fixtures: read-only, capability mutation, distinct recovery and historical-recognition records project at `1.0.0` and validate structurally against the current schema (every encoded member declared by a closed schema object, every required member present, enum/const/pattern satisfied); missing digest/step/target/reservation/coverage/supersession facts and lineage drift refuse; retired authority kinds refuse by name; the strict reader refuses other labels, same-label historical layouts, undeclared and duplicated members without rewriting bytes. Fixture results only; no real Runtime record is referenced here. |
| SVC-AC-08 internal formats | PASS on host fixtures: debug permit and invocation document are `1.0.0` with exact-shape reads and named refusals of `2.0.0` and retired-layout `1.0.0`; manual candidate/session documents are `1.0.0` and a `2.0.0` candidate is refused by the interpreted driver; all ten host-managed Rockchip identifiers are `.v1`, digests are recomputed by the same catalog, a `.v2` descriptor is refused by the validating host with zero executor calls, and the retired unbound verification and legacy flash intents stay refused. External versions (ArkForge, ArkTrace, HDC, SDK, code-sign format, `sqlite3_*_v2`) are untouched. |

## Residual audit (SVC-003 scope)

| Match | Disposition |
| --- | --- |
| `HardwareEvidenceV6Record`, `schemaVersion: "6.0.0"`, `HardwareEvidenceDocumentReader` (V1..V6) | Removed; `HardwareEvidenceRecord` at `1.0.0` is the only record. |
| `arkdeck://contracts/hardware-evidence/6.0.0`, schema title `(V6, CHG-2026-056 r7)` | Replaced by the `1.0.0` `$id` and `(current v1)` title. |
| `RuntimeHardwareEvidenceAuthorityKind.standingAuthorization`, `.evolutionCampaignConfirmation` | Retained as named refusals only; removal needs one line outside the allowlist, recorded in [scope-review.md](scope-review.md). |
| `RuntimeHardwareEvidenceAuthority` campaign fields | Removed; the daemon never emits them and no current consumer read them. |
| `RuntimeDebugAttemptPermitRecord` / `RuntimeDebugInvocationDocument` `"2.0.0"` | Replaced by `1.0.0` with strict current-shape reads. |
| `manual-ui-flash-candidate-program` `"2.0.0"`, `manual-ui-flash-debug-session` `"3.0.0"` | Replaced by `1.0.0`; candidate JSON and driver updated together. |
| `rockchip.hdc.wait-bound-reconnect.v2`, `rockchip.hdc.verify-bound-build.v2` | Replaced by `.v1`; the catalog comment names `.v2` only as history, and one test constructs it as the refused negative vector. |
| `PersistedTypedProviderAction.legacyRockchipLoweringKinds`, `retiredUnboundBuildVerificationKind`, retired direct Rockchip reset in `RockchipRuntimeActionHost` | Retained: these are refusals by name of retired intents, required by this Task, not compatibility readers. |
| `RuntimeHardwareEvidenceObservation` optionals (`targetId`, `bindingRevision`, `stableIdentitySha256`, `model`, `firmware`, `transport`, `confirmedAtUtc`) | Retained as optionals: partial read-only observations are legitimate; publication still requires all of them. No `pre-V3` comment exists in scope. |
| `DeviceProviderContractTests` narrative naming `rockchip.hdc.verify-build.v1` | Retained: it documents the retired unbound lowering that the negative test refuses; it is not a current identifier. |
| `openspec/changes/chg-2026-059-arkdeck-arkforge-authority/evidence/task-afa-001/EVD-AFA-DAYU200-20260818-001.json` (`6.0.0`) | Raw historical evidence, byte-identical (SHA-256 `f8bf9012681359a7da6d68a59b29a6ab88f79e7a2950a0c46103b223402df5c8`); not relabelled. |
| Archived changes and CHG-2026-075 planning documents mentioning V6/V2 | Historical text, unchanged. |
| `openspec/contracts/cli-*`, `runtime-control-plane.schema.json`, `spec/control/methods/**` | No SVC-003 version label present; unchanged, generator `--check` clean. |

SVC-004 owns the remaining preferences/configuration compatibility and the
change-wide residual audit. TASK-SVC-004 can start only after this
implementation is reviewed and merged into protected main.
