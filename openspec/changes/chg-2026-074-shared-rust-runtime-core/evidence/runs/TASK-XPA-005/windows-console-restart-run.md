# TASK-XPA-005 — the confirmed HDC restart approved at a real Windows console

Change: CHG-2026-074-shared-rust-runtime-core, over CHG-2026-078 (the registered DevEco Studio
26.0.0.43 `hdc.exe`, `3.2.0g`, c2). The last piece of GJ-1's restart hop on Windows: the human's
answer at the console, through the real CLI.

Branch `agent/xpa-005-windows-console-cli-20261004`, stacked on #2501 (the confirmed restart).
It also uses #2480 (the Windows foreground-console origin, maintainer ruling 2026-10-04) and
#2488 (`human-action.resume` admits an unsigned preview tool), both on `main`.

Host: the Windows 11 x64 reference host, console session 1, non-elevated. The live run used only
the server the daemon itself started on `127.0.0.1:8710` and stopped; no other server was adopted
or stopped, and no device was changed. Live development-root runs are not Windows acceptance and
not `REAL_DEVICE_PASS`.

## What

| Where | What |
| --- | --- |
| `arkdeck-platform/tests/windows_console_restart.rs` (`harness = false`) | The real daemon (a copy signed with the host-trusted development signer) over an isolated development root composing the registered `hdc.exe` as its managed server, and the real `arkdeck.exe` verifying it. The impact preview and the restart's approval request run through the CLI. Then `human-action resume` (1) with a redirected stdin, (2) in a pseudo console (`CreatePseudoConsole`) answered with a wrong challenge, (3) in a pseudo console answered with the challenge it rendered, typed as a human types it. Live-gated (`ARKDECK_LIVE_WINDOWS_HDC`, `ARKDECK_DEV_SIGNER_THUMBPRINT`); without them it says so and checks nothing. It lives in `arkdeck-platform`, the one crate that may host a pseudo console (the workspace forbids `unsafe` elsewhere), and runs the workspace's own daemon and CLI builds beside it. |
| Test cleanup (no product code) | What the Windows gates left in their 8.3 temporary directory, found by running the five crates' tests in a fresh one and listing it (22 entries; 25 in the earlier gate run): `arkdeck-provider-hdc` `windows_lifecycle.rs` (8 `arkdeck-lifecycle-hdc-*` fakes: the directory was removed while the fake's own `VerifiedTool` still held the image open, since a `Drop` body runs before the fields drop; it now goes with a last field, as in `windows_managed_hdc.rs`), `windows_managed_hdc.rs` (9 `arkdeck-xpa005-hdc-*`: one removal attempt raced the ended server letting go of its image; now retried for up to 10 s), `arkdeck-hoststore` `fixture_fs::rewrite_sealed` (`sealed-*` payloads moved aside on Windows and never removed; now removed), `flash_run.rs` (the fixed `arkdeck-flash-run-oracle` root; now removed when a test lets go of its lock), and `arkdeck-agentd` `spawning/signed_daemon.rs` (`daemon-stderr-<pid>.log` beside a root in the temporary directory; now removed on drop unless the test failed). After main brought in #2504, `arkdeck-agentd` `spawning` also left `flash-plan-control-*` roots (its subprocess fixtures' roots, which a child cannot always remove while its background Job threads still hold the stores open; the parent test now names the root and removes it after the child exits) and the fixed `arkdeck-hdc-oracle` root of `support::debug_hap` (now removed on Windows when a test lets go of its lock, as `flash_run`'s). A rerun leaves only the three fixed cross-process lock files (`arkdeck-flash-run-oracle.lock`, `arkdeck-hdc-oracle.lock`, `arkdeck-workspace-sign-oracle.lock`), which stay by design: removing a lock file another test process may hold would break the lock. No test process was left running. |

## Proof (live, 2026-10-04, real c2 `hdc.exe`)

- Preview through the CLI: healthy, `arkDeckManaged`, no blocker; `runtime hdc restart` returned
  the waiting `impactApproval`.
- (1) Redirected stdin: the daemon derived the console origin (same user, active console session)
  and issued the challenge, and the CLI refused to read an answer from a non-terminal
  (`recordUnreadable`, exit 2). Nothing was dispatched (`dispatchCount` 0).
- (2) Wrong answer typed at the pseudo console: the CLI rendered the impact and the challenge, the
  Runtime refused the answer (exit 77), and nothing was dispatched.
- (3) The rendered challenge typed at the pseudo console: exit 0; `control-action show` reads
  `succeeded` with `dispatchCount` 1; `runtime hdc status` names a strictly newer server generation,
  `arkDeckManaged`. The daemon's stop ended the proved replacement ("ended the replacement HDC
  server a confirmed restart proved"); nothing listened on 8710 afterwards.

## Notes

- A pseudo console's child must be given null standard handles (`STARTF_USESTDHANDLES`), as the
  product's own pseudo-console spawn does; otherwise it may take the host process's redirected
  ones and its stdin is no terminal.
- The no-console refusal keeps the CLI's existing code and message (`recordUnreadable`, "Runtime
  impact challenge lacks its immutable control-action preview"), which `arkdeck-cli`'s
  `console_approval.rs` tests pin; the message names the preview although the cause is the
  redirected stdin. Left as is.

## Gates

The PR description gives this commit's gate output.
