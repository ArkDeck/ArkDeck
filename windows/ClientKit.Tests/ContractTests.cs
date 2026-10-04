using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit.Tests;

/// <summary>The generated bindings against their inputs.</summary>
[TestClass]
public sealed class GeneratorTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    public void GeneratedBindingsMatchARegenerationFromTheCheckout()
    {
        var python = Environment.GetEnvironmentVariable("ARKDECK_PYTHON") is { Length: > 0 } configured ? configured : "python";
        var start = new ProcessStartInfo(python, [RepoPaths.At("windows", "scripts", "generate-clientkit.py"), "--check"])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = RepoPaths.Root,
        };
        start.Environment["PYTHONUTF8"] = "1";
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        process.WaitForExit();
        TestContext.WriteLine(output);
        Assert.AreEqual(0, process.ExitCode, output);
    }

    [TestMethod]
    public void ContractIdentityIsTheDigestOfTheSortedRegistry()
    {
        // Independent of the generator: this client's canonical writer over the registry.
        var registry = StrictJson.Parse(File.ReadAllBytes(RepoPaths.At("Packages", "ArkDeckKit", "Contracts", "control-protocol.json")));
        Assert.AreEqual(ControlContract.ContractIdentity, Convert.ToHexStringLower(SHA256.HashData(CanonicalJson.Encode(registry))));
        Assert.AreEqual(ControlContract.ProtocolVersion, ((JsonString)registry["currentVersion"]).Value);
        CollectionAssert.AreEqual(((JsonArray)registry["methods"]).Items.Cast<JsonString>().Select(s => s.Value).ToArray(), ControlContract.Methods.ToArray());
        Assert.AreEqual(StrictJson.Parse("4194304"u8), registry["maximumRequestFrameBytes"]);
        Assert.AreEqual(JsonNumber.FromInt64(ControlContract.MaxRequestBytes), registry["maximumRequestFrameBytes"]);
        Assert.AreEqual(JsonNumber.FromInt64(ControlContract.MaxResponseBytes), registry["maximumResponseFrameBytes"]);
    }

    [TestMethod]
    public void EveryEmbeddedSchemaIsTheRecordedFile()
    {
        Assert.AreEqual(ControlContract.Methods.Count, ContractSchemas.Verify());
        foreach (var method in ControlContract.Methods)
        {
            var bytes = File.ReadAllBytes(RepoPaths.At("spec", "control", "methods", method + ".json"));
            Assert.AreEqual(ControlContract.MethodSchemaSha256[method], Convert.ToHexStringLower(SHA256.HashData(bytes)), method);
        }
    }
}

/// <summary>Frame limits and envelope refusals, the Rust framing tests' cases.</summary>
[TestClass]
public sealed class FramingTests
{
    private static ControlRequest RequestOfLength(int bytes)
    {
        var empty = Wire.EncodeRequestFrame(ControlRequest.Create("r", "doctor", new JsonObject([new("deep", new JsonString(""))])), int.MaxValue);
        var padding = bytes - (empty.Length - 1);
        return ControlRequest.Create("r", "doctor", new JsonObject([new("deep", new JsonString(new string('x', padding)))]));
    }

    [TestMethod]
    public void TheRequestLimitIncludesTheLineFeed()
    {
        var largest = Wire.EncodeRequestFrame(RequestOfLength(ControlContract.MaxRequestBytes - 1));
        Assert.AreEqual(ControlContract.MaxRequestBytes, largest.Length);
        var refused = Assert.ThrowsExactly<ContractException>(() => Wire.EncodeRequestFrame(RequestOfLength(ControlContract.MaxRequestBytes)));
        Assert.AreEqual(ContractErrorKind.Malformed, refused.Kind);
    }

    private static FrameReader Reader(byte[] bytes, int chunk = 8192)
    {
        var offset = 0;
        return new FrameReader((buffer, _) =>
        {
            var count = Math.Min(Math.Min(chunk, buffer.Length), bytes.Length - offset);
            bytes.AsSpan(offset, count).CopyTo(buffer.Span);
            offset += count;
            return ValueTask.FromResult(count);
        });
    }

