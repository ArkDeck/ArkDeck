using System.Text;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.ClientKit.Contract;

/// <summary>A single-v1 request <c>{protocolVersion,contractIdentity,id,method,params?}</c>.</summary>
public sealed record ControlRequest(string ProtocolVersion, string ContractIdentity, string Id, string Method, JsonObject? Params)
{
    /// <summary>The Rust <c>Request::new</c>: this client's version and identity.</summary>
    public static ControlRequest Create(string id, string method, JsonObject? parameters = null) =>
        new(ControlContract.ProtocolVersion, ControlContract.ContractIdentity, id, method, parameters);

    /// <summary>The members in the order the Rust struct serializes them: serde writes a
    /// struct's fields in declaration order (only a map's keys are sorted), and skips
    /// <c>params</c> when it is <c>None</c>.</summary>
    internal void WriteTo(StringBuilder output)
    {
        output.Append("{\"protocolVersion\":").Append(Text(new JsonString(ProtocolVersion)))
            .Append(",\"contractIdentity\":").Append(Text(new JsonString(ContractIdentity)))
            .Append(",\"id\":").Append(Text(new JsonString(Id)))
            .Append(",\"method\":").Append(Text(new JsonString(Method)));
        if (Params is not null) output.Append(",\"params\":").Append(Text(Params));
        output.Append('}');
    }

    private static string Text(JsonValue value) => Encoding.UTF8.GetString(CanonicalJson.Encode(value));
}

/// <summary>The Rust <c>WireError{code,message,details?}</c>.</summary>
public sealed record WireError(string Code, string Message, JsonObject? Details);

/// <summary>A decoded response: a result or a daemon's wire error.</summary>
public sealed record ControlResponse(string Id, JsonValue? Result, WireError? Error)
{
    public bool Ok => Error is null;
}

