# Signature checks shared by the Windows packaging scripts (TASK-XPA-022):
# rust/scripts/windows-package-xcopy.ps1 and windows/scripts/package-rc.ps1 dot-source this
# file, so the daemon, the CLI and the App are verified by one definition of a certificate
# pin, a publisher identity (maintainer ruling 17) and a production signing command's call.
# It holds no credential and signs nothing by itself.

function Get-CertificatePin($Certificate) {
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Certificate.RawData)).ToLowerInvariant()
}

# The Artifact Signing Public Trust root, as arkdeck-platform/src/windows/publisher.rs pins it
# (ARTIFACT_SIGNING_ROOT_SHA256; SHA-1 f40042e2e5f7e8ef8189fed15519aece42c3bfa2 in the Microsoft
# PKI Services repository). Change both together.
$ArtifactSigningRootSha256 = '5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270'
$IdentityEkuPrefix = '1.3.6.1.4.1.311.97.'
$PublicTrustMarkerEku = '1.3.6.1.4.1.311.97.1.0'

# The publisher identity of a production (Artifact Signing) leaf, read as the CLI matches it:
# the chain ends at the pinned root, exactly one subject O=, and exactly one certificate-profile
# identity EKU beside code signing.
function Get-PublisherIdentity($Certificate) {
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        # Trust was already decided by Get-AuthenticodeSignature; the chain only names the root.
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        [void]$chain.Build($Certificate)
        $elements = @($chain.ChainElements)
        if ($elements.Count -lt 2) { throw "The production signer $($Certificate.Subject) has no chain to a root." }
        $root = Get-CertificatePin $elements[-1].Certificate
    } finally {
        $chain.Dispose()
    }
    if ($root -ne $ArtifactSigningRootSha256) {
        throw "The production signer chains to root $root, not Microsoft Identity Verification Root Certificate Authority 2020 ($ArtifactSigningRootSha256)."
    }
    $organizations = @(foreach ($rdn in $Certificate.SubjectName.EnumerateRelativeDistinguishedNames()) {
            if ($rdn.GetSingleElementType().Value -eq '2.5.4.10') { $rdn.GetSingleElementValue() }
        })
    if ($organizations.Count -ne 1) { throw "The production signer $($Certificate.Subject) must carry exactly one O=, not $($organizations.Count)." }
    $usages = @(foreach ($extension in $Certificate.Extensions) {
            if ($extension -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
                foreach ($usage in $extension.EnhancedKeyUsages) { $usage.Value }
            }
        })
    if ($usages -notcontains '1.3.6.1.5.5.7.3.3') { throw "The production signer $($Certificate.Subject) has no code-signing EKU." }
    $profiles = @($usages | Where-Object { $_.StartsWith($IdentityEkuPrefix) -and $_ -ne $PublicTrustMarkerEku })
    if ($profiles.Count -ne 1) { throw "The production signer must carry exactly one Artifact Signing identity EKU, not: $($profiles -join ', ')" }
    return [ordered]@{ organization = $organizations[0]; eku = $profiles[0] }
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
        certificate = $signature.SignerCertificate
    }
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
