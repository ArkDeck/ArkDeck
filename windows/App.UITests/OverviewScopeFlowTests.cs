namespace ArkDeck.App.UITests;

/// <summary>
/// The device Overview describes and its remote build server (macOS <c>OverviewRecordView</c>
/// deviceBar), through UIA patterns only: over the scripted <c>jobs</c> daemon the one online
/// adopted device is in scope with its Target, binding, system and transport; its server line
/// reads the App's own bindings — unbound, bound (name and endpoint) or stale (the server removed).
/// </summary>
[TestClass]
public sealed class OverviewScopeFlowTests
{
    private const string SourceId = "6F1E5B7A-2C3D-4E5F-8A9B-0C1D2E3F4A5B";

    private static string Root(string bindings, bool withSource)
    {
        var root = Directory.CreateTempSubdirectory("arkdeck-uitest-overview-").FullName;
        if (withSource)
        {
            File.WriteAllText(Path.Combine(root, "sources-v1.json"),
                $$"""{"records":[{"authentication":"password","canonicalRootPath":"/srv/out","host":"builder.example","hostKeyFingerprint":"SHA256:00","hostPublicKey":"ssh-ed25519 AAAA","id":"{{SourceId}}","lastVerifiedAt":"2026-10-04T00:00:00Z","name":"Builder","port":22,"rootPath":"/srv/out","username":"build"}],"version":1}""");
        }
        File.WriteAllText(Path.Combine(root, "target-bindings-v1.json"), bindings);
        return root;
    }

    private static string Binding(string target) =>
        $$"""{"bindings":[{"boundAt":"2026-10-04T00:00:00Z","sourceID":"{{SourceId}}","targetID":"{{target}}"}],"version":1}""";

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TheOnlineDeviceAndItsServerAreInScope()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var empty = Root("""{"bindings":[],"version":1}""", withSource: false);
        using (var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--remote-sources-root", empty]))
        {
            Assert.AreEqual("DAYU200", app.WaitForName("overview.record.device.name", n => n.Length > 0));
            Assert.AreEqual("TGT-FIXTURE-1 · " + strings.Format("overview.record.binding", ["3"]) + " · OpenHarmony 6.0 · usb", AppSession.Name(app.Find("overview.record.device.facts")));
            Assert.AreEqual(strings["overview.record.remoteServer.unbound"], app.WaitForName("overview.record.remoteServer.state", n => n == strings["overview.record.remoteServer.unbound"]));
        }
        using (var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--remote-sources-root", Root(Binding("TGT-FIXTURE-1"), withSource: true)]))
        {
            Assert.AreEqual("Builder", app.WaitForName("overview.record.remoteServer.name", n => n.Length > 0));
            Assert.AreEqual("build@builder.example:22", AppSession.Name(app.Find("overview.record.remoteServer.endpoint")));
            Assert.AreEqual(strings["overview.record.remoteServer.bound"], AppSession.Name(app.Find("overview.record.remoteServer.state")));
        }
        using (var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--remote-sources-root", Root(Binding("TGT-FIXTURE-1"), withSource: false)]))
        {
            Assert.AreEqual(strings["overview.record.remoteServer.stale"], app.WaitForName("overview.record.remoteServer.state", n => n == strings["overview.record.remoteServer.stale"]));
        }
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void WithoutAnHdcNoDeviceIsInScope()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "foundation", "--language", "en-US"]);
        Assert.AreEqual(strings["overview.record.device.none"], app.WaitForName("overview.record.device.name", n => n.Length > 0));
        Assert.AreEqual(strings["overview.record.device.noneDetail"], AppSession.Name(app.Find("overview.record.device.facts")));
    }
}
