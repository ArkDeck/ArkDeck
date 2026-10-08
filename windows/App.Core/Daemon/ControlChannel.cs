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

/// <summary>Optional one-exchange synchronous Job lane. Callers must derive the deadline from the matching fresh operation descriptor.</summary>
public interface IRuntimeJobChannel
{
    Task<ControlResult> RunJobOnceAsync(string jobId, TimeSpan callBudget);
}

/// <summary>Published diagnostic-session controls on separate authenticated health-first connections.
/// Their fixed120s deadline matches the macOS control path; no method or deadline is supplied by the caller.</summary>
public interface IDiagnosticSessionChannel
{
    Task<ControlResult> StatusAsync(string jobId);
    Task<ControlResult> MarkAsync(string jobId, string markerId);
    Task<ControlResult> StopAsync(string jobId);
    Task<ControlResult> CancelPreparationAsync(string jobId);
}

/// <summary>The production channel: <see cref="ControlSession"/> over the authenticated pipe.</summary>
public sealed class SessionChannel(ControlSession session, ControlSession? inventoryReads = null) : IControlChannel, IRuntimeJobChannel, IDiagnosticSessionChannel
{
    public Task<ControlResult> HealthAsync() => session.HealthAsync();

    public Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null) =>
        (method is "doctor" or "operation.list" ? inventoryReads ?? session : session).RequestAsync(method, parameters);

    public Task<ControlResult> RunJobOnceAsync(string jobId, TimeSpan callBudget) => session.RunJobOnceAsync(jobId, callBudget);
    public Task<ControlResult> StatusAsync(string jobId) => session.DiagnosticStatusAsync(jobId);
    public Task<ControlResult> MarkAsync(string jobId, string markerId) => session.DiagnosticMarkAsync(jobId, markerId);
    public Task<ControlResult> StopAsync(string jobId) => session.DiagnosticStopAsync(jobId);
    public Task<ControlResult> CancelPreparationAsync(string jobId) => session.DiagnosticCancelPreparationAsync(jobId);
}

/// <summary>
/// A channel whose connections are streams from <paramref name="connect"/>, driven by the
/// same <see cref="ControlClient"/> as the pipe (one connection per call, health first).
/// Used by the scripted test transport; a stream that fails before the health reply
/// produces the same <see cref="ControlFailureKind.DaemonUnavailable"/> failure as a pipe.
/// </summary>
public sealed class StreamChannel(Func<Stream> connect, TimeSpan budget) : IControlChannel, IRuntimeJobChannel, IDiagnosticSessionChannel
{
    public Task<ControlResult> HealthAsync() => CallAsync(client => client.HealthAsync(NewId()));

    public Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null) =>
        CallAsync(client => client.RequestAsync(NewId(), method, parameters));

    public Task<ControlResult> RunJobOnceAsync(string jobId, TimeSpan callBudget)
    {
        if (string.IsNullOrEmpty(jobId) || callBudget < TimeSpan.FromSeconds(11) || callBudget > TimeSpan.FromSeconds(910))
            return Task.FromResult(ControlResult.Failed(new ControlFailure(ControlFailureKind.InvalidRequest, "Device run deadline is outside its bounded published range")));
        return CallAsync(client => client.RequestAsync(NewId(), "job.run", new JsonObject([new("jobId", new JsonString(jobId))])), callBudget);
    }

    public Task<ControlResult> StatusAsync(string jobId) => DiagnosticCall("diagnostic.session.status", jobId);
    public Task<ControlResult> MarkAsync(string jobId, string markerId) => string.IsNullOrEmpty(markerId)
        ? Task.FromResult(ControlResult.Failed(new(ControlFailureKind.InvalidRequest, "A diagnostic marker identity is required")))
        : DiagnosticCall("diagnostic.session.mark", jobId, markerId);
    public Task<ControlResult> StopAsync(string jobId) => DiagnosticCall("diagnostic.session.stop", jobId);
    public Task<ControlResult> CancelPreparationAsync(string jobId) => DiagnosticCall("job.cancel", jobId);
    private Task<ControlResult> DiagnosticCall(string method, string jobId, string? markerId = null)
    {
        if (string.IsNullOrEmpty(jobId)) return Task.FromResult(ControlResult.Failed(new(ControlFailureKind.InvalidRequest, "A diagnostic Job identity is required")));
        var parameters = new JsonObject(markerId is null ? [new("jobId", new JsonString(jobId))]
            : [new("jobId", new JsonString(jobId)), new("markerId", new JsonString(markerId))]);
        return CallAsync(client => client.RequestAsync(NewId(), method, parameters), TimeSpan.FromSeconds(120));
    }

    private async Task<ControlResult> CallAsync(Func<ControlClient, Task<JsonValue>> call, TimeSpan? callBudget = null)
    {
        try
        {
            using var client = new ControlClient(connect(), callBudget ?? budget);
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
