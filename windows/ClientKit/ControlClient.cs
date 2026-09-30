using System.Diagnostics;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit;

/// <summary>
/// One control connection, semantically the Rust <c>arkdeck_client::Client</c> (T1) and
/// byte-identical on the wire (T0):
/// <list type="bullet">
/// <item>single-v1 LF frames carrying this client's <c>protocolVersion</c> and <c>contractIdentity</c>;</item>
/// <item>before the first business request, <c>health</c> on the same connection must pass
/// <see cref="Wire.ValidateHealth"/>; a failed preflight sends zero business frames;</item>
/// <item>a request that fails in transport or contract leaves the connection unusable and
/// is never replayed; a wire error from the daemon does not;</item>
/// <item>a malformed local request is refused before any byte, the health frame included;</item>
/// <item>connection, authentication and every read and write share one time budget; a late
/// reply cannot succeed.</item>
/// </list>
/// </summary>
public sealed class ControlClient : IDisposable
{
    private readonly Stream _stream;
    private readonly FrameReader _reader;
    private readonly long _deadline;
    private bool _verified;
    private bool _unusable;

    /// <summary>A client over a transport that has already authenticated its peer (the
    /// Rust <c>Client::new</c>). Tests use in-memory streams; production code uses
    /// <see cref="Connect"/>.</summary>
    public ControlClient(Stream authenticated, TimeSpan budget)
        : this(authenticated, Stopwatch.GetTimestamp() + Ticks(budget))
    {
    }

    private ControlClient(Stream authenticated, long deadline)
    {
        _stream = authenticated;
        _deadline = deadline;
        _reader = new FrameReader(ReadSomeAsync);
    }

    /// <summary>The Rust <c>Client::connect_bounded</c>: connect and authenticate the
    /// daemon within <paramref name="budget"/>, which then also bounds every exchange.</summary>
    /// <exception cref="ControlClientException">Always <see cref="ControlFailureKind.DaemonUnavailable"/>.</exception>
    public static ControlClient Connect(PipeEndpoint endpoint, DaemonIdentity identity, TimeSpan budget)
    {
        var deadline = Stopwatch.GetTimestamp() + Ticks(budget);
        RequireBudget(deadline);
        AuthenticatedPipe pipe;
        try
        {
            pipe = PipeConnector.Connect(endpoint, identity, Stopwatch.GetElapsedTime(Stopwatch.GetTimestamp(), deadline));
        }
        catch (ServerAuthenticationException error)
        {
            throw new ControlClientException(ControlFailure.Unavailable(error.Reason, error.Message), error);
        }
        try
        {
            RequireBudget(deadline);
        }
        catch
        {
            pipe.Dispose();
            throw;
        }
        return new ControlClient(pipe, deadline);
    }

    /// <summary>The verified <c>health</c> document: the contract preflight is this call
    /// itself, so reading health takes one exchange, not two.</summary>
    public async Task<JsonValue> HealthAsync(string id = "health")
    {
        if (_unusable) throw Unusable();
        try
        {
            CheckDeadline();
            var response = await ExchangeAsync(ControlRequest.Create(id, "health"), () => { }).ConfigureAwait(false);
            Wire.ValidateHealth(response);
            _verified = true;
            CheckDeadline();
            return response.Result!;
        }
        catch (Exception error) when (error is TransportException or ContractException)
        {
            _unusable = true;
            throw Failed(error, businessSent: false, preflight: true);
        }
    }

