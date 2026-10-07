using System.Text;
using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary>Software-only bounded control flow. Artifacts derive from the committed fake-provider fixture; no device is contacted.</summary>
    public const string DiagnosticCapture = "diagnostic-capture";
    public const string InteractiveDiagnosticJobId = "job-859b86ab3981a6c5194e9a6c77ac9667";
    private static readonly Lazy<JsonObject> InteractiveDiagnosticFixture = new(() => CaptureResource("diagnostic-session-interactive.json"));
    private static readonly Lazy<JsonObject> InteractiveDiagnosticDescription = new(() => CaptureResource("diagnostic-session-description.json"));

    private static JsonObject CaptureResource(string name)
    {
        using var stream = typeof(ScriptedDaemon).Assembly.GetManifestResourceStream("ArkDeck.Recorded." + name)
            ?? throw new InvalidOperationException("the software Diagnostic Session fixture is missing");
        using var bytes = new MemoryStream(); stream.CopyTo(bytes);
        return (JsonObject)StrictJson.Parse(bytes.ToArray());
    }

    private static JsonObject CaptureWith(JsonObject original, params (string Key, JsonValue Value)[] replacements)
    {
        var replaced = replacements.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal);
        return new(original.Members.Select(p => replaced.Remove(p.Key, out var value) ? new(p.Key, value) : p)
            .Concat(replaced.Select(p => new KeyValuePair<string, JsonValue>(p.Key, p.Value))));
    }

    private sealed partial class Script
    {
        private string? _interactiveRequest;
        private bool _interactiveStarted;
        private bool _interactiveClosed;
        private readonly List<string> _interactiveMarkers = [];

        private byte[]? DiagnosticCaptureRoute(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            string? Owner() => parameters.TryGetValue("owner", out var v) && v is JsonObject o ? ((JsonString)o["id"]).Value : null;
            switch (method)
            {
                case "device.observations":
                    return Success(request, Parse(ObservationsNow().Replace(FixtureTargetId, OracleTargetId, StringComparison.Ordinal)
                        .Replace("\"bindingRevision\":3", "\"bindingRevision\":1", StringComparison.Ordinal)));
                case "target.list": return Target(request, method, [OracleTargetId]);
                case "target.show":
                case "target.availability": return Target(request, method, [OracleTargetId]);
                case "operation.list":
                    return Success(request, Parse("""[{"reference":"capture.diagnostic-session@1","canonicalReference":"capture.diagnostic-session@1","aliasFor":null,"availability":"available","binding":"confirmedDevice","minimumEffect":"deviceMutation","profiles":["openharmony-standard@1","dayu200"],"reasons":[],"reasonCodes":[],"reasonOrigins":[]}]"""));
                case "operation.describe" when Param("reference") == DiagnosticCaptureProvider.Operation:
                    return Success(request, CaptureWith(InteractiveDiagnosticDescription.Value, ("availability", new JsonString("available")),
                        ("availabilityReasons", new JsonArray([])), ("availabilityReasonCodes", new JsonArray([])), ("availabilityReasonOrigins", new JsonArray([]))));
                case "trace.probe":
                    return Param("targetId") == OracleTargetId ? Success(request, ViewerRecorded.Value["probe"]) : Failure(request, "rejected", "wrong fixture Target");
                case "artifact.quota":
                    return Success(request, Parse("""{"totalBytes":536870912,"usedBytes":0,"remainingBytes":536870912}"""));
                case "job.list":
                    return Success(request, Parse(JobPage(_interactiveRequest is null ? [] : [DiagnosticSummaryRow(InteractiveStatus())])));
                case "job.submit":
                {
                    if (_interactiveRequest is not null) return Failure(request, "rejected", "the one-shot fixture Job was already submitted");
                    var text = Param("requestJson");
                    if (text is null || Parse(text) is not JsonObject document || Operation(document) != DiagnosticCaptureProvider.Operation
                        || Target(document) is not (OracleTargetId, 1) || document.ContainsKey("authorization") || document.ContainsKey("campaignReservation"))
                        return Failure(request, "invalidInput", "wrong bounded fixture request");
                    _interactiveRequest = text;
                    return Success(request, Parse($$"""{"schemaVersion":"arkdeck.job-acceptance/1","jobId":"{{InteractiveDiagnosticJobId}}","deduplicated":false,"newDispatchCount":0}"""));
                }
                case "job.run" when Param("jobId") == InteractiveDiagnosticJobId && _interactiveRequest is not null:
                    if (_interactiveStarted) return Failure(request, "rejected", "the one-shot fixture Job was already run");
                    _interactiveStarted = true;
                    return Success(request, InteractiveStatus());
                case "diagnostic.session.status":
                case "diagnostic.session.mark":
                case "diagnostic.session.stop":
                    if (Param("jobId") != InteractiveDiagnosticJobId || _interactiveRequest is null) return Failure(request, "notFound", "not this accepted fixture Job");
                    if (method == "diagnostic.session.mark")
                    {
                        if (!_interactiveStarted || _interactiveClosed || Param("markerId") is not { Length: > 0 } marker)
                            return Failure(request, "conflict", "fixture is not recording");
                        if (!_interactiveMarkers.Contains(marker)) _interactiveMarkers.Add(marker);
                    }
                    if (method == "diagnostic.session.stop") _interactiveClosed = true;
                    return Success(request, InteractiveSnapshot());
                case "job.cancel" when Param("jobId") == InteractiveDiagnosticJobId && !_interactiveStarted:
                    _interactiveClosed = true;
                    return Success(request, Parse("""{"cancelRequested":true}"""));
                case "job.status" when Param("jobId") == InteractiveDiagnosticJobId:
                    return Success(request, InteractiveStatus());
                case "job.show" when Param("jobId") == InteractiveDiagnosticJobId:
                    return Success(request, InteractiveShow());
                case "job.evidence" when Param("jobId") == InteractiveDiagnosticJobId:
                    return Success(request, InteractiveEvidence());
                case "artifact.list" when Owner() == InteractiveDiagnosticJobId:
                    return Success(request, Parse($$"""{"schemaVersion":"arkdeck.cli.page/1","hasMore":false,"items":{{InteractiveRows()}},"nextCursor":null,"order":"createdAtDescArtifactIdAsc","pageKind":"snapshot","snapshotRevision":"0f5e0c1a-0000-4000-8000-00000000001d"}"""));
                case "artifact.read" when Owner() == InteractiveDiagnosticJobId:
                {
                    var rows = InteractiveRows().Items.Cast<JsonObject>();
                    var row = rows.FirstOrDefault(r => ((JsonString)r["artifactId"]).Value == Param("artifactId"));
                    if (row is null || !InteractiveDocuments().TryGetValue(((JsonString)row["name"]).Value, out var bytes))
                        return Failure(request, "resourceNotFound", "the fixture contains only derived document bytes", ArtifactDetails);
                    var offset = checked((int)TypedJson.Int64(parameters["offset"]));
                    var count = Math.Max(0, Math.Min(checked((int)TypedJson.Int64(parameters["maxBytes"])), bytes.Length - offset));
                    return Success(request, Parse($$"""{"artifactDigest":{{row["artifactDigest"]}},"artifactId":{{row["artifactId"]}},"base64":"{{Convert.ToBase64String(bytes,offset,count)}}","byteCount":{{count}},"eof":{{(offset+count==bytes.Length?"true":"false")}},"nextOffset":{{offset+count}},"offset":{{offset}},"totalByteCount":{{bytes.Length}}}"""));
                }
                default: return null;
            }
        }

        private JsonObject InteractiveSnapshot()
        {
            var inputs = _interactiveRequest is null ? InteractiveDiagnosticFixture.Value["typedParameters"] : Parse(_interactiveRequest)["inputs"];
            var marks = new JsonArray(_interactiveMarkers.Select(id => Parse($$"""{"markerId":"{{id}}","atHostUTC":"2026-10-04T07:56:45.626Z","offsetMs":21}""")));
            return Parse($$"""{"schemaVersion":"1.0.0","jobId":"{{InteractiveDiagnosticJobId}}","targetId":"{{OracleTargetId}}","bindingRevision":1,"state":"{{(_interactiveClosed?"closed":_interactiveStarted?"recording":"preparing")}}","jobState":"{{(_interactiveClosed?"succeeded":_interactiveStarted?"running":"queued")}}","outcomeUnknown":false,"controlAvailable":{{(_interactiveStarted&&!_interactiveClosed?"true":"false")}},"maximumSeconds":{{inputs["durationSeconds"]}},"maximumMarkers":{{(inputs is JsonObject o && o.TryGetValue("maximumMarkers",out var max)?max:JsonNumber.FromInt64(50))}},"elapsedMs":63,"stopRequested":{{(_interactiveClosed?"true":"false")}},"armedAtHostUTC":{{(_interactiveStarted?"\"2026-10-04T07:56:45.604Z\"":"null")}},"endedAtHostUTC":{{(_interactiveClosed?"\"2026-10-04T07:56:45.668Z\"":"null")}},"markers":{{marks}}}""") as JsonObject ?? throw new InvalidOperationException();
        }

        private JsonObject InteractiveStatus()
        {
            var old = (JsonObject)DiagnosticRecord(DiagnosticSessionJobId)!["status"];
            var state = _interactiveClosed ? "succeeded" : _interactiveStarted ? "running" : "queued";
            return CaptureWith(old, ("jobId", new JsonString(InteractiveDiagnosticJobId)), ("operation", new JsonString(DiagnosticCaptureProvider.Operation)),
                ("targetId", new JsonString(OracleTargetId)), ("sessionId", new JsonString("session-" + InteractiveDiagnosticJobId)),
                ("workspaceKind", new JsonString("diagnostics")), ("state", new JsonString(state)), ("outcomeUnknown", JsonBool.False),
                ("waitingForHuman", JsonBool.False), ("outstandingResidueCount", JsonNumber.FromInt64(0)), ("failure", JsonNull.Instance),
                ("outcome", new JsonString(state)));
        }

        private JsonObject InteractiveShow()
        {
            var old = (JsonObject)DiagnosticRecord(DiagnosticSessionJobId)!["show"];
            return CaptureWith(old, ("job", InteractiveStatus()), ("materializedBindingRevision", JsonNumber.FromInt64(1)),
                ("catalogDigest", new JsonString(new string('a', 64))),
                ("materializedStableIdentitySha256", new JsonString(Sha256Hex(Encoding.ASCII.GetBytes(TargetFacts(OracleTargetId).Connect)))),
                ("materializedPlanDigest", new JsonString(Sha256Hex(Encoding.UTF8.GetBytes(_interactiveRequest ?? "fixture-not-admitted")))),
                ("request", _interactiveRequest is null ? old["request"] : StoredRequest(_interactiveRequest)),
                ("events", Parse($$"""{"jobId":"{{InteractiveDiagnosticJobId}}","method":"job.events"}""")),
                ("evidence", Parse($$"""{"jobId":"{{InteractiveDiagnosticJobId}}","method":"job.evidence"}""")));
        }

        private JsonObject InteractiveEvidence() => CaptureWith((JsonObject)DiagnosticRecord(DiagnosticSessionJobId)!["evidence"],
            ("catalogDigest", new JsonString(new string('a', 64))),
            ("jobId", new JsonString(InteractiveDiagnosticJobId)), ("operationReference", new JsonString(DiagnosticCaptureProvider.Operation)),
            ("targetId", new JsonString(OracleTargetId)), ("bindingRevision", JsonNumber.FromInt64(1)), ("terminalState", new JsonString("succeeded")),
            ("status", new JsonString("verified")), ("parameters", Parse(_interactiveRequest!)["inputs"]), ("outcomeUnknown", JsonBool.False));

        private Dictionary<string, byte[]> InteractiveDocuments()
        {
            var documents = ((JsonObject)InteractiveDiagnosticFixture.Value["documents"]).Members
                .ToDictionary(p => p.Key, p => Encoding.UTF8.GetBytes(((JsonString)p.Value).Value), StringComparer.Ordinal);
            var markerDoc = (JsonObject)StrictJson.Parse(documents["markers.json"]);
            var marks = new JsonArray(_interactiveMarkers.Select(id => Parse($$"""{"kind":"manual","markerId":"{{id}}","atHostUTC":"2026-10-04T07:56:45.626Z","offsetFromReadyMs":21}""")));
            documents["markers.json"] = Encoding.UTF8.GetBytes(CaptureWith(markerDoc, ("markers", marks)).ToString());
            return documents;
        }

        private JsonArray InteractiveRows()
        {
            if (!_interactiveClosed) return new JsonArray([]);
            var documents = InteractiveDocuments();
            return new JsonArray(((JsonArray)InteractiveDiagnosticFixture.Value["inventory"]).Items.Cast<JsonObject>().Select(row =>
                documents.TryGetValue(((JsonString)row["name"]).Value, out var bytes)
                    ? CaptureWith(row, ("byteCount", JsonNumber.FromInt64(bytes.Length)), ("artifactDigest", new JsonString(Sha256Hex(bytes)))) : row));
        }
    }
}
