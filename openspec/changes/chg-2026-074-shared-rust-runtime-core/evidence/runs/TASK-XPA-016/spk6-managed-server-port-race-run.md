# TASK-XPA-016 — SPK-6 run record: the managed-server tests' port race

Change: CHG-2026-074-shared-rust-runtime-core@r11. Lane B, a test-only fix in
`arkdeck-provider-hdc`'s `tests/managed_server.rs` and `tests/lifecycle.rs`. Host measurement
only (POL-VERIFY-001, POL-MODE-001). Base: protected main `8f79fbfe` (#1951). No stack.

## What was wrong

Lane A's #1957 (which changes no Rust) went red on `rust-checks / Rust workspace (macos-26)` in
`a_listener_of_another_process_never_binds_the_launch`:

```
tests/managed_server.rs:236: called `Result::unwrap()` on an `Err` value:
Os { code: 48, kind: AddrInUse, message: "Address already in use" }
```

Line 236 bound a `TcpListener` to the endpoint `free_endpoint()` had just returned — a port
found by binding `127.0.0.1:0` and releasing the listener. The tests of one binary run on
parallel threads, and the kernel may hand a port it just released straight back to the next
`bind(0)`, so two tests could be handed the same port and the second bind, or a fake server's
bind, found it taken. The local gate never showed it; CI did once.

## What changed

- The foreign-listener test binds `127.0.0.1:0` itself and keeps that listener for the whole
  test, passing its `local_addr()` as the endpoint: there is no window between finding the
  port and holding it.
- `free_endpoint()` in both binaries records every port it issues in a process-wide set and
  binds again when `bind(0)` returns one it already issued, releasing the probing listener only
  after the port is recorded — no two tests of one binary are handed the same port. The window
  between the release and the fake server's own bind remains (the server must bind the
  endpoint it is named), but no test of the binary can be the one that takes it.

## Measurement

```
cargo test -p arkdeck-provider-hdc --test managed_server --test lifecycle   3 runs: 7 + 5 passed each
cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings           clean
cargo fmt --all --check                                                     clean
```

The race is timing-dependent and was not reproduced locally before the fix; the fix removes
the two ways one binary's tests could collide rather than proving the flake by replay.
