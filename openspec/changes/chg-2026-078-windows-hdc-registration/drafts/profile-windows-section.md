<!-- DRAFT of CHG-2026-078: the section TASK-WHR-002 adds to
openspec/integrations/openharmony/profile.md, with every TBD filled from the processed samples.
It is not part of the profile until then. -->

## Windows HDC registry (CHG-2026-078 / TASK-WHR-002, TBD date)

`OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0` is registered in
`openspec/integrations/openharmony/windows-probes.yaml` (SHA-256 `TBD`). Its resource manifest
is `rust/tests/fixtures/hdc-windows/resources.json` (SHA-256 `TBD`). Profile
`OPENHARMONY-TOOLS@TBD`, lock `INTEGRATION-PROFILES-TBD`.

**Tool identity (read first).** A Windows tuple is the `hdc.exe` executable SHA-256 plus the
`hdc -v` stdout bytes observed with it.

| Candidate | Source | SHA-256 | `-v` bytes | Registered |
| --- | --- | --- | --- | --- |
| c1 | hand-placed tools directory | `f6d6c47551d976f33b0f22b17a74f345c0788e59131873aa5f75d356f5141d9b` | TBD(sample) | TBD(maintainer) |
| c2 | DevEco Studio 26.0.0.43 toolchains (MotW) | `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e` | TBD(sample) | TBD(maintainer) |

Path, file version, timestamp and signature are not identity:

- the only version resource is the bundled winpthread's;
- the timestamp is normalised;
- both builds are unsigned.

These are not the macOS 3.2.0d or 3.2.0f tools. No macOS entry, fixture, endpoint or fact
applies to Windows, or the other way round, even when the version text matches.

| Family | Windows conclusion (as sampled) | Differences from macOS, stated as found |
| --- | --- | --- |
| `version` | TBD(sample) | TBD(sample): terminator |
| `healthyCheckserver` | TBD(sample) | TBD(sample): whether it starts a server |
| `deviceObservationSnapshot` | TBD(sample) | TBD(sample): `[Empty]` terminator, row terminator, literals, removal behaviour |
| `serverIdentityGeneration` | TBD(sample) | TBD(sample): listening address, which command starts the server |

The registered Windows fixtures are the maintainer's capture of TBD(date), redacted by
`rust/scripts/windows_sample_process.py`:

- connect keys are same-length `a` runs;
- no hash of key-bearing bytes is kept;
- user paths are relative, and account and machine names are removed.

The run records are CHG-2026-074 `evidence/runs/TASK-XPA-002/hdc-windows-sample-TBD-run.md`
and `evidence/runs/TASK-XPA-004/dayu200-usb-properties-TBD-run.md`.

This registration publishes integration input only:

- no consumer is wired;
- no Core, platform-conformance, hardware, support or release status changes;
- the Windows daemon adopts the registry in CHG-2026-074 TASK-XPA-004/005.
