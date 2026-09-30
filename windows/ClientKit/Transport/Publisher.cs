using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace ArkDeck.ClientKit.Transport;

/// <summary>
/// The publisher identity of a production-signed daemon (maintainer ruling 17; the Rust
/// <c>arkdeck-platform/src/windows/publisher.rs</c>). Azure Artifact Signing renews its leaf
/// certificates daily, so a pin on one certificate's SHA-256 would break with every signing.
/// The daemon is pinned instead by who signed it: the Authenticode chain that
/// <c>WinVerifyTrust</c> already accepted must end at the Microsoft root that Artifact Signing
/// Public Trust chains to, and the leaf's subject organisation (<c>O=</c>) and its
/// certificate-profile identity EKU must both equal the configured values.
/// </summary>
internal sealed record PublisherIdentity(string Organization, string Eku)
{
    /// <summary>SHA-256 of the DER of "Microsoft Identity Verification Root Certificate
    /// Authority 2020" (SHA-1 thumbprint <c>f40042e2e5f7e8ef8189fed15519aece42c3bfa2</c>), the
    /// Rust <c>ARTIFACT_SIGNING_ROOT_SHA256</c>. Both clients pin the same root; the test
    /// <c>TheRootPinIsTheOfficialCertificate</c> ties it to the Rust fixture.</summary>
    internal const string ArtifactSigningRootSha256 = "5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270";

    private const string IdentityEkuPrefix = "1.3.6.1.4.1.311.97.";

    /// <summary>Present in every Artifact Signing Public Trust certificate, so it names no
    /// publisher and is refused as a configured identity.</summary>
    internal const string PublicTrustMarkerEku = "1.3.6.1.4.1.311.97.1.0";

    internal const string CodeSigningEku = "1.3.6.1.5.5.7.3.3";

    private const string OrganizationOid = "2.5.4.10";

    /// <summary>Both inputs or neither: null when neither is configured. Only one of them, or
    /// a value that is not a usable identity, refuses the connection outright, whatever else
    /// is configured.</summary>
    public static PublisherIdentity? FromConfig(string? organization, string? eku)
    {
        if (organization is null && eku is null) return null;
        if (organization is null || eku is null)
        {
            throw new UnauthorizedAccessException(
                "partial daemon publisher identity: both the organisation and the Artifact Signing identity EKU are required; zero frames sent");
        }
        if (organization.Length == 0 || organization.Trim() != organization)
        {
            throw new UnauthorizedAccessException("the daemon publisher organisation must be the exact non-empty subject O= value");
        }
        var suffix = eku.StartsWith(IdentityEkuPrefix, StringComparison.Ordinal) ? eku[IdentityEkuPrefix.Length..] : string.Empty;
        if (suffix.Length == 0
            || eku == PublicTrustMarkerEku
            || !suffix.Split('.').All(arc => arc.Length > 0 && arc.All(char.IsAsciiDigit) && (arc == "0" || arc[0] != '0')))
        {
            throw new UnauthorizedAccessException(
                "the daemon publisher EKU must be an Artifact Signing certificate-profile identity OID (1.3.6.1.4.1.311.97.<profile>)");
        }
        return new PublisherIdentity(organization, eku);
    }

    /// <summary>Whether a chain <c>WinVerifyTrust</c> verified (leaf first, root last) is this
    /// publisher's: the root's DER SHA-256 is <paramref name="rootSha256"/>, and the leaf has
    /// exactly one subject <c>O=</c> equal to the organisation, the code-signing EKU and the
    /// identity EKU in its own extension. A pure function: no trust decision of its own.</summary>
    public bool ChainMatches(IReadOnlyList<byte[]> chain, string rootSha256)
    {
        if (chain.Count < 2 || Convert.ToHexStringLower(SHA256.HashData(chain[^1])) != rootSha256) return false;
        List<string?> organizations;
        List<string> usages;
        try
        {
            using var leaf = X509CertificateLoader.LoadCertificate(chain[0]);
            organizations = SubjectOrganizations(leaf.SubjectName.RawData);
            usages = leaf.Extensions.OfType<X509EnhancedKeyUsageExtension>()
                .SelectMany(extension => extension.EnhancedKeyUsages.Cast<Oid>())
                .Select(usage => usage.Value ?? string.Empty)
                .ToList();
        }
        catch (Exception error) when (error is CryptographicException or AsnContentException)
        {
            return false;
        }
        return organizations is [var only] && only == Organization
            && usages.Contains(CodeSigningEku)
            && usages.Contains(Eku);
    }

    /// <summary>Every <c>O=</c> attribute of an X.500 name, multi-valued RDNs included; a value
    /// that is not a directory string is kept as null, so it still counts (and never matches).</summary>
    private static List<string?> SubjectOrganizations(byte[] name)
    {
        var organizations = new List<string?>();
        var reader = new AsnReader(name, AsnEncodingRules.DER);
        var rdns = reader.ReadSequence();
        reader.ThrowIfNotEmpty();
        while (rdns.HasData)
        {
            var attributes = rdns.ReadSetOf();
            while (attributes.HasData)
            {
                var attribute = attributes.ReadSequence();
                var type = attribute.ReadObjectIdentifier();
                var tag = attribute.PeekTag();
                if (type == OrganizationOid)
                {
                    organizations.Add(tag.TagClass == TagClass.Universal && IsDirectoryString((UniversalTagNumber)tag.TagValue)
                        ? attribute.ReadCharacterString((UniversalTagNumber)tag.TagValue)
                        : null);
                }
                else
                {
                    attribute.ReadEncodedValue();
                }
                attribute.ThrowIfNotEmpty();
            }
        }
        return organizations;
    }

    private static bool IsDirectoryString(UniversalTagNumber tag) => tag is UniversalTagNumber.UTF8String
        or UniversalTagNumber.PrintableString or UniversalTagNumber.BMPString or UniversalTagNumber.T61String
        or UniversalTagNumber.UniversalString or UniversalTagNumber.IA5String;
}

/// <summary>The signing pins configured for an installed daemon (the Rust <c>SignerPins</c>):
/// the development signer's certificate SHA-256 and the production publisher identity.
/// Either that is configured may vouch for the image; the package family is checked
/// separately on the process.</summary>
internal sealed record SignerPins(string? Certificate, PublisherIdentity? Publisher)
{
    /// <summary>Reads the pins from the installation inputs. A publisher identity with only
    /// one of its two values, or a malformed one, throws: the caller refuses with zero frames
    /// rather than falling back.</summary>
    public static SignerPins Configured(DaemonIdentity expected) =>
        new(expected.AuthenticodeSha256, PublisherIdentity.FromConfig(expected.PublisherOrganization, expected.PublisherEku));

    public bool IsEmpty => Certificate is null && Publisher is null;

    /// <summary>The Rust <c>verify_signature</c> after <c>WinVerifyTrust</c>: the verified chain
    /// satisfies one configured pin. A malformed certificate pin satisfies nothing, whatever
    /// else is configured.</summary>
    public bool ChainMatches(IReadOnlyList<byte[]> chain, string rootSha256)
    {
        if (IsEmpty || chain.Count == 0) return false;
        if (Certificate is { } pin && (pin.Length != 64 || !pin.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f'))) return false;
        var certificateMatches = Certificate is { } expected && Convert.ToHexStringLower(SHA256.HashData(chain[0])) == expected;
        var publisherMatches = Publisher?.ChainMatches(chain, rootSha256) ?? false;
        return certificateMatches || publisherMatches;
    }
}