/// <summary>
/// The Rust contract's framing functions (<c>arkdeck-contract/src/framing.rs</c>), same
/// checks in the same order (T0/T1).
/// </summary>
public static class Wire
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    /// <summary><c>encode_frame</c> of a request: its bytes plus LF; refused when the bytes
    /// alone reach the limit, so the LF counts toward it.</summary>
    public static byte[] EncodeRequestFrame(ControlRequest request, int limit = ControlContract.MaxRequestBytes)
    {
        var text = new StringBuilder();
        try
        {
            request.WriteTo(text);
        }
        catch (ArgumentException error)
        {
            throw new ContractException(ContractErrorKind.Malformed, error.Message);
        }
        return Frame(StrictUtf8.GetBytes(text.ToString()), limit);
    }

    /// <summary><c>encode_frame</c> of any value (the fake servers of the tests use it).</summary>
    public static byte[] EncodeFrame(JsonValue value, int limit)
    {
        byte[] bytes;
        try
        {
            bytes = CanonicalJson.Encode(value);
        }
        catch (ArgumentException error)
        {
            throw new ContractException(ContractErrorKind.Malformed, error.Message);
        }
        return Frame(bytes, limit);
    }

    private static byte[] Frame(byte[] bytes, int limit)
    {
        if (bytes.Length >= limit) throw new ContractException(ContractErrorKind.Malformed, "frame exceeds its limit");
        var frame = new byte[bytes.Length + 1];
        bytes.CopyTo(frame, 0);
        frame[^1] = (byte)'\n';
        return frame;
    }

    private static JsonObject WireObject(ReadOnlySpan<byte> bytes, int limit)
    {
        if (bytes.Length >= limit || bytes.IndexOfAny((byte)'\n', (byte)'\r') >= 0)
        {
            throw new ContractException(ContractErrorKind.Malformed, "frame is too long or holds a line terminator");
        }
        JsonValue value;
        try
        {
            value = StrictJson.Parse(bytes);
        }
        catch (MalformedJsonException error)
        {
            throw new ContractException(ContractErrorKind.Malformed, error.Message);
        }
        return value as JsonObject ?? throw new ContractException(ContractErrorKind.Malformed, "frame is not an object");
    }

    /// <summary>Rust <c>valid_id</c>: 1..=128 UTF-8 bytes, no control character below U+0020.</summary>
    public static bool ValidId(string id) =>
        id.Length > 0 && Encoding.UTF8.GetByteCount(id) <= 128 && id.EnumerateRunes().All(r => r.Value >= 0x20);

    private static readonly string[] RequestMembers = ["protocolVersion", "contractIdentity", "id", "method", "params"];

    /// <summary><c>decode_request</c>. The client runs it over its own frame before sending
    /// anything, as the Rust client does, so a malformed local request sends zero frames.</summary>
    public static ControlRequest DecodeRequest(ReadOnlySpan<byte> bytes)
    {
        var fields = WireObject(bytes, ControlContract.MaxRequestBytes);
        if (fields.Keys.Any(k => Array.IndexOf(RequestMembers, k) < 0)
            || fields["id"] is not JsonString { Value: var id } || !ValidId(id)
            || fields["method"] is not JsonString { Value: var method } || method.Length == 0 || Encoding.UTF8.GetByteCount(method) > 128)
        {
            throw new ContractException(ContractErrorKind.Malformed, "request envelope");
        }
        if (fields["protocolVersion"] is not JsonString { Value: ControlContract.ProtocolVersion })
        {
            throw new ContractException(ContractErrorKind.UnsupportedVersion);
        }
        if (fields["contractIdentity"] is not JsonString { Value: ControlContract.ContractIdentity })
        {
            throw new ContractException(ContractErrorKind.ContractMismatch);
        }
        JsonObject? parameters = null;
        if (fields.TryGetValue("params", out var rawParams))
        {
            // serde: `params: Option<Map>`; a JSON null is None, anything else must be an object.
            // serde's `Option<Map>` would read null as None, but the envelope check before
            // it refuses every `params` that is not an object, null included.
            parameters = rawParams as JsonObject
                         ?? throw new ContractException(ContractErrorKind.Malformed, "params must be an object");
        }
        if (!ControlContract.Methods.Contains(method)) throw new ContractException(ContractErrorKind.UnknownMethod, method);
        return new ControlRequest(ControlContract.ProtocolVersion, ControlContract.ContractIdentity, id, method, parameters);
    }

    private static readonly string[] ErrorMembers = ["code", "message", "details"];

    /// <summary><c>decode_response</c>: exactly <c>{id,ok,result|error}</c> for the expected
    /// id, the result or error validated against the method's schema.</summary>
    public static ControlResponse DecodeResponse(ReadOnlySpan<byte> bytes, string expectedId, string method)
    {
        var fields = WireObject(bytes, ControlContract.MaxResponseBytes);
        if (!ValidId(expectedId) || fields["id"] is not JsonString { Value: var id } || id != expectedId || fields.Count != 3)
        {
            throw new ContractException(ContractErrorKind.Malformed, "response envelope");
        }
        switch (fields["ok"])
        {
            case JsonBool { Value: true }:
                if (!fields.TryGetValue("result", out var result)) throw new ContractException(ContractErrorKind.Malformed, "missing result");
                SchemaValidator.ValidateMethodValue(method, "result", result);
                return new ControlResponse(expectedId, result, null);
            case JsonBool { Value: false }:
                if (!fields.TryGetValue("error", out var rawError)) throw new ContractException(ContractErrorKind.Malformed, "missing error");
                if (rawError is JsonObject errorObject && errorObject.TryGetValue("details", out var rawDetails) && rawDetails is not JsonObject)
                {
                    throw new ContractException(ContractErrorKind.Malformed, "error details must be an object");
                }
                if (rawError is not JsonObject e
                    || e.Keys.Any(k => Array.IndexOf(ErrorMembers, k) < 0)
                    || e["code"] is not JsonString { Value: var code }
                    || e["message"] is not JsonString { Value: var message }
                    || code.Length == 0)
                {
                    throw new ContractException(ContractErrorKind.Malformed, "error envelope");
                }
                var details = e.TryGetValue("details", out var d) ? (JsonObject)d : null;
                SchemaValidator.ValidateMethodValue(method, "errorCode", new JsonString(code));
                if (details is not null) SchemaValidator.ValidateMethodValue(method, "errorDetails", details);
                return new ControlResponse(expectedId, null, new WireError(code, message, details));
            default:
                throw new ContractException(ContractErrorKind.Malformed, "ok must be a boolean");
        }
    }

    /// <summary><c>validate_health</c>: this is the contract preflight of a connection.</summary>
    public static void ValidateHealth(ControlResponse response)
    {
        if (response.Result is not { } result) throw new ContractException(ContractErrorKind.ContractMismatch, "health failed");
        SchemaValidator.ValidateMethodValue("health", "result", result);
        if (result["catalogDigest"] is not JsonString { Value: var digest }) throw new ContractException(ContractErrorKind.ContractMismatch);
        var methods = new JsonArray(ControlContract.Methods.Select(m => (JsonValue)new JsonString(m)));
        if (result["status"] is not JsonString { Value: "ok" }
            || result["protocolVersion"] is not JsonString { Value: ControlContract.ProtocolVersion }
            || result["contractIdentity"] is not JsonString { Value: ControlContract.ContractIdentity }
            || !result["publishedMethods"].Equals(methods)
            || digest.Length != 64
            || !digest.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')
            || result["providers"] is not JsonArray providers
            || !providers.Items.All(p => p is JsonString { Value.Length: > 0 }))
        {
            throw new ContractException(ContractErrorKind.ContractMismatch, "health does not describe this contract");
        }
    }
}
