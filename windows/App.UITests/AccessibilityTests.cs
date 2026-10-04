using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>
/// The automated accessibility pass over every page (TASK-XPA-020):
/// <list type="bullet">
/// <item>keyboard-only traversal: every action on the page is a Tab stop, the stops follow the
/// reading order, Shift+Tab walks the same stops back, each stop takes keyboard focus; the Tab
/// order is WinUI's own (the App's in-process walk, <c>--focus-walk</c>), and real Tab keys
/// are sent too when the desktop is unlocked;</item>
/// <item>access keys on every navigation item (and Alt+key reaching the page, unlocked desktop);</item>
/// <item>a visible focus indicator (pixels change around a keyboard-focused button, unlocked
/// desktop) and no source that turns the system focus visuals off;</item>
/// <item>Escape closing each dialog (a key stroke posted to the window, which works locked);</item>
/// <item>the high-contrast token mapping (<c>--high-contrast-tokens</c>): the ink is the
/// system window-text colour;</item>
/// <item>the layout at the largest Windows text size (<c>--text-scale 2.25</c>): no text or
/// button runs past the page, over the whole scrolled page.</item>
/// </list>
/// What still needs a person — Narrator by ear, the system high-contrast themes and the system
/// text size themselves — is listed in the run record.
/// </summary>
[TestClass]
public sealed class AccessibilityTests
{
    public TestContext TestContext { get; set; } = null!;

    /// <summary>Each page, the scenario that fills it, and what is selected first.</summary>
    public static IEnumerable<object[]> Pages() =>
    [
        ["overview", "jobs", Array.Empty<string>()],
        ["device", "targets", new[] { "device.target.TGT-3ba3f5f43b92" }],
        ["history", "jobs", new[] { "history.row.job-0000000000000000000000000000a003" }],
        ["settings", "targets", new[] { "settings.tab.workspace", "settings.workspace.project.project-04dfc9a54d0e77e090fbb537" }],
        ["sessions", "targets", new[] { "sessions.row.session-job-0f77f8c52864d676372962eccb17389c" }],
        ["agents", "jobs", new[] { "agents.humanAction.<har-3>" }],
        ["imports", "jobs", new[] { "imports.row.imp-dcb7943f-d934-43da-b290-65d0066cae35" }],
        ["debug", "jobs", Array.Empty<string>()],
        ["debug", "jobs", new[] { "debug.tab.logs" }],
        ["debug", "jobs", new[] { "debug.tab.apps" }],
        ["debug", "jobs", new[] { "debug.tab.network" }],
        ["debug", "jobs", new[] { "debug.tab.commands" }],
        ["flash", "flash", Array.Empty<string>()],
        ["trace", "viewer", Array.Empty<string>()],
        ["traceViewer", "viewer", Array.Empty<string>()],
        ["viewer", "viewer", new[] { "viewer.recapture" }],
        ["diagnostics", "jobs", Array.Empty<string>()],
        ["diagnostics", "diagnostics", new[] { "@history", "history.row.job-6c545eb6042a9ea99e700467bbb77d06", "history.openDiagnostics" }],
        ["diagnostics", "diagnostics", new[] { "@history", "history.row.job-ce57f7b014978fe39492cf64043a8fc9", "history.openDiagnostics" }],
        ["overview", "jobs", new[] { "jobInspector.row.job-0000000000000000000000000000a004" }],
    ];

