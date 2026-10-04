# TASK-XPA-010 — Flash device access and the lane plan preview through the CLI on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice G2, GJ-4 leftovers, part 2.
Stacked on #2523 (the debug reads, branch `agent/xpa-008-windows-debug-reads-20261004`), on #2519
(`windows-flash-recovery-run.md`). Host: the Windows 11 x64 reference host,
non-elevated. No device was contacted, no `hdc` and no `arkforged` ran, and nothing was flashed.
Host tests are not Windows acceptance.

## What

| Where | What |
| --- | --- |
| `src/device_access_control.rs` | Builds on Windows: Swift's committed `flash.device-access` control frames (a refused parameter, the refusal without a daemon, two flashing modes) are answered frame for frame by the Windows Host and Control, against a stand-in serving ArkForge's public named pipe for the lane directory (`arkforge_platform::LocalListener` on `LocalEndpoint::for_runtime(.., Public)`, ArkForge's own codec), and a parameter Swift refuses never reaches the pipe. |
| `tests/spawning/flash_socket_control.rs` | A case on both hosts through the real CLI against the signed test daemon: `flash device-access` reads `Loader` and `Maskrom` from the stand-in's three modes in one public session (`discoverDevices`), and `flash lane-preview --target --device-profile dayu200 --archive-sha256` projects a stand-in previewer's available plan over the bound target's facts; nothing is planned, admitted or dispatched. Both stand-ins live in the test binary; the daemon binary has no seam for them. |
| `arkdeck-agentd` dev-dependencies | `arkforge-ipc` and `arkforge-platform` (workspace crates already) on macOS and Windows, for the stand-in's codec and transport. |

## Coverage

`flash.device-access` and `flash.lane-preview` join `WINDOWS_MEASURED_LEAVES`;
`cli-feature-coverage.json` regenerated with `arkdeck maintainer contracts export`: against #2523,
Windows implemented 104 -> 106 (`flash.device-access`, `flash.lanePlanPreview`), partial 53 -> 51.
`oracle.json` is left as it is (the lead's decision of 2026-10-04).

## Local checks

See the commit message.
