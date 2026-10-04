# TASK-XPA-004 — DAYU200 USB properties on Windows, sanitized run record, 2026-10-04

The processed result of `dayu200-usb-properties-crib-20260930.md` ("Redaction rules"). It fills
in the crib's mapping table from the sample and states every difference from the macOS I/O
Registry census (`arkdeck_platform::usb_registry`) as found. It changes no Rust source, census
mapping verdict (`CENSUS_MAPPING` stays `Tbd`), status line or registry. It is not device
evidence and not acceptance. The census field registration belongs to CHG-2026-078 TASK-WHR-003.

## Capture

- **Who.** Captured on 2026-10-04 by the agent, at the maintainer's instruction, with
  `rust/scripts/windows-usb-sample.ps1` (schema `arkdeck-windows-usb-sample/v2`; read-only PnP
  queries, no elevation). The maintainer only plugged and unplugged the board. They reported no
  driver dialog and no board prompt.
- **Host.** The Windows 11 x64 reference host, 10.0.26200, PowerShell 7.6.6.
- **Root.** `%LOCALAPPDATA%\ArkDeck-samples\usb-dayu200-20261004`, with all four phases:

  | Phase | State | Seconds after the first arrival |
  | --- | --- | --- |
  | `before` | board unplugged | before |
  | `after` | plugged and booted; candidate 1's HDC server running | +21 |
  | `removed` | unplugged | +83 |
  | `replugged` | the same physical port, booted; candidate 2's HDC server running | +439 |

  The interleaving with the HDC phases is in
  `TASK-XPA-002/hdc-windows-sample-20261004-run.md`.

## Processing and redaction

The root was processed with `rust/scripts/windows_sample_process.py usb`, in the corrected
scratch copy described in the HDC run record (findings 2–4: the case-insensitive hub chain,
`HardwareIds` kept, GUID labels).

- **Kept.** Only the two `VID_2207` nodes (the DAYU200's HDC personality and a remembered
  loader personality, below) and their parent root hub. Every other USB device, and its
  entries in `Children`/`Siblings`/`BusRelations`, is dropped. Its parent PCI controller ID
  becomes `<other-device>`.
- **Serials.** Both serials (32 and 16 characters) are same-length `a` runs, wherever they
  occur, matched ignoring case. Only their length, character classes and relation to the HDC
  connect key are recorded.
- **GUIDs and times.** GUIDs become `<container-N>` labels. Dates become an order index; this
  record gives only deltas.
