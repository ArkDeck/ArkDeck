using System.Text;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary>A daemon with the ArkForge lane and the flash-bundle validator composed, as the
    /// macOS daemon is: the recorded Flash oracles answer (<c>Recorded/flash-workspace.json</c>).</summary>
    public const string Flash = "flash";

    private static readonly Lazy<JsonObject> FlashRecorded = new(() =>
    {
        using var stream = typeof(ScriptedDaemon).Assembly.GetManifestResourceStream("ArkDeck.Recorded.flash-workspace.json")
                           ?? throw new InvalidOperationException("the recorded Flash answers are missing");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return (JsonObject)StrictJson.Parse(buffer.ToArray());
    });

    /// <summary>The recorded answer with its Target and binding rewritten to the scenario's.</summary>
    private static JsonObject ForFixtureTarget(JsonValue recorded)
    {
        var text = recorded.ToString().Replace("TGT-83405c84ff74", FixtureTargetId, StringComparison.Ordinal)
            .Replace("TGT-HOST", FixtureTargetId, StringComparison.Ordinal);
        return Rebind((JsonObject)Parse(text));
    }

    private static JsonObject Rebind(JsonObject o) => new(o.Members.Select(m => new KeyValuePair<string, JsonValue>(m.Key,
        m.Key == "bindingRevision" && m.Value is JsonNumber ? JsonNumber.FromInt64(3)
        : m.Value is JsonObject inner ? Rebind(inner) : m.Value)));

    private sealed partial class Script
    {
        /// <summary>A Flash route of the <c>flash</c> scenario, or null when the method is not one.</summary>
        private byte[]? FlashRoute(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            var recorded = FlashRecorded.Value;
            switch (method)
            {
                case "operation.list":
                    return Success(request, new JsonArray([.. ((JsonArray)DebugRecorded.Value["list"]).Items, recorded["list"]]));
                case "operation.describe" when Param("reference") == "flash.full-restore@1":
                    return Success(request, recorded["describe"]);
                case "flash.device-access":
                    return Success(request, recorded["deviceAccess"]);
                case "flash.bootloader-status":
                    return Success(request, ForFixtureTarget(recorded["bootloader"]));
                case "flash.prerequisites":
                    return Param("targetId") == FixtureTargetId ? Success(request, ForFixtureTarget(recorded["prerequisites"]))
                        : Failure(request, "notFound", "target is not adopted");
                case "flash.lanePlanPreview":
                    return Success(request, ForFixtureTarget(recorded["lanePreview"]));
                case "job.plan":
                {
                    if (Request(Param("requestJson")) is not { } document || Operation(document) != "flash.full-restore@1") return null;
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    var plan = ForFixtureTarget(recorded["plan"]);
                    return Success(request, new JsonObject(plan.Members.Where(m => m.Key != "inputs").Append(new("inputs", document["inputs"]))));
                }
                case "job.submit":
                {
                    if (Request(Param("requestJson")) is not { } document || Operation(document) != "flash.full-restore@1") return null;
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    if (!document.ContainsKey("reviewedPlanDigest")) return Failure(request, "invalidInput", "a destructive Flash needs its reviewed plan digest");
                    var id = "job-" + Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());
                    _debugJobs.Add((id, "flash.full-restore@1", "queued", Param("requestJson")!));
                    return Success(request, Parse($$"""{"deduplicated":false,"jobId":"{{id}}","newDispatchCount":0,"schemaVersion":"arkdeck.job-acceptance/1"}"""));
                }
                case "job.evidence":
                {
                    var job = _debugJobs.FirstOrDefault(j => j.Id == Param("jobId") && j.Operation == "flash.full-restore@1");
                    if (job.Id is null) return null;
                    var text = ForFixtureTarget(recorded["evidence"]).ToString().Replace((((JsonString)((JsonObject)recorded["evidence"])["jobId"]).Value), job.Id,
                        StringComparison.Ordinal);
                    return Success(request, Parse(text));
                }
                default:
                    return null;
            }
        }

        /// <summary>The Flash Job's recorded run answer, for <see cref="DebugStatus"/>.</summary>
        private static JsonObject FlashRun => ForFixtureTarget(FlashRecorded.Value["run"]);
    }
}
