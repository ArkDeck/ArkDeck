# `workspace.project.show` answers why an operation is unavailable, as Swift does (TASK-XPA-015, M3)

#2199 ported the project projections and kept one declared difference: a
`workspace.project.show` answered every operation's `reason` and `reasonCode`
as `null`, because the published schema had them as `null` only and the Rust
control layer rewrites an answer outside its schema to `internalError`. #2197
widened that schema from a recorded Swift frame. With it, `show` answers each
operation exactly as Swift's `encodeRegisteredWorkspaceProject` does — the
same projection `workspace.project.list` already answered — and the
declared difference is gone.

Base: `agent/xpa-015-workspace-project-show-widening` (#2197, head
`81008dd36` on protected `main` `25511c249`). **Stacked on #2197: merge #2197
first.** Without #2197's schema this change's `show` answers would be
rewritten.

## What changes

- `WorkspaceProjectStore::handle` (`workspace.project.show`) answers the
  composed projection unchanged; the helper that nulled the two members is
  removed.
- `workspace_availability_oracle` compares every recorded `show` frame of
  `WorkspaceAvailabilityOracleContractTests` as recorded — an active project's
  unavailable operations carry `workspace_preset_unavailable` /
  `workspace.presetUnavailable` and the other codes Swift gave — and every
  answer is admitted by the published (widened) method schema.

Also fills the CI sections of #2195, #2199 and #2204's run records.

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target, over #2197's widened
schema; logs are `/private/tmp/arkdeck-s28-g-*.log`.

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0; the same with `--target
  x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`: exit 0, 0.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --no-fail-fast`: exit 0; 109 targets, 821 passed, 0 failed, 14 ignored
  (existing); `workspace_availability_oracle` compares every `show` frame
  as recorded.
- `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `check-readonly.py
  --bin-dir <target>/debug` (validation venv): exit 0, PASS.
- `python3 rust/scripts/generate-contract.py --check`: exit 0 (this change
  touches no contract input; #2197's are the stack's).
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: Swift (no Swift change; the frames are #2199's recording),
  `check-contracts.py` (#2197 ran it for the inputs), the App, devices, the
  installed service.

## CI

Pending.
