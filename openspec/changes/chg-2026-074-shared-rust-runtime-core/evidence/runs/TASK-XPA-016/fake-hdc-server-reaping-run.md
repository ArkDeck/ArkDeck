# TASK-XPA-016 — the fake HDC servers a restart starts are ended by their test

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane B, test-only. Host measurement only.
Base: protected main `6afce089` (#2125).

## Why

On 2026-09-23 the development host carried 65 orphaned processes (PPID 1), every one
`/private/tmp/arkdeck-managed-hdc-unit-<32 hex>/hdc -s 127.0.0.1:<port> -m`, each listening on a
port of the range `loopback_ports` hands the host tests. Every `cargo test -p arkdeck-agentd`
since 2026-09-22 had left three or four of them.

They are the replacement servers of the fake `hdc` in the `managed_hdc` unit tests. The fake's
`kill -r` (`rust/tests/fixtures/managed-hdc/fake-hdc.c`, the `RESTART_DIR` block) forks, calls
`setsid()` and executes a new `-m` server, as HDC's restart does, so that server is nobody's
child; it ends only when the `stop` marker appears in the fake's directory, which it polls every
20 ms. `host_never_claims_zero_dispatch_after_lifecycle_audit_failure` wrote that marker right
after the restart (`rust/crates/arkdeck-agentd/src/managed_hdc.rs:649` at the base) and its
`Fake` guard removed the directory at the end of each of its four turns (lines 369-373).
Measured on the base with an instrumented copy: 15.5–17.4 ms from the marker to the removal,
shorter than the poll, with three of four replacements still running at the removal; once the
directory is gone the marker can never be seen. Run alone at the base, that test left exactly
four orphans (session leaders in their poll loop, `access` failing with ENOENT). The
confirmed-restart test's `Cleanup` wrote the marker and waited up to 3 s while a lease on the
endpoint could still be acquired, so it leaked only when that wait ended early or ran out.
`tests/lifecycle.rs` in `arkdeck-provider-hdc` ended its replacement by `end_server` after the
last assertion only, and `FakeHdc::server()` dropped its child without a kill whenever the lease
proof panicked.

The product leaves the replacement running on purpose. `ManagedHdc::stop` stops only the
original child, as Swift's `HeadlessHDCServerHost.stop` stops only its own task: the server a
confirmed restart starts is not the daemon's child in either implementation. Ending a test's
replacements is the test's job, and no product lifecycle changes here.

`FakeHdc::server()` also judged readiness by the port accepting a connection. The single
`NotFound` failure at `tests/lifecycle.rs:177` of 2026-09-23 has that shape: holding the endpoint
with a foreign listener before `server()` reproduces it exactly at the base (`177:72`,
"no existing selected HDC process owns the exact endpoint") — the fake's own bind failed (exit
67), the foreign listener answered the reachability probe, and the lease found no fake.

## What changed

Tests and fixtures only.

- `rust/tests/fixtures/managed-hdc/fake-hdc.c`: `kill -r` appends the replacement's PID to
  `servers` in the fake's directory before it returns (a failed record kills the child and
  exits 71). A `RESTART_DIR` server also ends once `OWNER_PID`, the test process, is gone, so a
  test killed before its guard runs leaves nothing listening.
- `rust/tests/support/fake_hdc_servers.rs` (included like `loopback_ports.rs`): `tear_down`
  SIGKILLs every recorded PID whose kernel launch record (`process_argument_record`) still names
  the fake's own path in that directory, waits until none does, then removes the directory; a
  failure fails the test, or is printed when the test is already failing. A PID the kernel has
  handed to another process is never signalled.
- `arkdeck-agentd` `managed_hdc` tests: the `Fake` guard calls `tear_down` and is built as soon
  as the directory exists; restart fakes get `OWNER_PID`. The early marker write in the audit
  failure test and the confirmed-restart test's `Cleanup` are removed; the guard ends every turn's
  replacements, on a panic too. No assertion changed.
- `arkdeck-provider-hdc` `tests/lifecycle.rs`: the fake's server writes `listening-<pid>` with its
  PID and port once it listens; `server()` holds its child in `Server` at once, waits for that
  file (a child that ends first fails with its exit status), and requires the lease's PID to be
  that child's. The fake records replacements and checks its owner as above, `FakeHdc`'s drop
  calls `tear_down`, and `end_server` is gone; the restart test also asserts that the fake
  recorded the replacement the lease proved.

## Local targeted checks

In worktree 1330's own target (`/private/tmp/arkdeck-1330-rust-target`), `CARGO_BUILD_JOBS=2`.
Orphans counted as PPID-1 processes whose command is a fake under a test directory; the installed
HDC server is not one. Count before the first run: 0 (the stale directory
`arkdeck-managed-hdc-unit-c084767e…` of 2026-09-22, used by no process, was removed).

- Three runs each of the `managed_hdc::` unit tests (4 passed) and of `--test lifecycle`
  (7 passed): exit 0 every time, 0 orphans, 0 fake processes and 0 fake directories after each.
- Mutation, reaping and owner check both removed: 4 orphans after the unit tests, 1 after
  `lifecycle` (ended by hand). Reaping kept, owner check disabled: 0 and 0 — the guard alone ends
  them.
- Owner check: the test process SIGKILLed while a replacement ran (agentd confirmed-restart test
  once, `lifecycle`'s restart test twice): the replacement ended 44–46 ms later. The directories
  those killed runs left were removed by hand.
- Foreign listener on the endpoint before `server()`: `server()` now fails with
  "the fake server ended before it listened on 127.0.0.1:43429: exit status: 67".
- `cargo fmt --all --check`: exit 0. `cargo clippy -p arkdeck-agentd -p arkdeck-provider-hdc
  --all-targets -- -D warnings`: exit 0.
- `cargo test -p arkdeck-agentd` (after `cargo build -p arkdeck-cli`): exit 0, 80 passed in 8
  binaries. `cargo test -p arkdeck-provider-hdc`: exit 0, 160 passed in 16 binaries. 0 orphans
  after each.
- `sh scripts/check-sdd.sh` (this record is under `openspec/`): exit 0.

## CI

Pending: the PR's `guard` + `swift` aggregate is the gate.
