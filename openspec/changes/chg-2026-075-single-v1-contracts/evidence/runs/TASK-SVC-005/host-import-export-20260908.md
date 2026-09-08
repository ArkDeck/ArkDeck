# SVC published host acceptance continuation — 2026-09-08

This is an additional execution record for `TASK-SVC-005`. It records real host
product operations and preserves their distinction from device acceptance. It
does not mark the Task done or certify a final hardware-verified Swift baseline.

## Published helper and preserved Runtime

The clean protected-main source used for the installed helper was
`6a8a06fc2f437c790322c50871173b72a9ca80c9`. Its signed CLI executable is
`c82a9c0889ef696582b424c49243cb61ebe407f74efa1091a30559ca7fa6dcec` and nested
daemon executable is
`488b66ce71db225fd93feb60f2b3574f37fb63412a6cf02aa5f782227a1f1944` (SHA-256).
The typed service update completed at `2026-09-08T01:38:35Z`. Before and after
readbacks retained the same seven Jobs and all five original state hashes from
the earlier SVC acceptance record. The service reported ready with no service
diagnostics, the unchanged current contract identity
`1054d17b598ce23003ebbdec4d42eb359b63016d6421709ba53c3f21f7c6558d` and Catalog
digest `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`.

The published CLI now reads the existing unknown Flash evidence with `ok: true`,
`actualStepKinds: null`, its original blockers and exit 75. Job result correctly
returns `resultNotReady` with exit 75. This verifies the reviewed CLI repair on
the installed Runtime; the original Flash remains `waitingForRecovery` and has
not been reconciled, replayed or relabeled.

Local immutable captures are under
`/private/tmp/arkdeck-svc-a-20260908/published-6a8a-readback/`. The `before` and
`after` indexes identify actual arguments, times, exits and output hashes.
The deep doctor probe intermittently reports `hdc.identityObservationTimedOut`
at the current 1000 ms process-identity boundary. Both success and timeout were
observed on the same daemon/HDC processes without reconfiguration. A later
formal timed capture is retained in `hdc-identity-diagnosis/`; it timed out with
zero new dispatch. This is not evidence of a signature bypass or a reason to
increase the registered timeout. Device execution requires fresh passing facts.

## Import and Artifact export

Between `2026-09-08T02:18:02Z` and `02:24:03Z`, the installed CLI completed three
typed imports for existing target `TGT-958780b2ffb7`, then inspected each import.

| Material | Import request | Import resource | Artifact resource |
| --- | --- | --- | --- |
| Paired HAP | `svc-20260908-hap` | `imp-2a8a095c-4c46-4ce1-b78e-5d1f2b4509f6` | `ART-e116a0747c0acbbc9b4c827ad1febe54` |
| Positive native library | `svc-20260908-native-positive` | `imp-965d92d2-a192-4b46-9889-a3a88a449c11` | `ART-a809e3f37e6341e0799bf7d6b47f91af` |
| Rollback library fixture | `svc-20260908-native-rollback` | `imp-c0e9af4a-3d04-499d-8298-fc55eb582dce` | `ART-b77596be8d7a595347cb9419f5a9843e` |

All three import and inspect commands exited 0. Repeating the same HAP request
returned the same import result. Listing the HAP's Artifact and exporting it to
a fresh local destination also exited 0; the receipt reports `overwritten: false`
and 2,679,364 bytes. The exported file's SHA-256,
`3ab86dc367d00ca533b4b29219e104d60dbfd1f9f95268f570cec3656a82db82`, exactly matches
the imported HAP. The original seven Job IDs and five original state hashes were
unchanged after these host operations.

Captures, typed arguments and input/output hashes are under
`/private/tmp/arkdeck-svc-a-20260908/host-import-export-6a8a/`; `verification.json`
records equality checks, and `preservation-after.json` records source preservation.
The library labeled rollback is only imported here; no deployment, atomic
publication, process restart or rollback has been demonstrated by this record.

## Session export remains blocked

The same installed CLI's `session list` exited 69 with `operationUnavailable`,
`phase: sessionOwner` and `newDispatchCount: 0`. Storage reports zero catalog
entries, one unaccounted Session, incomplete measurement and 4,017,489,603 bytes.
The one historical Session has an identity record but no `manifest.json`.
Its files are from 2026-08-02. The existing owner refuses the incomplete catalog
for list, show and export, so Session export has not passed.

The original Session is preserved. No file was moved, deleted or rewritten, no
manifest or terminal evidence was invented, and the Runtime root was unchanged.
The diagnosis and exact source refusal chain are in the local
`session-catalog-diagnosis.md`. A reviewed Runtime product path is needed before
this prescribed acceptance can complete. The successful Artifact export above
does not stand in for Session export.

## Later published GJ-1 readback

The next clean protected-main helper was built from
`0b35d535ccda2d01a12d29c9966de54c46a276ab`, after reviewed PR #1770. Its signed
CLI executable SHA-256 is
`3c5e7fcd95e59f155308489e2dd68da3c4ab8ff1641011fdaed6afbf518afce3`; the nested
daemon is `8bb060bea75c9c51074c95205e460bedbe0f699a81bb6f41112723fcebb53882`.
The typed service update completed at `2026-09-08T03:26:13.180353Z`, exit 0.

The immediate published readback at `03:26:28Z` passed service status, deep
doctor with `--require-healthy`, operation list, target list and storage status.
It preserved the same seven Jobs, all five original state hashes, HDC selection,
ArkForge configuration and ArkTrace descriptor. Unknown Flash evidence remained
readable with its original null step inventory and exit 75. No new Job,
agent execution, reconcile or device-mutation request was submitted.

`device candidates` exited 70 and now exposed the bounded actual parser failure:
the registered `[Empty]` sentinel followed by physical CRLF was treated as one
malformed column. Direct compilation of the unchanged published parser reproduced
the exact captured message; literal backslash-r/backslash-n produces a different
escaped preview. Swift's Character splitting left physical CRLF unseparated;
the same code rejects a valid five-column CRLF row. This is a newly localized
production parser defect, not proof of a connected device or completed GJ-1.
The empty-list/HumanActionRequired repair is being validated separately.

Immutable captures and argument/time/exit/hash indexes are under
`/private/tmp/arkdeck-svc-a-20260908/published-0b35-readback/`. Deep doctor's stdout
SHA-256 is `a140cfe01e16af609336e6d97492e907214ca4610ccb42aa791570bfd8f67c60`;
device candidates is `532c465f788bb4b60935b12f9edecc363c9949e14b46bc0069deb060fb02548f`.
This later passing doctor does not erase the earlier identity-timeout captures.

## Remaining acceptance

Current GJ-1/2 product fixes, published `agent run/resume` journeys, the original
GJ-4 proof/lineage blockage, the Session export path and App/Settings assertions
remain open. The exact local App launch and first-password-prompt signing cancel
actions were rejected by automatic approval review and are awaiting the specific
user decisions already requested. No signing installation or cancellation was
performed by the rejected action.
