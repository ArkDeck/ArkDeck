# CHG-2026-078 Tasks

## TASK-WHR-001 — Process the maintainer's Windows HDC and USB samples

- Status:blocked（waits for the maintainer's sample roots, both HDC candidates and the DAYU200
  USB phases, taken with the CHG-2026-074 cribs; the processing script and its tests land with
  this draft）
- Platform:windows
- Requirements:REQ-HDC-001, REQ-HDC-002, REQ-HDC-004, REQ-DEV-001, REQ-DEV-003
- Acceptance:none changes
- Depends on:the maintainer's sample roots（`%LOCALAPPDATA%\ArkDeck-samples\hdc-c1-*`,
  `hdc-c2-*`, `usb-dayu200-*`）
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: rust/scripts/windows_sample_process.py
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:none（host-only file processing, no effect; the refusal on any
  leak is the script's own check）
- Production reachability:not applicable（the output is evidence and fixtures, not a runtime
  path）
- Trusted fact sources:the maintainer's capture with `windows-hdc-sample.ps1` and
  `windows-usb-sample.ps1`. The agent never runs `hdc` and cannot produce the raw bytes. The
  committed fixtures are the redacted capture.
- Allowed paths:
  - `rust/tests/fixtures/hdc-windows/**`
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-002/hdc-windows-sample-*-run.md`
  - `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-004/dayu200-usb-properties-*-run.md`
  - `openspec/changes/chg-2026-078-windows-hdc-registration/**`
- Forbidden paths:
  - `openspec/integrations/**`（registration is TASK-WHR-002）
  - the raw sample roots（read only; never copied into a work tree）
- Risk:low
- Hardware required:no（the maintainer's capture is its input; this task touches no device）

### Deliverables

r2 progress note (planning only; the status line above is unchanged):

- The samples were captured on 2026-10-04.
- The run records and redacted resources merged in #2456.
- The script's defects on the real samples are fixed in #2457.
- Deliverables 2–4 are covered by #2456 and by this change's r2. Only deliverable 1 remains, and
  only for the registered candidate.

1. For the registered candidate only (maintainer ruling 2026-10-04: c2), run
   `python rust/scripts/windows_sample_process.py hdc --root <raw c2> --label c2 --tool-dir
   <DevEco install> --out rust/tests/fixtures/hdc-windows/c2`. The output must reproduce the
   redacted SHA-256s listed in `design.md` §3. Candidate 1's output stays CHG-2026-074 evidence
   only.
2. For USB, `python rust/scripts/windows_sample_process.py usb --root <raw> --hdc-root <raw c1>
   --hdc-root <raw c2> --out <scratch>/usb`. The USB output feeds the run record and
   TASK-XPA-004. It is not a registered fixture.
3. `python rust/scripts/windows_sample_process.py render --hdc … --usb … --date <date> --out …`
   writes the two run records next to the cribs.
4. Every `TBD(sample)` in `design.md`, `drafts/windows-probes.yaml` and
   `drafts/profile-windows-section.md` is filled from `summary.json`, or marked "not observed".

### Verification

- `python rust/scripts/test_windows_sample_process.py` passes.
- The script's leak scan passes for every output.
- A reviewer's own search of the new files for the board serial finds nothing.

## TASK-WHR-002 — Register the Windows registry, fixtures, profile section and lock

- Status:blocked（waits for TASK-WHR-001 and the maintainer's choice of candidate(s) and
  `supported` families）
- r2 planning note: the choice is maintainer ruling 2026-10-04. Register c2 only. The families:
  - `version`: `supported`;
  - `healthyCheckserver`: `unsupported`, never dispatched;
  - `deviceObservationSnapshot`: `supported`, with the UART exclusion;
  - `serverIdentityGeneration`: `supported`, as Windows server health.

  `drafts/windows-probes.yaml` r2 carries them. This task now waits only for TASK-WHR-001's c2
  fixtures.
- Platform:windows
- Requirements:REQ-HDC-001, REQ-HDC-002, REQ-HDC-004
- Acceptance:none changes
- Depends on:TASK-WHR-001
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: rust/tests/fixtures/hdc-windows/resources.json
    sha256: <64-hex sha256>
  ```

- Applicable failure patterns:AF-004（a registry that admits more than the samples show）
- Production reachability:not applicable（integration input; the consumers are CHG-2026-074
  TASK-XPA-004/005）
- Trusted fact sources:the TASK-WHR-001 fixtures, hash-pinned in `resources.json` and in the lock
- Allowed paths:
  - `openspec/integrations/openharmony/windows-probes.yaml`
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `rust/tests/fixtures/hdc-windows/**`
  - `rust/crates/arkdeck-provider-hdc/tests/**`（registry and fixture contract tests）
- Forbidden paths:
  - `openspec/integrations/openharmony/readonly-probes.yaml`, `device-observation-probes.yaml`,
    `supervisor-observation-probes.yaml`, `trace-probes/**` and their fixture packs（macOS
    authorities stay byte-identical）
  - `openspec/specs/**`, `openspec/constitution.md`
- Risk:medium（it opens HDC dispatch on Windows once adopted）
- Hardware required:no

### Deliverables

- `windows-probes.yaml`, from `drafts/windows-probes.yaml` with every TBD resolved and the
  `draftNotice` removed.
- The fixture pack with `resources.json`.
- The profile's Windows section, from `drafts/profile-windows-section.md`, with the profile
  version bump.
- The lock entries.
- Contract tests on Windows:
  - the registry parses;
  - the hash closure holds;
  - each registered fixture classifies as its family;
  - negative vectors: another SHA-256 (including candidate 1's `f6d6c475…d9b`), another
    endpoint, two listeners, zero-byte stdout, the `[Empty]` marker, CR in a field, an unknown
    literal, a 5-column row, a sixth column other than `hdc`, a UART row outside the sampled form,
    non-empty stderr;
  - the UART-only fixture classifies as `observedEmpty`, the connected fixture as one device, and
    the removed fixture as `observedEmpty`;
  - `checkserver` is never dispatched by any registered entry;
  - no Windows entry matches a macOS tuple, and no macOS entry matches a Windows tuple.

### Verification

- The contract tests pass on Windows, and CI's macOS and Linux lanes stay green.
- `check-sdd` passes.
- The macOS registries' bytes are unchanged (`git diff --stat` shows none of them).

## TASK-WHR-003 — Windows USB relation census fields

- Status:blocked（waits for TASK-WHR-001's USB facts）
- Platform:windows
- Requirements:REQ-DEV-001, REQ-DEV-003
- Acceptance:none changes
- Depends on:TASK-WHR-001
- Readiness input pins（非载体示例）:

  ```yaml pin-example
  - path: openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-004/dayu200-usb-properties-20261004-run.md
    blob: <40-hex git OID>
  ```

- Applicable failure patterns:AF-010（an identity built from a port-derived suffix）
- Production reachability:the Windows census `arkdeck_platform::usb_host_devices` →
  `UsbRegistryRelations::system()` → the Target observation owner（CHG-2026-074 TASK-XPA-004
  implements it; this task fixes which fields it may use）
- Trusted fact sources:the PnP properties the DAYU200 sample shows, read by the Runtime's own
  census, never supplied by a caller
- Allowed paths:
  - `openspec/changes/chg-2026-078-windows-hdc-registration/design.md`
  - `openspec/platforms/windows/profile.md`（the USB census mapping row）
- Forbidden paths:
  - `rust/**`（the census code is CHG-2026-074 TASK-XPA-004）
- Risk:low
- Hardware required:no

### Deliverables

- `design.md` §4 filled from the sample. r2 has done this from the 2026-10-04 USB record and
  maintainer ruling 2026-10-04, items 4 and 5.
- In the Windows profile's USB census mapping row:
  - present-only nodes;
  - the ASCII-lowercase fold of the instance-ID serial before comparing it with the connect key;
  - device identity = the folded serial;
  - attachment = (instance ID, `LastArrivalDate`);
  - topology valid only within one attachment;
  - the fail-closed rule for a port-derived suffix.

### Verification

- The mapping cites the sanitized run record for every field.
- A port-derived suffix yields no identity in the TASK-XPA-004 census tests.
- In the TASK-XPA-004 census tests:
  - an upper-case serial suffix relates to a lower-case connect key;
  - a phantom node is never an entry;
  - a new `LastArrivalDate` is a new attachment.
