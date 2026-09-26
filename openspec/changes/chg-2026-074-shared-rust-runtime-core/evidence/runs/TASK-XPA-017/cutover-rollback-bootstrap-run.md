# TASK-XPA-017 — Explicit rollback after a failed Rust bootstrap

The runbook's Appendix B item 18 had no test of its explicit rollback path after
the helper exchange. The new `runtime_service` integration test drives the actual
Rust service-install owner through that boundary in a private temporary home:

1. Install a Swift helper fixture through `update_leaf` and retain its bytes,
   plist, receipt and an opaque Runtime-state fixture.
2. Cut over to a Rust helper fixture. Both preflight passes answer clear; the
   snapshot, helper exchange, plist and receipt complete, then the recording
   launchctl runner refuses bootstrap with exit 1. The service stays stopped;
   no automatic rollback is claimed.
3. Call `update_leaf` explicitly with the retained `.rollback/ArkDeckAgent.app`.
   The staging copy must precede rotation of that same rollback slot. Swift's
   helper, plist and receipt are restored byte-for-byte; Runtime state and the
   snapshot remain unchanged. The rollback slot now retains the Rust helper.

This closes the bounded source-level test gap, not XPA-AC-9 or G5 acceptance.
Both helpers and launchctl are fixtures, and helper trust is substituted only
inside the existing test harness. There is no real launchd, Keychain, signing,
installed state or device interaction. The signing-preset refusal is unchanged.
No production implementation or safety policy changed.

## Local targeted checks

Target directory: `/private/tmp/arkdeck-takeover-d79c-target`; `CARGO_BUILD_JOBS=2`.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test runtime_service
  a_failed_rust_bootstrap_can_explicitly_roll_back_without_rewriting_runtime_state`:
  exit 0, one pass; `/private/tmp/arkdeck-cutover-rollback-test.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli`: exit 0, 408 pass;
  `/private/tmp/arkdeck-cutover-rollback-cli-tests.log`. The initial sandboxed run
  was denied local socket binding; the rerun used permission for the test's
  private IPC. No crate depends directly on `arkdeck-cli`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml` and `git diff --check`:
  exit 0.
- `sh scripts/check-sdd.sh`: exit 0, 121 acceptance IDs;
  `/private/tmp/arkdeck-cutover-rollback-sdd.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-cutover-rollback-clippy.log`. This final check ran
  after the coordinated UI exclusive window was released.

## CI

PR/run pending publication. Maintainer review
and actual installed rollback acceptance remain required.
