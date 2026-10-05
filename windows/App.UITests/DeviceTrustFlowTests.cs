namespace ArkDeck.App.UITests;

/// <summary>The Device section's rows, a device's detail with the trust steps and the bounded
/// wait, the App-local name and the live observation, through UIA only (macOS
/// <c>DeviceListViewModel</c>, <c>DeviceSidebarRow</c>, <c>DeviceDetailView</c>).</summary>
[TestClass]
public sealed class DeviceTrustFlowTests
{
    private const string Unauthorized = "fixture-serial-2";
    private const string Offline = "fixture-serial-3";

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void AnUnauthorizedDeviceIsWaitedForUntilItTrustsThisComputer()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "trust", "--language", "en-US", "--page", "device", "--trust-wait-fast"]);
        app.Navigate("device." + Unauthorized);
        Assert.AreEqual(strings["device.trust.waiting"], app.WaitForName("device.trust.waiting", n => n.Length > 0));
        app.Find("device.trust.step1");
        app.Find("device.trust.step3");
        app.Invoke("device.action.beginWait");
        Assert.AreEqual(strings["device.trust.authorizedUnadopted"], app.WaitForName("device.trust.ready", n => n.Length > 0), "the wait ends when the device trusts this computer");
        Assert.AreEqual("Connected", AppSession.Name(app.Find("device.fact.state")));
        app.Find("device.detail.adoptViaCLI.candidate");
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void AWaitThatRunsOutSaysSoAndADeviceCanBeNamedHere()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "device", "--trust-wait-fast"]);
        app.Navigate("device." + Unauthorized);
        app.Invoke("device.action.beginWait");
        Assert.AreEqual(strings["device.wait.timedOut"], app.WaitForName("device.wait.timedOut", n => n.Length > 0));
        Assert.AreEqual(strings["device.action.retryWait"], AppSession.Name(app.Find("device.action.beginWait")));

        app.Navigate("device." + Offline);
        Assert.AreEqual(strings["device.trust.offline"], app.WaitForName("device.trust.offline", n => n.Length > 0));
        app.Invoke("device.action.rename");
        app.Find("device.rename.field").Patterns.Value.Pattern.SetValue("  Spare   board ");
        app.Invoke("PrimaryButton");
        StringAssert.StartsWith(app.WaitForName("app.navigation.device." + Offline, n => n.StartsWith("Spare board", StringComparison.Ordinal)), "Spare board");
        app.Invoke("device.action.clearAlias");
        SemanticSnapshotTests.WaitUntil(() => !AppSession.Name(app.Find("app.navigation.device." + Offline)).StartsWith("Spare", StringComparison.Ordinal), "the alias is gone");
    }

    /// <summary>The live observation re-reads the devices on its own: the sidebar row follows the
    /// device without a refresh.</summary>
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TheSidebarFollowsTheLiveObservation()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "trust", "--language", "en-US", "--page", "overview", "--live-observation-ms", "300"]);
        StringAssert.Contains(app.WaitForName("app.navigation.device." + Unauthorized, n => n.Length > 0), strings["device.state.needsTrust"]);
        StringAssert.Contains(app.WaitForName("app.navigation.device." + Unauthorized, n => n.Contains(strings["device.state.authorizedUnadopted"], StringComparison.Ordinal)),
            strings["device.state.authorizedUnadopted"]);
    }
}
