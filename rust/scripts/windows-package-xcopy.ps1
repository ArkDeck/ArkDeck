#requires -Version 7.2
<#
.SYNOPSIS
The xcopy form of the Windows daemon and CLI (CHG-2026-074 TASK-XPA-022, r12 decision 10;
Windows 11 x64 only, r13).

.DESCRIPTION
Build mode (default) builds `arkdeck.exe` and `arkdeck-agentd.exe` from one recorded checkout:

  1. Refuses an existing -OutputDirectory, and a checkout with any change or untracked file
     unless -AllowDirty (recorded in the manifest with the entries it found).
  2. `cargo build --release --locked -p arkdeck-agentd -p arkdeck-cli
     --target x86_64-pc-windows-msvc` in rust/.
  3. Stages both executables side by side (the CLI's default daemon is its sibling).
  4. Signs both (-SigningMode):
       none         nothing is signed; the CLI refuses the daemon (no signer to pin).
       development  rust/scripts/windows-dev-identity.ps1 sign with the host-trusted
                    development certificate (-Thumbprint, else ARKDECK_DEV_SIGNER_THUMBPRINT
                    from the process or HKCU\Environment). Not an installation identity.
       production   an external command the maintainer supplies (-ProductionSignCommand, else
                    ARKDECK_PRODUCTION_SIGN_COMMAND), called once per file with the file path as
                    its only argument. It must sign with a timestamp (for example signtool with
                    the Azure Artifact Signing dlib and /tr); this script holds no credential.
                    Not configured, a failed command or an untimestamped result fails closed.
     Every signed file must then verify (Get-AuthenticodeSignature: Valid), and both must carry
     the same signer; the pin is the SHA-256 of that signer certificate's DER.
  5. Writes manifest.json inside the package (revision, dirty flag, rustc -V, cargo -V, target,
     file SHA-256s, signing mode and signer pin), zips the package, and writes manifest.json
     beside the zip with the zip's SHA-256 added.
  6. Prints the pin the CLI must be configured with (ARKDECK_DAEMON_SIGNER_SHA256).

-Smoke after a build, or -SmokeZip <zip> alone (for example on a clean host), unpacks the zip
into a fresh directory under -SmokeParent, checks every file against the manifest and the
daemon's signer against the pin, and with ARKDECK_DAEMON_SIGNER_SHA256 set to the pin and a
private development state root (ARKDECK_DEVELOPMENT_STATE_ROOT) inside that directory:

  - runs `arkdeck --output json doctor`. A CLI that starts its daemon (decision 11) starts it
    here; otherwise the smoke starts the unpacked daemon itself and waits for its
    `listening on` line, then runs doctor again on the root's pipe (ARKDECK_ENDPOINT from the
    root's instance.json). Doctor must answer `ok: true`: the CLI verified the daemon's
    image path and signer before sending it;
  - runs `arkdeck --output json runtime service verify`, recorded as unavailable when the CLI
    does not serve it on Windows;
  - stops the daemon through its stop path (the root's named stop event, what
    InstanceScope::request_stop sets) and waits for it to exit;
  - removes the directory.
It never sleeps to synchronise: it waits on the daemon's output, its exit and its instance
document. It changes no certificate store and starts nothing but the unpacked executables.
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$OutputDirectory,
    [Parameter(ParameterSetName = 'Build')][ValidateSet('none', 'development', 'production')][string]$SigningMode = 'none',
    [Parameter(ParameterSetName = 'Build')][string]$Thumbprint,
    [Parameter(ParameterSetName = 'Build')][string]$ProductionSignCommand,
    [Parameter(ParameterSetName = 'Build')][string]$ExpectedSignerSha256,
    [Parameter(ParameterSetName = 'Build')][switch]$AllowDirty,
    [Parameter(ParameterSetName = 'Build')][switch]$Smoke,
    [Parameter(Mandatory, ParameterSetName = 'SmokeOnly')][string]$SmokeZip,
    [string]$SmokeParent = [System.IO.Path]::GetTempPath(),
    [string]$SmokeRecord
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The Windows xcopy package is built and smoked on Windows only.' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'The Windows support tuple is Windows 11 x64 only (CHG-2026-074 r13).'
}

