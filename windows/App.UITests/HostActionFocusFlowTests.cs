using FlaUI.Core.AutomationElements;

namespace ArkDeck.App.UITests;

/// <summary>Native keyboard/focus behavior over task-private scripted owners. No Runtime or device is used.</summary>
[TestClass]
public sealed class HostActionFocusFlowTests
{
    private const int Enter = 0x0D, Right = 0x27, Up = 0x26;
    private const string Observed = "session-job-0f77f8c52864d676372962eccb17389c";
    private const string Removable = "session-job-efd52ab9c633074171a19ddd916fffd9";

    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void CleanupCancelEnterAndEscapeKeepTheReviewedSessionsAndReturnFocus(string language)
    {
        var strings = Catalogue.Load(language);
        using var app = PinnedSessions(language);
        var before = AppSession.Name(app.Find("sessions.status"));
        foreach (var dismissal in new[] { "enter", "escape", "close" })
        {
            OpenWithCancelFocus(app, "sessions.cleanup", "sessions.cleanup.preview", strings["settings.common.cancel"]);
            if (dismissal == "close")
            {
                AssertTabStaysInDialog(app, "sessions.cleanup.preview", "sessions.cleanup");
                app.Invoke("CloseButton");
            }
            else KeyInput.Press(app.Handle, dismissal == "enter" ? Enter : KeyInput.Escape);
            ClosedAtTrigger(app, "sessions.cleanup.preview", "sessions.cleanup");
            Assert.AreEqual(before, AppSession.Name(app.Find("sessions.status")), "dismissing does not apply cleanup");
            app.Find("sessions.row." + Removable);
            app.Find("sessions.row." + Observed);
        }
        // A new preview still proposes the identical removal after every cancellation path.
        OpenWithCancelFocus(app, "sessions.cleanup", "sessions.cleanup.preview", strings["settings.common.cancel"]);
        app.Find("sessions.cleanup.session." + Removable);
        Assert.IsNull(app.TryFind("sessions.cleanup.session." + Observed, TimeSpan.FromMilliseconds(200)), "the pinned Session remains protected");
        app.Invoke("CloseButton");
        ClosedAtTrigger(app, "sessions.cleanup.preview", "sessions.cleanup");
    }

    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void ExplicitCleanupPrimaryRemovesOnlyTheExactUnpinnedPreview(string language)
    {
        var strings = Catalogue.Load(language);
        using var app = PinnedSessions(language);
        OpenWithCancelFocus(app, "sessions.cleanup", "sessions.cleanup.preview", strings["settings.common.cancel"]);
        app.Find("sessions.cleanup.session." + Removable);
        Assert.IsNull(app.TryFind("sessions.cleanup.session." + Observed, TimeSpan.FromMilliseconds(200)));
        Assert.AreEqual(strings["windows.sessions.cleanup.confirm"], AppSession.Name(app.Find("PrimaryButton")));
        app.Invoke("PrimaryButton");
        app.WaitForName("sessions.status", n => n == strings.Format("windows.sessions.cleanup.done", ["1", strings.Format("windows.bytes", ["7013"])]));
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("sessions.row." + Removable, TimeSpan.FromMilliseconds(200)) is null, "only the reviewed unpinned Session leaves the catalog");
        app.Select("sessions.row." + Observed);
        Assert.AreEqual(strings["windows.sessions.pinnedYes"], app.WaitForName("sessions.detail.pinned", n => n == strings["windows.sessions.pinnedYes"]));
        // The explicit action consumed its preview; there is no second removal to submit.
        app.Invoke("sessions.cleanup");
        app.WaitForName("sessions.status", n => n == strings["windows.sessions.cleanup.nothing"]);
        Assert.IsNull(app.TryFind("sessions.cleanup.preview", TimeSpan.FromMilliseconds(200)));
        app.Find("sessions.row." + Observed);
    }

    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TracePurgeDefaultsToCancelAndExplicitPrimaryKeepsTheActiveEntry(string language)
    {
        var strings = Catalogue.Load(language);
        using var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", "jobs", "--language", language, "--page", "settings"]);
        app.Select("settings.tab.trace");
        var before = app.WaitForName("settings.trace.entries", n => n.Length > 0);
        var status = AppSession.Name(app.Find("settings.trace.status"));
        foreach (var dismissal in new[] { "enter", "escape", "close" })
        {
            OpenWithCancelFocus(app, "settings.trace.purge", "settings.trace.confirm", strings["settings.common.cancel"]);
            if (dismissal == "close")
            {
                AssertTabStaysInDialog(app, "settings.trace.confirm", "settings.trace.purge");
                app.Invoke("CloseButton");
            }
            else KeyInput.Press(app.Handle, dismissal == "enter" ? Enter : KeyInput.Escape);
            ClosedAtTrigger(app, "settings.trace.confirm", "settings.trace.purge");
            Assert.AreEqual(before, AppSession.Name(app.Find("settings.trace.entries")), "cancellation keeps the inactive derived entry");
            Assert.AreEqual(status, AppSession.Name(app.Find("settings.trace.status")), "no purge result is reported");
        }
        OpenWithCancelFocus(app, "settings.trace.purge", "settings.trace.confirm", strings["settings.common.cancel"]);
        app.Invoke("PrimaryButton");
        app.WaitForName("settings.trace.status", n => n == strings.Format("windows.settings.trace.purgeDone", ["1"]));
        app.WaitForName("settings.trace.entries", n => n == strings.Format("windows.settings.trace.entries", ["1", "1", "0"]));
        // A fresh confirmation reads the retained active-only inventory; nothing is deleted again.
        OpenWithCancelFocus(app, "settings.trace.purge", "settings.trace.confirm", strings["settings.common.cancel"]);
        app.Invoke("CloseButton");
        ClosedAtTrigger(app, "settings.trace.confirm", "settings.trace.purge");
        Assert.AreEqual(strings.Format("windows.settings.trace.entries", ["1", "1", "0"]), AppSession.Name(app.Find("settings.trace.entries")));
    }

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void CurrentPointerHasAKeyboardPathAndItsStalePictureCannotRepeatInput()
    {
        var strings = Catalogue.Load("en-US");
        var cache = Directory.CreateTempSubdirectory("arkdeck-pointer-keyboard-").FullName;
        using var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", "device-screen", "--language", "en-US", "--page", "device", "--cache-root", cache]);
        app.Invoke("device.screen.capture");
        app.WaitForName("device.screen.liveness", n => n == strings["windows.device.screen.current"]);
        app.Find("device.screen.pointer").Focus();
        Focused(app, "device.screen.pointer");
        KeyInput.Press(app.Handle, Right);
        app.WaitForName("device.screen.pointer.position", n => n == strings.Format("windows.device.screen.pointerPosition", ["205", "400"]));
        KeyInput.Press(app.Handle, Up);
        app.WaitForName("device.screen.pointer.position", n => n == strings.Format("windows.device.screen.pointerPosition", ["205", "395"]));
        KeyInput.Press(app.Handle, Enter);
        app.WaitForName("device.screen.status", n => n.StartsWith(strings["windows.device.screen.inputConfirmed"], StringComparison.Ordinal));
        app.WaitForName("device.screen.liveness", n => n == strings["device.stale.badge"]);
        var histories = app.Buttons().Count(b => b.Id.StartsWith("device.screen.log.open.", StringComparison.Ordinal));
        Assert.AreEqual(2, histories, "one capture and one confirmed input have distinct source Jobs");
        app.Find("device.screen.pointer").Focus();
        Focused(app, "device.screen.pointer");
        KeyInput.Press(app.Handle, Enter);
        app.WaitForName("device.screen.status", n => n.StartsWith(strings["device.stale.refused"], StringComparison.Ordinal));
        Assert.AreEqual(histories, app.Buttons().Count(b => b.Id.StartsWith("device.screen.log.open.", StringComparison.Ordinal)), "stale input creates no new source Job action");
    }

    private static AppSession PinnedSessions(string language)
    {
        var strings = Catalogue.Load(language);
        var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", "targets", "--language", language, "--page", "sessions"]);
        try
        {
            app.Select("sessions.row." + Observed);
            app.Invoke("sessions.pin");
            app.WaitForName("sessions.status", n => n == strings["windows.sessions.pinnedDone"]);
            app.Select("sessions.row." + Observed);
            app.WaitForName("sessions.detail.pinned", n => n == strings["windows.sessions.pinnedYes"]);
            return app;
        }
        catch { app.Dispose(); throw; }
    }

    private static void OpenWithCancelFocus(AppSession app, string trigger, string dialog, string cancelName)
    {
        app.Find(trigger).Focus();
        Focused(app, trigger);
        app.Invoke(trigger);
        app.Find(dialog);
        Assert.AreEqual(cancelName, AppSession.Name(app.Find("CloseButton")));
        Focused(app, "CloseButton");
    }

    private static void ClosedAtTrigger(AppSession app, string dialog, string trigger)
    {
        SemanticSnapshotTests.WaitUntil(() => app.TryFind(dialog, TimeSpan.FromMilliseconds(200)) is null, "the dialog closes without another key stroke");
        Focused(app, trigger);
    }

    private static void Focused(AppSession app, string id) =>
        SemanticSnapshotTests.WaitUntil(() => app.Find(id).Properties.HasKeyboardFocus.ValueOrDefault, id + " receives keyboard focus");

    private static void AssertTabStaysInDialog(AppSession app, string dialog, string trigger)
    {
        foreach (var backwards in new[] { false, true })
        {
            for (var i = 0; i < 4; i++)
            {
                var previous = FocusedInDialog(app, dialog).Properties.RuntimeId.Value;
                KeyInput.Press(app.Handle, KeyInput.Tab, shift: backwards);
                SemanticSnapshotTests.WaitUntil(() =>
                {
                    // Selectable preview text can be a native Tab stop too. It must remain
                    // inside this modal, rather than being forced into a two-button model.
                    var focused = app.Find(dialog).FindAllDescendants().Where(e => e.Properties.HasKeyboardFocus.ValueOrDefault).ToArray();
                    return focused.Length == 1 && !previous.SequenceEqual(focused[0].Properties.RuntimeId.Value);
                }, "Tab moves to another native element inside the confirmation");
                Assert.IsFalse(app.Find(trigger).Properties.HasKeyboardFocus.ValueOrDefault, "the background trigger cannot receive modal Tab focus");
            }
        }
    }

    private static AutomationElement FocusedInDialog(AppSession app, string dialog)
    {
        var focused = app.Find(dialog).FindAllDescendants().Where(e => e.Properties.HasKeyboardFocus.ValueOrDefault).ToArray();
        Assert.AreEqual(1, focused.Length, "exactly one native descendant of the confirmation has keyboard focus");
        return focused[0];
    }
}
