# TASK-XPA-002 — a single-instance pipe squatter is refused as a held name, 2026-09-30

Follow-up to observation 1 of `spk-3-20260930-run.md`. Host tests on the Windows 11 x64
reference host (Windows 11 Pro 10.0.26200, non-elevated). Not SPK-3, not Windows platform
acceptance, not device acceptance: no board, no `hdc`, nothing installed, elevated or
reconfigured; every pipe name is a random per-test `\\.\pipe\arkdeck-spk3-test-<hex>`.

Base: `main` at `efab7f29` (#2337).

## Defect

A same-account squatter that creates the daemon's pipe name first with `nMaxInstances = 1`
makes the product's `CreateNamedPipeW(FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_UNLIMITED_INSTANCES)`
fail with `ERROR_PIPE_BUSY` (231). `create_instance` mapped only `ERROR_ACCESS_DENIED` (5, a
holder that allows more instances) to the "named pipe … is held by another instance" refusal,
so against a one-instance squatter the daemon failed closed but with the raw OS error.

## Change

- `arkdeck-platform/src/windows/mod.rs`: `create_instance` maps 5, and 231 on the first
  instance, to the same `PermissionDenied` refusal `named pipe <name> is held by another
  instance (Win32 error <code>); daemon did not start`. Nothing waits for or retries against the
  holder. 231 on a later instance (never expected: the daemon's own instances are unlimited) is
  left as it was.
- The daemon's start reports the held name through that error unchanged: both the account and
  the development root answer `the endpoint <pipe> is not this Runtime's: named pipe <pipe> is
  held by another instance (Win32 error <code>); daemon did not start; nothing was started`
  (`arkdeck-agentd/src/windows_lifecycle.rs`, not modified), and the private-endpoint path
  prints the same platform message. No `doctor` path exists for a daemon that did not start:
  the client-started daemon of decision 11 is a later slice, so the tasks.md row's "`doctor`
  reports the held name" part stays open.
- README Windows listener paragraph states both codes.

## Tests

- New `single_instance_squatter_is_refused_as_a_held_name` (`tests/windows_transport.rs`):
  a pipe created in-process with `FILE_FLAG_FIRST_PIPE_INSTANCE` and one instance holds the
  name; `LocalListener::bind` returns `PermissionDenied`, no raw OS error, and the message
  names the pipe and error 231. The squatter is created synchronously before bind; no sleeps.
- `second_daemon_cannot_take_an_existing_pipe_name` (multi-instance holder, error 5) still
  passes, now also asserting the held-by-another-instance wording.

## Local checks

| Command (from `rust/`, dedicated `CARGO_TARGET_DIR` on D:, `CARGO_BUILD_JOBS=3`) | Result |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy -p arkdeck-platform -p arkdeck-agentd --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-platform` | 0 (49 passed; `windows_transport` 14 passed) |
| `git diff --check` | 0 |

CI: to be recorded; not verified here.
