# TASK-XPA-022 — Existing-account development MSIX, 2026-10-13

The existing Windows 11 x64 reference host and current non-elevated account can
install a signed development MSIX. No new account, certificate, trust-store
entry or system policy was needed. The installed package exposed a missing
CLI/daemon declaration; the packaging-only candidate fixed that failure and
passed its real packaged App/Runtime smoke. It remains a candidate until review
and a protected-main package rerun. This is host evidence, not device evidence,
production signing, a clean-host result or an installed update.

## Source and artifacts

- The initial producer used clean protected source
  `caec3e7f77a9bfd3c2f15e39e9716385987ae568`, .NET SDK 10.0.401,
  Windows App SDK 2.5.1 and Windows SDK signing tools 10.0.26100.
- `package-rc.ps1 -SigningMode development -MsixPublisher
  'CN=ArkDeck Development Daemon (host-trusted only)' -MsixSignCommand
  <existing-signer-hook>` built and signed the package without `-AllowDirty`.
  The existing host development certificate was already trusted. Its private
  key was used only to sign these new local test packages.
- Initial package: `ArkDeck.App_0.1.0.0_x64.msix`, 73,667,260 bytes,
  SHA-256 `cfdd550933e72ec02614cc0488e40ab32a83c279c3d61c980bfabeb8f48128cd`.
  Signature status was `Valid`; publisher and signer subject matched.
- Registered identity: `ArkDeck.Development_0.1.0.0_x64__zt485k11138n0`;
  family: `ArkDeck.Development_zt485k11138n0`. `Get-AppxPackage` reported `Ok`.
  There was no pre-existing package of this identity in the account.
- Candidate package SHA-256:
  `8b03a86ba6ee60191655a9aa807fc4a921dae14ec1228effa615487661076fde`.
  Its App was published with the corrected RC manifest function. It reused
  the initial package's signed, published-source Runtime and CLI bytes:
  daemon `a612b65e5e98d6fdf98a8c34af2189bc58c2e5098d6030003500eef29b09eb83`,
  CLI `1e7ecbf03f5089a4b61dc9f0660ef2bc1188fa64ce1e3cccb7f490f995edc437`.
  No candidate Rust Runtime or device operation was run.

Original files, raw CLI envelopes, failure logs, TRX files and candidate
provenance remain local under
`D:/temp/arkdeck-windows-acceptance-20261013`. No serials, account identifiers,
connect keys, private signing material or user paths are copied into this run.

## Observations and repair

1. Current-user `Add-AppxPackage` installed the initial signed package with the
   existing trust configuration. Direct execution of its `bin/arkdeck.exe`
   failed at `CreateProcess` with Windows error 5, before any CLI control frame.
   The package contained both signed helpers but declared only `ArkDeck.exe`
   as an application.
2. The RC producer now derives a manifest containing hidden full-trust
   `Cli` and `Daemon` applications for `bin/arkdeck.exe` and
   `arkdeck-agentd.exe`. The ordinary App-only build manifest stays unchanged.
   The producer verifies both declarations in the final MSIX before signing
   and inventorying it. Publisher overrides and disabled write virtualization
   are preserved. This is consistent with Windows' application declaration
   model ([Application schema](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-application)).
3. The initial test package was removed while no package process was running.
   The signed packaging candidate was then installed at the same version and
   identity. Its CLI `--version` exited 0. This remove/reinstall is not an update.
4. With all account Jobs terminal, the original signed xcopy Runtime was
   stopped through its published service command. The packaged CLI's `doctor`
   started its bundled daemon and returned `ok: true`; service status verified
   the exact packaged daemon path. The real App UIA smoke passed 1/1, with no
   test transport, protocol `1.0.0`, no recovery banner and enabled controls.
   `GetPackageFullName` on the actual App process matched the registered
   full name. The Overview reported `Degraded`, with zero blockers, two
   warnings and seven information entries; it is not reported as a fully
   healthy environment.
5. The packaged daemon was stopped, and a `finally` path restored the original
   signed Runtime. The complete before/after Job lists, including every item,
   matched exactly: 57 Jobs, no new Job or changed item. The test-owned MSIX
   was removed; the account had zero remaining ArkDeck MSIX registrations.
   The original xcopy App, account state and all raw records were preserved.

