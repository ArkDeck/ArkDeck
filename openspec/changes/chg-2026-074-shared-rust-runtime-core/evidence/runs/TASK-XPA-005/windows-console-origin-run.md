# TASK-XPA-005 — the Windows foreground-console origin of a pipe client

Change: CHG-2026-074-shared-rust-runtime-core. This record covers the Windows counterpart of the
macOS daemon's foreground-console origin, which gates the interactive impact-approval challenge a
confirmed HDC restart needs (`human-action.resume`). It is ruling-backed: **maintainer ruling
2026-10-04** ("按建议" on the proposal the lead relayed the same day).

Branch `agent/xpa-005-windows-console-origin-20261004`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS, a console logon (session 1). No device
was contacted, no HDC was run, nothing installed was read or written, and no system setting was
changed. Host tests are not Windows acceptance.

## Why

The control layer issues the impact-approval challenge, and accepts its answer, only for a frame
that arrived from the foreground interactive console (`Origin::Local { foreground_console }`). The
macOS daemon derives that per frame from the kernel (peer uid, the peer's controlling terminal and
its foreground process group, `macos_control.c`). The Windows pipe derived nothing
(`foreground_console = false` off macOS), so on Windows an impact approval was always returned
unchanged and a confirmed HDC restart could never be consumed (gate inventory G16).

## The ruling (maintainer, 2026-10-04)

All three must hold; anything uncertain fails closed:

- (a) the pipe client (`GetNamedPipeClientProcessId`, opened and proved like the existing peer
  checks, no PID reuse) runs as the daemon's own user;
- (b) its session is the active console session (`ProcessIdToSessionId` ==
  `WTSGetActiveConsoleSessionId`), so Remote Desktop and other sessions and services fail;
- (c) the human answers the console challenge at the client's console; that answer is the presence
  proof.

## What

| Where | What |
| --- | --- |
| `arkdeck-platform` `windows/console_origin.rs` | `ConsoleFacts::foreground_console`: the daemon's own user (`require_client_user`), the session of the client's token and `ProcessIdToSessionId` of its PID both equal to `WTSGetActiveConsoleSessionId` (never the no-console value `0xFFFFFFFF`). Every fact is read of the client process the connection pinned when it authenticated the pipe instance (`ProcessIdentity`: its process object held open and its creation time re-read before and after), so a reused PID never stands for it. Anything unread is no console. |
| `arkdeck-platform` `windows/identity.rs`, `windows/mod.rs`, `Cargo.toml` | `Token::session` (`TokenSessionId`); `LocalConnection::foreground_console`; the `Win32_System_RemoteDesktop` feature of `windows-sys` (no new crate, `Cargo.lock` unchanged). |
| `arkdeck-agentd` `lib.rs` | `serve_control` reads it per frame on Windows, as it reads the kernel origin on macOS. macOS is unchanged; other platforms keep `false`. |

Part (c) is the CLI as it already is on every platform: `human-action.resume` reads the challenge
answer only from a terminal stdin, bounded and exact (`console_approval.rs`), and nothing else can
supply it.

## Proof

- `console_origin::tests::only_the_daemon_s_user_in_the_active_console_session_is_the_console`: the
  console only for the daemon's user in the active console session by both readings; refused for
  another session (Remote Desktop), session 0 (services), another user, no console session or the
  no-console value, an unread token or process session, and readings that disagree.
- `arkdeck-platform/tests/windows_transport.rs`,
  `a_connection_s_console_origin_is_its_client_s_session_and_user`: a real accepted pipe
  connection whose client is the test process answers what the host says of that process (here
  session 1 = the active console session: the console).
- Unchanged, and covering the rest of the ruling on Windows too: `arkdeck-cli/tests/console_approval.rs`
  (no console: a redirected stdin is refused before anything is read; the answer is bounded and
  exact, so an unanswered challenge sends nothing) and `arkdeck-hoststore`
  `hdc_control_action_tests::challenges_refuse_wrong_expired_replaced_and_drifted_approvals` (a wrong,
  expired, replaced or drifted answer runs nothing).

The confirmed restart that consumes it end to end with the registered HDC is the next part
(it waits for #2472 and CHG-2026-078 r3).

## Gates

The PR description gives this commit's gate output.
