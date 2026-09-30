using System.Text;
using System.Text.Json;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.ClientKit.Tests;

internal static class RepoPaths
{
    /// <summary>The repository root, found by walking up from the test binaries.</summary>
    public static string Root { get; } = FindRoot();

    public static string At(params string[] parts) => Path.Combine([Root, .. parts]);

    public static string Corpus(string method) =>
        At("Packages", "ArkDeckKit", "Tests", "ArkDeckContractTests", "Fixtures", "ControlFrames", method + ".jsonl");

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "windows", "ArkDeck.Windows.slnx"))) return dir.FullName;
        }
        throw new InvalidOperationException("repository root not found above " + AppContext.BaseDirectory);
    }
}

/// <summary>The recorded single-v1 corpus: one JSON line per recorded shape, keys sorted.</summary>
internal static class Corpus
{
    public static IEnumerable<(string Method, int Index, byte[] Line)> Rows()
    {
        foreach (var method in ControlContract.Methods)
        {
            var bytes = File.ReadAllBytes(RepoPaths.Corpus(method));
            Assert.AreEqual((byte)'\n', bytes[^1], $"{method}: torn corpus tail");
            var index = 0;
            var start = 0;
            for (var i = 0; i < bytes.Length; i++)
            {
                if (bytes[i] != (byte)'\n') continue;
                yield return (method, index++, bytes[start..i]);
                start = i + 1;
            }
        }
    }

    /// <summary>The raw bytes of the row's top-level <c>params</c> value, as recorded, or null.</summary>
    public static byte[]? RawParams(byte[] line)
    {
        var reader = new Utf8JsonReader(line);
        reader.Read();
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isParams = reader.ValueTextEquals("params");
            reader.Read();
            var start = (int)reader.TokenStartIndex;
            reader.Skip();
            if (isParams) return line[start..(int)reader.BytesConsumed];
        }
        return null;
    }

    /// <summary>A schema-valid <c>health</c> result for this contract.</summary>
    public static JsonObject HealthResult(string? contractIdentity = null) => new(
    [
        new("catalogDigest", new JsonString(new string('a', 64))),
        new("contractIdentity", new JsonString(contractIdentity ?? ControlContract.ContractIdentity)),
        new("protocolVersion", new JsonString(ControlContract.ProtocolVersion)),
        new("providers", new JsonArray([])),
        new("publishedMethods", new JsonArray(ControlContract.Methods.Select(m => (JsonValue)new JsonString(m)))),
        new("status", new JsonString("ok")),
    ]);

    /// <summary>The first recorded successful result of a method.</summary>
    public static JsonValue RecordedResult(string method) =>
        Rows().Where(r => r.Method == method).Select(r => StrictJson.Parse(r.Line)).First(r => r["ok"].Equals(JsonBool.True))["result"];
}

/// <summary>
/// An in-memory authenticated transport whose peer answers each complete request frame
/// through a script. It records every byte the client wrote, so a test can prove how many
/// frames were sent (zero frames on refusal, no replay after a lost reply).
/// </summary>
internal sealed class ScriptedPeer(Func<int, JsonObject, ScriptedReply> script) : Stream
{
    private readonly MemoryStream _received = new();
    private readonly Queue<byte> _outgoing = new();
    private bool _closed;
    private bool _hang;
    private int _consumed;

    public List<JsonObject> Frames { get; } = [];

    public byte[] Received => _received.ToArray();

    public override bool CanRead => true;

    public override bool CanSeek => false;

    public override bool CanWrite => true;

    public override long Length => throw new NotSupportedException();

    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (_outgoing.Count == 0 && _hang) await Task.Delay(Timeout.Infinite, cancellationToken);
        if (_outgoing.Count == 0) return 0;
        var count = Math.Min(buffer.Length, _outgoing.Count);
        for (var i = 0; i < count; i++) buffer.Span[i] = _outgoing.Dequeue();
        return count;
    }

    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (_closed) throw new IOException("the peer closed the connection");
        _received.Write(buffer.Span);
        var all = _received.ToArray();
        while (true)
        {
            var end = Array.IndexOf(all, (byte)'\n', _consumed);
            if (end < 0) break;
            var frame = (JsonObject)StrictJson.Parse(all.AsSpan(_consumed, end - _consumed));
            _consumed = end + 1;
            Frames.Add(frame);
            var reply = script(Frames.Count - 1, frame);
            switch (reply.Kind)
            {
                case ScriptedReplyKind.Bytes:
                    foreach (var b in reply.Bytes!) _outgoing.Enqueue(b);
                    break;
                case ScriptedReplyKind.Close:
                    _closed = true;
                    break;
                case ScriptedReplyKind.Hang:
                    _hang = true;
                    break;
            }
        }
        return ValueTask.CompletedTask;
    }

    public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override void Write(byte[] buffer, int offset, int count) => WriteAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override void Flush() { }

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public static ScriptedReply Success(JsonObject request, JsonValue result) =>
        ScriptedReply.Of(Wire.EncodeFrame(new JsonObject([new("id", request["id"]), new("ok", JsonBool.True), new("result", result)]), ControlContract.MaxResponseBytes));

    public static ScriptedReply Failure(JsonObject request, string code, string message) =>
        ScriptedReply.Of(Wire.EncodeFrame(new JsonObject(
        [
            new("id", request["id"]),
            new("ok", JsonBool.False),
            new("error", new JsonObject([new("code", new JsonString(code)), new("message", new JsonString(message))])),
        ]), ControlContract.MaxResponseBytes));
}

internal enum ScriptedReplyKind { Bytes, Close, Hang }

internal sealed record ScriptedReply(ScriptedReplyKind Kind, byte[]? Bytes)
{
    public static ScriptedReply Of(byte[] bytes) => new(ScriptedReplyKind.Bytes, bytes);

    public static ScriptedReply Of(string text) => new(ScriptedReplyKind.Bytes, Encoding.UTF8.GetBytes(text));

    public static readonly ScriptedReply Close = new(ScriptedReplyKind.Close, null);

    public static readonly ScriptedReply Hang = new(ScriptedReplyKind.Hang, null);
}
