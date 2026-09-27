# Rust soak socket lifecycle

Date: 2026-09-27. Task: TASK-XPA-025. Initial base: `62d49e8f0a3a63a9cd4f2981267c3ada592d21d9`.
Final integration base: `4c3ed7491a96921a5a48f908f168cd27438e1064` (#2291 Artifact cache).

The fixture now exercises the same serving loop as the Rust daemon, with the
existing authenticated transport and Control/Client codec. Each generation
binds its private `d/ctl.sock`, creates Jobs through `job.submit`, `job.run`,
`job.cancel` and `job.status`, then stops accepting and drains within five
seconds before releasing its owners. It never installs process-global signal
handlers. Production retains its 20-second drain, ArkForge-before-HDC stop order
and exit status. The shared library exports transport only, not production Host
or device composition.

The comparison is the Swift fixture's `executeCycle` and `startDaemon` in
`Packages/ArkDeckKit/Tests/ArkDeckRuntimeSoakFixture/main.swift`: server start,
owner-driven clean preflight recovery, client-driven new Jobs, five-second drain.
Swift `AgentClient.exchange` opens a new connection for each business request;
the Rust fixture does likewise and uses the existing client's health handshake.
Both are same-process owner/server lifecycles, not OS-process restarts. The Rust
private socket suffix is deliberately shorter than `/agentd.sock`, so the
benchmark harness's existing legal path boundary remains usable.

A completed drain releases handler-owned Control/Host resources before reporting
completion. A timed-out or failed accept generation retains its kernel directory
lease while its handlers still hold state, preventing a successor from binding.
The fixture refuses incomplete drain and does not proceed to another cycle.
The workload keeps the existing simulated provider, deterministic cancellation,
clean preflight recovery and fail-closed unknown-intent checks. Metrics retain
`arkdeck-runtime-soak/v1` unchanged.

## Local targeted checks

All Cargo commands use `CARGO_BUILD_JOBS=2` and the task-private target
`/private/tmp/arkdeck-takeover-d79c-target`. Tests with Unix sockets require the
controlled host execution path: the initial sandbox run failed at bind with
EPERM, including unchanged drain tests; the identical command passed after
permission elevation. No assertion or timeout was relaxed.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --lib`: exit 0,
  7 passed. Log: `/private/tmp/arkdeck-socket-agentd-lib.log`. New tests cover
  normal resource release/rebind, blocked-handler deadline, accept error, and
  idle/partial-frame drain with actual sockets and owner locks.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-soak`: exit 0,
  11 passed. Log: `/private/tmp/arkdeck-socket-soak-test.log`. Includes unchanged
  unknown-outcome refusal, oversize root refusal before publication, and the
  existing benchmark's 103-byte socket boundary.
- `rust/scripts/check-readonly.py` `assert_boundaries()` only: exit 0. Exact
  dependency edges add agentd/client/control to the soak; no protocol clone.

- All-target Clippy with `-D warnings`: exit 0 for platform, agentd, soak and
  direct consumers bootstrap, client, cli, hoststore, provider-hdc,
  provider-arkforge, provider-workspace and rockchip-binding. Log:
  `/private/tmp/arkdeck-socket-clippy.log`.
- Workspace format, diff check and `sh scripts/check-sdd.sh`: exit 0. SDD log:
  `/private/tmp/arkdeck-socket-sdd.log`.
- The first same-set test compilation exited 101 with ENOSPC during hoststore
  linking, before tests ran. Log: `/private/tmp/arkdeck-socket-affected-test.log`.
  Only this task's inactive incremental cache was removed after all compiler
  processes ended; binaries, dependencies and logs were retained. The retry
  uses unchanged code and assertions.

- The same 11-crate `cargo test` retry: exit 0, 2,038 passed, 0 failed,
  24 ignored, including custom harness summaries. Log:
  `/private/tmp/arkdeck-socket-affected-test-retry.log`. Includes production
  ArkForge/HDC stop ordering and daemon/client/storage integration tests. This
  broad direct-consumer set exceeded the ten-minute local target; no unified
  gate or unrelated Swift/App lane was added.

Initial-base release smoke: exit 0, 30 configured seconds, 4 cycles plus final
recovery/drain, 40 terminal Jobs (36 succeeded/4 cancelled), 36 verified Artifact
Jobs, active Jobs/cleanup debt/child count all zero, socket removed. FD stayed
15; RSS high-water growth was 868,352 bytes. Binary SHA-256:
`41edf583febc0a0dc96cc2bfe6615f09afbeb9840508914d3a1fd443dadcdbf1`.
Raw record: `/private/tmp/arkdeck-socket-smoke-base62d-result.json` and log
`/private/tmp/arkdeck-socket-smoke-base62d.log`. This predates #2291; it is not
substituted for the final combination below.

Final-base combination checks: shared-server 7 and soak 11 passed (exit 0),
platform/agentd/soak all-target Clippy passed (exit 0), locked release build passed
(exit 0, `CARGO_INCREMENTAL=0`). Logs:
`/private/tmp/arkdeck-socket-final-{agentd-lib,soak-test,clippy,release-build}.log`.
No repeat of the full 11-crate test suite after the conflict-free rebase.

Final release command: `arkdeck-soak --state-directory /private/tmp/adksock.4tc49gre
--duration-seconds 30 --restart-interval-seconds 5 --jobs-per-cycle 10` (exit 0).
Four cycles plus final recovery/drain produced 40 terminal Jobs (36 succeeded,
4 cancelled), 36 verified Artifact Jobs, zero active Jobs/cleanup debt/children,
and no remaining socket. FD stayed 15; RSS high-water growth was 704,512 bytes.
These are short lifecycle observations, not a performance budget result.

Source Rust tree: `8e0cec34d2e6331654be9fed47de5790402c4e15` (final base plus this
change; subsequent edits are evidence only). Binary SHA-256:
`c9ab8e5f1d124e54d83f1174fbd454ba44c2531938be42547b9a565c977b0c1c`.
Raw command/identity/metrics: [socket-lifecycle-smoke.json](socket-lifecycle-smoke.json).
Per-cycle output: [socket-lifecycle-smoke.log](socket-lifecycle-smoke.log).

## CI

Pending bot PR and exact-head GitHub checks. No local unified gate was run.

This change does not revise the prior four-hour owner-only evidence at source
`443e805ef7529e61a9860ccae7011c072142e52a` (run `36291225535`). It does not provide a
new four-/24-hour result, reference performance baseline, hardware acceptance,
installed Runtime cutover, or G5/G7 approval. The short smoke is a lifecycle
check; its resource numbers are not performance acceptance.
