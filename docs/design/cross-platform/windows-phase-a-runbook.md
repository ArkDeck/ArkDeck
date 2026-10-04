# Windows phase A runbook (maintainer)

- **Version:** 2026-10-04. Written against protected `main` `982d4e6d` (#2518). The first version
  (2026-09-30, `565f8b1d`) is superseded. §2 is done, and §4 is rewritten for what `main` composes
  now.
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
4. **Packaged smoke.** Set `ARKDECK_DAEMON_SIGNER_SHA256=<pin>` as a user environment variable
   (a Start-menu launch reads the persistent environment), run the packaged
   `<InstallLocation>\bin\arkdeck.exe --output json doctor` with
   `ARKDECK_DAEMON_PATH=<InstallLocation>\arkdeck-agentd.exe`, which starts the packaged daemon
   (decision 11: the App does not start it), then launch *ArkDeck* from Start. **Expected:**
   doctor `ok: true`; the App shows the doctor report and protocol 1.0.0, and no recovery
   banner.
5. Record the package family. It is not the daemon pin: a CLI-started daemon has no package
   identity, so the MSIX daemon is pinned like the xcopy one, by the signer here and by the
   publisher identity in production (delegated minor decision, see
   `runs/TASK-XPA-007/clientkit-publisher-pin-run.md`). Remove the package with
   `Remove-AppxPackage <PackageFullName>` and the user variable when done.
6. **Record:** `runs/TASK-XPA-022/msix-development-signing-<date>-run.md`. Include the package
   family, the MSIX SHA-256 and the smoke result. Leave out the thumbprint and the user SID.

### 1.3 Production signing (Azure Artifact Signing, ruling 17)

- **Gate.** An Artifact Signing account and certificate profile exist; the maintainer holds the
  credentials.
- `package-rc.ps1 -SigningMode production` delegates the runtime to
  `windows-package-xcopy.ps1 -SigningMode production`, checks its publisher against the expected
  organisation and EKU, and signs the App and the MSIX (see `windows-production-rc-run.md`).

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
4. Build the production release candidate from the same clean checkout, with the recorded
   organisation and EKU and the certificate's subject as the MSIX publisher:

   ```powershell
   pwsh D:\src\ArkDeck\windows\scripts\package-rc.ps1 -OutputDirectory D:\temp\rc-prod-<date> -SigningMode production -ProductionSignCommand D:\signing\sign-one.ps1 -MsixSignCommand D:\signing\sign-one.ps1 -ExpectedPublisherOrganization '<O=>' -ExpectedPublisherEku 1.3.6.1.4.1.311.97.<profile> -MsixPublisher '<certificate subject>' -FeedBaseUri https://<feed host>/arkdeck/windows/
   ```

   **Refusals, before anything is built:** no expected organisation or EKU, the Public Trust
   marker as the EKU, no MSIX command or publisher (unless `-SkipMsix`), or a publisher whose
   `O=` is another organisation. The Store and winget submissions are the maintainer's.
5. **Record:** `runs/TASK-XPA-022/production-signing-<date>-run.md`.

## 2. Sampling, then the Windows HDC registration

**Status: done (2026-10-04).** The samples are on `main` (#2456, #2457), and the maintainer chose
candidate `c2` (DevEco Studio 26.0.0.43 `hdc.exe`, 3.2.0g). WHR-001..003 have merged (#2459,
#2472, #2469):

- the Windows HDC registry, fixtures, profile section and lock;
- the USB census mapping, every row `Confirmed`.

The gate admits only `c2`. The steps below are kept as the record of how it was done. They are
re-run only if the maintainer registers another DevEco release (a new integration change).

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

- **Source runbook.** `docs/design/cli-golden-journey-headless-runbook.md` §0–§7 is followed as
  written, with the Windows differences below. Its judging criteria are unchanged.
- **Who does what.**
  - An agent drives every step through the published CLI and the Runtime's typed operations
    (`scripts/agent-guides/acceptance.md`).
  - The maintainer does the physical actions: plugging, unplugging and board images, plus every
    step marked **maintainer gate** below.
  - Device effects go only through `agent run --operation …` / `agent resume` and the typed
    resource commands. Raw `hdc` is never used for a device effect. A read-only `hdc` call is
    allowed only where a step names one as a host fact (`hdc -v` and `hdc list targets -v` for
    the pre-window check in §4.0.4).
- **Record.** Each Journey gets two records:
  - the redacted machine record, at
    `docs/design/references/v1.6-goal/gj-headless-rerun-<date>-windows.json` (the CHG-2026-074
    verification matrix's Golden Journeys row), in the headless runbook §7 shape
    (`arkdeck.gj-headless-rerun/1`);
  - a run note, at `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/<task>/windows-gj<N>-<date>-run.md`.

  The `<task>` is the Journey's owning task: XPA-006 for GJ-1, XPA-008 for GJ-2, XPA-009 for GJ-3,
  XPA-010 for GJ-4 and XPA-011 for GJ-5. The record's Windows fields are the host, OS build,
  Catalog digest, the registered HDC tuple (`c2`) and the installed daemon's SHA-256.

### 4.0 Before any Journey (all rows)

#### 4.0.1 Which daemon

The rows require a **trusted installed daemon** (`conformance-cases.yaml`, each WIN-GJ row's
preconditions). That is the account daemon of an installed RC, started by the CLI at
`%LOCALAPPDATA%\ArkDeck\Agentd`, not a development root. A development root's evidence is never
`REAL_DEVICE_PASS` (`rust/crates/arkdeck-agentd/src/main.rs`, `development_usb.rs`).

On protected `main` `982d4e6d` the two compose different things:

| | Account daemon (installed RC) | Development root (`ARKDECK_DEVELOPMENT_STATE_ROOT`) |
| --- | --- | --- |
| Managed registered HDC (`c2`, 8710) | **no** (`windows_lifecycle.rs`: the HDC gate runs only for a development root) | yes, with `ARKDECK_DEVELOPMENT_HDC_PATH=<DevEco hdc.exe>` and `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` |
| Read-only HDC observer (`ARKDECK_HDC_PATH` + `ARKDECK_HDC_SHA256`) | yes. It observes an existing server and answers `device candidates`; `target adopt` and every Job need the managed HDC | refused beside a development root |
| Device mutation authority (`deviceMutation`, `destructive`) | yes, over its own `jobs-state` | **no**. Its proof is pinned to the account's `jobs-state`, and `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY` refuses the start |
| Signing credential owner (GJ-5) | yes, Credential Manager bound to the daemon image | no |
| Counts as phase A evidence | yes | no (rehearsal only) |

So every WIN-GJ row waits for **gap G1**: the account daemon must select the registered HDC and
start it as its managed server. That is the Windows tool-selection owner port, which is in
flight. The `runtime tool register --kind hdc` registry already admits the `c2` digest into
`%LOCALAPPDATA%\ArkDeck\Bootstrap\v1`; nothing selects it into a running daemon yet. When G1
lands, §4.0.3 step 3 below is how the HDC is selected. Until then, a Journey may be rehearsed on
a development root (§4.0.5), but that rehearsal is never a row result.

#### 4.0.2 Install and configure (agent; maintainer gate for the pin)

1. **Install.** Unpack the RC xcopy zip (§1.2 or §1.3) into a new directory.
   - There is no `runtime service install|update` on Windows (`unsupportedOnPlatform`,
     decision 11, ruling 78). The first CLI call starts the daemon.
   - The headless runbook's §1 update path (`runtime bundle register` → `runtime service update`)
     is replaced by reinstalling the RC.
2. **Configure.** Set the environment **in the PowerShell session that will start the daemon**.
   The client-started daemon inherits that environment (minus `ARKDECK_ENDPOINT`). If a daemon is
   already running, stop it first with `arkdeck runtime service restart` from this session, then
   check `runtime service status`.

   ```powershell
   $rc = 'D:\ArkDeck-rc-<date>'
   $env:ARKDECK_DAEMON_PATH = "$rc\arkdeck-agentd.exe"
   # development RC (§1.1): the signer pin
   $env:ARKDECK_DAEMON_SIGNER_SHA256 = '<pin>'
   # or production RC (§1.3): both, never one
   # $env:ARKDECK_DAEMON_PUBLISHER_ORGANIZATION = '<O=>'; $env:ARKDECK_DAEMON_PUBLISHER_EKU = '1.3.6.1.4.1.311.97.<profile>'
   Set-Alias arkdeck "$rc\bin\arkdeck.exe"
   ```

   Leave every `ARKDECK_DEVELOPMENT_*` variable unset. A development variable on the account
   daemon refuses the start.
3. **The registered HDC.** The DevEco Studio 26.0.0.43 `sdk\default\openharmony\toolchains\hdc.exe`
   is the only registered Windows tuple (CHG-2026-078; `c2`, 3.2.0g, SHA-256
   `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e`, `127.0.0.1:8710`).
   - Register it once into the account's Bootstrap registry:

     ```powershell
     arkdeck runtime tool register --kind hdc --file '<DevEco>\sdk\default\openharmony\toolchains\hdc.exe' --output json
     arkdeck runtime tool list --output json
     ```

   - Any other `hdc.exe` is `admissionDenied`, including the one on `PATH` (c1, 3.2.0x).
   - **G1:** the selection into the account daemon goes here once the tool-selection port lands
     (`runtime tool select --tool <ref> --expected-active-generation <n> --action-request-id <id>`,
     today Swift's no-owner refusal on every Rust composition, or the composition that port
     defines). Until then, `runtime hdc status` answers `unconfigured` on the account daemon, and
     the rows stop at §4.0.3.
4. **Paths.** Raw outputs go in `$out` (§0), and inputs in `$out\inputs\`. `--file`,
   `--destination` and every path in an inputs file take `X:\…` drive paths.

#### 4.0.3 Fixed facts (agent, every window)

Read these values and record them. Never copy them from memory or from an earlier window
(headless runbook §0 table):

```powershell
arkdeck --version --output json                                   # buildIdentity
arkdeck doctor --deep --require-healthy --output json --control-request-id gjw-doctor
arkdeck runtime service status --output json                      # daemon image, signer or publisher
arkdeck runtime hdc status --output json --control-request-id gjw-hdc
arkdeck runtime tool list --output json --control-request-id gjw-tools
arkdeck operation list --output json --control-request-id gjw-ops # catalogDigest + availability
```

Expected:

- `doctor` ends `ok: true`, with `hdc.identityObserved` and `arkDeckManaged`.
- `runtime hdc status` shows `availability: available` with the `c2` digest and
  `newDispatchCount: 0`. `serverHealth` stays `unknown`
  (`hdc.commandlessIdentityDoesNotProveHealth`); that is expected and not a failure.
- `operation list` shows the Journey's operations `available`. An operation that is not
  available stops only the Journeys that use it. Its reason code is recorded verbatim.

#### 4.0.4 Board and host (maintainer)

- The DAYU200 is connected **directly** (no hub) to one fixed port, in HDC-normal mode, with
  the image named in the row (OpenHarmony 7.0.0.37 for the published fixtures).
- DevEco Studio and every other HarmonyOS tool are **closed**. Nothing else listens on 8710; if
  something does, close its owner normally (§0). The daemon refuses an endpoint that is already
  held and names the holder.
- Optional host-fact check, read-only, recorded as a host fact, not as row evidence:
  `& '<DevEco>\…\hdc.exe' -v` and `list targets -v` **before** the daemon starts. Never `kill`,
  `start`, `tmode`, `install`, `shell` or `file send`.

#### 4.0.5 Rehearsal on a development root (agent; not row evidence)

Until G1 lands, a read-only Journey step can be rehearsed against the registered `hdc.exe` with a
development-signed daemon. This is the `windows_hdc_live_process.rs` setup, run on 2026-10-04 for
`device candidates` and `target adopt`:

```powershell
$env:ARKDECK_DEVELOPMENT_STATE_ROOT = '<a new directory outside %LOCALAPPDATA%\ArkDeck>'
$env:ARKDECK_DEVELOPMENT_HDC_PATH   = '<DevEco>\sdk\default\openharmony\toolchains\hdc.exe'
$env:ARKDECK_DEVELOPMENT_HDC_SERVER = 'managed'
```

A development root holds no device mutation authority, so GJ-2..5 cannot be rehearsed there.
Rehearsal results go in the run note under "rehearsal", never into the `gj-headless-rerun`
record.

#### 4.0.6 How a row becomes `REAL_DEVICE_PASS`

No person writes `REAL_DEVICE_PASS`. The Runtime produces every fact a row is judged on:

- each Job's `terminalState`, `outcomeUnknown`, `blockers`, `actualStepKinds`,
  `outstandingResidueCount` and `humanActions`;
- each Artifact's digest-checked read;
- the RuntimeCapability references;
- the Catalog digest.

The agent saves the CLI's JSON for every step under `$out`. It then assembles the redacted record
from those saved outputs only:

- SHA-256s, IDs, counts and UTC times;
- no connect key, serial, path or account.

The `state` field is derived mechanically: `REAL_DEVICE_PASS` when every criterion of that
Journey's headless runbook section holds on the read values and the digest equals
`operation list`'s, and otherwise the first failing criterion with its raw value. The record is
reviewed and merged by the maintainer. No repository script generates it yet (**gap G9**), so
the agent applies the criteria by hand from the saved JSON and lists, per criterion, the saved
file it read.

Never:

- edit a Runtime record, a capability or evidence;
- replay an unknown;
- mark a row passed from a fixture, a rehearsal or an older digest.

### 4.1 GJ-1 Device Observe (WIN-GJ1-001)

- **Gates:** §4.0 complete. G1.
- **Maintainer:** board connected (§4.0.4). Unplug and replug **at the agent's call** for §2.1
  of the headless runbook, into the **same** port.
- **Agent, in order** (headless runbook §2 and §2.1; commands unchanged):
  1. `device candidates`.
  2. `target adopt --candidate <key> --observation <id> --observation-generation <n>` if not
     adopted.
  3. `target show` and `target availability`.
  4. `agent run --operation observe.device@1 --target <TGT> --execution-id gj1-<date>
     --maximum-wait 5m`, then `agent status`, `job result`, `job evidence`, `artifact list`, and
     `artifact read` for each Artifact.
  5. `runtime service verify --job <observe-job>`.
  6. `capture.diagnostics@1` with `gj1-capture.json` `{ "durationSeconds": 5 }`, then
     `job evidence`, `artifact list` and `artifact read`.
  7. `runtime service restart`, then `job show` and `job result` for **both** Jobs.
  8. §2.1 HAR crash-resume:
     1. The maintainer unplugs the board.
     2. The agent runs `agent run --operation observe.device@1` without `--target`; expect exit 75
        and `newDispatchCount: 0`.
     3. The agent discards that stdout.
     4. The maintainer replugs the board.
     5. Using only the execution ID: `agent status`, `human-action list --owner-kind
        agentExecution --owner <exec>`, `human-action show`, `agent resume --resume-reference
        <ref>`, then `job result`.
- **Windows specifics:**
  - The stable identity is the SHA-256 of the USB instance-ID serial (rulings 11 and 79). It must
    not change across the replug. `target show`'s `stablePhysicalIdentitySha256` and
    `bindingRevision` are recorded before and after.
  - The topology hash is valid only within one attachment, so it may change. It is recorded
    redacted.
- **Records:** observe Job, capture Job, HAR execution, `humanActions`, both reads after the
  restart.
- **Destructive:** none. Every effect is `readOnly`.
- **Software readiness:** `device candidates` and `target adopt` were measured live on a
  development root (2026-10-04). `target observe` and `diagnostics capture` were measured against
  the fake HDC (#2518).
- **Blocking gaps:** G1. G2 for `observe.device@1` on the real tuple: `probeHDCServer` lowers to
  the commandless observation (#2509), and `observe.device@1` and `capture.diagnostics@1` have
  not yet run once against the real `hdc.exe`.

### 4.2 GJ-2 HAP Debug (WIN-GJ2-001)

- **Gates:**
  - WIN-GJ1-001 passed on the same digest.
  - G1.
  - `debug.hap@1` `available` on the account daemon.
- **Input (maintainer supplies):** the same signed single-entry HAP as the macOS round, plus its
  `bundleName` and `abilityName`, in `$out\inputs\`.
- **Agent:** headless runbook §3, unchanged:
  1. `artifact import hap --import-request-id gj2-<date>-entry --target <TGT> --file
     $out\inputs\entry-signed.hap`.
  2. `artifact import inspect`.
  3. `gj2.json` (§3's shape).
  4. `agent run --operation debug.hap@1 … --execution-id gj2-<date> --maximum-wait 10m`.
  5. `job wait`, `job result`, `job evidence`, `artifact list`.
- **Authority:** `deviceMutation`. The account daemon generates, reserves and consumes the
  RuntimeCapability from the materialized plan (`POL-AGENT-002`). The agent never passes
  `--capability`, and no human confirmation stands in for it.
- **Destructive:** no. A device mutation (install and uninstall of the test HAP) inside the
  maintainer's device window.
- **Software readiness:** 63/63 Swift exchanges and 108 HDC calls replayed end to end through
  the real CLI and the signed test daemon (#2505), against the fake HDC.
- **Blocking gaps:** G1 (the account daemon has the mutation authority but no HDC).

### 4.3 GJ-3 Native Debug (WIN-GJ3-001)

- **Gates:**
  - WIN-GJ2-001 passed on the same digest.
  - G1.
  - `deploy.native-library.app-owned@1` `available`.
  - The code-sign helper is composed: the census line includes `codeSignHelper`, and `doctor`
    does not print `native deployment stays unavailable`.
- **The helper:** the package installs it at
  `<rc>\ArkDeckKit_ArkDeckWorkflows.bundle\OpenHarmonyNativeCodeSign\arkdeck-code-sign-enable`
  (214 016 bytes, SHA-256 `86497e1a…f5c1`, pinned in the RC manifest). There is no configuration
  for it; `ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER` is refused.
- **Inputs (maintainer supplies):**
  - the signed `armeabi-v7a` `.so`, `targetBundle` and `libraryLogicalName`;
  - **the rollback fixture**: the signed fixture checked for the current target. The macOS round
    pinned SHA-256 `260a533a…6d3a` (`runs/TASK-XPA-003/run.md`); the agent records its digest and
    checks the ABI before use.
- **Agent:**
  1. Headless runbook §4: `artifact import native-library`, `gj3.json`,
     `agent run --operation deploy.native-library.app-owned@1`, `job wait`, `job evidence`.
  2. The rollback leg, as a separate execution with the rollback fixture.
- **Authority:** `deviceMutation`, a Runtime-issued capability as in GJ-2.
- **Destructive:** no (app-owned library). The rollback leg is a device mutation that the
  Runtime itself reverts.
- **Software readiness:** 40/40 exchanges and 225 HDC calls replayed end to end (#2505).
- **Blocking gaps:**
  - G1.
  - G3: no Windows tooling checks the rollback fixture's applicability to the current target. The
    agent does it by hand from `artifact import inspect` and the target's ABI. Without an
    applicable fixture the rollback leg stays unverified, as the headless runbook says.

### 4.4 GJ-4 Flash Recovery (WIN-GJ4-001) — **destructive**

- **Maintainer gates** (all needed, in this order):
  1. The maintainer authorises this window per HardwareCampaign (agent prompt §1.1), and names
     the campaign. Every flash step below is **destructive**.
  2. AF-W1 is green: ArkForge's Windows acceptance on a real Windows host. This is an external
     dependency, and it is still `blocked` (`tasks.md` TASK-XPA-010).
  3. The ArkForge Windows bundle (`bin\arkforged.exe`, `bin\arkforge.exe`, the
     `org.openharmony.dayu200` profile) is validated and its path is given to the agent.
- **Configuration** (replaces the macOS `runtime service update --arkforge-*`, which Windows
  does not have). Set it in the daemon-starting session (§4.0.2), then restart the daemon from
  that session:

  ```powershell
  $env:ARKDECK_ARKFORGE_BUNDLE_PATH = '<absolute path to the validated ArkForge.bundle>'
  $env:ARKDECK_ARKFORGE_CAMPAIGN    = 'gj4-<date>'   # the maintainer-named campaign; omit to stay assessment-only
  arkdeck runtime service restart --output json
  arkdeck runtime service status --output json
  arkdeck operation list --output json
  ```

  - The retired `ARKDECK_ARKFORGED_PATH`, `ARKDECK_ARKFORGED_SHA256` and
    `ARKDECK_ARKFORGE_PROFILE_PATH` are refused at the start.
  - Without a campaign, the lane is assessment-only (`hardwareGated`) and nothing flashes.
  - To end the staging, clear `ARKDECK_ARKFORGE_CAMPAIGN`, restart, and read back.
- **Input (maintainer supplies):** `OpenHarmony-7.0.0.37` archive, SHA-256
  `4fd35765…c674` (730 783 514 bytes).
- **Agent:** headless runbook §5:
  1. `flash device-access`, `flash bootloader-status`, `flash prerequisites --target <TGT>
     --device-profile dayu200`.
  2. **`flash install-binding`: see G4.**
  3. `artifact import flash-bundle … --device-profile dayu200`.
  4. `flash lane-preview … --archive-sha256 4fd35765…c674`.
  5. `flash bind-loader --target <TGT> --expected-binding-revision <n>`.
  6. `gj4.json`, then `agent run --operation flash.full-restore@1 --target <TGT> --inputs-file
     gj4.json --execution-id gj4-<date> --maximum-wait 30m`. **Destructive**: the Runtime
     issues the capability only from fresh facts and the full plan.
  7. `job wait`, `job evidence`.
  8. Postflight: `device candidates`, `target show` (record the new binding revision),
     `agent run --operation observe.device@1`.
- **Maintainer during the run:**
  - Board physical actions only when the Runtime publishes a human action. Each is consumed with
    `agent resume`.
  - Never a manual Loader entry outside a published action.
- **Stop rule:** stop at the first missing proof. An unknown stays unknown, and nothing is
  replayed or forced.
- **Software readiness:**
  - Lane launch and pairing, plan, admission, run and reconcile are proved against fakes (#2504).
  - The recovery broker is composed (#2519).
  - No real `arkforged.exe` has run.
- **Blocking gaps:**
  - G1.
  - G4: `flash install-binding` is macOS-only (`flash_leaves.rs` `cfg(target_os = "macos")`), so
    the cross-mode binding cannot be established on Windows. This blocks a first takeover. A board
    whose binding already exists on this host is not a Windows case.
  - G5: AF-W1.
  - G6: `flash device-access`, `flash lane-preview` and `flash bind-loader` have not been
    measured through the CLI on Windows.

### 4.5 GJ-5 Bounded AI Debug Loop (WIN-GJ5-001)

- **Gates:**
  - WIN-GJ2-001 passed on the same digest.
  - G1.
  - The workspace Jobs `available` on the account daemon. Workspace mutations, build, test and
    signing need the account daemon: a development root composes neither mutation authority nor
    signing.
- **Host prerequisites (maintainer):**
  - DevEco Studio installed. Its install shape is confirmed by the WM3 crib
    (`runs/TASK-XPA-011/deveco-windows-install-shape-crib-20260930.md`).
  - Git for Windows installed machine-wide at `C:\Program Files\Git` (ruling 69: `mingw64\bin\git.exe`
    signed by its publisher; a per-user install is refused).
  - `System32\tar.exe` present (Windows ships it).
- **Toolchain and project (agent):**

  ```powershell
  arkdeck runtime tool register --kind deveco --root '<DevEco Studio dir>' --output json
  arkdeck runtime tool list --output json
  arkdeck workspace project register --registration-request-id gj5-<date>-project --kind openharmony --root '<project X:\…>' --output json
  arkdeck workspace preset register --registration-request-id gj5-<date>-build --project <ref> --kind build --template <template> --toolchain <toolchain ref> --toolchain-generation <n> --module <module> --product <product> --build-mode <mode> --timeout-seconds 900 --output json
  ```

  - The DevEco launcher must be Huawei-signed, and `node.exe` OpenJS-signed. Node and hvigor
    are never taken from `PATH`.
- **Signing credential: maintainer gate.**
  - It is installed **at the console**, because the secret is typed by the maintainer. The
    agent never sees it, and it never goes in argv or the environment.
  - `--build-profile` and `migrate-deveco` are `unsupportedOnPlatform` on Windows (they would read
    DevEco's encrypted password material). The maintainer therefore gives the explicit paths:

    ```powershell
    arkdeck runtime signing install --java '<DevEco>\jbr\bin\java.exe' `
      --jar '<DevEco>\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar' `
      --keystore '<storeFile .p12>' --certificate '<certpath .cer>' --profile '<profile .p7b>' `
      --key-alias debugKey --project-ref <ref> --output json
    # prompts: Keystore password, Key password (echo off)
    arkdeck workspace preset register --registration-request-id gj5-<date>-sign --project <ref> --kind signing --template openharmony.local-sign@1 --credential <credential> --timeout-seconds 600 --output json
    arkdeck runtime service restart --output json
    ```

  - The material is the DevEco **debug** signing of this board (device-ids include its UDID). The
    sample `install-sdk-release` material is rejected by the board (`9568329`).
  - The daemon image must satisfy the signing pin before Credential Manager is opened.
- **Inputs (maintainer supplies):**
  - the crash-probe fixture project and its signed HAP;
  - the fixed patch `gj5-fix.patch` (headless runbook §1).
- **Agent:** headless runbook §6 in full:
  1. repro;
  2. `analyzer.extract-crash-signature@1`;
  3. isolate, then `artifact import workspace-patch` and `workspace.apply-patch@1`;
  4. build, sign, `artifact export`, re-import;
  5. verify;
  6. the zero-dispatch negative case, with the full Job-set comparison.
- **Authority:** the repro and verify `debug.hap@1` steps are `deviceMutation`. The workspace
  mutations need the account daemon's authority.
- **Destructive:** none.
- **Software readiness:**
  - The reads, isolate and sweep are measured (#2500), and patch, checkpoint and revert are in
    flight (#2506).
  - The sign Job replays the Swift oracle (#2495), and signing through a registered preset is
    measured (#2508, open).
  - The hvigor build has not run on Windows.
- **Blocking gaps:**
  - G1.
  - G7: the hvigor build and test Jobs have not been measured on Windows.
  - G8: the signing passwords must be known in plaintext. Windows cannot decode DevEco's stored
    ones (`migrate-deveco` is unsupported), so the maintainer must know the debug keystore's
    passwords or re-create the debug signing material in DevEco with known ones.
  - `hap-sign-tool.jar` carries Mark-of-the-Web (ZoneId=3) in the sampled install. Whether it
    affects the signer has not been observed; record it.

### 4.6 Gaps that block rows

| Gap | What | Blocks | Owner |
| --- | --- | --- | --- |
| G1 | The account daemon does not select and start the registered `c2` HDC (the Windows tool-selection owner); only a development root composes the managed HDC, and it holds no mutation authority | WIN-GJ1..5 | tool-selection port, in flight |
| G2 | `observe.device@1` and `capture.diagnostics@1` not yet run once against the real `hdc.exe` (fake only; `probeHDCServer` lowered to the commandless observation, #2509) | WIN-GJ1 (risk, not a stop) | first rehearsal after G1 |
| G3 | No tooling checks the native rollback fixture's applicability to the current target | WIN-GJ3 rollback leg | agent at run time; tooling optional |
| G4 | `flash install-binding` is macOS-only | WIN-GJ4 first takeover | TASK-XPA-010 |
| G5 | AF-W1 (ArkForge Windows acceptance) | WIN-GJ4 | external, maintainer |
| G6 | `flash device-access`, `lane-preview`, `bind-loader` not measured through the CLI on Windows | WIN-GJ4 (risk) | TASK-XPA-010 |
| G7 | hvigor build and test Jobs not measured on Windows; workspace mutations in flight (#2506) | WIN-GJ5 | TASK-XPA-011 |
| G8 | Signing passwords must be known in plaintext; `--build-profile`/`migrate-deveco` unsupported | WIN-GJ5 | maintainer (material), or a ruling |
| G9 | No generator assembles the redacted `gj-headless-rerun` record from saved CLI JSON; the agent applies the criteria by hand (§4.0.6) | none (process) | optional tooling |

### 4.7 Readiness per row (main `982d4e6d`)

| Row | Software path on Windows | Real-device blockers | Maintainer gate | Destructive |
| --- | --- | --- | --- | --- |
| WIN-GJ1-001 | candidates and adopt live on a development root; observe and capture on the fake (#2518) | G1 (G2 risk) | board window; unplug and replug | no |
| WIN-GJ2-001 | full oracle replay end to end (#2505) | G1 | device window; HAP input | no (device mutation) |
| WIN-GJ3-001 | full oracle replay end to end (#2505); helper packaged | G1, G3 | device window; `.so` and rollback fixture | no (device mutation) |
| WIN-GJ4-001 | lane, plan, run, reconcile on fakes (#2504); broker (#2519) | G1, G4, G5, G6 | HardwareCampaign go; ArkForge bundle; image archive | **yes** (`flash.full-restore@1`) |
| WIN-GJ5-001 | reads, isolate, sweep measured; sign replayed; patch (#2506) and registered signing (#2508) in flight | G1, G7, G8 | DevEco install; console secret entry; inputs | no (device mutation) |

None of the rows can produce `REAL_DEVICE_PASS` before G1 is on `main`.

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

| # | Step | State on `main` `982d4e6d` | Blocked on |
| --- | --- | --- | --- |
| 1 | §1.1 dev signer check | open (maintainer) | — |
| 2 | §2 HDC and USB samples, WHR-001..003 | **done** | — |
| 3 | §1.2 dev MSIX publisher, §3 SPK-3 rows 1–5 | open (maintainer) | certificate creation, second account, elevated terminal, second host |
| 4 | G1: the account daemon selects and starts the registered HDC | in flight (agents) | the Windows tool-selection port |
| 5 | §4.1 GJ-1, §3 row 6 | blocked | step 4 |
| 6 | §4.2 GJ-2, §4.3 GJ-3 | blocked | step 4 (GJ-3 also G3) |
| 7 | §4.5 GJ-5 | blocked | step 4, G7 (agents), G8 (maintainer material) |
| 8 | §1.3 production signing | open (maintainer) | Artifact Signing account |
| 9 | §4.4 GJ-4 | blocked | step 4, G4 (agents), G5 AF-W1, the maintainer's HardwareCampaign go |
| 10 | §5 clean-host smoke | open | step 8 |
| 11 | §6 flip | blocked | everything above recorded |
