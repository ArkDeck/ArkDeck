using System.Diagnostics;
using Microsoft.UI.Xaml;

namespace ArkDeck.Spk4;

/// <summary>Command-line switches used by the SPK-4 measurement scripts.
///   --bench &lt;dir&gt;   run the scripted load/scroll benchmark, write JSON to dir, exit
///   --page &lt;tag&gt;    start on a page (overview, history, viewer, job, debug, trace)
/// </summary>
public sealed record LaunchOptions(string? BenchDir, string? StartPage)
{
    public static LaunchOptions Parse(string[] args)
    {
        string? bench = null, page = null;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--bench" when i + 1 < args.Length: bench = args[++i]; break;
                case "--page" when i + 1 < args.Length: page = args[++i]; break;
            }
        }
        return new LaunchOptions(bench, page);
    }
}

public partial class App : Application
{
    /// <summary>Process start, for the in-app startup marks (the probe measures externally too).</summary>
    public static readonly DateTime ProcessStartUtc = Process.GetCurrentProcess().StartTime.ToUniversalTime();

    public static double MsSinceProcessStart => (DateTime.UtcNow - ProcessStartUtc).TotalMilliseconds;

    public static LaunchOptions Options { get; private set; } = new(null, null);

    public static double AppCtorMs { get; private set; }

    private Window? _window;

    public App()
    {
        InitializeComponent();
        AppCtorMs = MsSinceProcessStart;
        Options = LaunchOptions.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow(Options);
        _window.Activate();
    }
}
