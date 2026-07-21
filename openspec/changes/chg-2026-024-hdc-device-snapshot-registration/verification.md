# CHG-2026-024 Verification Plan

> Change:CHG-2026-024-hdc-device-snapshot-registration@r1
> Status:planned
> Core baseline:CORE-2.1.0（canonical Core AC 零认领）

## Environment

- Registration tests are headless and consume only reviewed controlled receipts, versioned
  resources, fake/adversarial vectors and local files.
- Agent/CI installed HDC, real device, non-loopback network, server lifecycle/adoption,
  subserver/device mutation and destructive dispatch are prohibited.
- Production support requires maintainer-controlled capture for exact macOS/tool/executable/
  endpoint context; fake bytes are control-only.

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `I24-HDC-DEVICE-SNAPSHOT-001` | parameterized grammar + zero/one/many/stable/order/duplicate/adversarial contract | complete registered output yields a bounded unique pseudonym set; malformed, partial, mixed or unsupported output makes the whole snapshot unknown | platform + contract |
| `I24-HDC-DEVICE-EMPTY-001` | successful-empty vs stderr/nonzero/truncated/timeout/cancel/identity-drift matrix | only the registered successful zero-row family yields observedEmpty; every unavailable/failure/unknown input remains distinct and cannot produce disappearance | platform + contract |
| `I24-HDC-DEVICE-PROVENANCE-001` | controlled capture lineage/effect/privacy review | exact zero/one/many and transition inputs have immutable source hashes and stable server brackets; raw identifiers stay outside the repository; fake inputs never establish support | platform |
| `I24-HDC-DEVICE-REGISTRY-001` | profile/new-registry/lock/resource/macOS mapping closure + old-registry identity | all candidate versions, IDs, paths and hashes agree; the existing 1.0.0 readonly registry/resources remain byte-identical and old consumers gain no authority | contract |
| `I24-HDC-DEVICE-NODISPATCH-001` | static command surface + instrumented counters | registration/Agent/CI dispatches installed HDC/device/network/server lifecycle/adoption/subserver/device mutation/destructive actions zero times; only the exact existing-server-only entry can later be adopted | contract |

## Negative, cancellation and recovery gates

- server absent/ambiguous/substituted or endpoint drift => unavailable before command dispatch;
- unknown row literal/column/transport/state, duplicate ID, mixed failure marker, stderr, nonzero,
  truncation or invalid encoding => whole snapshot unknown, no partial set;
- timeout/cancellation => terminate only the owned client observation process; no HDC server kill;
- raw identifier in fixture, receipt, log, presentation sample or repository => privacy failure;
- missing zero/multi-row/effect provenance or any hash mismatch => entry unsupported and task blocked;
- rollback restores the prior integration profile/lock while leaving existing 1.0.0 registry bytes.

## Result gate

- All five change-local ACs require same-revision, reviewable evidence before TASK-I24-001 may be
  marked done.
- `done` establishes integration registration only. CHG-2026-022 must separately adopt the merged
  version and satisfy its own readiness/implementation/evidence gates.
- This change never counts as M0B-002 real-device acceptance or hardware/support/release evidence.
