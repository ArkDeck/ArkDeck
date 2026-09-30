#requires -Version 7.2
<#
Maintainer-run sampling of one Windows HDC build for the Windows HDC integration change
(CHG-2026-074 Windows phase, WM0.5). The agent never runs this: `list targets -v` starts an
HDC server, and a connected DAYU200 is reached through it. The crib is
openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-002/hdc-windows-sampling-crib-20260930.md.

It records, for the selected hdc.exe only, the exact stdout/stderr BYTES, exit code, duration
and stream-closure of the read-only commands the macOS profile registers (`-v`, `checkserver`,
`list targets -v`), the HDC server listener/process state before and after EVERY command, the
tool's identity (SHA-256, size, Authenticode, Mark-of-the-Web, sibling files) and the OHOS_HDC_*
environment. Raw output stays in -OutputDirectory, outside any git work tree: it holds connect
keys (serials) and user paths. The agent redacts it before anything is committed.

It never kills or restarts an HDC server it did not start, never runs a device-scoped command
(no `-t`, shell, file, install, flash, reboot or key command), never passes device output to a
shell, and refuses to reuse a phase directory or to mix two hdc.exe builds under one root.

Phases, one run each, in this order, with the same -OutputDirectory root per candidate:
  no-board          board unplugged; no HDC server or hdc process may be running (close DevEco)
  board-connected   DAYU200 plugged in (and, if prompted on the board, authorised)
  board-removed     DAYU200 unplugged again (on macOS 3.2.0f the row stays, as Offline)
  stop-server       optional: `hdc kill`, only for the server this root's no-board phase started
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HdcPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateSet('no-board', 'board-connected', 'board-removed', 'stop-server')][string]$Phase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows HDC sampling requires Windows.' }
$HdcPath = (Resolve-Path -LiteralPath $HdcPath).Path
if ([System.IO.Path]::GetFileName($HdcPath) -ne 'hdc.exe') { throw "Select an hdc.exe; got $HdcPath." }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

# Raw samples must never land inside a git work tree (they hold serials and user paths).
$probe = $OutputDirectory
while ($probe) {
    if (Test-Path -LiteralPath (Join-Path $probe '.git')) { throw "Choose an output directory outside any git work tree ($probe)." }
    $probe = [System.IO.Path]::GetDirectoryName($probe)
}

$toolSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $HdcPath).Hash.ToLowerInvariant()
$toolMarker = Join-Path $OutputDirectory 'selected-tool.sha256'
if ($Phase -eq 'no-board') {
    if (Test-Path -LiteralPath $OutputDirectory) { throw "Use a new output directory per candidate; $OutputDirectory exists." }
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
    Set-Content -NoNewline -Encoding ascii -LiteralPath $toolMarker -Value $toolSha256
} else {
    if (-not (Test-Path -LiteralPath $toolMarker)) { throw "Run the no-board phase first with this -OutputDirectory." }
    if ((Get-Content -Raw -LiteralPath $toolMarker) -ne $toolSha256) { throw 'This root was started with a different hdc.exe; one root per candidate.' }
}
$phaseDirectory = Join-Path $OutputDirectory $Phase
if (Test-Path -LiteralPath $phaseDirectory) { throw "Use a new output directory; $phaseDirectory exists." }
[void](New-Item -ItemType Directory -Path $phaseDirectory)
$startedMarker = Join-Path $OutputDirectory 'server-started-by-sampling.json'

function Get-ProcessFacts([int]$ProcessId) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return [ordered]@{ pid = $ProcessId; alive = $false } }
    $path = $null; $startTicks = $null; $parent = $null
    try { $path = $process.Path } catch { }
    try { $startTicks = $process.StartTime.ToUniversalTime().Ticks } catch { }
    try { $parent = $process.Parent.Id } catch { }
    [ordered]@{
        pid = $ProcessId; alive = $true; name = $process.ProcessName; parentPid = $parent
        path = $path
        sha256 = if ($path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() } catch { $null } } else { $null }
        # Ticks, not an ISO string: ConvertFrom-Json turns ISO strings back into DateTime.
        startTimeUtcTicks = $startTicks
    }
}

