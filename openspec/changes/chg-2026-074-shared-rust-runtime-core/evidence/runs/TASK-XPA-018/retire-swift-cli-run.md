# TASK-XPA-018 — retire the Swift CLI and the Swift Runtime's tests (macOS, 2026-09-28)

S6, first PR (maintainer task prompt 2026-09-28 §4 S6; design r10 route C:
delete first, final real-device GJ afterwards). Base: `main` `f574ad984`
(#2308, after #2309). Needs maintainer review. TASK-XPA-018 stays `in-progress`: its
criteria include the GJ-1..5 headless re-pass with the Rust CLI, which is
phase A.

Nothing here is device evidence. No Runtime, control schema, corpus,
Catalog, `openspec/contracts`, `openspec/specs` or constitution change. No
recorded fixture changes: every oracle the deleted Swift code produced stays
committed under `rust/tests/fixtures/**` and
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/{CLI,ControlFrames,HDC,SessionStorage,Unicode}`,
and the Rust tests keep replaying it.

## What is deleted

- The Swift CLI: the `ArkDeckCLI` executable target, the `arkdeck` product and
  `Sources/ArkDeckCLI` (29 files). The Rust `arkdeck` serves all 209 leaves.
- The export flip (`tasks.md` "Contracts export S6"): Swift's
  `maintainer contracts export` and its zero-drift test
  (`CLIMachineContractTests`) are gone with the CLI; the Rust export is the
  only producer of the machine-contract bundle and `machine_contracts` stays
  its CI gate, as the hub ruled.
- `ArkDeckContractTests` is pruned to the tests of what remains. The Swift
  CLI's tests and the Swift Runtime's tests could not be separated: they share
  helpers (`RuntimeAgentExecutionContractTests.Dispatcher`,
  `AgentDaemonContractTests` fixtures, `HDCOracleHarness`,
  `DiagnosticsAndHAPContractTests` builders, `JSONSchemaSubset`), and several
  tests spawn the built Swift `arkdeck` next to the test bundle. So every test
  file that imports a module TASK-XPA-017 deletes (`ArkDeckCLI`,
  `ArkDeckAgentDaemon`, `ArkDeckWorkflows`, `ArkDeckAgentComposition`,
  `ArkDeckStorage`, `ArkDeckProcess`, `ArkDeckOpenHarmony`,
  `ArkDeckLaunchAgent`, the ArkForge Swift SDK) or runs the Swift CLI binary
  goes: 258 of 296 Swift files. The design's split holds: black-box transport
  and protocol tests are the Rust control-plane tests, engine-internal tests
  are replaced by Rust, and the byte-decoding tests are fixtures the Rust
  crates replay. `AgentXPCTransportContractTests` goes as §4 S4 of the prompt
  says; its black-box duty is the Rust control-plane tests plus the SPK-8
  negatives (#2308).
- Helpers no remaining test uses (`HDCFixtures`, `JournalRecoveryFixtures`,
  `ProcessExecutorFixtures`, `GzipTarTestArchive`, `HDCOracleFake`, the two
  host-store shadow fixture files, `RuntimeJobSQLiteTestSupport`) and two
  fixture directories nothing reads any more (`RetiredDurableFormats`,
  `TargetNames`). The oracle file comparison the ClientKit update oracles use
  moves to `OracleFiles.swift`.
- `ArkDeckContractTests` now links only `ArkDeckClientKit`, `ArkDeckCore`,
  `ArkDeckRuntime`, `ArkDeckAgentClient`, `ArkDeckBootstrap` and
  `ArkDeckFakeHDCFixture` (the App UI tests run that fixture). No test links a
  target TASK-XPA-017 deletes, so that deletion touches no client.
- Swift-oracle tooling that builds or runs the Swift CLI or daemon:
  `rust/scripts/record-{maintainer-contracts,signing-install,signing-migrate,signing-remove,signing-sdk}-oracle.py`,
  `rust/scripts/check-{artifact-quota,capability-read,job-plan,job-submit,job-run,job-read-owner}.py`
  (each required `--swift-bin-dir` or a Swift-test-generated fixture), and the
  Swift/Rust host-store shadow (`rust/scripts/hoststore-shadow.py`, its test,
  `ArkDeckTraceAdapterTests/HostStoreTraceShadowTests.swift` and the nightly
  `host-store-shadow` job). None ran in the required gate. The replay harness
  `record-runtime-update-oracle.py` stays: the Rust CLI tests replay through it.
- The SPK-9 missing-archive carrier (`scripts/ci/run-spk9-preview-missing.py`)
  ran a Swift test class (`ArkForgeMissingArchiveLiveTests`, which imported
  the ArkForge Swift SDK) beside the Rust one. It now runs the Rust half alone
  and holds it to the same expected outcome; its unit test is unchanged.
- The Swift Runtime's slow durability lanes (`run-test-lane.sh slow`,
  `provider`, `storage`, and the process-identity race in `full`) and the
  nightly `slow-lanes` job: the tests they ran are deleted. `medium` is now
  Core plus ClientKit.

## What changes

- `ArchitectureBoundaryContractTests` is rewritten to guard that Swift
  carries no Runtime semantics: the manifest declares only the remaining
  libraries, one fixture, the test targets and the TASK-XPA-017 targets being
  deleted; no remaining target or test links those; the Swift CLI and the
  decision plane never return; the remaining sources keep their layer
  matrix, name no model surface and take no raw command string; the App links
  and imports only ClientKit, Core and the Trace adapter; ArkTrace stays
  pinned. The next PR turns the retiring set into a permanent absence.
- Three ClientKit tests stop reading Swift CLI sources and keep their App
  half (`AutoUpdateContractTests`, `DiagnosticSessionOfflineInspectorContractTests`,
  `UIDumpOfflineInspectorContractTests`).
- `ArkDeckApp/Resources/DebugLocalizable.xcstrings` drops seven
  `debug.commands.*` keys (arguments, executable, notGenerated and the four
  `result.*`). The App renders none of them; only deleted Swift code still
  named them, so the design suite's "no keys for paths the App no longer
  renders" check (`workspace-interactions.test.mjs`) now counts them dead.
- `Fixtures/HDC/HDCFixtures.swift` is one of the Rust contract generator's
  inputs, so `spec/baselines/swift-single-v1.json` is regenerated
  (`generate-contract.py --write`): that file leaves the input list and the
  HDC and input digests move. No schema, corpus or method changes.
- `scripts/ci/plan.py`: `CLICanonicalJSON.swift` leaves the Rust contract
  inputs; the bundle comment names the Rust export as the only producer.
  `scripts/ci/test_plan.py` and `scripts/test_agent_pr_workflow.py` follow.

## Left for the next PR (TASK-XPA-017)

The six Swift Runtime targets, `ArkDeckAgentComposition`, `ArkDeckLaunchAgent`,
the Journal/Engine/Soak/RuntimePort/FakeHapSigner fixtures, the ArkForge Swift
SDK dependency and `APIBaseline`'s imports of them, the lanes that build
them, and the App's code requirement that still admits the façade identifier
(with `scripts/release/build_macos_release.py`). #2309 already retired the
Swift branches of `build-helpers.sh` and `build-local-helpers.sh`, so nothing
outside the package builds the Swift `arkdeck` product any more; it also
edited `LaunchAgentServiceContractTests`, which this PR deletes (it imported
`ArkDeckLaunchAgent` and the Swift CLI).

## Local targeted checks

| Command | Exit | Log |
| --- | --- | --- |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build --build-tests` (after the rebase onto `f574ad984`) | 0 | `/private/tmp/arkdeck-s6-logs/a-build4.log` |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel --num-workers 4` (the whole remaining suite, 513 tests) | 0 | `/private/tmp/arkdeck-s6-logs/a-test2.log` |
| `python3 rust/scripts/generate-contract.py --write`, then `--check` | 0 | `/private/tmp/arkdeck-s6-logs/a-gencheck.log` |
| `npm --prefix docs/design/arkdeck-ds ci && npm --prefix docs/design/arkdeck-ds test` | 0 | `/private/tmp/arkdeck-s6-logs/a-ds.log` |
| `python3 scripts/ci/test_plan.py` | 0 | stdout |
| `python3 scripts/test_agent_pr_workflow.py` | 0 | stdout |
| `python3 rust/scripts/test_ci_execution.py` | 0 | `/private/tmp/arkdeck-s6-logs/a-tce.log` |
| `python3 scripts/ci/test_spk9_preview_missing.py` | 0 | stdout |
| `sh scripts/check-sdd.sh` | 0 | stdout |

Not run locally: `rust/scripts/test_contract_checks.py` (this host's Python
has no `jsonschema`; CI installs it), the App build-for-testing (the App
links none of what changed; CI's App lane runs it because `Package.swift`
changed), and no Rust source changed.

## CI

The first push (#2311, run 36439216948) was red in two lanes this PR caused:
the Rust host-independent checks (`spec/baselines/swift-single-v1.json` not
regenerated after `HDCFixtures.swift` left a generator input) and
`ds-interactions` (the seven orphaned localization keys). Both are fixed above;
the Swift and App lanes were green. The final result is recorded by the
follow-up PR.
