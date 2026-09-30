# TASK-XPA-022 — Windows xcopy package of the daemon and CLI, 2026-09-30

- Task: TASK-XPA-022, software part of Windows-phase exit condition 7 (WM6: "MSIX 与 xcopy 的构建脚本、签名接入点、App Installer 更新源、卸载路径"). This slice covers only the **xcopy form of
  the daemon and CLI** (r12 decision 10: for CI and headless use). The MSIX, the App Installer feed
  and maintainer ruling 8 (MSIX write virtualization off) are outside this slice.
- Base: protected `main` at `5a880439` (#2348). The package below was built from the slice's
  implementation commit `b1944716`, a clean checkout. The PR head adds only this record on top of
  it. The same run on the pre-rebase commit `c341cb3d` (base `04543110`) gave byte-identical
  signed executables.
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), `rustc 1.98.1 (48a229cea
  2026-09-01)`, `cargo 1.98.1 (797e8a9bc 2026-08-05)`, PowerShell 7, non-elevated. Nothing was
  installed or elevated, and no certificate store was changed: the existing host-trusted
  development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT` in `HKCU\Environment`) was used. The only
  processes signalled were the daemons this run started.

This is host evidence for the build, signing and smoke steps. It is not a clean-host result, not
installation-identity evidence (a development signer is not an installation identity, design §L.1
item 22), and not Windows platform acceptance.

## What was delivered

- `rust/scripts/windows-package-xcopy.ps1`, with `#requires -Version 7.2`, `Set-StrictMode
  -Version Latest` and `ErrorActionPreference Stop`. Its build mode does the following:
  - It refuses an existing output directory. It refuses a dirty checkout unless `-AllowDirty`,
    which the manifest records with the entries found. A production package always requires a
    clean checkout.
  - It runs `cargo build --release --locked -p arkdeck-agentd -p arkdeck-cli --target
    x86_64-pc-windows-msvc` and stages `arkdeck.exe` and `arkdeck-agentd.exe` side by side.
  - It signs both files (`-SigningMode none|development|production`). Each signed file must then
    pass `Get-AuthenticodeSignature` as `Valid`, and both must carry one signer. A production
    signature must also be timestamped.
  - It writes `manifest.json` (`arkdeck.windows-xcopy-package/1`) inside the package and beside
    the zip, where it adds the zip's SHA-256. It prints the pin for `ARKDECK_DAEMON_SIGNER_SHA256`.
- The smoke (`-Smoke`, or `-SmokeZip` alone) unpacks the zip into a new directory. It checks the
  files against the manifest and the daemon's signer against the pin. It runs `doctor` with a
  private owner-only development state root. If the CLI starts the daemon, the smoke uses that
  daemon, and it must be the unpacked image. Otherwise the smoke starts the daemon itself and waits
  for its `listening on` line. It then runs `runtime service verify` and stops the daemon through
  its stop event. It waits for the daemon's exit and its `arkdeck-agentd stopped` line, then
  removes the directory. It does not use sleeps for synchronisation.
- `rust/README.md` gains the section "Windows xcopy package (TASK-XPA-022)". It covers use,
  signing modes, the manifest, the smoke, and the uninstall path: deleting the directory. The
  daemon's state stays after that.

## Build, development signing and smoke (this host)

Command (clean worktree at `b1944716`, `CARGO_TARGET_DIR=D:\cargo-target\p1-xcopy`,
`CARGO_BUILD_JOBS=3`):

```powershell
pwsh -NoProfile -NonInteractive -File rust/scripts/windows-package-xcopy.ps1 `
  -OutputDirectory D:\temp\p1-xcopy-final -SigningMode development -Smoke -SmokeParent D:\temp
```

The first release build in this target directory took 1 min 12 s. The recorded run reused that
target directory, which cargo's fingerprints keep correct: the `rust/` tree did not change between
the two revisions.

| Item | Value |
| --- | --- |
| `sourceRevision` / `dirty` | `b194471625eea825412e5125f3952419d5ae38d5` / `false` |
| Target / profile | `x86_64-pc-windows-msvc` / `release` (`--locked`) |
| `arkdeck.exe` (signed) | 4 477 792 bytes, `959be2477ce876577e334697123d2abb91d63979ef3a828bd205426d046cf707` |
| `arkdeck-agentd.exe` (signed) | 1 774 944 bytes, `a52381048d37a7261701d42f9b17b873a35d7e7bdf432ba0316ffce0fa33dae4` |
| Zip | `arkdeck-0.1.0-windows-x64-b194471625ee.zip`, 1 788 649 bytes, `cad7a9fcb54ad6099093d2d747b7d8ca2d056ad0fa216394345d74a53448e505` |
| Signing | `development`, `CN=ArkDeck Development Daemon (host-trusted only)`, not timestamped, `Get-AuthenticodeSignature` `Valid` on both files |
| Signer pin (`ARKDECK_DAEMON_SIGNER_SHA256`) | `a63546a589349bcf3d5e9dc7f68a44617a0313ee158dc5c632c8e318d8730191` |

