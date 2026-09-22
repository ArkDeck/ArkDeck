# TASK-XPA-019 — App storage settings through the Rust owner

Base: protected main `9acccf8496360045054d7a26d17a7e7498aeee0f`.
Branch: `agent/xpa-019-app-storage-settings`.

The authenticated App ingress now accepts the existing `runtime.storage.policy`
and `runtime.storage.root` methods, forwarding each admitted request exactly once
to the same Control/SessionStore used by UDS. Previously the App could read
storage status but could not change policy or select/reset a Session root.
No storage owner, device authority, protocol schema or Catalog operation is added.

Policy requires exactly `expectedGeneration`, `totalQuotaBytes`,
`safetyMarginBytes`, and `retentionDays`: canonical positive Int64 decimal
strings. Root requires `expectedGeneration` plus either `rootPath` (a string)
or `resetToDefault: true`, never both. Extra/missing keys, wrong types and
noncanonical generations fail at ingress. Runtime remains responsible for
quota relationships, safe existing directories, root initialization, generation
CAS and durable publication. The existing authenticated peer check is unchanged.

Consumer contract: read fresh `runtime.storage.status`; its `sessionDomain`
contains the generation and policy/root values. Send one mutation with that
exact generation. `resourceConflict` permits a fresh status read, not an
automatic write retry. A lost reply may have committed; inspect status instead
of inventing success or repeating the mutation. Both mutation responses retain
the existing `artifactDomain`/`sessionDomain` envelope. B owns the ClientKit/UI
consumer; this PR does not modify App source or claim signed Mach acceptance.

## Local targeted checks

Cargo uses `CARGO_BUILD_JOBS=2`, isolated target
`/private/tmp/arkdeck-1330-rust-target`, manifest `rust/Cargo.toml`.

- `cargo test -p arkdeck-agentd`: exit 0, 80 passed, none ignored;
  `/private/tmp/arkdeck-app-storage-all-tests.log`. Includes real isolated
  SessionStore writes, UDS visibility, stale-generation refusal without file
  changes, policy semantics, root selection/reset, reopen persistence,
  malformed inputs/foreign peers with zero Control dispatch, unsafe roots and
  unreadable state without fallback. Dispatch counters prove one owner call per
  admitted request. No fake storage owner was used.
- Initial focused runs failed because the fixture omitted required directories
  and read the owner fields outside the wire `sessionDomain` envelope. Fixture
  setup and assertions were corrected; production validation was not relaxed.
  Logs: `/private/tmp/arkdeck-app-storage-{tests,focused}.log`.
- `cargo clippy -p arkdeck-agentd --all-targets -- -D warnings`: exit 0;
  `/private/tmp/arkdeck-app-storage-clippy.log`.
- `cargo fmt --all --check` and `sh scripts/check-sdd.sh`: exit 0;
  `/private/tmp/arkdeck-app-storage-{fmt,sdd}.log`.
- Contract generator check was not required: no contract inputs changed.

These are host integration checks with a synthetic peer context, not real signed
Mach/XPC identity evidence or REAL_DEVICE_PASS. No installed service or device
was accessed. ClientKit consumption, signed IPC and G5 remain incomplete.

## CI

Pending the agent-branch PR and current-head CI. Full unified checks run in CI;
pending/skipped jobs are not passes. Maintainer review remains required.
