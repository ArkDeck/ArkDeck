using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>
/// The TASK-XPA-020 actions through UIA patterns only (no synthetic input): renaming and
/// clearing a Target's Runtime display name in the Fluent dialog, and the macOS export preview
/// of a Job's Artifact. The scripted transport answers as the Windows daemon over a
/// development root (<c>targets</c>) and as a daemon with Jobs and Artifacts (<c>jobs</c>).
/// </summary>
[TestClass]
public sealed class SurfaceFlowTests
{
    private const string Oracle = "TGT-3ba3f5f43b92";
    private const string TraceJob = "job-0000000000000000000000000000a003";
    private const string FailedJob = "job-0000000000000000000000000000a002";
    private const string Trace = "ART-00000000000000000000000000000c01";
    private const string Missing = "ART-00000000000000000000000000000b02";

    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void ATargetIsRenamedAndClearedThroughTheRuntime()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "targets", "--language", "en-US", "--page", "device"]);
        app.Select("device.target." + Oracle);
        Assert.AreEqual(Oracle, app.WaitForName("device.target.detail.title", n => n.Length > 0));
        Assert.IsNull(app.TryFind("device.target.clearName", TimeSpan.FromMilliseconds(300)), "nothing to clear before a name exists");

        // A name outside the macOS rule is not sent: the dialog stays open and says why.
        app.Invoke("device.target.rename");
        var field = app.Find("device.rename.field");
        field.Patterns.Value.Pattern.SetValue("   ");
        app.Invoke("PrimaryButton");
        Assert.AreEqual(strings["device.rename.message"], app.WaitForName("device.rename.problem", n => n.Length > 0));
        var problem = app.Find("device.rename.problem");
        Assert.AreEqual(LiveSetting.Assertive, problem.Properties.LiveSetting.ValueOrDefault);

        field.Patterns.Value.Pattern.SetValue("  Bench \t board ");
        app.Invoke("PrimaryButton");
        Assert.AreEqual(strings.Format("windows.device.rename.saved", ["Bench board"]), app.WaitForName("device.target.nameStatus", n => n.Length > 0));
        app.WaitForName("device.target." + Oracle, n => n == "Bench board, " + Oracle);
        app.WaitForName("device.target.detail.title", n => n == "Bench board");

        app.Invoke("device.target.clearName");
        app.WaitForName("device.target.nameStatus", n => n == strings["windows.device.rename.cleared"]);
        app.WaitForName("device.target." + Oracle, n => n == Oracle);
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void TheExportPreviewNamesWhatWillBeWritten()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "history"]);

        // Only a published Artifact offers Export…; a missing one says so and offers nothing.
        app.Select("history.row." + FailedJob);
        app.WaitForName("history.artifact." + Missing, n => n == "partition-table.json, missing");
        Assert.IsNull(app.TryFind("history.artifact.export." + Missing, TimeSpan.FromMilliseconds(500)));

        app.Select("history.row." + TraceJob);
        app.Invoke("history.artifact.export." + Trace);
        var preview = app.Find("history.artifacts.exportPreview");
        Assert.AreEqual(strings["history.artifacts.exportPreview.title"], AppSession.Name(preview));
        var message = app.WaitForName("history.artifacts.exportPreview.message", n => n.Length > 0);
        TestContext.WriteLine(message);
        StringAssert.Contains(message, "trace.htrace");
        StringAssert.Contains(message, strings.Format("windows.bytes", ["300,000"]));
        StringAssert.Contains(message, "sensitive");
        Assert.AreEqual(strings["history.artifacts.exportSensitive"], AppSession.Name(app.Find("PrimaryButton")), "a sensitive Artifact is confirmed as such");
        Assert.AreEqual(strings["history.artifacts.exportCancel"], AppSession.Name(app.Find("CloseButton")));
        app.Invoke("CloseButton");
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("history.artifacts.exportPreview", TimeSpan.FromMilliseconds(200)) is null, "the preview closes");
        Assert.IsNull(app.TryFind("history.artifact.exporting." + Trace, TimeSpan.FromMilliseconds(300)), "cancelled: nothing read");
    }

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void AQueuedJobIsCancelledAfterConfirmation()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US"]);
        app.ShowInspector();
        app.Select("jobInspector.row.job-0000000000000000000000000000a004");
        Assert.AreEqual(strings["job.state.queued"], app.WaitForName("jobInspector.state", n => n.Length > 0));

        // Cancel in the confirmation: nothing is sent, the Job stays queued.
        app.Invoke("jobInspector.cancel");
        Assert.AreEqual(strings["windows.jobInspector.cancel.title"], AppSession.Name(app.Find("jobInspector.cancel.confirm")));
        StringAssert.Contains(app.WaitForName("jobInspector.cancel.message", n => n.Length > 0), "job-0000000000000000000000000000a004");
        app.Invoke("CloseButton");
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("jobInspector.cancel.confirm", TimeSpan.FromMilliseconds(200)) is null, "the confirmation closes");
        Assert.AreEqual(strings["job.state.queued"], AppSession.Name(app.Find("jobInspector.state")));

        app.Invoke("jobInspector.cancel");
        app.Find("jobInspector.cancel.confirm");
        app.Invoke("PrimaryButton");
        Assert.AreEqual(strings["jobInspector.cancel.requested"], app.WaitForName("jobInspector.cancel.result", n => n.Length > 0));
        app.WaitForName("jobInspector.state", n => n == strings["job.state.cancelled"]);
        Assert.IsNull(app.TryFind("jobInspector.cancel", TimeSpan.FromMilliseconds(500)), "a terminal Job offers no cancellation");
        app.WaitForName("jobInspector.result.artifacts", n => n.Length > 0);

        // Open this record: History with the Job's detail and evidence.
        app.Invoke("jobInspector.openRecord");
        Assert.AreEqual("job-0000000000000000000000000000a004", app.WaitForName("history.detail.job", n => n.Length > 0));
        app.Find("history.detail.evidence");
    }

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void SessionsArePinnedAndCleanedUpThroughTheirPreview()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        const string observed = "session-job-0f77f8c52864d676372962eccb17389c";
        const string failed = "session-job-efd52ab9c633074171a19ddd916fffd9";
        using var app = AppSession.Launch(exe, ["--test-transport", "targets", "--language", "en-US", "--page", "sessions"]);
        app.Select("sessions.row." + observed);
        app.Invoke("sessions.pin");
        Assert.AreEqual(strings["windows.sessions.pinnedDone"], app.WaitForName("sessions.status", n => n.Length > 0));
        app.Select("sessions.row." + observed);
        Assert.AreEqual(strings["windows.sessions.pinnedYes"], app.WaitForName("sessions.detail.pinned", n => n == strings["windows.sessions.pinnedYes"]));

        app.Invoke("sessions.cleanup");
        Assert.AreEqual(strings["windows.sessions.cleanup.title"], AppSession.Name(app.Find("sessions.cleanup.preview")));
        TestContext.WriteLine(app.WaitForName("sessions.cleanup.message", n => n.Length > 0));
        app.Find("sessions.cleanup.session." + failed);
        Assert.IsNull(app.TryFind("sessions.cleanup.session." + observed, TimeSpan.FromMilliseconds(300)), "the pinned Session is not in the removal");
        app.Invoke("PrimaryButton");
        app.WaitForName("sessions.status", n => n == strings.Format("windows.sessions.cleanup.done", ["1", strings.Format("windows.bytes", ["7013"])]));
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("sessions.row." + failed, TimeSpan.FromMilliseconds(200)) is null, "the removed Session leaves the list");
        app.Find("sessions.row." + observed);
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
