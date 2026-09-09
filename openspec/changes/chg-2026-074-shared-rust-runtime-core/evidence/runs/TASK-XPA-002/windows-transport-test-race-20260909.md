# The untrusted-server refusal tests race the listener — 2026-09-09

- Task: TASK-XPA-002
- Base: protected `main` `8a28f182`.

Seen on PR #1815's `Rust CI` run on `windows-latest`
(`rust-checks / Rust workspace (windows-latest)`, run 34329480095): in the
*published* contract view, two of `arkdeck-platform`'s native tests failed —
`same_account_wrong_image_is_refused_before_any_frame` and
`same_image_without_product_signing_identity_is_refused_before_any_frame` —
with

    called `Result::unwrap()` on an `Err` value: Custom { kind: PermissionDenied,
      error: "pipe client disconnected before authentication" }

while the same tests passed in the candidate view of the same job and on the
ubuntu and macOS runners. #1815 changes no Rust source; the failure is a race
inside the test helper `refused_before_first_byte`.

## What races

The helper spawns a listener, lets the client connect, and asserts that the
untrusted server never receives a frame. The client
(`LocalConnection::connect`) opens the pipe, refuses the server on identity
and closes the handle without writing. On the server side the listener's
`accept` can observe that in two ways depending only on scheduling:

- `ConnectNamedPipe` completes and the connection reads end-of-pipe
  (`Ok(0)`, or `ERROR_BROKEN_PIPE` / `ERROR_NO_DATA` on the read) — the branch
  the test already accepted;
- `ConnectNamedPipe` itself completes with `ERROR_NO_DATA` /
  `ERROR_BROKEN_PIPE` / `ERROR_PIPE_NOT_CONNECTED` because the client is
  already gone, which `LocalListener::accept` deliberately reports as
  `PermissionDenied("pipe client disconnected before authentication")` while
  replacing the spent instance — the branch the test `unwrap`ped and so
  panicked on.

Both outcomes are the refusal the test asserts: no byte reached the untrusted
server and no client lingered. Only received data or a client that stays
connected is a failure.

## The change

`refused_before_first_byte` matches `accept()`'s
`PermissionDenied` "disconnected before authentication" as a pass, panics on
any other `accept` error naming it, and keeps the read-side assertions
unchanged. The product code (`LocalListener::accept`) is untouched; the
fixture test hierarchy, expected messages and the three tests that share the
helper are unchanged.

## Verification

Windows tests cannot run on this host. Checked here:
`cargo fmt --check` and
`cargo clippy --locked --target x86_64-pc-windows-msvc -p arkdeck-platform --tests -- -D warnings`
(cross-target clippy compiles the `#![cfg(windows)]` test crate); the hosted
`windows-latest` job of the pull request is the execution.
