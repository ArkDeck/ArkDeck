# TASK-XPA-022 — Windows x64 release candidate of the App, daemon and CLI, 2026-09-30

- **Task.** TASK-XPA-022, software part of Windows-phase exit condition 7. This slice follows on
  from the xcopy package of the daemon and CLI (#2349, `xcopy-package-run.md`) and adds the
  WinUI App, the MSIX form and a CI artifact.
- **Rulings applied.**
  - r12 decision 10: App as MSIX with self-contained Windows App SDK; daemon and CLI also as xcopy.
  - Ruling 8: the MSIX turns write virtualization off.
  - Ruling 12: the development MSIX publisher is `CN=ArkDeck Development`.
  - Ruling 17: the xcopy daemon is pinned by publisher identity in production and by
    certificate hash in development.
  - r13: Windows 11 x64 only.
- **Base.** Protected `main` at `80184b64` (#2367). The package below was built by the slice's
  commit `4a7ed2d3` from a clean checkout (`dirty: false`). The PR head adds only this record
  and the manifest on top of it.
- **Host.** The Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), non-elevated.
  Toolchain: rustc/cargo 1.98.1, .NET SDK 10.0.401, Windows App SDK 2.5.1, PowerShell 7.
  - Nothing was installed or elevated.
  - No certificate store and no system setting was changed. The host's existing development
    signer was used (`CN=ArkDeck Development Daemon (host-trusted only)`, created before this
    slice).
  - No MSIX was registered or installed.
  - The only processes started were the installed CLI, the daemon it started, the installed App
    and the UIA test host.

This is host evidence for the build, signing and smoke steps. It is not a clean-host result,
not installation-identity evidence (a development signer is not an installation identity,
design §L.1 item 22), and not Windows platform acceptance.

## What was delivered

- **`windows/scripts/package-rc.ps1`** (PowerShell 7, strict mode). Its build mode does five
  things.
  1. It refuses an existing output directory. It refuses a dirty checkout unless
     `-AllowDirty`, which is recorded in the manifest.
  2. It builds and signs the daemon and CLI through `rust/scripts/windows-package-xcopy.ps1`,
     reusing that script's release build, signer checks, manifest and zip.
  3. It publishes the App unpackaged (`WindowsPackageType=None`). The App is self-contained
     (Windows App SDK and .NET), ReadyToRun and trimmed. `ArkDeck.exe` is signed like the
     runtime, and its signer must equal the runtime's.
  4. It stages the **xcopy form** `arkdeck-rc-<version>-windows-x64-<revision>\`:
     - the App and `arkdeck-agentd.exe` at the root, which is the App's default daemon;
     - the CLI in `bin\` (see decision 1 below).
     It then writes `rc-manifest.json` (`arkdeck.windows-rc-package/1`), zips the directory,
     and writes the manifest again beside the zip with the zip's SHA-256.
  5. It builds the **MSIX form** with the same layout.
     - The MSIX holds the signed daemon at the root and the CLI in `bin\`; the script checks
       both byte-for-byte against the runtime build.
     - Identity is `ArkDeck.Development` / `CN=ArkDeck Development`.
     - `desktop6:FileSystemWriteVirtualization` and `RegistryWriteVirtualization` are
       `disabled`, with `rescap:unvirtualizedResources`.
     - The MSIX is **unsigned**. Its SHA-256 goes into the manifest.
- **Signing modes.** `-SigningMode none` is for CI; `development` uses the host-trusted
  development signer. A production RC is refused by construction: the script has no production
  mode (see the maintainer items).
- **Smoke.** `-Smoke` after a build, or `-SmokeZip <zip>` on its own:
  - installs into `<LocalAppData>\arkdeck-rc-smoke-<guid>`, which is owner-only (the user and
    SYSTEM, protected), with a private development state root inside;
  - checks every file against the manifest, and the signers of `ArkDeck.exe`,
    `bin\arkdeck.exe` and `arkdeck-agentd.exe` against the pin;
  - runs `arkdeck --output json doctor`, which starts the installed daemon (decision 11). The
    started process must run the installed image, and doctor must answer `ok: true`;
  - runs the App UIA smoke `windows/App.UITests` `InstalledRcTests`. The installed
    `ArkDeck.exe`, given only the endpoint and the pin, connects to that daemon. It shows the
    doctor report and protocol 1.0.0, no recovery banner, and no disabled button. The outcome is
    read from the TRX: exactly 1 test, passed;
  - runs doctor again;
  - stops the daemon through its stop event and waits for it to exit;
  - uninstalls by removing the directory, then checks that no process runs from it, that no new
    entry appeared in the local application data, and that `%LOCALAPPDATA%\ArkDeck` is
    unchanged;
  - never sleeps to synchronise.
- **App project.** `windows/App/Package.appxmanifest` now carries ruling 8 (write
  virtualization off, `unvirtualizedResources`). `ArkDeck.App.csproj` adds the daemon and the
  CLI as package content only when the script passes `ArkDeckRuntimeDirectory`; a plain build
  carries neither.
- **CI.** New workflow `.github/workflows/windows-rc.yml`.
  - It runs on push to `main` (paths `rust/**`, `windows/**`, the release version, the workflow
    itself) and on demand. It has no pull-request trigger.
  - It uses `windows-latest`, `setup-dotnet` from `windows/global.json`, and the workspace
    toolchain.
  - It runs `cargo fetch --locked --target x86_64-pc-windows-msvc` **anonymously**, then
    `package-rc.ps1 -SigningMode none`.
  - It uploads `arkdeck-windows-rc-<sha>`: the zip, the MSIX, `rc-manifest.json` and the
    runtime manifest.
  - It uses no secret and only the read token. It is not part of the required `swift`
    aggregate.
- **Docs.** `windows/README.md` gains the section "Release candidate package". `rust/README.md`'s
  xcopy section points to it.

## Decisions (delegated minor choices; the maintainer may overrule)

1. **CLI in `bin\`.** NTFS names are case-insensitive, so `arkdeck.exe` (the CLI) and
   `ArkDeck.exe` (the App, the MSIX `Executable`) cannot share a directory. The App keeps its
   daemon beside it (its default). The CLI goes to `bin\` and is configured with
   `ARKDECK_DAEMON_PATH=<install>\arkdeck-agentd.exe` beside the pin it needs anyway. Both
   clients then pin the one daemon image. The first build attempt failed on exactly this
   collision.
2. **The xcopy form carries the App unpackaged**, so the whole product runs from one directory
   with no package registration. That is what the private-root smoke installs. The MSIX is the
   decision-10 form of the App. The two forms carry the same bits (the App built twice from one
   checkout, and the same signed daemon and CLI).
3. **The MSIX carries the CLI** in `bin\` for parity, although ruling 8 expects the CLI
   outside the package (an xcopy CLI sharing the unvirtualized state). Exposing it on PATH (an
   App Execution Alias) is not done here.

## Build, development signing and smoke (this host)

Command, clean worktree at `4a7ed2d3`:

```powershell
pwsh windows/scripts/package-rc.ps1 -OutputDirectory D:\temp\g2-rc-final -SigningMode development -Smoke
```

`CARGO_TARGET_DIR=D:\cargo-target\g2-rc`, `NUGET_PACKAGES=D:\nuget\packages`. The run took about
3 minutes: Rust release build about 1.5 min, App publish plus MSIX about 1.5 min.

| Item | Value |
| --- | --- |
| `sourceRevision` / `dirty` | `4a7ed2d3bebc2a763dae7f772afdce36b7f683f0` / `false` |
| xcopy zip | `arkdeck-rc-0.1.0-windows-x64-4a7ed2d3bebc.zip`, 64 471 946 bytes, `1a2f0e2db4c9065729a165836de4a8265aa513eeb4047fb9fafbfd7866df9ed3` |
| xcopy directory | 346 files, 160 150 825 bytes |
| `ArkDeck.exe` (signed) | 671 584 bytes, `6ea04c78677ecceacaa1ac089f25c58c04f1cd44b813da690a222a2c6465f090` |
| `arkdeck-agentd.exe` (signed) | 2 680 672 bytes, `2cec74083a1ce031d73445c7c669e8df882e7fd00e98717de9d373334ce621bd` |
| `bin/arkdeck.exe` (signed) | 4 699 488 bytes, `ef7361b5c30aa621043d9a0518482014979dea128e1eec3871c7dd3c04756143` |
| MSIX (unsigned) | `ArkDeck.App_0.1.0.0_x64.msix`, 64 388 447 bytes (61.4 MiB; §I.2 budget ≤ 150 MB), `f0f68e442bdfb71671a4ab3acefc86099fdc779df9f04df1081047ce48a06aa7`, 354 entries, `ArkDeck.Development` / `CN=ArkDeck Development` 0.1.0.0, write virtualization disabled, daemon and CLI byte-equal to the xcopy form's |
| Runtime zip (xcopy script) | `arkdeck-0.1.0-windows-x64-4a7ed2d3bebc.zip`, `2076a85a8e4a68f4cb86af20d4440c071bbff646188e2e468934a7e18cc3e909` |
| Signer pin (development) | `a63546a589349bcf3d5e9dc7f68a44617a0313ee158dc5c632c8e318d8730191`, the same signer on all three executables |

The complete package manifest, with every file's path, size and SHA-256, is committed beside
this record as `windows-rc-manifest-4a7ed2d3bebc.json`: the `rc-manifest.json` written beside the
zip, with its CRLF line ends normalised to LF.

Smoke: **PASS**.

| Step | Result |
| --- | --- |
| Install | The zip went into `<LocalAppData>\arkdeck-rc-smoke-<guid>`, owner-only. All 346 files matched the manifest. All three executables carry the pinned signer. |
| `doctor` (first start) | Exit 0, `ok: true`. The CLI started the installed daemon over the private development root, and the started process runs the installed `arkdeck-agentd.exe`. |
| App (`InstalledRcTests`) | Passed (TRX: total 1, passed 1). The installed App connected to the CLI-started daemon, showed its doctor report and protocol 1.0.0, with no recovery banner and every button enabled. |
| `doctor` (daemon running) | Exit 0, `ok: true`. |
| Stop | The daemon's `Local\ArkDeck.Agentd.Dev.<user SID>.<root id>.Stop.<pid>` event was set, and the daemon exited within the deadline. |
| Uninstall | The directory was removed. No process was running from it, before or after. No new entry appeared in the local application data. `%LOCALAPPDATA%\ArkDeck` was unchanged (absent before and after). |

The smoke record keeps the endpoint and the stop-event name, which carry the logon and user
SIDs; it is therefore not committed.

**Observation.** In the first combined build-and-smoke run (an `-AllowDirty` development
iteration, not the recorded run), the App step failed once. `overview.doctor.overall` did not
fill within the 20 s UIA timeout on the App's first launch after a fresh publish. The test now
reports the recovery banner's reason when that happens. Five later smokes all passed, the
failing package's step included. The cause of that one failure is not established:
- the recovery reason was not captured yet;
- the host was loaded by other agents' builds at the time.

It is recorded here rather than treated as a pass. A cold first launch of the trimmed
ReadyToRun App is about 0.7 s (SPK-4), so a slow ClientKit first call under load is the likelier
cause than the package.

## Fail-closed checks

| Case | Outcome |
| --- | --- |
| `arkdeck.exe` beside `ArkDeck.exe` (the first layout) | Refused before staging: "The App's publish output already holds arkdeck.exe". This is why the CLI is in `bin\`. |
| Dirty checkout without `-AllowDirty` | Refused before building, listing the 2 untracked entries. No output directory was created. |
| `-Smoke` with `-SigningMode none` | Refused before building: the clients refuse an unsigned daemon |
| App signer different from the runtime's | Refused ("carry different signers"); not triggered here |
| MSIX lacking the daemon or CLI, or carrying other bytes | Refused; not triggered here |

## Local checks

- `dotnet build windows/ArkDeck.Windows.slnx -c Release`: 0 errors.
- `dotnet test windows/ArkDeck.Windows.slnx -c Release --no-build`:
  - App.Tests: 37 passed;
  - ClientKit.Tests: 31 passed, 1 skipped (the end-to-end test without its environment);
  - App.UITests: 20 skipped without `ARKDECK_APP_UITESTS`.
- The pwsh 7 parser found 0 errors in `package-rc.ps1`.
- `scripts/ci/test_plan.py`, `scripts/test_agent_pr_workflow.py`: OK.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`: pass. `git diff --check`: clean.
- CI: the new workflow runs only on `main` and on demand, so this PR does not exercise it. Its
  first run is after merge. Anonymous `git ls-remote` of the pinned ArkForge repository
  succeeded from this host. If the hosted runner cannot fetch it anonymously, the job fails at
  its fetch step, and giving it the existing read-only deploy key is the maintainer's call.

## Maintainer items (not done here)

1. **Production signing.**
   - Sign the daemon, CLI and App with Azure Artifact Signing
     (`rust/scripts/windows-package-xcopy.ps1 -SigningMode production -ProductionSignCommand
     …`, publisher identity per ruling 17), and extend `package-rc.ps1` with that mode once the
     command exists.
   - Sign the MSIX with the production publisher. That also changes the manifest's `Publisher`
     from `CN=ArkDeck Development` to the certificate's subject.
2. **Development MSIX signature.** Create and trust `CN=ArkDeck Development` (ruling 12, the
   SPK-4 crib), sign the MSIX, then run `Add-AppxPackage` and a packaged smoke. The package
   family pin for the MSIX daemon also needs this.
3. **App Installer feed, Store and winget** submission.
4. **Clean-host smoke** of a production-signed RC. A development-signed one verifies only on a
   host that trusts the development certificate.
5. **The CI fetch.** Decide whether `windows-rc.yml` may use the read-only ArkForge deploy key if
   the anonymous fetch fails on the hosted runner.
6. **An App Execution Alias** for the packaged CLI, if the MSIX should put `arkdeck` on PATH.
