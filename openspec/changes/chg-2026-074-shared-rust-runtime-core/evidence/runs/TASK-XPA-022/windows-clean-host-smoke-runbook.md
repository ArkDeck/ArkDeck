# TASK-XPA-022 — Windows clean-host smoke runbook (maintainer-run)

Phase A item of the Windows phase (`docs/design/cross-platform/windows-phase-agent-prompt.md`, "阶段 A": "干净主机 smoke").
The agent wrote these steps. **The maintainer runs them** on a clean host with a
production-signed release candidate. The agent does not sign, does not hold a credential, and
only processes the record that is handed back.

This runbook details §5 of `docs/design/cross-platform/windows-phase-a-runbook.md`. Where the two
differ, the steps here apply, and they say why. A production RC cannot be smoked with
`package-rc.ps1 -SmokeZip` yet: the script refuses it because the App has no publisher pin. And
the MSIX daemon's package identity is unsettled. Both points are under "Current limits".

A clean-host PASS is evidence for the packaging exit condition 7. It is not GJ acceptance and not
device evidence: this runbook never connects a board and never runs `hdc`.

## What "clean" means

- A **fresh Windows 11 x64** installation, for example a new VM from Microsoft's evaluation
  image. It is fully updated, and nothing of ArkDeck, DevEco Studio, a development certificate,
  Rust, .NET or PowerShell 7 is installed beyond what the steps below add.
- A **standard (non-administrator) user** for every step except the ones marked *(admin)*.
- **No development trust.** `CN=ArkDeck Development Daemon (host-trusted only)` and
  `CN=ArkDeck Development` must not be in any store. The package must verify through its
  production signature alone.

## Inputs

From the maintainer's production signing run on the reference host, built from one clean
revision of `main`:

```powershell
pwsh windows/scripts/package-rc.ps1 -OutputDirectory <out> -SigningMode production `
  -ProductionSignCommand <sign-file wrapper> -MsixSignCommand <sign-msix wrapper> `
  -FeedBaseUri https://<feed host>/arkdeck/windows/
```

That run produces:

- `arkdeck-rc-<version>-windows-x64-<revision>.zip`, the xcopy form;
- `ArkDeck.App_<version>_x64.msix`, the MSIX form, signed. Its signer's subject must equal the
  manifest `Publisher`; the script refuses otherwise;
- `ArkDeck.appinstaller`, the App Installer feed of that MSIX;
- `rc-manifest.json`, with every file's SHA-256, the zip's and the MSIX's SHA-256, the publisher
  identity and the `daemonConfiguration`.

Host the feed and the MSIX at the URIs recorded in `rc-manifest.json` (`msix.appInstaller.uri`,
`msix.appInstaller.mainPackageUri`). Copy the zip and `rc-manifest.json` to the clean host by
any means.

Current limits that shape the steps:

- **The App's publisher pin (ruling 17) is not implemented yet.** The App reads only
  `ARKDECK_DAEMON_SIGNER_SHA256` or `ARKDECK_DAEMON_PACKAGE_FAMILY`.
  - The xcopy App is therefore pinned for this smoke by the daemon's leaf SHA-256 (step 4).
    That pin stays valid only until the next signing, since Artifact Signing leaves last 72
    hours.
  - The MSIX App is pinned by its package family.
- **The packaged daemon's identity is not settled.** A process has a package family only if it
  was activated with package identity. A CLI outside the package that starts
  `<InstallLocation>\arkdeck-agentd.exe` directly starts it *without* one, so a
  package-family pin cannot hold. How the MSIX daemon is started with its package identity is
  an open XPA-022 design point: for example, a `desktop4`/`uap5` execution alias for the
  daemon, or the App launching it as a full-trust process. Until it is settled, expect step 8
  to refuse with a package-family mismatch, and record that rather than working around it.
- **Neither the CLI nor the App starts a daemon of another package form.** Run the xcopy smoke
  and the MSIX smoke one after the other, never side by side (they share
  `%LOCALAPPDATA%\ArkDeck\Agentd`, ruling 8).

## Steps

### 1. Record the host (standard user)

```powershell
Get-ComputerInfo -Property OsName, OsVersion, OsBuildNumber, OsArchitecture, WindowsInstallDateFromRegistry
whoami /groups | Select-String -Pattern 'S-1-5-32-544'   # expect: no row, or "Deny only"
Get-ChildItem Cert:\CurrentUser\Root, Cert:\LocalMachine\Root, Cert:\CurrentUser\My |
  Where-Object Subject -like '*ArkDeck*'                 # expect: nothing
Test-Path "$env:LOCALAPPDATA\ArkDeck"                     # expect: False
```

Write down the OS build and the time. Do not record the machine or account name.

### 2. Verify the downloads (standard user)

```powershell
$rc = Get-Content .\rc-manifest.json -Raw | ConvertFrom-Json
(Get-FileHash .\$($rc.zip.name) -Algorithm SHA256).Hash.ToLower() -eq $rc.zip.sha256   # True
$rc.signing.mode                                                                      # production
```

### 3. Xcopy form: install (standard user)

Unzip into a folder of your own, for example `%LOCALAPPDATA%\Programs\ArkDeck-RC`. Windows
marks files from the internet (Mark of the Web); keep them marked, since that is what users
will have.

