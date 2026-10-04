using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using ArkDeck.App.Core.RemoteSources;

namespace ArkDeck.App.Tests;

/// <summary>
/// Remote build sources (macOS <c>RemoteBuildSourceApplicationFacade</c>, pinned by
/// <c>RemoteBuildSourceContractTests</c> and <c>RemoteBuildSourceStateTests</c>): the bounds of a
/// source and a path, the owner-only files and their audit, Credential Manager, and the provider
/// over an in-process SFTP server — probe and trust-on-save, the pinned host key, the canonical
/// root and its containment, the listing rules and the bounded native-library read.
/// </summary>
[TestClass]
public sealed class RemoteBuildSourceTests
{
    private const string Root = "/srv/build/out";

    private static RemoteBuildSourceException Refused(Action action)
    {
        try
        {
            action();
        }
        catch (RemoteBuildSourceException error)
        {
            return error;
        }
        throw new AssertFailedException("not refused");
    }

    private static async Task<RemoteBuildSourceException> RefusedAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (RemoteBuildSourceException error)
        {
            return error;
        }
        throw new AssertFailedException("not refused");
    }

    private static RemoteBuildSourceDraft Draft(Guid? id = null, string host = "builder.example", int port = 22, string root = Root) =>
        new(id, "Builder", host, port, "build", root, RemoteBuildSourceAuthentication.Password);

    [TestMethod]
    public void ADraftIsNormalizedAndBounded()
    {
        var draft = RemoteBuildSourceBounds.Validate(Draft() with { Name = "  Builder  ", Host = "BUILDER.EXAMPLE" });
        Assert.AreEqual(("Builder", "builder.example"), (draft.Name, draft.Host));
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidName, Refused(() => RemoteBuildSourceBounds.Validate(Draft() with { Name = " " })).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidName, Refused(() => RemoteBuildSourceBounds.Validate(Draft() with { Name = new string('n', 81) })).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidHost, Refused(() => RemoteBuildSourceBounds.Validate(Draft(host: "build er"))).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidPort, Refused(() => RemoteBuildSourceBounds.Validate(Draft(port: 0))).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidUsername, Refused(() => RemoteBuildSourceBounds.Validate(Draft() with { Username = "a b" })).Code);
        foreach (var root in new[] { "/", "relative", "/srv/../etc", "/srv//out", "/srv/./out", "/srv/\u0001x" })
        {
            Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidRoot, Refused(() => RemoteBuildSourceBounds.AbsoluteRoot(root)).Code, root);
        }
        Assert.AreEqual("/C:/Users/build/out", RemoteBuildSourceBounds.AbsoluteRoot(" /C:/Users/build/out "));
        foreach (var path in new[] { "../secret", "/absolute", "nested/../../secret", "nested//lib.so" })
        {
            Assert.AreEqual(RemoteBuildSourceErrorCode.PathOutsideRoot, Refused(() => RemoteBuildSourceBounds.RelativePath(path, allowEmpty: true)).Code, path);
        }
        Assert.AreEqual("", RemoteBuildSourceBounds.RelativePath("", allowEmpty: true));
        Assert.AreEqual(RemoteBuildSourceErrorCode.PathOutsideRoot, Refused(() => RemoteBuildSourceBounds.RelativePath("", allowEmpty: false)).Code);
        Assert.IsTrue(RemoteBuildSourceBounds.IsContained("/srv/build/out/lib", "/srv/build/out"));
        Assert.IsFalse(RemoteBuildSourceBounds.IsContained("/srv/build/outside", "/srv/build/out"));
    }

    [TestMethod]
    public void CredentialsAreBoundedAndTheirEnvelopeIsTheSwiftOne()
    {
        var password = RemoteBuildSourceBounds.Credential(new RemoteBuildSourceCredentialInput.Password("secret"), RemoteBuildSourceAuthentication.Password);
        Assert.AreEqual("""{"authentication":"password","origin":"provided","secret":"c2VjcmV0"}""", Encoding.UTF8.GetString(password.Encode()));
        var system = RemoteBuildSourceBounds.Credential(new RemoteBuildSourceCredentialInput.SystemDefault(""), RemoteBuildSourceAuthentication.PrivateKey);
        Assert.AreEqual("""{"authentication":"privateKey","origin":"systemDefault","secret":""}""", Encoding.UTF8.GetString(system.Encode()));
        // A first-release envelope without an origin is a provided secret.
        var legacy = RemoteBuildCredentialEnvelope.Decode(Encoding.UTF8.GetBytes("""{"authentication":"privateKey","secret":"a2V5","passphrase":"cA=="}"""))!;
        Assert.IsFalse(legacy.UsesSystemDefault);
        Assert.AreEqual("p", Encoding.UTF8.GetString(legacy.Passphrase!));
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidCredential,
            Refused(() => RemoteBuildSourceBounds.Credential(new RemoteBuildSourceCredentialInput.Password(""), RemoteBuildSourceAuthentication.Password)).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidCredential,
            Refused(() => RemoteBuildSourceBounds.Credential(new RemoteBuildSourceCredentialInput.Password(new string('p', 4097)), RemoteBuildSourceAuthentication.Password)).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidCredential,
            Refused(() => RemoteBuildSourceBounds.Credential(new RemoteBuildSourceCredentialInput.PrivateKey(new byte[256 * 1024 + 1], null), RemoteBuildSourceAuthentication.PrivateKey)).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidCredential,
            Refused(() => RemoteBuildSourceBounds.Credential(new RemoteBuildSourceCredentialInput.Password("x"), RemoteBuildSourceAuthentication.PrivateKey)).Code);
    }

    /// <summary>A fresh key from Windows' ssh-keygen (no private key is kept in the repository).</summary>
    internal static byte[] GeneratedKey(string type, string passphrase = "")
    {
        var keygen = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh-keygen.exe");
        if (!File.Exists(keygen)) Assert.Inconclusive("the Windows OpenSSH client is not installed");
        var directory = Directory.CreateTempSubdirectory("arkdeck-keygen-");
        try
        {
            var file = Path.Combine(directory.FullName, "key");
            var start = new System.Diagnostics.ProcessStartInfo(keygen) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var argument in new[] { "-q", "-t", type, "-f", file, "-N", passphrase, "-C", "arkdeck-test" }) start.ArgumentList.Add(argument);
            using var process = System.Diagnostics.Process.Start(start)!;
            process.WaitForExit(30_000);
            Assert.AreEqual(0, process.ExitCode, process.StandardError.ReadToEnd());
            return File.ReadAllBytes(file);
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [TestMethod]
    public void OnlyEd25519AndRsaKeysAreAccepted()
    {
        Assert.AreEqual("ssh-ed25519", OpenSshConnector.KeyType(GeneratedKey("ed25519")));
        Assert.AreEqual("ssh-ed25519", OpenSshConnector.KeyType(GeneratedKey("ed25519", "a passphrase")), "the public part names an encrypted key's type");
        Assert.AreEqual("ssh-rsa", OpenSshConnector.KeyType(GeneratedKey("rsa")));
        Assert.IsNull(OpenSshConnector.KeyType(GeneratedKey("ecdsa")));
        Assert.AreEqual("ssh-rsa", OpenSshConnector.KeyType(Encoding.ASCII.GetBytes("-----BEGIN RSA PRIVATE KEY-----\nMII\n-----END RSA PRIVATE KEY-----\n")));
        Assert.IsNull(OpenSshConnector.KeyType(Encoding.ASCII.GetBytes("not a key")));
        Assert.AreEqual("rsa-sha2-512,rsa-sha2-256,ssh-rsa", OpenSshConnector.HostKeyAlgorithms("ssh-rsa AAAA"));
        Assert.AreEqual("ssh-ed25519", OpenSshConnector.HostKeyAlgorithms("ssh-ed25519 AAAA"));
    }

    [TestMethod]
    public void TheFilesAreOwnerOnlyAndHoldNoSecretOrPath()
    {
        var directory = Path.Combine(Directory.CreateTempSubdirectory("arkdeck-remote-files-").FullName, "RemoteBuildSources");
        try
        {
            var files = new RemoteBuildSourceFiles(directory);
            IRemoteBuildSourceRecordStore records = files;
            var id = Guid.NewGuid();
            var record = new RemoteBuildSourceRecord(id, "Builder", "builder.example", 22, "build", Root, Root, RemoteBuildSourceAuthentication.Password,
                "ssh-ed25519 AAAA", "SHA256:00", DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));
            records.Replace([record]);
            Assert.AreEqual(record, records.Load().Single());
            var text = File.ReadAllText(Path.Combine(directory, "sources-v1.json"));
            StringAssert.StartsWith(text, """{"records":[{"authentication":"password","canonicalRootPath":""" );
            StringAssert.Contains(text, "\"id\":\"" + id.ToString("D").ToUpperInvariant() + "\"");
            StringAssert.Contains(text, "\"lastVerifiedAt\":\"2023-11-14T22:13:20Z\"");
            StringAssert.EndsWith(text, "\"version\":1}");

            IRemoteBuildSourceAudit audit = files;
            audit.Append(new RemoteBuildAuditEvent(Guid.NewGuid(), Guid.NewGuid(), "intent", "readNativeLibrary", id,
                RemoteBuildSourceFiles.PathDigest("nested/libsecret.so"), null, DateTimeOffset.UtcNow));
            audit.Append(new RemoteBuildAuditEvent(Guid.NewGuid(), Guid.NewGuid(), "outcome", "readNativeLibrary", id, null, "confirmed", DateTimeOffset.UtcNow));
            var lines = File.ReadAllLines(Path.Combine(directory, "audit-v1.jsonl"));
            Assert.AreEqual(2, lines.Length);
            Assert.IsFalse(lines.Any(l => l.Contains("libsecret", StringComparison.Ordinal) || l.Contains("passphrase", StringComparison.Ordinal)));

            IRemoteBuildSourceBindingStore bindings = files;
            bindings.Replace([new RemoteBuildSourceBindingRecord("TGT-1", id, DateTimeOffset.FromUnixTimeSeconds(1_700_000_000))]);
            Assert.AreEqual("TGT-1", bindings.Load().Single().TargetId);
            Assert.IsFalse(File.ReadAllText(Path.Combine(directory, "target-bindings-v1.json")).Contains("builder.example", StringComparison.Ordinal));

            var user = WindowsIdentity.GetCurrent().User!;
            foreach (var name in new[] { "sources-v1.json", "audit-v1.jsonl", "target-bindings-v1.json" })
            {
                var acl = new FileInfo(Path.Combine(directory, name)).GetAccessControl();
                Assert.IsTrue(acl.AreAccessRulesProtected, name);
                var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
                Assert.IsTrue(rules.All(r => (SecurityIdentifier)r.IdentityReference == user), name);
            }
            File.WriteAllText(Path.Combine(directory, "sources-v1.json"), """{"version":2,"records":[]}""");
            Assert.AreEqual(RemoteBuildSourceErrorCode.StorageFailed, Refused(() => records.Load()).Code);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(directory)!, recursive: true);
        }
    }

    [TestMethod]
    public void CredentialManagerKeepsAndRemovesAnEnvelopeOfAnySize()
    {
        var store = new WindowsRemoteCredentialStore(scope: "ArkDeck-fixture/" + Guid.NewGuid().ToString("N"));
        var account = Guid.NewGuid();
        try
        {
            Assert.IsFalse(store.Contains(account));
            Assert.AreEqual(RemoteBuildSourceErrorCode.CredentialUnavailable, Refused(() => store.Read(account)).Code);
            var large = Enumerable.Range(0, 100_000).Select(i => (byte)(i * 7)).ToArray();
            store.Set(large, account);
            Assert.IsTrue(store.Contains(account));
            CollectionAssert.AreEqual(large, store.Read(account));
            var small = "small"u8.ToArray();
            store.Set(small, account);
            CollectionAssert.AreEqual(small, store.Read(account));
            Assert.IsTrue(store.Remove(account));
            Assert.IsFalse(store.Contains(account));
            Assert.IsFalse(store.Remove(account));
        }
        finally
        {
            store.Remove(account);
        }
    }

    // ---- the provider over the in-process SFTP server ----

    private sealed class Rig
    {
        public FakeSftpServer Server { get; } = new();
        public FakeConnector Connector { get; }
        public MemoryCredentials Credentials { get; } = new();
        public string Directory { get; } = Path.Combine(System.IO.Directory.CreateTempSubdirectory("arkdeck-remote-provider-").FullName, "RemoteBuildSources");
        public DateTimeOffset Now { get; set; } = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        public RemoteBuildSourceProvider Provider { get; }
        public RemoteBuildSourceFiles Files { get; }

        public Rig()
        {
            Connector = new FakeConnector(Server);
            Files = new RemoteBuildSourceFiles(Directory);
            Provider = new RemoteBuildSourceProvider(Files, Files, Credentials, Files, Connector, () => Now);
            Server.Directory("/srv");
            Server.Directory("/srv/build");
            Server.Directory(Root);
            Server.Directory(Root + "/arm64");
            Server.File(Root + "/arm64/libentry.so", Library(4096));
            Server.File(Root + "/libtiny.so", Library(10));
            Server.File(Root + "/README.md", "text"u8.ToArray());
            Server.Directory("/etc");
            Server.File("/etc/libpasswd.so", Library(128));
            Server.Link(Root + "/escape", "/etc");
        }

        public async Task<RemoteBuildSourcePresentation> SavedAsync()
        {
            var probe = await Provider.ProbeAsync(Draft(), new RemoteBuildSourceCredentialInput.Password("secret"));
            return await Provider.SaveAsync(probe);
        }
    }

    private static byte[] Library(int size) => Enumerable.Range(0, size).Select(i => (byte)i).ToArray();

    [TestMethod]
    public async Task AProbeVerifiesTheRootAndTheHostKeyAndSavingTrustsItOnce()
    {
        var rig = new Rig();
        var probe = await rig.Provider.ProbeAsync(Draft() with { Host = "BUILDER.example" }, new RemoteBuildSourceCredentialInput.Password("secret"));
        Assert.AreEqual(("build@builder.example:22", Root), (probe.Endpoint, probe.CanonicalRootPath));
        Assert.IsTrue(probe.RequiresNewHostTrust);
        StringAssert.Matches(probe.HostKeyFingerprint, new System.Text.RegularExpressions.Regex("^SHA256:[0-9a-f]{64}$"));
        var firstAsked = rig.Connector.Connections.Single().Expected;
        Assert.IsNull(firstAsked, "a first probe trusts nothing yet");
        Assert.AreEqual(0, (await rig.Provider.ListSourcesAsync()).Count, "nothing is saved by a probe");

        var saved = await rig.Provider.SaveAsync(probe);
        Assert.AreEqual(("Builder", "build@builder.example:22", true, false), (saved.Name, saved.Endpoint, saved.CredentialStored, saved.UsesSystemDefaultCredential));
        Assert.AreEqual(RemoteBuildSourceErrorCode.ProbeExpired, (await RefusedAsync(() => rig.Provider.SaveAsync(probe))).Code, "a trust token is single-use");

        // A later probe of the same host and port expects the pinned key, and refuses another.
        var again = await rig.Provider.ProbeAsync(Draft(saved.Id), null);
        Assert.IsFalse(again.RequiresNewHostTrust);
        var pinned = rig.Connector.HostKey;
        var asked = rig.Connector.Connections[^1].Expected;
        Assert.AreEqual(pinned, asked);
        rig.Connector.HostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
        Assert.AreEqual(RemoteBuildSourceErrorCode.HostKeyChanged, (await RefusedAsync(() => rig.Provider.ListDirectoryAsync(saved.Id, ""))).Code);
        // Another port is a new host: no expectation, trust asked again.
        Assert.IsTrue((await rig.Provider.ProbeAsync(Draft(saved.Id, port: 2222), null)).RequiresNewHostTrust);
    }

    [TestMethod]
    public async Task AProbeExpiresAfterFiveMinutes()
    {
        var rig = new Rig();
        var probe = await rig.Provider.ProbeAsync(Draft(), new RemoteBuildSourceCredentialInput.Password("secret"));
        rig.Now += TimeSpan.FromMinutes(5);
        Assert.AreEqual(RemoteBuildSourceErrorCode.ProbeExpired, (await RefusedAsync(() => rig.Provider.SaveAsync(probe))).Code);
    }

    [TestMethod]
    public async Task APasswordProbeWithoutAPasswordIsRefusedAndAKeyProbeUsesTheSystemDefault()
    {
        var rig = new Rig();
        Assert.AreEqual(RemoteBuildSourceErrorCode.CredentialUnavailable, (await RefusedAsync(() => rig.Provider.ProbeAsync(Draft(), null))).Code);
        await rig.Provider.ProbeAsync(Draft() with { Authentication = RemoteBuildSourceAuthentication.PrivateKey }, null);
        Assert.IsTrue(rig.Connector.Connections.Single().Credential.UsesSystemDefault);
    }

    [TestMethod]
    public async Task AFailedSaveRestoresTheCredentialAndSavesNothing()
    {
        var rig = new Rig();
        var probe = await rig.Provider.ProbeAsync(Draft(), new RemoteBuildSourceCredentialInput.Password("secret"));
        rig.Credentials.FailWrites = true;
        Assert.AreEqual(RemoteBuildSourceErrorCode.StorageFailed, (await RefusedAsync(() => rig.Provider.SaveAsync(probe))).Code);
        Assert.AreEqual(0, (await rig.Provider.ListSourcesAsync()).Count);
        Assert.AreEqual(0, rig.Credentials.Items.Count);
    }

    [TestMethod]
    public async Task ListingShowsDirectoriesAndNativeLibrariesInsideTheRootOnly()
    {
        var rig = new Rig();
        var saved = await rig.SavedAsync();
        var listing = await rig.Provider.ListDirectoryAsync(saved.Id, "");
        CollectionAssert.AreEqual(new[] { "arm64 Directory", "libtiny.so NativeLibrary" }, listing.Entries.Select(e => $"{e.Name} {e.Kind}").ToArray(),
            "directories first; README.md is not a library; the symbolic link is skipped");
        var nested = await rig.Provider.ListDirectoryAsync(saved.Id, "arm64");
        Assert.AreEqual("arm64/libentry.so", nested.Entries.Single().RelativePath);
        Assert.AreEqual(4096UL, nested.Entries.Single().ByteCount);

        Assert.AreEqual(RemoteBuildSourceErrorCode.PathOutsideRoot, (await RefusedAsync(() => rig.Provider.ListDirectoryAsync(saved.Id, "escape"))).Code,
            "a symbolic link out of the root is refused by its canonical path");
        Assert.AreEqual(RemoteBuildSourceErrorCode.PathOutsideRoot, (await RefusedAsync(() => rig.Provider.ListDirectoryAsync(saved.Id, "../etc"))).Code);

        for (var i = 0; i < 501; i++) rig.Server.File($"{Root}/arm64/f{i}", [1]);
        Assert.AreEqual(RemoteBuildSourceErrorCode.TooManyEntries, (await RefusedAsync(() => rig.Provider.ListDirectoryAsync(saved.Id, "arm64"))).Code);

        // The root moved: everything is refused.
        rig.Server.Link(Root, "/etc");
        Assert.AreEqual(RemoteBuildSourceErrorCode.RootChanged, (await RefusedAsync(() => rig.Provider.ListDirectoryAsync(saved.Id, ""))).Code);
        CollectionAssert.IsSubsetOf(rig.Server.RequestTypes.Distinct().ToArray(), new byte[] { 1, 3, 4, 5, 8, 11, 12, 16 }, "only read-only SFTP requests");
    }

    [TestMethod]
    public async Task ANativeLibraryIsReadWhole()
    {
        var rig = new Rig();
        var saved = await rig.SavedAsync();
        var library = await rig.Provider.FetchNativeLibraryAsync(saved.Id, "arm64/libentry.so");
        Assert.AreEqual(("libentry.so", 4096), (library.FileName, library.ByteCount));
        CollectionAssert.AreEqual(Library(4096), library.Contents);
        Assert.AreEqual(Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Library(4096))), library.Sha256);

        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidLibraryName, (await RefusedAsync(() => rig.Provider.FetchNativeLibraryAsync(saved.Id, "README.md"))).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.InvalidLibrarySize, (await RefusedAsync(() => rig.Provider.FetchNativeLibraryAsync(saved.Id, "libtiny.so"))).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.PathOutsideRoot, (await RefusedAsync(() => rig.Provider.FetchNativeLibraryAsync(saved.Id, "escape/libpasswd.so"))).Code);

        rig.Server.File(Root + "/libbig.so", Library(200_000));
        rig.Server.AfterRead = path => rig.Server.Files[path] = rig.Server.Files[path] with { ModifiedTime = 1_700_000_999 };
        Assert.AreEqual(RemoteBuildSourceErrorCode.FileChanged, (await RefusedAsync(() => rig.Provider.FetchNativeLibraryAsync(saved.Id, "libbig.so"))).Code);
    }

    [TestMethod]
    public async Task RemovingASourceDropsItsCredentialAndBindingsPointAtSourcesOnly()
    {
        var rig = new Rig();
        var saved = await rig.SavedAsync();
        Assert.IsNull(await rig.Provider.BindingAsync("TGT-1"));
        await rig.Provider.BindAsync(saved.Id, "TGT-1");
        Assert.AreEqual(saved.Id, (await rig.Provider.BindingAsync("TGT-1"))!.SourceId);
        Assert.AreEqual(RemoteBuildSourceErrorCode.SourceNotFound, (await RefusedAsync(() => rig.Provider.BindAsync(Guid.NewGuid(), "TGT-1"))).Code);
        Assert.AreEqual(RemoteBuildSourceErrorCode.StorageFailed, (await RefusedAsync(() => rig.Provider.BindAsync(saved.Id, " TGT-1"))).Code);

        await rig.Provider.RemoveAsync(saved.Id);
        Assert.AreEqual(0, rig.Credentials.Items.Count);
        Assert.AreEqual(0, (await rig.Provider.ListSourcesAsync()).Count);
        // The binding is not cleaned up: Overview shows it as stale (macOS).
        Assert.AreEqual(saved.Id, (await rig.Provider.BindingAsync("TGT-1"))!.SourceId);
        await rig.Provider.UnbindAsync("TGT-1");
        Assert.IsNull(await rig.Provider.BindingAsync("TGT-1"));
        Assert.AreEqual(RemoteBuildSourceErrorCode.SourceNotFound, (await RefusedAsync(() => rig.Provider.RemoveAsync(saved.Id))).Code);

        var audit = File.ReadAllLines(Path.Combine(rig.Directory, "audit-v1.jsonl"));
        CollectionAssert.AreEqual(new[] { "intent probe", "outcome probe", "intent save", "outcome save", "intent remove", "outcome remove" },
            audit.Select(l => System.Text.Json.Nodes.JsonNode.Parse(l)!).Select(n => $"{(string?)n["phase"]} {(string?)n["action"]}").ToArray());
    }
}
