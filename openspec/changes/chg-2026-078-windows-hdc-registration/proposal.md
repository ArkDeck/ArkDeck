---
id: CHG-2026-078-windows-hdc-registration
revision: 3
status: approved # r2 (2026-10-04): samples processed (#2456), maintainer ruling 2026-10-04 applied. r3 (2026-10-04): the Windows server-startup listing; effective only when the maintainer reviews and merges the r3 PR
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-3.0.0
platforms: [windows]
---

# Register Windows HDC tuples, output families and the Windows USB relation census

## Revision r3: the Windows server-startup listing

After r2 and the TASK-WHR-002 registration, the Windows daemon's managed server (CHG-2026-074
TASK-XPA-005) read `list targets -v` from the registered c2 `hdc.exe` with no board attached and
got `[Empty]` CR TAB `hdc` CR LF (14 bytes, exit 0, empty stderr), a form the 2026-10-04 samples
never showed. Registry 1.0.0 classifies it `unknown`.

- **Maintainer ruling 2026-10-04 ("按建议").** Register exactly the observed `[Empty]` byte form as
  "no device"; every other form stays `unknown`.
- **Evidence-driven refinement.** A read-only reproduction against the agent's own server on
  `127.0.0.1:8710` (CHG-2026-074 `evidence/runs/TASK-XPA-002/hdc-windows-empty-form-20261004-run.md`) showed the form is a server-startup race, not an answer:
  - the registered server printed it in 15 of 15 listener-waited starts;
  - it appeared only from the moment the listener answered until at most 1.26 s after the server's
    start, and never after the first enumerated listing;
  - it did not depend on the server's or the client's environment.

  Read as "no device", a board that is attached would be reported absent during that window, a
  fabricated disappearance that design §"Failure, cancellation, and recovery" forbids. r3
  therefore applies the strictly more conservative reading, which the maintainer confirms by
  reviewing and merging this r3 PR.
- **r3 registers** that exact form, and no other, as `notYetObservable`: `unknown` and retryable,
  never `observedEmpty` and never a disappearance.
  - A managed start settles past it by listing again for at most 3 s (more than twice the longest
    window observed).
  - If it persists past the bound, the server stays up and every observation stays `unknown` (fail
    closed).
  - A consumer that reads it at any other time treats it as `unknown`.
- **Versions.** `OPENHARMONY-HDC-WINDOWS-PROBES@1.1.0`, profile `OPENHARMONY-TOOLS@0.7.1`, lock
  `INTEGRATION-PROFILES-0.8.1`, and the fixture `c2/server-startup/`. Every other r2 decision is
  unchanged.

## Revision r2: the samples and the maintainer ruling of 2026-10-04

r1 was a draft with every sample fact `TBD(sample)` and every choice `TBD(maintainer)`. Since then:

- **The samples were captured and processed.** Both candidates and the DAYU200 USB phases were
  captured on 2026-10-04 on the Windows 11 x64 reference host. The sanitized run records and
  redacted resources were merged in #2456:
  - CHG-2026-074 `evidence/runs/TASK-XPA-002/hdc-windows-sample-20261004-run.md`;
  - CHG-2026-074 `evidence/runs/TASK-XPA-004/dayu200-usb-properties-20261004-run.md`.

  The processing script's four defects found on the real samples are fixed in #2457.
