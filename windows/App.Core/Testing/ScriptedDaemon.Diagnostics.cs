using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary><see cref="Jobs"/> with two saved Diagnostics records (<c>Recorded/diagnostics-workspace.json</c>):
    /// the diagnostics-inspect oracle's <c>capture.diagnostics@1</c> session and job-run-hilog's
    /// <c>analyzer.summarize-hilog@1</c> Job, each with its status, timeline, evidence, Artifacts
    /// and published bytes.</summary>
    public const string Diagnostics = "diagnostics";

    /// <summary>The recorded session Job (diagnostics-inspect, "inspectComplete").</summary>
    public const string DiagnosticSessionJobId = "job-6c545eb6042a9ea99e700467bbb77d06";

    /// <summary>The recorded HiLog summary Job (job-run-hilog).</summary>
    public const string HilogSummaryJobId = "job-ce57f7b014978fe39492cf64043a8fc9";

    private static readonly Lazy<JsonObject> DiagnosticsRecorded = new(() =>
    {
        using var stream = typeof(ScriptedDaemon).Assembly.GetManifestResourceStream("ArkDeck.Recorded.diagnostics-workspace.json")
                           ?? throw new InvalidOperationException("the recorded Diagnostics answers are missing");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return (JsonObject)StrictJson.Parse(buffer.ToArray());
    });

    private static JsonObject? DiagnosticRecord(string? jobId) => jobId switch
    {
        DiagnosticSessionJobId => (JsonObject)DiagnosticsRecorded.Value["session"],
        HilogSummaryJobId => (JsonObject)DiagnosticsRecorded.Value["hilog"],
        _ => null,
    };

    /// <summary>A recorded status restated as a <c>job.list</c> row (arkdeck.job-summary/1).</summary>
    private static string DiagnosticSummaryRow(JsonObject status) =>
        new JsonObject(status.Members
            .Select(m => m.Key == "schemaVersion" ? new KeyValuePair<string, JsonValue>(m.Key, new JsonString("arkdeck.job-summary/1")) : m)
            .Append(new KeyValuePair<string, JsonValue>("current", JsonBool.True))
            .Append(new KeyValuePair<string, JsonValue>("timeline", JsonNull.Instance))).ToString();

    private sealed partial class Script
    {
        /// <summary>A route of the <c>diagnostics</c> scenario, or null when the method is not one.</summary>
        private byte[]? DiagnosticsRoute(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            string? Owner() => parameters.TryGetValue("owner", out var o) && o is JsonObject owner && owner["id"] is JsonString id ? id.Value : null;
            switch (method)
            {
                case "job.list":
                    return Success(request, Parse(JobPage([
                        .. new[] { HilogSummaryJobId, DiagnosticSessionJobId }.Select(id => DiagnosticSummaryRow((JsonObject)DiagnosticRecord(id)!["status"])),
                        .. DebugJobRows(),
                        .. JobsNow().Select(j => JobJson(j, list: true)),
                    ])));
                case "job.status" when DiagnosticRecord(Param("jobId")) is { } record:
                    return Success(request, record["status"]);
                case "job.show" when DiagnosticRecord(Param("jobId")) is { } record:
                    return Success(request, record["show"]);
                case "job.evidence" when DiagnosticRecord(Param("jobId")) is { } record:
                    return Success(request, record["evidence"]);
                case "artifact.list" when DiagnosticRecord(Owner()) is { } record:
                    return Success(request, new JsonObject(
                    [
                        new("hasMore", JsonBool.False),
                        new("items", record["rows"]),
                        new("nextCursor", JsonNull.Instance),
                        new("order", new JsonString("createdAtDescArtifactIdAsc")),
                        new("pageKind", new JsonString("snapshot")),
                        new("schemaVersion", new JsonString("arkdeck.cli.page/1")),
                        new("snapshotRevision", new JsonString("0f5e0c1a-0000-4000-8000-00000000000d")),
                    ]));
                case "artifact.read" when DiagnosticRecord(Owner()) is { } record:
                {
                    var artifactId = Param("artifactId");
                    var row = ((JsonArray)record["rows"]).Items.Cast<JsonObject>().FirstOrDefault(r => ((JsonString)r["artifactId"]).Value == artifactId);
                    var stored = (JsonObject)record["bytes"];
                    if (row is null || ((JsonString)row["status"]).Value != "published" || !stored.TryGetValue(artifactId!, out var encoded))
                    {
                        return Failure(request, "resourceNotFound", "no published Artifact", ArtifactDetails);
                    }
                    var allow = parameters.TryGetValue("allowSensitive", out var a) && a is JsonBool { Value: true };
                    if (((JsonString)row["privacy"]).Value == "sensitive" && !allow)
                    {
                        return Failure(request, "sensitiveAccessDenied", "Sensitive Artifact access requires allowSensitive", ArtifactDetails);
                    }
                    var bytes = Convert.FromBase64String(((JsonString)encoded).Value);
                    var offset = (int)TypedJson.Int64(parameters["offset"]);
                    var count = Math.Max(0, Math.Min((int)TypedJson.Int64(parameters["maxBytes"]), bytes.Length - offset));
                    var next = offset + count;
                    return Success(request, new JsonObject(
                    [
                        new("artifactDigest", row["artifactDigest"]),
                        new("artifactId", new JsonString(artifactId!)),
                        new("base64", new JsonString(Convert.ToBase64String(bytes, offset, count))),
                        new("byteCount", JsonNumber.FromInt64(count)),
                        new("eof", JsonBool.Of(next == bytes.Length)),
                        new("nextOffset", JsonNumber.FromInt64(next)),
                        new("offset", JsonNumber.FromInt64(offset)),
                        new("totalByteCount", JsonNumber.FromInt64(bytes.Length)),
                    ]));
                }
                default:
                    return null;
            }
        }
    }
}