    /// <summary>A business request on this connection, preceded by the <c>health</c>
    /// preflight when the connection has not been verified yet.</summary>
    public async Task<JsonValue> RequestAsync(string id, string method, JsonObject? parameters = null)
    {
        if (_unusable) throw Unusable();
        var request = ControlRequest.Create(id, method, parameters);
        try
        {
            // Refuse malformed local input before even the health frame is sent.
            var frame = Wire.EncodeRequestFrame(request);
            Wire.DecodeRequest(frame.AsSpan(0, frame.Length - 1));
        }
        catch (ContractException error)
        {
            throw new ControlClientException(new ControlFailure(ControlFailureKind.InvalidRequest, error.Message), error);
        }
        var businessSent = false;
        var inPreflight = !_verified;
        try
        {
            CheckDeadline();
            if (!_verified)
            {
                var health = await ExchangeAsync(ControlRequest.Create("health", "health"), () => { }).ConfigureAwait(false);
                Wire.ValidateHealth(health);
                _verified = true;
            }
            inPreflight = false;
            var response = await ExchangeAsync(request, () => businessSent = true).ConfigureAwait(false);
            CheckDeadline();
            return response.Error is { } wireError
                ? throw new ControlClientException(new ControlFailure(ControlFailureKind.Remote, $"{wireError.Code}: {wireError.Message}", Remote: wireError))
                : response.Result!;
        }
        catch (Exception error) when (error is TransportException or ContractException)
        {
            _unusable = true;
            throw Failed(error, businessSent, inPreflight);
        }
    }

    public void Dispose() => _stream.Dispose();

    private async Task<ControlResponse> ExchangeAsync(ControlRequest request, Action sending)
    {
        CheckDeadline();
        var frame = Wire.EncodeRequestFrame(request);
        sending();
        using (var budget = Budget())
        {
            try
            {
                await _stream.WriteAsync(frame, budget.Token).ConfigureAwait(false);
                await _stream.FlushAsync(budget.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException error)
            {
                throw new TransportException(TransportErrorKind.TimedOut, "control deadline exceeded", error);
            }
            catch (IOException error)
            {
                throw new TransportException(TransportErrorKind.Io, error.Message, error);
            }
        }
        CheckDeadline();
        var payload = await _reader.ReadFrameAsync(ControlContract.MaxResponseBytes, CancellationToken.None).ConfigureAwait(false);
        return Wire.DecodeResponse(payload, request.Id, request.Method);
    }

    private async ValueTask<int> ReadSomeAsync(Memory<byte> buffer, CancellationToken _)
    {
        using var budget = Budget();
        int count;
        try
        {
            count = await _stream.ReadAsync(buffer, budget.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException error)
        {
            throw new TransportException(TransportErrorKind.TimedOut, "control deadline exceeded", error);
        }
        catch (IOException error)
        {
            throw new TransportException(TransportErrorKind.Io, error.Message, error);
        }
        CheckDeadline();
        return count;
    }

    private CancellationTokenSource Budget() => new(Remaining(_deadline));

    private void CheckDeadline() => Remaining(_deadline);

    private static void RequireBudget(long deadline)
    {
        try
        {
            Remaining(deadline);
        }
        catch (TransportException error)
        {
            throw new ControlClientException(ControlFailure.Unavailable(DaemonUnavailableReason.DeadlineExceeded, error.Message), error);
        }
    }

    private static TimeSpan Remaining(long deadline)
    {
        var left = Stopwatch.GetElapsedTime(Stopwatch.GetTimestamp(), deadline);
        if (left <= TimeSpan.Zero) throw new TransportException(TransportErrorKind.TimedOut, "control deadline exceeded");
        return left;
    }

    private static long Ticks(TimeSpan budget)
    {
        if (budget <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(budget), "the control budget must be positive");
        return checked((long)(budget.TotalSeconds * Stopwatch.Frequency));
    }

    private static ControlClientException Unusable() => new(new ControlFailure(ControlFailureKind.ConnectionUnusable,
        "the connection is unusable after an incomplete exchange; no request was replayed"));

    private static ControlClientException Failed(Exception error, bool businessSent, bool preflight)
    {
        if (!businessSent)
        {
            var reason = error switch
            {
                TransportException { Kind: TransportErrorKind.TimedOut } => DaemonUnavailableReason.DeadlineExceeded,
                ContractException when preflight => DaemonUnavailableReason.ContractMismatch,
                _ => DaemonUnavailableReason.HealthExchangeFailed,
            };
            return new ControlClientException(ControlFailure.Unavailable(reason, error.Message), error);
        }
        return new ControlClientException(new ControlFailure(ControlFailureKind.OutcomeUnknown,
            $"no valid reply to the request, which is not replayed: {error.Message}"), error);
    }
}
