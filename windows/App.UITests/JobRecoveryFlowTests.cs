namespace ArkDeck.App.UITests;

/// <summary>The global Job recovery banner (macOS <c>GlobalRecoveryBannerView</c>) through UIA
/// patterns only: over the scripted <c>recovery</c> daemon both records that need a person are
/// shown with their kind, guidance, Job and Target and the count, and Open in History opens the
/// record; over <c>foundation</c> (no Job owner) there is no banner.</summary>
[TestClass]
public sealed class JobRecoveryFlowTests
{
    private const string Waiting = "job-0000000000000000000000000000a0f1";
    private const string ResumeSafe = "job-0000000000000000000000000000a0f2";

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void RecordsThatNeedAPersonAreShownAndOpenInHistory()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "recovery", "--language", "en-US"]);
        Assert.AreEqual(strings["jobRecovery.waiting.title"], app.WaitForName("jobRecovery.title." + Waiting, n => n.Length > 0));
        Assert.AreEqual(strings["jobRecovery.resumeSafe.title"], AppSession.Name(app.Find("jobRecovery.title." + ResumeSafe)));
        Assert.AreEqual(strings["jobRecovery.resumeSafe.guidance"], AppSession.Name(app.Find("jobRecovery.guidance." + ResumeSafe)));
        Assert.AreEqual($"{Waiting} · TGT-FIXTURE-1", AppSession.Name(app.Find("jobRecovery.job." + Waiting)));
        StringAssert.StartsWith(AppSession.Name(app.Find("jobRecovery.count")), "2 ");
        app.Invoke("jobRecovery.openHistory." + Waiting);
        Assert.AreEqual(Waiting, app.WaitForName("history.detail.job", n => n == Waiting));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void NoRecordNoBanner()
    {
        var exe = AppSession.RequireApp();
        using var app = AppSession.Launch(exe, ["--test-transport", "foundation", "--language", "en-US"]);
        app.WaitForName("overview.doctor.overall", n => n.Length > 0);
        Assert.IsNull(app.TryFind("jobRecovery.count", TimeSpan.FromSeconds(2)));
        Assert.IsNull(app.TryFind("jobRecovery.banner", TimeSpan.FromMilliseconds(300)));
    }
}
