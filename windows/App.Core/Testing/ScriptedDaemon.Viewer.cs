using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary><see cref="Jobs"/> with the HDC provider's read-only probes and captures, as the
    /// macOS daemon answers them (<c>Recorded/viewer-workspace.json</c>): <c>trace.probe</c> reports
    /// the recorded captureEligible adapter; a Trace capture publishes the recorded raw Trace, a
    /// UI dump capture the recorded screenshot, component tree and dump, a component-detail capture
    /// the recorded advanced dump. <c>trace.inspect</c> is refused as on Windows today.</summary>
    public const string Viewer = "viewer";

    private static readonly Lazy<JsonObject> ViewerRecorded = new(() =>
    {
        using var stream = typeof(ScriptedDaemon).Assembly.GetManifestResourceStream("ArkDeck.Recorded.viewer-workspace.json")
                           ?? throw new InvalidOperationException("the recorded Trace and UI dump answers are missing");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return (JsonObject)StrictJson.Parse(buffer.ToArray());
    });

    private sealed partial class Script
    {
        /// <summary>A route of the <c>viewer</c> scenario, or null when the method is not one.</summary>
        private byte[]? ViewerRoute(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            var recorded = ViewerRecorded.Value;
            switch (method)
            {
                case "trace.probe":
                    return Param("targetId") == FixtureTargetId
                        ? Success(request, Rebind((JsonObject)Parse(recorded["probe"].ToString().Replace(OracleTargetId, FixtureTargetId, StringComparison.Ordinal))))
                        : Failure(request, "rejected", $"Trace Runtime probe failed: target {Param("targetId")} has not been adopted");
                case "artifact.list":
                {
                    var jobId = ((JsonString)((JsonObject)parameters["owner"])["id"]).Value;
                    if (CaptureOf(jobId) is not { } capture) return null;
                    var rows = capture.Rows.Select(r => (JsonValue)Owned(r, jobId));
                    return Success(request, new JsonObject(
                    [
                        new("hasMore", JsonBool.False),
                        new("items", new JsonArray(rows)),
                        new("nextCursor", JsonNull.Instance),
                        new("order", new JsonString("createdAtDescArtifactIdAsc")),
                        new("pageKind", new JsonString("snapshot")),
                        new("schemaVersion", new JsonString("arkdeck.cli.page/1")),
                        new("snapshotRevision", new JsonString("0f5e0c1a-0000-4000-8000-00000000000a")),
                    ]));
                }
                case "artifact.read":
                {
                    var jobId = ((JsonString)((JsonObject)parameters["owner"])["id"]).Value;
                    if (CaptureOf(jobId) is not { } capture) return null;
                    var artifactId = Param("artifactId");
                    var row = capture.Rows.FirstOrDefault(r => ((JsonString)r["artifactId"]).Value == artifactId);
                    if (row is null || ((JsonString)row["status"]).Value != "published" || !capture.Bytes.TryGetValue(artifactId!, out var encoded))
                    {
                        return Failure(request, "resourceNotFound", "no published Artifact", ArtifactDetails);
                    }
                    var allow = parameters.TryGetValue("allowSensitive", out var a) && a is JsonBool { Value: true };
                    if (((JsonString)row["privacy"]).Value == "sensitive" && !allow)
                    {
                        return Failure(request, "sensitiveAccessDenied", "Sensitive Artifact access requires allowSensitive", ArtifactDetails);
                    }
                    var bytes = Convert.FromBase64String(encoded);
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

        /// <summary>The recorded Artifacts of a submitted capture, by the legs its request selected.</summary>
        private (IReadOnlyList<JsonObject> Rows, IReadOnlyDictionary<string, string> Bytes)? CaptureOf(string jobId)
        {
            var job = _debugJobs.FirstOrDefault(j => j.Id == jobId);
            if (job.Id is null || job.Operation != "capture.diagnostics@1" || job.State != "succeeded") return null;
            var inputs = (JsonObject)((JsonObject)Parse(job.Request))["inputs"];
            bool On(string key) => inputs.TryGetValue(key, out var v) && v is JsonBool { Value: true };
            var recorded = ViewerRecorded.Value;
            JsonObject? leg = inputs.ContainsKey("traceCategories") ? (JsonObject)recorded["trace"]
                : On("advancedDump") ? null
                : On("uiDump") ? (JsonObject)recorded["uiDump"]
                : null;
            if (leg is not null)
            {
                return (((JsonArray)leg["artifacts"]).Items.Cast<JsonObject>().ToArray(),
                    ((JsonObject)leg["bytes"]).Members.ToDictionary(m => m.Key, m => ((JsonString)m.Value).Value, StringComparer.Ordinal));
            }
            if (!On("advancedDump")) return null;
            var advanced = (JsonObject)recorded["advancedDump"];
            var row = (JsonObject)advanced["artifact"];
            return ([row], new Dictionary<string, string>(StringComparer.Ordinal) { [((JsonString)row["artifactId"]).Value] = ((JsonString)advanced["bytes"]).Value });
        }

        /// <summary>A recorded Artifact row owned by the submitted Job on the fixture Target.</summary>
        private static JsonObject Owned(JsonObject row, string jobId)
        {
            var text = row.ToString().Replace(OracleTargetId, FixtureTargetId, StringComparison.Ordinal);
            var rebound = Rebind((JsonObject)Parse(text));
            return new JsonObject(rebound.Members.Select(m => m.Key switch
            {
                "owner" => new KeyValuePair<string, JsonValue>("owner", new JsonObject([new("id", new JsonString(jobId)), new("kind", new JsonString("job"))])),
                "lease" when m.Value is JsonString => new KeyValuePair<string, JsonValue>("lease", new JsonString($"lease-v1:{jobId}:{((JsonString)rebound["artifactId"]).Value}")),
                _ => m,
            }));
        }
    }
}
