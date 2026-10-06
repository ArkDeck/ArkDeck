namespace ArkDeck.App.UITests;

/// <summary>UIA semantic actions over a task-private fake provider. No Runtime or hardware is involved.</summary>
[TestClass]
public sealed class DiagnosticCaptureFlowTests
{
    private const string Job = "job-859b86ab3981a6c5194e9a6c77ac9667";

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void OneInteractiveCaptureKeepsItsOwnerAcrossNavigationAndOpensItsOwnHistory()
    {
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", "diagnostic-capture", "--language", "en-US", "--page", "diagnostics"]);
        app.Invoke("diagnostics.capture.arm");
        Assert.AreEqual(strings["diagnostics.capture.state.recording"], app.WaitForName("diagnostics.capture.state", n => n == strings["diagnostics.capture.state.recording"]));
        Assert.AreEqual(Job, AppSession.Name(app.Find("diagnostics.capture.job")));
        // Navigation retains the one admitted owner; it does not start a new Job.
        app.Navigate("history");
        app.Navigate("diagnostics");
        Assert.AreEqual(Job, app.WaitForName("diagnostics.capture.job", n => n == Job));
        app.Invoke("diagnostics.capture.mark");
        app.WaitForName("diagnostics.capture.markCount", n => n.EndsWith("1 / 50", StringComparison.Ordinal));
        app.Invoke("diagnostics.capture.stop");
        Assert.AreEqual(Job, app.WaitForName("diagnostics.session.job", n => n == Job));
        Assert.AreEqual(strings["diagnostics.alignment.cannotAlign"], AppSession.Name(app.Find("diagnostics.alignment")));
        Assert.AreEqual(strings["diagnostics.capture.state.closed"], app.WaitForName("diagnostics.capture.state", n => n == strings["diagnostics.capture.state.closed"]));
        StringAssert.StartsWith(AppSession.Name(app.Find("diagnostics.alignment.detail")), strings["diagnostics.alignment.observedWindow"].Split("{milliseconds}")[0]);
        app.Navigate("history");
        app.Find("history.row." + Job).Patterns.SelectionItem.Pattern.Select();
        app.Invoke("history.openWorkspace");
        Assert.AreEqual(Job, app.WaitForName("diagnostics.session.job", n => n == Job));
        foreach (var control in new[] { "arm", "mark", "stop", "cancelPreparation" })
            Assert.IsNull(app.TryFind("diagnostics.capture." + control, TimeSpan.FromMilliseconds(300)));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, "XPA-AC-8: no disabled placeholder");
    }
}