$Target = 'x86_64-pc-windows-msvc'
$CliName = 'arkdeck.exe'
$DaemonName = 'arkdeck-agentd.exe'
$ManifestName = 'manifest.json'
$Schema = 'arkdeck.windows-xcopy-package/1'
$SmokeSchema = 'arkdeck.windows-xcopy-smoke/1'
# A command that has not answered in this time is reported, never waited on further.
$CommandTimeoutMs = 180000
# The daemon's own drain deadline is 20 seconds (windows_lifecycle.rs); a little more is allowed.
$DaemonDeadlineMs = 30000
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Invoke-Checked([string]$File, [string[]]$Arguments, [string]$WorkingDirectory) {
    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $output = & $File @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$File $($Arguments -join ' ') exited $LASTEXITCODE" }
        return $output
    } finally {
        Set-Location -LiteralPath $previous
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CertificatePin($Certificate) {
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Certificate.RawData)).ToLowerInvariant()
}

function Test-Pin([string]$Value, [string]$What) {
    $Value = $Value.ToLowerInvariant()
    if ($Value -notmatch '^[0-9a-f]{64}$') { throw "$What must be a certificate SHA-256 (64 hex), not a SHA-1 thumbprint." }
    return $Value
}

# The signature every signed file must carry: valid (trusted on this host), and the signer's pin.
function Get-VerifiedSigner([string]$Path, [bool]$RequireTimestamp) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw "$Path does not carry a valid Authenticode signature: $($signature.Status) $($signature.StatusMessage)"
    }
    if ($RequireTimestamp -and -not $signature.TimeStamperCertificate) {
        throw "$Path is signed without a timestamp; a production signature must be timestamped."
    }
    return [ordered]@{
        pin         = Get-CertificatePin $signature.SignerCertificate
        subject     = $signature.SignerCertificate.Subject
        notAfter    = $signature.SignerCertificate.NotAfter.ToUniversalTime().ToString('o')
        timestamped = [bool]$signature.TimeStamperCertificate
    }
}

function Resolve-DevelopmentThumbprint {
    if ($Thumbprint) { return $Thumbprint }
    $fromProcess = [Environment]::GetEnvironmentVariable('ARKDECK_DEV_SIGNER_THUMBPRINT')
    if ($fromProcess) { return $fromProcess }
    $fromUser = [Environment]::GetEnvironmentVariable('ARKDECK_DEV_SIGNER_THUMBPRINT', 'User')
    if ($fromUser) { return $fromUser }
    throw 'Development signing needs -Thumbprint or ARKDECK_DEV_SIGNER_THUMBPRINT (rust/scripts/windows-dev-identity.ps1 create).'
}

function Invoke-DevelopmentSigning([string[]]$Files, [string]$thumbprint) {
    $identityScript = Join-Path $PSScriptRoot 'windows-dev-identity.ps1'
    $pins = foreach ($file in $Files) {
        $answer = & $identityScript sign -Thumbprint $thumbprint -Path $file | ConvertFrom-Json
        if ($answer.status -ne 'Valid') { throw "Development signing of $file produced $($answer.status)." }
        $answer.pin
    }
    return [ordered]@{ thumbprint = $thumbprint; reportedPins = @($pins | Select-Object -Unique) }
}

function Resolve-ProductionCommand {
    $command = if ($ProductionSignCommand) { $ProductionSignCommand } else { [Environment]::GetEnvironmentVariable('ARKDECK_PRODUCTION_SIGN_COMMAND') }
    if (-not $command) {
        throw 'Production signing is not configured: pass -ProductionSignCommand or set ARKDECK_PRODUCTION_SIGN_COMMAND to the maintainer''s signing command. Nothing was built or signed.'
    }
    if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw "The production signing command $command does not exist. Nothing was built or signed." }
    return (Resolve-Path -LiteralPath $command).Path
}

function Invoke-ProductionSigning([string[]]$Files, [string]$command) {
    foreach ($file in $Files) {
        if ([System.IO.Path]::GetExtension($command) -eq '.ps1') {
            & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $command $file
        } else {
            & $command $file
        }
        if ($LASTEXITCODE -ne 0) { throw "The production signing command exited $LASTEXITCODE for $file." }
    }
    return [ordered]@{ command = [System.IO.Path]::GetFileName($command) }
}

