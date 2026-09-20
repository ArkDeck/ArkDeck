# TASK-XPA-016 — the lease tests take their turn, and their listeners say when they listen

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane B, test-only. Host measurement only.
Base: protected main `88248f67`.

## Why

`arkdeck-platform tests/loopback_server_lease.rs` went red again on a macOS 26 runner (#2076,
run 35496643577, job 106040738445):

```
thread 'an_existing_loopback_listener_of_the_verified_executable_is_proved_without_a_connect'
panicked at crates/arkdeck-platform/tests/loopback_server_lease.rs:114:78:
called `Result::unwrap()` on an `Err` value:
Custom { kind: NotFound, error: "no existing selected HDC process owns the exact endpoint" }
```

`NotFound` for the whole five-second budget: the test's own listener was never a candidate. The
test spawned the child and went straight to judging the endpoint, so a child that never bound —
whatever the reason — was indistinguishable from an endpoint no process owns, and the test spent
its budget scanning for a process that had already exited.

The neighbouring hazard is the same file's other half. Every listener these tests spawn is one
executable, this binary, so each test's children are candidates in every other test's scan, and
the vanished-candidate rule only covers a child the kernel reports as gone: a child read while
it is exiting can answer `Unscannable`, which fails the scan closed (`PermissionDenied`,
"macOS socket scan failed for the selected HDC process"). #2051 recorded one unexplained
`no_process_on_the_endpoint_is_unavailable_not_unknown` failure of exactly that shape.

## What changed

`rust/crates/arkdeck-platform/tests/loopback_server_lease.rs` only; the lease itself is untouched.

- **Each listener reports itself listening.** The child is given a file path in its environment
  and writes it once its `TcpListener` is bound; `Executable::listener` returns only after that
  file appears. If the child exits first, the test says so and prints the child's reason (the
  harness writes a panicking test's reason on stdout, which is piped and read once the child is
  known to have exited) instead of leaving a bound-looking listener that was never there.
- **The child parses its address instead of resolving it.** `TcpListener::bind(("127.0.0.1", p))`
  goes through `getaddrinfo`; the child now binds a `SocketAddrV4` it parsed, so binding needs no
  name service to answer.
- **The scanning tests take their turn.** A file-wide mutex, taken as each such test's first
  statement and released after its listeners are killed and reaped, makes the population of the
  verified executable's processes wholly its own. `the_endpoint_must_be_the_exact_ipv4_loopback`
  never scans (the endpoint is refused before any scan) and takes no turn.

The deliberate churn test keeps its coverage: it makes its own churn, three listeners at a time
coming and going while the endpoint is judged — and now they are proved listening before they are
killed, which the test could not tell before.

`a_listener_owned_by_another_executable_is_not_the_server` still waits for `nc` by probing the
port with a bind of its own. That probe can in principle take the port from `nc` for an instant;
the test's expectation (`NotFound`) holds either way, so it cannot go red from it, and it is left
as it is.

## Local targeted checks

In this worktree's own `target`, `CARGO_BUILD_JOBS=2`:

- `cargo fmt --all -- --check`: exit 0.
- `cargo clippy -p arkdeck-platform --all-targets -- -D warnings`: exit 0.
- `cargo test -p arkdeck-platform --test loopback_server_lease`: 7 passed, 3.36 s.
- The test binary run 20 more times directly: 20/20 passed, no failures.
- The dead-child path checked by hand: the child run with `ARKDECK_LEASE_LISTENER_PORT=1` prints
  `called `Result::unwrap()` on an `Err` value: Os { code: 13, kind: PermissionDenied }` on its
  stdout, which is what the parent's panic would carry.
- `cargo test -p arkdeck-platform` (the whole crate, 18 binaries): exit 0, 159 passed, 4 ignored.
- `sh scripts/check-sdd.sh` (this record is under `openspec/`): 0 errors, 0 warnings.

## CI

Pending: the PR's `guard` + `swift` aggregate is the gate.