    [TestMethod]
    public async Task TheResponseLimitIncludesTheLineFeed()
    {
        const int limit = 64;
        var exact = Enumerable.Repeat((byte)'a', limit - 1).Append((byte)'\n').ToArray();
        Assert.AreEqual(limit - 1, (await Reader(exact, 7).ReadFrameAsync(limit, default)).Length);

        var over = Enumerable.Repeat((byte)'a', limit).Append((byte)'\n').ToArray();
        var exceeded = await Assert.ThrowsExactlyAsync<TransportException>(() => Reader(over, 7).ReadFrameAsync(limit, default).AsTask());
        Assert.AreEqual(TransportErrorKind.InvalidData, exceeded.Kind);

        var endless = Enumerable.Repeat((byte)'a', limit * 2).ToArray();
        var undelimited = await Assert.ThrowsExactlyAsync<TransportException>(() => Reader(endless, limit).ReadFrameAsync(limit, default).AsTask());
        Assert.AreEqual(TransportErrorKind.InvalidData, undelimited.Kind);
    }

    [TestMethod]
    public async Task AnUnterminatedReplyIsALostReplyAndBytesAfterTheFrameWait()
    {
        var reader = Reader("{\"a\":1}\n{\"b\""u8.ToArray(), 3);
        CollectionAssert.AreEqual("{\"a\":1}"u8.ToArray(), await reader.ReadFrameAsync(1024, default));
        var lost = await Assert.ThrowsExactlyAsync<TransportException>(() => reader.ReadFrameAsync(1024, default).AsTask());
        Assert.AreEqual(TransportErrorKind.UnexpectedEof, lost.Kind);
    }

    private static ContractErrorKind Refusal(string payload, string id = "r", string method = "doctor") =>
        Assert.ThrowsExactly<ContractException>(() => Wire.DecodeResponse(Encoding.UTF8.GetBytes(payload), id, method)).Kind;

    [TestMethod]
    public void ResponseEnvelopesAreRefusedAsTheRustClientRefusesThem()
    {
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":true,\"result\":{}}\r"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"x\",\"ok\":false,\"error\":{\"code\":\"rejected\",\"message\":\"m\"}}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"\\u0069d\":\"r\",\"ok\":false,\"error\":{\"code\":\"rejected\",\"message\":\"m\"}}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":false,\"error\":{\"code\":\"rejected\",\"message\":\"m\"},\"extra\":1}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":\"false\",\"error\":{\"code\":\"rejected\",\"message\":\"m\"}}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":true,\"error\":{\"code\":\"rejected\",\"message\":\"m\"}}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":false,\"error\":{\"code\":\"rejected\",\"message\":\"m\",\"details\":null}}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":false,\"error\":{\"code\":\"\",\"message\":\"m\"}}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":false,\"error\":{\"code\":\"rejected\",\"message\":\"m\",\"hint\":\"h\"}}"));
        Assert.AreEqual(ContractErrorKind.SchemaMismatch, Refusal("{\"id\":\"r\",\"ok\":false,\"error\":{\"code\":\"noSuchCode\",\"message\":\"m\"}}"));
        Assert.AreEqual(ContractErrorKind.SchemaMismatch, Refusal("{\"id\":\"r\",\"ok\":true,\"result\":{\"unexpected\":true}}"));
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal("{\"id\":\"r\",\"ok\":true,\"result\":{}}", id: ""));
        var atLimit = "{\"id\":\"r\",\"ok\":true,\"result\":\"" + new string('x', ControlContract.MaxResponseBytes) + "\"}";
        Assert.AreEqual(ContractErrorKind.Malformed, Refusal(atLimit));
    }

    [TestMethod]
    public void RequestsAreCheckedLocallyAsTheRustDecoderChecksThem()
    {
        static ContractErrorKind Refused(ControlRequest request) => Assert.ThrowsExactly<ContractException>(() =>
        {
            var frame = Wire.EncodeRequestFrame(request);
            Wire.DecodeRequest(frame.AsSpan(0, frame.Length - 1));
        }).Kind;

        Assert.AreEqual(ContractErrorKind.UnknownMethod, Refused(ControlRequest.Create("r", "device.candidates")));
        Assert.AreEqual(ContractErrorKind.Malformed, Refused(ControlRequest.Create("", "health")));
        Assert.AreEqual(ContractErrorKind.Malformed, Refused(ControlRequest.Create("a\u001fb", "health")));
        Assert.AreEqual(ContractErrorKind.Malformed, Refused(ControlRequest.Create(new string('i', 129), "health")));
        Assert.AreEqual(ContractErrorKind.Malformed, Refused(ControlRequest.Create("r", "")));
        Assert.AreEqual(ContractErrorKind.UnsupportedVersion, Refused(new ControlRequest("2.0.0", ControlContract.ContractIdentity, "r", "health", null)));
        Assert.AreEqual(ContractErrorKind.ContractMismatch, Refused(new ControlRequest(ControlContract.ProtocolVersion, new string('0', 64), "r", "health", null)));
        Assert.AreEqual(ContractErrorKind.Malformed, Refused(ControlRequest.Create("\uD800", "health")));
    }
}

