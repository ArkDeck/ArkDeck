using System.Security.Cryptography;
using ArkDeck.ClientKit.Json;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit;

/// <summary>A control call's outcome: the result, or a typed failure. A
/// <see cref="ControlFailureKind.DaemonUnavailable"/> failure is what the UI turns into the
/// recovery banner (<see cref="ControlFailure.Banner"/>); it never carries data.</summary>
public sealed record ControlResult(JsonValue? Value, ControlFailure? Failure)
{
    public bool Succeeded => Failure is null;

    public static ControlResult Success(JsonValue value) => new(value, null);

    public static ControlResult Failed(ControlFailure failure) => new(null, failure);
}

/// <summary>
/// The daemon as the UI reaches it: one authenticated connection per call, <c>health</c>
/// first on that connection, then the request — the sequence the Rust CLI's read-only
/// leaves use. Nothing is retried; a lost reply is reported, not replayed.
/// </summary>
public sealed class ControlSession(PipeEndpoint endpoint, DaemonIdentity identity, TimeSpan budget)
{
    /// <summary>The session for this logon session's default endpoint.</summary>
    public static ControlSession ForCurrentUser(DaemonIdentity identity, TimeSpan budget)
    {
        try
        {
            return new ControlSession(PipeEndpoint.Default(), identity, budget);
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            // Like the Rust CLI: no endpoint is itself "Runtime unavailable".
            return new ControlSession(null!, identity, budget) { _endpointError = error.Message };
        }
    }

    private string? _endpointError;

    /// <summary>The verified <c>health</c> document.</summary>
    public Task<ControlResult> HealthAsync() => CallAsync(client => client.HealthAsync(NewId()));

    /// <summary>A request after the same-connection <c>health</c> preflight.</summary>
    public Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null) =>
        CallAsync(client => client.RequestAsync(NewId(), method, parameters));

    /// <summary>One synchronous Device Job run with its freshly read Catalog timeout plus the ordinary handshake allowance.
    /// The caller deadline changes; endpoint, image identity, health and no-replay rules do not.</summary>
    public Task<ControlResult> RunJobOnceAsync(string jobId, TimeSpan callBudget)
    {
        if (string.IsNullOrEmpty(jobId) || callBudget < TimeSpan.FromSeconds(11) || callBudget > TimeSpan.FromSeconds(910))
            return Task.FromResult(ControlResult.Failed(new ControlFailure(ControlFailureKind.InvalidRequest, "Device run deadline is outside its bounded published range")));
        return CallAsync(client => client.RequestAsync(NewId(), "job.run", new JsonObject([new("jobId", new JsonString(jobId))])), callBudget);
    }

    public Task<ControlResult> DiagnosticStatusAsync(string jobId) => DiagnosticCall("diagnostic.session.status", jobId);
    public Task<ControlResult> DiagnosticMarkAsync(string jobId, string markerId) => string.IsNullOrEmpty(markerId)
        ? Task.FromResult(ControlResult.Failed(new(ControlFailureKind.InvalidRequest, "A diagnostic marker identity is required")))
        : DiagnosticCall("diagnostic.session.mark", jobId, markerId);
    public Task<ControlResult> DiagnosticStopAsync(string jobId) => DiagnosticCall("diagnostic.session.stop", jobId);
    public Task<ControlResult> DiagnosticCancelPreparationAsync(string jobId) => DiagnosticCall("job.cancel", jobId);
    private Task<ControlResult> DiagnosticCall(string method, string jobId, string? markerId = null)
    {
        if (string.IsNullOrEmpty(jobId)) return Task.FromResult(ControlResult.Failed(new(ControlFailureKind.InvalidRequest, "A diagnostic Job identity is required")));
        var parameters = new JsonObject(markerId is null ? [new("jobId", new JsonString(jobId))]
            : [new("jobId", new JsonString(jobId)), new("markerId", new JsonString(markerId))]);
        return CallAsync(client => client.RequestAsync(NewId(), method, parameters), TimeSpan.FromSeconds(120));
    }

    private async Task<ControlResult> CallAsync(Func<ControlClient, Task<JsonValue>> call, TimeSpan? callBudget = null)
    {
        if (_endpointError is not null)
        {
            return ControlResult.Failed(ControlFailure.Unavailable(DaemonUnavailableReason.EndpointUnavailable,
                "the private local Runtime endpoint is unavailable: " + _endpointError));
        }
        try
        {
            using var client = ControlClient.Connect(endpoint, identity, callBudget ?? budget);
            return ControlResult.Success(await call(client).ConfigureAwait(false));
        }
        catch (ControlClientException error)
        {
            return ControlResult.Failed(error.Failure);
        }
    }

    /// <summary>A request id in the Rust CLI's form: a random UUID v4.</summary>
    private static string NewId()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        bytes[6] = (byte)((bytes[6] & 0x0f) | 0x40);
        bytes[8] = (byte)((bytes[8] & 0x3f) | 0x80);
        var hex = Convert.ToHexStringLower(bytes);
        return $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..]}";
    }
}
