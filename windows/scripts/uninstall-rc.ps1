#requires -Version 7.2
<#
.SYNOPSIS
Uninstalls a Windows release candidate of ArkDeck (CHG-2026-074 TASK-XPA-022): the xcopy form
built by windows/scripts/package-rc.ps1, or the MSIX form.

.DESCRIPTION
Xcopy form (-InstallDirectory):

  1. The directory must hold a package-rc.ps1 manifest (`rc-manifest.json`,
     arkdeck.windows-rc-package/1); anything else is refused, so no other directory is removed.
  2. If the daemon runs from that directory (the pid its instance document names runs the
     installed `arkdeck-agentd.exe`; a daemon of another installation is left alone), it is
     stopped by the installation's own CLI, `bin\arkdeck.exe runtime service uninstall`, pinned
     to that image and its signer certificate: the CLI proves the daemon's identity on its pipe,
     refuses while a Runtime Job is active or unclosed (exit 75), asks it to stop through its
     own stop event and awaits its single-instance guard. Any other answer of the CLI refuses
     the uninstall. An unsigned image, which no CLI can prove, is asked to stop through its stop
     event directly (the account daemon's `Local\ArkDeck.Agentd.<user SID>.Stop.<pid>`, or a
     development root's with -DevelopmentStateRoot), and its exit is awaited. Nothing else is
     signalled and no process is ever killed.
  3. Any other process still running from the directory (the App, a CLI) refuses the uninstall:
     close it and run again.
  4. The directory is removed.

Kept, and listed in the answer: the daemon's state (%LOCALAPPDATA%\ArkDeck\Agentd, or the
development root), the signing preset root (%LOCALAPPDATA%\ArkDeck\Signing\OpenHarmony) and
its Credential Manager items. Remove a signing credential with `arkdeck runtime signing remove`
before uninstalling; state is never removed by this script.

MSIX form (-PackageName, e.g. ArkDeck.Development): the same stop of a daemon running from the
package's install location, the same refusal while the App runs, then Remove-AppxPackage for
this user (no elevation). The package's own data is removed by Windows; the unvirtualized
%LOCALAPPDATA%\ArkDeck (ruling 8) is kept as above.

