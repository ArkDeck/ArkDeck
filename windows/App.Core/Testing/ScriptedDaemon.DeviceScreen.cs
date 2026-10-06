using System.Formats.Tar;
using System.Globalization;
using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary>Host-only Device UI/encoder fixture. Uses recorded image bytes and synthetic
    /// typed Jobs/products; it has no Runtime, transport, device or hardware-evidence authority.</summary>
    public const string DeviceScreen = "device-screen";
    private static readonly Lazy<JsonObject> ScreenDescriptions = new(() =>
    {
        using var stream = typeof(ScriptedDaemon).Assembly.GetManifestResourceStream("ArkDeck.Recorded.device-screen-descriptions.json")
            ?? throw new InvalidOperationException("The host-only Device descriptor fixture is missing");
        using var bytes = new MemoryStream();
        stream.CopyTo(bytes);
        return (JsonObject)StrictJson.Parse(bytes.ToArray());
    });

    private sealed partial class Script
    {
        private readonly Dictionary<string, JsonObject> _screenRequests = [];
        private readonly HashSet<string> _screenCompleted = [];
        private readonly Dictionary<string, ScriptedArtifact[]> _screenProducts = [];
        private byte[]? DeviceScreenRoute(JsonObject request, string method)
        {
            var parameters = request["params"] as JsonObject ?? new();
            string? Text(string key) => parameters[key] is JsonString s ? s.Value : null;
            switch (method)
            {
                case "operation.list":
                    return Success(request, new JsonArray(DeviceOperations.All.Select(op => Parse($$"""{"reference":"{{op}}","canonicalReference":"{{op}}","aliasFor":null,"availability":"available","binding":"confirmedDevice","minimumEffect":"{{(op==DeviceOperations.Capture ? "readOnly" : "deviceMutation")}}","profiles":["openharmony-standard@1","dayu200"],"reasonCodes":[],"reasonOrigins":[],"reasons":[]}"""))));
                case "operation.describe":
                {
                    var reference = Text("reference");
                    if (reference is null || !DeviceOperations.All.Contains(reference)) return null;
                    return Success(request, ScreenDescriptions.Value[reference]);
                }
                case "artifact.quota":
                    return Success(request, Parse("""{"totalBytes":1073741824,"usedBytes":0,"remainingBytes":1073741824}"""));
                case "job.submit":
                {
                    if (Request(Text("requestJson")) is not { } document || !DeviceOperations.All.Contains(Operation(document))
                        || Target(document) is not (FixtureTargetId, 3)
                        || document["clientContext"]["clientName"] is not JsonString { Value: DeviceOperations.Client })
                        return Failure(request, "invalidInput", "Not the fixed Device fixture intent");
                    var id = "job-" + Guid.NewGuid().ToString("N");
                    _screenRequests.Add(id, document);
                    return Success(request, Parse($$"""{"schemaVersion":"arkdeck.job-acceptance/1","jobId":"{{id}}","deduplicated":false,"newDispatchCount":0}"""));
                }
                case "job.run":
                {
                    var id = Text("jobId");
                    if (id is null || !_screenRequests.TryGetValue(id, out var document)) return null;
                    if (!_screenCompleted.Add(id)) return Failure(request, "conflict", "The fixture intent was already run");
                    _screenProducts[id] = ScreenFixtureProducts(id, document);
                    return Success(request, ScreenStatus(id));
                }
                case "job.status":
                    return Text("jobId") is { } statusId && _screenRequests.ContainsKey(statusId) ? Success(request, ScreenStatus(statusId)) : null;
                case "job.show":
                {
                    var id = Text("jobId");
                    if (id is null || !_screenRequests.TryGetValue(id, out var document)) return null;
                    var operation = Operation(document);
                    var proof = operation == "input.keyboard@1" ? "verified inject-keyboard-input [acknowledgement]"
                        : operation.StartsWith("input.", StringComparison.Ordinal) ? "verified inject-pointer-input [acknowledgement]" : "verified fixture-capture [wholeBytes]";
                    return Success(request, Parse($$$"""{"schemaVersion":"arkdeck.job/1","request":{{{document}}},"catalogDigest":"{{{new string('c',64)}}}","providerId":"hdc","materializedPlanDigest":"{{{Sha256Hex(CanonicalJson.Encode(document))}}}","materializedBindingRevision":3,"materializedStableIdentitySha256":"{{{ScreenIdentity}}}","actualStepKinds":null,"events":{"method":"job.events","jobId":"{{{id}}}"},"evidence":{"method":"job.evidence","jobId":"{{{id}}}"},"ringCoverage":null,"screenSequence":null,"job":{{{ScreenStatus(id)}}},"timeline":{"kind":"inline","entries":["{{{(_screenCompleted.Contains(id) ? proof : "jobCreated")}}}"]}}"""));
                }
                case "artifact.list":
                {
                    var id = parameters["owner"]["id"] is JsonString s ? s.Value : null;
                    if (id is null || !_screenProducts.TryGetValue(id, out var products)) return null;
                    var rows = products.Select(a => new JsonObject(((JsonObject)Parse(a.Json())).Members.Select(m => m.Key == "binding"
                        ? new KeyValuePair<string, JsonValue>(m.Key, Parse($$"""{"bindingRevision":3,"stableIdentitySha256":"{{ScreenIdentity}}","targetId":"{{FixtureTargetId}}"}""")) : m)));
                    return Success(request, Parse($$"""{"schemaVersion":"arkdeck.cli.page/1","items":[{{string.Join(',',rows)}}],"hasMore":false,"nextCursor":null,"snapshotRevision":"fixture-screen-products","order":"createdAtDescArtifactIdAsc","pageKind":"snapshot"}"""));
                }
                case "artifact.read":
                {
                    var id = parameters["owner"]["id"] is JsonString s ? s.Value : null;
                    if (id is null || !_screenProducts.TryGetValue(id, out var products)) return null;
                    var product = products.SingleOrDefault(p => p.Id == Text("artifactId"));
                    if (product is null) return Failure(request, "resourceNotFound", "No fixture product", ArtifactDetails);
                    if (product.Privacy == "sensitive" && parameters["allowSensitive"] is not JsonBool { Value: true })
                        return Failure(request, "sensitiveAccessDenied", "Sensitive fixture read requires consent", ArtifactDetails);
                    var offset = (int)TypedJson.Int64(parameters["offset"]);
                    var count = Math.Min((int)TypedJson.Int64(parameters["maxBytes"]), product.Bytes.Length - offset);
                    return Success(request, Parse($$"""{"artifactId":"{{product.Id}}","artifactDigest":"{{product.Sha256}}","offset":{{offset}},"byteCount":{{count}},"totalByteCount":{{product.Bytes.Length}},"nextOffset":{{offset+count}},"eof":{{(offset+count==product.Bytes.Length ? "true" : "false")}},"base64":"{{Convert.ToBase64String(product.Bytes,offset,count)}}"}"""));
                }
                default: return null;
            }
        }
        private string ScreenIdentity => Sha256Hex(System.Text.Encoding.ASCII.GetBytes(TargetFacts(FixtureTargetId).Connect));
        private JsonValue ScreenStatus(string id) => Parse(JobJson((id, Operation(_screenRequests[id]),
            _screenCompleted.Contains(id) ? "succeeded" : "queued", "2026-10-06T10:00:00Z"), list: false));
        private static ScriptedArtifact[] ScreenFixtureProducts(string jobId, JsonObject document)
        {
            var operation = Operation(document);
            if (operation.StartsWith("input.", StringComparison.Ordinal)) return [];
            var recorded = ViewerRecorded.Value["uiDump"];
            var image = ((JsonArray)recorded["artifacts"]).Items.Single(r => r["name"] is JsonString { Value: "screenshot.png" });
            var bytes = Convert.FromBase64String(((JsonString)recorded["bytes"][((JsonString)image["artifactId"]).Value]).Value);
            ScriptedArtifact Product(string suffix, string name, string media, string privacy, byte[] content) => new(jobId, "artifact-screen-"+suffix, name, media, privacy, "published", operation, content);
            if (operation == DeviceOperations.Capture) return [Product("image", "screenshot.png", "image/png", "sensitive", bytes)];
            var count = (int)TypedJson.Int64(document["inputs"]["frameCount"]);
            using var archive = new MemoryStream();
            using (var writer = new TarWriter(archive, TarEntryFormat.Ustar, leaveOpen: true))
                for (var i=1; i<=count; i++) writer.WriteEntry(new UstarTarEntry(TarEntryType.RegularFile, i.ToString("D4",CultureInfo.InvariantCulture)+".png") { DataStream = new MemoryStream(bytes) });
            var sequence = System.Text.Encoding.UTF8.GetBytes($$"""{"schemaVersion":"1.0.0","requestedFrameCount":{{count}},"capturedFrameCount":{{count}},"framesMissing":0,"frameDurationsSeconds":[{{string.Join(',',Enumerable.Repeat("0.5",count))}}],"observedFramesPerSecond":2}""");
            return [Product("frames", "frames.tar", "application/x-tar", "sensitive", archive.ToArray()), Product("sequence", "sequence.json", "application/json", "standard", sequence)];
        }
    }
}
