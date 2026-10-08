using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.App.Core.Daemon;

/// <summary>
/// Command-line switches of the App.
/// <list type="bullet">
/// <item><c>--language en-US|zh-Hans</c>: the UI language (otherwise from the user's Windows languages);</item>
/// <item><c>--page overview|device|history</c>: the first page;</item>
/// <item><c>--test-transport &lt;scenario&gt;</c>: connect to an in-process scripted daemon
/// (<see cref="ScriptedDaemon"/>) instead of the pipe, for the UIA tests of states the real
/// daemon cannot be made to show on demand. The window then says so in a banner.</item>
/// <item><c>--text-scale &lt;factor&gt;</c> (with <c>--test-transport</c> only): multiplies the
/// App's own text sizes, so the layout tests can check the pages at the largest Windows
/// text size (225 %) without changing the system setting. WinUI's own chrome keeps the
/// system size.</item>
/// <item><c>--high-contrast-tokens</c> (with <c>--test-transport</c> only): the App's tokens take
/// their high-contrast values (system colours) in the light and dark themes too, so the UIA
/// tests can check the high-contrast mapping without switching the system theme.</item>
/// <item><c>--focus-walk &lt;file&gt;</c> (with <c>--test-transport</c> only): the keyboard tests'
/// in-process Tab walk (see the App's <c>FocusWalk</c>) writes its stops to the file.</item>
/// <item><c>--render-snapshot &lt;file&gt;</c> and <c>--test-theme light|dark</c> (with
/// <c>--test-transport</c> only): native XAML visual checks with an explicit startup theme.</item>
/// <item><c>--cache-root &lt;directory&gt;</c>: the App's own cache (the Trace inbox and the Trace
/// viewer's recent list), by default <c>ArkDeck</c> in the per-user temporary directory — never
/// the Runtime's state root.</item>
/// <item><c>--remote-sources-root &lt;directory&gt;</c>: the remote build sources' files, by default
/// <c>%LOCALAPPDATA%\ArkDeck\App\RemoteBuildSources</c>; given, the credentials go to the
/// <c>ArkDeck-fixture/app</c> Credential Manager namespace instead of <c>ArkDeck/app</c> (tests).</item>
/// </list>
/// </summary>
public sealed record LaunchOptions(string? Language, string? StartPage, string? TestTransport, double TextScale = 1.0, bool HighContrastTokens = false, string? FocusWalkFile = null,
    string? CacheRootOption = null, string? RemoteSourcesRoot = null, string? PreferencesRoot = null, string? PickedFolder = null,
    string? TraceFile = null, bool FastTrustWait = false, int? LiveObservationMilliseconds = null, string? RenderSnapshotFile = null, string? TestTheme = null)
{
    /// <summary>The Trace files the App opens when Windows hands it one (macOS
    /// <c>CFBundleDocumentTypes</c>: htrace, ftrace, systrace, trace).</summary>
    public static readonly IReadOnlyList<string> TraceExtensions = [".htrace", ".ftrace", ".systrace", ".trace"];

    public string CacheRoot => CacheRootOption ?? Path.Combine(Path.GetTempPath(), "ArkDeck");

    public static LaunchOptions Parse(IReadOnlyList<string> args)
    {
        string? language = null, page = null, transport = null;
        var scale = 1.0;
        var highContrast = false;
        string? focusWalk = null;
        string? renderSnapshot = null;
        string? testTheme = null;
        string? cacheRoot = null;
        string? remoteSources = null;
        string? preferences = null;
        string? picked = null;
        string? traceFile = null;
        var fastTrustWait = false;
        int? liveObservation = null;
        for (var i = 0; i < args.Count; i++)
        {
            switch (args[i])
            {
                case "--language" when i + 1 < args.Count: language = args[++i]; break;
                case "--page" when i + 1 < args.Count: page = args[++i]; break;
                case "--test-transport" when i + 1 < args.Count: transport = args[++i]; break;
                case "--high-contrast-tokens": highContrast = true; break;
                case "--focus-walk" when i + 1 < args.Count: focusWalk = args[++i]; break;
                case "--render-snapshot" when i + 1 < args.Count: renderSnapshot = args[++i]; break;
                case "--test-theme" when i + 1 < args.Count: testTheme = args[++i]; break;
                case "--cache-root" when i + 1 < args.Count: cacheRoot = Path.GetFullPath(args[++i]); break;
                case "--remote-sources-root" when i + 1 < args.Count: remoteSources = Path.GetFullPath(args[++i]); break;
                case "--preferences-root" when i + 1 < args.Count: preferences = Path.GetFullPath(args[++i]); break;
                case "--pick-folder" when i + 1 < args.Count: picked = Path.GetFullPath(args[++i]); break;
                case "--trust-wait-fast": fastTrustWait = true; break;
                case "--live-observation-ms" when i + 1 < args.Count:
                    if (int.TryParse(args[++i], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var interval) && interval >= 100)
                    {
                        liveObservation = interval;
                    }
                    break;
                // "Open with ArkDeck" on an unpackaged copy: the file's path as the argument.
                case var path when !path.StartsWith("--", StringComparison.Ordinal) && traceFile is null
                                   && TraceExtensions.Contains(Path.GetExtension(path).ToLowerInvariant()):
                    traceFile = Path.GetFullPath(path);
                    break;
                case "--text-scale" when i + 1 < args.Count:
                    if (double.TryParse(args[++i], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var factor)
                        && factor is >= 1.0 and <= 2.25)
                    {
                        scale = factor;
                    }
                    break;
            }
        }
        // Only the scripted transport's test runs may enlarge the text; a real run follows Windows.
        return new LaunchOptions(language, page, transport, transport is null ? 1.0 : scale, transport is not null && highContrast,
            transport is null ? null : focusWalk, cacheRoot, remoteSources, preferences,
            // A folder the pickers answer without a dialog: the scripted transport's tests only.
            transport is null ? null : picked, traceFile,
            // The trust wait's window and the live observation's tick are the macOS ones (180 s
            // and 5 s, 10 s); only the scripted transport's tests shorten them, and its runs
            // observe no device unless they ask.
            transport is not null && fastTrustWait, transport is null ? null : liveObservation,
            transport is null ? null : renderSnapshot,
            transport is not null && (testTheme is "light" or "dark") ? testTheme : null);
    }
}

