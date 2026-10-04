using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>
/// XPA-AC-8 on Windows: each page's UIA tree, in each catalogue language, matches the
/// semantic snapshot of spec/ui-semantics/surfaces.json (identifier, role, accessible name,
/// live setting); no button anywhere is disabled; state changes reach a live region. The
/// daemon states come from the scripted test transport (<c>--test-transport</c>), which the
/// window labels as such.
/// </summary>
[TestClass]
public sealed class SemanticSnapshotTests
{
    public TestContext TestContext { get; set; } = null!;

    /// <summary>Every scenario some snapshot names (so none goes unchecked), in each language.</summary>
    public static IEnumerable<object[]> Scenarios()
    {
        using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "ui-semantics", "surfaces.json")));
        var scenarios = doc.RootElement.GetProperty("snapshots").EnumerateArray().Select(s => s.GetProperty("scenario").GetString()!).Distinct().ToArray();
        return from scenario in scenarios
               from language in new[] { "en-US", "zh-Hans" }
               select new object[] { scenario, language };
    }

    [TestMethod]
    [DynamicData(nameof(Scenarios))]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void PagesMatchTheirSemanticSnapshots(string scenario, string language)
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load(language);
        var snapshots = SurfaceSpec.Load(strings).Where(s => s.Scenario == scenario).ToArray();
        Assert.IsTrue(snapshots.Length > 0, scenario);
        using var app = AppSession.Launch(exe, ["--test-transport", scenario, "--language", language]);
        app.Find("app.testTransport");
        var actual = new List<object>();
        var problems = new List<string>();
        foreach (var snapshot in snapshots)
        {
            app.Navigate(snapshot.Page);
            foreach (var step in snapshot.Steps)
            {
                if (step.Action == "select") app.Select(step.AutomationId);
                else app.Invoke(step.AutomationId);
            }
            foreach (var expected in snapshot.Elements)
            {
                var element = app.TryFind(expected.AutomationId, AppSession.Timeout);
                if (element is null)
                {
                    problems.Add($"{snapshot.Id}: missing {expected.AutomationId}");
                    continue;
                }
                var name = WaitForExpectedName(app, expected);
                var role = element.Properties.ControlType.ValueOrDefault.ToString();
                var live = element.Properties.LiveSetting.IsSupported ? element.Properties.LiveSetting.ValueOrDefault.ToString() : "Off";
                actual.Add(new { snapshot = snapshot.Id, automationId = expected.AutomationId, origin = expected.Origin, role, name, live, enabled = element.Properties.IsEnabled.ValueOrDefault });
                if (role != SurfaceSpec.Roles[expected.Role]) problems.Add($"{snapshot.Id}: {expected.AutomationId} role {role}, expected {SurfaceSpec.Roles[expected.Role]}");
                if (!(expected.Prefix ? name.StartsWith(expected.Name, StringComparison.Ordinal) : name == expected.Name))
                {
                    problems.Add($"{snapshot.Id}: {expected.AutomationId} name \"{name}\", expected {(expected.Prefix ? "prefix " : "")}\"{expected.Name}\"");
                }
                if (expected.Live is { } setting && !string.Equals(live, setting, StringComparison.OrdinalIgnoreCase))
                {
                    problems.Add($"{snapshot.Id}: {expected.AutomationId} live setting {live}, expected {setting}");
                }
            }
            foreach (var button in app.Buttons().Where(b => !b.Enabled))
            {
                problems.Add($"{snapshot.Id}: disabled button {button.Id} \"{button.Name}\" (XPA-AC-8)");
            }
        }
        var text = JsonSerializer.Serialize(actual, new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        TestContext.WriteLine(text);
        if (Environment.GetEnvironmentVariable("ARKDECK_UI_SNAPSHOT_DIR") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, $"{scenario}.{language}.json"), text);
        }
        Assert.AreEqual(0, problems.Count, string.Join(Environment.NewLine, problems));
    }

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void TheRecoveryBannerIsAnnouncedWhenTheDaemonGoesAway()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "outage", "--language", "en-US"]);
        app.WaitForName("overview.doctor.overall", n => n.Length > 0);
        Assert.IsNull(app.TryFind("app.recovery.retry", TimeSpan.FromMilliseconds(500)), "no banner while the daemon answers");
        var events = new List<string>();
        using (app.Window.RegisterAutomationEvent(app.Automation.EventLibrary.Element.LiveRegionChangedEvent, TreeScope.Subtree,
                   (element, _) => { lock (events) events.Add(element.Properties.AutomationId.ValueOrDefault ?? ""); }))
        {
            app.Invoke("overview.refresh");
            var banner = app.Find("app.recovery.daemonUnavailable");
            Assert.AreEqual(strings["windows.recovery.title"], app.WaitForName("app.recovery.daemonUnavailable", n => n.Length > 0));
            Assert.AreEqual(LiveSetting.Assertive, banner.Properties.LiveSetting.ValueOrDefault);
            app.WaitForName("overview.doctor.unavailable.reason", n => n.StartsWith("unavailable(daemonUnavailable)", StringComparison.Ordinal));
            Thread.Sleep(500);
        }
        TestContext.WriteLine("live region events: " + string.Join(", ", events));
        lock (events) CollectionAssert.Contains(events, "app.recovery.daemonUnavailable");
    }

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void TheRecoveryBannerGoesAwayAfterRetry()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "recovers", "--language", "en-US"]);
        Assert.AreEqual(strings["windows.recovery.title"], app.WaitForName("app.recovery.daemonUnavailable", n => n.Length > 0));
        app.Invoke("app.recovery.retry");
        // The daemon answers now: the page shows the foundation's refusal and the banner closes.
        app.WaitForName("overview.record.recent.unavailable.reason", n => n.StartsWith("unavailable(rejected)", StringComparison.Ordinal));
        WaitUntil(() => app.TryFind("app.recovery.retry", TimeSpan.FromMilliseconds(200)) is null, "the banner closes");
    }

    [TestMethod]
    [Timeout(120_000, CooperativeCancellation = true)]
    public void JobStateChangesReachTheLiveRegion()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US"]);
        var row = app.Find("jobInspector.row.job-0000000000000000000000000000a001");
        var announced = new List<string>();
        using (app.Window.RegisterAutomationEvent(app.Automation.EventLibrary.Element.LiveRegionChangedEvent, TreeScope.Subtree,
                   (element, _) =>
                   {
                       if (element.Properties.AutomationId.ValueOrDefault == "jobInspector.state")
                       {
                           lock (announced) announced.Add(AppSession.Name(element));
                       }
                   }))
        {
            row.Patterns.SelectionItem.Pattern.Select();
            var state = app.Find("jobInspector.state");
            Assert.AreEqual(LiveSetting.Assertive, state.Properties.LiveSetting.ValueOrDefault);
            // The scripted Job advances on each job.status read (the inspector re-reads every
            // 2 s while the Job is active): running → waiting for device → running → succeeded.
            app.WaitForName("jobInspector.state", n => n == strings["job.state.succeeded"]);
            Thread.Sleep(1000);
        }
        TestContext.WriteLine("announced: " + string.Join(" | ", announced));
        lock (announced)
        {
            CollectionAssert.Contains(announced, strings["job.state.waitingForDevice"]);
            CollectionAssert.Contains(announced, strings["job.state.succeeded"]);
        }
        Assert.IsNull(app.TryFind("jobInspector.cancel", TimeSpan.FromMilliseconds(200)), "this slice offers no Job action");
    }

    private static string WaitForExpectedName(AppSession app, ExpectedElement expected)
    {
        try
        {
            return app.WaitForName(expected.AutomationId, n => expected.Prefix ? n.StartsWith(expected.Name, StringComparison.Ordinal) : n == expected.Name);
        }
        catch (AssertFailedException)
        {
            return AppSession.Name(app.Find(expected.AutomationId));
        }
    }

    internal static void WaitUntil(Func<bool> condition, string what)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        while (!condition())
        {
            if (watch.Elapsed > AppSession.Timeout) Assert.Fail("timed out waiting until " + what);
            Thread.Sleep(100);
        }
    }
}
