# Windows health provider inventory and workspace continuation

Date: 2026-10-05. Task: TASK-XPA-011. Host tests only; no hardware acceptance
or device dispatch. Based on protected `main` `7133461b6`.

## Behavior

`health` now reads `HostServices::registered_provider_ids`, the inventory of
ports already assembled into the Host. It sorts and deduplicates the IDs.
The inventory reads only composed Option fields: HDC (including the read-only
port), AnalyzerProfiles, WorkspaceComposition and FlashPlanning. These map to
the Catalog IDs `hdc`, `analyzer`, `workspace` and `arkforge` respectively.
Absent ports remain absent. An unavailable assembled provider is still listed.

This is deliberately separate from `doctor` and `operation.list`, whose fresh
availability projection checks executable readiness and mutation state.
Health does not call that projection, read tools or durable owners, acquire
mutation authority, create a retention catalog, or dispatch. Provider
registration does not assert operation availability or target admission.

Delegated minor decision, pending the next rulings batch: repair the health
provider parity defect through assembly inventory, as requested in the Windows
handover. No admission policy, identity gate, capability format or safety
invariant changes.

## Regression evidence

- `arkdeck-control/tests/health_providers.rs` exercises local and App health
  ingress; availability, host observation and HDC calls panic. It checks the
  sorted, unique provider list and empty composition.
- `host_tests::health_inventory_does_not_initialize_session_or_mutation_state`
  runs on macOS and Windows. With Job, capability and Session owners assembled,
  two health reads leave every directory and byte in the owner tree unchanged
  and leave the Session retention catalog absent. An unavailable ArkForge port
  remains listed without consulting its dispatcher. This preserves the
  readiness probe used before `check-session-resources.py` seeds its Sessions.
- `spawning/workspace_continuation_cli.rs` uses the existing signed test daemon
  and real CLI with the `observe-device` and `workspace-continuation` Swift
  oracles. Health leaves the owner files and fake-HDC log unchanged. A completed
  read-only source Job produces Swift's continuation draft and request bytes;
  submit accepts without dispatch; run sends the oracle Job calls once; a
  repeated run sends nothing; an invalid identity is refused before submit.

The integration layer includes the module registration and measured leaves
`workspace.continuation.submit` and `workspace.continuation.run`, together with
the generated coverage and census. The historical oracle is not re-pinned.

## Local targeted checks

Environment: `CARGO_TARGET_DIR=D:/cargo-target/health-continuation`,
`CARGO_BUILD_JOBS=2`; the configured development signer is used without an
identity bypass. Heavy checks run through the shared gate slot runner.

- `cargo test -p arkdeck-control`: exit 0; 36 reported passes, no failures or ignores.
  Log: `D:/src/ArkDeck-wt/tools/health-continuation-control.log`.
- `cargo test -p arkdeck-agentd -p arkdeck-soak -- --nocapture`: exit 0;
  179 reported passes, no failures, four existing ignored entries (three
  subprocess helpers and one opt-in signed soak). Existing live-HDC and DevEco
  opt-in rows report that they were not run because their environment inputs
  were absent. The new health and signed continuation regressions ran without
  skips. Spawning reported 46 passes, no failures and three helper ignores.
  Log: `D:/src/ArkDeck-wt/tools/health-continuation-agentd.log`.
- `cargo build -p arkdeck-cli`: exit 0.
  Log: `D:/src/ArkDeck-wt/tools/health-continuation-build-cli.log`.
- `cargo clippy -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0.
  Log: `D:/src/ArkDeck-wt/tools/health-continuation-clippy.log`.
- With verified C: 8.3 `TEMP` and `TMP`,
  `cargo test -p arkdeck-agentd --bin arkdeck-agentd
  health_inventory_does_not_initialize_session_or_mutation_state -- --nocapture`
  and `cargo test -p arkdeck-agentd --test spawning
  workspace_continuation_cli::a_completed_job_is_continued_over_the_signed_test_daemon
  -- --nocapture`: both exit 0; one active test each, no skips or ignores.
  Logs: `D:/src/ArkDeck-wt/tools/health-continuation-short-health.log` and
  `D:/src/ArkDeck-wt/tools/health-continuation-short-cli.log`.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: exit 0, zero errors/warnings.
  Log: `D:/src/ArkDeck-wt/tools/health-continuation-sdd.log`.
- `git diff --check`: exit 0.
- `cargo fmt -p arkdeck-control -p arkdeck-agentd --check`: exit 0.
  Log: `D:/src/ArkDeck-wt/tools/health-continuation-fmt-check.log`.
  `cargo fmt --all` hits the Windows command/path-length limit (OS error 206)
  before formatting in this checkout; both changed crates were formatted and
  checked separately.

Final integration checks, after layering on #2579, all exit 0:
`cargo build -p arkdeck-cli`; `cargo test -p arkdeck-cli` (264 reported passes);
`cargo test -p arkdeck-control` (36 passes); the signed continuation spawning
test and health inventory unit test with verified 8.3 `TEMP`/`TMP` (one pass each);
clippy for CLI, Control, Agentd and Soak with all targets and warnings denied;
`cargo fmt --all --check`; SDD; `git diff --check`; and the CLI contract check
(242 clean). Commands use `--manifest-path rust/Cargo.toml`. Logs are in
`D:/src/ArkDeck-wt/tools/logs/health-layer-{build,cli-tests,control-tests,short-tests,inventory-test,clippy,fmt,sdd}.log`.
The full-workspace fmt check succeeds in the shorter integration checkout.

## CI

Not run on this unpushed local layer. The integration PR must run the macOS
`Rust contract parity (xcode-27)` lane, including `check-session-resources.py`.
That script requires macOS Unix sockets, `fcntl` and its development composition
and cannot run on this Windows host. Native macOS/Linux results remain for CI.
No task, ruling, platform status or hardware evidence is changed.

This layer depends directly on #2579 (Windows crash symbolization). Its CI
result will be recorded after completion; the first layer's Swift CI run is
`37263980574`, in progress when this continuation increment was prepared.
