#requires -Version 7.2
<#
.SYNOPSIS
The Windows x64 release candidate of the whole product: the daemon, the CLI and the WinUI App
(CHG-2026-074 TASK-XPA-022; r12 decision 10, rulings 8, 12 and 17; Windows 11 x64 only, r13).

.DESCRIPTION
Build mode (default), from one recorded checkout:

  1. Refuses an existing -OutputDirectory, and a checkout with any change or untracked file
     unless -AllowDirty (recorded in the manifest).
  2. Builds and signs `arkdeck-agentd.exe` and `arkdeck.exe` with
     rust/scripts/windows-package-xcopy.ps1 (its own manifest, zip and signer checks), into
     <OutputDirectory>\runtime.
  3. Publishes the App (windows/App: WinUI 3, Windows App SDK 2.5.1 and .NET self-contained,
     ReadyToRun and trimmed, x64) unpackaged (`WindowsPackageType=None`), and signs
     `ArkDeck.exe` the same way as the runtime.
  4. Stages the xcopy form: the App with its daemon beside it (`ArkDeck.exe` and
     `arkdeck-agentd.exe` at the root, the App's default daemon) and the CLI in `bin\` — NTFS
     names are case-insensitive, so `arkdeck.exe` cannot sit beside `ArkDeck.exe`; the CLI is
     pointed at the root's daemon with ARKDECK_DAEMON_PATH. It writes `rc-manifest.json`
     (every file with its size and SHA-256) inside it, zips it, and writes the manifest beside
     the zip with the zip's SHA-256 added.
  5. Builds the MSIX form (r12 decision 10) with the same layout (daemon at the package root,
     CLI in `bin\`), write virtualization off (ruling 8), identity `CN=ArkDeck Development`
     (ruling 12) unless -MsixPublisher names the signing certificate's subject: the package is
     then built from a copy of windows/App/Package.appxmanifest with that Publisher (the
     tracked manifest is never rewritten). It is signed only through -MsixSignCommand (see
     below); its SHA-256 goes into the manifest.
  6. With -FeedBaseUri, writes the App Installer feed `ArkDeck.appinstaller` beside the MSIX,
     from the MSIX this run built (package name, publisher, version and architecture read from
     its AppxManifest.xml), so feed and package always come from one revision.

-SigningMode (the executables):
  none         nothing is signed (CI); the CLI and the App refuse the daemon, so no smoke runs.
  development  rust/scripts/windows-dev-identity.ps1 sign with the host-trusted development
               certificate (-Thumbprint, else ARKDECK_DEV_SIGNER_THUMBPRINT from the process or
               HKCU\Environment). Not an installation identity (design L.1 item 22).
  production   the maintainer's command (-ProductionSignCommand, else
               ARKDECK_PRODUCTION_SIGN_COMMAND), called once per file with the file's path as its
               only argument, for the daemon and the CLI (through windows-package-xcopy.ps1) and
               for ArkDeck.exe. Each must then verify with a timestamp, and all three must carry
               one publisher identity (maintainer ruling 17), and that identity must be the one
               the clients will pin: -ExpectedPublisherOrganization and -ExpectedPublisherEku
               (else ARKDECK_DAEMON_PUBLISHER_ORGANIZATION / ARKDECK_DAEMON_PUBLISHER_EKU, the
               CLI's own installation inputs). Unless -SkipMsix, the MSIX must be signed too:
               -MsixSignCommand and -MsixPublisher are required, and the publisher's O= must be
               the expected organisation. A clean checkout only. This script holds no
               credential; anything unconfigured fails before anything is built.
-MsixSignCommand (else ARKDECK_MSIX_SIGN_COMMAND), in any mode: the maintainer's command that
signs the MSIX, called with its path. The MSIX must then verify, and its signer's subject must be
the manifest's Publisher (a package whose publisher is not its certificate's subject does not
install); with -SigningMode production it must be timestamped. Without it the MSIX stays unsigned
and is recorded as not installable.

-Smoke after a signed build (or -SmokeZip <zip> alone, for a package built before) installs the zip into a new private directory under the
account's local application data (owner-only: the user and SYSTEM), with a private development
state root inside it, and then:

  - checks every file against the manifest and each executable's signer against the pin, or for
    a production RC its timestamped signature against the manifest's publisher identity, which
    the CLI and the App are then configured with (ruling 17);
  - runs `arkdeck --output json doctor`, which starts the installed daemon (decision 11); the
    started process must be the installed image, and doctor must answer `ok: true`;
  - runs the App's UIA smoke (windows/App.UITests `InstalledRcTests`) against the installed
    `ArkDeck.exe`: the App connects to that daemon, shows its doctor report and no recovery
    banner;
  - runs doctor again;
  - uninstalls with windows/scripts/uninstall-rc.ps1 (the daemon stopped through its stop
    event, the directory removed), and checks that no process runs from it, that the
    account's local application data holds no entry it did not hold before, and that
    `%LOCALAPPDATA%\ArkDeck` is as it was.
The uninstall is windows/scripts/uninstall-rc.ps1, run against the installed directory and its
development root: it stops the daemon through its stop event and removes the directory.
It never sleeps to synchronise; it changes no certificate store and starts nothing but the
installed executables and the UIA test host.
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$OutputDirectory,
    [Parameter(ParameterSetName = 'Build')][ValidateSet('none', 'development', 'production')][string]$SigningMode = 'none',
    [Parameter(ParameterSetName = 'Build')][string]$Thumbprint,
    [Parameter(ParameterSetName = 'Build')][string]$ProductionSignCommand,
    [Parameter(ParameterSetName = 'Build')][string]$MsixSignCommand,
    [Parameter(ParameterSetName = 'Build')][string]$MsixPublisher,
    [Parameter(ParameterSetName = 'Build')][string]$ExpectedPublisherOrganization,
    [Parameter(ParameterSetName = 'Build')][string]$ExpectedPublisherEku,
    [Parameter(ParameterSetName = 'Build')][string]$FeedBaseUri,
    [Parameter(ParameterSetName = 'Build')][switch]$AllowDirty,
    [Parameter(ParameterSetName = 'Build')][switch]$SkipMsix,
    [Parameter(ParameterSetName = 'Build')][switch]$Smoke,
    [Parameter(Mandatory, ParameterSetName = 'SmokeOnly')][string]$SmokeZip,
    [string]$SmokeRecord
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Schema = 'arkdeck.windows-rc-package/1'
$SmokeSchema = 'arkdeck.windows-rc-smoke/1'
$ManifestName = 'rc-manifest.json'
$DaemonName = 'arkdeck-agentd.exe'
$CliName = 'arkdeck.exe'
$AppName = 'ArkDeck.exe'
$CommandTimeoutMs = 300000
$DaemonDeadlineMs = 30000
$FeedName = 'ArkDeck.appinstaller'
$AppInstallerNamespace = 'http://schemas.microsoft.com/appx/appinstaller/2021'

# Get-CertificatePin, Get-PublisherIdentity, Get-VerifiedSigner and Invoke-ProductionSigning,
# shared with rust/scripts/windows-package-xcopy.ps1.
. (Join-Path $PSScriptRoot '..\..\rust\scripts\windows-signing-common.ps1')

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

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Resolve-DevelopmentThumbprint {
    $value = if ($Thumbprint) { $Thumbprint } else { $env:ARKDECK_DEV_SIGNER_THUMBPRINT }
    if (-not $value) {
        $value = (Get-ItemProperty -LiteralPath 'HKCU:\Environment' -Name ARKDECK_DEV_SIGNER_THUMBPRINT -ErrorAction SilentlyContinue).ARKDECK_DEV_SIGNER_THUMBPRINT
    }
    if (-not $value) { throw 'Development signing needs -Thumbprint or ARKDECK_DEV_SIGNER_THUMBPRINT (rust/scripts/windows-dev-identity.ps1 create). Nothing was built.' }
    return $value
}

function Get-Pwsh {
    $current = (Get-Process -Id $PID).Path
    if ($current -and (Split-Path -Leaf $current) -eq 'pwsh.exe') { return $current }
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'PowerShell 7 (pwsh) is required.'
}

function Get-Dotnet {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $installed = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $installed) { return $installed }
    throw 'The .NET SDK (windows/global.json) is required.'
}

# The same signature as the runtime's: windows-dev-identity.ps1 sign, then Valid and the pin.
function Invoke-DevelopmentSigning([string]$Path, [string]$thumbprint, [string]$repository) {
    $script = Join-Path $repository 'rust/scripts/windows-dev-identity.ps1'
    $answer = Invoke-Checked (Get-Pwsh) @('-NoProfile', '-NonInteractive', '-File', $script, 'sign', '-Thumbprint', $thumbprint, '-Path', $Path)
    $pin = (($answer -join "`n") | ConvertFrom-Json).pin
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { throw "$Path does not carry a valid Authenticode signature after signing ($($signature.Status))." }
    $actual = [System.Security.Cryptography.SHA256]::HashData($signature.SignerCertificate.RawData)
    $actual = ([System.Convert]::ToHexString($actual)).ToLowerInvariant()
    if ($actual -ne $pin) { throw "$Path carries signer $actual, not $pin." }
    return $pin
}

# A maintainer's signing command, resolved before anything is built: an unconfigured or absent
# command fails at once.
function Resolve-SignCommand([string]$Value, [string]$Variable, [string]$What, [bool]$Required) {
    $command = if ($Value) { $Value } else { [Environment]::GetEnvironmentVariable($Variable) }
    if (-not $command) {
        if ($Required) { throw "$What is not configured: pass it or set $Variable to the maintainer's signing command. Nothing was built or signed." }
        return $null
    }
    if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw "The signing command $command does not exist. Nothing was built or signed." }
    return (Resolve-Path -LiteralPath $command).Path
}

