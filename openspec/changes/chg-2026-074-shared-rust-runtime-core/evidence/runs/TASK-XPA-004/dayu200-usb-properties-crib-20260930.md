# TASK-XPA-004 — DAYU200 USB properties on Windows, sampling crib (maintainer-run), 2026-09-30

WM0.5 platform fact of the Windows phase
(`docs/design/cross-platform/windows-phase-agent-prompt.md` §2.2 and WM0.5 "真机采样
crib", item 2). The agent drafted this crib and the capture script
`rust/scripts/windows-usb-sample.ps1`; **the maintainer runs it**. The agent does
not touch the board and only processes the files handed back.

TASK-XPA-004 needs a Windows stable-identity census: the counterpart of the macOS
I/O Registry census `arkdeck_platform::usb_registry` (`UsbHostDevice`), which the
HDC provider uses to prove a USB relation for a target observation. This sample
shows which Windows device properties can carry each census field, so that the
Windows census is designed from observed data. It is not device evidence,
not acceptance and implements nothing.

## What the script does

`windows-usb-sample.ps1` only reads the PnP tree (`Get-PnpDevice`,
`Get-PnpDeviceProperty`: the SetupAPI / CfgMgr32 device properties). It opens no
device, sends no USB request, starts no HDC, needs no elevation, and installs,
enables, disables or changes no driver or device. Each phase writes one
`usb-<phase>.json` with:

- `rockchipNodes`: every node, present **or not**, whose instance ID carries
  `VID_2207` (Rockchip, the DAYU200's vendor), with all properties and their
  `DEVPROP_TYPE`s — this also shows the nodes Windows remembers after removal;
- `presentUsbNodes`: every present node whose instance ID starts with `USB\`
  (devices, interfaces, hubs, root hubs), with the same detail, so the hub chain
  above the board can be followed.

## Preconditions (maintainer)

1. PowerShell 7, a normal (non-elevated) terminal, a checkout containing this
   commit. No admin rights, driver installs or policy changes; if the board shows
   a driver problem, sample it as it is and report it.
2. DAYU200 **unplugged**, normal (HDC) image on board. DevEco Studio may stay
   closed (as for the HDC crib); PnP properties do not depend on it.
3. A new output root outside every git work tree (the script refuses an existing
   root for `before`, a repeated phase, and any root inside a git work tree).

## Steps

1. Set the root:

   ```powershell
   cd D:\src\ArkDeck
   $root = Join-Path $env:LOCALAPPDATA 'ArkDeck-samples\usb-dayu200-20260930'
   ```

2. Board unplugged:

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-usb-sample.ps1 -OutputDirectory $root -Phase before
   ```

3. Plug the DAYU200 in; note **which physical port** you use; wait until it has
   booted (about 30–60 s), then:

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-usb-sample.ps1 -OutputDirectory $root -Phase after
   ```

4. Optional (recommended): unplug, wait about 10 s, then:

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-usb-sample.ps1 -OutputDirectory $root -Phase removed
   ```

5. Optional (recommended): plug into the **same** port, wait until booted, then:

   ```powershell
   pwsh -NoProfile -File .\rust\scripts\windows-usb-sample.ps1 -OutputDirectory $root -Phase replugged
   ```

   Unplug afterwards if you are done.

The phases can be interleaved with the HDC crib
(`evidence/runs/TASK-XPA-002/hdc-windows-sampling-crib-20260930.md`) to save
plug cycles: `before` after its step 2, `after` after its step 4 (board-connected),
`removed` after its step 5. `replugged` then needs one extra plug into the same
port.

6. **Hand back**: tell the agent the root and anything unusual (port used, a
   driver dialog, a yellow-bang device in Device Manager, a step skipped). Do not
   paste the JSON into a chat, issue or commit: it carries the board serial and
   the identities of every other USB device on the host.

## Mapping to the macOS census fields

macOS (`usb_registry.rs`) reads, per `IOUSBHostDevice` entry: numeric
`idVendor`, `idProduct`, `locationID`; string `USB Serial Number` (else
`kUSBSerialNumberString`); optional `USB Product Name`; the registry entry ID,
which names one attachment lifetime. An entry lacking the numbers or the serial
is no identity. The Windows candidates, to be confirmed or refuted by the sample:

| macOS field | Windows property (candidate) | Why, and what the sample must show |
| --- | --- | --- |
| Entry = one USB device | the **device-level** node `USB\VID_2207&PID_xxxx\<id>` (no `&MI_xx`) | macOS matches the device, not its interfaces. A composite board also has `&MI_xx` interface children; the census must take the parent only. The sample shows the node set the board creates. |
| `idVendor`, `idProduct` | `DEVPKEY_Device_HardwareIds` (`USB\VID_2207&PID_5000&REV_xxxx`, `USB\VID_2207&PID_5000`) | Bus-reported descriptor values, as hex text; the instance ID prefix repeats them. Must parse to the same numbers as macOS (0x2207 / 0x5000 in the macOS fixture). |
| `USB Serial Number` | third segment of the device instance ID (`DEVPKEY_Device_InstanceId`) | Windows uses the iSerialNumber string as the instance suffix when the device reports one. A suffix containing `&` (e.g. `5&1a2b3c&0&3`) is a Windows-generated, port-derived ID: **no serial → no identity, fail closed**. The sample must show which case the DAYU200 is, and whether the suffix equals the HDC connectKey byte for byte (letter case matters: XPA-004's target ID is the SHA-256 of the normalised serial). |
| `locationID` (topology) | `DEVPKEY_Device_LocationPaths` (e.g. `PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(3)`), `DEVPKEY_Device_LocationInfo` (`Port_#0003.Hub_#0001`), `DEVPKEY_Device_Parent` | Windows has no packed 32-bit location number; the location path is the stable per-port string and the parent chain gives the hub path. The topology string is therefore a Windows-specific format, not byte-equal to macOS; the sample shows whether it survives a replug into the same port (`after` vs `replugged`). |
| `USB Product Name` | `DEVPKEY_Device_BusReportedDeviceDesc` | The iProduct string as the device reports it. `FriendlyName` / `DeviceDesc` come from the driver INF and are not device facts. |
| Registry entry ID (attachment lifetime) | no direct equivalent; candidates `DEVPKEY_Device_LastArrivalDate` (with `DEVPKEY_Device_LastRemovalDate`) and the node's `present` flag | A serial-bearing device keeps its instance ID across replugs, so the instance ID does not name one attachment. The `removed` / `replugged` phases show whether the arrival time changes per attachment and whether the node persists as non-present in between. |
| (grouping, no macOS field) | `DEVPKEY_Device_ContainerId` | Groups the device and its interface nodes; recorded to relate interface nodes to the device, not as an identity. |
| (driver, no macOS field) | `DEVPKEY_Device_Service`, `DEVPKEY_Device_DriverInfPath`, status / problem | Whether an interface is bound to WinUSB (what `libusb_shared.dll` needs) or has a driver problem; reported, never changed. |

## Redaction rules (agent, before anything is committed)

- Board serial wherever it occurs (instance IDs, `Parent`/`Children`/`Siblings`
  lists, any property string) → a same-length placeholder (`a` repeated, as the
  macOS fixtures do); record its length, character classes and whether it equals
  the HDC connectKey, never its value or a hash of it.
- `ContainerId` and any other per-device GUID → `<container-1>` style labels.
- Every node that is not the DAYU200, its interfaces or its hub/root-hub chain
  is dropped; other devices' identities never enter the repository.
- User paths → `%USERPROFILE%` / `%LOCALAPPDATA%`; no machine or account name.
- Arrival/removal/install times → kept only as order and deltas between phases.
- The sanitized result is recorded as `dayu200-usb-properties-<date>-run.md`
  next to this crib, with the filled-in mapping table above and every
  difference from the macOS census stated as found.

## What this sample feeds

The Windows stable-identity census of TASK-XPA-004 (its `Status` names "the
DAYU200 USB properties sample" as an input). The census design, and any change to
the provider's registered-DAYU200 relation rule for Windows, belong to that task;
this PR changes no Rust source, status line or registry.
