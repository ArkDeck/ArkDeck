namespace ArkDeck.App.UITests;

/// <summary>
/// The release-candidate smoke's App step (TASK-XPA-022, windows/scripts/package-rc.ps1): the
/// installed <c>ArkDeck.exe</c> of an unpacked RC, beside the installed daemon that the
/// installed CLI has just started, connects to it with only the installation inputs the CLI
/// reads — the endpoint and the development signer pin; the daemon path is left to the
/// App's default, the <c>arkdeck-agentd.exe</c> beside it — and shows the daemon's doctor
/// report with no recovery banner. Run by the smoke, which sets <c>ARKDECK_RC_APP</c>,
/// <c>ARKDECK_RC_ENDPOINT</c> and <c>ARKDECK_RC_SIGNER_SHA256</c>; skipped otherwise.
/// </summary>
[TestClass]
public sealed class InstalledRcTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void TheInstalledAppConnectsToTheDaemonTheCliStarted()
    {
        if (Environment.GetEnvironmentVariable("ARKDECK_APP_UITESTS") != "1")
        {
            Assert.Inconclusive("skipped: UIA tests of the running App need a Windows desktop session; set ARKDECK_APP_UITESTS=1 to run them");
        }
        var exe = Environment.GetEnvironmentVariable("ARKDECK_RC_APP");
        var endpoint = Environment.GetEnvironmentVariable("ARKDECK_RC_ENDPOINT");
        var pin = Environment.GetEnvironmentVariable("ARKDECK_RC_SIGNER_SHA256");
        if (string.IsNullOrEmpty(exe) || string.IsNullOrEmpty(endpoint) || string.IsNullOrEmpty(pin))
        {
            Assert.Inconclusive("skipped: run by windows/scripts/package-rc.ps1 -Smoke (ARKDECK_RC_APP, ARKDECK_RC_ENDPOINT, ARKDECK_RC_SIGNER_SHA256)");
        }
        Assert.IsTrue(File.Exists(exe), exe);
        Assert.IsTrue(File.Exists(Path.Combine(Path.GetDirectoryName(exe)!, "arkdeck-agentd.exe")), "the daemon is installed beside the App");

        using var app = AppSession.Launch(exe!, ["--language", "en-US"], new Dictionary<string, string>
        {
            ["ARKDECK_ENDPOINT"] = endpoint!,
            ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin!,
        });
        Assert.IsNull(app.TryFind("app.testTransport", TimeSpan.FromSeconds(1)), "no test transport");
        string overall;
        try
        {
            overall = app.WaitForName("overview.doctor.overall", n => n.Length > 0);
        }
        catch (AssertFailedException error)
        {
            // Say why: the recovery banner names what ClientKit refused.
            var reason = app.TryFind("app.recovery.reason", TimeSpan.FromSeconds(1)) is { } element ? AppSession.Name(element) : "(no recovery banner)";
            throw new AssertFailedException(error.Message + "; recovery reason: " + reason);
        }
        TestContext.WriteLine("overview: " + overall + " / " + AppSession.Name(app.Find("overview.doctor.counts")));
        StringAssert.StartsWith(AppSession.Name(app.Find("overview.runtime.protocol")), "1.0.0");
        Assert.IsNull(app.TryFind("app.recovery.retry", TimeSpan.FromMilliseconds(500)), "no recovery banner while the daemon answers");
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
