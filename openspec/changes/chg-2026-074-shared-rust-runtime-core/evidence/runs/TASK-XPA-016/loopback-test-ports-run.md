# TASK-XPA-016 — host tests take loopback ports below the ephemeral range

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane B, test-only. Host measurement only.
Base: protected main `e5daa945`.

## Why

The macOS 26 CI runners hand a port just released straight back to the next `bind(0)`. Tests
that take a port from `bind(0)`, release it and let another process listen on it therefore
collide systematically there (never on the macOS 27 development host, whose ephemeral ports are
random):

- `arkdeck-agentd tests/managed_hdc_process.rs` — fixed by #2042 with a shared issued set; its
  `issued_listener()` still probed with `bind(0)`, so while retrying it could hold, for a
  moment, a port another test had just been issued.
- `arkdeck-provider-hdc tests/lifecycle.rs` — #2047's CI (run 35448949993) went red in
  `a_nonzero_exit_leaves_the_outcome_unknown`: "no existing selected HDC process owns the exact
  endpoint". A neighbour's `free_endpoint()` probe, handed the port just released, was holding
  it when the test's fake server tried to bind, and the lease found the probe's owner instead.
- `arkdeck-provider-hdc tests/managed_server.rs`, `arkdeck-agentd tests/control_action_host_process.rs`,
  `arkdeck-agentd` `managed_hdc` unit test and `arkdeck-platform tests/loopback_server_lease.rs`
  take their ports the same way.

## What changed

`rust/tests/support/loopback_ports.rs`, included by each of those tests
(`mod loopback_ports { include!(..) }`): a port is chosen at random from the lower half below the
kernel's ephemeral range (`net.inet.ip.portrange.first` on macOS, `ip_local_port_range` on
Linux), recorded in the binary's issued set before it is tried, and checked free by binding it —
then held (`issued_listener`) or released for the process that will listen on it
(`free_endpoint`, `free_port`). No `bind(0)` anywhere on the host lands in that range, and no two
tests of one binary are handed the same port. Each test's own helper is replaced; nothing else in
the tests changes.

## Local targeted checks

With `CARGO_BUILD_JOBS=2`, after `cargo build -p arkdeck-cli`:

- `cargo fmt --all --check`; `cargo clippy -p arkdeck-provider-hdc -p arkdeck-agentd
  -p arkdeck-platform --all-targets -- -D warnings` (host and `x86_64-unknown-linux-gnu`): exit 0.
- Three rounds of `arkdeck-platform --test loopback_server_lease`, `arkdeck-provider-hdc --test
  lifecycle --test managed_server`, `arkdeck-agentd --test managed_hdc_process --test
  control_action_host_process` and the `managed_hdc` unit test: all passed, except one run of
  `loopback_server_lease::no_process_on_the_endpoint_is_unavailable_not_unknown` in the first
  round, which did not reproduce in 40 further runs of that binary (10 through cargo, 30 of the
  binary directly). That test scans the processes running its own executable while its
  neighbours start and end listener children of that executable; the one failure is recorded
  here, not explained.

## CI

Pending (this PR).
