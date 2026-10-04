using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>
/// The UI dump Viewer through UIA patterns only (no synthetic input). Over the scripted
/// <c>viewer</c> daemon (the recorded ui-dump-inspect oracle's capture) the Connected device's
/// view is captured; the tree, the screenshot's component outlines, the search, the property
/// tabs and the footer follow the macOS Viewer. Over the <c>targets</c> daemon (the Windows
/// daemon over a development root, no HDC) the device is not Connected, and Capture says so.
/// </summary>
[TestClass]
public sealed class ViewerFlowTests
{
    public TestContext TestContext { get; set; } = null!;

    private AutomationElement Row(AppSession app, string name)
    {
        AutomationElement? row = null;
        var seen = "";
        try
        {
            SemanticSnapshotTests.WaitUntil(() =>
            {
                var rows = app.Find("viewer.tree.scroll").FindAllDescendants(cf => cf.ByControlType(ControlType.ListItem));
                seen = string.Join(" | ", rows.Select(r => AppSession.Name(r) + "=" + r.Properties.AutomationId.ValueOrDefault));
                return (row = rows.FirstOrDefault(i => AppSession.Name(i) is var n && (n == name || n.StartsWith(name + " #", StringComparison.Ordinal)))) is not null;
            }, $"the tree row {name}");
        }
        finally
        {
            TestContext.WriteLine("tree rows: " + seen);
        }
        return row!;
    }

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void AViewIsCapturedAndInspected()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "viewer", "--language", "en-US", "--page", "viewer"]);
        Assert.AreEqual(strings["viewer.empty.explain"], app.WaitForName("viewer.empty.message", n => n.Length > 0));
        Assert.AreEqual(strings["viewer.toolbar.capture"], AppSession.Name(app.Find("viewer.recapture")));
        app.Invoke("viewer.recapture");

        var footer = app.WaitForName("viewer.footer", n => n.Length > 0);
        TestContext.WriteLine("footer: " + footer);
        StringAssert.StartsWith(footer, strings.Format("viewer.footer.nodes", ["9"]).Split(' ')[0]);
        StringAssert.Contains(footer, " · submit ");
        Assert.AreEqual(strings["viewer.toolbar.recapture"], AppSession.Name(app.Find("viewer.recapture")));
        app.Find("viewer.screenshot.hitTest");

        // The tree: the focused root is selected and expanded; its List is expanded by its disclosure.
        var disclosure = Row(app, "List").FindFirstDescendant(cf => cf.ByControlType(ControlType.Button))!;
        StringAssert.StartsWith(disclosure.Properties.AutomationId.Value, "viewer.tree.disclosure.");
        Assert.AreEqual(strings["viewer.tree.expand"], AppSession.Name(disclosure));
        disclosure.Patterns.Invoke.Pattern.Invoke();
        var list = Row(app, "Row first");
        list.Patterns.SelectionItem.Pattern.Select();
        Assert.AreEqual("Row", app.WaitForName("viewer.properties.type", n => n == "Row"));
        Assert.AreEqual("first", AppSession.Name(app.Find("viewer.field.text")));
        app.Find("viewer.inspector.tab.layout").Patterns.Toggle.Pattern.Toggle();
        Assert.AreEqual("x 0, y 80, 400 × 60", app.WaitForName("viewer.field.bounds", n => n.Length > 0));
        app.Find("viewer.inspector.tab.rawDump").Patterns.Toggle.Pattern.Toggle();
        StringAssert.Contains(app.WaitForName("viewer.rawDump", n => n.Length > 0), "\"text\"");
        app.Find("viewer.inspector.tab.advancedDump").Patterns.Toggle.Pattern.Toggle();
        Assert.AreEqual(strings["windows.viewer.advancedDump.noIds"], app.WaitForName("viewer.advancedDump", n => n.Length > 0));

        // The search keeps the matches and their ancestors, and steps between them.
        app.Find("viewer.inspector.tab.properties").Patterns.Toggle.Pattern.Toggle();
        app.Find("viewer.search").Patterns.Value.Pattern.SetValue("row");
        Assert.AreEqual("1 / 2", app.WaitForName("viewer.search.matchCount", n => n.EndsWith("/ 2", StringComparison.Ordinal)) .Split(':')[^1].Trim());
        app.Invoke("viewer.search.next");
        app.WaitForName("viewer.search.matchCount", n => n.EndsWith("2 / 2", StringComparison.Ordinal));
        Assert.AreEqual("second", AppSession.Name(app.Find("viewer.field.text")));
        app.Find("viewer.search").Patterns.Value.Pattern.SetValue("no such component");
        Assert.AreEqual(strings["viewer.tree.noMatches"], app.WaitForName("viewer.tree.noMatches", n => n.Length > 0));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void CaptureSaysWhyTheDeviceIsNotConnected()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "targets", "--language", "en-US", "--page", "viewer"]);
        Assert.AreEqual(strings["viewer.empty.selectTarget"], app.WaitForName("viewer.empty.message", n => n.Length > 0));
        app.Find("viewer.target").Patterns.ExpandCollapse.Pattern.Expand();
        var target = app.Find("viewer.target.TGT-3ba3f5f43b92");
        StringAssert.EndsWith(AppSession.Name(target), "· Could not read current device state: hdc.notConfigured");
        target.Patterns.SelectionItem.Pattern.Select();
        var blocked = strings.Format("viewer.empty.targetBlocked", ["TGT-3ba3f5f43b92", "Could not read current device state: hdc.notConfigured"]);
        Assert.AreEqual(blocked, app.WaitForName("viewer.empty.message", n => n == blocked));
        app.Invoke("viewer.recapture");
        Assert.AreEqual(blocked, app.WaitForName("viewer.captureFailure", n => n.Length > 0));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
