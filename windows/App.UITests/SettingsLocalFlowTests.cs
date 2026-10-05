namespace ArkDeck.App.UITests;

/// <summary>Settings' App-local parts through UIA patterns only: the window icon choice, the
/// update channel of an unpackaged copy, and the diagnostic bundle previewed, then exported
/// for that preview (the folder picker answered by <c>--pick-folder</c>).</summary>
[TestClass]
public sealed class SettingsLocalFlowTests
{
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TheIconUpdatesAndTheDiagnosticBundleAreLocal()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var parent = Directory.CreateTempSubdirectory("arkdeck-uitest-bundle-").FullName;
        try
        {
            using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings", "--pick-folder", parent]);
            Assert.IsTrue(app.Find("settings.general.appIcon.waveform").Patterns.SelectionItem.Pattern.IsSelected.Value, "the default");
            app.Select("settings.general.appIcon.keycap");
            Assert.IsTrue(app.Find("settings.general.appIcon.keycap").Patterns.SelectionItem.Pattern.IsSelected.Value);

            app.Select("settings.tab.updates");
            Assert.AreEqual(strings["windows.update.notPackaged"], app.WaitForName("update.status", n => n.Length > 0), "the test build is not an MSIX package");

            app.Select("settings.tab.diagnostics");
            app.Invoke("settings.diagnostics.preview");
            var destination = app.WaitForName("settings.diagnostics.destination", n => n.Length > 0);
            StringAssert.StartsWith(destination, parent);
            Assert.AreEqual(64, AppSession.Name(app.Find("settings.diagnostics.scopeHash")).Length);
            Assert.AreEqual(strings["settings.diagnostics.excluded"], AppSession.Name(app.Find("settings.diagnostics.deviceRaw")));
            Assert.IsFalse(Directory.Exists(destination), "a preview writes nothing");
            app.Invoke("settings.diagnostics.exportNow");
            Assert.AreEqual(strings["settings.diagnostics.exported"], app.WaitForName("settings.diagnostics.status", n => n.Length > 0));
            app.Find("settings.diagnostics.reveal");
            Assert.IsTrue(File.Exists(Path.Combine(destination, "bundle.json")));
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }
}