Smoke result: **PASS**.

| Step | Result |
| --- | --- |
| Unpack and check | The files matched the manifest. The daemon's signer matched the pin. |
| `doctor` (first) | Exit 69, `runtimeUnavailable` (`connect failed: errno 2`). `main`'s CLI does not start its daemon yet (#2344 is open), so nothing was running. |
| Daemon start | The smoke started it: PID 5948. It printed `state root …\state` and `listening on \\.\pipe\arkdeck-agentd-dev-<logon SID>-<root id>`. |
| `doctor` (on the root's pipe) | Exit 0, `ok: true`. The CLI verified the sibling daemon's image path and signer pin before sending. `overall: blocked`, `ready: false` as expected (no HDC, no provider, no stores). Catalog digest `508783ac…`. |
| `runtime service verify` | Recorded as unavailable: exit 69, `unsupportedOnPlatform` ("the runtime service is the macOS user-domain LaunchAgent"). This is `main` before #2344. |
| Stop | The smoke set `Local\ArkDeck.Agentd.Dev.<user SID>.<root id>.Stop.5948`. The daemon printed `arkdeck-agentd stopped` and exited 0 (a complete drain). |
| Cleanup | The directory was removed. Afterwards no `arkdeck-agentd.exe` process was running. |

### Client-start cross-check against PR #2344 (not merged)

I also ran the same script at the #2344 head `976af3ba` in a scratch detached worktree, with the
script copied in. That build used `-AllowDirty`, and the manifest recorded `dirty: true` with `??
rust/scripts/windows-package-xcopy.ps1`. I then ran `-SmokeZip` on its zip
(`378e05e5…`).

| Step | Result |
| --- | --- |
| Daemon start | The first `doctor` started the daemon itself (decision 11): exit 0, `ok: true`. The smoke checked that the started process runs the unpacked `arkdeck-agentd.exe`. |
| `runtime service verify` | Exit 0, `runtimeVerified: true`: `daemonImage.verified: true` with the signer pin, `startMode: clientStarted`, `identityVerified: true`. The state root was `ownerOnly: true` with no `accessFindings`, because the smoke creates it owner-only. |
| Stop and cleanup | Stopped through the stop event, exited within the deadline. The directory was removed. |

In an earlier try the smoke's root inherited `D:\temp`'s ACL, and #2344's `verify` listed the
Administrators, Authenticated Users and Users grants as `accessFindings`. The smoke now creates
its root with a protected DACL of the user and SYSTEM.

## Fail-closed checks (this host)

| Case | Outcome |
| --- | --- |
| Dirty checkout without `-AllowDirty` | Refused before building, listing `?? rust/scripts/windows-package-xcopy.ps1` |
| `-SigningMode production` with no command | Refused before building ("Production signing is not configured … Nothing was built or signed.") |
| Production command that signs nothing | `arkdeck.exe does not carry a valid Authenticode signature`. The partial output directory was removed. |
| Production command that signs without a timestamp (stand-in: the development signer) | `signed without a timestamp; a production signature must be timestamped`. The output was removed. |
| `-ExpectedSignerSha256` not matching | `The files carry signer a635…, not the expected 0000…`. The output was removed. |
| Existing output directory | Refused |
| `-SigningMode none` then smoke | The package was built. The smoke refused it: "unsigned; the CLI refuses an unsigned daemon". |

## Local checks

- The pwsh 7 parser (`System.Management.Automation.Language.Parser::ParseFile`) found 0 errors.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh` and `git diff --check`: see the PR.
- CI: to be recorded / not verified.

## What remains for the maintainer

1. **Production signing credentials and command.** Supply the signing command, for example a
   wrapper around `signtool sign /fd SHA256 /tr <timestamp URL> /td SHA256 /dlib <Azure Artifact
   Signing dlib> /dmdf <metadata.json> <file>`. Then run `-SigningMode production
   -ProductionSignCommand <wrapper>` from a clean checkout. The script holds no credential and
   has not been run with one.
2. **The pin with Artifact Signing.** Azure Artifact Signing issues short-lived leaf
   certificates, so the signer certificate's SHA-256 changes between signings. The CLI's
   `ARKDECK_DAEMON_SIGNER_SHA256` must then be taken from each package's manifest, not configured
   once. The alternative is for the maintainer to rule on a different installation identity for
   the xcopy form (design §F.2, XPA-AC-6). This is a decision for XPA-022's production part, and
   nothing here changes it.
3. **Clean-host smoke.** Run `-SmokeZip <zip>` on a clean Windows 11 x64 host with a production
   signed package. A development signed package passes `Get-AuthenticodeSignature` only on a host
   that trusts the development certificate.
4. **After #2344 merges**, rerun the smoke on `main`. The client-start and `runtime service
   verify` path is expected to pass there as in the cross-check above.
5. The rest of XPA-022 is outside this slice: the MSIX (ruling 8, ruling 12 publisher), the App
   Installer feed, the clean-host TRUST matrix, and the traceability and lock-file flips.
