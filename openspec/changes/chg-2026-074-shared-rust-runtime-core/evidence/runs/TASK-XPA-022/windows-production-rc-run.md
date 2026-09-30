# TASK-XPA-022 — production mode of the release-candidate package, 2026-09-30

- **Task.** TASK-XPA-022, WM6. This closes the software gap named in §1.3 of
  `docs/design/cross-platform/windows-phase-a-runbook.md` (#2398): `package-rc.ps1` had no
  production mode that pins the publisher the clients will pin, and it could not sign the MSIX
  under the production publisher.
- **Base.** Protected `main` at `bafedd1f`.
- **Host.** The Windows 11 x64 reference host, non-elevated.
  - Nothing was installed, elevated or trusted. No certificate was created and no store changed.
    The existing development signer stood in for the maintainer's command.
  - No MSIX was registered. The feed used the placeholder base
    `https://example.invalid/arkdeck/windows/` and was never fetched.
  - No production credential exists on this host, and none was read.

This is host evidence for the packaging script. It is not a production signing run, not a
clean-host result and not Windows platform acceptance.

## What was delivered

### `windows/scripts/package-rc.ps1`

- **Expected publisher (ruling 17, #2352).**
  - `-SigningMode production` now needs the publisher identity every client pins:
    `-ExpectedPublisherOrganization` and `-ExpectedPublisherEku`, else
    `ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` and `ARKDECK_DAEMON_PUBLISHER_EKU`, the CLI's own
    installation inputs.
  - The organisation must have no outer whitespace. The EKU must match
    `1.3.6.1.4.1.311.97.<profile>` and must not be the Public Trust marker
    `1.3.6.1.4.1.311.97.1.0`.
  - The runtime is still built by `windows-package-xcopy.ps1 -SigningMode production`: a
    timestamped signature, one publisher identity, a chain to the Microsoft Identity Verification
    Root 2020. After that build, its `signing.publisher` must equal the expected organisation and
    EKU. A certificate that merely verifies is not enough.
  - `ArkDeck.exe` must carry that same identity, as before.
  - `rc-manifest.json` records `signing.expectedPublisher`.
- **MSIX under the production publisher.**
  - `-MsixPublisher "<subject>"` builds the MSIX with the signing certificate's subject as
    `Identity/@Publisher`. The subject must be an X.500 name with a `CN=`, at most 8192
    characters and with no control characters.
  - The build uses a copy of `windows/App/Package.appxmanifest` under
    `<out>\msix-manifest\`, passed as `-p:ArkDeckPackageManifest=<path>`. The tracked manifest
    is never rewritten.
  - The script checks the built package's identity publisher against `-MsixPublisher`. As
    before, the signer's subject must equal it after signing.
  - In production mode, unless `-SkipMsix`, `-MsixSignCommand` (or `ARKDECK_MSIX_SIGN_COMMAND`)
    and `-MsixPublisher` are required, and the publisher's single `O=` must be the expected
    organisation.
- **Credentials.** None are held or read. The signing commands are the maintainer's, called at
  run time once per file. Every missing input is refused before anything is built, and no
  output directory is created.

### `windows/App/ArkDeck.App.csproj`

- It gains an `AppxManifest` item, used only when `ArkDeckPackageManifest` is set.
- The MSIX tooling adds its default `Package.appxmanifest` only when `@(AppxManifest)` is empty,
  so the copy replaces it.
- Without the property, nothing changes.

### Documentation

- `windows/README.md`: the RC section names the new inputs and refusals.
- `windows-clean-host-smoke-runbook.md` (inputs): the full production command and its refusals.
- `docs/design/cross-platform/windows-phase-a-runbook.md` §1.3: the "software gap" note is
  replaced, and step 4 is now the production RC command.

## Delegated minor decisions (pending the next rulings batch)

1. **The MSIX publisher is set at build time, from a copy of the manifest.** This supersedes
   decision 3 of `windows-appinstaller-uninstall-signing-run.md`, which had a reviewed change of
   the tracked `Publisher` in mind.
   - `CN=ArkDeck Development` stays the tracked identity (ruling 12).
   - The production subject is a run-time input, like the organisation and EKU. It is tied to
     them through its `O=`.
   - Why: the certificate's subject is known only when the maintainer signs, and the lead asked
     for MSIX signing under the production publisher without anything secret in the repository.
     A subject is not secret, but it would put one certificate's identity into every
     development build.
2. **Both pins come from the maintainer, never from what was signed.** The script refuses a
   production run without them, rather than recording whatever the certificate says.
3. **A production run signs the MSIX unless `-SkipMsix`.** A production RC with an unsigned MSIX
   cannot be installed. The maintainer opts out explicitly instead.

## Runs on this host

1. **Refusals** (`-SigningMode production`, clean tree). Each was refused before any build, and
   no output directory was created:

   | Case | Refusal |
   | --- | --- |
   | no expected organisation or EKU (parameters and environment unset) | "A production release candidate needs the publisher identity the clients pin (maintainer ruling 17) … Nothing was built or signed." |
   | EKU `1.3.6.1.4.1.311.97.1.0` (the marker) | "The expected publisher identity is malformed … not the Public Trust marker … Nothing was built or signed." |
   | no `-MsixSignCommand` | "A production release candidate signs its MSIX: pass -MsixSignCommand … Nothing was built or signed." |
   | no `-MsixPublisher` | "A production MSIX is published under its signing certificate's subject … Nothing was built or signed." |
   | `-MsixPublisher` with another `O=` | "-MsixPublisher names O=…, not the expected publisher …. Nothing was built or signed." |
   | `-MsixPublisher` without `CN=` | "-MsixPublisher must be the signing certificate's subject as a distinguished name with a CN=: …" |

2. **MSIX publisher override with stand-in signing.** The run used `-SigningMode development`,
   because the development signature has no timestamp and production mode refuses it (as
   recorded in the earlier run). Its inputs were:
   - `-MsixPublisher "CN=ArkDeck Development Daemon (host-trusted only)"`, the development
     certificate's subject;
   - `-MsixSignCommand`, a scratch wrapper around `signtool sign /fd SHA256` with the existing
     development certificate and no timestamp;
   - `-FeedBaseUri https://example.invalid/arkdeck/windows/`.

   It exited 0. `sourceRevision` is `85d1b384`, the slice's working commit.
   - The runtime zip SHA-256 is `bd731fbd…`. The daemon's leaf SHA-256 is `a63546a5…`.
   - The xcopy RC zip SHA-256 is `d6edadbf…`.
   - The MSIX is 67 059 426 bytes, SHA-256 `491a381f…`, with 356 entries and write
     virtualization disabled. It has identity `ArkDeck.Development` and publisher
     `CN=ArkDeck Development Daemon (host-trusted only)`.
   - `msix.signing` records `signed: true`, `installable: true`, a signer subject equal to the
     publisher, signer SHA-256 `a63546a5…` and `timestamped: false`.
   - The feed's `MainPackage` names the same publisher (673 bytes, `3cbc6627…`).
   - `git status` shows `windows/App/Package.appxmanifest` unchanged.

   The earlier run recorded signtool refusing this same stand-in on the unmodified manifest,
   because of the publisher mismatch. With the override, the MSIX signs and verifies.

Not exercised:
- the positive production path, which needs the maintainer's Artifact Signing certificate and a
  timestamp;
- installing the signed MSIX, which would need the development certificate trusted as a
  package signer — a store change this slice does not make.

## Open points (unchanged, for the maintainer)

- The App still has no publisher-identity pin (ruling 17), so `-Smoke` with production signing
  stays refused.
- The packaged daemon's identity, when the CLI starts it, is still undecided.

## Local checks

- The pwsh 7 parser found 0 errors in `package-rc.ps1`.
- `PYTHONUTF8=1 sh scripts/check-sdd.sh` and `git diff --check`: pass.
- No Rust or C# source changed. The csproj item was exercised by run 2.

## Maintainer items

1. Record the Artifact Signing organisation and EKU (runbook §1.3 step 3).
2. Run `package-rc.ps1 -SigningMode production` with both signing commands, the expected
   publisher and `-MsixPublisher "<certificate subject>"` from a clean checkout. Then run the
   clean-host runbook.
