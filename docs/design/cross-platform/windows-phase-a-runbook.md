# Windows phase A runbook (maintainer)

- **Version:** 2026-09-30. Written against protected `main` `565f8b1d` (#2394).
- **Scope:** CHG-2026-074 r12/r13, Windows phase A. This runbook is the maintainer's ordered
  checklist. Phase S (software) is the agents'.
- **Status:** a runbook, not a run record. Nothing here is evidence until a step is run and
  recorded.

Phase A is everything that needs the maintainer's hands, host, accounts, credentials or the
DAYU200. This runbook lists it in the order it can be done. For each step it gives:

- the gate: what must already be on `main`;
- the exact command;
- the expected result;
- where the record goes.

Steps that wait on software still in flight say so and are not to be forced. A step that cannot
run as written is recorded as found and stops there; nothing is bypassed, and no macOS authority
is reused (AGENTS.md; `docs/design/cross-platform/windows-phase-agent-prompt.md` §2.2).

## 0. Conventions

- **Host.** The Windows 11 x64 reference host, in a normal, non-elevated PowerShell 7 (`pwsh`)
  window, unless a step says **elevated**. Record `winver`, the OS build
  (`(Get-CimInstance Win32_OperatingSystem).BuildNumber`) and the tool versions each time.
- **Checkout.** `D:\src\ArkDeck` at the protected-`main` commit named in the step's record.
  `git -C D:\src\ArkDeck status --porcelain` must be empty before any package build.
- **Raw outputs** go outside every git work tree, in one new directory per step:

  ```powershell
  $out = Join-Path $env:LOCALAPPDATA "ArkDeck-phaseA\<step>-<yyyymmdd>"
  New-Item -ItemType Directory $out
  ```

  Raw outputs hold serials, SIDs, user paths and account names, so they are never pasted into a
  chat, issue or commit. The agent turns them into sanitized records:
  - `rust/scripts/windows_sample_process.py` for the HDC and USB samples;
  - by hand review for everything else.
- **CLI invocations.** Every CLI call takes `--output json`, and its stdout is saved as
  `$out\<journey>-<step>.json`. Control-plane calls also take a readable
  `--control-request-id` (for example `gj1-doctor`).
- **Outcome states.** A Golden Journey is recorded in `PRODUCT-LOOP.md` §6's four states only:
  `NOT_STARTED`, `IMPLEMENTING`, `BLOCKED_BY_PRODUCT_DEFECT`, `REAL_DEVICE_PASS`.
  `REAL_DEVICE_PASS` holds only on the current Catalog digest.
- **DevEco Studio and other HDC servers.** DevEco Studio and any other HarmonyOS tool stay
  **closed** during every HDC step. Nothing is ever killed from a script. If port 8710 is held,
  close its owner normally or stop and report it.

## 1. Identity

Each item below is maintainer-only (§1.1 of the agent prompt): certificate creation, trust-store
changes and signing credentials.

### 1.1 Development daemon signer (done, keep)

- **Status.** Created during W0/XPA-002 as `CN=ArkDeck Development Daemon (host-trusted only)`.
  Its thumbprint is in `HKCU\Environment` `ARKDECK_DEV_SIGNER_THUMBPRINT`.
- **Check that it is present:**

  ```powershell
  $t = (Get-ItemProperty HKCU:\Environment).ARKDECK_DEV_SIGNER_THUMBPRINT
  pwsh -NoProfile -File D:\src\ArkDeck\rust\scripts\windows-dev-identity.ps1 pin -Thumbprint $t
  ```

  **Expected:** JSON with `pin` (the SHA-256 of the certificate DER). The certificate is in
  `Cert:\CurrentUser\My` with a private key, and in `Cert:\CurrentUser\Root`.
- **If it is missing, recreate it.** `create` shows a Windows trust prompt; confirm it.

  ```powershell
  pwsh -NoProfile -File D:\src\ArkDeck\rust\scripts\windows-dev-identity.ps1 create
  setx ARKDECK_DEV_SIGNER_THUMBPRINT <thumbprint printed>
  ```

- **Scope.** It signs development daemons for the signed-CLI tests and the development RC. It is
  **not** an installation identity (design §L.1 item 22) and never enters a production package.

### 1.2 Development MSIX publisher `CN=ArkDeck Development` (ruling 12)

Needed for the packaged-client SPK-3 row (§3), SPK-4 (d), and a packaged smoke of the
development MSIX.

1. Create the certificate (normal terminal):

   ```powershell
   New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=ArkDeck Development" `
     -KeyUsage DigitalSignature -CertStoreLocation Cert:\CurrentUser\My `
     -NotAfter (Get-Date).AddYears(1) -TextExtension @("2.5.29.19={text}")
   ```

2. **Elevated:** trust the public certificate on this host only.

   ```powershell
   Export-Certificate -Cert Cert:\CurrentUser\My\<THUMBPRINT> -FilePath D:\certs\arkdeck-dev.cer
   Import-Certificate -FilePath D:\certs\arkdeck-dev.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
   ```

3. Build the development RC and sign its MSIX (normal terminal; `signtool` is from Windows SDK
   10.0.26100):

   ```powershell
   pwsh D:\src\ArkDeck\windows\scripts\package-rc.ps1 -OutputDirectory D:\temp\rc-dev-<date> -SigningMode development -Smoke
   $msix = (Get-ChildItem D:\temp\rc-dev-<date>\msix -Recurse -Filter *.msix).FullName
   signtool sign /fd SHA256 /sha1 <THUMBPRINT> $msix
   Add-AppxPackage $msix
   ```

   `package-rc.ps1` builds the MSIX unsigned (identity `ArkDeck.Development`, publisher
   `CN=ArkDeck Development`). Signing it is this maintainer step.

   **Expected:**
   - `package-rc.ps1` ends with smoke **PASS**: all files match the manifest, doctor `ok: true`
     twice, the App UIA test 1/1, and the daemon stopped and the directory removed. This is the
     same table as `runs/TASK-XPA-022/windows-rc-package-run.md`.
   - `Add-AppxPackage` succeeds.
   - `Get-AppxPackage ArkDeck.Development` shows `PackageFamilyName`.
4. **Packaged smoke.** Launch *ArkDeck* from Start. **Expected:** the App starts the packaged
   daemon, shows the doctor report and protocol 1.0.0, and shows no recovery banner.
5. Record the package family. It is the MSIX daemon pin (`ARKDECK_DAEMON_PACKAGE_FAMILY`, ruling
   17). Remove the package with `Remove-AppxPackage <PackageFullName>` when done.
6. **Record:** `runs/TASK-XPA-022/msix-development-signing-<date>-run.md`. Include the package
   family, the MSIX SHA-256 and the smoke result. Leave out the thumbprint and the user SID.

### 1.3 Production signing (Azure Artifact Signing, ruling 17)

- **Gate.** An Artifact Signing account and certificate profile exist; the maintainer holds the
  credentials.
- **Software gap.** `package-rc.ps1` has no production mode yet (see `windows-rc-package-run.md`,
  maintainer item 1). The xcopy runtime already has it.

1. Write the signing command the scripts call once per file: a `.ps1` or `.exe` that signs its
   only argument with a timestamp. For example, `signtool sign /fd SHA256 /tr
   http://timestamp.acs.microsoft.com /td SHA256 /dlib <Azure.CodeSigning.Dlib.dll> /dmdf
   <metadata.json> <file>`. Keep it outside the repository.
2. Build the production xcopy runtime from a clean checkout:

   ```powershell
   $env:ARKDECK_PRODUCTION_SIGN_COMMAND = 'D:\signing\sign-one.ps1'
   pwsh D:\src\ArkDeck\rust\scripts\windows-package-xcopy.ps1 -OutputDirectory D:\temp\runtime-prod-<date> -SigningMode production
   ```

   **Expected:**
   - both executables verify `Valid`;
   - each chain ends at *Microsoft Identity Verification Root Certificate Authority 2020*;
   - both leaves carry the same single `O=` and the same certificate-profile EKU
     `1.3.6.1.4.1.311.97.<profile>`;
   - the manifest's `daemonConfiguration` names `ARKDECK_DAEMON_PUBLISHER_ORGANIZATION` and
     `ARKDECK_DAEMON_PUBLISHER_EKU`.

   **Refusals:** an untimestamped signature, a dirty checkout, or `-ExpectedSignerSha256`.
3. Record the publisher organisation and EKU. Every client is configured with them (both or
   neither). No certificate hash is pinned in production.
4. **Gate for the production App and MSIX:** a `package-rc.ps1` production mode (an agent slice)
   and the MSIX `Publisher` set to the certificate subject. Then:
   - sign the MSIX with the same command;
   - build the App Installer feed (maintainer item 3 of `windows-rc-package-run.md`);
   - the Store and winget submissions are the maintainer's.
5. **Record:** `runs/TASK-XPA-022/production-signing-<date>-run.md`.

## 2. Sampling, then the Windows HDC registration

### 2.1 HDC sample (both candidates)

- **Gate:** `rust/scripts/windows-hdc-sample.ps1` is on `main` (yes).
- **Crib:** `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-002/hdc-windows-sampling-crib-20260930.md`.
  Follow its "Steps", candidate 1 then candidate 2.
- **Run** each of the phases `no-board`, `board-connected`, `board-removed` and `stop-server` once
  per root, in a fresh root per candidate:

  ```powershell
  pwsh -NoProfile -File .\rust\scripts\windows-hdc-sample.ps1 -HdcPath $hdc -OutputDirectory $root -Phase <phase>
  ```

- **Expected:** each run prints the `sample.json` path with no yellow `WARNING`. A `WARNING` means
  the phase refused; stop and hand back the root as it is.
- **Hand back:** the two root paths (`%LOCALAPPDATA%\ArkDeck-samples\hdc-c1-<date>`,
  `…\hdc-c2-<date>`), plus anything unusual: a board prompt, a driver dialog, a refusal, a step
  skipped.

### 2.2 DAYU200 USB properties

- **Crib:** `…/evidence/runs/TASK-XPA-004/dayu200-usb-properties-crib-20260930.md`.
- **Run** phases `before`, `after`, `removed` and `replugged` (the last into the **same** port):

  ```powershell
  pwsh -NoProfile -File .\rust\scripts\windows-usb-sample.ps1 -OutputDirectory $root -Phase <phase>
  ```

  The phases can be interleaved with §2.1 to save plug cycles, as the crib says.
- **Expected:** each phase prints the `usb-<phase>.json` path.
- **Hand back:** the root and the port used.

### 2.3 WHR-001..003 (agent, then maintainer decision)

1. **Agent (TASK-WHR-001, host-only).** Runs these from the raw roots, then fills every
   `TBD(sample)` in `openspec/changes/chg-2026-078-windows-hdc-registration/`:

   ```powershell
   python rust/scripts/windows_sample_process.py hdc --root <c1 root> --label c1 --tool-dir <c1 dir> --out rust/tests/fixtures/hdc-windows/c1
   python rust/scripts/windows_sample_process.py hdc --root <c2 root> --label c2 --tool-dir <c2 dir> --out rust/tests/fixtures/hdc-windows/c2
   python rust/scripts/windows_sample_process.py usb --root <usb root> --hdc-root <c1 root> --hdc-root <c2 root> --out <scratch>\usb
   python rust/scripts/windows_sample_process.py render --hdc rust/tests/fixtures/hdc-windows/c1 --hdc rust/tests/fixtures/hdc-windows/c2 --usb <scratch>\usb --date <yyyymmdd> --out <CHG-2026-074 runs dir>
   ```

   **Expected:**
   - no `refused:` line (the leak scan passes);
   - two run records, `hdc-windows-sample-<date>-run.md` and `dayu200-usb-properties-<date>-run.md`;
   - a PR.
2. **Maintainer decision** on that PR:
   - which candidate(s) to register (`TBD(maintainer)`);
   - which families are `supported`. `healthyCheckserver` is registrable only if `checkserver`
     started no server.
3. **Agent (TASK-WHR-002).** Registers the Windows registry, fixtures, profile section and lock,
   with contract tests. **Maintainer:** reviews and merges it (governance).
4. **Agent (TASK-WHR-003).** Fills the Windows USB census fields. Then CHG-2026-074 TASK-XPA-004
   and XPA-005 adopt the registry on the Windows daemon.
   - **Gate for GJ-1..5 below:** those adoption PRs are on `main`.
   - `operation list` on Windows names `observe.device@1` `available` once an HDC is selected.

## 3. SPK-3 rows only the maintainer can run

- **Gate:** §1.1 (and §1.2 for row 5).
- **Record:** `runs/TASK-XPA-002/spk-3-<date>-run.md`, with the rows as `PASS`/`FAIL`/`NOT_RUN`
  from the harness's `spk3.json`.

Build once from `rust/`:

```powershell
cargo build --release -p arkdeck-agentd -p arkdeck-cli
cargo build --release -p arkdeck-platform --example windows_spk3
```

Here `<target>` is the Cargo target directory, and `<pin>` is the §1.1 pin. Sign the daemon
before any row:

```powershell
pwsh -NoProfile -File D:\src\ArkDeck\rust\scripts\windows-dev-identity.ps1 sign -Thumbprint $t -Path <target>\release\arkdeck-agentd.exe
```

The base invocation (a fresh output directory each time):

```powershell
pwsh -NoProfile -File rust/scripts/windows-spk3.ps1 -DaemonPath <target>\release\arkdeck-agentd.exe `
  -CliPath <target>\release\arkdeck.exe -ProbePath <target>\release\examples\windows_spk3.exe `
  -OutputDirectory <new dir> -PythonPath $env:ARKDECK_PYTHON -SignerCertificateSha256 <pin> <row options>
```

| # | Row(s) | Extra condition | Row options | Expected |
| --- | --- | --- | --- | --- |
| 1 | `installed-daemon-owner-image-signature-or-package`, the three `product-*` rows | §1.1 | (none beyond the base) | the product rows `RECORDED`/`PASS`; frames exchanged with the signed daemon |
| 2 | `foreign-account-owner`, `cross-account-client` | a second local Windows account with read access to the probe binary (creating it is a system change) | `-OtherUserCredential (Get-Credential)` | the foreign squatter is refused; the foreign `raw-connect` is refused with Win32 error 5 |
| 3 | `different-elevation-client` | a separately **elevated** same-user terminal | run by hand: normal terminal `& <probe> guard-server \\.\pipe\arkdeck-spk3-<fresh>`; elevated terminal `& <probe> raw-connect <same name>` | the guard-server record shows `frameConsumerEntries: 0` |
| 4 | `remote-client` | a second Windows machine with the identical probe build (same SHA-256), and a `PSSession` to it (WinRM and firewall on both hosts may need configuring) | `-RemoteSession $s -RemoteProbePath <path>` | `connected: false`, `osError: 5` (`PIPE_REJECT_REMOTE_CLIENTS`) |
| 5 | `packaged-client` | the probe packaged as a signed MSIX and registered (§1.2) | `-PackagedProbePath <path> -ExpectedClientPackageFamily <family>` | accepted; the observed package family equals the expected one |
| 6 | `W0-SmartScreen-driver-distribution`, `DAYU200-current-published-HDC-tuple` | §2.3 merged; the board connected; USB driver access checked as a non-admin; a **downloaded** signed build for MotW/SmartScreen | `-HdcPath <registered hdc.exe> -HdcSha256 <sha>` | recorded per row; SmartScreen and MotW observed, not inferred |

The harness exits 1 whenever any row is `FAIL`, and 2 when every row is
`PASS`/`NOT_RUN`/`REVIEW_REQUIRED`. Do not edit a row to make it pass.

## 4. GJ-1..5 on the DAYU200

- **Source runbook:** `docs/design/cli-golden-journey-headless-runbook.md` §0–§7, followed as
  written with the Windows differences below. The judging criteria are that runbook's, unchanged.
- **Record:** per Journey, `runs/<task>/windows-gj<N>-<date>-run.md` in §7's template. The Windows
  column uses the Windows host, build, Catalog digest and HDC tuple.

### 4.0 Windows installation and differences (all Journeys)

1. **Install the product.** Unpack the RC xcopy zip into a new directory, then configure the CLI
   with the daemon path and pin.
   - Production (§1.3): use the publisher organisation and EKU.
   - Development: use `ARKDECK_DAEMON_SIGNER_SHA256=<pin>` (§1.1).

   ```powershell
   Expand-Archive <rc zip> D:\ArkDeck-rc-<date>
   $env:ARKDECK_DAEMON_PATH = 'D:\ArkDeck-rc-<date>\arkdeck-agentd.exe'
   $env:ARKDECK_DAEMON_PUBLISHER_ORGANIZATION = '<org>'; $env:ARKDECK_DAEMON_PUBLISHER_EKU = '<eku>'
   Set-Alias arkdeck D:\ArkDeck-rc-<date>\bin\arkdeck.exe
   ```

   There is no `runtime service install`/`update` on Windows (`unsupportedOnPlatform`,
   decision 11). The first CLI call starts the daemon (`%LOCALAPPDATA%\ArkDeck\Agentd`), and
   `runtime service status|verify|restart` manage it. The headless runbook's §1 update path
   (`runtime bundle register` → `runtime service update`) is replaced by reinstalling the RC.
2. **Paths.** Input files live under `$out\inputs\` (the headless runbook's
   `/private/tmp/…/inputs/`). `--file` and `--destination` take `X:\…` drive paths.
3. **Preconditions** (headless runbook §1), with Windows expectations:
   - `doctor --deep --require-healthy` answers;
   - `runtime service status` names the installed daemon and its signer or package;
   - `runtime hdc status` and `runtime tool list` name the registered Windows HDC.
     **Gate:** §2.3 adoption on `main`. Before that they answer `operationUnavailable`, and every
     HDC Journey below stops.
   - `operation list` names the Journey's operations `available`.
4. **Board.** The DAYU200 is connected directly (no hub), with its normal image. DevEco Studio is
   closed. A board authorisation prompt is a HAR, recorded as §0 of the headless runbook says.

### 4.1 GJ-1 Device Observe

- **Gate:** §2.3 adoption.
- **Steps:** headless runbook §2 and §2.1, unchanged commands:
  1. `device candidates`;
  2. `target adopt`, `target show`, `target availability`;
  3. `agent run --operation observe.device@1` and `capture.diagnostics@1`;
  4. `job result`/`evidence`, `artifact list`/`read`;
  5. `runtime service restart`, then read both Jobs back;
  6. the HAR crash-resume.
- **Expected:** that runbook's criteria. In addition, `target show`'s
  `stablePhysicalIdentitySha256` must not change across the replug. The Windows USB relation
  (ruling 11 topology) is recorded, redacted.

### 4.2 GJ-2 HAP Debug

- **Gate:**
  - §4.1 passed;
  - `artifact import hap` and `debug.hap@1` `available` on Windows (TASK-XPA-008, Import owner
    and deviceMutation admission).
- **Steps:** headless runbook §3. The HAP is the same signed single-entry HAP as the macOS round.
- **Expected:** that runbook's criteria. Every step is `verified`, with
  `outstandingResidueCount == 0`.

### 4.3 GJ-3 Native Debug

- **Gate:**
  - §4.2 passed;
  - `deploy.native-library.app-owned@1` `available` on Windows (TASK-XPA-009, including the
    code-sign helper on Windows);
  - the rollback fixture checked for the current target.
- **Steps:** headless runbook §4. **Expected:** that runbook's criteria.

### 4.4 GJ-4 Flash Recovery (destructive)

- **Gate:**
  - the maintainer authorises this window per HardwareCampaign (§1.1 of the agent prompt);
  - AF-W1 is green (ArkForge's self-hosted Windows acceptance workflow);
  - TASK-XPA-010's Windows lane is on `main`;
  - its Windows configuration surface replaces the macOS `runtime service update
    --arkforge-bundle … --arkforge-campaign …`, which does not exist on Windows. Its exact
    command is **TBD by TASK-XPA-010** and goes here when that slice lands.
- **Steps:** headless runbook §5, with the flash prerequisites, `install-binding` (hdc-normal
  first), the bundle import, the lane preview, `flash.full-restore@1` and the postflight
  observe.
- **Expected:** that runbook's criteria, including the machine readback `OpenHarmony-7.0.0.37`.
  Stop at the first missing proof; nothing is forced.

### 4.5 GJ-5 Bounded AI Debug Loop

- **Gate:**
  - §4.2 passed;
  - the workspace, analyzer and signing operations `available` on Windows (TASK-XPA-011): the
    workspace composition, the DevEco toolchain registry, and signing through Credential Manager
    (#2372);
  - DevEco Studio installed; its SDK path confirmed by the maintainer (WM3 crib);
  - the credential installed with `runtime signing install --build-profile <DevEco
    build-profile.json5> --keystore <storeFile> --key-alias debugKey --project-ref <ref>`.
    The secret is entered at the console prompt; it is never put in argv or the environment.
- **Steps:** headless runbook §6, with Windows paths.
- **Expected:** that runbook's criteria and discipline: no raw device command, no App, no repository
  write.

## 5. Clean-host smoke

- **Gate:** §1.3, a production-signed RC. A development-signed RC verifies only on a host that
  trusts the development certificate.
- **Target:** a clean Windows 11 x64 host or Windows Sandbox. Windows Sandbox is enabled elevated
  with `Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All`,
  then a reboot.

1. Copy only the RC zip and `package-rc.ps1` (or a checkout) to the target. PowerShell 7 must be
   installed there.
2. Run:

   ```powershell
   pwsh .\windows\scripts\package-rc.ps1 -SmokeZip <rc zip>
   ```

3. **Expected:** the six rows of `windows-rc-package-run.md`'s smoke table, all passing:
   - install and verify every file;
   - `doctor` `ok: true` on first start (the daemon starts from the installed image);
   - the App UIA test 1/1;
   - `doctor` again;
   - stop through the stop event;
   - uninstall leaves no process, no new local application data, and `%LOCALAPPDATA%\ArkDeck`
     unchanged.
4. **MSIX on the clean host:**
   - `Add-AppxPackage <production msix>`;
   - launch;
   - the App shows the doctor report with no recovery banner;
   - `Remove-AppxPackage`.

   **Expected:** installs without Developer Mode, with the Windows App SDK self-contained
   (decision 10).
5. **Record:** `runs/TASK-XPA-022/clean-host-smoke-<date>-run.md`. Include the host tuple and the
   package SHA-256s; leave out the account name and SIDs.

## 6. Traceability and platform flip (maintainer PR, last)

- **Gate:**
  - every row of `openspec/platforms/windows/conformance-cases.yaml` is run and recorded (the GJ
    rows from §4, the SPK-3 rows from §3, the XPA-002 rows);
  - CHG-2026-074's Windows tasks reach `done` through their own PRs;
  - the change is `verified` for the Windows tuple.

  The traceability update rule (`openspec/verification/traceability.md` header) flips a platform
  column only at change-level `verified`.

In one maintainer PR:

1. `openspec/platforms/windows/conformance-cases.yaml`:
   - each case `status` goes to its actual result (`PASS`/`FAIL`/…) with its evidence path;
   - the `support_cells` entry `windows-11-x64-planned` goes to the tested tuple (OS build,
     package format MSIX + xcopy, tool tuple).
2. `openspec/platforms/PLATFORM-PROFILES.lock.yaml`:
   - `PLATFORM-WINDOWS` `conformance_status` goes from `notStarted` to the evidenced status, and
     `last_verified` is set;
   - `windows` moves from `not_started_platforms` to `current_delivery_platforms` only if the
     maintainer declares delivery.
3. `openspec/verification/traceability.md`: the Windows column of each Requirement range the
   evidence covers. Ranges without evidence stay `notStarted`; a gap is `blocked` or
   `nonConformant`, never a waiver.
4. `openspec/platforms/windows/profile.md`: the version bump and the support cell.

Nothing flips on hosted CI, fixtures or plan-only runs (AGENTS.md "什么不算真机或平台验收").

## 7. Order at a glance

| # | Step | Blocked on |
| --- | --- | --- |
| 1 | §1.1 dev signer check | — |
| 2 | §2.1/§2.2 HDC and USB samples | — (the board is connected) |
| 3 | §2.3 WHR-001 (agent), candidate choice, WHR-002/003 merge | samples; maintainer decision |
| 4 | §1.2 dev MSIX publisher, §3 SPK-3 rows 1–5 | certificate creation, second account, elevated terminal, second host |
| 5 | XPA-004/005 adoption of the Windows registry | WHR-002 on `main` (agents) |
| 6 | §4.1 GJ-1, §3 row 6 | step 5 |
| 7 | §4.2 GJ-2, §4.3 GJ-3, §4.5 GJ-5 | their Windows owners on `main` (agents) |
| 8 | §1.3 production signing | Artifact Signing account; `package-rc.ps1` production mode (agents) |
| 9 | §4.4 GJ-4 | AF-W1, TASK-XPA-010, the maintainer's go |
| 10 | §5 clean-host smoke | step 8 |
| 11 | §6 flip | everything above recorded |
