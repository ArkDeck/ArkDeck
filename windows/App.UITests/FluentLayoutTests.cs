using System.Runtime.InteropServices;
using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>Observable layout contracts of every Windows page, on the native WinUI window.</summary>
[TestClass]
public sealed class FluentLayoutTests
{
    public TestContext TestContext { get; set; } = null!;
    private readonly string _snapshotFile = Path.Combine(Path.GetTempPath(), $"arkdeck-render-{Guid.NewGuid():N}.png");
    private string _theme = "light";

    private static string Refresh(string page) => page switch
    {
        "device" => "hdc.devices.refresh",
        "diagnostics" => "diagnostics.session.reload",
        _ => page + ".refresh",
    };

    private static IEnumerable<object[]> PageCases() =>
    [
        ["overview", "jobs", "overview.record.device.label"],
        ["device", "targets", "device.targets.title"],
        ["history", "jobs", "history.readOnlyNote"],
        ["sessions", "targets", "sessions.list"],
        ["agents", "jobs", "agents.executions.title"],
        ["imports", "jobs", "imports.list.title"],
        ["debug", "jobs", "debug.tabs"],
        ["flash", "flash", "flash.workspace.currentDevice"],
        ["trace", "viewer", "trace.capture.title"],
        ["traceViewer", "viewer", "trace.viewer.recent.title"],
        ["viewer", "viewer", "viewer.empty.title"],
        ["diagnostics", "jobs", "diagnostics.session.empty"],
        ["settings", "jobs", "settings.general.build.title"],
    ];

    public static IEnumerable<object[]> Pages()
    {
        foreach (var page in PageCases())
            foreach (var theme in new[] { "light", "dark" }) yield return [.. page, theme];
    }

    [TestMethod]
    [DynamicData(nameof(Pages))]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void EveryPageFitsAndKeepsItsHeaderWhenScrolled(string page, string scenario, string ready, string theme)
    {
        _theme = theme;
        using var app = AppSession.Launch(AppSession.RequireApp(),
            ["--test-transport", scenario, "--language", "zh-Hans", "--page", page,
                "--cache-root", Directory.CreateTempSubdirectory("arkdeck-layout-cache-").FullName,
                "--render-snapshot", _snapshotFile, "--test-theme", theme]);
        app.Find(ready);
        foreach (var width in new[] { 1280, 720 })
        {
            Resize(app, width);
            var viewport = app.Find(page + ".page");
            var title = app.Find(page + ".title");
            var refresh = app.Find(Refresh(page));
            var titleBounds = title.BoundingRectangle;
            var refreshBounds = refresh.BoundingRectangle;
            var window = app.Window.BoundingRectangle;
            Assert.IsTrue(titleBounds.Width > 0 && titleBounds.Left >= window.Left && titleBounds.Right <= window.Right, page + " title fits");
            Assert.IsTrue(refreshBounds.Left >= titleBounds.Right && refreshBounds.Right <= window.Right, page + " refresh fits beside title");
            var scroll = viewport.Patterns.Scroll.PatternOrDefault;
            for (var position = 0; position <= 100; position += 50)
            {
                if (scroll is { VerticallyScrollable.ValueOrDefault: true }) scroll.SetScrollPercent(-1, position);
                var bounds = viewport.BoundingRectangle;
                foreach (var element in viewport.FindAllDescendants(cf => cf.ByControlType(ControlType.Text).Or(cf.ByControlType(ControlType.Button))))
                {
                    if (element.Properties.IsOffscreen.ValueOrDefault) continue;
                    var rect = element.BoundingRectangle;
                    if (rect.Width <= 0 || rect.Height <= 0) continue;
                    Assert.IsTrue(rect.Left >= bounds.Left - 1 && rect.Right <= bounds.Right + 1,
                        $"{page}/{width}: {element.Properties.AutomationId.ValueOrDefault} {rect} outside {bounds}");
                }
                Assert.AreEqual(titleBounds, title.BoundingRectangle, page + " title stays pinned");
                Assert.AreEqual(refreshBounds, refresh.BoundingRectangle, page + " refresh stays pinned");
            }
            if (scroll is { VerticallyScrollable.ValueOrDefault: true }) scroll.SetScrollPercent(-1, 0);
            Screenshot(app, $"{page}-{width}");
        }
    }

