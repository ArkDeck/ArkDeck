namespace ArkDeck.App.UITests;

/// <summary>Settings' Runtime writes through UIA patterns only, over the scripted <c>jobs</c>
/// daemon: the retention policy checked, confirmed and saved by the Runtime; the default root
/// left alone; the Trace cache purge confirmed and reported.</summary>
[TestClass]
public sealed class SettingsWriteFlowTests
{
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ThePolicyAndThePurgeAreConfirmedAndTheRuntimeAnswers()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings"]);
        app.Select("settings.tab.storage");
        Assert.AreEqual("20", app.Find("settings.storage.policy.quota").Patterns.Value.Pattern.Value.Value);

        app.Find("settings.storage.policy.margin").Patterns.Value.Pattern.SetValue("50");
        app.Invoke("settings.storage.save");
        Assert.AreEqual(strings["settings.storage.validationError"], app.WaitForName("settings.storage.status", n => n.Length > 0));
        Assert.IsNull(app.TryFind("settings.storage.confirm", TimeSpan.FromMilliseconds(300)), "nothing to confirm");

        app.Find("settings.storage.policy.margin").Patterns.Value.Pattern.SetValue("2");
        app.Find("settings.storage.policy.quota").Patterns.Value.Pattern.SetValue("40");
        app.Invoke("settings.storage.save");
        app.Find("settings.storage.confirm");
        app.Invoke("PrimaryButton");
        Assert.AreEqual(strings["windows.settings.storage.saved"], app.WaitForName("settings.storage.status", n => n == strings["windows.settings.storage.saved"]));
        Assert.AreEqual(strings.Format("windows.bytes", ["42949672960"]), app.WaitForName("settings.storage.quota", n => n.Contains("42949672960", StringComparison.Ordinal)));

        app.Invoke("settings.storage.resetRoot");
        Assert.AreEqual(strings["windows.settings.storage.alreadyDefault"], app.WaitForName("settings.storage.status", n => n == strings["windows.settings.storage.alreadyDefault"]));

        app.Select("settings.tab.trace");
        app.Invoke("settings.trace.purge");
        app.Find("settings.trace.confirm");
        app.Invoke("PrimaryButton");
        Assert.AreEqual(strings.Format("windows.settings.trace.purgeDone", ["1"]), app.WaitForName("settings.trace.status", n => n.Length > 0 && n != strings["settings.common.working"]));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
