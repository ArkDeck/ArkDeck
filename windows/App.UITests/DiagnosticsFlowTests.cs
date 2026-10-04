namespace ArkDeck.App.UITests;

/// <summary>
/// Diagnostics through UIA patterns only (no synthetic input). Over the scripted
/// <c>diagnostics</c> daemon (the diagnostics-inspect oracle's session and job-run-hilog's summary
/// Job) a record is opened from History and read as macOS reads it: the alignment state, the marks
/// and their missing pictures, the missing products, a local text preview; the HiLog summary;
/// and Arm and Mark, which say that session capture is not connected.
/// </summary>
[TestClass]
public sealed class DiagnosticsFlowTests
{
    private const string SessionJob = "job-6c545eb6042a9ea99e700467bbb77d06";
    private const string HilogJob = "job-ce57f7b014978fe39492cf64043a8fc9";

    public TestContext TestContext { get; set; } = null!;

    /// <summary>Opens a record in Diagnostics: the session (a Trace workspace record) through
    /// Open Diagnostics, the HiLog summary (a Diagnostics record) through its Open button.</summary>
    private static void Open(AppSession app, string jobId)
    {
        app.Find("history.row." + jobId).Patterns.SelectionItem.Pattern.Select();
        app.Invoke(jobId == HilogJob ? "history.openWorkspace" : "history.openDiagnostics");
    }

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void ASavedSessionIsOpenedFromHistoryAndRead()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "diagnostics", "--language", "en-US", "--page", "history"]);
        Open(app, SessionJob);

        Assert.AreEqual(strings["diagnostics.alignment.cannotAlign"], app.WaitForName("diagnostics.alignment", n => n.Length > 0));
        Assert.AreEqual(SessionJob, app.WaitForName("diagnostics.session.job", n => n.Length > 0));
        Assert.AreEqual(strings["diagnostics.partial"], AppSession.Name(app.Find("diagnostics.partial")));
        Assert.AreEqual($"{strings["diagnostics.mark.manual"]} 1 · stutter", AppSession.Name(app.Find("diagnostics.mark.1.title")));
        Assert.AreEqual($"{strings["diagnostics.mark.auto"]} 2 · anr", AppSession.Name(app.Find("diagnostics.mark.2.title")));
        Assert.AreEqual(strings["diagnostics.mark.timeMissing"], AppSession.Name(app.Find("diagnostics.mark.time.2")));
        Assert.AreEqual(strings["diagnostics.shot.none"], AppSession.Name(app.Find("diagnostics.mark.1.noScreenshot")));
        Assert.AreEqual("trace capture failed", AppSession.Name(app.Find("diagnostics.missing.trace.htrace.reason")));
        Assert.AreEqual("frameDrops", AppSession.Name(app.Find("diagnostics.notDerived")));
        Assert.AreEqual(strings["diagnostics.alignment.explain"], AppSession.Name(app.Find("diagnostics.alignment.detail")));
        Assert.AreEqual(strings["diagnostics.selection.timeOnly"], AppSession.Name(app.Find("diagnostics.selection")));

        // Reading device text is an explicit local action.
        Assert.IsNull(app.TryFind("diagnostics.preview.text", TimeSpan.FromMilliseconds(300)));
        app.Invoke("diagnostics.artifact.read.hilog.txt");
        Assert.AreEqual("hilog.txt", app.WaitForName("diagnostics.preview.text", n => n.Length > 0));
        Assert.AreEqual($"{strings["diagnostics.artifacts.readSensitive"]}: private-hilog.txt", AppSession.Name(app.Find("diagnostics.artifact.read.private-hilog.txt")));
        // The failed Trace was never published, so there is nothing to open in the Trace viewer.
        Assert.IsNull(app.TryFind("diagnostics.artifacts.openTrace", TimeSpan.FromMilliseconds(300)));

        // Session capture is not connected: Arm and Mark say so.
        app.Invoke("diagnostics.capture.arm");
        StringAssert.StartsWith(app.WaitForName("diagnostics.status", n => n.Length > 0), strings["diagnostics.capture.unavailable"]);
        Assert.AreEqual("diagnostic_session_capture_not_connected", AppSession.Name(app.Find("diagnostics.capture.reasonCode")));
        Assert.AreEqual(strings["windows.diagnostics.capture.mark"], AppSession.Name(app.Find("diagnostics.capture.mark")));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ASavedHilogSummaryIsOpenedFromHistoryAndVerified()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "diagnostics", "--language", "en-US", "--page", "history"]);
        Open(app, HilogJob);
        Assert.AreEqual(strings["diagnostics.hilog.title"], app.WaitForName("diagnostics.workspace.title", n => n.Length > 0));
        Assert.AreEqual(HilogJob, app.WaitForName("diagnostics.hilog.job", n => n.Length > 0));
        var coverages = new[] { "complete", "partial", "unrecognized", "empty" }.Select(c => strings["diagnostics.hilog.coverage." + c]).ToArray();
        CollectionAssert.Contains(coverages, AppSession.Name(app.Find("diagnostics.hilog.coverage")));
        Assert.IsTrue(long.Parse(AppSession.Name(app.Find("diagnostics.hilog.count.lines")), System.Globalization.CultureInfo.InvariantCulture) > 0);
        StringAssert.StartsWith(AppSession.Name(app.Find("diagnostics.hilog.sourceArtifact")), "ART-");
        StringAssert.StartsWith(AppSession.Name(app.Find("diagnostics.hilog.sourceJob")), "job-");
        Assert.AreEqual(strings["diagnostics.hilog.digests"], AppSession.Name(app.Find("diagnostics.hilog.digests")));
        Assert.IsNull(app.TryFind("diagnostics.hilog.artifactDigest", TimeSpan.FromMilliseconds(300)));
        app.Invoke("diagnostics.hilog.digests");
        Assert.AreEqual(64, app.WaitForName("diagnostics.hilog.artifactDigest", n => n.Length == 64).Length);
        // The HiLog context has no capture pane.
        Assert.IsNull(app.TryFind("diagnostics.capture.arm", TimeSpan.FromMilliseconds(300)));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void WithoutARecordThePageSaysHowToOpenOne()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "diagnostics"]);
        Assert.AreEqual(strings["diagnostics.session.none"], app.WaitForName("diagnostics.session.empty", n => n.Length > 0));
        Assert.AreEqual(strings["diagnostics.alignment.cannotAlign"], AppSession.Name(app.Find("diagnostics.alignment")));
        app.Invoke("diagnostics.capture.mark");
        StringAssert.StartsWith(app.WaitForName("diagnostics.status", n => n.Length > 0), strings["diagnostics.capture.unavailable"]);
    }
}
