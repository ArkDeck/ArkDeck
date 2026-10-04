# Change Design: Windows HDC registration (r2)

## Context and constraints

- Proposal: `proposal.md` revision 2 (samples of 2026-10-04 and maintainer ruling 2026-10-04).
- Core baseline: CORE-3.0.0, unchanged.
- Related inputs:
  - `openspec/integrations/openharmony/profile.md` (OPENHARMONY-TOOLS@0.6.0) and its three
    macOS HDC registries;
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`;
  - `openspec/platforms/windows/profile.md`;
  - CHG-2026-074 `evidence/xpa-002-readonly-foundation.md` §"Windows HDC registration scope";
  - the two sampling cribs (HDC and USB).
- Repository evidence (r2):
  - the static facts of both candidates are in the HDC crib;
  - the 2026-10-04 samples are in the sanitized run records and redacted resources of #2456
    (CHG-2026-074 `evidence/runs/TASK-XPA-002/hdc-windows-sample-20261004-run.md` and
    `evidence/runs/TASK-XPA-004/dayu200-usb-properties-20261004-run.md`).
- Rerunning the corrected processing script (#2457) on the raw roots reproduces those redacted
  resources byte for byte, apart from one hand-redacted path in candidate 2's `tool.json`.

r1 used two placeholders: `TBD(sample)` for values read from the processed samples, and
`TBD(maintainer)` for the maintainer's decisions. In r2:

- every sample value comes from those records, never from macOS; a fact the samples did not show
  is written **not observed**;
- every decision cites **maintainer ruling 2026-10-04**, item 1–5 of `proposal.md`
  "Revision r2".

## 1. Tool identity

| Field | Rule | Value (r2) |
| --- | --- | --- |
| `platform` | `windows` | fixed |
| `executableSHA256` | the selected `hdc.exe` bytes, verified before and after every probe | **candidate 2 only**: `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e` (maintainer ruling 2026-10-04, item 1). Candidate 1 (`f6d6c475…d9b`) is not registered |
| `reportedVersion` | the `Ver: X` text of `hdc -v` stdout observed with that hash | `3.2.0g` (candidate 2). Candidate 1 printed `3.2.0b`, recorded only |
| `versionBytes` | the exact stdout bytes of `hdc -v`, terminator included | `Ver: 3.2.0g` CR LF, 13 B, SHA-256 `78c4d7b4ffc0bb7bb0bac0512e5fe9da25be07c481ff7a41dfc9732f7da0a424` |
| path, file version, timestamp, signature | **not** identity (winpthread version resource, normalised timestamp, NotSigned) | — |
| Mark-of-the-Web | recorded as provenance, never identity; candidate 2 carries it | `ZoneId=3`, no `HostUrl` |
| source channel | provenance; selection must resolve to it | DevEco Studio 26.0.0.43 `sdk\default\openharmony\toolchains\hdc.exe` (apiVersion 26, Beta). On the sampled host it is not on `PATH` (candidate 1 is), so external-first selection must resolve to the DevEco path or answer `unsupported` (ruling item 1) |

Two different builds are two tuples. Nothing is inferred between them, or from either to the
macOS 3.2.0d/3.2.0f tuples, even if `-v` prints the same version text. A DevEco update that
changes the executable hash is a new, unregistered tuple until a later change registers it
(ruling item 1).

## 2. Registry `OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`

It is drafted in full in `drafts/windows-probes.yaml`. It is a JSON-compatible YAML 1.2 file
with the same schema as `device-observation-probes.yaml` and `supervisor-observation-probes.yaml`.
Entry ids end in `-<reportedVersion>-windows-<sha-prefix>`, so no entry can be confused with a
macOS one. For candidate 2 the suffix is `-3.2.0g-windows-c7951849`.

| Family | Kind | Argv | Sampled facts (candidate 2; candidate 1 identical apart from the version text) | Status |
| --- | --- | --- | --- | --- |
| `version` | golden | `-v` | `Ver: 3.2.0g` CR LF, 13 B; stderr empty; exit 0; starts no server (0 → 0 listeners) | `supported` |
| `healthyCheckserver` | golden bytes only | `checkserver` | with the server up: `Client version:Ver: 3.2.0g, server version:Ver: 3.2.0g` CR LF, 56 B. With **no** server it **starts one** (0 → 1 listeners, about 1.44 s) and prints the same form | `unsupported` as a probe; never invoked (ruling item 3) |
| `deviceObservationSnapshot` | `hdcCommand`, existing-server-only | `list targets -v` | 6 TAB columns, CR LF rows (below); device row kept and flipped to `Offline` on removal; UART rows in every phase; `[Empty]` and zero bytes not observed | `supported` with the rule below (ruling item 2) |
| `serverIdentityGeneration` | `platformProcessObservation`, commandless | `[]` | one listener on `127.0.0.1:8710` (IPv4 loopback only); owner image SHA-256 = the selected tool; the same PID and creation time in every bracket of every phase across unplug and replug; started by `checkserver` with no server; stopped by `kill` | `supported`; this is Windows server health (ruling item 3) |

The endpoint is **`127.0.0.1:8710`**, as observed. No `0.0.0.0`, `::` or dual-stack listener was
seen. Another address, a second listener or a foreign owner is not the registered endpoint.

### `list targets -v` row form (ruling item 2)

Observed with candidate 2 (and byte-identical with candidate 1):

| Row | Columns (TAB) | Terminator | Bytes (32-character key) |
| --- | --- | --- | --- |
| board, present | `<connectKey>` / `` (deviceName, empty) / `USB` / `Connected` / `localhost` / `hdc` | CR LF | 63 |
| board, removed | the same with `Offline` | CR LF | 61 |
| host serial port | `COM<n>` / `` / `UART` / `Ready` / `unknown...` / `hdc` | CR LF | 33 (`COM1`, `COM2`) |

Registered interpretation:

- **Device rows.** Only rows with transport `USB` are device observations. Presence is decided by
  the state column (`Connected` present, `Offline` absent), as on macOS. A removed device keeps
  its row.
- **Non-device rows.** A row is a known non-device row and is **excluded** only when every field
  has the sampled UART form:
  - connectKey `COM<digits>`;
  - empty deviceName;
  - transport `UART`;
  - state `Ready`;
  - hostTag `unknown...`;
  - sixth column `hdc`.

  Any other UART row is `unknown`.
- **No device.** A snapshot of only excluded rows, or of excluded rows plus `Offline` USB rows,
  is `observedEmpty`, not `unknown`.
- **Fail closed.** Each of these makes the whole snapshot `unknown`:
  - a column count other than 6;
  - a sixth column other than `hdc`;
  - an unknown transport, state or hostTag literal;
  - a duplicate connect key;
  - a CR left inside a field;
  - non-empty stderr, a non-zero exit, or truncation.
- **Not observed, so `unknown`.** The `[Empty]` marker (never emitted on the sampled host) and
  zero-byte stdout are `unknown` on Windows. They are not registered as empty.

### CR/LF rule

The parser accepts LF and CR LF and no field may keep a CR, as on macOS. Every sampled Windows
stdout (`-v`, `checkserver`, every `list targets -v` row, `kill`) is CR LF; the registry records
`observedTerminator: CRLF` per family. A parser that splits on LF only would leave the CR in the
sixth column, which is `unknown` (residual CR). The fixtures keep the bytes exactly.

## 3. Fixture families

The corrected processing script (#2457) writes these under
`rust/tests/fixtures/hdc-windows/c2/` for the registered candidate (ruling item 1). Candidate 1's
redacted output stays evidence only (CHG-2026-074, #2456) and is not a registered fixture.

| File | Content |
| --- | --- |
| `tool.json` | the sanitized tool facts (SHA-256, size, Authenticode, MotW reduced to `ZoneId` and URL host, version resource, sibling DLLs) |
| `<phase>/<command>.stdout.bin`, `.stderr.bin` | the redacted bytes: connect keys become same-length `a` runs, `COM<n>` UART names are kept, every other byte is kept |
| `<phase>/sample.json` | exit, duration, pipe closure, raw byte counts, **redacted** SHA-256s, terminators, listener/owner state before and after each command with PID labels and relative start seconds |
| `summary.json` | the comparison with the macOS-registered facts, and the anomalies |

The registered fixture pack (`golden/` and `probes/` with `resources.json`) is then assembled
from these files by TASK-WHR-002. Each registered fixture is one of these redacted byte files,
listed with its SHA-256 in `resources.json` and in the lock. The expected redacted SHA-256s
(identical to the #2456 resources):

| Fixture | Bytes | SHA-256 |
| --- | --- | --- |
| `no-board/version.stdout.bin` | 13 | `78c4d7b4ffc0bb7bb0bac0512e5fe9da25be07c481ff7a41dfc9732f7da0a424` |
| `no-board/checkserver-server-up.stdout.bin` | 56 | `653e2fe893655835e9c2ed84a2b0b8663cec4af47fa8d50f5304ea912d38c37e` |
| `no-board/list-targets-empty.stdout.bin` (UART rows only) | 66 | `31ab060ed0339793ebabd7b8b5c36866d5f37ee80aa0d43eecad9ffc897db623` |
| `board-connected/list-targets-board-connected.stdout.bin` | 129 | `55f6ea08dde54a798535c7350526b5a6913c2a80d9ba9a318a5b21a699bde3da` |
| `board-removed/list-targets-board-removed.stdout.bin` | 127 | `95f2d8900e51ab1e9d51d7c8dc1144c3294a8838af20cf0083b1fbda4ba72a4e` |

## 4. Windows USB relation census (for TASK-XPA-004)

Sample: CHG-2026-074 `evidence/runs/TASK-XPA-004/dayu200-usb-properties-20261004-run.md`.

| macOS `UsbHostDevice` field | Windows source | Registered rule | Sample fact |
| --- | --- | --- | --- |
| one USB device | the device-level PnP node `USB\VID_2207&PID_5000\<suffix>` (no `&MI_xx`) | interfaces, if any, are grouped under it and never counted. **Present nodes only**; a phantom (non-present) node keeps stale properties and is never an entry (ruling item 5) | one device-level node and no interface nodes: WinUSB is bound at device level. A remembered phantom loader node `USB\VID_2207&PID_350A\<16-digit serial>` (Rockusb) was never present |
| `idVendor`, `idProduct` | `DEVPKEY_Device_HardwareIds` (`USB\VID_…&PID_…`) | parsed as hex to the same numbers as macOS | `USB\VID_2207&PID_5000&REV_0223`, `USB\VID_2207&PID_5000`, giving `0x2207`/`0x5000` as on macOS |
| serial | the instance ID's third segment | a suffix containing `&` is Windows-generated and port-derived: **no serial, no identity, fail closed**. Otherwise the suffix is **ASCII-lowercase folded** before it is compared with the HDC connect key or used as the identity serial (ruling item 4). The connect key is not rewritten | device-reported (no `&`), 32 characters, upper-case hex. The connect key is 32 characters of lower-case hex. They are equal after the fold, not byte-equal |
| topology (`locationID`) | `DEVPKEY_Device_LocationPaths` (first entry) | Windows format, never byte-equal to macOS; maintainer ruling 11 hashes it for the USB topology field. **Valid only within one attachment** and never part of the long-term identity (ruling item 5) | does **not** survive a replug into the same physical port: `…#USB(10)` (`HS10`) became `…#USB(26)` (`SS10`). `LocationInfo`, address and `ContainerId` changed too; `Parent` and the ACPI `_PLD` buffer did not |
| product name | `DEVPKEY_Device_BusReportedDeviceDesc` | device-reported only; `FriendlyName`/`DeviceDesc` are INF text, not device facts | `"HDC Device"` with the double quotes (12 characters), the same as the macOS `USB Product Name` fixture |
| attachment lifetime | the pair (instance ID, `DEVPKEY_Device_LastArrivalDate`) of a present node | one attachment = that pair (ruling item 5). Neither alone names an attachment; a missing or zero arrival forms no relation | `LastArrivalDate` is new on every attachment (+381.17 s between the two) and fixed within one. The instance ID and `PDOName` repeat across attachments. `LastRemovalDate` is absent while present |
| driver binding | `DEVPKEY_Device_Service` of the device node (the board has no interface nodes) | WinUSB (what `libusb_shared.dll` needs) recorded, never changed | `WINUSB` from `winusb.inf` via `USB\MS_COMP_WINUSB`, `CM_PROB_NONE` |

