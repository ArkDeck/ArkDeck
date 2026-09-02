# TASK-DTO-001 Debug template operation evidence

- Evidence class: deterministic macOS arm64 contract, catalog generation and
  production composition verification with scripted process receipts. It is
  not a real-device, HDC, Flash or Trace result; no device was connected and
  no device command was executed.
- Protected-main base: ``60af6bc7` (`main` after #1687)`.
- Change: `CHG-2026-073-debug-template-operation@r1`; operation
  `debug.template@1`; CLI leaves `arkdeck debug template list`,
  `arkdeck debug template run` and `arkdeck debug logs`; Catalog digest after publication
  `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`.
- Production route exercised by the scripted engine contract:
  `RuntimeJobEngine` admission → `debug.template@1` plan
  (`confirm-evidence-target`, `run-debug-template`, `finalize-session`) →
  `HDCObservationProviderAdapter` lowering → `RuntimeProcessDispatching`
  receipt → provider verification → `RuntimeArtifactStore` publication →
  evidence snapshot.

## Acceptance results

- DTO-AC-1 closed vocabulary: the descriptor validates with zero generated
  drift; the `templateId` enum equals `DebugRuntimeCommandTemplate.allCases`;
  the registry publishes exactly `debug template list` (local, non-connecting)
  and `debug template run` (domain leaf bound to `debug.template@1`) and the
  parser refuses a `--template` flag, a `--target` on `list` and an unknown
  verb; the coverage test confirms every published operation still has a
  convenience name.
- DTO-AC-2 admitted execution: the scripted Job succeeded read-only with
  exactly two dispatches, binding confirmation first; the template step
  lowered to `-t <connectKey> shell uptime` with a 30-second timeout and the
  template's 16 KiB budget; every template's typed action persisted through
  the journal encoding and back unchanged and classified as `readOnly`.
- DTO-AC-3 products and privacy: `template-output.txt` was published
  `sensitive` and refused without opt-in, then read back as the exact stdout;
  `template-report.json` was published `standard` naming the operation,
  template identity, disclosed command, exit status, byte counts and Catalog
  digest; neither carried the connect key.
- DTO-AC-4 refusal: `device.reboot` was refused at admission with zero
  dispatch; a receipt exiting 1 failed the Job without publishing output
  under the template's name.
- DTO-AC-5 logs preset: `debug logs` projected exactly
  `DiagnosticCapturePreset.logs` (the App's HiLog-only
  `capture.diagnostics@1` inputs, every other leg off), defaulted absent
  filters to an empty array, and refused a shell-looking filter, a 601-second
  window and a foreign `uiDump` field before any connection; the registry
  binds the leaf to `capture.diagnostics@1` and the parser refuses a
  `--duration` flag.

## Frozen verification

- Catalog generator: `generate.py --write` then `--check` with zero drift;
  generator unittest 49 passed.
- Focused contract sets: the template set (`ArchitectureBoundaryContractTests`,
  `DiagnosticsRuntimeOperationCatalogContractTests`,
  `DebugTemplateOperationContractTests`, `CLIDebugTemplateContractTests`,
  `RuntimeOperationCatalogTests`, `RuntimeArtifactContractTests`,
  `DeviceProviderContractTests`, `DiagnosticsAndHAPContractTests`,
  `AgentDaemonContractTests`, `CLICommandRegistryCoverageContractTests`)
  296 passed, 0 failed, 1 pre-existing skip; the logs set
  (`CLITypedCapturePresetContractTests`, `CLIDebugTemplateContractTests`,
  `DebugApplicationFacadeContractTests`,
  `CLICommandRegistryCoverageContractTests`, `CLIArgumentParserContractTests`,
  `DebugTemplateOperationContractTests`, `ArchitectureBoundaryContractTests`,
  `DiagnosticsRuntimeOperationCatalogContractTests`,
  `CLIProcessGoldenContractTests`) 170 passed, 0 failed, on the final tree.
- Path-aware unified local gate
  (`scripts/ci/plan.py --merge-base --include-worktree --run-local`):
  selected the Swift and App lanes and exited 0 in 271 seconds on the final
  tree:
  - plan tests 21/21; Agent PR workflow tests 9/9;
  - SDD: 121 acceptance IDs, 0 errors, 0 warnings;
  - Catalog generator tests 49/49, generated output unchanged;
  - design-system interaction tests 83/83;
  - SwiftPM wrapper tests 12/12; xcodebuild wrapper tests 16/16;
  - `full-parallel` lane: 2,344 tests, exit 0, 181 seconds, maximum RSS
    442,892,288 bytes; `full-process-identity-race`: 1 test, exit 0;
    `full-viewer-scale`: 5 tests, exit 0;
  - macOS App/UI-test `build-for-testing`: `TEST BUILD SUCCEEDED`.
- A first full-lane run on the earlier shape of this change failed exactly
  two contracts: the execution kernel may not gain a per-operation name, and
  the set of steps carrying generated action references is pinned. The
  descriptor was reduced to binding confirmation plus the template step and
  the engine edit withdrawn; the gate above ran on the final tree.
- `sh scripts/check-sdd.sh` and `git diff --check` passed on the final tree.

The maintainer merge and protected-branch CI remain separate gates. The
Catalog digest changed, so earlier current-digest real-device records now
describe the previous digest; no `REAL_DEVICE_PASS` is claimed.