function Get-ServerState {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 8710 -ErrorAction SilentlyContinue)
    $ownerPids = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
    [ordered]@{
        observedAtUtc = [DateTime]::UtcNow.ToString('o')
        listeners8710 = @(foreach ($listener in $listeners) {
                [ordered]@{ localAddress = $listener.LocalAddress; localPort = $listener.LocalPort; pid = [int]$listener.OwningProcess }
            })
        listenerOwners = @(foreach ($ownerPid in $ownerPids) { Get-ProcessFacts ([int]$ownerPid) })
        hdcProcesses = @(foreach ($process in @(Get-Process -Name hdc -ErrorAction SilentlyContinue)) { Get-ProcessFacts $process.Id })
    }
}

function Test-SamplingServer($State) {
    if (-not (Test-Path -LiteralPath $startedMarker)) { return $false }
    $started = Get-Content -LiteralPath $startedMarker -Raw | ConvertFrom-Json
    $now = @($State.listenerOwners)
    $then = @($started.listenerOwners)
    $now.Count -eq 1 -and $then.Count -eq 1 -and
    $now[0].pid -eq $then[0].pid -and $now[0].startTimeUtcTicks -eq $then[0].startTimeUtcTicks -and
    $null -ne $now[0].startTimeUtcTicks -and $now[0].sha256 -eq $toolSha256
}

function Invoke-Hdc([string]$Name, [string[]]$Argv) {
    $before = Get-ServerState
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $HdcPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = Split-Path -Parent $HdcPath
    foreach ($argument in $Argv) { $start.ArgumentList.Add($argument) }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($start)
    $process.StandardInput.Close()
    $stdout = [System.IO.MemoryStream]::new()
    $stderr = [System.IO.MemoryStream]::new()
    $copyOut = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $copyErr = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $exited = $process.WaitForExit(30000)
    # On timeout kill only this client, never its process tree: a server it spawned stays up and
    # is stopped, if at all, by the stop-server phase.
    if (-not $exited) { try { $process.Kill($false) } catch { }; [void]$process.WaitForExit(5000) }
    $watch.Stop()
    # A server spawned with inherited handles would keep the pipes open after the client exits;
    # record that instead of waiting forever.
    $streamsClosed = [System.Threading.Tasks.Task]::WaitAll(@($copyOut, $copyErr), 5000)
    $outBytes = $stdout.ToArray(); $errBytes = $stderr.ToArray()
    [System.IO.File]::WriteAllBytes((Join-Path $phaseDirectory "$Name.stdout.bin"), $outBytes)
    [System.IO.File]::WriteAllBytes((Join-Path $phaseDirectory "$Name.stderr.bin"), $errBytes)
    $sha = [System.Security.Cryptography.SHA256]
    [ordered]@{
        name = $Name; argv = $Argv
        exitCode = $(if ($exited) { $process.ExitCode } else { $null }); timedOut = -not $exited
        durationMs = $watch.Elapsed.TotalMilliseconds
        streamsClosedWithin5s = $streamsClosed
        stdoutBytes = $outBytes.Length; stdoutSha256 = [Convert]::ToHexString($sha::HashData($outBytes)).ToLowerInvariant()
        stderrBytes = $errBytes.Length; stderrSha256 = [Convert]::ToHexString($sha::HashData($errBytes)).ToLowerInvariant()
        stdoutHasCR = $outBytes -contains 13
        serverBefore = $before
        serverAfter = Get-ServerState
    }
}

