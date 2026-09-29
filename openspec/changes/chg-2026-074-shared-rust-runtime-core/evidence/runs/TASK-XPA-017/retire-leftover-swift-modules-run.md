# Retire the Swift modules only tests still linked, and the Swift lanes' ArkForge key

TASK-XPA-017, follow-up to "Delete the Swift Runtime targets and the ArkForge
Swift SDK" (#2312), base `d247f62a6` (#2314), 2026-09-29. Host-only: no
installed Runtime, launchctl, device, signing identity or credential was used;
nothing here is `REAL_DEVICE_PASS`.

## What changed

- **Deleted Swift targets** `ArkDeckRuntime`, `ArkDeckAgentClient` and
  `ArkDeckBootstrap` (library products, targets and sources). A search over
  `ArkDeckApp/`, the Xcode project, `ArkDeckClientKit`, `ArkDeckCore` and
  `ArkDeckTraceAdapter` found no production import; their users were tests:
  - deleted with them: `BootstrapToolRustOwnerTests`,
    `CLIDomainExecutorEvidenceOracleContractTests`,
    `CrashSymbolizerOracleContractTests`,
    `DevEcoToolchainPinOracleContractTests`,
    `HardwareEvidenceProjectionContractTests`, `JSCrashSymbolizerContractTests`,
    `ToolSelectionRegistryOracleContractTests`. Their recorded oracles stay under
    `rust/tests/fixtures/{crash-symbolizer-oracle,deveco-toolchain-pins,domain-executor-evidence,tool-selection-registry}`
    and remain replayed by the Rust tests that already cite them;
  - `DeviceControlFacadeContractTests` dropped an unused `@testable import ArkDeckRuntime`;
  - `APIBaseline` no longer links the two products; the Runtime request/rejection
    surface it asserts is `ArkDeckCore`'s, so only `HumanActionRequired` and the
    `AgentClient` surface left with the modules.
- `ArchitectureBoundaryContractTests`: the exact target set is now Core,
  ClientKit, TraceAdapter, `ArkDeckFakeHDCFixture` and the four test targets;
  `ArkDeckContractTests` links ClientKit, Core and the fixture; the three names
  join `deletedTargets` so they cannot return.
- `rust/crates/arkdeck-hoststore/examples/tool_registry_read.rs` (the adapter
  only `BootstrapToolRustOwnerTests` ran) deleted; `rust/README.md` says so.
- `scripts/ci/plan.py` / `test_plan.py`: the `ArkDeckRuntime` App-package prefix
  and the two deleted source paths are gone. `docs/ArchitectureRules.md`, the
  `SystemLogger.swift` comment and `scripts/bench/control.py`'s docstring follow.
- **CI:** no Swift package depends on ArkForge any more, so `swift-tests` and
  `app-build` in `.github/workflows/swift-ci.yml` no longer configure or remove
  the ArkForge deploy key. The Rust lanes keep `arkforge-cargo-fetch.sh`, which
  still calls `arkforge-package-auth.sh` (its header now names that one caller).
  `scripts/test_agent_pr_workflow.py`: the deploy key appears once in Swift CI
  (the Rust lane's secret), and the Swift lanes must not handle it (mutation:
  re-adding the setup step to `app-build` is refused); the auth script's
  hardening tokens stay pinned.
- `scripts/check_sdd.py`: the two debt-ledger reasons no longer cite the deleted
  `Sources/ArkDeckOpenHarmony` files; entries and counts are unchanged.

## Local targeted checks

Logs under `/private/tmp/arkdeck-cleanup-logs/` (not committed);
`CARGO_TARGET_DIR=/private/tmp/arkdeck-cleanup-target CARGO_BUILD_JOBS=2`.

| Command | Exit | Log |
| --- | --- | --- |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ArchitectureBoundaryContractTests\|APIBaselineGateContractTests\|DeviceControlFacadeContractTests\|SettingsApplicationFacadeContractTests\|DeviceListApplicationContractTests'` (builds every test target) | 0 (24 tests) | `p2-swift-test.log` |
| `sh scripts/ci/run-xcodebuild.sh` (unsigned Debug build-for-testing) | 0 (TEST BUILD SUCCEEDED) | `p2-xcodebuild.log` |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | — |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore --all-targets -- -D warnings` | 0 | `p2-clippy.log` |
| `python3 scripts/test_agent_pr_workflow.py` | 0 (16 tests) | — |
| `python3 scripts/ci/test_plan.py` | 0 (40 tests) | — |
| `python3 -m unittest bench.test_harness` (from `scripts/`) | 0 | — |
| `sh scripts/check-sdd.sh` | 0 | — |

`python3 scripts/test_check_sdd.py` was not run locally (this host's Python has
no `yaml`); SDD Guard runs it. No contract input changed.

## CI

To be recorded by the docs-only follow-up (PR number, run id, conclusion).
