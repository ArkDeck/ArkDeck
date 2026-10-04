namespace ArkDeck.App.UITests;

/// <summary>Overview's next step, run threads, Run It Again and the prepared continuation through
/// UIA patterns only, over the scripted <c>continue</c> daemon (macOS <c>OverviewRecordView</c>,
/// <c>OverviewResumeSheet</c>, <c>WorkspaceContinuationCard</c>).</summary>
[TestClass]
public sealed class OverviewRecordFlowTests
{
    private const string Observe = "job-0000000000000000000000000000c001";
    private const string ObserveOlder = "job-0000000000000000000000000000c002";
    private const string Flash = "job-0000000000000000000000000000c003";
    private const string Unknown = "job-0000000000000000000000000000c004";
    private const string Unreported = "job-0000000000000000000000000000c005";
    private const string Thread = "thread:t-observe-0001";

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void ARecordedRunIsPreparedAndStartedOnceAsANewJob()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "continue", "--language", "en-US", "--page", "overview"]);

        // The next step is the line that needs a person: the unknown outcome, never replayed.
        Assert.AreEqual(strings["overview.record.next.attention"], app.WaitForName("overview.record.next.attention", n => n.Length > 0));
        Assert.AreEqual(strings["overview.record.next.unknownDetail"], AppSession.Name(app.Find("overview.record.next.detail")));
        Assert.AreEqual(strings["overview.record.refusal.neverReplayed"], AppSession.Name(app.Find($"overview.record.run.{Unknown}.refusal")));
        Assert.AreEqual(strings["overview.record.refusal.parametersNotReported"], AppSession.Name(app.Find($"overview.record.run.{Unreported}.refusal")));
        Assert.AreEqual(strings["overview.record.run.againGated"], AppSession.Name(app.Find($"overview.record.run.{Flash}.again")));

        // A line's other runs behind Show more.
        Assert.IsNull(app.TryFind("overview.record.run." + ObserveOlder, TimeSpan.FromMilliseconds(300)));
        app.Invoke($"overview.record.thread.{Thread}.more");
        app.Find("overview.record.run." + ObserveOlder);
        app.Invoke($"overview.record.thread.{Thread}.more");
        Assert.IsNull(app.TryFind("overview.record.run." + ObserveOlder, TimeSpan.FromMilliseconds(500)));

        // Run It Again shows what the source recorded, then prepares a draft (nothing submitted).
        app.Invoke($"overview.record.run.{Observe}.again");
        app.Find("overview.resume.title");
        Assert.AreEqual("true", AppSession.Name(app.Find("overview.resume.parameter.refreshServerFacts")));
        Assert.AreEqual("TGT-FIXTURE-1", AppSession.Name(app.Find("overview.resume.target")));
        Assert.IsNull(app.TryFind("overview.resume.prepare.reason", TimeSpan.FromMilliseconds(300)));
        app.Invoke("overview.resume.prepare");
        app.Find("overview.continuation.title");
        StringAssert.Contains(AppSession.Name(app.Find("overview.continuation.inputs")), "observe.device@1");

        // Started once: a new Job, run to its end; a second start is refused in words.
        app.Invoke("overview.continuation.submit");
        Assert.AreEqual("succeeded", app.WaitForName("overview.continuation.result", n => n == "succeeded"));
        app.Find("overview.continuation.openJob");
        app.Invoke("overview.continuation.submit");
        Assert.AreEqual(strings["windows.overview.continuation.attempted"], app.WaitForName("overview.continuation.result", n => n != "succeeded"));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        app.Invoke("overview.continuation.close");
        Assert.IsNull(app.TryFind("overview.continuation.title", TimeSpan.FromMilliseconds(500)));
    }

    /// <summary>A destructive run re-enters its workspace's gate: the sheet says so, refuses to
    /// prepare a draft or open a prefilled workspace, and Cancel closes it.</summary>
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ADestructiveRunIsNotPreparedAgain()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "continue", "--language", "en-US", "--page", "overview"]);
        app.Invoke($"overview.record.run.{Flash}.again");
        Assert.AreEqual(strings.Format("overview.resume.gated", ["destructive"]), app.WaitForName("overview.resume.gated", n => n.Length > 0));
        app.Invoke("overview.resume.prepare");
        StringAssert.EndsWith(app.WaitForName("overview.resume.status", n => n.Length > 0), "continuation_source_not_repeatable");
        app.Invoke("overview.resume.open");
        Assert.AreEqual(strings["windows.overview.resume.openRefused"], app.WaitForName("overview.resume.status", n => !n.EndsWith("repeatable", StringComparison.Ordinal)));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        app.Invoke("overview.resume.cancel");
        Assert.IsNull(app.TryFind("overview.resume.title", TimeSpan.FromMilliseconds(500)));
    }
}