`InstalledRcTests` now optionally requires the exact observed package identity
with `ARKDECK_RC_PACKAGE_FULL_NAME`. Its existing connection checks still apply;
being registered is not sufficient to pass. `ARKDECK_RC_DAEMON_PATH` permits an
explicit mixed-installation diagnostic while keeping the expected image pin.

## Retained failures and limits

- The initial package's CLI startup failure remains in `raw-msix-smoke`.
  That incomplete capture directory was retained. Restoration used a fresh
  `raw-msix-restore` directory and verified the original daemon and Job set.
- A separate initial MSIX App to xcopy Runtime check proved the App's package
  identity, then failed with `HealthExchangeFailed: Pipe is broken`
  (`uia-msix-app.log` and its TRX). Read-only native calls showed that an
  unpackaged process cannot open the system `WindowsApps` ancestor directory
  for the Runtime's required namespace lock, although it can open the package
  directory and executable. Zero requested access and both sharing modes also
  returned error 5. No ACL, namespace-lock or peer-authentication check was
  relaxed. The matching MSIX App/CLI/daemon passed with the unchanged checks.
  Mixed-package client acceptance remains unproved/failed on this host; this
  smoke does not close SPK-3's independent packaged-probe row.
- No production publisher, timestamped distribution, HTTPS update feed,
  same-publisher higher-version update, clean host, second account, elevated
  client, remote client or audible Narrator result is supplied by this run.
  Local development smoke does not replace those distinct observations.

## Local targeted checks

- Initial clean producer: exit 0, `package-msix.log`; signature, whole package
  size/hash, publisher and disabled write virtualization verified.
- Candidate manifest generation and `dotnet publish` with the exact existing
  signed runtime directory: exit 0 (`msix-candidate/build.log`). Windows SDK
  validation accepted the three application declarations. The known missing
  optional `mspdbcmf.exe` warning means no symbols package was produced.
- Candidate registration and actual `bin/arkdeck.exe --version`: exit 0;
  `msix-candidate/registration.json` and `cli-version.log`.
- `dotnet test windows/App.UITests/ArkDeck.App.UITests.csproj -c Release
  --no-restore -p:Platform=x64 --filter FullyQualifiedName~InstalledRcTests`
  with actual candidate installation inputs: exit 0, 1/1, zero skips, 22 s;
  `uia-msix-candidate.log` and
  `uia-msix-candidate/installed-msix-candidate.trx`.
- CLI doctor/status/stop and original restoration: all exit 0;
  `raw-msix-candidate-smoke`, `raw-msix-candidate-stop`, and
  `raw-msix-candidate-restore`. Uninstall exit 0: `msix-cleanup.json`.
- Final producer manifest checks: exit 0; default and overridden publishers
  preserve the tracked source and disabled virtualization. The final-package
  check rejects the actual original MSIX and accepts the actual candidate.
  Log: `D:/src/ArkDeck-wt/tools/windows-msix-validation-20261013.log`.
- `python rust/scripts/run-cargo.py fmt --all --check` again hit Windows'
  existing argument-length limit (error 206). The same runner's equivalent
  per-edition batched `rustfmt --check` passed all 356 workspace target roots,
  exit 0: `msix-fmt-all-check.log` and `msix-fmt-batched-check.log`.
  No Rust crate, contract input or Swift source changed in this increment;
  crate tests/clippy, contract generation and Swift tests were not repeated.
- `sh scripts/check-sdd.sh`: exit 0; log
  `D:/src/ArkDeck-wt/tools/windows-msix-sdd-20261013.log`. Git for Windows'
  `sh.exe` is invoked by its absolute path. `git diff --check`: exit 0.
  No complete local CI gate or device test was run.

## CI

The preceding PR [#2633](https://github.com/ArkDeck/ArkDeck/pull/2633),
head `1410cec2f3d96b0a3020ff2e302ace98adbb739a`, passed SDD Guard run
`38373622446` and Swift CI run `38373622565`. The latter passed the Windows
client lane and all selected Rust workspace/parity lanes on Windows, macOS
and Linux. The local direct-test historical-Catalog failures documented in its
run did not reproduce in CI's existing routed views. No head was amended to
record green CI. The maintainer merged it at protected-main
`aea6c663e8c79fe1501d5751a411a5b15021b3e6`; its tree is identical to the tested
head. This MSIX repair starts from that main. Its own CI and maintainer review
are pending.
