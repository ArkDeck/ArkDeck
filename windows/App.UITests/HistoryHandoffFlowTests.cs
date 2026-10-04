namespace ArkDeck.App.UITests;

/// <summary>
/// History's hand-off into the workspace that produced a record (macOS
/// <c>openHistoryWorkspace</c>), through UIA patterns only: the record's Open button names its
/// workspace, the workspace shows the read-only context banner (Job, Target, operation, state,
/// Artifacts) and takes the record's Target, and Dismiss removes the banner.
/// </summary>
[TestClass]
public sealed class HistoryHandoffFlowTests
{
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ADeviceRecordReopensInDevice()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "history"]);
        app.Select("history.row.job-0000000000000000000000000000a003");
        Assert.AreEqual(strings["history.activity.open.device"], app.WaitForName("history.openWorkspace", n => n.Length > 0));
        Assert.IsNull(app.TryFind("history.openDiagnostics", TimeSpan.FromMilliseconds(300)));
        app.Invoke("history.openWorkspace");
        Assert.AreEqual("job-0000000000000000000000000000a003", app.WaitForName("history.context.job", n => n.Length > 0));
        Assert.AreEqual(strings["history.context.title"], AppSession.Name(app.Find("history.context.title")));
        Assert.AreEqual(strings["history.context.readOnly"], AppSession.Name(app.Find("history.context.readOnly")));
        app.Find("hdc.devices.refresh");
        app.Invoke("history.context.dismiss");
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("history.context", TimeSpan.FromMilliseconds(200)) is null, "the banner goes away");
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ACaptureRecordReopensInTraceAndInDiagnostics()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "diagnostics", "--language", "en-US", "--page", "history"]);
        app.Select("history.row.job-6c545eb6042a9ea99e700467bbb77d06");
        Assert.AreEqual(strings["history.activity.open.trace"], app.WaitForName("history.openWorkspace", n => n.Length > 0));
        Assert.AreEqual(strings["history.activity.open.diagnostics"], AppSession.Name(app.Find("history.openDiagnostics")));
        app.Invoke("history.openWorkspace");
        Assert.AreEqual("job-6c545eb6042a9ea99e700467bbb77d06", app.WaitForName("history.context.job", n => n.Length > 0));
        Assert.AreEqual("TGT-3ba3f5f43b92", AppSession.Name(app.Find("history.context.target")));
        StringAssert.Contains(AppSession.Name(app.Find("history.context.artifacts")), "markers.json");
        app.Find("trace.refresh");
        // The record's Trace was never published, so the viewer is not opened; the page says why.
        Assert.AreEqual(strings["trace.viewer.artifactInvalid"], app.WaitForName("trace.status", n => n.Length > 0));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
