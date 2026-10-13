# Windows GJ-1/2/3 actual-device acceptance — 2026-10-13

Tasks: `TASK-XPA-006`, `TASK-XPA-008`, `TASK-XPA-009`, `TASK-XPA-022`.

The unchanged `gj_record` judge reports `REAL_DEVICE_PASS` for GJ-1
(88/88 criteria), GJ-2 (70/70) and GJ-3 (54/54) on the current protected-main
Catalog. The actual signed Windows CLI and account Runtime ran every device
operation. No fixture transport, simulation, candidate Runtime or manually
written PASS supplied these results.

The generated records are copied byte-for-byte from the official assembler:

- [GJ-1 record](../../../../../../docs/design/references/v1.6-goal/gj-headless-rerun-2026-10-13-windows-gj1.json), SHA-256 `9418ffb7a469ed1a424f16e6a20860a5ccef202ee8268a2467e801948270dc5b`.
- [GJ-2/3 record](../../../../../../docs/design/references/v1.6-goal/gj-headless-rerun-2026-10-13-windows-gj23.json), SHA-256 `53c0291385ffda745cc17c8999eb9fda7a836d6f905c93aca132817be7f6ceae`.

## Source and package

| Identity | Observed value |
| --- | --- |
| Protected-main source | `caec3e7f77a9bfd3c2f15e39e9716385987ae568` |
| Catalog | `e4e8a47cc4e9f6f099c9f4c47ef701fc928c20103cc42a23a46e887f624ab5f7` |
| Clean development RC ZIP | `227053c56cf9549036c257416ccf08ba2d9e63f0db23ea223e793b11da9657b7` |
| Runtime executable | `237caeff03302c51d021677d9ef2e8e5af859dbdd6c1139c8c8c47f04e477fc0` |
| CLI executable | `886a3f273a8c930d46997a59cc3636567a4612621399972e4a0c3d17201ec995` |
| Registered HDC | `3.2.0g`, `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e` |

The package producer ran from the clean protected-main tree with the existing
host-trusted development signer and `-SkipMsix`. This is development xcopy
qualification, not production signing or MSIX update acceptance. Runtime state
remained in the existing account root. The user closed the external SDK HDC
server before the Runtime started its own managed server; the Agent did not
stop or adopt an external/unknown server.

## Actual behavior

| Leg | Result |
| --- | --- |
| GJ-1 observe | `job-442648508cbe213f0ce9a5a5a158a1cd` succeeded; three published Artifacts, 1,188 bytes, read whole and hash-checked |
| GJ-1 diagnostics | `job-bdc52eb96973da2294b9176f09a71a3f` succeeded; six published Artifacts, 774,464 bytes; eight empty missing declarations retained honestly |
| GJ-1 restart | Typed service restart succeeded; both Jobs and all published bytes were read again |
| GJ-1 HAR | Physical unplug yielded `humanActionRequired`, exit 75, zero dispatch; reconnect resumed only a reference recovered from fresh status/action reads; action became `resolvedByFreshProbe` |
| GJ-1 resumed observe | `job-11b3df897abbe83030ac5e0ae1c8ecaa` succeeded; three Artifacts, 1,188 bytes; same target and binding revision |
| GJ-2 debug | `job-2862d3e21751eb88666b7eec246af0a2` succeeded; install/package/process readbacks, stop and staging cleanup verified; three Artifacts, 811,266 bytes |
| GJ-2 retained preflight | The exact same HAP ran with `retain`/`running` in `job-f235e0d6d539e752b1349ff01f0d3ac2`; three Artifacts, 784,463 bytes |
| GJ-2 capture | `job-c39bdd88911ed92fbe51c4ad57e19de7` succeeded; app-scoped HiLog, UI Dump and `ohos` Trace complete; eight published Artifacts, 829,340 bytes |
| GJ-2 durability | A second typed restart succeeded; all three Jobs and their complete published bytes remained readable and digest-equal |
| GJ-3 forward | `job-c1010a6f98db4ce8a8b970c6aa8bd9ba` succeeded; atomic publication, restart and `hashProcessAndMaps` verified; two reports, 1,487 bytes |
| GJ-3 rollback | `job-1aaaf70175ad4ea335341910e9b286f4` reached post-publication loader failure; Runtime restored the previous whole hash and process; one published report, 788 bytes; zero residue and known outcome |

The accepted paired baseline supplies the HAP and both signed ARMv7 libraries.
The rollback Job is intentionally `failed`; its CLI result exits 2 and retains
`artifactIntegrityFailed` because successful verification was not published.
The unmodified recorder checks the restored library/process and rollback
timeline rather than interpreting the failing Job as a successful deployment.

Raw captures stay outside Git under `D:/temp/arkdeck-windows-acceptance-20261013/`.
`raw/` retains every original call, including a local import basename rejection
(exit 64, no device dispatch). That refusal produced plain-text stderr and
empty stdout, which the recorder correctly refuses as a JSON evidence envelope.
No raw bytes or journal entries were removed or rewritten. GJ-1 was assembled
before that refusal. GJ-2/3 were assembled from fresh `agent status`, `job show`,
`job result`, fixture inspection and complete Artifact reads in
`raw-continuation/`, using the same settled execution and Job IDs; no device
operation was replayed to obtain those records.

## Windows App