The answer is one JSON document on stdout. It never sleeps to synchronise: it waits on the
daemon's exit.
#>
[CmdletBinding(DefaultParameterSetName = 'Xcopy')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Xcopy')][string]$InstallDirectory,
    [Parameter(ParameterSetName = 'Xcopy')][string]$DevelopmentStateRoot,
    [Parameter(Mandatory, ParameterSetName = 'Msix')][string]$PackageName,
    [ValidateRange(1, 300)][int]$StopTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Schema = 'arkdeck.windows-rc-package/1'
$AnswerSchema = 'arkdeck.windows-rc-uninstall/1'
$DaemonName = 'arkdeck-agentd.exe'

function Get-ProcessesUnder([string]$Directory) {
    $prefix = $Directory.TrimEnd('\') + '\'
    return @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

# The daemon's instance document and its stop event, as InstanceScope names them: the account
# root's `Local\ArkDeck.Agentd.<user SID>.Stop.<pid>`, a development root's
# `Local\ArkDeck.Agentd.Dev.<user SID>.<root id>.Stop.<pid>` (the root id ends its pipe name).
function Get-DaemonInstance([string]$StateRoot, [bool]$Development) {
    $path = Join-Path $StateRoot 'instance.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $instance = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($Development) {
        if ($instance.socketPath -notmatch '-([0-9a-f]{16}-[0-9a-f]{32})$') { throw "The instance document names an unexpected pipe $($instance.socketPath)." }
        $event = "Local\ArkDeck.Agentd.Dev.$user.$($Matches[1]).Stop.$($instance.pid)"
    } else {
        $event = "Local\ArkDeck.Agentd.$user.Stop.$($instance.pid)"
    }
    return [ordered]@{ pid = [int]$instance.pid; stopEvent = $event }
}

# `runtime service uninstall` of the installation's own CLI, with only the inputs that pin the
# installed image: its path and its signer certificate's SHA-256 (as
# rust/scripts/windows-dev-identity.ps1 pins one), over the same state root. Any exit but 0
# refuses: 75 (a Runtime Job is active or unclosed) and 69 (the daemon could not be proved or
# stopped) alike, since the image was already proved to be this installation's.
function Invoke-CliUninstall([string]$Directory, [string]$Image, [string]$Pin, [string]$StateRoot, [bool]$Development, [int]$InstancePid) {
    $cli = Join-Path $Directory 'bin\arkdeck.exe'
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw "$cli is missing, so the daemon $InstancePid cannot be stopped through its CLI; nothing was removed." }
    $saved = @{}
    foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ARKDECK_*' -or $_.Name -like 'OHOS_HDC_*' } | ForEach-Object Name)) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    try {
        $env:ARKDECK_DAEMON_PATH = $Image
        $env:ARKDECK_DAEMON_SIGNER_SHA256 = $Pin
        if ($Development) { $env:ARKDECK_DEVELOPMENT_STATE_ROOT = $StateRoot }
        $errorFile = New-TemporaryFile
        try {
            $stdout = & $cli --output json runtime service uninstall 2> $errorFile.FullName
            $status = $LASTEXITCODE
            $stderr = (Get-Content -LiteralPath $errorFile.FullName -Raw) ?? ''
        } finally { Remove-Item -LiteralPath $errorFile.FullName -Force }
    } finally {
        foreach ($name in @('ARKDECK_DAEMON_PATH', 'ARKDECK_DAEMON_SIGNER_SHA256', 'ARKDECK_DEVELOPMENT_STATE_ROOT')) { [Environment]::SetEnvironmentVariable($name, $null) }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    if ($status -eq 75) { throw "The daemon $InstancePid refused to stop while Runtime Jobs are active or unclosed; nothing was removed. $($stderr.Trim())" }
    if ($status -ne 0) { throw "runtime service uninstall exited $status, so the daemon $InstancePid was not proved stopped; nothing was removed. $($stderr.Trim())" }
    $uninstall = (($stdout -join "`n") | ConvertFrom-Json).result.uninstall
    if ($null -ne $uninstall.stoppedPid -and [int]$uninstall.stoppedPid -ne $InstancePid) { throw "runtime service uninstall stopped $($uninstall.stoppedPid), not the installation's daemon $InstancePid; nothing was removed." }
    return [ordered]@{ running = $true; pid = $InstancePid; stopRequest = 'runtimeServiceUninstall'; stoppedPid = $uninstall.stoppedPid; drain = $uninstall.drain; exited = $true }
}

# Stops the daemon only when it runs the image installed under $Directory.
function Stop-InstalledDaemon([string]$Directory, [string]$StateRoot, [bool]$Development) {
    $instance = Get-DaemonInstance $StateRoot $Development
    if (-not $instance) { return [ordered]@{ running = $false } }
    $process = Get-Process -Id $instance.pid -ErrorAction SilentlyContinue
    $image = Join-Path $Directory $DaemonName
    if (-not $process -or -not $process.Path -or -not $process.Path.Equals($image, [StringComparison]::OrdinalIgnoreCase)) {
        # Another daemon (another installation, or none): not this uninstall's to stop.
        return [ordered]@{ running = $false; instancePid = $instance.pid; note = 'the state root names a daemon that does not run from this installation' }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $image
    if ($signature.Status -eq 'Valid') {
        $pin = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($signature.SignerCertificate.RawData)).ToLowerInvariant()
        return Invoke-CliUninstall $Directory $image $pin $StateRoot $Development $instance.pid
    }
    if ($signature.Status -ne 'NotSigned') {
        throw "The installed daemon image's signature is $($signature.Status); the daemon $($instance.pid) was not stopped and nothing was removed."
    }
    $event = [System.Threading.EventWaitHandle]::OpenExisting($instance.stopEvent)
    try { [void]$event.Set() } finally { $event.Dispose() }
    if (-not $process.WaitForExit($StopTimeoutSeconds * 1000)) {
        throw "The daemon $($instance.pid) did not exit within $StopTimeoutSeconds s of its stop event; nothing was removed. Stop it and run again."
    }
    return [ordered]@{ running = $true; pid = $instance.pid; stopRequest = 'stopEvent'; stopEvent = ($instance.stopEvent -replace 'S-1-5-21-[0-9-]+', '<user SID>'); exited = $true }
}

function Get-KeptState {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $kept = [ordered]@{}
    foreach ($relative in @('ArkDeck\Agentd', 'ArkDeck\Signing\OpenHarmony')) {
        $kept[$relative] = Test-Path -LiteralPath (Join-Path $local $relative)
    }
    if ($DevelopmentStateRoot) { $kept['developmentStateRoot'] = Test-Path -LiteralPath $DevelopmentStateRoot }
    return $kept
}

$answer = [ordered]@{ schemaVersion = $AnswerSchema; form = $PSCmdlet.ParameterSetName }
if ($PSCmdlet.ParameterSetName -eq 'Xcopy') {
    $directory = (Resolve-Path -LiteralPath $InstallDirectory).Path
    $manifestPath = Join-Path $directory 'rc-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "$directory holds no rc-manifest.json; it is not an ArkDeck release-candidate installation, and nothing was removed." }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne $Schema) { throw "$manifestPath is not $Schema; nothing was removed." }
    $answer.sourceRevision = $manifest.sourceRevision
    $stateRoot = if ($DevelopmentStateRoot) { (Resolve-Path -LiteralPath $DevelopmentStateRoot).Path } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ArkDeck\Agentd' }
    $answer.daemon = Stop-InstalledDaemon $directory $stateRoot ([bool]$DevelopmentStateRoot)
    $others = @(Get-ProcessesUnder $directory)
    if ($others.Count -gt 0) {
        throw "Close ArkDeck first; still running from the installation: $(($others | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', '). Nothing was removed."
    }
    Remove-Item -LiteralPath $directory -Recurse -Force
    $answer.removed = -not (Test-Path -LiteralPath $directory)
    if (-not $answer.removed) { throw "$directory could not be removed completely." }
} else {
    $packages = @(Get-AppxPackage -Name $PackageName)
    if ($packages.Count -eq 0) {
        $answer.removed = $false
        $answer.note = "no package named $PackageName is installed for this user"
    } else {
        foreach ($package in $packages) {
            $location = $package.InstallLocation
            $answer.daemon = Stop-InstalledDaemon $location (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ArkDeck\Agentd') $false
            $others = @(Get-ProcessesUnder $location)
            if ($others.Count -gt 0) {
                throw "Close ArkDeck first; still running from the package: $(($others | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', '). Nothing was removed."
            }
            Remove-AppxPackage -Package $package.PackageFullName
            $answer.packageFullName = $package.PackageFullName
        }
        $answer.removed = @(Get-AppxPackage -Name $PackageName).Count -eq 0
    }
}
$answer.kept = Get-KeptState
$answer.keptNote = 'The daemon state and the signing preset root and its Credential Manager items stay; `arkdeck runtime signing remove` removes a signing credential.'
$answer | ConvertTo-Json -Depth 6
