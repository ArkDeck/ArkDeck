namespace ArkDeck.App.UITests;

/// <summary>Read-only Toolchains inventory through UIA over task-private software fixtures.</summary>
[TestClass]
public sealed class ToolchainInventoryFlowTests
{
    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void CompleteInventoryShowsBothPagesAndRuntimeSelectedFacts(string language)
    {
        var strings = Catalogue.Load(language);
        using var app = Launch("toolchain-inventory", language);
        var selected = strings["windows.settings.tools.selected"];
        StringAssert.EndsWith(app.WaitForName("settings.toolchains.tool.tool-hdc-3.2.0f.text", n => n.Contains(selected, StringComparison.Ordinal)), selected + ": true");
        StringAssert.EndsWith(AppSession.Name(app.Find("settings.toolchains.tool.tool-hdc-fixture-secondary.text")), selected + ": false");
        foreach (var (digest, state, references) in new[] { (new string('a', 64), "available", "1"), (new string('b', 64), "removed", "0") })
        {
            var id = "settings.toolchains.bundle.bundle:sha256:" + digest;
            StringAssert.EndsWith(AppSession.Name(app.Find(id)), state);
            Assert.AreEqual(digest, AppSession.Name(app.Find(id + ".digest")));
            Assert.AreEqual("4096", AppSession.Name(app.Find(id + ".bytes")));
            Assert.AreEqual("3", AppSession.Name(app.Find(id + ".entries")));
            Assert.AreEqual("true", AppSession.Name(app.Find(id + ".retained")));
            Assert.AreEqual(references, AppSession.Name(app.Find(id + ".references")));
            Assert.AreEqual("arkdeck.windows-daemon-package/1 · verified · notPerformed · fixture-signer", AppSession.Name(app.Find(id + ".trust")));
        }
        ReadonlyBoundary(app);
    }

    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void EmptyRegistryIsAnEmptyFactWithTheMaintenanceCli(string language)
    {
        var strings = Catalogue.Load(language);
        using var app = Launch("toolchain-inventory-empty", language);
        Assert.AreEqual(strings["windows.settings.bundles.empty"], app.WaitForName("settings.toolchains.bundles.empty", n => n.Length > 0));
        Assert.IsNull(app.TryFind("settings.toolchains.bundles.list", TimeSpan.FromMilliseconds(300)));
        ReadonlyBoundary(app);
    }

    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void RefusedRegistryKeepsItsReasonAndNeverShowsPartialRows(string language)
    {
        var strings = Catalogue.Load(language);
        using var app = Launch("toolchain-inventory-refused", language);
        Assert.AreEqual(strings["windows.settings.bundles.unavailable"], app.WaitForName("settings.toolchains.bundles.unavailable", n => n.Length > 0));
        StringAssert.Contains(AppSession.Name(app.Find("settings.toolchains.bundles.unavailable.reason")), "recordUnreadable");
        Assert.IsNull(app.TryFind("settings.toolchains.bundles.list", TimeSpan.FromMilliseconds(300)));
        Assert.IsNull(app.TryFind("settings.toolchains.bundles.empty", TimeSpan.FromMilliseconds(300)));
        ReadonlyBoundary(app);
    }

    private static AppSession Launch(string scenario, string language)
    {
        var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", scenario, "--language", language, "--page", "settings"]);
        app.Select("settings.tab.toolchains");
        return app;
    }

    private static void ReadonlyBoundary(AppSession app)
    {
        StringAssert.Contains(AppSession.Name(app.Find("settings.toolchains.bundles.cli")), "arkdeck runtime bundle list");
        StringAssert.Contains(AppSession.Name(app.Find("settings.toolchains.signing.cli")), "arkdeck runtime signing status");
        // The inventory does not introduce selection, registration, or lifecycle controls.
        foreach (var button in app.Buttons())
        {
            Assert.IsTrue(button.Enabled, "XPA-AC-8: no disabled placeholder");
            Assert.IsFalse(button.Id.StartsWith("settings.toolchains.bundle.select", StringComparison.Ordinal)
                || button.Id.StartsWith("settings.toolchains.bundle.register", StringComparison.Ordinal)
                || button.Id.StartsWith("settings.toolchains.tool.select", StringComparison.Ordinal));
        }
    }
}