/// <summary>
/// Which daemon the App talks to. The identity is an installation input, never read from the
/// pipe (ClientKit's <see cref="DaemonIdentity"/>): the same variables the Rust CLI reads
/// (<c>ARKDECK_DAEMON_PATH</c>, <c>ARKDECK_DAEMON_SIGNER_SHA256</c>,
/// <c>ARKDECK_DAEMON_PUBLISHER_ORGANIZATION</c> with <c>ARKDECK_DAEMON_PUBLISHER_EKU</c>,
/// <c>ARKDECK_DAEMON_PACKAGE_FAMILY</c>, <c>ARKDECK_ENDPOINT</c>), the image defaulting to
/// <c>arkdeck-agentd.exe</c> beside the App. With no signer pin, publisher identity or package
/// family there is nothing to verify, so the App connects to nothing and shows the recovery
/// banner. A publisher identity with only one of its two values is passed on as given:
/// ClientKit refuses it before any frame, as the CLI does (maintainer ruling 17).
/// </summary>
public static class DaemonConfiguration
{
    /// <summary>The ClientKit budget of one call (connect, authenticate, health, request).</summary>
    public static readonly TimeSpan CallBudget = TimeSpan.FromSeconds(10);

    // These read-only projections inspect registered tools and projects. The installed CLI
    // allows 30 seconds for the same reads; ordinary and Job calls keep their own budgets.
    public static readonly TimeSpan InventoryReadBudget = TimeSpan.FromSeconds(30);

    public static IControlChannel Create(LaunchOptions options, Func<string, string?> environment, string appDirectory)
    {
        if (options.TestTransport is { } scenario) return ScriptedDaemon.Channel(scenario);

        var path = Value(environment, "ARKDECK_DAEMON_PATH") ?? Path.Combine(appDirectory, "arkdeck-agentd.exe");
        var signer = Value(environment, "ARKDECK_DAEMON_SIGNER_SHA256");
        var family = Value(environment, "ARKDECK_DAEMON_PACKAGE_FAMILY");
        var organization = Value(environment, "ARKDECK_DAEMON_PUBLISHER_ORGANIZATION");
        var eku = Value(environment, "ARKDECK_DAEMON_PUBLISHER_EKU");
        if (signer is null && family is null && organization is null && eku is null)
        {
            return new UnconfiguredChannel(
                "set ARKDECK_DAEMON_SIGNER_SHA256, ARKDECK_DAEMON_PUBLISHER_ORGANIZATION and ARKDECK_DAEMON_PUBLISHER_EKU, or ARKDECK_DAEMON_PACKAGE_FAMILY for " + path);
        }
        var identity = new DaemonIdentity(path, signer, family, organization, eku);
        if (Value(environment, "ARKDECK_ENDPOINT") is { } endpoint)
        {
            try
            {
                var pipe = new PipeEndpoint(endpoint);
                return new SessionChannel(new ControlSession(pipe, identity, CallBudget),
                    new ControlSession(pipe, identity, InventoryReadBudget));
            }
            catch (ServerAuthenticationException error)
            {
                return new UnconfiguredChannel(error.Message);
            }
        }
        return new SessionChannel(ControlSession.ForCurrentUser(identity, CallBudget),
            ControlSession.ForCurrentUser(identity, InventoryReadBudget));
    }

    private static string? Value(Func<string, string?> environment, string name) =>
        environment(name) is { Length: > 0 } value ? value : null;
}