# A package publisher: a distinguished name with a CN= (what makeappx and App Installer compare
# with the signing certificate's subject), no control character, at most 8192 characters.
function Test-MsixPublisher([string]$Value) {
    try { $name = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Value) } catch { $name = $null }
    if (-not $name -or $Value.Length -gt 8192 -or $Value -match '[\x00-\x1f]' -or $Value -notmatch '(^|,\s*)CN=') {
        throw "-MsixPublisher must be the signing certificate's subject as a distinguished name with a CN=: $Value"
    }
}

function Get-SubjectOrganization([string]$Subject) {
    $name = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Subject)
    $organizations = @(foreach ($rdn in $name.EnumerateRelativeDistinguishedNames()) {
            if ($rdn.GetSingleElementType().Value -eq '2.5.4.10') { $rdn.GetSingleElementValue() }
        })
    if ($organizations.Count -ne 1) { return $null }
    return $organizations[0]
}

# The feed's base URI: absolute https, ending in '/', where the maintainer hosts the feed and the
# MSIX side by side.
function Test-FeedBaseUri([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or -not $Value.EndsWith('/') -or $uri.Query -or $uri.Fragment) {
        throw "-FeedBaseUri must be an absolute https URI ending in '/', with no query or fragment: $Value"
    }
    return $Value
}

