#requires -Version 7.2
<#
Development daemon identity on Windows (CHG-2026-074 r12, design §L.1 item 22).

The Windows CLI sends no frame to a daemon whose image is not the pinned path or whose
Authenticode signer certificate is not the pinned SHA-256 (XPA-AC-6, design §F.2). There is
never a switch that skips this. For development the daemon is instead signed with a
certificate trusted only on this host:

  create   Create a self-signed code-signing certificate in Cert:\CurrentUser\My and trust it.
           Local host (maintainer): trusts it in Cert:\CurrentUser\Root — Windows shows a
           security warning that the maintainer must confirm. CI (-Machine, hosted runner as
           administrator): trusts it in Cert:\LocalMachine\Root without a prompt.
           Prints the thumbprint and the pin (SHA-256 of the certificate DER).
  sign     Sign one executable with that certificate (-Thumbprint), SHA-256 digest, no timestamp.
  pin      Print the pin of an existing certificate (-Thumbprint).
  remove   Remove the certificate from My and from the Root store it was trusted in.

The pin goes to ARKDECK_DAEMON_SIGNER_SHA256 and the signed daemon's path to
ARKDECK_DAEMON_PATH (by default the daemon beside the CLI). Never commit a thumbprint-bound
private key; the key stays non-exportable in the user's store.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('create', 'sign', 'pin', 'remove')][string]$Action,
    [string]$Thumbprint,
    [string]$Path,
    [switch]$Machine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows only.' }
$subject = 'CN=ArkDeck Development Daemon (host-trusted only)'
$rootStore = if ($Machine) { 'Cert:\LocalMachine\Root' } else { 'Cert:\CurrentUser\Root' }

function Get-Certificate([string]$Value) {
    if (-not $Value) { throw '-Thumbprint is required.' }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$Value"
    if (-not $certificate.HasPrivateKey) { throw 'The certificate has no private key in Cert:\CurrentUser\My.' }
    return $certificate
}

function Get-Pin($Certificate) {
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Certificate.RawData)).ToLowerInvariant()
}

switch ($Action) {
    'create' {
        $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
            -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
            -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(1) `
            -CertStoreLocation 'Cert:\CurrentUser\My'
        $public = Join-Path ([System.IO.Path]::GetTempPath()) "arkdeck-dev-$($certificate.Thumbprint).cer"
        try {
            Export-Certificate -Cert $certificate -FilePath $public -Type CERT | Out-Null
            Import-Certificate -FilePath $public -CertStoreLocation $rootStore | Out-Null
        } finally {
            Remove-Item -LiteralPath $public -ErrorAction SilentlyContinue
        }
        [ordered]@{ thumbprint = $certificate.Thumbprint; pin = Get-Pin $certificate; trustedIn = $rootStore; notAfter = $certificate.NotAfter.ToString('o') } | ConvertTo-Json
    }
    'sign' {
        $certificate = Get-Certificate $Thumbprint
        if (-not $Path) { throw '-Path is required.' }
        $result = Set-AuthenticodeSignature -LiteralPath $Path -Certificate $certificate -HashAlgorithm SHA256
        if ($result.Status -ne 'Valid') { throw "Signing produced status $($result.Status): $($result.StatusMessage)" }
        [ordered]@{ path = (Resolve-Path -LiteralPath $Path).Path; status = $result.Status.ToString(); pin = Get-Pin $certificate } | ConvertTo-Json
    }
    'pin' {
        [ordered]@{ thumbprint = $Thumbprint; pin = Get-Pin (Get-Certificate $Thumbprint) } | ConvertTo-Json
    }
    'remove' {
        $certificate = Get-Certificate $Thumbprint
        Get-ChildItem -LiteralPath $rootStore | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } | Remove-Item
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)"
        [ordered]@{ removed = $certificate.Thumbprint } | ConvertTo-Json
    }
}
