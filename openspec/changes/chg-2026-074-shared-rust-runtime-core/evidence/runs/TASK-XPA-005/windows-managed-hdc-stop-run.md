# TASK-XPA-005 — WM1: managed HDC start/stop semantics on Windows (#2131 over #2341)

Change: CHG-2026-074-shared-rust-runtime-core. WM1, TASK-XPA-005. #2131 (TASK-XPA-014, macOS) did
two things:

- It ended the replacement server a confirmed `kill -r` proved when the daemon stops.
- It refused a held endpoint before launching.

#2341 ported the managed server, the commandless proof and the occupied-endpoint refusal to
Windows. This slice ports the stop half.

Branch `agent/xpa-005-windows-managed-hdc-stop-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run: the fake `hdc` is the
  test binary itself.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## What

`arkdeck-platform`:

- `end_proved_process(receipt, grace, kill_grace)` on Windows (`windows/server.rs`), the
  counterpart of `macos_server::end_proved_process`. It ends only the process an identity receipt
  names:
  - The PID is opened once, with query, synchronize and terminate access. The handle pins the PID
    for the whole call, so a PID reused since the receipt can never be ended.
  - On that handle, it reads the creation time (`GetProcessTimes`, the receipt's birth) and the
    token user (this process's user) before anything is terminated.
  - A PID with no process, an exited one, or one naming another birth means the receipt's process
    has ended: `AlreadyEnded`, and nothing is terminated.
  - A PID of 4 or less is refused (`InvalidInput`). Another user's process is refused
    (`PermissionDenied`).
  - Windows has no TERM, as `ManagedServer::stop` already has none. So `grace` is not waited: the
    process is terminated at once, and the call returns `Killed` once its process object is
    signalled (its exit finished, its listener gone), or `TimedOut` after `kill_grace`.
- `ProvedProcessEnd` moves to `server_identity.rs`, shared by both hosts. The macOS enum and its
  answers are unchanged; only its documentation names the Windows meaning.

Tests on Windows:

- `arkdeck-platform/tests/windows_tool_dispatch.rs`,
  `a_proved_server_outside_the_job_is_ended_and_no_other_birth_ever_is`:
  - A `listen` server of the verified tool is spawned outside any Job, as `kill -r` leaves the
    replacement. The commandless proof names it.
  - Another birth at its PID, and PIDs 0, 4 and -1, end nothing, and it keeps serving.
  - The proved receipt ends it: `Killed`, its exit finished, and no process of the tool owns the
    endpoint any more. Asking again answers `AlreadyEnded`.
- `arkdeck-provider-hdc/tests/windows_managed_hdc.rs`,
  `a_proved_replacement_is_ended_and_the_endpoint_serves_the_next_start` (#2131's
  restart → stop → start):
  - A fake `hdc -s <endpoint> -m` replacement runs outside the Runtime's Job.
  - `ManagedHdcServer::start` launches nothing, and names it: "a server of the configured HDC
    executable that this launch did not start listens there (pid …)". It is neither adopted nor
    stopped.
  - The proved replacement is ended (`Killed`), and the endpoint is unreachable.
  - The next start is ready on the endpoint, bound to its own launch.

## Not reached, and why

- **The daemon's managed-HDC owner.** `arkdeck-agentd/src/managed_hdc.rs` (with the
  foreground-approved restart lifecycle and its control actions) stays macOS-only. It starts only
  beside a registered HDC, and none is registered on Windows. A Windows development root refuses
  `ARKDECK_DEVELOPMENT_HDC_PATH` and `ARKDECK_DEVELOPMENT_HDC_SERVER` before starting anything
  (`windows_lifecycle::a_development_root_refuses_an_input_it_does_not_compose`). Composing it on
  Windows follows the HDC tuple's registration.
- **Crash paths.** A replacement left by a crashed Runtime keeps the next start refused
  (fail-closed, AC-HDC-003-02, as on macOS): the provider test's first start shows that refusal.

### Delegated minor decision, pending the next rulings batch

The Windows `end_proved_process` terminates at once and does not wait `grace` (Windows has no TERM
to wait on). It reports `Killed`, never `Terminated`.

## Local checks

Run on Windows 11 x64 with `ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-agentd` | 0 / 101 | this slice's tests pass. The only `SKIPPED` lines are #2396's wildcard-listener skips outside GitHub Actions; no signed test skipped. Unrelated to this slice, `windows_credential_store.rs`'s `concurrent_writers_keep_each_others_credentials` (#2354) failed twice in six runs with "Credential Manager did not keep the written credential"; its other runs pass. It is reported to the lead |
| the same with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and Ubuntu cannot be built here. The macOS change is the enum's move (the same items, the
same paths through the re-export), so CI decides.