Long-term device identity is the case-folded serial (ruling item 5). It agrees with
`stable_identity_sha256_for_serial`, which already lower-cases.

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| REQ-HDC-001 external-first tool selection | §1 identity by SHA-256 and `-v` bytes | registry and fixture hash closure tests (TASK-WHR-002) |
| REQ-HDC-002 host-wide supervisor | §2 `serverIdentityGeneration` (Windows) | Windows observer contract tests, consumer side in CHG-2026-074 |
| REQ-HDC-004 endpoint isolation | §2 exact observed endpoint, no fallback | negative vectors: other address, second listener, foreign owner |
| REQ-DEV-001/003 identity and USB relation | §4 census fields: present-only, ASCII-lowercase serial fold, attachment = (instance ID, arrival), topology per attachment only, fail closed on a port-derived suffix | XPA-004 census tests over the sanitized USB sample |
| REQ-HDC-002 device observation on Windows | §2 row form: USB rows only, sampled UART rows excluded, everything else `unknown` | fixture classification and negative vectors (TASK-WHR-002) |

## Architecture and data flow

This is an integration input only. The Windows daemon's consumers (CHG-2026-074 TASK-XPA-004/005)
read the registry through the same parser and registry types as macOS, keyed by platform and
executable SHA-256. The registry itself implements nothing.

