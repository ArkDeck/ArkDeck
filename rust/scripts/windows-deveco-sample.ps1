#requires -Version 7.2
<#
Maintainer-run, read-only sampling of the Windows install shape of DevEco Studio's toolchain —
node, hvigor, the bundled JDK and hap-sign-tool — for the Windows registration of those tools as
registered toolchain references (TASK-XPA-011, WM3). The crib is
openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-011/deveco-windows-install-shape-crib-20260930.md.

It records, for the DevEco Studio root given and nothing found through PATH:
  - each known role file: presence, size, SHA-256, Authenticode status and signer (subject,
    leaf certificate SHA-256, timestamp), Mark-of-the-Web zone, file version resource, owner
    and whether any principal other than the user and SYSTEM / Administrators /
    TrustedInstaller may write it or its directory;
  - the names and versions of the SDK components (oh-uni-package.json) and of the hvigor
    package (package.json), and the tools directory's first two levels of names;
  - with -RunVersionProbes: `node.exe --version` and `java.exe -version`, run from the root
    (never from PATH), with an empty working directory and a 20 s bound;
  - whether PATH resolves node / java / hvigorw, and whether that resolution is inside the
    DevEco root (the product never uses it; this shows what a user's shell would pick);
  - the signing material's SHAPE under -SigningConfigDirectory (default
    %USERPROFILE%\.ohos\config): directory names, file extensions, sizes and depth. No file
    under it is opened or read;
  - with -BuildProfile: the shape of one project's build-profile.json5 signing entry: how the
    storeFile path is spelled (separators, escaping, where it points relative to the signing
    config directory), and the LENGTH and hex-ness of storePassword / keyPassword. No password
    value and no path with an account name is recorded.

It writes nothing outside -OutputDirectory, which must be new and outside every git work tree,
changes no file, setting, certificate store or environment, and starts no process other than
the two optional version probes. Nothing of DevEco is copied.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DevEcoRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$SigningConfigDirectory = (Join-Path $env:USERPROFILE '.ohos\config'),
    [string]$BuildProfile,
    [switch]$RunVersionProbes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'DevEco install-shape sampling requires Windows.' }
$DevEcoRoot = (Resolve-Path -LiteralPath $DevEcoRoot).Path
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$probe = $OutputDirectory
while ($probe) {
    if (Test-Path -LiteralPath (Join-Path $probe '.git')) { throw "Choose an output directory outside any git work tree ($probe)." }
    $probe = [System.IO.Path]::GetDirectoryName($probe)
}
if (Test-Path -LiteralPath $OutputDirectory) { throw "Use a new output directory; $OutputDirectory exists." }
[void](New-Item -ItemType Directory -Path $OutputDirectory)

