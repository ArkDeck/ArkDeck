# TASK-XPA-014 — Closed Debug templates through Rust Jobs

Base: protected main `fcfa9893e3350a3215386818686d9bc950436c04` (#2120).
Branch: `agent/xpa-014-debug-template-jobs`.

The existing `debug.template@1` operation now materializes and executes through
Rust Job admission, the bound HDC provider, durable intent verification, Artifact
publication and recovery. All four published template identities lower to their
existing fixed argv and individual timeout/output budgets. Caller command text
and stale binding revisions fail before dispatch. Read-only admission needs no
mutation capability authority. The operation remains ineligible for physical
observation evidence.

Successful Jobs publish exact stdout bytes as the sensitive `template-output.txt`
and a derived `template-report.json`. Truncated output, nonzero exits and zero-exit
transport failures fail verification. Lost process outcomes remain unknown;
restart recovery, reconciliation and resubmission do not replay the template.
The existing App client `ArkDeckApp.DebugWorkspace.Commands` reaches this Job path
without widening its ingress allowlist. Generic CLI Job commands can use the same
operation; the `debug template` convenience command is separate remaining work.

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2` and
`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`.

- Targeted template planner/admitter/runner/Artifact/recovery integration: exit 0;
  `/private/tmp/arkdeck-template-run.log`. Four templates plus offline, nonzero,
  truncated and unobservable outcomes; sensitive reads require explicit opt-in.
- App ingress with a real private synthetic HDC subprocess: exit 0;
  `/private/tmp/arkdeck-template-app.log`. Success publishes readable artifacts;
  killed process retains unknown state across reopening and cannot replay.
  Initial failures exposed a missing planner journal mapping and a test request
  missing the wire-required empty provenance object; both were corrected.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-hdc
  -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak`: exit 0, 726 passed,
  14 existing ignored tests; `/private/tmp/arkdeck-template-tests.log`.
  The ignored hardware/installed-tool/crash-child fixtures are not passes.
- `cargo clippy` for those same four crates with `--all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-template-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `/private/tmp/arkdeck-template-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0; `/private/tmp/arkdeck-template-sdd.log`.
  No contract inputs changed; generator check and full unified local gate were
  not required or run for this slice.

These are isolated host/synthetic checks, not signed production IPC, physical
hardware evidence or REAL_DEVICE_PASS. No installed Runtime or device changed.

## CI

Pending branch push and maintainer review. No pending or skipped job is a pass.
G5 remains incomplete; native USB provenance, signed deployment, physical GJ
acceptance, remaining operations and final authority cutover are still required.
