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
}
