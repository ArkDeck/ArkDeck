# TASK-SEP-001 generation-bound Session export evidence

- Evidence class: deterministic macOS arm64 contract, protocol and production
  composition verification on host fixtures. It is not a real-device, HDC,
  Flash, Trace or notarized-distribution result, and the exported directories
  it produced were temporary fixtures that were deleted after each test.
- Protected-main base: `1075137b` (`main` after #1684 and #1685).
- Change: `CHG-2026-072-session-export-control@r1`; control methods
  `session.export.preview` and `session.export.apply`; CLI leaves
  `arkdeck session export preview` and `arkdeck session export apply`.
- Production route exercised by the subprocess contract:
  `arkdeck` process → `AgentDaemonServer` (UDS) → `RuntimeControlPlaneHandler`
  → `RuntimeSessionResourceHandler` → `RuntimeSessionStorageStore` →
  `SessionRetentionCatalog` scan + `RuntimeSessionExportRecordStore` →
  `SessionDiagnosticExporter` (bounded heavy-writer `StorageClaim`,
  device-identifier redaction, exclusive rename) → immutable receipt.

## Acceptance results

- SEP-AC-1 closed surface: the registry publishes exactly the two leaves;
  `--allow-sensitive` is accepted only by preview and apply refuses a
  destination of its own; the XPC boundary admits exactly `sessionId`,
  `destinationPath`, `allowSensitive` and exactly `previewId`,
  `previewDigest`; the daemon method scrape, effect classification and
  failure-mapping registries stayed exhaustive; the generated control contract
  has zero drift.
- SEP-AC-2 privacy and integrity: with a raw and a log Artifact, the default
  preview excluded the raw Artifact (`excludeByDefault`, `excluded`) and
  included the log Artifact (`include`, `redactDeviceIdentifiers`); the
  explicit opt-in preview carried a different digest, and a mixed tuple was
  refused; the published export held `manifest.json` and the included bytes
  only; the source manifest and raw bytes were byte-identical afterwards; no
  Session-private path appeared in any response.
- SEP-AC-3 drift and publication: an occupied destination, a catalog
  generation change (pin) and an expired preview each returned
  `resourceConflict` with zero output and no staging residue; an injected
  fault at `exportBeforeReplace` returned `outcomeUnknown`, left no
  destination or residue, and a retry did not run the exporter again.
- SEP-AC-4 production CLI path: a real `arkdeck` subprocess ran preview,
  apply, a receipt-returning retry and a stale-digest refusal
  (`resourceConflict`, phase `sessionOwner`, `newDispatchCount` 0) against the
  production handler; the exported directory existed exactly once and the
  Runtime Job ledger stayed empty.

## Frozen verification

- Focused contract set (`SessionExportContractTests`,
  `SessionResourceContractTests`, `SessionCleanupContractTests`,
  `AgentXPCTransportContractTests`, `CLIControlFailureMappingContractTests`,
  `CLICommandRegistryCoverageContractTests`, `CLIArgumentParserContractTests`,
  `CLIProcessGoldenContractTests`, `RuntimeStorageResourceContractTests`):
  168 passed, 0 failed, rerun on the final tree after the last source edit.
- Path-aware unified local gate
  (`scripts/ci/plan.py --merge-base --include-worktree --run-local`) selected
  the Swift and App lanes and exited 0 in 362 seconds:
  - plan tests 21/21; Agent PR workflow tests 9/9;
  - SDD: 121 acceptance IDs, 0 errors, 0 warnings;
  - Catalog generator tests 49/49, generated output unchanged;
  - design-system interaction tests 83/83;
  - SwiftPM wrapper tests 12/12; xcodebuild wrapper tests 16/16;
  - `full-parallel` lane: 2,337 tests, exit 0, 245 seconds, maximum RSS
    2,153,037,824 bytes; `full-process-identity-race`: 1 test, exit 0;
    `full-viewer-scale`: 5 tests, exit 0;
  - macOS App/UI-test `build-for-testing`: `TEST BUILD SUCCEEDED`.
- The unified gate ran on the tree before one final edit that removed an
  unreachable guard from the CLI apply branch; the focused contract set above
  was rerun after that edit and is the final verification of the CLI files.
- `generate-control-contract.py --check`, `scripts/check-sdd.sh` and
  `git diff --check` passed on the final tree.

The maintainer merge and protected-branch CI remain separate gates. No
device was connected, no HDC, RockUSB or Flash dispatch occurred, and no
`REAL_DEVICE_PASS` is claimed.
