# TASK-XPA-010 — `flash install-binding` on Windows and `flash bind-loader` through the CLI

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice G2, GJ-4 leftovers, part 3
(phase A runbook gaps G4 and G6). Stacked on #2531 (`windows-flash-device-access-run.md`). Host:
the Windows 11 x64 reference host, non-elevated. No device was contacted, no `hdc` and no
`arkforged` ran, nothing was flashed, and the account's own Application Support root was never
read or written. Host tests are not Windows acceptance.

## What

| Where | What |
| --- | --- |
| `arkdeck-cli` `flash install-binding [--rebind]` (G4) | Served on Windows as on macOS (Swift `runInstallBinding`): the DAYU200 cross-mode binding installed in the CLI's own process, never through the Runtime, from one census of the Windows USB registry (`arkdeck_platform::usb_host_devices`, the census the daemon's Flash facts read) into the Rockchip binding store of `%LOCALAPPDATA%\ArkDeck` (`arkdeck_application_support_root`, the Application Support root the Windows daemon composes). The receipt and the refusals are rendered as on macOS. It leaves the macOS-only host leaves. |
| `arkdeck-rockchip-binding/tests/install_binding.rs` | The Swift install oracle (`rockchip-binding-install`, `RockchipBindingInstallOracleContractTests`) replays all 35 steps on Windows: every answer and every byte as Swift's, each entry's kind, size and link destination. Owner-only modes are the private DACL, a shared mode a Users read entry, a symbolic link a file or directory link to the same relative destination; modes are not compared. |
| `arkdeck-cli` `install_binding_tests` | Build on Windows over a private temporary root. |
| `tests/spawning/flash_socket_control.rs` (G6) | `flash bind-loader` through the real CLI against the signed test daemon, over the Swift Loader binding oracle as it stood before exchange 15 (its Target store and installed binding, the census of exchange 11, ArkForge's half of the Loader observation confirming): it answers exchange 15's first cross-mode bind and exchange 16's retry exactly as Swift did. The whole oracle (33 exchanges) already replays through the Windows Host (`loader_binding_control.rs`). |

## Coverage

`flash.bind-loader` joins `WINDOWS_MEASURED_LEAVES`; `cli-feature-coverage.json` regenerated with
`arkdeck maintainer contracts export`: `flash.bind-current-loader` is implemented on Windows (against
#2531, Windows implemented +1). `flash.install-binding` is a legacy, macOS-required entry with no
Windows status, so the coverage does not change for it; the CLI now serves it on Windows.
`oracle.json` is left as it is (the lead's decision of 2026-10-04).

## Delegated minor decisions (pending the next rulings batch)

1. The binding a Windows install writes carries Swift's evidence literals unchanged
   (`product:e0-iokit-single-dayu200-readback`, …): the Runtime's binding readers require them, and
   on Windows they name the Windows USB census reading that stands for the I/O Registry readback.

## Not run

The installed CLI's `flash install-binding` against the real account was not run: it would read the
host's USB census and write the account's binding (no board use was authorized).

## Local checks

See the commit message.