- **The maintainer ruled** on every open point (maintainer ruling 2026-10-04, "按照建议执行所有未
  裁决的内容", accepting the recommendations made from the samples):
  1. **Register candidate 2 only.** That is DevEco Studio 26.0.0.43's bundled `hdc.exe`,
     `Ver: 3.2.0g`, identified by executable SHA-256 plus its `-v` bytes.
     - Candidate 1 (`3.2.0b`, origin not recorded) is **not registered**.
     - Tool selection must resolve to the DevEco path. Every DevEco update that changes the hash
       needs a new tuple.
  2. **`list targets -v` on Windows:**
     - Rows with transport `UART` (state `Ready`) are known **non-device rows** and are excluded.
       Only `USB` rows are device observations, and a snapshot with only UART rows is
       **no device**, not `unknown`.
     - The row form is 6 columns with CR LF rows, with the literals as sampled. Anything else stays
       `unknown` and fails closed.
     - The `[Empty]` marker and zero-byte stdout stay `unknown` on Windows, since neither was
       observed.
  3. **`checkserver` is not a read-only probe on Windows.** With no server it starts one. Server
     health is the commandless listener observation: exactly one `127.0.0.1:8710` listener, owned
     by the registered hash, with a stable PID and start time.
  4. **USB census serial.** The instance-ID serial suffix is compared with the HDC connect key after
     an explicit, registered **ASCII-lowercase fold**.
  5. **USB census topology and attachment.**
     - Topology (location path and the like) is valid only within one attachment and is not part
       of the long-term identity.
     - Device identity is the case-folded serial.
     - One attachment is (instance ID, `LastArrivalDate`).
     - The present-only rule is kept.

r2 fills every `TBD(sample)` with the sampled value (or states "not observed") and every
`TBD(maintainer)` with the ruling. It registers nothing by itself: the registry, fixtures, profile
section and lock remain TASK-WHR-002. The maintainer's review and merge of this r2 PR approves the
change in this form.

## Why

The Windows daemon composes the Target owners (#2350), but it dispatches no HDC. None of the
OpenHarmony integration profile's HDC authorities covers Windows:

- the 3.2.0d golden and read-only probe registries;
- the 3.2.0f device-observation registry;
- the 3.2.0f commandless supervisor-observation registry.

All three are exact macOS tuples (tool version, executable SHA-256, endpoint, output bytes), and
`evidence/xpa-002-readonly-foundation.md` §"Windows HDC registration scope needed before
acceptance" forbids relabelling them as Windows evidence.

Until a Windows tuple is registered:

- `device.observations` and `target.adopt` are refused before any dispatch;
- no Catalog operation is available on Windows (`evidence/windows-remaining.md`: 0/30);
- GJ-1 cannot be software-ready on Windows.

The maintainer is sampling two Windows `hdc.exe` builds and the DAYU200's USB properties on the
Windows 11 x64 reference host, with the maintainer-run cribs of CHG-2026-074:

- `evidence/runs/TASK-XPA-002/hdc-windows-sampling-crib-20260930.md`;
- `evidence/runs/TASK-XPA-004/dayu200-usb-properties-crib-20260930.md`.

This change prepares their registration. In r1 every value that had to come from the samples was
`TBD(sample)`, and every choice belonging to the maintainer was `TBD(maintainer)`. r2 fills both
(see "Revision r2"). Nothing is registered until TASK-WHR-002 lands.

## What changes

### In scope

1. **Windows tool identity.** A Windows HDC tuple is identified by the executable's **SHA-256**
   together with the exact `hdc -v` stdout bytes observed with that hash.
   - Never by path, file version, timestamp or signature. The only version resource of both
     candidates belongs to the bundled winpthread, the timestamp is normalised, and neither build
     is Authenticode-signed (crib, "Consequence").
   - Two candidates are known by hash:

     | Candidate | Source | SHA-256 |
     | --- | --- | --- |
     | 1 | hand-placed tools directory | `f6d6c47551d976f33b0f22b17a74f345c0788e59131873aa5f75d356f5141d9b` |
     | 2 | DevEco Studio 26.0.0.43 toolchains | `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e` |

   - Their reported versions are `Ver: 3.2.0b` (candidate 1) and `Ver: 3.2.0g` (candidate 2), both
     CR LF terminated.
   - **Only candidate 2 is registered** (maintainer ruling 2026-10-04, item 1).
2. **A new Windows registry** `OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`
   (`openspec/integrations/openharmony/windows-probes.yaml`, drafted in
   `drafts/windows-probes.yaml`). It is separate from every macOS registry, and each entry carries
   the Windows tuple in its id. Its families:
   - `version`: a golden family, the counterpart of the 3.2.0d golden `version` fixture, with
     Windows bytes;
   - `healthyCheckserver`: recorded as `unsupported` on Windows and never invoked as a probe,
     because `checkserver` starts a server when none runs (ruling item 3). Its bytes are kept as
     a fixture only;
   - `deviceObservationSnapshot`: `list targets -v` on the exact Windows endpoint, with the
     Windows row form (6 columns, CR LF) and UART rows excluded (ruling item 2);
   - `serverIdentityGeneration`: the commandless supervisor observation. Exactly one listener on
     the endpoint (8710) is owned by the selected executable, with process identity and
     pre/post equality. On Windows it is read with the TCP table and process image and creation
     time, and with the per-command brackets the macOS registration lacks (`DEV-1`).
3. **Sanitized Windows fixture families.** A golden pack and a probe pack under
   `rust/tests/fixtures/hdc-windows/<tuple>/`, written by the processing script (below) from the
   samples:
   - the redacted stdout/stderr bytes, byte-exact, with CR/LF as found;
   - a `resources.json` manifest of SHA-256s.
4. **The Windows USB relation census fields.** These are the Windows spelling of the macOS
   `UsbHostDevice` fields (vendor, product, serial, topology, product name, attachment
   lifetime), set in `design.md` §4 from the sample and the ruling. The census code belongs to
   CHG-2026-074 TASK-XPA-004. This change registers:
   - which fields the census may rely on;
   - the ASCII-lowercase serial fold;
   - topology valid only within one attachment;
   - the attachment pair;
   - the fail-closed rule for a port-derived instance suffix.
5. **Profile and lock.** `openspec/integrations/openharmony/profile.md` gains a Windows section
   (drafted in `drafts/profile-windows-section.md`), and
   `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` gains the new registry and resource
   hashes. Both bump the profile version.
6. **The processing script.** `rust/scripts/windows_sample_process.py` with unit tests on
   synthetic input: it turns the raw sample roots into the sanitized fixtures and the two run
   records, following each crib's "What the agent does" rules. It landed with the r1 draft
   (#2384) and was corrected against the real samples in #2457.

### Out of scope

- Running `hdc` or touching the board, by the agent or CI.
- Choosing a candidate without the maintainer. The choice is the maintainer ruling of 2026-10-04
  (candidate 2 only).
- Reusing any macOS value as Windows evidence. The macOS registries, their fixture packs and
  their bytes stay unchanged.
- Consumer wiring (the Windows daemon's HDC provider, supervisor observer, USB relation reader).
  That is CHG-2026-074 TASK-XPA-004/005, which adopts this registry once it is approved.
- `keyAccessDiagnostics`, `subserverCapability`, any device mutation, flash or destructive family.
- Any Core Requirement, Acceptance Scenario, contract, baseline or hardware-matrix change.

### Observable behaviour before and after

- **Before:** no Windows tuple is registered, so every HDC-dependent answer on Windows is a
  zero-dispatch refusal.
- **After approval and adoption:** a Windows daemon whose selected `hdc.exe` has a registered
  SHA-256 may observe devices and prove server identity within exactly the registered families.
  Any other tool, output or endpoint stays `unsupported`/`unknown`, and nothing falls back to a
  macOS registry.

## Scope (Requirements and ACs)

- Requirements, as applied to Windows by `openspec/platforms/windows/profile.md`; no
  Requirement text changes:
  - REQ-HDC-001 (external-first tool selection);
  - REQ-HDC-002 (host-wide supervisor);
  - REQ-HDC-004 (endpoint isolation);
  - REQ-DEV-001 and REQ-DEV-003 (the durable target identity and the USB relation it rests on).
- Acceptance: none changes. CHG-2026-074 XPA-AC-1/2 (identity equality, observation) become
  reachable on Windows once the registry is adopted.
- Contracts/schemas: none. Registries are integration inputs.
- Core baseline bump: no.

## Safety, privacy, and compatibility

- **Failure modes.** Every tuple, output, endpoint or listener mismatch is `unsupported`,
  `unknown` or `unavailable`, never a partial set. Zero-byte stdout and the `[Empty]` marker are
  `unknown` on Windows, never empty; the one observed `[Empty]` form, the server-startup listing,
  is `notYetObservable` (r3), still never empty. Only the sampled UART row form is excluded as a non-device
  row; any other UART form is `unknown`. A port-derived USB instance suffix is no serial and no
  identity (fail closed).
- **Case fold.** The ASCII-lowercase fold of the USB serial is safe. Windows treats device
  instance IDs case-insensitively, so two present devices whose serials differ only in letter
  case cannot exist as separate nodes. The fold is applied only to the census serial before the
  comparison with the connect key; the connect key itself is never rewritten.
- **Privacy.** Connect keys and serials never enter the repository: same-length `a` runs, with
  no hash of key-bearing bytes. User paths, account and machine names are removed. Other USB
  devices are dropped. The processing script scans every output for each secret and refuses on
  a leak.
- **Compatibility.** The macOS registries and profile sections are unchanged and byte-identical.
  The new registry is a separate authority.
- **Platform impact.**
  - macOS: none.
  - Windows: this is the registration Windows needs.
  - Linux: not started.
- **Rollback.** Drop the Windows registry, profile section and lock entries. The consumers then
  refuse again, as today.

## Revision history

- r1 (2026-09-30, #2384): draft with every sample fact `TBD(sample)` and every choice
  `TBD(maintainer)`, plus the processing script.
- r2 (2026-10-04): the sampled values from #2456 and the maintainer ruling 2026-10-04 (five items,
  "Revision r2"). It is effective only when the maintainer reviews and merges this r2 PR.
