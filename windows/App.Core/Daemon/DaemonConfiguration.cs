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
/// </list>
/// </summary>
public sealed record LaunchOptions(string? Language, string? StartPage, string? TestTransport)
{
    public static LaunchOptions Parse(IReadOnlyList<string> args)
    {
        string? language = null, page = null, transport = null;
        for (var i = 0; i < args.Count; i++)
        {
            switch (args[i])
            {
                case "--language" when i + 1 < args.Count: language = args[++i]; break;
                case "--page" when i + 1 < args.Count: page = args[++i]; break;
                case "--test-transport" when i + 1 < args.Count: transport = args[++i]; break;
            }
        }
        return new LaunchOptions(language, page, transport);
    }
}

/// <summary>
/// Which daemon the App talks to. The identity is an installation input, never read from the
/// pipe (ClientKit's <see cref="DaemonIdentity"/>): the same variables the Rust CLI reads
/// (<c>ARKDECK_DAEMON_PATH</c>, <c>ARKDECK_DAEMON_SIGNER_SHA256</c>,
/// <c>ARKDECK_DAEMON_PACKAGE_FAMILY</c>, <c>ARKDECK_ENDPOINT</c>), the image defaulting to
/// <c>arkdeck-agentd.exe</c> beside the App. With neither a signer pin nor a package family
/// there is nothing to verify, so the App connects to nothing and shows the recovery banner.
/// </summary>
public static class DaemonConfiguration
{
    /// <summary>The ClientKit budget of one call (connect, authenticate, health, request).</summary>
    public static readonly TimeSpan CallBudget = TimeSpan.FromSeconds(10);

    public static IControlChannel Create(LaunchOptions options, Func<string, string?> environment, string appDirectory)
    {
        if (options.TestTransport is { } scenario) return ScriptedDaemon.Channel(scenario);

        var path = Value(environment, "ARKDECK_DAEMON_PATH") ?? Path.Combine(appDirectory, "arkdeck-agentd.exe");
        var signer = Value(environment, "ARKDECK_DAEMON_SIGNER_SHA256");
        var family = Value(environment, "ARKDECK_DAEMON_PACKAGE_FAMILY");
        if (signer is null && family is null)
        {
            return new UnconfiguredChannel("set ARKDECK_DAEMON_SIGNER_SHA256 or ARKDECK_DAEMON_PACKAGE_FAMILY for " + path);
        }
        var identity = new DaemonIdentity(path, signer, family);
        if (Value(environment, "ARKDECK_ENDPOINT") is { } endpoint)
        {
            try
            {
                return new SessionChannel(new ControlSession(new PipeEndpoint(endpoint), identity, CallBudget));
            }
            catch (ServerAuthenticationException error)
            {
                return new UnconfiguredChannel(error.Message);
            }
        }
        return new SessionChannel(ControlSession.ForCurrentUser(identity, CallBudget));
    }

    private static string? Value(Func<string, string?> environment, string name) =>
        environment(name) is { Length: > 0 } value ? value : null;
}
