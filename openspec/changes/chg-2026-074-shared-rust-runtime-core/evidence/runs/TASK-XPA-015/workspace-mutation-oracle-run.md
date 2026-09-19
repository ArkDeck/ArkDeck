# Workspace project and preset mutation oracle (TASK-XPA-015, M3)

This change is Swift-only. One Swift contract test records the native control
frames of the seven workspace methods the Rust owner does not serve yet:
`workspace.project.update`, `workspace.project.remove` and
`workspace.preset.register/update/remove/list/show`. Their schemas are
re-derived from those frames and the committed corpus. The Rust slices that
port these methods then replay this oracle without touching Swift, as tasks.md
r11 (7) asks.

Base: protected `main` `2af5c806`. The recording ran on `7b5872f1`; nothing in
`ArkDeckWorkflows/WorkspaceProvider`, `ArkDeckAgentDaemon` or `ArkDeckCore`
changed between the two.

| Already on `main` | This oracle delivers | Still remaining (M3) |
|---|---|---|
| Rust `workspace.project.register/list/show`, with the full refusal vocabulary of `workspace.project.register`; the SPK-10 signing layer (#2031) | `AgentDaemonContractTests.testWorkspacePresetAndProjectMutationControlFramesRecordTheirRefusals`; 78 recorded frames; re-derived schemas and corpus for the seven methods | the Rust owner for the seven methods; the DevEco toolchain and signing credential acquire/release that preset mutations pin; CLI leaves; the 13 `workspace.*` operations; GJ-5 |

## What the test records

The test runs the production daemon handler over a real
`RuntimeWorkspaceProjectStore` on test-owned roots. Toolchain and credential
pinning are test-owned closures that accept every pin except one foreign
credential.

| Method | Answers | Refusals recorded |
|---|---|---|
| `workspace.project.update` | a moved root at generation 2 | `resourceConflict` (kind change with an available preset, a root already registered, a stale generation), `workspaceReferenceNotFound`, `invalidInput` (kind, root), `operationUnavailable`, `recordUnreadable`, `ioFailure`, `outcomeUnknown` |
| `workspace.project.remove` | a removed project | `resourceConflict` (available presets, stale generation), `workspaceReferenceNotFound`, `invalidInput`, `operationUnavailable`, `recordUnreadable`, `ioFailure` |
| `workspace.preset.register` | build, symbol and signing presets, and a replay | `idempotencyConflict`, `workspaceReferenceNotFound`, `resourceConflict` (foreign credential), `invalidInput` (9 definitions), `invalidParams`, `operationUnavailable` (no toolchain owner; retained mutation), `quotaExceeded` (the 257th preset), `recordUnreadable`, `ioFailure`, `outcomeUnknown` |
| `workspace.preset.update` | a new definition and its replay | `idempotencyConflict`, `resourceConflict`, `workspaceReferenceNotFound`, `invalidInput`, `invalidParams`, `operationUnavailable`, `recordUnreadable`, `ioFailure`, `outcomeUnknown` |
| `workspace.preset.remove` | a removal and its replay | `idempotencyConflict`, `resourceConflict`, `workspaceReferenceNotFound`, `invalidInput`, `operationUnavailable`, `recordUnreadable`, `ioFailure`, `outcomeUnknown` |
| `workspace.preset.list` | a whole project and one kind | `workspaceReferenceNotFound`, `invalidInput`, `invalidParams`, `operationUnavailable`, `recordUnreadable` |
| `workspace.preset.show` | one preset | `workspaceReferenceNotFound`, `operationUnavailable`, `recordUnreadable` |

Storage failures come from the store's existing injected clock, which runs
after the document is loaded and before it is published, with a fresh owner for
each attempt. A project removal reads no clock, so its `ioFailure` comes from a
read-only owner directory, and it has no rename failure to inject.

**A Swift defect was found and avoided.** Removing a project whose presets were
removed leaves preset records that name no project. Every later load refuses
them with `recordUnreadable`, including the store's own construction. The
first recording run hit this. The test's successful removal therefore comes
from a project that never had presets. The defect is left to a separate
change, because the fix must keep the durable format frozen and change the
Swift owner and the Rust validator together.

## Schema derivation

For each of the seven methods only, the source held the committed corpus plus
this test's frames. `Packages/ArkDeckKit/Scripts/generate-control-contract.py
--derive-method-schemas` then wrote the seven schemas and corpora, and
`rust/scripts/generate-contract.py --write` regenerated the manifest:
105 methods, 856 recorded shapes. No other method's schema or corpus changed.

| Method | Codes added to the published set | Corpus lines |
|---|---|---|
| `workspace.project.update` | `invalidInput`, `ioFailure`, `operationUnavailable`, `outcomeUnknown`, `resourceConflict` | 2 → 9 |
| `workspace.project.remove` | `invalidInput`, `ioFailure`, `operationUnavailable`, `resourceConflict` | 2 → 8 |
| `workspace.preset.register` | `idempotencyConflict`, `invalidInput`, `ioFailure`, `operationUnavailable`, `outcomeUnknown`, `quotaExceeded`, `resourceConflict` | 2 → 19 |
| `workspace.preset.update` | `idempotencyConflict`, `invalidInput`, `ioFailure`, `operationUnavailable`, `outcomeUnknown`, `resourceConflict` | 2 → 12 |
| `workspace.preset.remove` | `idempotencyConflict`, `invalidInput`, `ioFailure`, `operationUnavailable`, `outcomeUnknown`, `resourceConflict` | 2 → 11 |
| `workspace.preset.list` | `operationUnavailable` | 4 → 11 |
| `workspace.preset.show` | `operationUnavailable` | 3 → 7 |

A structural check found every new schema to be a superset of the old one:
types, properties, definitions and codes. The error details of the two project
mutations now carry `phase` and `newDispatchCount`, as the owner answers them.
Two old corpus lines were replaced by smaller successful frames of the same
shape. `workspace-mutation-native-recording/` holds the 78 frames and their
provenance.

## Local targeted checks

| Check | Exit | Result |
|---|---|---|
| `run-swiftpm.sh test --filter AgentDaemonContractTests/testWorkspacePresetAndProjectMutationControlFramesRecordTheirRefusals` with `ARKDECK_CONTROL_FRAME_LOG` | 0 | 1 test, 0 failures |
| `run-swiftpm.sh test --filter ControlMethodSchemaContractTests` | 0 | 5 tests, 1 skipped, 0 failures |
| `python rust/scripts/generate-contract.py --check` | 0 | no difference after `--write` |
| `cargo test -p arkdeck-contract` | 0 | 49 passed |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

The PR's `guard` and `swift` aggregate are the unified gate. The Swift lane
ran because a Swift test changed; the Rust lane ran because contract inputs
changed. Both were green at head `dfdf5fe4`, and #2041 merged as `3e95ac6d`.
This result is recorded by the next slice, #2041's Rust port.

| Workflow run | Job | Result |
|---|---|---|
| Swift CI 35447197759 | `swift` aggregate | pass |
| Swift CI 35447197759 | `swift-tests` | pass (5m56s) |
| Swift CI 35447197759 | Rust workspace on macos-26, ubuntu-latest and windows-latest; host-independent checks | pass (12m23s, 2m52s, 5m3s, 26s) |
| Swift CI 35447197759 | `app-build` | skipped by the plan |
| SDD Guard 35447197591 | `guard`, `ds-tokens` | pass |
| Agent PR 35447197611 | `open-pr` | pass |
