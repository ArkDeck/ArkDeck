# TASK-M0A-006 run record — 2026-07-15

- Evidence class: `evidenceRollup` + `decisionDraft` (local documentation and
  integrity checks only; no hardware)
- Core baseline: `CORE-1.0.0`
- Platform input: `PLATFORM-MACOS@0.1.0`
- Integration input: `OPENHARMONY-TOOLS@0.1.0`
- Source revision: `0abbbaa1a6af080a94b7222ba67f4e7a3f325ab0`
- Scope: `MAC-M0A-DIST-001` and all-row M0A evidence classification

## Ready check

- `CHG-2026-001-macos-m0a` is approved on protected `main` at the source
  revision above.
- Dependencies TASK-M0A-002, TASK-M0A-003, TASK-M0A-004, and TASK-M0A-005A
  are recorded `done`.
- TASK-M0A-005B and TASK-M0A-007 are explicitly accepted as blocked inputs to
  this rollup rather than completion dependencies; their missing evidence must
  remain visible in the ADR and matrix.
- TASK-M0A-006's verification method is an ADR content/integrity check followed
  by independent maintainer review. Local read-only git, hashing, and SDD tools
  are available. No unavailable hardware or signing tool is required to draft
  the scoped documents.
- Work was restricted to `docs/adr/**` and this change's `evidence/**`.
  Authoritative platform/profile/verification/task status files were not
  edited.

## Work completed

1. Added `docs/adr/0001-macos-v1-distribution.md`, selecting exactly one v1
   target: non-Sandbox Developer ID Application + Hardened Runtime in one
   notarized DMG for the declared macOS 14/arm64 support cell.
2. Recorded the exact prospective release entitlement set as empty and
   enumerated entitlements/runtime exceptions that are absent. The ADR states
   that no selected artifact exists and therefore makes no release claim.
3. Recorded considered evidence, rejected alternatives, residual risks,
   mandatory release evidence, and revalidation triggers.
4. Added `rollup.md`, classifying all 13 M0A rows: 5 `passed`, 0 `failed`, and
   8 `blocked`. No pending or unclassified row remains in the rollup.
5. Added `evidence-index.sha256.md`, pinning the exact authoritative inputs and
   source task evidence consumed at the source revision. Re-hashing the
   ephemeral TASK-M0A-005A executable matched its previously recorded hash;
   the artifact was not executed.
6. Added `macos-profile-verification-0.2.0-draft.md` as a non-authorizing input
   to a future platform change. It keeps platform conformance `notStarted`,
   preserves blocked rows, and does not alter Core or current profile files.

## Commands and results

| Command | Result |
| --- | --- |
| `shasum -a 256` over the nine authoritative inputs and seven source evidence files listed in `evidence-index.sha256.md` | Passed: every digest matched the recorded index. |
| `shasum -a 256 /private/tmp/arkdeck-m0a-005a-derived/Build/Products/Release/ArkDeck.app/Contents/MacOS/ArkDeck` | Passed as an integrity cross-check: `f9478493480c715b7610fa4aafd58e280798e6ebdc82d4d10491ddcdafb8242a`, matching TASK-M0A-005A. The executable was not launched. |
| Top-level matrix-row audit over `rollup.md` | Passed: 13 unique acceptance rows; 5 passed, 0 failed, 8 blocked; no pending/unclassified status. The separately enumerated blocked subcells are excluded from this top-level count. |
| `scripts/check-sdd.sh` | Passed: `0 error(s), 0 warning(s), 110 acceptance IDs`. |
| `git diff --check` | Passed: no whitespace errors. |
| `shasum -a 256` over the four generated ADR/rollup/index/draft outputs | Passed; exact digests are recorded below. |

No build or Swift test was rerun because TASK-M0A-006 changes documentation
and evidence only; no source, package, project, fixture, schema, or current spec
file changed. The source task test outcomes are cited with their exact run-file
hashes rather than represented as new executions.

## Generated output hashes

| SHA-256 | Output |
| --- | --- |
| `5b13b75f8c576c19403d0b7459a5559e397e325e4f443cebcdb44370d91744a4` | `docs/adr/0001-macos-v1-distribution.md` |
| `bc2a7bf78efb9e67e2970064b14cd0e227bbd547076797a732375dcf6cd49a0e` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-006/rollup.md` |
| `4f7f0d7ab3d58d9c1ea8115e53c33534a194226da0fb167be916ef3f81026b09` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-006/evidence-index.sha256.md` |
| `b749f3313d2fe9ae091bf7bfc5b0ee69a25446303f38978003b66904b226a1a8` | `openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-006/macos-profile-verification-0.2.0-draft.md` |

This run record is not self-hashed; its integrity comes from the reviewed git
commit. File hashes are evidence locators, not an approval mechanism.

## AC conclusion

The Agent-authored deliverables for TASK-M0A-006 are complete within the
allowed paths:

- the ADR selects exactly one v1 distribution target;
- the exact entitlement set, evidence basis, rejected alternatives, residual
  risks, and revalidation triggers are explicit;
- every M0A matrix row has a non-pending status in the rollup; and
- the hash index and next-profile/verification draft are present.

`MAC-M0A-DIST-001` remains **blocked at this run boundary** because the
selected non-Sandbox Developer ID/Hardened Runtime/notarized DMG artifact and
its signed evidence do not exist, and the required independent maintainer ADR
review has not yet occurred. The current ad-hoc Sandbox entitlement dump is
preserved as considered prototype evidence; it is not misattributed to the
selected distribution.

TASK-M0A-006 remains `ready` in the authoritative `tasks.md`: that file is
outside this task's allowed paths, and the Agent does not self-approve a status
transition. Maintainer review must decide the task/status follow-up without
converting any blocked matrix row into a pass.

## Safety, deviations, and residual risk

- No HDC/device command, browser download, VM, signing identity, network,
  USB/UART/TCP endpoint, or real hardware was used.
- No Flash, erase, format, unlock, update, HDC lifecycle action, device
  mutation, or destructive operation was dispatched. Destructive dispatch
  count for this task is `0`.
- No quarantine/xattr, code signature, system security, credential, private
  key, or host trust setting was changed.
- The distribution direction is a reviewed-decision candidate, not proof of
  feasibility. Developer ID, notarization, Gatekeeper, external HDC trust,
  supervised file access, and real transport evidence remain future blockers.
- Platform conformance remains `notStarted`; the change is not verified by
  this run, and no macOS support claim is created.
