# TASK-XPA-005 — a confirmed HDC restart of the registered Windows HDC

Change: CHG-2026-074-shared-rust-runtime-core, over CHG-2026-078 (the registered DevEco Studio
26.0.0.43 `hdc.exe`, `3.2.0g`, c2). GJ-1's restart hop on Windows.

Branch `agent/xpa-005-windows-hdc-restart-20261004`, on `main` after #2486 (the Windows HDC
adoption: TEMP/TMP for the managed server, the plain image spelling in the commandless observer,
the registered Windows listing grammar). The confirmed restart end to end also needs two independent
PRs: #2480 (the Windows foreground-console origin, maintainer ruling 2026-10-04) and #2488
(`human-action.resume` admits an unsigned preview tool). CHG-2026-078 r3 (#2484) settles the
managed start past the `[Empty]` listing of a fresh server, so the live tests need no wait.

Host: the Windows 11 x64 reference host, console session 1, non-elevated. The live runs used only
the server the daemon itself started on `127.0.0.1:8710` and stopped it; no other server was
adopted or stopped, and no board was needed (a restart only addresses the server). Host tests and
these live development-root runs are not Windows acceptance and not `REAL_DEVICE_PASS`.

## Why

The impact preview of a restart (`runtime.hdc.impact-preview`) must prove the server healthy and
this daemon's before a restart can be approved. Its health observer (`ManagedServerImpact`) knew
one way: the registered macOS 3.2.0d family's `checkserver` bracketed by two identity
observations. On Windows `checkserver` is never run, because with no server it starts one
(CHG-2026-078 ruling item 3); the Windows server-health family is `serverIdentityGeneration`, the
commandless identity itself. So every Windows preview was `hdc.serverIdentityUnproven` (the
receipt's verbatim `\\?\` image spelling also failed the ownership check) and no restart could be
requested.

## What

| Where | What |
| --- | --- |
| `arkdeck-hoststore` `hdc_impact_source.rs` | On Windows, for a registered Windows tuple's executable on the tuple's endpoint, health is two equal commandless identity observations with a representable generation (nothing is run); the version is the tuple's. A server receipt's image is compared with the configured path in the plain spelling (`\\?\` removed), as #2486 does in the status observer. macOS is unchanged. |
| `arkdeck-platform` `windows/server.rs`; `arkdeck-provider-hdc` `managed_server.rs`; `arkdeck-agentd` `managed_hdc.rs` | A held port is its own typed refusal. On the reference host an unrelated process (a proxy) held local port 8710 for an outbound connection; nothing listened, so the start launched the server, which could not bind (`uv_tcp_bind -4092`, EACCES) and exited 0, read as a generic "exited with status 0". Now, before launching, `port_holders` reads the kernel's connection table (`GetExtendedTcpTable`, `TCP_TABLE_OWNER_PID_ALL`, IPv4 and IPv6) for any socket holding the port (a listener on any address or a connection's local port; TIME_WAIT and other ownerless rows excluded), and the start is refused as `StartFailure::PortInUse`, naming each holder (PID, image when readable, state, local and remote address). Nothing is launched, and no holder is adopted or stopped; a table that cannot be read refuses the start too. |
| `arkdeck-hoststore` `hdc_control_lifecycle.rs` | The durable lifecycle record's command executable must be an absolute path of the platform: `/…` on macOS (unchanged), a drive or UNC path on Windows. It only admitted `/…`, so the approval of the registered Windows `hdc.exe` (`C:\Program Files\…`) was refused as `recordUnreadable` before dispatch. The Windows test fixture's executable is now `C:\fixture\hdc.exe`. |
| `arkdeck-provider-hdc` `lifecycle.rs` | The Windows lifecycle client (`kill -r`) is named this daemon's TEMP/TMP, as the managed server is: 3.2.0g's client finds the server it ends through the server's files in the temporary directory, and the replacement it starts inherits the client's environment. Without them `kill -r` ended nothing, its replacement could not bind, and the restart was `outcomeUnknown` (dispatch 1, generation unchanged). |
| `arkdeck-agentd` `windows_hdc_restart_tests.rs` | The confirmed restart end to end through Control over the real Windows composition (`windows_lifecycle::start`, `Authority::compose`) with the real registered `hdc.exe` (`ARKDECK_LIVE_WINDOWS_HDC`; skipped without it). |
| `arkdeck-agentd/tests/windows_hdc_restart_live_process.rs` | The real daemon over its pipe: preview healthy and `arkDeckManaged`, version 3.2.0g, no blocker; the restart requests the impact approval and restarts nothing (generation and PID unchanged). Live-gated likewise. |

## Proof

- `hdc_impact_source::tests::a_registered_windows_tuple_proves_health_by_its_identity_generation`
  (Windows): healthy with the tuple's version and nothing dispatched; another identity across the
  bracket, an unavailable second observation or none refuse health; a verbatim-spelled receipt is
  owned as the plain one. The macOS 3.2.0d `checkserver` test is unchanged.
- `windows_managed_hdc.rs` `a_held_port_launches_nothing_and_names_its_holder`: a listener on
  127.0.0.2 holding the endpoint's port refuses the start as `PortInUse` naming that process, with
  nothing launched; once the holder lets go, the start owns the port.
- `hdc_control_action_tests::a_lifecycle_command_names_an_absolute_executable_of_its_platform`:
  the DevEco `C:\Program Files\…\hdc.exe` path is admitted on Windows; relative spellings are not.
- **The confirmed restart, live, end to end** (2026-10-04 12:58Z, real c2 `hdc.exe`, on this layer
  plus #2488, in process through Control over the Windows composition, the console origin supplied
  as on macOS): preview healthy and `arkDeckManaged` at generation 1791118709224786; the restart
  requested the impact approval; without the console it came back unchanged; with it the challenge
  was issued; its answer ran `-s 127.0.0.1:8710 kill -r` once (`dispatchCount` 1) and the control
  action ended `succeeded`; the replacement (PID 25016, generation 1791118714229049, strictly newer)
  was proved and reported `arkDeckManaged`; the daemon's stop ended it ("ended the replacement HDC
  server a confirmed restart proved") and nothing listened on 8710 afterwards. The DAYU200 happened
  to be attached (one affected device observation in the preview); the restart only addresses the
  server, and no device was changed. Before the two fixes above the same run failed at the approval
  (`recordUnreadable`) and then at the outcome (`outcomeUnknown`, nothing ended).
- Live, earlier (2026-10-04, real c2 `hdc.exe`, no board): preview `serverHealth: healthy`,
  `serverOwnership: arkDeckManaged`, `serverVersion: 3.2.0g`, `blockerReasonCode: null`; the restart
  answered the waiting `impactApproval`. Without #2488 the console challenge was replaced as
  nonconforming (an unsigned tool's `identifier: null`), the gap #2488 closes.

## Left out

- Driving the real CLI's console prompt through ConPTY end to end: the in-process test supplies the
  console origin as the macOS tests do; #2480 derives it on the pipe.

## Gates

The PR description gives this commit's gate output.