function New-PackageBuild {
    if (Test-Path -LiteralPath $OutputDirectory) { throw "$OutputDirectory exists; a package is never written over an existing directory." }
    $repository = (Invoke-Checked git @('-C', $PSScriptRoot, 'rev-parse', '--show-toplevel')).Trim()
    $revision = (Invoke-Checked git @('-C', $repository, 'rev-parse', 'HEAD')).Trim()
    $status = @(Invoke-Checked git @('-C', $repository, 'status', '--porcelain=v1', '--untracked-files=all') | Where-Object { $_ })
    $dirty = $status.Count -gt 0
    if ($dirty -and -not $AllowDirty) {
        throw "The checkout at $repository is not clean ($($status.Count) entries); commit or remove them, or pass -AllowDirty (recorded in the manifest).`n$($status -join "`n")"
    }
    if ($SigningMode -eq 'production' -and $dirty) { throw 'A production package is built from a clean checkout only.' }
    $expectedPin = if ($ExpectedSignerSha256) { Test-Pin $ExpectedSignerSha256 '-ExpectedSignerSha256' } else { $null }
    # Signing is configured before anything is built: an unconfigured mode fails closed at once.
    $signer = switch ($SigningMode) {
        'development' { Resolve-DevelopmentThumbprint }
        'production' { Resolve-ProductionCommand }
        default { $null }
    }
    $rustDirectory = Join-Path $repository 'rust'
    $releaseVersion = Get-Content -LiteralPath (Join-Path $repository 'scripts/release/release-version.json') -Raw | ConvertFrom-Json

    $rustc = (Invoke-Checked rustc @('-V') $rustDirectory).Trim()
    $cargoVersion = (Invoke-Checked cargo @('-V') $rustDirectory).Trim()
    $cargoArguments = @('build', '--release', '--locked', '-p', 'arkdeck-agentd', '-p', 'arkdeck-cli', '--target', $Target)
    Write-Host "cargo $($cargoArguments -join ' ')"
    $previous = Get-Location
    try {
        Set-Location -LiteralPath $rustDirectory
        & cargo @cargoArguments | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "cargo build exited $LASTEXITCODE" }
        $metadata = & cargo metadata --format-version 1 --no-deps --locked | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "cargo metadata exited $LASTEXITCODE" }
    } finally {
        Set-Location -LiteralPath $previous
    }
    # The build must still be of the recorded revision.
    if ((Invoke-Checked git @('-C', $repository, 'rev-parse', 'HEAD')).Trim() -ne $revision) { throw 'HEAD moved during the build.' }
    $binaries = Join-Path $metadata.target_directory "$Target/release"

    $name = "arkdeck-$($releaseVersion.version)-windows-x64-$($revision.Substring(0, 12))"
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
    $output = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $stage = Join-Path $output $name
    [void](New-Item -ItemType Directory -Path $stage)
    foreach ($file in @($CliName, $DaemonName)) { Copy-Item -LiteralPath (Join-Path $binaries $file) -Destination $stage }
    $staged = @($CliName, $DaemonName | ForEach-Object { Join-Path $stage $_ })

    $signing = [ordered]@{ mode = $SigningMode; signerSha256 = $null }
    if ($SigningMode -ne 'none') {
        $detail = if ($SigningMode -eq 'development') { Invoke-DevelopmentSigning $staged $signer } else { Invoke-ProductionSigning $staged $signer }
        $signers = @($staged | ForEach-Object { Get-VerifiedSigner $_ ($SigningMode -eq 'production') })
        $pins = @($signers | ForEach-Object { $_.pin } | Select-Object -Unique)
        if ($pins.Count -ne 1) { throw "The CLI and the daemon carry different signers: $($pins -join ', ')" }
        if ($SigningMode -eq 'development' -and (@($detail.reportedPins) -join ',') -ne $pins[0]) {
            throw "windows-dev-identity.ps1 reported $($detail.reportedPins -join ', ') but the files carry $($pins[0])."
        }
        if ($expectedPin -and $pins[0] -ne $expectedPin) { throw "The files carry signer $($pins[0]), not the expected $expectedPin." }
        $signing.signerSha256 = $pins[0]
        $signing.signerSubject = $signers[1].subject
        $signing.signerNotAfter = $signers[1].notAfter
        $signing.timestamped = $signers[1].timestamped
        if ($SigningMode -eq 'development') {
            $signing.developmentThumbprint = $detail.thumbprint
            $signing.note = 'Host-trusted development signer (design L.1 item 22); not an installation identity.'
        } else {
            $signing.command = $detail.command
        }
    }

    $manifest = [ordered]@{
        schemaVersion        = $Schema
        kind                 = 'windows-xcopy-daemon-cli'
        version              = $releaseVersion.version
        build                = $releaseVersion.build
        sourceRevision       = $revision
        dirty                = $dirty
        allowDirty           = [bool]$AllowDirty
        dirtyEntries         = @($status)
        rustc                = $rustc
        cargo                = $cargoVersion
        target               = $Target
        profile              = 'release'
        cargoArguments       = $cargoArguments
        createdAtUtc         = [DateTime]::UtcNow.ToString('o')
        signing              = $signing
        files                = @(foreach ($path in $staged) {
                [ordered]@{ path = [System.IO.Path]::GetFileName($path); bytes = (Get-Item -LiteralPath $path).Length; sha256 = Get-Sha256 $path }
            })
        daemonConfiguration  = [ordered]@{
            ARKDECK_DAEMON_SIGNER_SHA256 = $signing.signerSha256
            ARKDECK_DAEMON_PATH          = "unset: the CLI's sibling $DaemonName"
        }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage $ManifestName) -Encoding utf8NoBOM
    $zip = Join-Path $output "$name.zip"
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $manifest.zip = [ordered]@{ name = "$name.zip"; bytes = (Get-Item -LiteralPath $zip).Length; sha256 = Get-Sha256 $zip }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output $ManifestName) -Encoding utf8NoBOM

    Write-Host "package  $zip"
    Write-Host "sha256   $($manifest.zip.sha256)"
    if ($signing.signerSha256) {
        Write-Host "Configure the CLI with ARKDECK_DAEMON_SIGNER_SHA256=$($signing.signerSha256) (the daemon is the CLI's sibling)."
    } else {
        Write-Host 'Unsigned: the CLI refuses this daemon; no pin can be configured.'
    }
    return [pscustomobject]@{ Zip = $zip; Output = $output; Manifest = $manifest }
}

# One process with its own environment; stdout and stderr are read to their end.
function Invoke-Process([string]$File, [string[]]$Arguments, [hashtable]$Environment, [string]$WorkingDirectory) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($File)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.WorkingDirectory = $WorkingDirectory
    $info.Environment.Clear()
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = $Environment[$key] }
    $process = [System.Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($CommandTimeoutMs)) {
        $process.Kill($true)
        throw "$File $($Arguments -join ' ') did not exit within $($CommandTimeoutMs / 1000) s."
    }
    $process.WaitForExit()
    return [ordered]@{ exitCode = $process.ExitCode; stdout = $stdout.Result; stderr = $stderr.Result }
}

function Get-Json([string]$Text) {
    try { return $Text | ConvertFrom-Json -Depth 64 } catch { return $null }
}

function Get-Property($Object, [string[]]$Path) {
    foreach ($name in $Path) {
        if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $name)) { return $null }
        $Object = $Object.$name
    }
    return $Object
}

function Read-Instance([string]$Root) {
    $path = Join-Path $Root 'instance.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

# The development root's stop event, as InstanceScope::stop_event_name spells it:
# Local\ArkDeck.Agentd.Dev.<user SID>.<root file id>.Stop.<pid>; the root's file id ends its pipe name.
function Request-DaemonStop($Instance) {
    if ($Instance.socketPath -notmatch '-([0-9a-f]{16}-[0-9a-f]{32})$') { throw "The instance document names an unexpected pipe $($Instance.socketPath)." }
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = "Local\ArkDeck.Agentd.Dev.$user.$($Matches[1]).Stop.$($Instance.pid)"
    $event = [System.Threading.EventWaitHandle]::OpenExisting($name)
    try { [void]$event.Set() } finally { $event.Dispose() }
    return $name
}

function Invoke-XcopySmoke([string]$Zip) {
    if (-not (Test-Path -LiteralPath $SmokeParent -PathType Container)) { throw "-SmokeParent $SmokeParent is not a directory." }
    $work = Join-Path (Resolve-Path -LiteralPath $SmokeParent).Path "arkdeck-xcopy-smoke-$([guid]::NewGuid().ToString('N'))"
    [void](New-Item -ItemType Directory -Path $work)
    $record = [ordered]@{ schemaVersion = $SmokeSchema; zip = (Resolve-Path -LiteralPath $Zip).Path; zipSha256 = Get-Sha256 $Zip; directory = $work; steps = [System.Collections.Generic.List[object]]::new() }
    $daemon = $null
    $daemonPid = $null
    $result = 'FAIL'
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, (Join-Path $work 'package'))
        $packages = @(Get-ChildItem -LiteralPath (Join-Path $work 'package') -Directory)
        if ($packages.Count -ne 1) { throw 'The zip must hold exactly one package directory.' }
        $package = $packages[0].FullName
        $manifest = Get-Content -LiteralPath (Join-Path $package $ManifestName) -Raw | ConvertFrom-Json
        if ($manifest.schemaVersion -ne $Schema) { throw "The package manifest is not $Schema." }
        foreach ($file in $manifest.files) {
            if ((Get-Sha256 (Join-Path $package $file.path)) -ne $file.sha256) { throw "$($file.path) differs from the package manifest." }
        }
        $record.sourceRevision = $manifest.sourceRevision
        $record.signingMode = $manifest.signing.mode
        $pin = $manifest.signing.signerSha256
        if (-not $pin) { throw 'The package is unsigned; the CLI refuses an unsigned daemon, so there is nothing to smoke.' }
        $signer = Get-VerifiedSigner (Join-Path $package $DaemonName) $false
        if ($signer.pin -ne $pin) { throw "The unpacked daemon carries signer $($signer.pin), not the manifest's $pin." }
        $record.signerSha256 = $pin
        # The development root is created owner-only (the user and SYSTEM, protected), as the
        # daemon creates the account's root; it is this smoke's own directory.
        $state = Join-Path $work 'state'
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($user)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($user, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        }
        [System.IO.FileSystemAclExtensions]::Create([System.IO.DirectoryInfo]::new($state), $security)

        $environment = @{}
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            if ($entry.Key -notmatch '^(ARKDECK_|OHOS_HDC_)') { $environment[$entry.Key] = $entry.Value }
        }
        $environment['ARKDECK_DAEMON_SIGNER_SHA256'] = $pin
        $environment['ARKDECK_DEVELOPMENT_STATE_ROOT'] = $state
        $cli = Join-Path $package $CliName

        $step = { param($Name, $Answer) $record.steps.Add([ordered]@{ name = $Name; exitCode = $Answer.exitCode; stdout = $Answer.stdout; stderr = $Answer.stderr }) }

        # Decision 11: a CLI that starts its daemon starts it here. Otherwise nothing runs yet.
        $doctor = Invoke-Process $cli @('--output', 'json', 'doctor') $environment $work
        & $step 'doctor (first)' $doctor
        $instance = Read-Instance $state
        if ($instance) {
            $record.daemonStart = 'client'
            $daemonPid = [int]$instance.pid
            $client = Get-Process -Id $daemonPid
            if ($client.Path -ne (Join-Path $package $DaemonName)) { throw "The client-started daemon $daemonPid runs $($client.Path), not the unpacked daemon." }
            $daemon = $client
        } else {
            $record.daemonStart = 'explicit'
            $info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $package $DaemonName))
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.RedirectStandardInput = $true
            $info.WorkingDirectory = $package
            $info.Environment.Clear()
            foreach ($key in $environment.Keys) { $info.Environment[$key] = $environment[$key] }
            $daemon = [System.Diagnostics.Process]::Start($info)
            $daemonPid = $daemon.Id
            $daemon.StandardInput.Close()
            $daemonErrors = $daemon.StandardError.ReadToEndAsync()
            $daemonLines = [System.Collections.Generic.List[string]]::new()
            $deadline = [DateTime]::UtcNow.AddMilliseconds($DaemonDeadlineMs)
            while ($true) {
                $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
                if ($remaining -le 0) { throw "The daemon printed no listening line within $($DaemonDeadlineMs / 1000) s: $($daemonLines -join ' | ')" }
                $line = $daemon.StandardOutput.ReadLineAsync()
                if (-not $line.Wait($remaining)) { continue }
                if ($null -eq $line.Result) { throw "The daemon exited $($daemon.ExitCode) before serving: $($daemonLines -join ' | ') $($daemonErrors.Result)" }
                $daemonLines.Add($line.Result)
                if ($line.Result.StartsWith('arkdeck-agentd listening on ')) { break }
            }
            $instance = Read-Instance $state
            if (-not $instance -or [int]$instance.pid -ne $daemonPid) { throw 'The daemon serves but its instance document does not name it.' }
            $environment['ARKDECK_ENDPOINT'] = $instance.socketPath
            $doctor = Invoke-Process $cli @('--output', 'json', 'doctor') $environment $work
            & $step 'doctor (daemon started by the smoke)' $doctor
        }
        $record.endpoint = $instance.socketPath
        $record.daemonPid = $daemonPid
        $doctorJson = Get-Json $doctor.stdout
        if ($doctor.exitCode -ne 0 -or (Get-Property $doctorJson @('ok')) -ne $true) { throw "doctor exited $($doctor.exitCode): $($doctor.stdout) $($doctor.stderr)" }
        $record.doctor = 'PASS'

        $verify = Invoke-Process $cli @('--output', 'json', 'runtime', 'service', 'verify') $environment $work
        & $step 'runtime service verify' $verify
        $verifyJson = Get-Json $verify.stdout
        $verifyError = Get-Property $verifyJson @('error', 'code')
        if ($verify.exitCode -eq 0 -and (Get-Property $verifyJson @('result', 'runtimeVerified')) -eq $true) {
            $record.runtimeServiceVerify = 'PASS'
        } elseif ($verifyError -in @('unsupportedOnPlatform', 'invalidCommand')) {
            $record.runtimeServiceVerify = "unavailable ($verifyError)"
        } else {
            $record.runtimeServiceVerify = "FAIL (exit $($verify.exitCode))"
        }

        $record.stopEvent = Request-DaemonStop $instance
        if (-not $daemon.WaitForExit($DaemonDeadlineMs)) { throw "The daemon did not exit within $($DaemonDeadlineMs / 1000) s of its stop event." }
        $record.daemonExitCode = if ($record.daemonStart -eq 'explicit') { $daemon.ExitCode } else { $null }
        if ($record.daemonStart -eq 'explicit') {
            $rest = $daemon.StandardOutput.ReadToEnd()
            $record.daemonStdout = (($daemonLines -join "`n") + "`n" + $rest).Trim()
            $record.daemonStderr = $daemonErrors.Result
            if ($record.daemonStdout -notmatch 'arkdeck-agentd stopped') { throw 'The daemon exited without a complete drain (no "arkdeck-agentd stopped").' }
        }
        $daemon = $null
        if ($record.runtimeServiceVerify -like 'FAIL*') { throw 'runtime service verify failed.' }
        $result = 'PASS'
    } catch {
        $record.error = $_.Exception.Message
    } finally {
        if ($daemon -and -not $daemon.HasExited) {
            # Only the daemon this smoke started or proved it started (its unpacked image).
            $daemon.Kill($true)
            [void]$daemon.WaitForExit($DaemonDeadlineMs)
            $record.daemonKilled = $true
        }
        Remove-Item -LiteralPath $work -Recurse -Force
        $record.directoryRemoved = -not (Test-Path -LiteralPath $work)
        $record.result = $result
    }
    $json = $record | ConvertTo-Json -Depth 8
    if ($SmokeRecord) { $json | Set-Content -LiteralPath $SmokeRecord -Encoding utf8NoBOM }
    Write-Host "smoke $result (daemon start: $($record['daemonStart']); doctor: $($record['doctor']); runtime service verify: $($record['runtimeServiceVerify']))"
    if ($result -ne 'PASS') { throw "The xcopy smoke failed: $($record['error'])" }
    return $record
}

if ($PSCmdlet.ParameterSetName -eq 'SmokeOnly') {
    [void](Invoke-XcopySmoke $SmokeZip)
} else {
    # A build that fails leaves no partial package: the directory it created is removed.
    $outputExisted = Test-Path -LiteralPath $OutputDirectory
    try {
        $built = New-PackageBuild
    } catch {
        if (-not $outputExisted -and (Test-Path -LiteralPath $OutputDirectory)) { Remove-Item -LiteralPath $OutputDirectory -Recurse -Force }
        throw
    }
    if ($Smoke) {
        if (-not $SmokeRecord) { $SmokeRecord = Join-Path $built.Output 'smoke.json' }
        [void](Invoke-XcopySmoke $built.Zip)
    }
}
