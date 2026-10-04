<!-- DRAFT of CHG-2026-078 r2: the section TASK-WHR-002 adds to
openspec/integrations/openharmony/profile.md. The sample values come from the 2026-10-04 samples
(CHG-2026-074 evidence, #2456), and the decisions from maintainer ruling 2026-10-04. Only the
registry/manifest SHA-256s, the profile/lock versions and the date are left for registration
time. It is not part of the profile until then. -->

## Windows HDC registry (CHG-2026-078 / TASK-WHR-002, <registration date>)

`OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0` is registered in
`openspec/integrations/openharmony/windows-probes.yaml` (SHA-256 `<at registration>`). Its resource
manifest is `rust/tests/fixtures/hdc-windows/resources.json` (SHA-256 `<at registration>`).
Profile `OPENHARMONY-TOOLS@0.7.0`, lock `INTEGRATION-PROFILES-<at registration>`.

**Tool identity (read first).** A Windows tuple is the `hdc.exe` executable SHA-256 plus the
`hdc -v` stdout bytes observed with it.

| Candidate | Source | SHA-256 | `-v` bytes | Registered |
| --- | --- | --- | --- | --- |
| c1 | hand-placed tools directory | `f6d6c47551d976f33b0f22b17a74f345c0788e59131873aa5f75d356f5141d9b` | `Ver: 3.2.0b` CR LF | **no** (maintainer ruling 2026-10-04) |
| c2 | DevEco Studio 26.0.0.43 toolchains (MotW `ZoneId=3`) | `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e` | `Ver: 3.2.0g` CR LF | **yes** |

Path, file version, timestamp and signature are not identity:

- the only version resource is the bundled winpthread's;
- the timestamp is normalised;
- both builds are unsigned.

Tool selection must resolve to the registered DevEco executable. Any other `hdc.exe` is
`unsupported`, including one found first on `PATH`, and so is a DevEco update with a new hash
until it is registered.

These are not the macOS 3.2.0d or 3.2.0f tools. No macOS entry, fixture, endpoint or fact
applies to Windows, or the other way round, even when the version text matches.

| Family | Windows conclusion (as sampled) | Differences from macOS, stated as found |
| --- | --- | --- |
| `version` | `supported`: `Ver: 3.2.0g` CR LF (13 B), stderr empty, exit 0, starts no server | the terminator is CR LF (macOS golden: LF) |
| `healthyCheckserver` | `unsupported`; never dispatched. Server health is `serverIdentityGeneration` | with no server, `checkserver` **starts one**, then prints the healthy form (CR LF, 56 B) |
| `deviceObservationSnapshot` | `supported`, existing server on `127.0.0.1:8710` only. 6 TAB columns, CR LF rows. Only `USB` rows are devices (`Connected`/`Offline`, hostTag `localhost`, sixth column `hdc`). The sampled `COM<n>`/`UART`/`Ready`/`unknown...`/`hdc` rows are excluded non-device rows, so UART rows alone mean no device. Any other form is `unknown` | 6 columns, not 5; CR LF rows, not LF; UART rows in every phase; `[Empty]` never emitted, so it is `unknown` on Windows, as is zero-byte stdout. Unchanged: the removed row is kept and flipped to `Offline` |
| `serverIdentityGeneration` | `supported`: exactly one listener on `127.0.0.1:8710`, owned by the registered hash, with a stable PID and creation time | per-command brackets exist (closing `DEV-1` for this tuple); the server is started by `checkserver`, never by `-v` |

The registered Windows fixtures are the capture of 2026-10-04, redacted by
`rust/scripts/windows_sample_process.py`:

- connect keys are same-length `a` runs, and `COM<n>` port names are kept;
- no hash of key-bearing bytes is kept;
- user paths are relative, and account and machine names are removed.

The run records are CHG-2026-074 `evidence/runs/TASK-XPA-002/hdc-windows-sample-20261004-run.md`
and `evidence/runs/TASK-XPA-004/dayu200-usb-properties-20261004-run.md`.

This registration publishes integration input only:

- no consumer is wired;
- no Core, platform-conformance, hardware, support or release status changes;
- the Windows daemon adopts the registry in CHG-2026-074 TASK-XPA-004/005.
