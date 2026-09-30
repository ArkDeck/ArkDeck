# TASK-XPA-022 — App Installer feed, uninstall path, signing hooks and the clean-host runbook, 2026-09-30

- **Task.** TASK-XPA-022, the rest of the software part of WM6 exit condition 7, on top of the
  release-candidate package (#2380, `windows-rc-package-run.md`):
  - the App Installer feed generated from the same revision as the MSIX;
  - the uninstall path;
  - the signing hook points, with no credential;
  - a clean-host smoke runbook written as maintainer steps.
- **Base.** Protected `main` at `565f8b1d`, merged with `origin/main` before push.
- **Host.** The Windows 11 x64 reference host, non-elevated.
  - Nothing was installed, elevated or trusted. No certificate was created and no store changed.
    The existing development signer was used.
  - No MSIX was registered. The App Installer feed was generated with the placeholder base
    `https://example.invalid/arkdeck/windows/` and never fetched.

This is host evidence for the packaging scripts. It is not a clean-host result and not Windows
platform acceptance.

## What was delivered

### `windows/scripts/package-rc.ps1` (extended)

- **App Installer feed.** `-FeedBaseUri <https://…/>` writes `ArkDeck.appinstaller` beside the
  MSIX, using schema `http://schemas.microsoft.com/appx/appinstaller/2021`.
  - `MainPackage` takes Name, Publisher, Version and ProcessorArchitecture from the
    `AppxManifest.xml` of the MSIX this run built. The script checks that the feed names that
    package, so feed and package always come from one revision.
  - Update settings: `OnLaunch` with `HoursBetweenUpdateChecks="0"`, `ShowPrompt="true"` and
    `UpdateBlocksActivation="false"`; `ForceUpdateFromAnyVersion` false; and
    `AutomaticBackgroundTask`.
  - The feed's name, SHA-256, URIs and version go into `rc-manifest.json` under
    `msix.appInstaller`.
  - The base must be absolute `https`, end in `/` and have no query or fragment, or the script
    refuses before building.
- **Signing hooks.** No credential is held; every hook is the maintainer's command, called once
  per file with its path.
  - `-SigningMode production -ProductionSignCommand <cmd>` (or `ARKDECK_PRODUCTION_SIGN_COMMAND`):
    - the daemon and CLI go through `windows-package-xcopy.ps1 -SigningMode production`, as
      before (timestamped, one publisher identity);
    - `ArkDeck.exe` is signed by the same command, must verify with a timestamp, and must carry
      the runtime's publisher identity (ruling 17: subject `O=` and the Artifact Signing
      identity EKU);
    - a clean checkout only; an unconfigured command fails before anything is built.
  - `-MsixSignCommand <cmd>` (or `ARKDECK_MSIX_SIGN_COMMAND`), in any mode, signs the MSIX in
    place. The MSIX must then verify, and its signer's subject must equal the manifest's
    `Publisher` (Windows installs nothing else); in production mode it must also be timestamped.
    The manifest records `msix.signing` (`signed`, `installable`, signer subject and SHA-256,
    `timestamped`). An unsigned MSIX is recorded as `installable: false`.
- **Manifest.**
  - A production RC records `signing.publisher` and a `daemonConfiguration` with the two
    publisher inputs.
  - `signing.signed` now names `bin/arkdeck.exe` correctly.
  - The script notes that the App cannot pin a production daemon by publisher identity yet
    (below).
- **Shared helpers.** The signature helpers (certificate pin, publisher identity, verified
  signer, signing-command call) moved to `rust/scripts/windows-signing-common.ps1`, which
  `windows-package-xcopy.ps1` and `package-rc.ps1` both dot-source. This is a mechanical move:
  the xcopy script's behaviour is unchanged.
