#requires -Version 7.2
# Native file-identity regression only; no product executable, daemon or device starts.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Join-Path $PSScriptRoot 'package-rc.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'package-rc.ps1 does not parse.' }
$names = @('New-PrivateDirectory', 'Initialize-RcSmokeFileIdentity', 'Get-RcSmokeFileIdentity', 'Test-RcSmokeDaemonImage')
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($function.Name -in $names) { . ([scriptblock]::Create($function.Extent.Text)) }
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$local = [Environment]::GetFolderPath('LocalApplicationData')
$logical = Join-Path $local ('arkdeck-rc-path-test-' + [guid]::NewGuid().ToString('N'))
New-PrivateDirectory $logical
$physical = $null
try {
    $directory = Get-RcSmokeFileIdentity $logical
    $physical = $directory.Path
    Assert ($directory.SameFile((Get-RcSmokeFileIdentity $physical))) 'Logical and physical directory handles differ.'
    Assert ($physical -notlike '\\?\*') 'The physical path retains an extended-path prefix.'
    $logicalFile = Join-Path $logical 'installed-image.txt'
    [System.IO.File]::WriteAllText($logicalFile, 'same bytes do not establish process ownership')
    $installed = Get-RcSmokeFileIdentity $logicalFile
    Assert ($installed.SameFile((Get-RcSmokeFileIdentity $installed.Path))) 'Logical and physical file identities differ.'
    Assert (Test-RcSmokeDaemonImage ([pscustomobject]@{ Path = $installed.Path }) $logicalFile) 'The same installed file was refused.'
    $copy = Join-Path $physical 'same-bytes-other-image.txt'
    [System.IO.File]::Copy($installed.Path, $copy)
    Assert ((Get-FileHash -LiteralPath $copy).Hash -eq (Get-FileHash -LiteralPath $installed.Path).Hash) 'Test copy bytes differ.'
    Assert (-not (Test-RcSmokeDaemonImage ([pscustomobject]@{ Path = $copy }) $logicalFile)) 'A different file with identical bytes was admitted.'
    Assert (-not (Test-RcSmokeDaemonImage ([System.Diagnostics.Process]::GetCurrentProcess()) $logicalFile)) 'An unrelated running image was admitted.'
    Assert (-not (Test-RcSmokeDaemonImage ([pscustomobject]@{ Path = $null }) $logicalFile)) 'An unreadable process image was admitted.'
    $refused = $false
    try { [void](Get-RcSmokeFileIdentity (Join-Path $physical 'absent-image')) } catch { $refused = $true }
    Assert $refused 'An absent image did not fail closed.'

    # The single forced cleanup is dominated by positive installed-file ownership.
    $smoke = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RcSmoke' }, $true)[0]
    $kills = @($smoke.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -eq 'Kill' }, $true))
    Assert ($kills.Count -eq 1) 'Expected exactly one forced daemon cleanup.'
    $ownerGuard = $kills[0].Parent
    while ($ownerGuard -and $ownerGuard -isnot [System.Management.Automation.Language.IfStatementAst]) { $ownerGuard = $ownerGuard.Parent }
    Assert ($ownerGuard -and $ownerGuard.Clauses[0].Item1.Extent.Text.Contains('$daemonOwned')) 'Cleanup lacks positive daemon ownership.'
    Write-Host 'PASS: native logical/physical identity, same-byte foreign-file refusal, missing/unreadable refusal and owned cleanup guard.'
} finally {
    # Only this fresh GUID directory is removed; verify its handle identity first.
    $cleanup = if ($physical) { $physical } else { $logical }
    $current = Get-RcSmokeFileIdentity $cleanup
    Assert ($current.SameFile((Get-RcSmokeFileIdentity $logical))) 'The fresh test directory identity changed; nothing removed.'
    Assert ((Split-Path -Leaf $cleanup) -eq (Split-Path -Leaf $logical)) 'The cleanup target left the fresh test directory.'
    Remove-Item -LiteralPath $cleanup -Recurse -Force
}