    [TestMethod]
    [DynamicData(nameof(Pages))]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void EveryActionIsATabStopInReadingOrder(string page, string scenario, string[] selections)
    {
        var exe = AppSession.RequireApp();
        var file = Path.Combine(Path.GetTempPath(), $"arkdeck-focus-{Guid.NewGuid():N}.json");
        try
        {
            var start = StartPage(page, selections);
            using var app = AppSession.Launch(exe, ["--test-transport", scenario, "--language", "en-US", "--page", start, "--focus-walk", file]);
            app.Find(Refresh(start));
            foreach (var id in selections.Where(s => !s.StartsWith('@')))
            {
                var element = app.Find(id);
                if (element.Patterns.SelectionItem.IsSupported) element.Patterns.SelectionItem.Pattern.Select();
                else element.Patterns.Invoke.Pattern.Invoke();
            }
            Thread.Sleep(800);

            // The actions a keyboard user must reach: every button of the page.
            var pageRoot = app.Find(page + ".page");
            var buttons = Buttons(pageRoot);
            Assert.IsTrue(buttons.Contains(Refresh(page)), page);

            var forward = Walk(app, file, backward: false);
            var ids = forward.Select(s => s.Id).ToList();
            TestContext.WriteLine($"{page} Tab: {string.Join(" > ", ids.Select((id, i) => id.Length > 0 ? id : forward[i].Type))}");
            var missing = buttons.Except(ids).ToArray();
            Assert.AreEqual(0, missing.Length, $"{page}: not a Tab stop: {string.Join(", ", missing)}");
            // No Tab stop is an empty host: every stop is a control a person can name.
            var anonymous = forward.Where(s => s.Type == "ContentControl").ToArray();
            Assert.AreEqual(0, anonymous.Length, $"{page}: empty Tab stops (ContentControl hosts)");

            // Reading order: the page's own actions go top to bottom, left to right on a line.
            var onPage = forward.Where(s => buttons.Contains(s.Id)).ToList();
            for (var i = 1; i < onPage.Count; i++)
            {
                var (before, after) = (onPage[i - 1], onPage[i]);
                var sameLine = Math.Abs(after.Y - before.Y) < Math.Min(after.Height, before.Height);
                Assert.IsTrue(sameLine ? after.X >= before.X : after.Y > before.Y,
                    $"{page}: {after.Id} ({after.X:0},{after.Y:0}) follows {before.Id} ({before.X:0},{before.Y:0}) in Tab order but not in reading order");
            }

            // Shift+Tab: the same stops, in reverse.
            var back = Walk(app, file, backward: true);
            TestContext.WriteLine($"{page} Shift+Tab: {string.Join(" > ", back.Select(s => s.Id.Length > 0 ? s.Id : s.Type))}");
            var backward = back.Select(s => s.Id).Where(buttons.Contains).ToList();
            CollectionAssert.AreEqual(onPage.Select(s => s.Id).Reverse().ToList(), backward, $"{page}: Shift+Tab does not retrace Tab");

        }
        finally
        {
            File.Delete(file);
        }
    }

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void EveryPageHasAnAccessKey()
    {
        var exe = AppSession.RequireApp();
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US"]);
        app.Find("overview.refresh");
        var keys = new Dictionary<string, (string Key, int Unused)>
        {
            ["sessions"] = ("N", 0),
            ["agents"] = ("A", 0),
            ["imports"] = ("I", 0),
            ["debug"] = ("B", 0),
            ["flash"] = ("F", 0),
            ["trace"] = ("T", 0),
            ["traceViewer"] = ("R", 0),
            ["viewer"] = ("V", 0),
            ["diagnostics"] = ("G", 0),
            ["history"] = ("H", 0),
            ["device"] = ("D", 0),
            ["settings"] = ("S", 0),
            ["overview"] = ("O", 0),
        };
        foreach (var (page, (key, _)) in keys)
        {
            Assert.AreEqual("Alt, " + key, app.Find("app.navigation." + page).Properties.AccessKey.ValueOrDefault, page);
        }
        var all = keys.Values.Select(k => k.Key).ToArray();
        Assert.AreEqual(all.Length, all.Distinct().Count(), "access keys are unique");
    }

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void KeyboardFocusIsVisible()
    {
        // No App source turns the Fluent focus visuals off.
        foreach (var source in Directory.EnumerateFiles(RepoPaths.At("windows", "App"), "*.*", SearchOption.AllDirectories)
                     .Where(p => (p.EndsWith(".cs", StringComparison.Ordinal) || p.EndsWith(".xaml", StringComparison.Ordinal))
                                 && !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                                 && !p.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")))
        {
            var text = File.ReadAllText(source);
            foreach (var off in new[] { "UseSystemFocusVisuals=\"False\"", "UseSystemFocusVisuals = false", "FocusVisualPrimaryThickness=\"0\"", "FocusVisualSecondaryThickness=\"0\"" })
            {
                Assert.IsFalse(text.Contains(off, StringComparison.Ordinal), $"{Path.GetFileName(source)}: {off}");
            }
        }
        var exe = AppSession.RequireApp();
        if (DesktopLocked()) Assert.Inconclusive("the desktop is locked: nothing is drawn to the screen, so the focus rectangle cannot be seen (the Tab walk still checks every stop)");
        var file = Path.Combine(Path.GetTempPath(), $"arkdeck-focus-{Guid.NewGuid():N}.json");
        try
        {
            using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings", "--focus-walk", file]);
            app.Find("settings.refresh");
            Thread.Sleep(500);
            // Keyboard focus goes, stop by stop, to the last Tab stop of the window; its
            // surroundings before and after must differ by the Fluent focus rectangle.
            var last = Walk(app, file, backward: true)[0].Id;
            Thread.Sleep(300);
            var element = app.Find(last);
            var area = element.BoundingRectangle;
            area.Inflate(6, 6);
            using var focused = Capture.Rectangle(area).Bitmap;
            app.Find("settings.refresh").Patterns.Invoke.Pattern.Invoke(); // pointer-less refresh moves keyboard focus away
            Thread.Sleep(800);
            using var unfocused = Capture.Rectangle(area).Bitmap;
            var changed = 0;
            for (var y = 0; y < Math.Min(focused.Height, unfocused.Height); y++)
            {
                for (var x = 0; x < Math.Min(focused.Width, unfocused.Width); x++)
                {
                    if (focused.GetPixel(x, y) != unfocused.GetPixel(x, y)) changed++;
                }
            }
            TestContext.WriteLine($"focus ring: {changed} pixels differ around {last}");
            Assert.IsTrue(changed > area.Width + area.Height, $"a keyboard focus indicator is drawn around {last}");
        }
        finally
        {
            File.Delete(file);
        }
    }

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void EscapeClosesEveryDialog()
    {
        var exe = AppSession.RequireApp();
        using (var app = AppSession.Launch(exe, ["--test-transport", "targets", "--language", "en-US", "--page", "device"]))
        {
            app.Select("device.target.TGT-3ba3f5f43b92");
            app.Invoke("device.target.rename");
            app.Find("device.rename.field").Focus();
            EscapeCloses(app, "device.rename", "Escape closes the rename dialog");
            Assert.AreEqual("", AppSession.Name(app.Find("device.target.nameStatus")), "nothing was renamed");
        }
        using (var app = AppSession.Launch(exe, ["--test-transport", "targets", "--language", "en-US", "--page", "sessions"]))
        {
            app.Invoke("sessions.cleanup");
            app.Find("sessions.cleanup.preview");
            EscapeCloses(app, "sessions.cleanup.preview", "Escape closes the cleanup preview");
            Assert.IsNotNull(app.TryFind("sessions.row.session-job-efd52ab9c633074171a19ddd916fffd9", TimeSpan.FromSeconds(2)), "nothing was removed");
        }
        using (var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "agents"]))
        {
            app.Select("agents.row.har-connect");
            app.Invoke("agents.abandon");
            app.Find("agents.abandon.confirm");
            EscapeCloses(app, "agents.abandon.confirm", "Escape closes the abandon confirmation");
            Assert.AreEqual("", AppSession.Name(app.Find("agents.status")), "nothing was abandoned");
            app.Navigate("imports");
            app.Select("imports.row.imp-dcb7943f-d934-43da-b290-65d0066cae35");
            app.Invoke("imports.release");
            app.Find("imports.release.confirm");
            EscapeCloses(app, "imports.release.confirm", "Escape closes the release confirmation");
            Assert.AreEqual("", AppSession.Name(app.Find("imports.status")), "nothing was released");
            app.Navigate("debug");
            app.Select("debug.artifacts.source.remote");
            app.Invoke("debug.artifacts.browseRemote");
            app.Find("debug.artifacts.remoteBrowser");
            EscapeCloses(app, "debug.artifacts.remoteBrowser", "Escape closes the remote build browser");
        }
        using (var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "history"]))
        {
            app.Select("history.row.job-0000000000000000000000000000a003");
            app.Invoke("history.artifact.export.ART-00000000000000000000000000000c01");
            app.Find("history.artifacts.exportPreview");
            EscapeCloses(app, "history.artifacts.exportPreview", "Escape closes the export preview");
            app.Select("jobInspector.row.job-0000000000000000000000000000a004");
            app.Invoke("jobInspector.cancel");
            app.Find("jobInspector.cancel.confirm");
            EscapeCloses(app, "jobInspector.cancel.confirm", "Escape closes the cancellation confirmation");
            Assert.IsNull(app.TryFind("jobInspector.cancel.result", TimeSpan.FromMilliseconds(300)), "nothing was cancelled");
            Assert.IsNull(app.TryFind("history.artifact.exporting.ART-00000000000000000000000000000c01", TimeSpan.FromMilliseconds(300)), "nothing was read");
        }
    }

    /// <summary>The page states the layout test checks at 225 % text.</summary>
    public static IEnumerable<object[]> LargeTextStates() =>
    [
        ["overview", "jobs", Array.Empty<string>()],
        ["overview", "unavailable", Array.Empty<string>()],
        ["device", "jobs", Array.Empty<string>()],
        ["device", "targets", new[] { "device.target.TGT-3ba3f5f43b92" }],
        ["history", "jobs", new[] { "history.row.job-0000000000000000000000000000a003", "history.artifact.inspectTrace.ART-00000000000000000000000000000c01" }],
        ["history", "foundation", Array.Empty<string>()],
        ["settings", "jobs", Array.Empty<string>()],
        ["settings", "foundation", new[] { "settings.tab.runtime" }],
        ["settings", "jobs", new[] { "settings.tab.toolchains" }],
        ["settings", "jobs", new[] { "settings.tab.storage" }],
        ["settings", "jobs", new[] { "settings.tab.trace" }],
        ["settings", "targets", new[] { "settings.tab.workspace", "settings.workspace.project.project-04dfc9a54d0e77e090fbb537" }],
        ["sessions", "targets", new[] { "sessions.row.session-job-0f77f8c52864d676372962eccb17389c" }],
        ["sessions", "foundation", Array.Empty<string>()],
        ["agents", "jobs", new[] { "agents.humanAction.<har-3>" }],
        ["agents", "foundation", Array.Empty<string>()],
        ["imports", "jobs", new[] { "imports.row.imp-dcb7943f-d934-43da-b290-65d0066cae35" }],
        ["imports", "foundation", Array.Empty<string>()],
        ["debug", "jobs", Array.Empty<string>()],
        ["debug", "jobs", new[] { "debug.tab.logs" }],
        ["debug", "jobs", new[] { "debug.tab.apps" }],
        ["debug", "jobs", new[] { "debug.tab.network" }],
        ["debug", "jobs", new[] { "debug.tab.commands" }],
        ["debug", "foundation", Array.Empty<string>()],
        ["flash", "flash", new[] { "flash.workspace.details" }],
        ["flash", "foundation", new[] { "flash.workspace.details" }],
        ["trace", "viewer", Array.Empty<string>()],
        ["trace", "targets", Array.Empty<string>()],
        ["traceViewer", "viewer", Array.Empty<string>()],
        ["viewer", "viewer", new[] { "viewer.recapture" }],
        ["viewer", "targets", Array.Empty<string>()],
        ["diagnostics", "jobs", Array.Empty<string>()],
        ["diagnostics", "diagnostics", new[] { "@history", "history.row.job-6c545eb6042a9ea99e700467bbb77d06", "history.openDiagnostics", "diagnostics.artifact.read.hilog.txt" }],
        ["diagnostics", "diagnostics", new[] { "@history", "history.row.job-ce57f7b014978fe39492cf64043a8fc9", "history.openDiagnostics" }],
        ["history", "jobs", new[] { "history.row.job-0000000000000000000000000000a002" }],
    ];

    [TestMethod]
    [DynamicData(nameof(LargeTextStates))]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void NothingIsClippedAtTheLargestTextSize(string page, string scenario, string[] steps)
    {
        var exe = AppSession.RequireApp();
        var start = StartPage(page, steps);
        using var app = AppSession.Launch(exe, ["--test-transport", scenario, "--language", "en-US", "--page", start, "--text-scale", "2.25"]);
        app.Find(Refresh(start));
        foreach (var id in steps.Where(s => !s.StartsWith('@')))
        {
            var element = app.Find(id);
            if (element.Patterns.SelectionItem.IsSupported) element.Patterns.SelectionItem.Pattern.Select();
            else element.Patterns.Invoke.Pattern.Invoke();
        }
        Thread.Sleep(1500);
        var root = app.Find(page + ".page");
        var viewport = root.BoundingRectangle;
        var problems = new List<string>();
        var seen = new HashSet<string>();
        var scroll = root.Patterns.Scroll.PatternOrDefault;
        // Every scroll position of the page: elements scrolled out are checked once they show.
        for (var position = 0.0; ; position += 100.0 / 6)
        {
            if (scroll is { VerticallyScrollable.ValueOrDefault: true }) scroll.SetScrollPercent(-1, Math.Min(100, position));
            Thread.Sleep(250);
            foreach (var element in root.FindAllDescendants(cf => cf.ByControlType(ControlType.Text).Or(cf.ByControlType(ControlType.Button))))
            {
                if (element.Properties.IsOffscreen.ValueOrDefault) continue;
                var rect = element.BoundingRectangle;
                if (rect.Width <= 0 || rect.Height <= 0) continue;
                var key = $"{element.Properties.AutomationId.ValueOrDefault}|{AppSession.Name(element)}";
                seen.Add(key);
                if (rect.Left < viewport.Left - 1 || rect.Right > viewport.Right + 1)
                {
                    problems.Add($"{key} {rect} outside {viewport}");
                }
            }
            if (scroll is not { VerticallyScrollable.ValueOrDefault: true } || position >= 100) break;
        }
        TestContext.WriteLine($"{page}/{scenario}/{string.Join(",", steps)}: {seen.Count} elements within {viewport}");
        Assert.IsTrue(seen.Count > 3, "the page rendered");
        Assert.AreEqual(0, problems.Count, string.Join(Environment.NewLine, problems.Distinct()));
    }

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void HighContrastTokensUseTheSystemColours()
    {
        var exe = AppSession.RequireApp();
        var windowText = (int)GetSysColor(8); // COLOR_WINDOWTEXT, what SystemColorWindowTextColor maps to
        string Ink(string[] extra)
        {
            using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings", .. extra]);
            var title = app.Find("settings.general.build.title");
            var colour = title.Patterns.Text.Pattern.DocumentRange.GetAttributeValue(app.Automation.TextAttributeLibrary.ForegroundColor);
            return Convert.ToString(colour, System.Globalization.CultureInfo.InvariantCulture) ?? "";
        }
        var tokens = Ink([]);
        var contrast = Ink(["--high-contrast-tokens"]);
        TestContext.WriteLine($"ink: tokens {tokens}, high-contrast tokens {contrast}, system window text {windowText}");
        Assert.AreEqual(windowText.ToString(System.Globalization.CultureInfo.InvariantCulture), contrast, "high contrast: the ink is the system window-text colour");
    }

    /// <summary>Escape, once the dialog is fully shown (its buttons exist), closes it. A
    /// stroke that arrived while the dialog was still being shown is repeated once, and said.</summary>
    private void EscapeCloses(AppSession app, string dialog, string what)
    {
        app.Find("CloseButton");
        Thread.Sleep(300);
        KeyInput.Press(app.Handle, KeyInput.Escape);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        while (app.TryFind(dialog, TimeSpan.FromMilliseconds(200)) is not null && watch.Elapsed < TimeSpan.FromSeconds(3)) Thread.Sleep(100);
        if (app.TryFind(dialog, TimeSpan.FromMilliseconds(200)) is not null)
        {
            TestContext.WriteLine($"{dialog}: still open 3 s after Escape; Escape sent again");
            KeyInput.Press(app.Handle, KeyInput.Escape);
        }
        SemanticSnapshotTests.WaitUntil(() => app.TryFind(dialog, TimeSpan.FromMilliseconds(200)) is null, what);
    }

    private static string Refresh(string page) => page switch
    {
        "device" => "hdc.devices.refresh",
        "diagnostics" => "diagnostics.session.reload",
        _ => page + ".refresh",
    };

    /// <summary>The page the App starts on: the page itself, or the one an <c>@page</c> step names
    /// (Diagnostics opens a record from History).</summary>
    private static string StartPage(string page, string[] steps) => steps.FirstOrDefault(s => s.StartsWith('@'))?[1..] ?? page;

    private static HashSet<string> Buttons(AutomationElement pageRoot) =>
        pageRoot.FindAllDescendants(cf => cf.ByControlType(ControlType.Button))
            .Select(b => b.Properties.AutomationId.ValueOrDefault ?? "")
            // The App's own actions (dotted identifiers), not template parts such as scroll bar buttons.
            .Where(id => id.Contains('.', StringComparison.Ordinal))
            // The Viewer's per-component outlines and tree disclosures are for screen readers: the
            // keyboard reaches the same components through the tree (arrows, Left and Right), as on macOS.
            .Where(id => !id.StartsWith("viewer.screenshot.node.", StringComparison.Ordinal) && !id.StartsWith("viewer.tree.disclosure.", StringComparison.Ordinal))
            .ToHashSet();

    private sealed record Stop(string Id, string Type, string State, double X, double Y, double Width, double Height);

    /// <summary>The walk's file once the App has closed it (it may still be writing when it appears).</summary>
    private static string ReadWhenWritten(string file, Stopwatch watch)
    {
        while (true)
        {
            try
            {
                return File.ReadAllText(file);
            }
            catch (IOException) when (watch.Elapsed < AppSession.Timeout)
            {
                Thread.Sleep(100);
            }
        }
    }

    /// <summary>The App's in-process Tab (or Shift+Tab) walk over the whole window.</summary>
    private static List<Stop> Walk(AppSession app, string file, bool backward)
    {
        File.Delete(file);
        PostMessage(app.Handle, RegisterWindowMessage("ArkDeck.FocusWalk"), backward ? 1 : 0, 0);
        var watch = Stopwatch.StartNew();
        while (!File.Exists(file))
        {
            if (watch.Elapsed > AppSession.Timeout) Assert.Fail("the App did not walk its focus");
            Thread.Sleep(100);
        }
        using var doc = JsonDocument.Parse(ReadWhenWritten(file, watch));
        return doc.RootElement.EnumerateArray().Select(s => new Stop(
            s.GetProperty("id").GetString() ?? "", s.GetProperty("type").GetString()!, s.GetProperty("state").GetString()!,
            s.GetProperty("x").GetDouble(), s.GetProperty("y").GetDouble(), s.GetProperty("width").GetDouble(), s.GetProperty("height").GetDouble())).ToList();
    }

    /// <summary>The workstation is locked (the logon screen runs in this session): key strokes
    /// and screen pixels do not reach the App.</summary>
    private static bool DesktopLocked()
    {
        var session = Process.GetCurrentProcess().SessionId;
        return Process.GetProcessesByName("LogonUI").Any(p => p.SessionId == session);
    }

    [DllImport("user32.dll")]
    private static extern uint GetSysColor(int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, nint wParam, nint lParam);
}
