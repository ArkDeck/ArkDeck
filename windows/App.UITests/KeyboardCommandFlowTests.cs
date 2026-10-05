namespace ArkDeck.App.UITests;

/// <summary>The macOS keyboard commands, the Trace document type and the restored selection,
/// through key strokes and UIA only (macOS <c>WorkspaceKeyboardCommands</c>, the Trace menu,
/// <c>CFBundleDocumentTypes</c> and <c>storedSelection</c>).</summary>
[TestClass]
public sealed class KeyboardCommandFlowTests
{
    private const int F = 0x46, N = 0x4E, R = 0x52;

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void CtrlFFindsTheSearchAndCtrlNOpensTrace()
    {
        var exe = AppSession.RequireApp();
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "history"]);
        // The host runs its tests with the desktop locked, so the system's focus is the lock
        // screen: the search field's own keyboard-focus state is what Ctrl+F changes.
        var search = app.Find("history.filter.search");
        Assert.IsFalse(search.Properties.HasKeyboardFocus.ValueOrDefault);
        KeyInput.PressControl(app.Handle, F);
        SemanticSnapshotTests.WaitUntil(() => app.Find("history.filter.search").Properties.HasKeyboardFocus.ValueOrDefault, "Ctrl+F focuses the search");
        KeyInput.PressControl(app.Handle, N);
        SemanticSnapshotTests.WaitUntil(() => app.Find("app.navigation.trace").Patterns.SelectionItem.Pattern.IsSelected.Value, "Ctrl+N opens Trace");
    }

    /// <summary>Ctrl+R re-reads the page: the daemon that went away is noticed.</summary>
    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void CtrlRReadsThePageAgain()
    {
        var exe = AppSession.RequireApp();
        using var app = AppSession.Launch(exe, ["--test-transport", "outage", "--language", "en-US"]);
        app.WaitForName("overview.doctor.overall", n => n.Length > 0);
        Assert.IsNull(app.TryFind("app.recovery.retry", TimeSpan.FromMilliseconds(500)));
        KeyInput.PressControl(app.Handle, R);
        app.WaitForName("overview.doctor.unavailable.reason", n => n.StartsWith("unavailable(daemonUnavailable)", StringComparison.Ordinal));
    }

    /// <summary>A Trace file handed to the App opens in the Trace viewer, and the page shown last
    /// comes back at the next launch.</summary>
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void AHandedTraceOpensAndTheLastPageComesBack()
    {
        var exe = AppSession.RequireApp();
        var folder = Directory.CreateTempSubdirectory("arkdeck-uitest-keys-");
        try
        {
            var trace = Path.Combine(folder.FullName, "handed.htrace");
            File.WriteAllBytes(trace, [0x68, 0x74, 0x72, 0x61, 0x63, 0x65]);
            var preferences = Path.Combine(folder.FullName, "preferences");
            using (var app = AppSession.Launch(exe, ["--test-transport", "viewer", "--language", "en-US", "--cache-root", folder.FullName,
                       "--preferences-root", preferences, trace]))
            {
                Assert.AreEqual("handed.htrace", app.WaitForName("trace.viewer.document", n => n.Length > 0));
                Assert.IsTrue(app.Find("app.navigation.traceViewer").Patterns.SelectionItem.Pattern.IsSelected.Value);
                app.Navigate("history");
                app.Find("history.filter.search");
            }
            using (var again = AppSession.Launch(exe, ["--test-transport", "viewer", "--language", "en-US", "--cache-root", folder.FullName,
                       "--preferences-root", preferences]))
            {
                SemanticSnapshotTests.WaitUntil(() => again.Find("app.navigation.history").Patterns.SelectionItem.Pattern.IsSelected.Value, "the last page");
            }
        }
        finally
        {
            folder.Delete(recursive: true);
        }
    }
}