# The App Installer feed of one built MSIX: its identity as the package itself declares it.
function New-AppInstallerFeed([string]$Path, [string]$BaseUri, [string]$MsixName, $Identity) {
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.NewLineChars = "`n"
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('AppInstaller', $AppInstallerNamespace)
        $writer.WriteAttributeString('Version', $Identity.Version)
        $writer.WriteAttributeString('Uri', "$BaseUri$FeedName")
        $writer.WriteStartElement('MainPackage', $AppInstallerNamespace)
        $writer.WriteAttributeString('Name', $Identity.Name)
        $writer.WriteAttributeString('Publisher', $Identity.Publisher)
        $writer.WriteAttributeString('Version', $Identity.Version)
        $writer.WriteAttributeString('ProcessorArchitecture', $Identity.ProcessorArchitecture)
        $writer.WriteAttributeString('Uri', "$BaseUri$MsixName")
        $writer.WriteEndElement()
        $writer.WriteStartElement('UpdateSettings', $AppInstallerNamespace)
        $writer.WriteStartElement('OnLaunch', $AppInstallerNamespace)
        $writer.WriteAttributeString('HoursBetweenUpdateChecks', '0')
        $writer.WriteAttributeString('ShowPrompt', 'true')
        $writer.WriteAttributeString('UpdateBlocksActivation', 'false')
        $writer.WriteEndElement()
        $writer.WriteElementString('ForceUpdateFromAnyVersion', $AppInstallerNamespace, 'false')
        $writer.WriteStartElement('AutomaticBackgroundTask', $AppInstallerNamespace)
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    } finally {
        $writer.Dispose()
    }
}