The processing script is a host tool. It reads the raw roots outside the repository and writes
only sanitized material into the repository.

## Data and contract changes

- New file `openspec/integrations/openharmony/windows-probes.yaml`.
- New fixtures under `rust/tests/fixtures/hdc-windows/`.
- A new Windows section in `profile.md`, with a version bump (`OPENHARMONY-TOOLS@0.7.0`, fixed
  at registration time by TASK-WHR-002).
- The lock gains the registry and resource SHA-256s.
- No schema or contract change.

## Authority and production reachability

- **Production composition root.** The Windows daemon's `windows_lifecycle::Authority::compose`
  (CHG-2026-074), when TASK-XPA-004/005 adopt this registry. Not in this change.
- **Authority point.** The registry entry matched by the selected executable's SHA-256. A caller
  cannot supply the entry, the hash or the version.
- **Effect dispatch point.** None in this change. The registered families are read-only or
  commandless, and every lifecycle, mutation and destructive effect is forbidden in each entry.
- **Fake and production.** Synthetic vectors in the contract tests prove fail-closed behaviour
  only. They never count as provenance or as hardware support.
- **Facts and provenance.** The 2026-10-04 capture was taken by the agent at the maintainer's
  instruction (AGENTS.md #2454 allows read-only `hdc` sampling); the maintainer did the plugging.
  It was processed by the reviewed script (#2457), and the committed bytes are the redacted
  capture, hash-pinned. No caller can supply a fixture, a hash or an entry.

## Failure, cancellation, and recovery

These rules are inherited from the macOS families, with the Windows additions of maintainer
ruling 2026-10-04:

- a tool, path or hash mismatch is `unsupported`;
- a server or listener absent is `unavailable`;
- multiple or ambiguous owners, pre/post drift, an unknown literal, a wrong column count,
  non-empty stderr, a non-zero exit, a timeout or a truncated read give `unknown`;
- zero-byte stdout is `unknown`, and so is the `[Empty]` marker on Windows (never observed);
- only the sampled UART row form is excluded as a non-device row, and any other UART form is
  `unknown`;
- `checkserver` is never dispatched as a probe, because it can start a server;
- there is never a partial device set and never a fabricated disappearance.

## Security and privacy

- Connect keys and serials are same-length `a` runs, with no hash of key-bearing bytes.
- User paths are `%USERPROFILE%`/`%LOCALAPPDATA%`-relative. Account and machine names are
  removed.
- Only the DAYU200 chain is kept of the USB tree.
- PIDs and GUIDs become labels, and times become order and deltas.
- The script scans every output for each secret and fails, removing the output, on a leak.