$signature = Get-AuthenticodeSignature -LiteralPath $HdcPath
$zone = Get-Item -LiteralPath $HdcPath -Stream Zone.Identifier -ErrorAction SilentlyContinue
$version = (Get-Item -LiteralPath $HdcPath).VersionInfo
$record = [ordered]@{
    schema = 'arkdeck-windows-hdc-sample/v2'
    phase = $Phase
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture)
    powershell = $PSVersionTable.PSVersion.ToString()
    environment = [ordered]@{
        ohosHdc = [ordered]@{}
        hdcOnPath = @(Get-Command hdc.exe -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    }
    tool = [ordered]@{
        path = $HdcPath
        sha256 = $toolSha256
        bytes = (Get-Item -LiteralPath $HdcPath).Length
        lastWriteTimeUtc = (Get-Item -LiteralPath $HdcPath).LastWriteTimeUtc.ToString('o')
        versionResource = [ordered]@{
            fileVersion = $version.FileVersion; productVersion = $version.ProductVersion
            originalFilename = $version.OriginalFilename; productName = $version.ProductName
            companyName = $version.CompanyName
        }
        authenticodeStatus = $signature.Status.ToString()
        signerSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
        markOfTheWeb = $null -ne $zone
        zoneIdentifier = if ($zone) { Get-Content -LiteralPath $HdcPath -Stream Zone.Identifier -Raw } else { $null }
        siblingFiles = @(foreach ($file in @(Get-ChildItem -LiteralPath (Split-Path -Parent $HdcPath) -File)) {
                if ($file.Extension -in '.dll', '.exe') {
                    [ordered]@{
                        name = $file.Name; bytes = $file.Length
                        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
                        authenticodeStatus = (Get-AuthenticodeSignature -LiteralPath $file.FullName).Status.ToString()
                    }
                }
            })
    }
    serverBefore = Get-ServerState
    commands = [System.Collections.Generic.List[object]]::new()
    refused = $null
}
foreach ($variable in @(Get-ChildItem Env: | Where-Object Name -Like 'OHOS_HDC*')) {
    $record.environment.ohosHdc[$variable.Name] = $variable.Value
}

switch ($Phase) {
    'no-board' {
        if ($record.environment.ohosHdc.Contains('OHOS_HDC_SERVER_PORT')) {
            $record.refused = 'OHOS_HDC_SERVER_PORT is set; this sample is for the default endpoint 127.0.0.1:8710. Unset it in this shell and rerun with a new root.'
        } elseif (@($record.serverBefore.listeners8710).Count -gt 0 -or @($record.serverBefore.hdcProcesses).Count -gt 0) {
            $record.refused = 'Port 8710 is listening or an hdc process is running. Report its owner (serverBefore) and close it yourself (e.g. quit DevEco Studio); this script does not kill it. Rerun with a new root.'
        } else {
            $record.commands.Add((Invoke-Hdc 'version' @('-v')))
            $record.commands.Add((Invoke-Hdc 'checkserver-no-server' @('checkserver')))
            $record.commands.Add((Invoke-Hdc 'list-targets-first' @('list', 'targets', '-v')))
            Start-Sleep -Seconds 2
            $record.commands.Add((Invoke-Hdc 'list-targets-empty' @('list', 'targets', '-v')))
            $record.commands.Add((Invoke-Hdc 'checkserver-server-up' @('checkserver')))
            $state = Get-ServerState
            $owners = @($state.listenerOwners)
            # Only a single new listener owned by the selected hdc.exe counts as this sampling's server.
            if ($owners.Count -eq 1 -and $owners[0].sha256 -eq $toolSha256 -and $null -ne $owners[0].startTimeUtcTicks) {
                $state | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath $startedMarker
            } else {
                $record.refused = 'After the no-board commands there is not exactly one 8710 listener owned by the selected hdc.exe; later phases will refuse. Hand back this root as is.'
            }
        }
    }
    { $_ -in 'board-connected', 'board-removed' } {
        if (-not (Test-SamplingServer $record.serverBefore)) {
            $record.refused = 'The 8710 server is not the one this root''s no-board phase started (or none is running); not sampling through another server.'
        } else {
            $record.commands.Add((Invoke-Hdc "list-targets-$Phase" @('list', 'targets', '-v')))
            Start-Sleep -Seconds 2
            $record.commands.Add((Invoke-Hdc "list-targets-$Phase-again" @('list', 'targets', '-v')))
            $record.commands.Add((Invoke-Hdc "checkserver-$Phase" @('checkserver')))
        }
    }
    'stop-server' {
        if (-not (Test-SamplingServer $record.serverBefore)) {
            $record.refused = 'The 8710 server is not the one this root''s no-board phase started; not stopping it.'
        } else {
            $record.commands.Add((Invoke-Hdc 'kill-server' @('kill')))
        }
    }
}
$record.serverAfter = Get-ServerState
$samplePath = Join-Path $phaseDirectory 'sample.json'
$record | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM -LiteralPath $samplePath
if ($record.refused) { Write-Warning $record.refused }
Write-Output $samplePath