    public static IEnumerable<object[]> Readers()
    {
        object[][] cases =
        [
            ["sessions", "targets", "sessions.row.session-job-0f77f8c52864d676372962eccb17389c", "sessions.list", "sessions.detail.title"],
            ["imports", "jobs", "imports.row.imp-dcb7943f-d934-43da-b290-65d0066cae35", "imports.list", "imports.detail.title"],
            ["history", "jobs", "history.row.job-0000000000000000000000000000a003", "history.table", "history.detail.title"],
            ["device", "targets", "device.target.TGT-3ba3f5f43b92", "device.targets.list", "device.target.detail.title"],
        ];
        foreach (var record in cases)
            foreach (var theme in new[] { "light", "dark" }) yield return [.. record, theme];
    }

    [TestMethod]
    [DynamicData(nameof(Readers))]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void ReadersReflowWithoutLosingTheSelectedRecord(string page, string scenario, string selection, string listId, string detailId, string theme)
    {
        _theme = theme;
        using var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", scenario, "--language", "zh-Hans", "--page", page,
            "--render-snapshot", _snapshotFile, "--test-theme", theme]);
        app.Select(selection);
        var name = AppSession.Name(app.Find(detailId));
        Resize(app, 1280);
        RevealReader(app, page, listId, detailId);
        var list = app.Find(listId).BoundingRectangle;
        var detail = app.Find(detailId).BoundingRectangle;
        Screenshot(app, page + "-selected-wide");
        Assert.IsTrue(detail.Left > list.Left + list.Width / 2, $"{page} reader is beside its list: {list}, {detail}");
        Resize(app, 720);
        RevealReader(app, page, listId, detailId);
        list = app.Find(listId).BoundingRectangle;
        detail = app.Find(detailId).BoundingRectangle;
        Assert.IsTrue(detail.Top >= list.Bottom, $"{page} reader follows its list in a narrow window: {list}, {detail}");
        Assert.AreEqual(name, AppSession.Name(app.Find(detailId)), page + " selection survives reflow");
        Screenshot(app, page + "-selected-narrow");
    }

    private static void RevealReader(AppSession app, string page, string listId, string detailId)
    {
        // The Device reader follows its screen workspace. Offscreen WinUI text peers have
        // empty rectangles, so make the list and detail heading visible before comparing them.
        var scroll = app.Find(page + ".page").Patterns.Scroll.PatternOrDefault;
        for (var position = 0; position <= 100; position += 5)
        {
            if (scroll is { VerticallyScrollable.ValueOrDefault: true }) scroll.SetScrollPercent(-1, position);
            if (app.Find(listId).BoundingRectangle.Width > 0 && app.Find(detailId).BoundingRectangle.Width > 0) return;
        }
        Assert.Fail(page + " list and reader heading could not be brought into view together");
    }

    [TestMethod]
    [DataRow("light")]
    [DataRow("dark")]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void CapturedViewerPanesReflowTogether(string theme)
    {
        _theme = theme;
        using var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", "viewer", "--language", "zh-Hans", "--page", "viewer",
            "--render-snapshot", _snapshotFile, "--test-theme", theme]);
        app.Invoke("viewer.recapture");
        app.Find("viewer.pane.screenshot");
        Resize(app, 1280);
        SemanticSnapshotTests.WaitUntil(() => app.Find("viewer.pane.tree").BoundingRectangle.Left
            > app.Find("viewer.pane.screenshot").BoundingRectangle.Left, "viewer panes placed beside each other");
        Assert.IsTrue(app.Find("viewer.properties.type").BoundingRectangle.Left > app.Find("viewer.pane.tree").BoundingRectangle.Right,
            "the properties pane follows the component tree horizontally");
        Screenshot(app, "viewer-captured-wide");
        Resize(app, 720);
        var scroll = app.Find("viewer.page").Patterns.Scroll.Pattern;
        scroll.SetScrollPercent(-1, 0);
        Screenshot(app, "viewer-captured-narrow");
        var screenshot = app.Find("viewer.pane.screenshot").BoundingRectangle;
        var treePosition = RevealHeading(app, "viewer.pane.tree", scroll, 0);
        var tree = app.Find("viewer.pane.tree").BoundingRectangle;
        Assert.IsTrue(treePosition > 0, "the component tree is reached by scrolling after the screenshot");
        Assert.AreEqual(screenshot.Left, tree.Left, 2, "the component tree uses the same narrow column");
        Screenshot(app, "viewer-tree-narrow");
        var propertiesPosition = RevealHeading(app, "viewer.properties.type", scroll, treePosition);
        Assert.IsTrue(propertiesPosition >= treePosition, "the properties pane is reached after the component tree");
        Assert.AreEqual(screenshot.Left, app.Find("viewer.properties.type").BoundingRectangle.Left, 2,
            "the properties pane uses the same narrow column");
        Screenshot(app, "viewer-properties-narrow");
    }

    private static int RevealHeading(AppSession app, string id, FlaUI.Core.Patterns.IScrollPattern scroll, int start)
    {
        for (var position = start; position <= 100; position += 5)
        {
            scroll.SetScrollPercent(-1, position);
            if (app.Find(id).BoundingRectangle.Width > 0) return position;
        }
        Assert.Fail(id + " was not reachable by scrolling");
        return -1;
    }

    public static IEnumerable<object[]> SettingsCategories()
    {
        object[][] cases =
        [
            ["general", "settings.general.build.title"],
            ["runtime", "settings.runtime.identity.title"],
            ["toolchains", "settings.toolchains.hdc.title"],
            ["remoteSources", "settings.remoteSources.title"],
            ["storage", "settings.storage.runtimeUsage.title"],
            ["trace", "settings.trace.cache.title"],
            ["updates", "update.title"],
            ["diagnostics", "settings.diagnostics.defaultScope.title"],
            ["workspace", "settings.workspace.projects.title"],
        ];
        foreach (var category in cases)
            foreach (var theme in new[] { "light", "dark" }) yield return [.. category, theme];
    }

    [TestMethod]
    [DynamicData(nameof(SettingsCategories))]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void EverySettingsCategoryUsesTheSameLayout(string category, string ready, string theme)
    {
        _theme = theme;
        using var app = AppSession.Launch(AppSession.RequireApp(), ["--test-transport", "jobs", "--language", "zh-Hans", "--page", "settings",
            "--render-snapshot", _snapshotFile, "--test-theme", theme]);
        app.Select("settings.tab." + category);
        app.Find(ready);
        foreach (var width in new[] { 1280, 720 })
        {
            Resize(app, width);
            Assert.IsTrue(app.Find("settings.tab." + category).Patterns.SelectionItem.Pattern.IsSelected.Value);
            if (width == 720)
            {
                var scale = Math.Max(96, GetDpiForWindow(app.Handle)) / 96.0;
                SemanticSnapshotTests.WaitUntil(() => app.Find("settings.tabs").BoundingRectangle.Height <= 3 * 44 * scale + 4,
                    "the settings categories wrap into three compact rows");
            }
            Screenshot(app, "settings-" + category + "-" + width);
        }
    }

    private static void Resize(AppSession app, double width)
    {
        var scale = Math.Max(96, GetDpiForWindow(app.Handle)) / 96.0;
        app.Window.Patterns.Transform.Pattern.Resize(width * scale, 850 * scale);
        SemanticSnapshotTests.WaitUntil(() => Math.Abs(app.Window.BoundingRectangle.Width - width * scale) <= 2, "window resized");
        DwmFlush();
    }

    private void Screenshot(AppSession app, string name)
    {
        if (Environment.GetEnvironmentVariable("ARKDECK_UI_SCREENSHOT_DIR") is not { Length: > 0 } directory) return;
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, name + "-" + _theme + ".png");
        File.Delete(_snapshotFile);
        File.Delete(_snapshotFile + ".error");
        PostMessage(app.Handle, RegisterWindowMessage("ArkDeck.RenderSnapshot"), 0, 0);
        SemanticSnapshotTests.WaitUntil(() => File.Exists(_snapshotFile) || File.Exists(_snapshotFile + ".error"), "XAML snapshot rendered");
        Assert.IsFalse(File.Exists(_snapshotFile + ".error"), File.Exists(_snapshotFile + ".error") ? File.ReadAllText(_snapshotFile + ".error") : "");
        File.Copy(_snapshotFile, path, overwrite: true);
        TestContext.AddResultFile(path);
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    [DllImport("dwmapi.dll")]
    private static extern int DwmFlush();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);
}
