# TASK-XPA-014 — Rust foreground HDC exit recovery boundary

Base: protected main `37453467d` (#2105). This ports the existing
`HeadlessHDCServerHost.Lifecycle` / daemon `onUnexpectedExit` behavior on macOS;
it introduces no new replay, adoption, capability or device operation.

Previously the Rust managed host refused subsequent dispatch after its original
foreground HDC died, but the daemon kept serving indefinitely. The process
composition now arms a weak-reference monitor after successful managed startup.
An unexpected end (including an unreadable wait status) exits the Runtime with
status 70, matching Swift's crash boundary so launchd can rebuild the complete
provider graph. It does not wait for a client request to notice the death.

The existing confirmed restart executor marks the original child's exit
expected for twenty seconds, only after its durable launch-window marker and
while holding the launch lease. The window is bounded like Swift's. Normal
stop marks the foreground lifecycle stopping before ending the child. Once the
original child's exit is classified, the monitor ends; it does not adopt or
kill a background replacement, nor infer a successful external effect from
that exit. The monitor owns no Runtime authority and performs no HDC command.

Local tests kill only a kernel-proven isolated fake child's exact PID, observe
daemon exit 70, start the same binary with the same state root, and verify a
fresh HDC identity, recovered control socket/store ownership, working status,
and normal exit 0. Existing tests cover confirmed restart's expected exit,
unknown lifecycle outcomes, normal stop and foreign endpoint refusal. A clock
unit test checks the accepted twenty-second boundary without waiting or changing
that budget. This is isolated host-process evidence, not launchd deployment or
REAL_DEVICE_PASS.

## Local targeted checks

Rust uses `CARGO_BUILD_JOBS=2` and independent
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd managed_hdc`:
  exit 0, 4 passed; `/private/tmp/arkdeck-1330-hdc-exit-targeted.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test managed_hdc_process`:
  exit 0, 7 passed; `/private/tmp/arkdeck-1330-hdc-exit-process.log`.
- `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0,
  process-test prerequisite; `/private/tmp/arkdeck-1330-hdc-exit-cli-build.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd`: exit 0,
  64 passed, 0 failed/ignored; `/private/tmp/arkdeck-1330-hdc-exit-tests.log`.
- Final `managed_hdc` subset after preserving the unknown-outcome guard around
  expected-exit setup: exit 0, 4 passed;
  `/private/tmp/arkdeck-1330-hdc-exit-final-targeted.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings`,
  `cargo fmt --all --check --manifest-path rust/Cargo.toml`, and
  `sh scripts/check-sdd.sh`: exit 0;
  `/private/tmp/arkdeck-1330-hdc-exit-clippy.log`,
  `/private/tmp/arkdeck-1330-hdc-exit-fmt.log`,
  `/private/tmp/arkdeck-1330-hdc-exit-sdd.log` (zero errors/warnings).
- No complete local unified gate or performance/RSS measurement. The polling
  monitor has fixed state and one thread; its production performance remains
  subject to the existing performance/soak acceptance, not inferred from tests.
- No installed Runtime, LaunchAgent, hardware evidence or real device changed.

## CI

Pending this PR. The base #2105 passed its four selected Rust jobs and swift
aggregate in `35701423731`, with guards `35701423514` / `35701443334` passing.
App/Swift tests/design-system interactions were skipped, not counted as passes.
#2105 was separately reviewed and merged by the maintainer.

## Remaining M1 boundaries

This completes the original foreground child's accepted unexpected-exit path,
not all daemon recovery. Background replacement lifetime across daemon
shutdown/relaunch still needs an exact recovery/ownership proof before cutover.
Trusted USB relations, signed/published deployment, CLI and App acceptance, and
pure-Rust GJ-1 REAL_DEVICE_PASS remain outstanding. ArkForge's current public
observation API exposes digests, not the raw serial and attachment facts the
existing DAYU200 relation matcher consumes; those cannot be manufactured from
fixture relations. M1/G5 are not complete.