$profileDirectory = $env:USERPROFILE
function Hide-Account([string]$Text) {
    if (-not $Text) { return $Text }
    # Either separator and any case: an account or host name never survives.
    $hidden = $Text.Replace('/', '\')
    foreach ($pair in @(@($DevEcoRoot, '<DevEco>'), @($profileDirectory, '%USERPROFILE%'), @($env:USERNAME, '<user>'), @($env:COMPUTERNAME, '<host>'))) {
        $hidden = [regex]::Replace($hidden, [regex]::Escape($pair[0].Replace('/', '\')), $pair[1], 'IgnoreCase')
    }
    return $hidden
}

# Principals that may write an installed tool, as the Rust reader counts them (ruling 24).
$Trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$WriteRights = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, DeleteSubdirectoriesAndFiles, Delete, ChangePermissions, TakeOwnership'
function Get-AccessShape([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $owner = ([System.Security.Principal.NTAccount]$acl.Owner).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $writers = @(foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne 'Allow' -or -not ($rule.FileSystemRights -band $WriteRights)) { continue }
            try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = $rule.IdentityReference.Value }
            if ($sid -eq $user) { 'user' } elseif ($Trusted -contains $sid) { 'trusted' } else { $sid }
        })
    [ordered]@{
        owner          = if ($owner -eq $user) { 'user' } elseif ($Trusted -contains $owner) { $owner } else { 'other' }
        untrustedWrite = @($writers | Where-Object { $_ -notin @('user', 'trusted') } | Select-Object -Unique)
        userWrite      = $writers -contains 'user'
    }
}

function Get-FileShape([string]$Relative) {
    $path = Join-Path $DevEcoRoot $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [ordered]@{ relative = $Relative; present = $false } }
    $item = Get-Item -LiteralPath $path
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    $leaf = $signature.SignerCertificate
    $zone = $null
    try { $zone = (Get-Content -LiteralPath $path -Stream Zone.Identifier -ErrorAction Stop | Select-String '^ZoneId=').Line } catch { }
    [ordered]@{
        relative        = $Relative
        present         = $true
        bytes           = $item.Length
        sha256          = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        authenticode    = "$($signature.Status)"
        signatureType   = "$($signature.SignatureType)"
        signerSubject   = if ($leaf) { $leaf.Subject } else { $null }
        signerSha256    = if ($leaf) { [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($leaf.RawData)).ToLowerInvariant() } else { $null }
        timestamped     = [bool]$signature.TimeStamperCertificate
        markOfTheWeb    = $zone
        fileVersion     = $item.VersionInfo.FileVersion
        productVersion  = $item.VersionInfo.ProductVersion
        originalName    = $item.VersionInfo.OriginalFilename
        access          = Get-AccessShape $path
        directoryAccess = Get-AccessShape (Split-Path -Parent $path)
    }
}

# The role files D2 read (runs/TASK-XPA-011/windows-deveco-files-run.md) and their neighbours.
$roles = @(
    'bin\devecostudio64.exe',
    'product-info.json',
    'sdk\default\sdk-pkg.json',
    'tools\node\node.exe',
    'tools\hvigor\bin\hvigorw.js',
    'tools\hvigor\hvigor\package.json',
    'tools\ohpm\bin\ohpm.bat',
    'jbr\bin\java.exe',
    'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar',
    'sdk\default\openharmony\toolchains\oh-uni-package.json',
    'sdk\default\openharmony\toolchains\hdc.exe'
)
$sample = [ordered]@{
    schemaVersion = 'arkdeck.windows-deveco-install-shape-sample/1'
    sampledAtUtc  = [DateTime]::UtcNow.ToString('o')
    host          = [ordered]@{ os = [System.Environment]::OSVersion.VersionString; architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }
    root          = [ordered]@{ spelling = Hide-Account $DevEcoRoot; access = Get-AccessShape $DevEcoRoot; underProgramFiles = $DevEcoRoot.StartsWith($env:ProgramFiles, [StringComparison]::OrdinalIgnoreCase) }
    files         = @($roles | ForEach-Object { Get-FileShape $_ })
}

# The tools directory, two levels of names; the hvigor package's own version.
$tools = Join-Path $DevEcoRoot 'tools'
$sample.tools = @(if (Test-Path -LiteralPath $tools) {
        Get-ChildItem -LiteralPath $tools -Directory | ForEach-Object {
            [ordered]@{ name = $_.Name; children = @(Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 40 | ForEach-Object { $_.Name }) }
        }
    })
# hvigor ships as tools\hvigor\{bin, hvigor, hvigor-ohos-plugin}; each package names its version.
$sample.hvigorPackages = @(foreach ($package in @('tools\hvigor\hvigor\package.json', 'tools\hvigor\hvigor-ohos-plugin\package.json')) {
        $path = Join-Path $DevEcoRoot $package
        if (-not (Test-Path -LiteralPath $path)) { [ordered]@{ relative = $package; present = $false }; continue }
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        [ordered]@{ relative = $package; present = $true; name = $document.name; version = $document.version; main = $document.PSObject.Properties['main']?.Value }
    })
# SDK components: every oh-uni-package.json's name and versions.
$sdk = Join-Path $DevEcoRoot 'sdk'
$sample.sdkComponents = @(if (Test-Path -LiteralPath $sdk) {
        Get-ChildItem -LiteralPath $sdk -Recurse -Depth 3 -File -Filter 'oh-uni-package.json' | ForEach-Object {
            $document = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            [ordered]@{
                relative   = $_.FullName.Substring($DevEcoRoot.Length + 1)
                path       = $document.PSObject.Properties['path']?.Value
                version    = $document.PSObject.Properties['version']?.Value
                apiVersion = $document.PSObject.Properties['apiVersion']?.Value
                releaseType = $document.PSObject.Properties['releaseType']?.Value
            }
        }
    })

# What a shell's PATH would pick (the product never searches PATH).
$sample.path = @(foreach ($name in @('node', 'java', 'hvigorw', 'ohpm', 'hdc')) {
        $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        [ordered]@{
            name         = $name
            resolved     = [bool]$found
            insideDevEco = if ($found) { $found.Source.StartsWith($DevEcoRoot, [StringComparison]::OrdinalIgnoreCase) } else { $null }
            spelling     = if ($found) { Hide-Account $found.Source } else { $null }
        }
    })

# Optional version probes, from the root only, bounded, in an empty directory.
if ($RunVersionProbes) {
    $empty = Join-Path $OutputDirectory 'probe-cwd'
    [void](New-Item -ItemType Directory -Path $empty)
    $sample.versionProbes = @(foreach ($probeCase in @(@{ tool = 'tools\node\node.exe'; arguments = @('--version') }, @{ tool = 'jbr\bin\java.exe'; arguments = @('-version') })) {
            $tool = Join-Path $DevEcoRoot $probeCase.tool
            if (-not (Test-Path -LiteralPath $tool)) { [ordered]@{ tool = $probeCase.tool; ran = $false }; continue }
            $info = [System.Diagnostics.ProcessStartInfo]::new($tool)
            foreach ($argument in $probeCase.arguments) { $info.ArgumentList.Add($argument) }
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.RedirectStandardInput = $true
            $info.WorkingDirectory = $empty
            $process = [System.Diagnostics.Process]::Start($info)
            $process.StandardInput.Close()
            $out = $process.StandardOutput.ReadToEndAsync()
            $err = $process.StandardError.ReadToEndAsync()
            $exited = $process.WaitForExit(20000)
            if (-not $exited) { $process.Kill($true) }
            [ordered]@{ tool = $probeCase.tool; arguments = $probeCase.arguments; ran = $true; exited = $exited; exitCode = if ($exited) { $process.ExitCode } else { $null }; stdout = Hide-Account $out.Result; stderr = Hide-Account $err.Result }
        })
}

# The signing material's shape: names, extensions, sizes; nothing is opened.
if (Test-Path -LiteralPath $SigningConfigDirectory) {
    $base = (Resolve-Path -LiteralPath $SigningConfigDirectory).Path
    $sample.signingConfig = [ordered]@{
        spelling = Hide-Account $base
        access   = Get-AccessShape $base
        entries  = @(Get-ChildItem -LiteralPath $base -Recurse -Force -Depth 6 | ForEach-Object {
                $relative = $_.FullName.Substring($base.Length + 1)
                $parts = $relative.Split('\')
                # Directory names DevEco fixes (material, fd, ac, ce, 0-2, openharmony) are kept;
                # any other name (projects, keys) becomes its length and extension.
                $shape = @(foreach ($part in $parts) {
                        if ($part -match '^(material|fd|ac|ce|[0-9]|openharmony|config)$') { $part } else { "<$($part.Length)>$([System.IO.Path]::GetExtension($part))" }
                    }) -join '\'
                [ordered]@{ shape = $shape; directory = $_.PSIsContainer; bytes = if ($_.PSIsContainer) { $null } else { $_.Length } }
            })
    }
} else {
    $sample.signingConfig = [ordered]@{ spelling = Hide-Account $SigningConfigDirectory; present = $false }
}

# One build profile's signing entry, as a shape.
if ($BuildProfile) {
    $text = Get-Content -LiteralPath $BuildProfile -Raw
    function Get-Field([string]$Name) {
        $matches = [regex]::Matches($text, "[`"']?$Name[`"']?\s*:\s*[`"']([^`"']*)[`"']")
        return @($matches | ForEach-Object { $_.Groups[1].Value })
    }
    $stores = Get-Field 'storeFile'
    $sample.buildProfile = [ordered]@{
        storeFileCount = $stores.Count
        storeFiles     = @(foreach ($store in $stores) {
                $unescaped = $store.Replace('\\', '\')
                [ordered]@{
                    doubledBackslashes = $store.Contains('\\')
                    forwardSlashes     = $store.Contains('/')
                    driveLetter        = $store -match '^[A-Za-z]:'
                    relative           = -not ($store -match '^[A-Za-z]:' -or $store.StartsWith('/') -or $store.StartsWith('\'))
                    underSigningConfig = $unescaped.Replace('/', '\').StartsWith($SigningConfigDirectory, [StringComparison]::OrdinalIgnoreCase)
                    extension          = [System.IO.Path]::GetExtension($unescaped)
                    spelling           = (Hide-Account $unescaped) -replace '[^\\/]+(\.(p12|jks))$', '<name>$1'
                }
            })
        passwords      = @(foreach ($name in @('storePassword', 'keyPassword')) {
                foreach ($value in (Get-Field $name)) {
                    [ordered]@{ field = $name; length = $value.Length; hex = $value -match '^[0-9A-Fa-f]+$'; even = ($value.Length % 2) -eq 0 }
                }
            })
    }
}

$path = Join-Path $OutputDirectory 'sample.json'
$sample | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
Write-Host "sample $path"