`InstalledRcTests.TheInstalledAppConnectsToTheDaemonTheCliStarted` passed 1/1
with zero skips against this signed RC and the real account Runtime. It verifies
the native App's real doctor/protocol presentation, enabled actions and absence
of a recovery banner or test transport. This test does not establish all App
workflows, audible Narrator behavior, MSIX packaging or App Installer updates.

The same 365-file RC was then staged and checked whole against its manifest,
promoted to the existing per-user xcopy installation, and checked again. The
previous App directory and launcher were retained as rollback copies. The
Windows `runtime service uninstall` leaf drained/stopped the old serving
instance while explicitly preserving its files, registration and state; the
installed CLI then started the identical signed bytes from the final path.
The launcher now selects the bundled analyzer and registered HDC. Health and
service status succeeded, the retained Job list remained readable, and the
real installed App smoke again passed 1/1 with zero skips. This is a local
xcopy upgrade, not an App Installer/MSIX update or a clean-host result.

## Native Windows observations

The repository's `windows_spk3` native executable, SHA-256
`95ba5316f85f2f80e56164bc6a92cd33eaf2d4122106f99e4a6b512b08566eaf`,
was built from the unchanged current platform source. Its actual Windows
results verified argv/environment roundtrip, output/timeout refusal, native
pipe PID agreement and the current daemon's signed identity. An isolated
same-account wrong-image server was refused with zero frames sent and zero
bytes received; binding its already-held pipe was also refused. The real
Runtime's instance was unchanged across the read-only observations.

The original native outputs are in `native-probes/` and the bracketing
published service reads in `raw-native-cli/` under the same local output root.
The existing direct-start SPK-3 orchestration was not used for its outdated
endpoint/HDC-hash configuration: the probes observed the already authenticated
current Runtime and used a separate owned pipe only for the negative case.
These are host transport observations, not a whole-platform support claim.

## Local targeted checks

- `windows/scripts/package-rc.ps1 -SigningMode development -SkipMsix`: exit 0;
  clean Rust release and WinUI/.NET publish. Log:
  `D:/temp/arkdeck-windows-acceptance-20261013/package.log`.
- `python -m gj_record assemble` for GJ-1, then GJ-2/GJ-3: exit 0;
  212 holding criteria, no failing criterion. Original CLI command arrays,
  exit codes, image hashes and byte readbacks remain in the two local journals.
- `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj -c Release --no-restore -p:Platform=x64 --filter FullyQualifiedName~InstalledRcTests`:
  exit 0, 1/1 passed. Log `D:/temp/arkdeck-windows-acceptance-20261013/uia-installed.log`;
  TRX `D:/temp/arkdeck-windows-acceptance-20261013/uia/installed-current-main.trx`.
- The same UIA command after xcopy promotion: exit 0, 1/1 passed, zero skips.
  Log `D:/temp/arkdeck-windows-acceptance-20261013/uia-promoted.log`;
  TRX `D:/temp/arkdeck-windows-acceptance-20261013/uia-promoted/promoted-current-main.trx`.
- `cargo build --release -p arkdeck-platform --example windows_spk3`: exit 0
  (17.87 seconds), using the phase-A guide's command, two build jobs and the
  same fixed target already used by this chat's RC producer. Log
  `D:/src/ArkDeck-wt/tools/windows-spk3-native-build-20261013.log`.
  Native probe orchestration: exit 0; all exercised conditions above held.
- `sh scripts/check-sdd.sh`: exit 0, zero errors/warnings and 121 acceptance
  IDs, using the installed Git shell after its sandboxed launch failed before
  startup. Log `D:/src/ArkDeck-wt/tools/windows-acceptance-sdd-20261013.log`.
- `git diff --check`: exit 0. No runtime source, contract, Catalog or App
  implementation changed in this delivery, so no broad Rust/Swift/CI gate was
  run locally.

## CI

The installed source is protected-main PR #2631. Its implementation checks
passed in Swift CI run `37771712012` and SDD Guard run `37771711746`; these are
implementation checks, not proof of this later device acceptance.
The documentation PR and its own CI are pending.

## Remaining acceptance

GJ-5's supplied crash fixture, fixed patch, source scope and build/test presets
are present. Its current signing preset is unresolved because the existing
credential remains bound to the previous daemon image. The existing published
maintenance path has been prepared; specific user authorization for that
persistent credential/preset change is pending. The affected operation has not
been attempted, and no credential store was edited directly.

GJ-4 still lacks the matched Windows ArkForge release Bundle and AF-W1 run.
The trusted Windows ArkTrace distribution, MSIX signing/feed and production
signing prerequisites are also absent. No flash, certificate/trust change,
performance-baseline adoption or platform conformance promotion is claimed.
CLI/App feature census counts are unchanged by these acceptance records.

The initial native SPK-3 probe build through
`run-cargo.py build --release -p arkdeck-platform --example windows_spk3`
refused the existing package-build cache because it lacked the runner's
ownership marker (exit 1; `D:/src/ArkDeck-wt/tools/windows-spk3-build-20261013.log`).
The guide's direct build reused that same producer target; no marker was
invented and no new cache was created. Cross-account, elevation, remote-host
and packaged-client rows still need their separate host/identity prerequisites;
none is inferred from the GJ, native same-user observations or App smoke.
