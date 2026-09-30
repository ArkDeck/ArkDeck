# Change Design: Windows HDC registration (draft)

## Context and constraints

- Proposal: `proposal.md` revision 1, status proposed (draft).
- Core baseline: CORE-3.0.0, unchanged.
- Related inputs:
  - `openspec/integrations/openharmony/profile.md` (OPENHARMONY-TOOLS@0.6.0) and its three
    macOS HDC registries;
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`;
  - `openspec/platforms/windows/profile.md`;
  - CHG-2026-074 `evidence/xpa-002-readonly-foundation.md` §"Windows HDC registration scope";
  - the two sampling cribs (HDC and USB).
- Repository evidence today: the static facts of both candidates (SHA-256, size, Authenticode,
  MotW, version resource) are in the HDC crib. No Windows `hdc` output has been captured yet;
  every output fact below is `TBD(sample)`.

Placeholders used in this change:

- `TBD(sample)`: a value that must be read from the processed samples
  (`rust/scripts/windows_sample_process.py` output). It is never filled from macOS.
- `TBD(maintainer)`: a decision that belongs to the maintainer (which candidate, which families
  are `supported`).

## 1. Tool identity

| Field | Rule | Value |
| --- | --- | --- |
| `platform` | `windows` | fixed |
| `executableSHA256` | the selected `hdc.exe` bytes, verified before and after every probe | one entry per registered candidate: `f6d6c475…d9b` (candidate 1) and/or `c7951849…01e` (candidate 2); `TBD(maintainer)` which |
| `reportedVersion` | the `Ver: X` text of `hdc -v` stdout observed with that hash | `TBD(sample)` per candidate |
| `versionBytes` | the exact stdout bytes of `hdc -v`, terminator included | `TBD(sample)` (LF or CRLF, as found) |
| path, file version, timestamp, signature | **not** identity (winpthread version resource, normalised timestamp, NotSigned) | — |
| Mark-of-the-Web | recorded as provenance, never identity; candidate 2 carries it | from the crib; `ZoneId` `TBD(sample)` |

Two different builds are two tuples. Nothing is inferred between them, or from either to the
macOS 3.2.0d/3.2.0f tuples, even if `-v` prints the same version text.

## 2. Registry `OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`

It is drafted in full in `drafts/windows-probes.yaml`. It is a JSON-compatible YAML 1.2 file
with the same schema as `device-observation-probes.yaml` and `supervisor-observation-probes.yaml`.
Entry ids end in `-<reportedVersion>-windows-<sha-prefix>`, so no entry can be confused with a
macOS one.

| Family | Kind | Argv | Facts to fill from the samples |
| --- | --- | --- | --- |
| `version` | golden | `-v` | stdout bytes, terminator, stderr empty, exit 0 |
| `healthyCheckserver` | golden | `checkserver` | the `Client version:…, server version:…` form **with the server up**; whether `checkserver` with no server starts one (from the per-command brackets); if it does, the family is `server-starting` and is **not** a read-only probe |
| `deviceObservationSnapshot` | `hdcCommand`, existing-server-only | `list targets -v` | `[Empty]` marker bytes and terminator; zero-byte behaviour; row columns (5?), delimiter, row terminator, `Connected`/`Offline` literals, transport literal(s), hostTag literal(s), row byte length for the observed key length; row kept as `Offline` after removal or deleted; whether the marker disappears after a device was seen; any `CR` inside a field |
| `serverIdentityGeneration` | `platformProcessObservation`, commandless | `[]` | the listening address(es) (`127.0.0.1:8710` vs `0.0.0.0`/`::`); exactly one listener; owner image SHA-256 equals the selected tool; PID and creation time stable across every phase; which command started the server |

The endpoint is `TBD(sample)`. The macOS registries fix `127.0.0.1:8710`; Windows registers only
the address it actually observed. A dual-stack or wildcard listener is a Windows-specific
difference, recorded, never normalised to the macOS form.

### CR/LF rule

The parser rule stays the macOS one: it accepts LF and CRLF, and no field may keep a CR. The
registry records the **observed** terminator of each Windows family separately
(`observedTerminator`). The fixtures keep the bytes exactly, so a consumer's parser is tested
against the real Windows bytes, not a normalised copy.

## 3. Fixture families

The processing script writes these under `rust/tests/fixtures/hdc-windows/<label>/`:

| File | Content |
| --- | --- |
| `tool.json` | the sanitized tool facts (SHA-256, size, Authenticode, MotW reduced to `ZoneId` and URL host, version resource, sibling DLLs) |
| `<phase>/<command>.stdout.bin`, `.stderr.bin` | the redacted bytes: connect keys become same-length `a` runs, and every other byte is kept |
| `<phase>/sample.json` | exit, duration, pipe closure, raw byte counts, **redacted** SHA-256s, terminators, listener/owner state before and after each command with PID labels and relative start seconds |
| `summary.json` | the comparison with the macOS-registered facts, and the anomalies |

The registered fixture pack (`golden/` and `probes/` with `resources.json`) is then assembled
from these files by TASK-WHR-002. Each registered fixture is one of these redacted byte files,
listed with its SHA-256 in `resources.json` and in the lock.

## 4. Windows USB relation census (for TASK-XPA-004)

| macOS `UsbHostDevice` field | Windows source (candidate from the USB crib) | Registered rule | Sample fact |
| --- | --- | --- | --- |
| one USB device | the device-level PnP node `USB\VID_2207&PID_xxxx\<suffix>` (no `&MI_xx`) | interfaces are grouped under it, never counted as devices | node set `TBD(sample)` |
| `idVendor`, `idProduct` | `DEVPKEY_Device_HardwareIds` (`USB\VID_…&PID_…`) | parsed as hex to the same numbers as macOS | `TBD(sample)` |
| serial | the instance ID's third segment | a suffix containing `&` is Windows-generated and port-derived: **no serial, no identity, fail closed** | serial or port-derived, its length and character classes, equality with the HDC connect key (case-sensitive): `TBD(sample)` |
| topology (`locationID`) | `DEVPKEY_Device_LocationPaths` (first entry) | Windows format, never byte-equal to macOS; maintainer ruling 11 hashes it for the USB topology field | survives a replug into the same port: `TBD(sample)` |
| product name | `DEVPKEY_Device_BusReportedDeviceDesc` | device-reported only; `FriendlyName`/`DeviceDesc` are INF text, not device facts | `TBD(sample)` |
| attachment lifetime | `DEVPKEY_Device_LastArrivalDate` with `present` | per-attachment only if arrival changes per replug | `TBD(sample)` |
| driver binding | `DEVPKEY_Device_Service` of the interfaces | WinUSB (what `libusb_shared.dll` needs) recorded, never changed | `TBD(sample)` |

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| REQ-HDC-001 external-first tool selection | §1 identity by SHA-256 and `-v` bytes | registry and fixture hash closure tests (TASK-WHR-002) |
| REQ-HDC-002 host-wide supervisor | §2 `serverIdentityGeneration` (Windows) | Windows observer contract tests, consumer side in CHG-2026-074 |
| REQ-HDC-004 endpoint isolation | §2 exact observed endpoint, no fallback | negative vectors: other address, second listener, foreign owner |
| REQ-DEV-001/003 identity and USB relation | §4 census fields, fail closed on a port-derived suffix | XPA-004 census tests over the sanitized USB sample |

## Architecture and data flow

This is an integration input only. The Windows daemon's consumers (CHG-2026-074 TASK-XPA-004/005)
read the registry through the same parser and registry types as macOS, keyed by platform and
executable SHA-256. The registry itself implements nothing.

The processing script is a host tool. It reads the raw roots outside the repository and writes
only sanitized material into the repository.

## Data and contract changes

- New file `openspec/integrations/openharmony/windows-probes.yaml`.
- New fixtures under `rust/tests/fixtures/hdc-windows/`.
- A new Windows section in `profile.md`, with a version bump (`OPENHARMONY-TOOLS@0.7.0`,
  `TBD` at registration time).
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
- **Facts and provenance.** The maintainer's capture, processed by a reviewed script. The agent
  cannot produce the raw bytes (it never runs `hdc`), and the committed bytes are the redacted
  capture, hash-pinned.

## Failure, cancellation, and recovery

These rules are inherited unchanged from the macOS families:

- a tool, path or hash mismatch is `unsupported`;
- a server or listener absent is `unavailable`;
- multiple or ambiguous owners, pre/post drift, an unknown literal, a wrong column count,
  non-empty stderr, a non-zero exit, a timeout or a truncated read give `unknown`;
- zero-byte stdout is `unknown`;
- there is never a partial device set and never a fabricated disappearance.

## Security and privacy

- Connect keys and serials are same-length `a` runs, with no hash of key-bearing bytes.
- User paths are `%USERPROFILE%`/`%LOCALAPPDATA%`-relative. Account and machine names are
  removed.
- Only the DAYU200 chain is kept of the USB tree.
- PIDs and GUIDs become labels, and times become order and deltas.
- The script scans every output for each secret and fails, removing the output, on a leak.