- **Leak scan.** The leak scan of the script and an independent scan (case-folded, UTF-8 and
  UTF-16LE, including the other devices' instance suffixes) found nothing.

Sanitized resources (`.json` LF): `dayu200-usb-properties-20261004/`, holding
`usb-before.json`, `usb-after.json`, `usb-removed.json`, `usb-replugged.json` and
`summary.json`.

## Nodes the board creates

| Node | `present` in before / after / removed / replugged | Class / service | Notes |
| --- | --- | --- | --- |
| `USB\VID_2207&PID_5000\<32-char serial>` | no / **yes** / no / **yes** | `USBDevice` / `WINUSB` (`winusb.inf`, via compatible ID `USB\MS_COMP_WINUSB`) | the HDC personality. One device-level node, **no `&MI_xx` interface nodes** (`Children` empty). Class `FF`/`50`/`01`. Status OK, no problem code when present; `CM_PROB_PHANTOM` when absent |
| `USB\VID_2207&PID_350A\<16-char serial>` | no / no / no / no | `Rockusb Device` / `Rockusb` (third-party `oem*.inf`) | a remembered phantom, last arrival 2026-09-17. Bus-reported name `USB download gadget`, class `FF`/`06`/`05`. Its 16-digit serial is unrelated to the HDC connect key |
| `USB\ROOT_HUB30\4&73F3995&0&0` | yes in all | `USB` / `USBHUB3` | the parent of both. No external hub in the chain |

## Mapping to the macOS census fields (filled in)

| macOS field | Windows property | Sample shows | Verdict |
| --- | --- | --- | --- |
| Entry = one USB device | device-level node `USB\VID_2207&PID_5000\<id>` | One node, no interface children. WinUSB is bound at the device level (a single-function device), so there is no parent/interface split to make. Phantom (non-present) nodes persist with their last attachment's properties | confirmed. Only **present** nodes may count, which the census already ensures (`DIGCF_PRESENT`) |
| `idVendor`, `idProduct` | `DEVPKEY_Device_HardwareIds` | `USB\VID_2207&PID_5000&REV_0223`, `USB\VID_2207&PID_5000`. The instance-ID prefix repeats VID/PID | confirmed: `0x2207`/`0x5000`, the same numbers as the macOS fixture. `REV_0223` (bcdDevice) has no macOS census field |
| `USB Serial Number` | third segment of `DEVPKEY_Device_InstanceId` | 32 characters, no `&`, so it is device-reported, not port-derived. **Upper-case hex** (digits and `A`–`F`). **Equal to the HDC connect key only ignoring ASCII case**: the connect key is lower-case hex, so they are **not byte-equal** | refuted as "byte-equal". See "Serial and the connect key" |
| `locationID` (topology) | `DEVPKEY_Device_LocationPaths` first entry; `LocationInfo`; `Parent` | `after`: `PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(10)` / `…#ACPI(RHUB)#ACPI(HS10)`, `Port_#0010.Hub_#0001`, address 10. `replugged` (same physical port): `…#USB(26)` / `…#ACPI(SS10)`, `Port_#0026.Hub_#0001`, address 26. `Parent` is the same root hub both times. `DEVPKEY_Device_PhysicalDeviceLocation` (the ACPI `_PLD` buffer) is identical in all phases | **refuted**: the first location path does **not** survive a replug into the same physical port. See "Topology" |
| `USB Product Name` | `DEVPKEY_Device_BusReportedDeviceDesc` | `"HDC Device"`, double quotes included (12 characters), byte-equal to the macOS fixture's `USB Product Name`. `FriendlyName` carries the same text, and `DeviceDesc`/`Manufacturer` carry the INF's localized `WinUSB 设备` | confirmed |
| Registry entry ID (attachment lifetime) | `DEVPKEY_Device_LastArrivalDate` (+ `LastRemovalDate`, `present`) | `LastArrivalDate` is new for each attachment: attachment B arrived 381.17 s after A. It is unchanged within an attachment, and is kept on the phantom after removal. `LastRemovalDate` is absent while present and set on removal (52.68 s after arrival A). The instance ID and `PDOName` (`\Device\USBPDO-1`) are the **same** for both attachments | confirmed with a caveat: one attachment = (instance ID, `LastArrivalDate`). Neither alone names it |
| grouping (`ContainerId`) | `DEVPKEY_Device_ContainerId` / `BaseContainerId` | **differs between the two attachments** (`<container-2>` on `SS10`, `<container-8>` on `HS10`; the `before` phantom kept the `SS10` value from an earlier attachment) | not stable across replug; grouping only, never identity |
| driver | `DEVPKEY_Device_Service`, `DriverInfPath`, problem | `WINUSB`, `winusb.inf`, `CM_PROB_NONE` when present; the loader phantom is `Rockusb` | WinUSB present for `libusb_shared.dll`; nothing changed |

## Serial and the connect key

The board's iSerialNumber case cannot be read from the PnP properties:

- The device instance ID (`InstanceId`, the node's own ID) spells the suffix in **upper
  case**.
- The hub's `Children`/`BusRelations` and the other nodes' `Siblings` spell the same instance in
  **lower case**. That lower-case spelling equals the connect key byte for byte. But those lists
  lower-case every instance ID, including Windows-generated ones (another device's port-derived
  `5&<hex>&0&<n>` suffix is lower-case hex in these lists and upper-case hex in its own
  `InstanceId`; the root hub's own ID shows the same, `4&73f3995&0&0` in `Parent` against
  `4&73F3995&0&0`), so the lower case is Windows' spelling, not
  evidence of the device's own case.

Consequence for the census as built (`serial` = "instance ID suffix, as it is"):

- **The relation would never match.** `usable_relations` compares `relation.serial ==
  candidate serial` byte for byte, so an upper-case suffix never matches the lower-case HDC
  connect key. Every DAYU200 relation would fail closed (`generationScoped`) even with the
  mapping confirmed.
- **The stable identity digest is case-blind.** `stable_identity_sha256_for_serial` lower-cases
  before hashing, so the digest would be equal.
- **Matching needs a fold.** Matching therefore needs an explicit, registered case rule, for
  example ASCII-lower-casing the instance suffix. Windows itself treats instance IDs
  case-insensitively, so two devices whose serials differ only in case cannot coexist as
  separate nodes anyway.

That rule is a census design decision (TASK-XPA-004, registered by CHG-2026-078 WHR-003). It is
not made here.

## Topology

- **Two location paths.** The two attachments into the same physical connector enumerated on
  different root-hub ports: `HS10` (USB 2) for attachment A and `SS10` (USB 3) for attachment B.
  That they share a connector is shown by the identical `_PLD` buffer and by the
  maintainer's report.
- **Speed is inferred.** The speed itself is not a sampled property. The `HS`/`SS` ACPI names
  are the basis for that inference.
- **Different digests.** The location path, `LocationInfo`, address, `BiosDeviceName` and
  `ContainerId` all differ, so ruling 11's hashed topology differs between the two attachments.
- **Stable within an attachment.** Within one attachment the path did not change; the phantom
  keeps it after removal.
- **Earlier attachments.** The `before` phantom shows an earlier attachment that day was on
  `SS10` too.
- **No macOS counterpart.** The macOS census has no recorded counterpart for this case: whether
  `locationID` changes between a USB 2 and a USB 3 enumeration of one connector is not in the
  macOS fixtures.

## Differences from the macOS census, stated as found

1. **Serial case.** The serial comes from the instance-ID suffix in upper case; macOS reads the
   `USB Serial Number` string. It is equal to the HDC connect key only ignoring ASCII case.
2. **No packed location.** There is no packed `locationID`. The location path is a string, and it
   changed between two attachments to the same physical connector (`HS10` vs `SS10`).
3. **No entry ID.** There is no registry entry ID. An attachment is named by `LastArrivalDate`
   together with the instance ID. `PDOName` and the instance ID repeat across attachments.
4. **Phantom nodes.** Phantom nodes persist with stale properties (location, container, arrival
   and removal dates) after removal. The macOS registry has no entry for an absent device.
5. **A remembered loader personality.** A second `VID_2207` personality (`PID_350A`, Rockusb
   loader, 16-digit serial) is remembered by the host. It was never present during this sample.
6. **Unchanged from macOS.** VID/PID numbers and the bus-reported product name (quotes included)
   equal the macOS fixture.

## Answers to the open questions of `windows-usb-census-run.md`

1. **Is the suffix the iSerialNumber, byte-equal to the connect key?** It is a device-reported
   serial (no `&`). It is **not byte-equal** to the connect key: upper case against lower case.
   It is equal ignoring case. As built, relations would never match and would fail closed.
2. **Is the bus-reported name `HDC Device`?** It is `"HDC Device"`, with the double quotes, as
   on macOS.
3. **Does `LastArrivalDate` change per attachment?** Yes. It changes on every attachment and
   stays fixed within one.
4. **Does the first location path survive a replug into the same port?** **No** in this sample:
   it moved from `USB(10)`/`HS10` to `USB(26)`/`SS10`.

## Local targeted checks

| Command | Result |
| --- | --- |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | exit 0 (`check_sdd: 0 error(s), 0 warning(s)`) |
| `git diff --check` | clean |

No Rust, Swift or contract input changed, so no cargo, Swift or generator check applies. CI: the PR's run, recorded by a follow-up.
