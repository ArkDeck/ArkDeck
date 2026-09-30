using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Daemon;

/// <summary>
/// How the App reaches the daemon: the ClientKit calls it makes, nothing else. Every
/// implementation runs the real ClientKit connection (<see cref="ControlClient"/>: health
/// first on each connection, the frame codec and the method schemas); they differ only in
/// where the authenticated byte stream comes from.
/// </summary>
public interface IControlChannel
{
    /// <summary>The verified <c>health</c> document.</summary>
    Task<ControlResult> HealthAsync();

    /// <summary>A request after the same-connection <c>health</c> preflight.</summary>
    Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null);
}

/// <summary>The production channel: <see cref="ControlSession"/> over the authenticated pipe.</summary>
public sealed class SessionChannel(ControlSession session) : IControlChannel
{
    public Task<ControlResult> HealthAsync() => session.HealthAsync();

    public Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null) =>
        session.RequestAsync(method, parameters);
}

/// <summary>
/// A channel whose connections are streams from <paramref name="connect"/>, driven by the
/// same <see cref="ControlClient"/> as the pipe (one connection per call, health first).
/// Used by the scripted test transport; a stream that fails before the health reply
/// produces the same <see cref="ControlFailureKind.DaemonUnavailable"/> failure as a pipe.
/// </summary>
public sealed class StreamChannel(Func<Stream> connect, TimeSpan budget) : IControlChannel
{
    public Task<ControlResult> HealthAsync() => CallAsync(client => client.HealthAsync(NewId()));

    public Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null) =>
        CallAsync(client => client.RequestAsync(NewId(), method, parameters));

    private async Task<ControlResult> CallAsync(Func<ControlClient, Task<JsonValue>> call)
    {
        try
        {
            using var client = new ControlClient(connect(), budget);
            return ControlResult.Success(await call(client).ConfigureAwait(false));
        }
        catch (ControlClientException error)
        {
            return ControlResult.Failed(error.Failure);
        }
    }

    private static string NewId() => Guid.NewGuid().ToString("D");
}

/// <summary>No daemon identity is configured, so nothing may be connected to: every call is
/// a <see cref="ControlFailureKind.DaemonUnavailable"/> failure and no byte is written.</summary>
public sealed class UnconfiguredChannel(string detail) : IControlChannel
{
    public const string Marker = "the installed daemon identity is unavailable";

    public Task<ControlResult> HealthAsync() => Task.FromResult(Failure());

    public Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null) => Task.FromResult(Failure());

    private ControlResult Failure() => ControlResult.Failed(new ControlFailure(
        ControlFailureKind.DaemonUnavailable, $"{Marker}: {detail}", ArkDeck.ClientKit.Transport.DaemonUnavailableReason.EndpointUnavailable));
}