- **Smoke.** The uninstall step now runs `uninstall-rc.ps1`. It must report `removed: true` and
  that it stopped the installed daemon (the smoke's PID), and the daemon must have exited. The
  leftover checks are as before. `-Smoke` with production signing is refused, because the App
  lacks a publisher pin.

### `windows/scripts/uninstall-rc.ps1` (new)

- **Xcopy form** (`-InstallDirectory`, optional `-DevelopmentStateRoot`):
  - the directory must hold an `arkdeck.windows-rc-package/1` manifest, or nothing is touched;
  - the daemon is stopped through its own stop event (`Local\ArkDeck.Agentd.<SID>.Stop.<pid>`,
    or the development root's), and only when it runs the installed image;
  - any other process running from the directory (the App, a CLI) refuses the uninstall;
  - no process is ever killed;
  - then the directory is removed.
- **MSIX form** (`-PackageName`): the same stop and refusal, then `Remove-AppxPackage` for this
  user.
- **Kept, and listed:** `%LOCALAPPDATA%\ArkDeck\Agentd`, the signing preset root and its
  Credential Manager items. `arkdeck runtime signing remove` removes a credential. The answer is
  one JSON document.

### `windows/App/Controls/FocusWalk.cs` (fix)

The accessibility pass (#2383) serialized its focus stops with reflection-based
`JsonSerializer`, which the trimmed publish refuses (`IL2026`, warnings as errors).
- This broke `package-rc.ps1` and the `windows-rc.yml` workflow on `main` from #2383 on. The
  runs 36702942845 through 36716764168 failed there; #2380's own run was green.
- The stops are now built as `JsonObject`s in a `JsonArray` (`ToJsonString`), with the same
  member names and values, and `JsonArray.Add(JsonNode)` is chosen explicitly.

### `evidence/runs/TASK-XPA-022/windows-clean-host-smoke-runbook.md` (new)

Maintainer steps for a production-signed RC on a fresh Windows 11 x64 host with no development
trust:
- verifying the downloads;
- the xcopy form: install, CLI first start with the publisher inputs, the App, uninstall;
- the MSIX form through App Installer: install, first start, feed update, uninstall;
- the hand-back and the stop conditions.

It states two current limits (below) instead of hiding them. It details §5 of
`docs/design/cross-platform/windows-phase-a-runbook.md` (#2398, merged while this slice was open).
That section's `package-rc.ps1 -SmokeZip <production zip>` cannot pass today: the App has no
publisher pin. The script now refuses a production zip with that reason, rather than calling it
unsigned. The phase A runbook's §5 should point here; that edit is left to its owner.

## Delegated minor decisions (pending the next rulings batch)

1. **Feed update policy.** Check on every launch and prompt, without blocking activation, and no
   downgrade (`ForceUpdateFromAnyVersion` false). The background task is on.
2. **Package version.** The feed takes the MSIX's own version, and nothing rewrites the tracked
   `Package.appxmanifest` at build time. App Installer updates only to a higher version, so the
   maintainer raises `Identity/@Version` with each published RC; the manifest says so.
3. **The MSIX's publisher.** `CN=ArkDeck Development` stays in the tracked manifest (ruling 12). A
   production publisher subject is a reviewed manifest change once the certificate exists. The
   hook refuses any mismatch rather than rewriting the identity at build time.
4. **Uninstall keeps state.** The daemon's state and signing credentials are never removed by the
   uninstall. The answer names them, and credential removal stays the explicit
   `runtime signing remove`.

## Open points found (for the maintainer; not changed here)

- **The App has no publisher-identity pin (ruling 17).** `DaemonConfiguration` reads only
  `ARKDECK_DAEMON_SIGNER_SHA256` / `ARKDECK_DAEMON_PACKAGE_FAMILY`. A production xcopy App can be
  pinned only by the daemon's current leaf SHA-256, which lasts until the next signing. The
  clean-host runbook uses that for now. The fix is a ClientKit/App change (TASK-XPA-007/020).
- **The packaged daemon's identity is not settled.** A process has a package family only when it
  is activated with package identity. A CLI outside the package that starts
  `<InstallLocation>\arkdeck-agentd.exe` directly starts it without one, so the MSIX form's
  package-family pin cannot hold today. Options include an execution alias for the daemon, or
  the App launching it as a full-trust process. This is an XPA-022 design decision; the
  runbook expects a refusal there.
- The feed was not validated against Microsoft's App Installer XSD (none is available offline on
  this host) and never fetched. Step 7 of the runbook is its real test.

## Runs on this host

1. **Build, feed and smoke.** Development signing,
   `-FeedBaseUri https://example.invalid/arkdeck/windows/`, `-AllowDirty` (a development
   iteration, recorded dirty). `sourceRevision` is `565f8b1d…`, the base (`dirty: true`).
   - xcopy zip: 67 140 822 bytes, `588da0d4…`, 348 files.
   - MSIX: unsigned, 67 045 059 bytes, `cd0b498e…`, 356 entries, write virtualization disabled.
   - `ArkDeck.appinstaller`: 646 bytes, `10e03fd0…`. It names `ArkDeck.Development` /
     `CN=ArkDeck Development` / `0.1.0.0` / `x64` at `…/ArkDeck.App_0.1.0.0_x64.msix`.
   - `rc-manifest.json` carries `msix.signing.installable: false` and `msix.appInstaller`.
2. **Smoke** (`-SmokeZip` of that zip), after two fixes:
   - the uninstall script's empty-array unwrap;
   - `Get-TreeListing` on a directory under strict mode, since `%LOCALAPPDATA%\ArkDeck\Agentd`
     now exists on this host from other runs.

   **PASS.**
   - The first `doctor` started the installed daemon.
   - The App UIA step passed (TRX total 1, passed 1).
   - `doctor` passed again.
   - `uninstall-rc.ps1` exited 0: `removed: true`, the daemon stopped through its development
     stop event, kept `ArkDeck\Agentd: true` (pre-existing), `developmentStateRoot: true`.
   - Leftover checks: directory removed, no new LocalAppData entry, `%LOCALAPPDATA%\ArkDeck`
     unchanged, no process from the directory.
3. **Fail-closed checks** (clean tree at the slice commit):

   | Case | Outcome |
   | --- | --- |
   | `-SigningMode production` with no command | Refused before building: "Production signing is not configured…". No output directory was created. |
   | `-SigningMode production` with a stand-in command (signtool with the development certificate, no timestamp) | The runtime step refused: "arkdeck.exe is signed without a timestamp; a production signature must be timestamped". The output was removed. |
   | `-MsixSignCommand` with the same stand-in on the development MSIX | `signtool` itself refused with "An unexpected internal error". That is its usual answer to a publisher mismatch, which is expected here: `CN=ArkDeck Development` against the development certificate's subject. The command's non-zero exit failed the build and the output was removed. The script's own subject check sits behind that and is not reached with this certificate. |
   | `-SigningMode production` on a dirty checkout | Refused: "A production release candidate is built from a clean checkout only." |
   | `-FeedBaseUri http://…` (not https, no trailing `/`) | Refused before building |
   | `uninstall-rc.ps1` on a directory with no RC manifest | Refused: "… not an ArkDeck release-candidate installation, and nothing was removed". The file stayed. |

   Not exercised: the positive production and MSIX signing path (it needs the maintainer's
   certificates), and `uninstall-rc.ps1 -PackageName` (no MSIX is installed on this host).

## Local checks

- The pwsh 7 parser found 0 errors in `package-rc.ps1`, `uninstall-rc.ps1`,
  `windows-package-xcopy.ps1` and `windows-signing-common.ps1`.
- The trimmed App publish (`WindowsPackageType=None`) succeeds again with the `FocusWalk` fix.
- `dotnet build windows/ArkDeck.Windows.slnx -c Release` and `dotnet test --no-build`: see the
  commit message.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check`: pass.

## Maintainer items

1. Supply the production signing command (Artifact Signing, timestamped), the MSIX signing
   command, and a production MSIX publisher, as a reviewed change of
   `Package.appxmanifest` `Publisher`. Then run
   `package-rc.ps1 -SigningMode production … -FeedBaseUri <host>` from a clean checkout.
2. Host the feed and the MSIX, then run the clean-host runbook.
3. Decide the two open points above: the App's publisher pin, and the packaged daemon's identity.
