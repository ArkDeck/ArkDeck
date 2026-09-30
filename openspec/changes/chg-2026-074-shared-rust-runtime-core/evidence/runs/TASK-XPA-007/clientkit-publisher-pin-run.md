# TASK-XPA-007 — the ClientKit production publisher-identity pin, 2026-09-30

- **Task.** TASK-XPA-007 (ClientKit), for WM6 and the TASK-XPA-022 release candidate. This closes
  the gap recorded in `evidence/runs/TASK-XPA-022/windows-appinstaller-uninstall-signing-run.md`
  ("The App has no publisher-identity pin"): the .NET ClientKit now pins a production daemon by
  its publisher identity (maintainer ruling 17, #2352), exactly as the Rust client does, and
  the App reads the same installation inputs as the CLI.
- **Base.** Protected `main` at `7d2dd8ae`.
- **Host.** The Windows 11 x64 reference host, non-elevated. Nothing was installed, elevated or
  trusted; no certificate was created in a store and no setting changed. Fixture certificates
  are in-memory self-signed certificates on ephemeral keys. The real Artifact Signing sample is
  the host's installed GitHub CLI `gh.exe`, only opened and verified, never run.

## What was delivered

### ClientKit (`windows/ClientKit/Transport`)

- **`DaemonIdentity`** gains `PublisherOrganization` and `PublisherEku` (optional, after the
  existing members, so every existing construction is unchanged).
- **`Publisher.cs`** (new), the Rust `publisher.rs` and `SignerPins`:
  - `PublisherIdentity.FromConfig`: both inputs or neither. Only one of them, an empty or
    whitespace-padded organisation, or an EKU that is not `1.3.6.1.4.1.311.97.<profile>` (arcs
    of digits, no leading zeros, never the Public Trust marker `1.3.6.1.4.1.311.97.1.0`)
    refuses.
  - `PublisherIdentity.ChainMatches`: over the chain `WinVerifyTrust` verified (leaf first, root
    last, at least two certificates). The root's DER SHA-256 must be
    `5367f20c…1270`, the Microsoft Identity Verification Root Certificate Authority 2020, the
    same constant as the Rust `ARTIFACT_SIGNING_ROOT_SHA256`. The leaf must have exactly one
    subject `O=` (multi-valued RDNs included) equal to the organisation, and the code-signing
    EKU and the configured identity EKU in its own EKU extension. Undecodable DER is no match.
  - `SignerPins`: the development certificate SHA-256 and the publisher identity. Either that
    is configured may vouch for the chain; a malformed certificate pin satisfies nothing,
    whatever else is configured (the Rust `verify_signature`).
- **`Authenticode.TrustedSignerChain`** replaces `SignerMatches`: the same `WinVerifyTrust` call
  (generic verify v2, no UI, whole-chain revocation from the cache only, root excluded, over
  the held image handle), now copying every certificate of the first signer's chain
  (`CRYPT_PROVIDER_SGNR.csCertChain`) as the Rust `trusted_signer_chain` does.
- **`ProcessIdentity.RequireServer`** reads the pins before the file-identity check and accepts
  the package family or a trusted signature that satisfies a pin.
- **`PipeConnector.Connect`** reads the pins before the pipe is opened: a partial or malformed
  publisher identity is refused (`InstanceMismatch`) with zero frames, whether or not a server
  exists, as the Rust `verify_installed_image` refuses before anything is opened.

### App (`windows/App.Core/Daemon/DaemonConfiguration.cs`)

The App reads `ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` and `ARKDECK_DAEMON_PUBLISHER_EKU`, the
CLI's variables, beside the signer pin and the package family. A publisher identity alone
configures a connection; half of one reaches ClientKit and is refused there, as in the CLI.

### Release candidate (`windows/scripts/package-rc.ps1`, `App.UITests/InstalledRcTests.cs`)

The production smoke was refused only because the App had no publisher pin. It now runs:
- each executable's signature must be valid and timestamped, and its publisher identity
  (`Get-PublisherIdentity`, the shared helper) must equal the manifest's;
- the CLI and the App's UIA step are configured with the two publisher variables instead of a
  certificate hash (`ARKDECK_RC_PUBLISHER_ORGANIZATION` / `_EKU` for the UIA test);
- `-Smoke` is refused only for an unsigned build;
- the manifest's production `daemonConfiguration` note now says both clients read the publisher
  inputs.

### Documentation

`windows/README.md` ("Which daemon", the RC smoke) and the clean-host runbook: its "Current
limits" no longer pin the xcopy App by the leaf SHA-256; step 5 starts the App with the same
publisher variables as the CLI and adds a negative check.

## Tests

| Where | What |
| --- | --- |
| `ClientKit.Tests/PublisherTests.cs` (fixtures) | the root constant is the Rust fixture's certificate (SHA-1 `f40042e2…`, SHA-256 `5367f20c…`); a matching chain, with or without an intermediate, and with `O=` inside a multi-valued RDN; six other or ambiguous organisations; five EKU sets without the code-signing or the configured profile EKU; another root, a lone leaf, an empty chain, the root as leaf, undecodable DER; eleven partial or malformed configurations; a partial identity refused whatever else is set, and refused by `PipeConnector` before any pipe exists; either pin vouching, a malformed certificate pin vouching for nothing; an unsigned image (a copy of `whoami.exe`) has no trusted chain |
| `PublisherTests.ARealArtifactSigningPublisherIsMatchedThroughWinVerifyTrust` | with `ARKDECK_PUBLISHER_SAMPLE` = `gh.exe`, organisation `GitHub, Inc.` and its profile EKU `1.3.6.1.4.1.311.97.335068538.954251622.774763419.164527060`: the `WinVerifyTrust` chain (leaf, two intermediates, the 2020 root) matches; another organisation, another profile EKU and a certificate pin do not. Inconclusive without the variables |
| `ClientKit.Tests/EndToEndTests.cs` (real daemon) | the dev-signed Rust daemon: health and doctor under the development pin as before; refused (`InstanceMismatch`, no value) under a production publisher pin naming the development signer or Contoso, and under a partial publisher identity beside the right development pin; accepted with a publisher identity configured beside the development pin |
| `App.Tests/SurfaceTests.cs` | a publisher identity alone configures a `SessionChannel` (no server: `EndpointUnavailable`); half of one, or the marker EKU, is `InstanceMismatch` |

## Runs on this host

1. `dotnet build windows/ArkDeck.Windows.slnx -c Release`: 0 warnings, 0 errors.
2. `dotnet test ClientKit.Tests -c Release` with `ARKDECK_DEV_SIGNER_THUMBPRINT`, the daemon built
   from this revision (`cargo build -p arkdeck-agentd`) and the `gh.exe` sample: **43 passed,
   0 skipped**.
3. `dotnet test App.Tests -c Release`: **51 passed, 0 skipped**.
   Both suites again with `TEMP`/`TMP` on an 8.3 short path on `C:`: 43 and 51 passed, 0
   skipped.
4. `package-rc.ps1 -SmokeZip` of a development RC (built by #2413's run, revision `85d1b384`)
   with this revision's smoke and UIA test: **PASS** (doctor, the App UIA step 1/1, uninstall).
   The production branch of the smoke was not exercised: there is no production RC.

## The MSIX daemon's package identity (design options; not implemented)

**The problem.** A process has a package family only when it is activated with package
identity. The CLI starts `<InstallLocation>\arkdeck-agentd.exe` with `CreateProcess`, so the
daemon of the MSIX form runs without one, and a client pinned only by
`ARKDECK_DAEMON_PACKAGE_FAMILY` refuses it (clean-host runbook step 8). The App does not start
the daemon (decision 11: the client-started daemon lives in the CLI).

1. **An App Execution Alias for the CLI** (`uap5:AppExecutionAlias`, full trust). A CLI started
   through the alias runs with package identity, and a child process of a packaged full-trust
   process stays in the package, so the daemon it starts would carry the package family.
   - For: the package family becomes a real proof, and the Store/winget form gets `arkdeck` on
     `PATH` for free.
   - Against: only alias activation carries identity. A CLI run by its full path, from a script
     or from the xcopy form, still starts an unpackaged daemon. The alias must not be
     `arkdeck.exe` beside an `ArkDeck.exe` alias (NTFS case). Aliases and child identity need a
     clean-host proof before the pin can rely on them.
2. **The App starts the daemon** (as a full-trust child of the packaged App).
   - For: an App-started daemon has the package family.
   - Against: it contradicts decision 11 and leaves CLI-only use (no App running) unsolved, so
     the CLI would still need another pin. It adds a second daemon starter to keep in step
     with the CLI's pre-launch checks.
3. **Pin fallback: pin the MSIX daemon by its publisher identity.** The daemon and CLI inside
   the MSIX are the same Authenticode-signed files as the xcopy form (package-rc signs the
   runtime before packing it). Both clients already accept any configured pin: the package
   family or a signature that satisfies the publisher identity (Rust `verify_installed_image`
   and `require_server`, and now ClientKit). An MSIX installation is configured with the two
   publisher variables, with the package family optional beside them.
   - For: no code change, one trust story for both forms, and it works for every starter
     (CLI by alias or by path, App, script). The path pin still applies, and
     `C:\Program Files\WindowsApps` is not writable by the user.
   - Against: the package family is then not what proves the daemon; a daemon of the same
     publisher at the configured path would pass, as in the xcopy form. It relies on the inner
     files staying Authenticode-signed if the package is re-signed (the Store re-signs the
     package, not the files inside).

**Recommendation: option 3 now** (accepted as delegated minor decision 4 below), recorded as
the MSIX form's configuration in the clean-host runbook. It needs no code, matches ruling 17 for both forms, and
covers every way the daemon can be started. Option 1 can be added later if the maintainer wants
the package family as a proof of its own (for example for a Store listing), and is compatible
with 3. Option 2 is not recommended.

## Delegated minor decisions (pending the next rulings batch)

1. **The App's publisher inputs are the CLI's variable names**, read with the App's existing
   rule that an empty value is unset. ClientKit itself treats an empty string as malformed,
   as the Rust client does.
2. **A partial publisher identity is refused at connect, not at App start.** ClientKit is the
   one place that decides; the App shows the recovery banner with ClientKit's reason
   (`InstanceMismatch`), as for any refused identity.
3. **The production smoke configures the clients by publisher only**, no certificate hash,
   so it proves the configuration a user will have.
4. **The MSIX daemon is pinned by its publisher identity (option 3 above).** Accepted by the
   lead after #2416 under the user's standing instruction for minor decisions; delegated minor
   decision, pending the next rulings batch. No code change: an MSIX installation is
   configured with `ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` and `ARKDECK_DAEMON_PUBLISHER_EKU`,
   the package family optional beside them. The clean-host runbook's step 8 and
   `docs/release/windows-install.md` state it. Options 1 and 2 are not taken.

## Not changed

- No Rust source (the Rust client already pins the publisher), so no cfg gate changed and the
  macOS cross-check does not apply.
