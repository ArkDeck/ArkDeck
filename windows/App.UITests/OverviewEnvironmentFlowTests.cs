namespace ArkDeck.App.UITests;

/// <summary>Overview's HDC environment through UIA patterns only, over the scripted <c>jobs</c>
/// daemon (macOS <c>HDCStatusView</c>): the summary facts, the disclosure with the server, the
/// capability matrix of the device in scope (hidumper proved by a read-only window inventory
/// when asked), the device and channel, and the advanced facts.</summary>
[TestClass]
public sealed class OverviewEnvironmentFlowTests
{
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TheEnvironmentShowsTheRuntimesHdcAndTheDeviceInScope()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "overview"]);
        Assert.AreEqual(strings["overview.serverHealth.healthy"], app.WaitForName("overview.status.server.value", n => n.Length > 0));
        Assert.AreEqual(strings["overview.trust.ready"], AppSession.Name(app.Find("overview.status.trust.value")));
        Assert.AreEqual(strings["overview.status.needsAttention.none"], AppSession.Name(app.Find("overview.status.needsAttention.value")));
        Assert.IsNull(app.TryFind("hdc.endpoint", TimeSpan.FromMilliseconds(300)), "collapsed");

        app.Invoke("overview.advanced.toggle");
        Assert.AreEqual("127.0.0.1:8710", app.WaitForName("hdc.endpoint", n => n.Length > 0));
        Assert.AreEqual("arkDeckManaged", AppSession.Name(app.Find("hdc.ownership")));
        Assert.AreEqual("ready", AppSession.Name(app.Find("hdc.authorization")));
        Assert.AreEqual(strings.Format("overview.capabilities.title.target", ["TGT-FIXTURE-1", "3"]), AppSession.Name(app.Find("overview.capabilities.matrixTitle")));
        Assert.AreEqual(strings["overview.capabilities.state.unknown"], AppSession.Name(app.Find("overview.capabilities.hidumper.state")));

        app.Invoke("overview.capabilities.hidumper.check");
        Assert.AreEqual(strings["overview.capabilities.state.available"], app.WaitForName("overview.capabilities.hidumper.state", n => n == strings["overview.capabilities.state.available"]));
        StringAssert.StartsWith(AppSession.Name(app.Find("overview.capabilities.hidumper.evidence")), "debug.template@1 Job succeeded · job-");
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");

        app.Invoke("overview.advanced.toggle");
        Assert.IsNull(app.TryFind("hdc.endpoint", TimeSpan.FromMilliseconds(500)), "collapsed again");
    }
}