```powershell
$install = "$env:LOCALAPPDATA\Programs\ArkDeck-RC"
Expand-Archive .\$($rc.zip.name) -DestinationPath $install
$root = Get-ChildItem $install -Directory | Select-Object -First 1 -ExpandProperty FullName
foreach ($f in $rc.files) {
  if ((Get-FileHash (Join-Path $root $f.path) -Algorithm SHA256).Hash.ToLower() -ne $f.sha256) { "MISMATCH $($f.path)" }
}                                                                                     # expect: no output
Get-AuthenticodeSignature "$root\ArkDeck.exe", "$root\arkdeck-agentd.exe", "$root\bin\arkdeck.exe" |
  Format-Table Status, SignerCertificate, TimeStamperCertificate                      # expect: Valid, timestamped
```

### 4. Xcopy form: first start through the CLI (standard user)

```powershell
$env:ARKDECK_DAEMON_PUBLISHER_ORGANIZATION = $rc.daemonConfiguration.ARKDECK_DAEMON_PUBLISHER_ORGANIZATION
$env:ARKDECK_DAEMON_PUBLISHER_EKU          = $rc.daemonConfiguration.ARKDECK_DAEMON_PUBLISHER_EKU
$env:ARKDECK_DAEMON_PATH                   = "$root\arkdeck-agentd.exe"
& "$root\bin\arkdeck.exe" --output json doctor          # expect: exit 0, "ok": true (it starts the daemon)
& "$root\bin\arkdeck.exe" --output json runtime service verify   # expect: exit 0, "runtimeVerified": true
Get-Content "$env:LOCALAPPDATA\ArkDeck\Agentd\instance.json"     # the daemon's PID and pipe
```

Then check the negative: in a new window without the two publisher variables, `arkdeck doctor`
must refuse the daemon (exit 69), never answer.

### 5. Xcopy form: the App (standard user)

The App is pinned by the daemon's leaf SHA-256 for now (see "Current limits"):

```powershell
$leaf = (Get-AuthenticodeSignature "$root\arkdeck-agentd.exe").SignerCertificate
$env:ARKDECK_DAEMON_SIGNER_SHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($leaf.RawData)).ToLower()
Start-Process "$root\ArkDeck.exe"
```

Expect the Overview page to show the daemon's doctor report (`blocked`, no HDC on this host) and
protocol `1.0.0`, with **no** recovery banner. Device shows `unavailable(rejected): hdc…`. Close
the App. Screenshot the Overview page without account names.

### 6. Xcopy form: uninstall (standard user)

From a checkout of the same revision, or the script copied from it:

```powershell
pwsh -NoProfile -File .\windows\scripts\uninstall-rc.ps1 -InstallDirectory $root
```

Expect JSON with `"removed": true` and `"daemon": { "running": true, "exited": true }`, and `kept`
listing `ArkDeck\Agentd: true`. Then:

```powershell
Test-Path $root                                           # False
Get-Process arkdeck-agentd, ArkDeck -ErrorAction SilentlyContinue   # nothing
Remove-Item "$env:LOCALAPPDATA\ArkDeck" -Recurse          # the kept state, removed by hand for the next form
```

### 7. MSIX form: install through App Installer (standard user)

Open `https://<feed host>/arkdeck/windows/ArkDeck.appinstaller` in the browser, or run
`Add-AppxPackage -AppInstallerFile <uri>`. App Installer must show the publisher from the
certificate with no warning, and install without elevation.

```powershell
Get-AppxPackage -Name <msix.identityName> | Format-List Name, Publisher, Version, PackageFamilyName, InstallLocation, SignatureKind
```

`SignatureKind` should be `Developer` or `Store`, never `None`. Write down `PackageFamilyName`.

### 8. MSIX form: first start and the App (standard user)

The packaged App finds its daemon beside it and pins it by the package family:

```powershell
$pkg = Get-AppxPackage -Name <msix.identityName>
$env:ARKDECK_DAEMON_PACKAGE_FAMILY = $pkg.PackageFamilyName
$env:ARKDECK_DAEMON_PATH = Join-Path $pkg.InstallLocation 'arkdeck-agentd.exe'
& (Join-Path $pkg.InstallLocation 'bin\arkdeck.exe') --output json doctor   # see "Current limits": a package-family refusal is the expected answer today
```

Start ArkDeck from the Start menu and expect the same Overview as in step 5. Then confirm ruling 8:
`Test-Path "$env:LOCALAPPDATA\ArkDeck\Agentd\instance.json"` must be `True`, which is the
physical, unvirtualized path.

### 9. MSIX form: update through the feed (standard user, optional)

If the maintainer has published a higher package version to the same feed, restart the App. App
Installer checks on launch (`HoursBetweenUpdateChecks="0"`, `ShowPrompt="true"`); accept the
prompt, and `Get-AppxPackage` must show the new version. Skip this step if no second version
exists.

### 10. MSIX form: uninstall (standard user)

```powershell
pwsh -NoProfile -File .\windows\scripts\uninstall-rc.ps1 -PackageName <msix.identityName>
Get-AppxPackage -Name <msix.identityName>                 # nothing
```

### 11. Hand back

Send the agent:
- the OS build;
- every command's result as expected or not, with the actual output where it differed;
- the `doctor` and `verify` JSON, with the pipe name and the PIDs as they are, since they carry
  no account data;
- the screenshots.

Remove account and machine names first. The agent writes the sanitized run record
`windows-clean-host-smoke-<date>-run.md` next to this runbook.

## What would stop the smoke

- Any hash mismatch.
- A signature that is not `Valid`, or not timestamped.
- A SmartScreen or App Installer warning other than the normal reputation prompt for a new
  publisher.
- A step that needs elevation.
- The CLI answering with the publisher variables absent.
- The App showing data while pinned to another daemon.

Report the step and stop; do not work around it on the host.
