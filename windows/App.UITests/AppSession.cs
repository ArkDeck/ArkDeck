using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;

namespace ArkDeck.App.UITests;

/// <summary>One launched App (out of process, UIA3). Only the process it launched is closed or
/// killed, on dispose.</summary>
internal sealed class AppSession : IDisposable
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(20);

    private readonly Application _app;

    private AppSession(Application app, UIA3Automation automation, Window window)
    {
        _app = app;
        Automation = automation;
        Window = window;
    }

    public UIA3Automation Automation { get; }

    public Window Window { get; }

    public int ProcessId => _app.ProcessId;

    /// <summary>The App window's handle (keyboard tests post their strokes to it).</summary>
    public IntPtr Handle => Window.Properties.NativeWindowHandle.ValueOrDefault;

    /// <summary>The App to test: ARKDECK_APP_EXE, else the solution's Release (then Debug) build.</summary>
    public static string? FindExe()
    {
        if (Environment.GetEnvironmentVariable("ARKDECK_APP_EXE") is { Length: > 0 } configured) return File.Exists(configured) ? configured : null;
        foreach (var configuration in new[] { "Release", "Debug" })
        {
            var path = RepoPaths.At("windows", "App", "bin", configuration, "net10.0-windows10.0.26100.0", "win-x64", "ArkDeck.exe");
            if (File.Exists(path)) return path;
        }
        return null;
    }

    /// <summary>Skips the calling test unless UI tests are enabled and the App is built.</summary>
    public static string RequireApp()
    {
        if (Environment.GetEnvironmentVariable("ARKDECK_APP_UITESTS") != "1")
        {
            Assert.Inconclusive("skipped: UIA tests of the running App need a Windows desktop session; set ARKDECK_APP_UITESTS=1 to run them");
        }
        return FindExe() ?? throw new AssertInconclusiveException("skipped: the App is not built (dotnet build windows/ArkDeck.Windows.slnx -c Release)");
    }

    private static readonly Lazy<string> RemoteSourcesRoot = new(() => Directory.CreateTempSubdirectory("arkdeck-uitest-remote-sources-").FullName);

    public static AppSession Launch(string exe, IEnumerable<string> arguments, IReadOnlyDictionary<string, string>? environment = null)
    {
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        // The remote build sources of a test run are its own (files in a temporary directory,
        // credentials in the ArkDeck-fixture namespace), never the person's.
        if (!start.ArgumentList.Contains("--remote-sources-root"))
        {
            start.ArgumentList.Add("--remote-sources-root");
            start.ArgumentList.Add(RemoteSourcesRoot.Value);
        }
        // No inherited ArkDeck configuration: each test states the daemon it means.
        foreach (var key in start.Environment.Keys.ToArray())
        {
            if (key.StartsWith("ARKDECK_", StringComparison.OrdinalIgnoreCase)) start.Environment.Remove(key);
        }
        foreach (var (key, value) in environment ?? new Dictionary<string, string>()) start.Environment[key] = value;
        var app = Application.Launch(start);
        var automation = new UIA3Automation();
        try
        {
            var window = app.GetMainWindow(automation, Timeout) ?? throw new InvalidOperationException("the App showed no window");
            return new AppSession(app, automation, window);
        }
        catch
        {
            automation.Dispose();
            Stop(app);
            throw;
        }
    }

    public AutomationElement Find(string automationId) =>
        TryFind(automationId, Timeout) ?? throw new AssertFailedException($"no element {automationId} within {Timeout.TotalSeconds} s");

    public AutomationElement? TryFind(string automationId, TimeSpan timeout)
    {
        var watch = Stopwatch.StartNew();
        do
        {
            try
            {
                if (Window.FindFirstDescendant(cf => cf.ByAutomationId(automationId)) is { } found) return found;
            }
            catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
            {
                // the tree is being rebuilt
            }
            Thread.Sleep(50);
        }
        while (watch.Elapsed < timeout);
        return null;
    }

    /// <summary>Waits until the element's name satisfies <paramref name="predicate"/>.</summary>
    public string WaitForName(string automationId, Func<string, bool> predicate)
    {
        var watch = Stopwatch.StartNew();
        var last = "";
        while (watch.Elapsed < Timeout)
        {
            if (TryFind(automationId, TimeSpan.FromMilliseconds(200)) is { } element)
            {
                last = Name(element);
                if (predicate(last)) return last;
            }
            Thread.Sleep(100);
        }
        throw new AssertFailedException($"{automationId}: name never matched; last {last}");
    }

    public void Navigate(string page)
    {
        var item = Find("app.navigation." + page);
        item.Patterns.SelectionItem.Pattern.Select();
    }

    public void Invoke(string automationId) => Find(automationId).Patterns.Invoke.Pattern.Invoke();

    /// <summary>Selects a list item (UIA SelectionItem pattern, no synthetic input).</summary>
    public void Select(string automationId) => Find(automationId).Patterns.SelectionItem.Pattern.Select();

    public static string Name(AutomationElement element)
    {
        try
        {
            return element.Properties.Name.ValueOrDefault ?? "";
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return "";
        }
    }

    /// <summary>Every button in the window (XPA-AC-8: none may be disabled).</summary>
    public IReadOnlyList<(string Id, string Name, bool Enabled)> Buttons() =>
        Window.FindAllDescendants(cf => cf.ByControlType(ControlType.Button))
            .Select(b => (b.Properties.AutomationId.ValueOrDefault ?? "", Name(b), b.Properties.IsEnabled.ValueOrDefault))
            .ToArray();

    public void Dispose()
    {
        Automation.Dispose();
        Stop(_app);
    }

    private static void Stop(Application app)
    {
        try
        {
            app.Close();
            using var process = Process.GetProcessById(app.ProcessId);
            if (!process.WaitForExit(5000))
            {
                process.Kill();
                process.WaitForExit(5000);
            }
        }
        catch (ArgumentException)
        {
            // already exited
        }
        app.Dispose();
    }
}
