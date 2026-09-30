---
id: CHG-2026-078-windows-hdc-registration
revision: 1
status: proposed # draft: every sample-derived value is TBD(sample) until the maintainer's Windows samples are processed
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-3.0.0
platforms: [windows]
---

# Register Windows HDC tuples, output families and the Windows USB relation census

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

This change prepares their registration so that it can be completed as soon as the samples are
processed. **It is a draft.** Every value that must come from the samples is written
`TBD(sample)`, every choice that belongs to the maintainer is `TBD(maintainer)`, and nothing is
registered until those are filled in and the maintainer approves the change.

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

   - Their reported versions are `TBD(sample)`. Which candidate(s) are registered is
     `TBD(maintainer)`.
2. **A new Windows registry** `OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`
   (`openspec/integrations/openharmony/windows-probes.yaml`, drafted in
   `drafts/windows-probes.yaml`). It is separate from every macOS registry, and each entry carries
   the Windows tuple in its id. Its families:
   - `version` and `healthyCheckserver`: golden families, the counterpart of the 3.2.0d golden
     `version`/`healthy` fixtures, with Windows bytes;
   - `deviceObservationSnapshot`: `list targets -v` on the exact Windows endpoint, with the
     `[Empty]` marker, row and terminator facts found on Windows;
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
   lifetime), drafted in `design.md` §4 with each Windows property `TBD(sample)`. The census code
   belongs to CHG-2026-074 TASK-XPA-004. This change registers which fields it may rely on and
   the fail-closed rule for a port-derived instance suffix.
5. **Profile and lock.** `openspec/integrations/openharmony/profile.md` gains a Windows section
   (drafted in `drafts/profile-windows-section.md`), and
   `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` gains the new registry and resource
   hashes. Both bump the profile version.
6. **The processing script.** `rust/scripts/windows_sample_process.py` with unit tests on
   synthetic input: it turns the raw sample roots into the sanitized fixtures and the two run
   records, following each crib's "What the agent does" rules. It lands with this draft and can
   run the day the samples arrive.

### Out of scope

- Running `hdc` or touching the board, by the agent or CI.
- Choosing a candidate without the maintainer.
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
  `unknown` or `unavailable`, never a partial set. Zero-byte stdout is `unknown`, never empty. A
  port-derived USB instance suffix is no serial and no identity (fail closed).
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
