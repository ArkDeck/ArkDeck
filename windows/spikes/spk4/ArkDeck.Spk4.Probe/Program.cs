using System.Diagnostics;
using System.Drawing;
using System.Text.Json;
using ArkDeck.Spk4.Fixtures;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;

namespace ArkDeck.Spk4.Probe;

/// <summary>
/// SPK-4 UIA probe. Commands (all print one JSON document; --out also writes it to a file):
///   startup  --exe PATH | --aumid AUMID  [--runs N]   launch → first navigation item exposed and enabled
///   uia      --exe PATH | --aumid AUMID                tree walk, live region, keyboard, layout bounds
/// The probe only closes or kills processes it launched.
/// </summary>
internal static class Program
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("usage: probe startup|uia (--exe PATH | --aumid AUMID) [--runs N] [--out FILE]");
            return 2;
        }
        var opt = Options.Parse(args.Skip(1).ToArray());
        object result = args[0] switch
        {
            "startup" => Startup(opt),
            "uia" => Uia(opt),
            var c => throw new ArgumentException($"unknown command {c}"),
        };
        var text = JsonSerializer.Serialize(result, Json);
        Console.WriteLine(text);
        if (opt.Out is { } path) File.WriteAllText(path, text);
        return 0;
    }

    // ---------------------------------------------------------------- startup (criterion b)

    private static object Startup(Options opt)
    {
        using var automation = new UIA3Automation();
        var samples = new List<double>();
        var marks = new List<object>();
        for (var i = 0; i < opt.Runs; i++)
        {
            var sw = Stopwatch.StartNew();
            var app = opt.Launch();
            try
            {
                var nav = WaitFor(automation, app, AutomationIds.NavOverview, TimeSpan.FromSeconds(30));
                var ms = sw.Elapsed.TotalMilliseconds;
                samples.Add(ms);
                marks.Add(new { run = i + 1, launchToNavInteractiveMs = Math.Round(ms, 1), navName = SafeName(nav) });
            }
            finally
            {
                Stop(app);
            }
            Thread.Sleep(1500);
        }
        return new
        {
            command = "startup",
            target = opt.Describe(),
            runs = opt.Runs,
            definition = "t0 = before process launch; t1 = UIA exposes Nav.Overview as enabled and on screen",
            medianMs = Math.Round(FrameStats.Percentile(samples, 50), 1),
            p95Ms = Math.Round(FrameStats.Percentile(samples, 95), 1),
            maxMs = Math.Round(samples.Max(), 1),
            passesH4b = FrameStats.Percentile(samples, 95) <= 2000,
            samples = marks,
        };
    }

    private static AutomationElement WaitFor(UIA3Automation automation, Application app, string automationId, TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < timeout)
        {
            try
            {
                var windows = app.GetAllTopLevelWindows(automation);
                foreach (var w in windows)
                {
                    var hit = w.FindFirstDescendant(cf => cf.ByAutomationId(automationId));
                    if (hit is not null && hit.Properties.IsEnabled.ValueOrDefault && !hit.Properties.IsOffscreen.ValueOrDefault) return hit;
                }
            }
            catch (Exception e) when (e is System.Runtime.InteropServices.COMException or TimeoutException or InvalidOperationException)
            {
                // window not ready yet
            }
            Thread.Sleep(5);
        }
        throw new TimeoutException($"{automationId} not exposed within {timeout.TotalSeconds} s");
    }

    private static void Stop(Application app)
    {
        try
        {
            app.Close();
            using var p = Process.GetProcessById(app.ProcessId);
            if (!p.WaitForExit(5000)) p.Kill();
        }
        catch (ArgumentException)
        {
            // already exited
        }
        app.Dispose();
    }

    // ---------------------------------------------------------------- uia (criteria c, e)

    private static object Uia(Options opt)
    {
        using var automation = new UIA3Automation();
        var app = opt.Launch();
        try
        {
            WaitFor(automation, app, AutomationIds.NavOverview, TimeSpan.FromSeconds(30));
            var window = app.GetMainWindow(automation, TimeSpan.FromSeconds(10))
                ?? throw new InvalidOperationException("main window not found");
            window.SetForeground();
            var cf = automation.ConditionFactory;

            // 1. Navigation items: one invokable/selectable element each, stable id + name.
            var nav = AutomationIds.FixedNavigationItems.Select(id =>
            {
                var e = window.FindFirstDescendant(cf.ByAutomationId(id));
                return new
                {
                    automationId = id,
                    found = e is not null,
                    name = e is null ? null : SafeName(e),
                    controlType = e?.Properties.ControlType.ValueOrDefault.ToString(),
                    enabled = e?.Properties.IsEnabled.ValueOrDefault,
                    keyboardFocusable = e?.Properties.IsKeyboardFocusable.ValueOrDefault,
                    selectionItem = e?.Patterns.SelectionItem.IsSupported,
                    invoke = e?.Patterns.Invoke.IsSupported,
                };
            }).ToList();
            var settings = window.FindFirstDescendant(cf.ByAutomationId("SettingsItem")) ??
                           window.FindFirstDescendant(cf.ByName("Settings").And(cf.ByControlType(ControlType.ListItem)));

            // 2. Each page's primary surface, reached by selecting the nav item through UIA.
            var pages = new List<object>();
            foreach (var (id, primary) in new[]
                     {
                         (AutomationIds.NavOverview, AutomationIds.FixtureBanner),
                         (AutomationIds.NavHistory, AutomationIds.HistoryList),
                         (AutomationIds.NavViewer, AutomationIds.ViewerTree),
                         (AutomationIds.NavJob, AutomationIds.JobState),
                         (AutomationIds.NavDebug, AutomationIds.DebugUnavailable),
                         (AutomationIds.NavTrace, AutomationIds.TraceUnavailable),
                     })
            {
                Select(window, cf, id);
                var p = Retry(() => window.FindFirstDescendant(cf.ByAutomationId(primary)), TimeSpan.FromSeconds(10));
                pages.Add(new
                {
                    nav = id,
                    primary,
                    found = p is not null,
                    controlType = p?.Properties.ControlType.ValueOrDefault.ToString(),
                    name = p is null ? null : SafeName(p),
                    childSample = p is null ? null : ChildSample(p),
                    layout = Layout(window),
                });
            }

            // 3. Job state change → UIA LiveRegionChanged event, and the new name.
            Select(window, cf, AutomationIds.NavJob);
            var state = Retry(() => window.FindFirstDescendant(cf.ByAutomationId(AutomationIds.JobState)), TimeSpan.FromSeconds(10))!;
            var liveSetting = state.Properties.LiveSetting.ValueOrDefault.ToString();
            var before = SafeName(state);
            var events = new List<string>();
            using (window.RegisterAutomationEvent(automation.EventLibrary.Element.LiveRegionChangedEvent, TreeScope.Subtree,
                       (el, _) => { lock (events) events.Add(SafeName(el)); }))
            {
                var advance = window.FindFirstDescendant(cf.ByAutomationId(AutomationIds.JobAdvance))!;
                for (var i = 0; i < 4; i++)
                {
                    advance.Patterns.Invoke.Pattern.Invoke();
                    Thread.Sleep(400);
                }
                Thread.Sleep(500);
            }
            var cancelVisible = window.FindFirstDescendant(cf.ByAutomationId(AutomationIds.JobCancel)) is { } shown && !shown.Properties.IsOffscreen.ValueOrDefault;
            var after = SafeName(state);

            // 4. Keyboard: focus the first nav item, arrow down, activate with Enter.
            var keyboard = KeyboardPath(window, cf);

            // 5. Disabled controls anywhere in the shell (XPA-AC-8: none as placeholders).
            var disabled = window.FindAllDescendants(cf.ByControlType(ControlType.Button))
                .Where(b => !b.Properties.IsEnabled.ValueOrDefault && !b.Properties.IsOffscreen.ValueOrDefault).Select(SafeName).ToList();

            return new
            {
                command = "uia",
                target = opt.Describe(),
                navigation = nav,
                settingsItem = new { found = settings is not null, name = settings is null ? null : SafeName(settings), automationId = settings?.AutomationId },
                pages,
                jobLiveRegion = new
                {
                    liveSetting,
                    nameBefore = before,
                    nameAfter = after,
                    liveRegionChangedEvents = events,
                    cancelVisibleAtEnd = cancelVisible,
                },
                keyboard,
                visibleDisabledButtons = disabled,
                accessibilitySettings = new
                {
                    highContrast = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast,
                    textScaleFactor = new Windows.UI.ViewManagement.UISettings().TextScaleFactor,
                },
            };
        }
        finally
        {
            Stop(app);
        }
    }

    private static void Select(Window window, FlaUI.Core.Conditions.ConditionFactory cf, string navId)
    {
        var item = window.FindFirstDescendant(cf.ByAutomationId(navId)) ?? throw new InvalidOperationException($"{navId} missing");
        if (item.Patterns.SelectionItem.IsSupported) item.Patterns.SelectionItem.Pattern.Select();
        else item.Patterns.Invoke.Pattern.Invoke();
        Thread.Sleep(600);
    }

    private static object KeyboardPath(Window window, FlaUI.Core.Conditions.ConditionFactory cf)
    {
        var steps = new List<object>();
        Select(window, cf, AutomationIds.NavOverview);
        window.SetForeground();
        var first = window.FindFirstDescendant(cf.ByAutomationId(AutomationIds.NavOverview))!;
        first.Focus();
        Thread.Sleep(300);
        string Focused() => window.Automation.FocusedElement() is { } f ? $"{f.Properties.AutomationId.ValueOrDefault}|{f.Properties.ControlType.ValueOrDefault}|{SafeName(f)}" : "(none)";
        steps.Add(new { key = "(UIA SetFocus Nav.Overview)", focused = Focused() });
        try
        {
            foreach (var (label, key) in new[]
                     {
                         ("Down", VirtualKeyShort.DOWN), ("Down", VirtualKeyShort.DOWN), ("Down", VirtualKeyShort.DOWN),
                         ("Enter", VirtualKeyShort.ENTER), ("Tab", VirtualKeyShort.TAB), ("Tab", VirtualKeyShort.TAB),
                     })
            {
                Keyboard.Type(key);
                Thread.Sleep(450);
                steps.Add(new { key = label, focused = Focused() });
            }
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            // SendInput needs the interactive input desktop (fails while the session is locked).
            return new { steps, notRun = $"SendInput failed: Win32 error {e.NativeErrorCode}" };
        }
        var jobState = window.FindFirstDescendant(cf.ByAutomationId(AutomationIds.JobState));
        return new { steps, jobInspectorShownAfterEnter = jobState is { } shown && !shown.Properties.IsOffscreen.ValueOrDefault };
    }

    private static object Layout(Window window)
    {
        var win = window.Properties.BoundingRectangle.ValueOrDefault;
        var elements = window.FindAllDescendants()
            .Where(e => !e.Properties.IsOffscreen.ValueOrDefault && e.Properties.ControlType.ValueOrDefault is ControlType.Button or ControlType.ListItem or ControlType.Text
                or ControlType.List or ControlType.Tree or ControlType.TreeItem or ControlType.TabItem)
            .Select(e => (e, r: e.Properties.BoundingRectangle.ValueOrDefault))
            .ToList();
        var outside = elements.Where(x => !x.r.IsEmpty && !Contains(win, x.r)).Select(x => SafeName(x.e)).ToList();
        var empty = elements.Count(x => x.r.IsEmpty || x.r.Width < 1 || x.r.Height < 1);
        var navRects = AutomationIds.FixedNavigationItems
            .Select(id => window.FindFirstDescendant(c => c.ByAutomationId(id))?.Properties.BoundingRectangle.ValueOrDefault ?? Rectangle.Empty)
            .ToList();
        var navOverlaps = 0;
        for (var i = 0; i < navRects.Count; i++)
            for (var j = i + 1; j < navRects.Count; j++)
                if (navRects[i].IntersectsWith(navRects[j])) navOverlaps++;
        return new
        {
            window = $"{win.Width}x{win.Height}",
            visibleElements = elements.Count,
            outsideWindow = outside,
            emptyBounds = empty,
            navOverlaps,
            navRects = navOverlaps > 0 ? navRects.Select(r => $"{r.X},{r.Y},{r.Width}x{r.Height}").ToList() : null,
        };
    }

    private static bool Contains(Rectangle outer, Rectangle inner)
    {
        var slack = Rectangle.Inflate(outer, 2, 2);
        return slack.Contains(inner);
    }

    /// <summary>First realised rows of a list/tree (with tree level state), else the children.</summary>
    private static List<string> ChildSample(AutomationElement e)
    {
        var rows = e.FindAllDescendants(c => c.ByControlType(ControlType.ListItem).Or(c.ByControlType(ControlType.TreeItem)))
            .Take(4).ToList();
        if (rows.Count == 0) rows = e.FindAllChildren().Take(4).ToList();
        return rows.Select(c =>
        {
            var type = c.Properties.ControlType.ValueOrDefault;
            var extra = type == ControlType.TreeItem && c.Patterns.ExpandCollapse.IsSupported
                ? $" [{c.Patterns.ExpandCollapse.Pattern.ExpandCollapseState.ValueOrDefault}]"
                : "";
            return $"{type}: {SafeName(c)}{extra}";
        }).ToList();
    }

    private static string SafeName(AutomationElement e)
    {
        try { return e.Name ?? ""; }
        catch (Exception) { return "(unreadable)"; }
    }

    private static T? Retry<T>(Func<T?> f, TimeSpan timeout) where T : class
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < timeout)
        {
            if (f() is { } v) return v;
            Thread.Sleep(100);
        }
        return null;
    }

    private sealed record Options(string? Exe, string? Aumid, int Runs, string? Out, string? Args)
    {
        public static Options Parse(string[] a)
        {
            string? exe = null, aumid = null, output = null, extra = null;
            var runs = 10;
            for (var i = 0; i < a.Length; i++)
            {
                switch (a[i])
                {
                    case "--exe": exe = a[++i]; break;
                    case "--aumid": aumid = a[++i]; break;
                    case "--runs": runs = int.Parse(a[++i], System.Globalization.CultureInfo.InvariantCulture); break;
                    case "--out": output = a[++i]; break;
                    case "--args": extra = a[++i]; break;
                    default: throw new ArgumentException($"unknown option {a[i]}");
                }
            }
            if ((exe is null) == (aumid is null)) throw new ArgumentException("give exactly one of --exe or --aumid");
            return new Options(exe, aumid, runs, output, extra);
        }

        public Application Launch() => Exe is not null
            ? Application.Launch(new ProcessStartInfo(Exe, Args ?? "") { UseShellExecute = false })
            : Application.LaunchStoreApp(Aumid!, Args ?? "");

        public string Describe() => Exe is not null ? $"exe:{Path.GetFileName(Exe)}" : $"aumid:{Aumid}";
    }
}
