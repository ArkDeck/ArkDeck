using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit.Tests;

/// <summary>
/// The production publisher-identity pin (maintainer ruling 17), the same cases as the Rust
/// <c>publisher.rs</c> and <c>identity.rs</c> tests. The chain matcher runs after
/// <c>WinVerifyTrust</c>, so fixture chains of in-memory self-signed certificates (ephemeral
/// keys, never in a store) exercise every field it reads; the root is the official
/// Microsoft Identity Verification Root 2020, the Rust fixture.
/// </summary>
[TestClass]
public sealed class PublisherTests
{
    private const string ProfileEku = "1.3.6.1.4.1.311.97.990309390.766961637.194916062.941502583";
    private const string OtherProfileEku = "1.3.6.1.4.1.311.97.123456789.1.2.3";
    private const string CodeSigning = PublisherIdentity.CodeSigningEku;
    private const string Marker = PublisherIdentity.PublicTrustMarkerEku;

    private static readonly byte[] OfficialRoot = File.ReadAllBytes(
        RepoPaths.At("rust", "crates", "arkdeck-platform", "src", "windows", "fixtures", "microsoft-identity-verification-root-2020.crt"));

    private static byte[] Certificate(string subject, params string[] usages)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest(new X500DistinguishedName(subject), key, HashAlgorithmName.SHA256);
        if (usages.Length > 0)
        {
            var collection = new OidCollection();
            foreach (var usage in usages) collection.Add(new Oid(usage));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(collection, false));
        }
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        return certificate.RawData;
    }

    private static PublisherIdentity Publisher() => PublisherIdentity.FromConfig("Contoso Ltd", ProfileEku)!;

    private static byte[][] Leaf(string subject, params string[] usages) => [Certificate(subject, usages), OfficialRoot];

    [TestMethod]
    public void TheRootPinIsTheOfficialCertificate()
    {
        Assert.AreEqual("f40042e2e5f7e8ef8189fed15519aece42c3bfa2", Convert.ToHexStringLower(SHA1.HashData(OfficialRoot)));
        Assert.AreEqual(PublisherIdentity.ArtifactSigningRootSha256, Convert.ToHexStringLower(SHA256.HashData(OfficialRoot)));
    }

    [TestMethod]
    public void TheConfiguredPublisherMatches()
    {
        var chain = Leaf("CN=Contoso Ltd, O=Contoso Ltd, L=Redmond, C=US", CodeSigning, Marker, ProfileEku);
        Assert.IsTrue(Publisher().ChainMatches(chain, PublisherIdentity.ArtifactSigningRootSha256));
        // Intermediates between leaf and root do not change the answer.
        Assert.IsTrue(Publisher().ChainMatches([chain[0], Certificate("CN=Intermediate"), chain[1]], PublisherIdentity.ArtifactSigningRootSha256));
        // One O= inside a multi-valued RDN is still the one O=.
        Assert.IsTrue(Publisher().ChainMatches(Leaf("CN=Contoso Ltd, O=Contoso Ltd + OU=Signing, C=US", CodeSigning, ProfileEku),
            PublisherIdentity.ArtifactSigningRootSha256));
    }

    [TestMethod]
    public void ADifferentOrganisationIsRefused()
    {
        foreach (var subject in new[]
        {
            "CN=Contoso Ltd, O=Fabrikam Inc, C=US",
            "CN=Contoso Ltd, O=contoso ltd, C=US",
            "CN=Contoso Ltd, O=Contoso Ltd., C=US",
            "CN=Contoso Ltd, C=US",
            // Two O= values are ambiguous, even when one matches, in separate RDNs or in one.
            "CN=Contoso Ltd, O=Contoso Ltd, O=Fabrikam Inc, C=US",
            "CN=Contoso Ltd, O=Contoso Ltd + O=Fabrikam Inc, C=US",
        })
        {
            Assert.IsFalse(Publisher().ChainMatches(Leaf(subject, CodeSigning, ProfileEku), PublisherIdentity.ArtifactSigningRootSha256), subject);
        }
    }

    [TestMethod]
    public void AMissingOrDifferentIdentityEkuIsRefused()
    {
        foreach (var usages in new[]
        {
            Array.Empty<string>(),
            [CodeSigning],
            [CodeSigning, Marker],
            [CodeSigning, OtherProfileEku],
            // The profile EKU without code signing is not a code-signing leaf.
            [ProfileEku],
        })
        {
            Assert.IsFalse(Publisher().ChainMatches(Leaf("CN=Contoso Ltd, O=Contoso Ltd, C=US", usages), PublisherIdentity.ArtifactSigningRootSha256),
                string.Join(",", usages));
        }
    }

    [TestMethod]
    public void ADifferentRootIsRefused()
    {
        var leaf = Certificate("CN=Contoso Ltd, O=Contoso Ltd, C=US", CodeSigning, ProfileEku);
        var root = PublisherIdentity.ArtifactSigningRootSha256;
        Assert.IsFalse(Publisher().ChainMatches([leaf, Certificate("CN=Contoso Test Root, O=Contoso Ltd")], root));
        // A leaf alone (its own root) and an empty chain never match.
        Assert.IsFalse(Publisher().ChainMatches([leaf], root));
        Assert.IsFalse(Publisher().ChainMatches([], root));
        // The official root in the leaf position is not a chain ending there.
        Assert.IsFalse(Publisher().ChainMatches([OfficialRoot], root));
        // Undecodable DER is no match, not an exception.
        Assert.IsFalse(Publisher().ChainMatches([[0x30, 0x03, 0x02, 0x01], OfficialRoot], root));
    }

    [TestMethod]
    public void PartialOrMalformedConfigurationIsRefused()
    {
        Assert.IsNull(PublisherIdentity.FromConfig(null, null));
        foreach (var (organization, eku) in new (string?, string?)[]
        {
            ("Contoso Ltd", null),
            (null, ProfileEku),
            ("", ProfileEku),
            (" Contoso Ltd", ProfileEku),
            ("Contoso Ltd", ""),
            ("Contoso Ltd", CodeSigning),
            ("Contoso Ltd", Marker),
            ("Contoso Ltd", "1.3.6.1.4.1.311.97."),
            ("Contoso Ltd", "1.3.6.1.4.1.311.97.1..2"),
            ("Contoso Ltd", "1.3.6.1.4.1.311.97.01.2"),
            ("Contoso Ltd", "1.3.6.1.4.1.311.97.1.x"),
        })
        {
            Assert.ThrowsExactly<UnauthorizedAccessException>(() => PublisherIdentity.FromConfig(organization, eku), $"{organization} {eku}");
        }
    }

    [TestMethod]
    public void APartialPublisherIdentityIsRefusedWhateverElseIsSet()
    {
        var identity = new DaemonIdentity(@"C:\unused.exe", new string('0', 64), "Contoso.ArkDeck_8wekyb3d8bbwe", PublisherOrganization: "Contoso Ltd");
        Assert.ThrowsExactly<UnauthorizedAccessException>(() => SignerPins.Configured(identity));
        Assert.ThrowsExactly<UnauthorizedAccessException>(() => SignerPins.Configured(identity with { PublisherOrganization = null, PublisherEku = ProfileEku }));
        Assert.IsFalse(SignerPins.Configured(identity with { PublisherOrganization = null }).IsEmpty);
        Assert.IsTrue(SignerPins.Configured(new DaemonIdentity(@"C:\unused.exe")).IsEmpty);

        // Before any pipe is opened: no server exists at this endpoint, yet the refusal is the
        // configuration's, not "endpoint unavailable".
        var error = Assert.ThrowsExactly<ServerAuthenticationException>(() =>
            PipeConnector.Connect(new PipeEndpoint($@"\\.\pipe\arkdeck-clientkit-test-{Guid.NewGuid():N}"), identity));
        Assert.AreEqual(DaemonUnavailableReason.InstanceMismatch, error.Reason);
        StringAssert.Contains(error.Message, "partial daemon publisher identity");
    }

    [TestMethod]
    public void EitherConfiguredSigningPinVouchesForTheChain()
    {
        var chain = Leaf("CN=Contoso Ltd, O=Contoso Ltd, C=US", CodeSigning, ProfileEku);
        var leafPin = Convert.ToHexStringLower(SHA256.HashData(chain[0]));
        var root = PublisherIdentity.ArtifactSigningRootSha256;
        Assert.IsTrue(new SignerPins(leafPin, null).ChainMatches(chain, root));
        Assert.IsTrue(new SignerPins(null, Publisher()).ChainMatches(chain, root));
        Assert.IsTrue(new SignerPins(new string('0', 64), Publisher()).ChainMatches(chain, root));
        Assert.IsTrue(new SignerPins(leafPin, PublisherIdentity.FromConfig("Fabrikam Inc", ProfileEku)).ChainMatches(chain, root));
        Assert.IsFalse(new SignerPins(null, null).ChainMatches(chain, root));
        Assert.IsFalse(new SignerPins(new string('0', 64), PublisherIdentity.FromConfig("Fabrikam Inc", ProfileEku)).ChainMatches(chain, root));
        // A malformed certificate pin satisfies nothing, whatever else is configured (Rust
        // verify_signature refuses it before looking at the chain).
        Assert.IsFalse(new SignerPins(leafPin.ToUpperInvariant(), Publisher()).ChainMatches(chain, root));
        Assert.IsFalse(new SignerPins("NOT-A-PIN", Publisher()).ChainMatches(chain, root));
    }

    [TestMethod]
    public void AnUnsignedImageHasNoTrustedChain()
    {
        var directory = Directory.CreateTempSubdirectory("arkdeck-clientkit-publisher-");
        try
        {
            var copy = Path.Combine(directory.FullName, "daemon.exe");
            File.Copy(Path.Combine(Environment.SystemDirectory, "whoami.exe"), copy);
            using var image = FileIdentity.OpenLocked(copy);
            Assert.IsNull(Authenticode.TrustedSignerChain(image, copy));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    /// <summary>The <c>WinVerifyTrust</c>-integrated publisher path against a real Artifact
    /// Signing Public Trust signature, when the host has one (the Rust
    /// <c>a_real_artifact_signing_publisher_is_matched_through_winverifytrust</c>):
    /// <c>ARKDECK_PUBLISHER_SAMPLE</c> names a signed executable and
    /// <c>ARKDECK_PUBLISHER_SAMPLE_ORGANIZATION</c> / <c>_EKU</c> its publisher. The file is only
    /// opened and verified, never run.</summary>
    [TestMethod]
    public void ARealArtifactSigningPublisherIsMatchedThroughWinVerifyTrust()
    {
        var sample = Environment.GetEnvironmentVariable("ARKDECK_PUBLISHER_SAMPLE");
        var organization = Environment.GetEnvironmentVariable("ARKDECK_PUBLISHER_SAMPLE_ORGANIZATION");
        var eku = Environment.GetEnvironmentVariable("ARKDECK_PUBLISHER_SAMPLE_EKU");
        if (string.IsNullOrEmpty(sample) || string.IsNullOrEmpty(organization) || string.IsNullOrEmpty(eku))
        {
            Assert.Inconclusive("skipped: ARKDECK_PUBLISHER_SAMPLE is not set; no real publisher is exercised");
        }
        using var image = FileIdentity.OpenLocked(sample!);
        var chain = Authenticode.TrustedSignerChain(image, sample!);
        Assert.IsNotNull(chain, "the sample must verify through WinVerifyTrust");
        var root = PublisherIdentity.ArtifactSigningRootSha256;
        Assert.IsTrue(new SignerPins(null, PublisherIdentity.FromConfig(organization, eku)).ChainMatches(chain, root));
        Assert.IsFalse(new SignerPins(null, PublisherIdentity.FromConfig("Contoso Ltd", eku)).ChainMatches(chain, root));
        Assert.IsFalse(new SignerPins(null, PublisherIdentity.FromConfig(organization, ProfileEku)).ChainMatches(chain, root));
        // Its leaf is short-lived: a certificate pin on it is exactly what ruling 17 retires.
        Assert.IsFalse(new SignerPins(new string('0', 64), null).ChainMatches(chain, root));
    }
}
