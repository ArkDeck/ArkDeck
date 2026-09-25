# Workspace admission asks the dispatcher, as Swift's does (TASK-XPA-015, M3)

A follow-up of #2199's independent review (F3), recorded as optional there and
taken as its own change. Swift's `RuntimeJobEngine.materializeTypedPlanBeforeAuthorization`
refuses an operation, in this order, when its provider reports it unavailable,
when the dispatcher does (`unavailableReason(providerID:)`), and when it needs
the Artifact store and there is none — each as `invalidInput`, "`<reference>`
is runtime unavailable: `<reason>`". The Rust workspace materialization
(`JobPlanner::materialize_workspace`, behind both `job.plan` and
`job.submit`) asked the provider and the Artifact store, never the
dispatcher.

Base: protected `main` `9bd452b55` (#2204). No stack. The checks below ran
on `1bfa52054` (#2202); after the rebase the three workspace oracle binaries
that read what moved (`workspace_read_oracle`, `workspace_availability_oracle`,
`workspace_tombstone_oracle`) ran again: 6 passed.

## What changes

After the provider's answer, the materialization asks
`WorkspaceComposition::dispatcher_unavailability` — the port of Swift's
workspace dispatcher chain that #2199 added for `operation.list` — and refuses
with its reason, as Swift does.

Only one case answers differently: with every executable the start-up
profiles pinned changed (or unreadable), Swift's combined resolver has no
executable left, and `workspace.inspect-source@1` — whose provider
(`WorkspaceProvider`) offers it whenever an inspector is configured and a
registered root exists — is refused:

    workspace.inspect-source@1 is runtime unavailable: provider executable is
    unavailable: failed("workspace registry has no available executable preset")

Every other workspace operation is already refused by its provider first in
that state (the profile's own pins drifted), and with no start-up profile the
provider refuses before the dispatcher is asked, so nothing else moves.

## Tests

`workspace_read_oracle::an_inspection_with_no_pinned_executable_left_is_refused_at_admission`
(hoststore): the read oracle's two profiles over their stand-in tools; the
inspection plans; every stand-in the profiles pinned changes; the inspection
is then refused at `job.plan` and at `job.submit` with Swift's code and
message, and the git status read by its provider first (the first profile's
`workspace.presetUnavailable`). With the new check disabled the test fails.

No Swift frame is recorded for this refusal. The refusal is the one Swift's
engine writes for any dispatcher reason (its shape is the provider refusal's,
which the workspace oracles record), and the reason is the dispatcher's own
text: `DescriptorBoundProcessDispatcher.unavailableReason` interpolates the
resolver's `RuntimeDispatchFailure.failed(...)`, which has no custom
description, as `failed("…")`. The same reason is what `operation.list`
publishes in that state since #2199 (declared there as ported from the
source, not recorded: #2199's oracle records the no-profile dispatcher's
reason only).

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s28-f-*.log`.

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0; the same with `--target
  x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`: exit 0, 0.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --no-fail-fast`: exit 0; 108 targets, 816 passed, 0 failed, 14 ignored
  (existing).
- The new check disabled (`.filter(|_| false)`): the new test fails; restored.
- `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `check-readonly.py
  --bin-dir <target>/debug` (validation venv): exit 0, PASS.
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: Swift (no Swift source or test changes), `generate-contract.py
  --check` and `check-contracts.py` (no contract input changed), the App,
  devices, the installed service.

## CI

Pending.