function Get-FileList([string]$Directory) {
    $root = (Resolve-Path -LiteralPath $Directory).Path.TrimEnd('\') + '\'
    return @(Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object { $_.Name -ne $ManifestName } | Sort-Object FullName | ForEach-Object {
            [ordered]@{ path = $_.FullName.Substring($root.Length).Replace('\', '/'); bytes = $_.Length; sha256 = Get-Sha256 $_.FullName }
        })
}

function New-RcBuild {
    if (Test-Path -LiteralPath $OutputDirectory) { throw "$OutputDirectory exists; a package is never written over an existing directory." }
    $repository = (Invoke-Checked git @('-C', $PSScriptRoot, 'rev-parse', '--show-toplevel')).Trim()
    $revision = (Invoke-Checked git @('-C', $repository, 'rev-parse', 'HEAD')).Trim()
    $status = @(Invoke-Checked git @('-C', $repository, 'status', '--porcelain=v1', '--untracked-files=all') | Where-Object { $_ })
    $dirty = $status.Count -gt 0
    if ($dirty -and -not $AllowDirty) {
        throw "The checkout at $repository is not clean ($($status.Count) entries); commit or remove them, or pass -AllowDirty (recorded in the manifest).`n$($status -join "`n")"
    }
    if ($SigningMode -eq 'production' -and $dirty) { throw 'A production release candidate is built from a clean checkout only.' }
    # Signing and the feed are configured before anything is built: an unconfigured mode fails at once.
    $thumbprint = if ($SigningMode -eq 'development') { Resolve-DevelopmentThumbprint } else { $null }
    $productionCommand = if ($SigningMode -eq 'production') { Resolve-SignCommand $ProductionSignCommand 'ARKDECK_PRODUCTION_SIGN_COMMAND' 'Production signing' $true } else { $null }
    $msixCommand = Resolve-SignCommand $MsixSignCommand 'ARKDECK_MSIX_SIGN_COMMAND' 'MSIX signing' $false
    if ($msixCommand -and $SkipMsix) { throw '-MsixSignCommand needs the MSIX; drop -SkipMsix.' }
    $feedBase = if ($FeedBaseUri) { Test-FeedBaseUri $FeedBaseUri } else { $null }
    if ($MsixPublisher) {
        if ($SkipMsix) { throw '-MsixPublisher needs the MSIX; drop -SkipMsix.' }
        Test-MsixPublisher $MsixPublisher
    }
    $expectedPublisher = $null
    if ($SigningMode -eq 'production') {
        # Ruling 17: the identity the CLI and the daemon's clients will pin, given by the
        # maintainer, never derived from what was signed.
        $organization = if ($ExpectedPublisherOrganization) { $ExpectedPublisherOrganization } else { [Environment]::GetEnvironmentVariable('ARKDECK_DAEMON_PUBLISHER_ORGANIZATION') }
        $eku = if ($ExpectedPublisherEku) { $ExpectedPublisherEku } else { [Environment]::GetEnvironmentVariable('ARKDECK_DAEMON_PUBLISHER_EKU') }
        if (-not $organization -or -not $eku) {
            throw 'A production release candidate needs the publisher identity the clients pin (maintainer ruling 17): -ExpectedPublisherOrganization and -ExpectedPublisherEku, or ARKDECK_DAEMON_PUBLISHER_ORGANIZATION and ARKDECK_DAEMON_PUBLISHER_EKU. Nothing was built or signed.'
        }
        if ($organization -ne $organization.Trim() -or $eku -notmatch '^1\.3\.6\.1\.4\.1\.311\.97\.[0-9]+(\.[0-9]+)*$' -or $eku -eq '1.3.6.1.4.1.311.97.1.0') {
            throw "The expected publisher identity is malformed: the organisation must have no outer whitespace and the EKU must be an Artifact Signing certificate-profile identity (1.3.6.1.4.1.311.97.<profile>, not the Public Trust marker). Nothing was built or signed."
        }
        $expectedPublisher = [ordered]@{ organization = $organization; eku = $eku }
        if (-not $SkipMsix) {
            if (-not $msixCommand) { throw 'A production release candidate signs its MSIX: pass -MsixSignCommand or set ARKDECK_MSIX_SIGN_COMMAND (or -SkipMsix). Nothing was built or signed.' }
            if (-not $MsixPublisher) { throw 'A production MSIX is published under its signing certificate''s subject: pass -MsixPublisher "<subject>" (or -SkipMsix). Nothing was built or signed.' }
            if ((Get-SubjectOrganization $MsixPublisher) -ne $organization) {
                throw "-MsixPublisher names O=$(Get-SubjectOrganization $MsixPublisher), not the expected publisher $organization. Nothing was built or signed."
            }
        }
    }
    if ($feedBase -and $SkipMsix) { throw '-FeedBaseUri needs the MSIX; drop -SkipMsix.' }
    $dotnet = Get-Dotnet
    $releaseVersion = Get-Content -LiteralPath (Join-Path $repository 'scripts/release/release-version.json') -Raw | ConvertFrom-Json
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
    $output = (Resolve-Path -LiteralPath $OutputDirectory).Path

    # 1. The daemon and the CLI: the xcopy script's build, signing and checks.
    $runtimeOutput = Join-Path $output 'runtime'
    $xcopy = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repository 'rust/scripts/windows-package-xcopy.ps1'), '-OutputDirectory', $runtimeOutput, '-SigningMode', $SigningMode)
    if ($thumbprint) { $xcopy += @('-Thumbprint', $thumbprint) }
    if ($productionCommand) { $xcopy += @('-ProductionSignCommand', $productionCommand) }
    if ($AllowDirty) { $xcopy += '-AllowDirty' }
    & (Get-Pwsh) @xcopy | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "windows-package-xcopy.ps1 exited $LASTEXITCODE" }
    $runtimeManifest = Get-Content -LiteralPath (Join-Path $runtimeOutput 'manifest.json') -Raw | ConvertFrom-Json
    $runtimeStage = @(Get-ChildItem -LiteralPath $runtimeOutput -Directory)
    if ($runtimeStage.Count -ne 1) { throw 'The runtime build left more than one package directory.' }
    $runtimeStage = $runtimeStage[0].FullName
    if ($runtimeManifest.sourceRevision -ne $revision) { throw 'The runtime was built from another revision.' }
    if ($expectedPublisher) {
        $runtimePublisher = $runtimeManifest.signing.publisher
        if ($runtimePublisher.organization -ne $expectedPublisher.organization -or $runtimePublisher.eku -ne $expectedPublisher.eku) {
            throw "The runtime is signed by $($runtimePublisher.organization) / $($runtimePublisher.eku), not the expected publisher $($expectedPublisher.organization) / $($expectedPublisher.eku)."
        }
    }

    # 2. The App, unpackaged, self-contained, published (ReadyToRun + trimmed).
    $appProject = Join-Path $repository 'windows/App/ArkDeck.App.csproj'
    $appPublish = Join-Path $output 'app-publish'
    $dotnetVersion = (Invoke-Checked $dotnet @('--version') (Join-Path $repository 'windows')).Trim()
    $publish = @('publish', $appProject, '-c', 'Release', '-p:Platform=x64', '-p:WindowsPackageType=None', '-o', $appPublish, '--nologo')
    Write-Host "dotnet $($publish -join ' ')"
    & $dotnet @publish | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish (unpackaged App) exited $LASTEXITCODE" }
    foreach ($name in @($DaemonName, 'bin')) {
        if (Test-Path -LiteralPath (Join-Path $appPublish $name)) { throw "The App's publish output already holds $name." }
    }
    $appPin = $null
    $appPath = Join-Path $appPublish $AppName
    if ($SigningMode -eq 'development') {
        $appPin = Invoke-DevelopmentSigning $appPath $thumbprint $repository
        if ($appPin -ne $runtimeManifest.signing.signerSha256) { throw "The App and the runtime carry different signers." }
    } elseif ($SigningMode -eq 'production') {
        [void](Invoke-ProductionSigning @($appPath) $productionCommand)
        $appSigner = Get-VerifiedSigner $appPath $true
        $appPublisher = Get-PublisherIdentity $appSigner.certificate
        $runtimePublisher = $runtimeManifest.signing.publisher
        if ($appPublisher.organization -ne $runtimePublisher.organization -or $appPublisher.eku -ne $runtimePublisher.eku) {
            throw "ArkDeck.exe carries publisher $($appPublisher.organization) / $($appPublisher.eku), not the runtime's $($runtimePublisher.organization) / $($runtimePublisher.eku)."
        }
    }

    # 3. The xcopy form: the App beside its daemon, the CLI in bin\.
    $name = "arkdeck-rc-$($releaseVersion.version)-windows-x64-$($revision.Substring(0, 12))"
    $stage = Join-Path $output $name
    Copy-Item -LiteralPath $appPublish -Destination $stage -Recurse
    Copy-Item -LiteralPath (Join-Path $runtimeStage $DaemonName) -Destination $stage
    [void](New-Item -ItemType Directory -Path (Join-Path $stage 'bin'))
    Copy-Item -LiteralPath (Join-Path $runtimeStage $CliName) -Destination (Join-Path $stage 'bin')

    # 4. The MSIX form: the same App with the signed daemon and CLI at the package root, unsigned.
    $msix = $null
    if (-not $SkipMsix) {
        $msixDirectory = Join-Path $output 'msix'
        $package = @('publish', $appProject, '-c', 'Release', '-p:Platform=x64', '-p:GenerateAppxPackageOnBuild=true',
            "-p:AppxPackageDir=$msixDirectory\", "-p:ArkDeckRuntimeDirectory=$runtimeStage", '--nologo')
        if ($MsixPublisher) {
            # The signing certificate's subject as the package publisher, in a copy of the
            # tracked manifest: nothing in the checkout changes.
            $manifestCopy = Join-Path $output 'msix-manifest\Package.appxmanifest'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $manifestCopy))
            [xml]$source = Get-Content -LiteralPath (Join-Path $repository 'windows/App/Package.appxmanifest') -Raw
            $source.Package.Identity.SetAttribute('Publisher', $MsixPublisher)
            $source.Save($manifestCopy)
            $package += "-p:ArkDeckPackageManifest=$manifestCopy"
        }
        Write-Host "dotnet $($package -join ' ')"
        & $dotnet @package | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish (MSIX) exited $LASTEXITCODE" }
        $packages = @(Get-ChildItem -LiteralPath $msixDirectory -Recurse -File -Filter '*.msix')
        if ($packages.Count -ne 1) { throw "Expected one MSIX under $msixDirectory, found $($packages.Count)." }
        $archive = [System.IO.Compression.ZipFile]::OpenRead($packages[0].FullName)
        try {
            $entries = @($archive.Entries | ForEach-Object { $_.FullName })
            foreach ($required in @($AppName, $DaemonName, "bin/$CliName", 'AppxManifest.xml')) {
                if ($entries -notcontains $required) { throw "The MSIX has no $required." }
            }
            $inside = @{}
            foreach ($file in @($DaemonName, "bin/$CliName")) {
                $stream = $archive.GetEntry($file).Open()
                try { $inside[(Split-Path -Leaf $file)] = ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream))).ToLowerInvariant() } finally { $stream.Dispose() }
            }
            $reader = [System.IO.StreamReader]::new($archive.GetEntry('AppxManifest.xml').Open())
            try { [xml]$appx = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally {
            $archive.Dispose()
        }
        foreach ($file in @($DaemonName, $CliName)) {
            if ($inside[$file] -ne (Get-Sha256 (Join-Path $runtimeStage $file))) { throw "The MSIX's $file is not the runtime build's." }
        }
        $identity = $appx.Package.Identity
        # The signing hook: the maintainer's command signs the package in place.
        $msixSigning = [ordered]@{ signed = $false; installable = $false; note = 'Unsigned: Windows installs only a signed MSIX (the development certificate of ruling 12, or the production publisher).' }
        if ($msixCommand) {
            [void](Invoke-ProductionSigning @($packages[0].FullName) $msixCommand)
            $signer = Get-VerifiedSigner $packages[0].FullName ($SigningMode -eq 'production')
            if ($MsixPublisher -and $identity.Publisher -ne $MsixPublisher) {
                throw "The MSIX was built with publisher $($identity.Publisher), not -MsixPublisher $MsixPublisher."
            }
            if ($signer.subject -ne $identity.Publisher) {
                throw "The MSIX is signed by $($signer.subject), but its manifest names the publisher $($identity.Publisher); Windows would refuse to install it."
            }
            $msixSigning = [ordered]@{ signed = $true; installable = $true; signerSubject = $signer.subject; signerSha256 = $signer.pin; timestamped = $signer.timestamped; command = [System.IO.Path]::GetFileName($msixCommand) }
            $packages[0].Refresh()
        }
        $msix = [ordered]@{
            name                        = $packages[0].Name
            bytes                       = $packages[0].Length
            sha256                      = Get-Sha256 $packages[0].FullName
            signed                      = $msixSigning.signed
            signing                     = $msixSigning
            processorArchitecture       = $identity.ProcessorArchitecture
            identityName                = $identity.Name
            publisher                   = $identity.Publisher
            packageVersion              = $identity.Version
            writeVirtualizationDisabled = ($appx.OuterXml -match 'FileSystemWriteVirtualization>disabled<') -and ($appx.OuterXml -match 'RegistryWriteVirtualization>disabled<')
            daemonSha256                = $inside[$DaemonName]
            cliSha256                   = $inside[$CliName]
            entries                     = $entries.Count
        }
        Copy-Item -LiteralPath $packages[0].FullName -Destination $output
        if ($feedBase) {
            $feedPath = Join-Path $output $FeedName
            New-AppInstallerFeed $feedPath $feedBase $packages[0].Name $identity
            [xml]$feed = Get-Content -LiteralPath $feedPath -Raw
            if ($feed.AppInstaller.MainPackage.Version -ne $identity.Version -or $feed.AppInstaller.MainPackage.Name -ne $identity.Name -or $feed.AppInstaller.MainPackage.Publisher -ne $identity.Publisher) {
                throw 'The App Installer feed does not name the MSIX this run built.'
            }
            $msix.appInstaller = [ordered]@{
                name           = $FeedName
                bytes          = (Get-Item -LiteralPath $feedPath).Length
                sha256         = Get-Sha256 $feedPath
                uri            = "$feedBase$FeedName"
                mainPackageUri = "$feedBase$($packages[0].Name)"
                version        = $identity.Version
                note           = 'Host the feed and the MSIX at these URIs; App Installer updates only to a higher package version, so the package Version in windows/App/Package.appxmanifest must increase with each published RC.'
            }
        }
    }

    $manifest = [ordered]@{
        schemaVersion  = $Schema
        kind           = 'windows-rc-app-daemon-cli'
        version        = $releaseVersion.version
        build          = $releaseVersion.build
        sourceRevision = $revision
        dirty          = $dirty
        allowDirty     = [bool]$AllowDirty
        dirtyEntries   = @($status)
        target         = 'x86_64-pc-windows-msvc / win-x64'
        toolchains     = [ordered]@{
            rustc          = $runtimeManifest.rustc
            cargo          = $runtimeManifest.cargo
            dotnetSdk      = $dotnetVersion
            windowsAppSdk  = '2.5.1'
            appPublish     = 'unpackaged, self-contained, ReadyToRun, trimmed'
        }
        createdAtUtc   = [DateTime]::UtcNow.ToString('o')
        signing        = [ordered]@{
            mode         = $SigningMode
            signerSha256 = $runtimeManifest.signing.signerSha256
            publisher    = if ($SigningMode -eq 'production') { $runtimeManifest.signing.publisher } else { $null }
            expectedPublisher = $expectedPublisher
            signed       = if ($SigningMode -ne 'none') { @($AppName, "bin/$CliName", $DaemonName) } else { @() }
            note         = switch ($SigningMode) {
                'development' { 'Host-trusted development signer (design L.1 item 22); not an installation identity.' }
                'production' { 'Production signatures, timestamped, one publisher identity (maintainer ruling 17).' }
                default { 'Unsigned: the CLI and the App refuse this daemon until it is signed.' }
            }
        }
        runtime        = [ordered]@{ manifest = 'runtime/manifest.json'; zipSha256 = $runtimeManifest.zip.sha256 }
        layout         = [ordered]@{
            app    = $AppName
            daemon = $DaemonName
            cli    = "bin/$CliName"
            note   = "NTFS names are case-insensitive: the CLI cannot sit beside ArkDeck.exe. The App's daemon is its sibling by default; the CLI is given ARKDECK_DAEMON_PATH."
        }
        daemonConfiguration = if ($SigningMode -eq 'production') {
            [ordered]@{
                ARKDECK_DAEMON_PUBLISHER_ORGANIZATION = $runtimeManifest.signing.publisher.organization
                ARKDECK_DAEMON_PUBLISHER_EKU          = $runtimeManifest.signing.publisher.eku
                ARKDECK_DAEMON_PATH                   = "the App: unset ($DaemonName beside ArkDeck.exe); the CLI: <install>\$DaemonName"
                note                                  = 'The CLI and the App read the same publisher inputs (ruling 17); no certificate hash is pinned in production.'
            }
        } else {
            [ordered]@{
                ARKDECK_DAEMON_SIGNER_SHA256 = $runtimeManifest.signing.signerSha256
                ARKDECK_DAEMON_PATH          = "the App: unset ($DaemonName beside ArkDeck.exe); the CLI: <install>\$DaemonName"
            }
        }
        msix           = $msix
        files          = Get-FileList $stage
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage $ManifestName) -Encoding utf8NoBOM
    $zip = Join-Path $output "$name.zip"
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $manifest.zip = [ordered]@{ name = "$name.zip"; bytes = (Get-Item -LiteralPath $zip).Length; sha256 = Get-Sha256 $zip }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output $ManifestName) -Encoding utf8NoBOM
    Write-Host "rc       $zip"
    Write-Host "sha256   $($manifest.zip.sha256)"
    if ($msix) { Write-Host "msix     $($msix.name) ($(if ($msix.signed) { 'signed' } else { 'unsigned' })) $($msix.sha256)" }
    if ($msix -and $msix.Contains('appInstaller')) { Write-Host "feed     $($msix.appInstaller.name) -> $($msix.appInstaller.uri)" }
    return [pscustomobject]@{ Zip = $zip; Output = $output; Manifest = $manifest; Repository = (Invoke-Checked git @('-C', $PSScriptRoot, 'rev-parse', '--show-toplevel')).Trim() }
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

# A directory owned by the user with a protected DACL of the user and SYSTEM.
function New-PrivateDirectory([string]$Path) {
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($user)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($user, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    [void][System.IO.FileSystemAclExtensions]::Create([System.IO.DirectoryInfo]::new($Path), $security)
}

function Get-TreeListing([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$(if ($_.PSIsContainer) { 0 } else { $_.Length })|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object)
}

function Invoke-RcSmoke($Built) {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $productRoot = Join-Path $localAppData 'ArkDeck'
    $before = @(Get-ChildItem -LiteralPath $localAppData -Force | ForEach-Object { $_.Name } | Sort-Object)
    $productBefore = Get-TreeListing $productRoot
    $work = Join-Path $localAppData "arkdeck-rc-smoke-$([guid]::NewGuid().ToString('N'))"
    New-PrivateDirectory $work
    $record = [ordered]@{
        schemaVersion = $SmokeSchema
        zip           = $Built.Zip
        zipSha256     = Get-Sha256 $Built.Zip
        installRoot   = '<LocalAppData>\' + (Split-Path -Leaf $work)
        steps         = [System.Collections.Generic.List[object]]::new()
    }
    $daemon = $null
    $result = 'FAIL'
    try {
        # Install: the zip into the private root, every file checked against the manifest.
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Built.Zip, (Join-Path $work 'install'))
        $packages = @(Get-ChildItem -LiteralPath (Join-Path $work 'install') -Directory)
        if ($packages.Count -ne 1) { throw 'The zip must hold exactly one package directory.' }
        $install = $packages[0].FullName
        $manifest = Get-Content -LiteralPath (Join-Path $install $ManifestName) -Raw | ConvertFrom-Json
        if ($manifest.schemaVersion -ne $Schema) { throw "The package manifest is not $Schema." }
        $installed = Get-FileList $install
        if ($installed.Count -ne @($manifest.files).Count) { throw "The install holds $($installed.Count) files, the manifest names $(@($manifest.files).Count)." }
        foreach ($file in $manifest.files) {
            if ((Get-Sha256 (Join-Path $install $file.path)) -ne $file.sha256) { throw "$($file.path) differs from the package manifest." }
        }
        $record.files = $installed.Count
        # A production RC is pinned by its publisher identity (ruling 17): the leaf renews
        # daily, so no certificate hash is pinned. A development RC keeps its signer pin.
        $publisher = if ($manifest.signing.mode -eq 'production') { $manifest.signing.publisher } else { $null }
        $pin = if ($publisher) { $null } else { $manifest.signing.signerSha256 }
        if (-not $pin -and -not $publisher) { throw 'The package is unsigned; the CLI and the App refuse an unsigned daemon, so there is nothing to smoke.' }
        foreach ($name in @($AppName, "bin\$CliName", $DaemonName)) {
            $signer = Get-VerifiedSigner (Join-Path $install $name) ([bool]$publisher)
            if ($publisher) {
                $identity = Get-PublisherIdentity $signer.certificate
                if ($identity.organization -ne $publisher.organization -or $identity.eku -ne $publisher.eku) { throw "$name does not carry the manifest's publisher." }
            } elseif ($signer.pin -ne $pin) {
                throw "$name does not carry the manifest's signer."
            }
        }
        if ($publisher) { $record.publisher = [ordered]@{ organization = $publisher.organization; eku = $publisher.eku } } else { $record.signerSha256 = $pin }

        $state = Join-Path $work 'state'
        New-PrivateDirectory $state
        $environment = @{}
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            if ($entry.Key -notmatch '^(ARKDECK_|OHOS_HDC_)') { $environment[$entry.Key] = $entry.Value }
        }
        if ($publisher) {
            $environment['ARKDECK_DAEMON_PUBLISHER_ORGANIZATION'] = $publisher.organization
            $environment['ARKDECK_DAEMON_PUBLISHER_EKU'] = $publisher.eku
        } else {
            $environment['ARKDECK_DAEMON_SIGNER_SHA256'] = $pin
        }
        $environment['ARKDECK_DEVELOPMENT_STATE_ROOT'] = $state
        $environment['ARKDECK_DAEMON_PATH'] = Join-Path $install $DaemonName
        $cli = Join-Path $install "bin\$CliName"
        $step = { param($Name, $Answer) $record.steps.Add([ordered]@{ name = $Name; exitCode = $Answer.exitCode; stdout = $Answer.stdout; stderr = $Answer.stderr }) }

        # First start: the CLI starts the installed daemon (decision 11).
        $doctor = Invoke-Process $cli @('--output', 'json', 'doctor') $environment $work
        & $step 'doctor (first start)' $doctor
        $instancePath = Join-Path $state 'instance.json'
        if (-not (Test-Path -LiteralPath $instancePath)) { throw "doctor started no daemon: $($doctor.stdout) $($doctor.stderr)" }
        $instance = Get-Content -LiteralPath $instancePath -Raw | ConvertFrom-Json
        $daemon = Get-Process -Id ([int]$instance.pid)
        if ($daemon.Path -ne (Join-Path $install $DaemonName)) { throw "The started daemon $($instance.pid) runs $($daemon.Path), not the installed image." }
        $doctorJson = Get-Json $doctor.stdout
        if ($doctor.exitCode -ne 0 -or $doctorJson.ok -ne $true) { throw "doctor exited $($doctor.exitCode): $($doctor.stdout) $($doctor.stderr)" }
        $record.daemonPid = [int]$instance.pid
        $record.endpoint = $instance.socketPath
        $record.doctor = 'PASS'

        # The App: the UIA smoke against the installed ArkDeck.exe and this daemon.
        $dotnet = Get-Dotnet
        $uitests = Join-Path $Built.Repository 'windows/App.UITests'
        $build = Invoke-Process $dotnet @('build', $uitests, '-c', 'Release', '--nologo') $environment $Built.Repository
        if ($build.exitCode -ne 0) { throw "Building the UIA tests failed: $($build.stdout) $($build.stderr)" }
        $uiEnvironment = $environment.Clone()
        foreach ($key in @('ARKDECK_DAEMON_SIGNER_SHA256', 'ARKDECK_DAEMON_PUBLISHER_ORGANIZATION', 'ARKDECK_DAEMON_PUBLISHER_EKU', 'ARKDECK_DEVELOPMENT_STATE_ROOT', 'ARKDECK_DAEMON_PATH')) {
            $uiEnvironment.Remove($key)
        }
        $uiEnvironment['ARKDECK_APP_UITESTS'] = '1'
        $uiEnvironment['ARKDECK_RC_APP'] = Join-Path $install $AppName
        $uiEnvironment['ARKDECK_RC_ENDPOINT'] = $instance.socketPath
        if ($publisher) {
            $uiEnvironment['ARKDECK_RC_PUBLISHER_ORGANIZATION'] = $publisher.organization
            $uiEnvironment['ARKDECK_RC_PUBLISHER_EKU'] = $publisher.eku
        } else {
            $uiEnvironment['ARKDECK_RC_SIGNER_SHA256'] = $pin
        }
        # The outcome is read from the TRX, not the (localised) console: exactly one test, passed.
        $results = Join-Path $work 'uitest'
        $ui = Invoke-Process $dotnet @('test', $uitests, '-c', 'Release', '--no-build', '--nologo', '--filter', 'FullyQualifiedName~InstalledRcTests',
            '--results-directory', $results, '--logger', 'trx;LogFileName=installed-rc.trx') $uiEnvironment $Built.Repository
        & $step 'App UIA smoke (InstalledRcTests)' $ui
        $trx = Join-Path $results 'installed-rc.trx'
        $counters = if (Test-Path -LiteralPath $trx) { ([xml](Get-Content -LiteralPath $trx -Raw)).TestRun.ResultSummary.Counters } else { $null }
        if ($ui.exitCode -ne 0 -or -not $counters -or $counters.total -ne '1' -or $counters.passed -ne '1') {
            $message = if (Test-Path -LiteralPath $trx) { (([xml](Get-Content -LiteralPath $trx -Raw)).TestRun.Results.UnitTestResult.Output.ErrorInfo.Message) } else { $ui.stdout }
            throw "The App's UIA smoke did not pass (exit $($ui.exitCode), total $($counters.total), passed $($counters.passed)): $message"
        }
        $record.app = 'PASS'

        $again = Invoke-Process $cli @('--output', 'json', 'doctor') $environment $work
        & $step 'doctor (daemon running)' $again
        if ($again.exitCode -ne 0 -or (Get-Json $again.stdout).ok -ne $true) { throw "doctor (daemon running) exited $($again.exitCode)." }

        # Uninstall: the uninstall script stops the installed daemon through its stop event and
        # removes the installed directory.
        $uninstall = Invoke-Process (Get-Pwsh) @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'uninstall-rc.ps1'),
            '-InstallDirectory', $install, '-DevelopmentStateRoot', $state) $environment $work
        & $step 'uninstall-rc.ps1' $uninstall
        $answer = Get-Json $uninstall.stdout
        if ($uninstall.exitCode -ne 0 -or -not $answer -or $answer.removed -ne $true -or $answer.daemon.running -ne $true -or $answer.daemon.pid -ne [int]$instance.pid) {
            throw "uninstall-rc.ps1 exited $($uninstall.exitCode): $($uninstall.stdout) $($uninstall.stderr)"
        }
        if (-not $daemon.HasExited) { throw 'The daemon still runs after the uninstall.' }
        $record.uninstallScript = [ordered]@{ removed = $answer.removed; daemonStopped = $answer.daemon.exited; kept = $answer.kept }
        $daemon = $null
        $result = 'PASS'
    } catch {
        $record.error = $_.Exception.Message
    } finally {
        if ($daemon -and -not $daemon.HasExited) {
            # Only the daemon this smoke proved it started (the installed image).
            $daemon.Kill($true)
            [void]$daemon.WaitForExit($DaemonDeadlineMs)
            $record.daemonKilled = $true
        }
        # Uninstall: the directory goes; nothing of it may run or remain.
        $running = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($work, [StringComparison]::OrdinalIgnoreCase) })
        $record.processesLeftBeforeUninstall = $running.Count
        Remove-Item -LiteralPath $work -Recurse -Force
        $after = @(Get-ChildItem -LiteralPath $localAppData -Force | ForEach-Object { $_.Name } | Sort-Object)
        $record.uninstall = [ordered]@{
            directoryRemoved          = -not (Test-Path -LiteralPath $work)
            newLocalAppDataEntries    = @($after | Where-Object { $before -notcontains $_ })
            productRootUnchanged      = ((Get-TreeListing $productRoot) -join "`n") -eq ($productBefore -join "`n")
            processesRunningFromIt    = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($work, [StringComparison]::OrdinalIgnoreCase) }).Count
        }
        if ($result -eq 'PASS' -and ($running.Count -ne 0 -or -not $record.uninstall.directoryRemoved -or $record.uninstall.newLocalAppDataEntries.Count -ne 0 -or -not $record.uninstall.productRootUnchanged -or $record.uninstall.processesRunningFromIt -ne 0)) {
            $result = 'FAIL'
            $record.error = 'The uninstall left something behind.'
        }
        $record.result = $result
    }
    $json = $record | ConvertTo-Json -Depth 8
    $path = if ($SmokeRecord) { $SmokeRecord } else { Join-Path $Built.Output 'smoke.json' }
    $json | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-Host "smoke $result (doctor: $($record['doctor']); app: $($record['app'])); record $path"
    if ($result -ne 'PASS') { throw "The RC smoke failed: $($record['error'])" }
}

if ($PSCmdlet.ParameterSetName -eq 'SmokeOnly') {
    $zip = (Resolve-Path -LiteralPath $SmokeZip).Path
    Invoke-RcSmoke ([pscustomobject]@{ Zip = $zip; Output = (Split-Path -Parent $zip); Repository = (Invoke-Checked git @('-C', $PSScriptRoot, 'rev-parse', '--show-toplevel')).Trim() })
    return
}
if ($Smoke -and $SigningMode -eq 'none') {
    throw '-Smoke needs a signed release candidate: the clients refuse an unsigned daemon.'
}
$outputExisted = Test-Path -LiteralPath $OutputDirectory
try {
    $built = New-RcBuild
} catch {
    if (-not $outputExisted -and (Test-Path -LiteralPath $OutputDirectory)) { Remove-Item -LiteralPath $OutputDirectory -Recurse -Force }
    throw
}
if ($Smoke) { Invoke-RcSmoke $built }
