#requires -Version 7.2
<#
Run on a real Windows host. This records OS transport results separately from
Windows 11 + DAYU200 product acceptance. It does not install certificates,
drivers, packages or tools, start an HDC server, or change machine policy.

Build the probe with:
  cargo build --release -p arkdeck-platform --example windows_spk3

The product daemon and CLI must already be built from the recorded checkout.
Use an installation-owned signer pin or registered package family. A missing
Windows HDC profile/host/driver/board remains an explicit incomplete result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DaemonPath,
    [Parameter(Mandatory)][string]$CliPath,
    [Parameter(Mandatory)][string]$ProbePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$SignerCertificateSha256,
    [string]$DaemonPackageFamily,
    [string]$HdcPath,
    [string]$HdcSha256,
    [PSCredential]$OtherUserCredential,
    [System.Management.Automation.Runspaces.PSSession]$RemoteSession,
    [string]$RemoteProbePath,
    [string]$PackagedProbePath,
    [string]$ExpectedClientPackageFamily,
    [string]$PythonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'SPK-3 requires execution on Windows; a cross build is not platform evidence.' }
if ($SignerCertificateSha256) {
    $SignerCertificateSha256 = $SignerCertificateSha256.ToLowerInvariant()
    if ($SignerCertificateSha256 -notmatch '^[a-f0-9]{64}$') { throw 'The installed signer pin must be a SHA256 certificate digest, not a SHA1 thumbprint.' }
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory; existing evidence is never overwritten.' }
[void](New-Item -ItemType Directory -Path $OutputDirectory)
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$DaemonPath = (Resolve-Path -LiteralPath $DaemonPath).Path
$CliPath = (Resolve-Path -LiteralPath $CliPath).Path
$ProbePath = (Resolve-Path -LiteralPath $ProbePath).Path
$rows = [System.Collections.Generic.List[object]]::new()
$processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$captures = [System.Collections.Generic.List[object]]::new()
$schemaFailed = $false
$nonce = [Guid]::NewGuid().ToString('N')
$endpoint = "\\.\pipe\arkdeck-spk3-$nonce"
$identityArgs = @($DaemonPath, $(if ($SignerCertificateSha256) { $SignerCertificateSha256 } else { '-' }), $(if ($DaemonPackageFamily) { $DaemonPackageFamily } else { '-' }))
$childEnvironment = @{
    ARKDECK_ENDPOINT = $endpoint
    ARKDECK_DAEMON_PATH = $DaemonPath
    ARKDECK_DAEMON_SIGNER_SHA256 = $SignerCertificateSha256
    ARKDECK_DAEMON_PACKAGE_FAMILY = $DaemonPackageFamily
    ARKDECK_HDC_PATH = $HdcPath
    ARKDECK_HDC_SHA256 = $HdcSha256
}

function Add-Row([string]$Name, [string]$Status, $Detail) {
    $rows.Add([ordered]@{ case = $Name; status = $Status; detail = $Detail })
}

function Add-Capture($Process, $Stdout, $Stderr) {
    $capture = [pscustomobject]@{ Process = $Process; Stdout = $Stdout; Stderr = $Stderr }
    $captures.Add($capture)
    return $capture
}

function Wait-Capture($Capture, [int]$Milliseconds = 5000) {
    $tasks = [System.Threading.Tasks.Task[]]@($Capture.Stdout, $Capture.Stderr)
    if (-not [System.Threading.Tasks.Task]::WaitAll($tasks, $Milliseconds)) {
        throw 'Producer output did not drain within the recording budget.'
    }
}

function New-Process([string]$Path, [string[]]$Argv, [hashtable]$Environment, [PSCredential]$Credential = $null) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [Environment]::GetFolderPath('System')
    foreach ($argument in $Argv) { $start.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) {
        if ([string]::IsNullOrEmpty($Environment[$key])) { [void]$start.Environment.Remove($key) }
        else { $start.Environment[$key] = $Environment[$key] }
    }
    if ($Credential) {
        $network = $Credential.GetNetworkCredential()
        $start.UserName = $network.UserName
        $start.Domain = $network.Domain
        $start.Password = $Credential.Password
        $start.LoadUserProfile = $true
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $processes.Add($process)
    return $process
}

function Invoke-Process([string]$Path, [string[]]$Argv, [hashtable]$Environment = @{}, [PSCredential]$Credential = $null) {
    $process = New-Process $Path $Argv $Environment $Credential
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $capture = Add-Capture $process $stdout $stderr
    $exited = $process.WaitForExit(30000)
    if (-not $exited) {
        $process.Kill($true)
        if (-not $process.WaitForExit(5000)) { throw 'Producer did not exit after the cleanup request.' }
    }
    Wait-Capture $capture
    return [ordered]@{ exitCode = $process.ExitCode; stdout = $stdout.GetAwaiter().GetResult(); stderr = $stderr.GetAwaiter().GetResult(); timedOut = -not $exited }
}

function Probe([string[]]$Argv, [PSCredential]$Credential = $null) {
    $result = Invoke-Process $ProbePath $Argv @{} $Credential
    if ($result.exitCode -ne 0 -or $result.timedOut) { throw "Probe failed: $($result.stderr) $($result.stdout)" }
    return ($result.stdout | ConvertFrom-Json -AsHashtable)
}

function Squat-Case([string]$Name, [PSCredential]$Credential = $null) {
    $squatEndpoint = "\\.\pipe\arkdeck-spk3-$nonce-$Name"
    $holder = New-Process $ProbePath @('raw-squat', $squatEndpoint) @{} $Credential
    $stderr = $holder.StandardError.ReadToEndAsync()
    $readyTask = $holder.StandardOutput.ReadLineAsync()
    $capture = Add-Capture $holder $readyTask $stderr
    if (-not $readyTask.Wait(10000)) { throw 'Squatter fixture did not become ready.' }
    $ready = $readyTask.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
    if ($ready.probe -ne 'squatter-ready') { throw 'Squatter fixture failed before listening.' }
    $remaining = $holder.StandardOutput.ReadToEndAsync()
    $capture.Stdout = $remaining
    $bind = Probe @('bind', $squatEndpoint)
    $client = Probe (@('server-auth', $squatEndpoint) + $identityArgs)
    if (-not $holder.WaitForExit(10000)) { throw 'Squatter did not observe client disconnection.' }
    Wait-Capture $capture
    $observed = $remaining.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
    $passed = (-not $bind.accepted) -and (-not $client.accepted) -and $client.framesSent -eq 0 -and $observed.receivedBytes -eq 0
    Add-Row $Name $(if ($passed) { 'PASS' } else { 'FAIL' }) @{ daemonBind = $bind; client = $client; holder = $observed; holderStderr = $stderr.GetAwaiter().GetResult() }
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $signature = Get-AuthenticodeSignature -LiteralPath $DaemonPath
    $motw = Get-Item -LiteralPath $DaemonPath -Stream Zone.Identifier -ErrorAction SilentlyContinue
    $metadata = [ordered]@{
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        osCaption = $os.Caption; osVersion = $os.Version; osBuild = $os.BuildNumber
        osArchitecture = $os.OSArchitecture
        daemonSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $DaemonPath).Hash.ToLowerInvariant()
        cliSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $CliPath).Hash.ToLowerInvariant()
        probeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ProbePath).Hash.ToLowerInvariant()
        daemonAuthenticodeStatus = $signature.Status.ToString()
        daemonMarkOfTheWebPresent = $null -ne $motw
        selectedEndpoint = $endpoint
        sourceCommit = (& git -C (Join-Path $PSScriptRoot '..') rev-parse HEAD)
        sourceDirty = -not [string]::IsNullOrWhiteSpace((& git -C (Join-Path $PSScriptRoot '..') status --porcelain | Out-String))
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $OutputDirectory 'host.json')
    $primitive = Probe @('process-selftest')
    Add-Row 'verified-process-argv-environment-output-timeout' 'PASS' $primitive
    Squat-Case 'same-account-different-image'
    if ($OtherUserCredential) { Squat-Case 'foreign-account-owner' $OtherUserCredential }
    else { Add-Row 'foreign-account-owner' 'NOT_RUN' 'A second Windows account credential and read access to the probe binary are required.' }

    $daemon = New-Process $DaemonPath @() $childEnvironment
    $daemonStdout = $daemon.StandardOutput.ReadToEndAsync()
    $daemonStderr = $daemon.StandardError.ReadToEndAsync()
    $daemonCapture = Add-Capture $daemon $daemonStdout $daemonStderr
    $pidProbe = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ($daemon.HasExited) { break }
        $pidProbe = Probe @('connection-pid', $endpoint)
        if ($pidProbe.connected) { break }
        Start-Sleep -Milliseconds 100
    }
    $pidMatches = $null -ne $pidProbe -and $pidProbe.serverPidAvailable -and $pidProbe.serverPid -eq $daemon.Id
    Add-Row 'GetNamedPipeServerProcessId-on-CreateFileW-handle' $(if ($pidMatches) { 'PASS' } else { 'FAIL' }) $pidProbe
    $auth = Probe (@('server-auth', $endpoint) + $identityArgs)
    Add-Row 'installed-daemon-owner-image-signature-or-package' $(if ($auth.accepted) { 'PASS' } else { 'FAIL' }) $auth
    if ($OtherUserCredential) {
        $foreign = Probe @('raw-connect', $endpoint) $OtherUserCredential
        Add-Row 'cross-account-client' $(if (-not $foreign.connected -and $foreign.osError -eq 5) { 'PASS' } else { 'FAIL' }) $foreign
    } else { Add-Row 'cross-account-client' 'NOT_RUN' 'A second Windows account is required to exercise the kernel DACL.' }

    if ($RemoteSession -and $RemoteProbePath) {
        $remoteEndpoint = "\\$env:COMPUTERNAME\pipe\arkdeck-spk3-$nonce"
        $remote = Invoke-Command -Session $RemoteSession -ScriptBlock {
            param($Path, $Endpoint)
            @{ executableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant(); output = (& $Path raw-connect $Endpoint) }
        } -ArgumentList $RemoteProbePath, $remoteEndpoint
        $remoteProbe = $remote.output | ConvertFrom-Json -AsHashtable
        $matched = $remote.executableSha256 -eq $metadata.probeSha256
        Add-Row 'remote-client' $(if ($matched -and -not $remoteProbe.connected -and $remoteProbe.osError -eq 5) { 'PASS' } else { 'FAIL' }) $remote
    } else { Add-Row 'remote-client' 'NOT_RUN' 'A distinct remote Windows session with the identical probe build is required; local URI validation is not remote-client evidence.' }

    if ($PackagedProbePath -and $ExpectedClientPackageFamily) {
        $packaged = Invoke-Process $PackagedProbePath (@('server-auth', $endpoint) + $identityArgs)
        $packageResult = $packaged.stdout | ConvertFrom-Json -AsHashtable
        $matched = $packageResult.accepted -and $packageResult.clientPackageFamily -eq $ExpectedClientPackageFamily
        Add-Row 'packaged-client' $(if ($matched) { 'PASS' } else { 'FAIL' }) $packageResult
    } else { Add-Row 'packaged-client' 'NOT_RUN' 'A registered MSIX probe with an observed package family is required; an unpackaged executable is insufficient.' }

    $productCommands = @(
        [pscustomobject]@{ Name = 'doctor'; Argv = @('doctor', '--deep') },
        [pscustomobject]@{ Name = 'operation-list'; Argv = @('operation', 'list') },
        [pscustomobject]@{ Name = 'device-candidates'; Argv = @('device', 'candidates') }
    )
    foreach ($command in $productCommands) {
        $name = $command.Name
        $result = Invoke-Process $CliPath (@('--output', 'json') + [string[]]$command.Argv) $childEnvironment
        $result.stdout | Set-Content -Encoding utf8NoBOM -NoNewline -LiteralPath (Join-Path $OutputDirectory "$name.stdout.json")
        $result.stderr | Set-Content -Encoding utf8NoBOM -NoNewline -LiteralPath (Join-Path $OutputDirectory "$name.stderr.txt")
        # Device-model identity requires review of the actual observation and
        # published tuple. A zero exit status alone cannot establish DAYU200.
        Add-Row "product-$name" $(if ($result.exitCode -eq 0 -and -not $result.timedOut) { 'RECORDED' } else { 'FAIL' }) @{ exitCode = $result.exitCode; timedOut = $result.timedOut; stdout = "$name.stdout.json"; stderr = "$name.stderr.txt" }
    }
    Add-Row 'different-elevation-client' 'NOT_RUN' 'Run guard-server in a normal-user terminal and raw-connect from a separately elevated same-user terminal; require the server record to show zero frameConsumerEntries. This harness never elevates silently.'
    Add-Row 'native-pipe-cancellation-and-process-cleanup' 'NOT_RUN' 'Run cargo test -p arkdeck-platform on Windows and record pending read/write cancellation latency and completion races. Cross compilation cannot prove cancellation timing or Job Object cleanup.'
    Add-Row 'W0-SmartScreen-driver-distribution' 'NOT_RUN' 'Record downloaded/installed signed build MotW and SmartScreen behavior, DAYU200 USB driver access as a non-admin, and the selected Windows support tuple.'
    Add-Row 'DAYU200-current-published-HDC-tuple' 'REVIEW_REQUIRED' 'Review recorded device-candidates bytes against the real connected board and current hash-pinned Windows observation profile; mock/cross compilation cannot close this row.'
} catch {
    Add-Row 'harness-execution' 'FAIL' $_.Exception.Message
} finally {
    $allExited = $true
    foreach ($process in $processes) {
        try {
            if (-not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { throw 'Producer remained alive after cleanup.' }
            }
        } catch {
            $allExited = $false
            Add-Row 'producer-cleanup' 'FAIL' $_.Exception.Message
        }
    }
    $allDrained = $captures.Count -eq $processes.Count
    try {
        $pendingTasks = [System.Threading.Tasks.Task[]]@($captures | ForEach-Object { $_.Stdout; $_.Stderr })
        if ($pendingTasks.Count -gt 0 -and -not [System.Threading.Tasks.Task]::WaitAll($pendingTasks, 5000)) { throw 'Some producer output remained open after cleanup.' }
    } catch {
        $allDrained = $false
        Add-Row 'producer-output-drain' 'FAIL' $_.Exception.Message
    }
    if ($allDrained -and (Get-Variable -Name daemonCapture -ErrorAction SilentlyContinue)) {
        try {
            $daemonStdout.GetAwaiter().GetResult() | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $OutputDirectory 'daemon.stdout.txt')
            $daemonStderr.GetAwaiter().GetResult() | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $OutputDirectory 'daemon.stderr.txt')
        } catch {
            $allDrained = $false
            Add-Row 'daemon-output-recording' 'FAIL' $_.Exception.Message
        }
    }
    $allProductFiles = @('doctor', 'operation-list', 'device-candidates').Where({ -not (Test-Path -LiteralPath (Join-Path $OutputDirectory "$_.stdout.json")) }).Count -eq 0
    $recordingComplete = $allExited -and $allDrained -and $allProductFiles
    $schemaStatus = if (-not $recordingComplete) { 'NOT_RUN_RECORDING_INCOMPLETE' } elseif (-not $PythonPath) { 'NOT_RUN_PYTHON_NOT_CONFIGURED' } else { 'PENDING_AFTER_RECORDING' }
    Add-Row 'recorded-cli-schema-validation' $schemaStatus 'Validation reads completed original CLI bytes after all producers exit; see spk3-schema-validation.json and schema-invocation.json for the subsequent result.'
    $record = [ordered]@{
        schema = 'arkdeck-windows-spk3-host-record/v1'
        result = $(if ($rows.Where({ $_.status -eq 'FAIL' }).Count -gt 0) { 'FAIL' } else { 'INCOMPLETE' })
        evidenceKind = 'REAL_WINDOWS_HOST_PROBE'
        windowsSupportClaim = $false
        deviceAcceptanceClaim = $false
        recordingComplete = $recordingComplete
        schemaValidation = $schemaStatus
        cases = $rows
    }
    $record | ConvertTo-Json -Depth 16 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $OutputDirectory 'spk3.json')
    $processes | ForEach-Object { $_.Dispose() }
    $schemaInvocation = [ordered]@{ status = $schemaStatus; originalRecordModified = $false; deviceAcceptanceClaim = $false }
    if ($recordingComplete -and $PythonPath) {
        try {
            $resolvedPython = (Resolve-Path -LiteralPath $PythonPath).Path
            & $resolvedPython (Join-Path $PSScriptRoot 'check-readonly.py') --spk3-recordings $OutputDirectory 2>&1 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $OutputDirectory 'schema-validation.log')
            if ($LASTEXITCODE -ne 0) { throw "Schema validator exited with code $LASTEXITCODE; see schema-validation.log. Missing Python dependencies do not establish schema conformance." }
            $schemaInvocation.status = 'VALIDATED'
        } catch {
            $schemaFailed = $true
            $schemaInvocation.status = 'FAILED_OR_NOT_RUN'
            $schemaInvocation.detail = $_.Exception.Message
        }
    }
    $schemaInvocation | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $OutputDirectory 'schema-invocation.json')
}
Write-Output (Join-Path $OutputDirectory 'spk3.json')
if ($schemaFailed -or $rows.Where({ $_.status -eq 'FAIL' }).Count -gt 0) { exit 1 }
# A recorded host run is intentionally not a finished Windows acceptance.
exit 2
