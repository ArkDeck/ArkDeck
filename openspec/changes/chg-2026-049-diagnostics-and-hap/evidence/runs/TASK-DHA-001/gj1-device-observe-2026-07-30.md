# GJ-1 Device Observe — real DAYU200 run (2026-07-30)

## Result

`GJ-1 Device Observe`: **REAL_DEVICE_PASS**

The production Device Runtime Agent completed discovery/resume, durable
binding, `observe.device@1`, bounded HiLog, UI Dump, Artifact publication and
daemon-restart readback on a real DAYU200. No person ran an HDC command. Raw
HiLog and UI Dump bytes were neither read nor exported; only product-reported
metadata and the standard-privacy capture summary were inspected.

## Runtime

| Item | Value |
| --- | --- |
| Source baseline | `main@0435949b1a25588a4278ecd029573f788c76b04d` |
| Device | DAYU200 (RK3568), USB |
| Durable target | `TGT-958780b2ffb7`, binding revision `1` |
| HDC | `3.2.0f`, SHA-256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` |
| Catalog digest | `3455e050c8a6e09c026d784b652be22dc69b5809d448059f7f1c3524e7bf60a2` |
| Runtime state | `/private/tmp/ad-gj1-0435949`, mode `0700` |
| Authority | `default-read-only-policy`, actual effect `E0` |

The first discovery observed the candidate as `Offline` and produced a
resumable human action. The device was connected and the same persisted resume
token continued; no new operation and no manual HDC command was used. The
resumed `observe.device@1` job
`job-d6485f47927a582fcab4897512457380` succeeded with machine-readback model,
firmware, transport, stable identity and binding confirmation.

## Product defect and fix

The first diagnostics job
`job-2beaafa7c50cc9e5712f31df8501bcd0` published HiLog, UI Dump, Artifact index
and capture summary and reached `succeeded`, but `job.evidence` returned no
artifact references plus an `artifactVerification` blocker. It had treated the
honest missing placeholder for an unrequested optional Trace as though a
selected product had disappeared.

The fix derives intentionally omitted products from the persisted typed inputs
and operation dependency graph. Such products stay visible as `missing` in the
Artifact index and summary but are excluded from evidence-bearing references.
A selected missing/truncated/tampered product still fails closed. The same
vertical change also maps an `Offline` candidate to `physicalReconnect`;
`trustDevice` is now reserved for `Unauthorized`.

## Fixed production run

The rebuilt production Agent ran one new
`capture.diagnostics@1` job with `{"durationSeconds":5}` and no Trace request:

- job: `job-6b6e174a05b31944e7f19b30687f4ed4`;
- terminal state: `succeeded`;
- `outcomeUnknown`: `false`;
- `evidenceBlockers`: empty;
- published, byte-verified evidence references: `4`;
- HiLog: published, 694249 bytes, default redaction applied;
- UI Dump: published, 37 bytes;
- Artifact index: published, 636 bytes;
- capture summary: published, 697 bytes;
- Trace: honestly indexed as optional `missing`, not an evidence reference;
- summary: `completeness=complete`, `missingRequired=[]`.

The daemon was stopped cleanly and restarted with the same state directory. It
recovered all three persisted jobs without dispatch. Product queries then
returned the fixed job as `succeeded`, `outcomeUnknown=false`, timeline suffix
`recovered: journal clean`, the same five Artifact index entries, one adopted
target and the same binding revision.

## Verification

- `swift test --package-path Packages/ArkDeckKit --filter
  AgentRuntimeExecutorContractTests`: 8 tests, 0 failures for the artifact fix;
- `swift test --package-path Packages/ArkDeckKit --filter
  RuntimeArtifactContractTests`: 22 tests, 0 failures;
- focused bootstrap + Agent follow-up: 18 tests, 0 failures;
- final `swift test --package-path Packages/ArkDeckKit`: 701 tests, 1 skipped,
  0 failures;
- `scripts/check-sdd.sh`: 0 errors, 0 warnings, 114 Acceptance IDs.

This record changes no Acceptance ID, acceptance count, governance state or
OpenSpec change.