/// <summary>T0: this client's request bytes equal the recorded corpus, and every recorded
/// response replays through its decoder (the Rust <c>corpus_parity</c> replay).</summary>
[TestClass]
public sealed class WireCorpusTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    public void EveryRecordedRequestEncodesToTheRecordedBytes()
    {
        var all = new MemoryStream();
        var count = 0;
        foreach (var (method, index, line) in Corpus.Rows())
        {
            var raw = Corpus.RawParams(line) ?? "{}"u8.ToArray();
            // The committed recording omits transport ids and the handshake identity; they are
            // rebuilt exactly as corpus_parity.rs rebuilds them.
            var expected = Encoding.UTF8.GetBytes(
                    $"{{\"protocolVersion\":\"{ControlContract.ProtocolVersion}\",\"contractIdentity\":\"{ControlContract.ContractIdentity}\",\"id\":\"corpus-{index}\",\"method\":\"{method}\",\"params\":")
                .Concat(raw).Concat("}\n"u8.ToArray()).ToArray();
            var parameters = (JsonObject)StrictJson.Parse(raw);
            var actual = Wire.EncodeRequestFrame(ControlRequest.Create($"corpus-{index}", method, parameters));
            CollectionAssert.AreEqual(expected, actual, $"{method} row {index}");
            var decoded = Wire.DecodeRequest(actual.AsSpan(0, actual.Length - 1));
            Assert.AreEqual(method, decoded.Method);
            Assert.AreEqual(parameters, decoded.Params);
            all.Write(actual);
            count++;
        }
        var health = Wire.EncodeRequestFrame(ControlRequest.Create("health", "health"));
        all.Write(health);
        Assert.AreEqual(
            $"{{\"protocolVersion\":\"1.0.0\",\"contractIdentity\":\"{ControlContract.ContractIdentity}\",\"id\":\"health\",\"method\":\"health\"}}\n",
            Encoding.UTF8.GetString(health));
        // Compared with the Rust client's own encode_frame output in the run record.
        TestContext.WriteLine($"{count} corpus request frames + health: {all.Length} bytes, sha256 {Convert.ToHexStringLower(SHA256.HashData(all.ToArray()))}");
        Assert.IsTrue(count > 1000);
    }

    [TestMethod]
    public void EveryRecordedResponseReplaysThroughTheDecoder()
    {
        foreach (var (method, index, line) in Corpus.Rows())
        {
            var row = (JsonObject)StrictJson.Parse(line);
            var id = $"corpus-{index}";
            var ok = row["ok"].Equals(JsonBool.True);
            var wire = new JsonObject([new("id", new JsonString(id)), new("ok", JsonBool.Of(ok)), ok ? new("result", row["result"]) : new("error", row["error"])]);
            var response = Wire.DecodeResponse(Wire.EncodeFrame(wire, ControlContract.MaxResponseBytes).AsSpan()[..^1], id, method);
            Assert.AreEqual(ok, response.Ok, $"{method} row {index}");
            if (ok) Assert.AreEqual(row["result"], response.Result);
            if (method == "health")
            {
                // The original Swift health frame remains readable provenance,
                // but its old method surface must not negotiate as current.
                if (response.Result!["contractIdentity"] is JsonString
                    { Value: "1d7d101e83fe005f364c1e9273968b64d744c815eb39bc82d43a307ce046b633" })
                    Assert.AreEqual(ContractErrorKind.ContractMismatch,
                        Assert.ThrowsExactly<ContractException>(() => Wire.ValidateHealth(response)).Kind);
                else Wire.ValidateHealth(response);
            }
        }
    }

    [TestMethod]
    public void TypedRecordsRoundTripEveryRecordedValue()
    {
        var checkedValues = 0;
        foreach (var (method, index, line) in Corpus.Rows())
        {
            var row = StrictJson.Parse(line);
            var parameters = row is JsonObject o && o.TryGetValue("params", out var p) ? p : new JsonObject();
            var result = row["ok"].Equals(JsonBool.True) ? row["result"] : null;
            switch (method)
            {
                case "health":
                    Assert.AreEqual(parameters, TypedMethods.HealthRequestJson(TypedMethods.ParseHealthRequest(parameters)));
                    if (result is not null) Assert.AreEqual(result, TypedMethods.HealthResultJson(TypedMethods.ParseHealthResult(result)));
                    break;
                case "doctor":
                    Assert.AreEqual(parameters, TypedMethods.DoctorRequestJson(TypedMethods.ParseDoctorRequest(parameters)));
                    if (result is not null) Assert.AreEqual(result, TypedMethods.DoctorResultJson(TypedMethods.ParseDoctorResult(result)));
                    break;
                case "operation.list":
                    Assert.AreEqual(parameters, TypedMethods.OperationListRequestJson(TypedMethods.ParseOperationListRequest(parameters)));
                    if (result is not null) Assert.AreEqual(result, TypedMethods.OperationListResultJson(TypedMethods.ParseOperationListResult(result)));
                    break;
                case "device.observations":
                    Assert.AreEqual(parameters, TypedMethods.DeviceObservationsRequestJson(TypedMethods.ParseDeviceObservationsRequest(parameters)));
                    if (result is not null) Assert.AreEqual(result, TypedMethods.DeviceObservationsResultJson(TypedMethods.ParseDeviceObservationsResult(result)));
                    break;
                default:
                    continue;
            }
            checkedValues++;
        }
        Assert.IsTrue(checkedValues >= 4, $"{checkedValues} typed rows");
    }

    [TestMethod]
    public void TypedRecordsAreClosedAndKeepRequiredNullApartFromMissing()
    {
        var observation = (JsonObject)((JsonArray)Corpus.RecordedResult("device.observations")["observations"]).Items.FirstOrDefault()!;
        if (observation is null) Assert.Inconclusive("no recorded observation");
        var withExtra = new JsonObject(observation.Members.Append(new("unexpected", JsonBool.True)));
        Assert.AreEqual(ContractErrorKind.SchemaMismatch, Assert.ThrowsExactly<ContractException>(() => DeviceObservationsResultObservationsItem.Parse(withExtra)).Kind);
        var missing = new JsonObject(observation.Members.Where(m => m.Key != "displayName"));
        Assert.AreEqual(ContractErrorKind.SchemaMismatch, Assert.ThrowsExactly<ContractException>(() => DeviceObservationsResultObservationsItem.Parse(missing)).Kind);
        var explicitNull = new JsonObject(missing.Members.Append(new("displayName", JsonNull.Instance)));
        Assert.IsNull(DeviceObservationsResultObservationsItem.Parse(explicitNull).DisplayName);
    }
}
