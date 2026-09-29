# TASK-XPA-017 — delete the Swift Runtime targets (macOS, 2026-09-28)

S6, second PR (maintainer task prompt 2026-09-28 §4 S6; design r10 route C).
It follows the first S6 PR (#2311, TASK-XPA-018, merged as `32db20b10`),
which deleted the Swift CLI and took every test off the targets deleted here.
Base: `main` `32db20b10`. Needs maintainer review. TASK-XPA-017 stays `blocked`: GJ-1..5 on
the pure Rust daemon, the LaunchAgent switch and the lock and traceability
flip are phase A.

Nothing here is device evidence. No Rust source, control schema, corpus,
Catalog, `openspec/contracts`, `openspec/specs` or constitution change. Every
oracle the deleted code recorded stays committed and is replayed by the Rust
crates.

## What is deleted

- The six Swift Runtime targets and their products: `ArkDeckAgentDaemon`,
  `ArkDeckAgentDaemonMain` (the `arkdeck-agentd` executable),
  `ArkDeckWorkflows`, `ArkDeckStorage`, `ArkDeckProcess`,
  `ArkDeckOpenHarmony`. The dashboard's "Swift targets deleted" count
  (`evidence/macos-remaining.md`) reads `Package.swift` and is now 6/6.
- `ArkDeckAgentComposition` (sources under `Sources/ArkDeckWorkflows`) and
  `ArkDeckLaunchAgent` (`LaunchAgents/LaunchAgentService.swift` and its plist
  template; the Rust CLI's `runtime service` owns the LaunchAgent).
  `LaunchAgents/README.md` stays as documentation.
- The Journal, Engine and Soak crash/soak fixtures, and the RuntimePort and
  FakeHapSigner fixtures whose only consumers were tests the first PR deleted.
  The Rust test `fake_hap_signer.rs` compiles its vendored copy
  (`rust/tests/fixtures/fake-hap-signer/main.swift`) and already tolerates the
  Swift original's absence (the contract views never carry it), so it is left
  unchanged.
- The ArkForge Swift SDK dependency: gone from `Package.swift`, from both
  `Package.resolved` files (the package's and the Xcode workspace's; no other
  pin changes, and SwiftPM leaves both files byte-identical on `resolve`), and
  from `APIBaseline`, whose imports and surfaces of the deleted modules go too.

## What changes

- `rust/scripts/check-arkforge-pin.py` now holds the Rust pin alone: every
  ArkForge crate in `rust/Cargo.toml` at one full revision, locked from that
  revision, never named outside the workspace, and `Package.swift` must not
  reference ArkForge again. `--run-vectors` still reruns ArkForge's wire and
  StepPermit vectors at the pin. Comments in `rust-ci.yml`,
  `scripts/ci/arkforge-cargo-fetch.sh` and `scripts/test_agent_pr_workflow.py`
  no longer say the pin comes from `Package.swift`.
- `ArchitectureBoundaryContractTests`: the set of targets is now exact (the
  six remaining libraries, `ArkDeckFakeHDCFixture` for the App UI tests, the
  four test targets), every deleted target's name and source directory is a
  permanent absence, `Package.swift` may declare neither an `arkdeck` nor an
  `arkdeck-agentd` executable nor the ArkForge package, and the App's code
  requirement may not admit the façade identity.
- The App admits only the standalone Rust daemon: `ArkDeckAgentXPC`'s server
  identity requirement drops `com.arkdeck.agentd.facade` (#2309 retired the
  façade). Its mirrors change with it:
  `scripts/release/build_macos_release.py` (and its test),
  `scripts/ci/installed_spk8_negatives.py` and `rust/scripts/macos-xpc-probe.swift`.
  The version and build pins are unchanged.
- `RuntimeHistoryApplicationContractTests` reads the three facades from
  ClientKit only and no longer reads the deleted Swift engine;
  `AutoUpdateContractTests` expects six direct package dependencies and no
  ArkForge pin.
- `scripts/ci/plan.py`: the App's package targets are ClientKit, Core,
  Runtime and the Trace adapter; the Storage journal sources and the Swift
  control-frame recorder leave the Rust contract inputs. `test_plan.py`
  follows. `swift-ci.yml` needs no edit: the required `swift` aggregate and
  its lanes are unchanged, and the Swift lane still runs every remaining
  test (ClientKit, Core, Trace adapter, contract tests) while the App lane
  still builds the App and its UI tests for testing.
- `docs/ArchitectureRules.md` describes the Swift side as it now is.

## Left

- `ArkDeckRuntime`, `ArkDeckAgentClient` and `ArkDeckBootstrap` stay: they were
  not in S6's deletion list, depend only on Core, and are linked by the
  contract tests, not by the App. Whether they go too is a follow-up call.
- The Swift and App lanes still configure the ArkForge deploy key
  (`arkforge-package-auth.sh`), which they no longer need; removing it edits
  the workflow contract `test_agent_pr_workflow.py` enforces, so it is left to
  a separate change.
- Rust-side façade constants (`FACADE_CODE_REQUIREMENT`,
  `rust/crates/arkdeck-agentd/build.rs`) belong to #2309's lane.
- `scripts/check_sdd.py` still words two registry-debt reasons with the
  deleted `Sources/ArkDeckOpenHarmony` files; the ledger's counts are
  unaffected.

## Local targeted checks

| Command | Exit | Log |
| --- | --- | --- |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build --build-tests` | 0 | `/private/tmp/arkdeck-s6-logs/b-build1.log` |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --parallel --num-workers 4` (the whole suite, 514 tests, incl. the APIBaseline gate; rerun after the rebase onto `32db20b10`) | 0 | `/private/tmp/arkdeck-s6-logs/b-test4.log` |
| `sh scripts/ci/run-xcodebuild.sh` (App and UI-test build-for-testing; rerun after the rebase) | 0 | `/private/tmp/arkdeck-s6-logs/b-xcode3.log` |
| `swift package resolve` on a copy of the manifest and resolved file | 0 | resolved file unchanged |
| `python3 rust/scripts/check-arkforge-pin.py` | 0 | stdout |
| `python3 scripts/ci/test_plan.py` | 0 | stdout |
| `python3 scripts/test_agent_pr_workflow.py` | 0 | stdout |
| `python3 scripts/release/test_build_macos_release.py` | 0 | `/private/tmp/arkdeck-s6-logs/b-release2.log` |
| `python3 scripts/ci/test_installed_spk8_negatives.py` | 0 | `/private/tmp/arkdeck-s6-logs/b-spk8.log` |
| `sh scripts/check-sdd.sh` | 0 | stdout |

Not run locally: `check-arkforge-pin.py --run-vectors` and the rest of the
Rust lane (no Rust source changed; CI runs the lane because `scripts/ci/` and
`rust/scripts/` changed).

## CI

First run while stacked on #2311 (#2312, run 36441737694): Swift, App,
design and Rust host-independent lanes green, the Linux and Windows Rust
workspaces green; the macOS Rust workspace red in the published contract
view only, at `arkdeck-soak`'s
`the_existing_benchmark_socket_path_boundary_remains_valid_for_seeding`
("descriptors 24 / 16"). Judged an invalid run by the four criteria: no Rust
source changed here, it is a known load-sensitive resource bound, it passed in
twice elsewhere in the same job and in #2311's run of the same Rust tree, and nothing in
the diff reaches it. The rebase onto `32db20b10` reran it.

Final: #2312 head `9cfd2fe0d`, Swift CI run 36449252325 success (the `swift` aggregate and every selected lane), SDD Guard run 36449252163 success; squash-merged as `57ba8e36f` on 2026-09-29. Recorded by the docs-only follow-up (TASK-XPA-017).
