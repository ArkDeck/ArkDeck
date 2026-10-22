using System.Text;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary>A daemon with the ArkForge lane and the flash-bundle validator composed, as the
    /// macOS daemon is: the recorded Flash oracles answer (<c>Recorded/flash-workspace.json</c>).</summary>
    public const string Flash = "flash";

    /// <summary><see cref="Flash"/> whose <c>flash.device-access</c> is the typed ArkForge
    /// handshake refusal (<c>PROTOCOL_REFUSED</c>).</summary>
    public const string FlashHandshake = "flash-handshake";

    /// <summary><see cref="Flash"/> whose verify maintenance returns exit 7 (content mismatch).</summary>
    public const string FlashVerifyExit7 = "flash-verify-exit-7";

    /// <summary><see cref="Flash"/> whose verify maintenance returns exit 9 (typed skip).</summary>
    public const string FlashVerifyExit9 = "flash-verify-exit-9";

    /// <summary>The finished Flash a verify scenario offers as the maintenance source.</summary>
    public const string VerifySourceJobId = "job-fixture-flash-source";

    /// <summary>The Job id <c>job.submit</c> of a scripted verify returns.</summary>
    public const string VerifyJobId = "job-fixture-verify";

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
                    return scenario == FlashHandshake
                        ? Failure(request, "unsupportedProtocolVersion", "ArkForge PROTOCOL_REFUSED: protocol major 2 is not compatible with 1")
                        : Success(request, recorded["deviceAccess"]);
                case "flash.bootloader-status":
                    return Success(request, ForFixtureTarget(recorded["bootloader"]));
                case "flash.prerequisites":
                    return Param("targetId") == FixtureTargetId ? Success(request, ForFixtureTarget(recorded["prerequisites"]))
                        : Failure(request, "notFound", "target is not adopted");
                case "flash.lanePlanPreview":
                    return Success(request, ForFixtureTarget(recorded["lanePreview"]));
                case "job.plan":
                {
                    if (Request(Param("requestJson")) is not { } document) return null;
                    if (Operation(document) == "flash.verify@1" && scenario is FlashVerifyExit7 or FlashVerifyExit9)
                    {
                        if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                        return Success(request, Parse(VerifyPlanJson));
                    }
                    if (Operation(document) != "flash.full-restore@1") return null;
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    var plan = ForFixtureTarget(recorded["plan"]);
                    return Success(request, new JsonObject(plan.Members.Where(m => m.Key != "inputs").Append(new("inputs", document["inputs"]))));
                }
                case "job.submit":
                {
                    if (Request(Param("requestJson")) is not { } document) return null;
                    if (Operation(document) == "flash.verify@1" && scenario is FlashVerifyExit7 or FlashVerifyExit9)
                    {
                        if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                        return Success(request, Parse($$"""{"deduplicated":false,"jobId":"{{VerifyJobId}}","newDispatchCount":0,"schemaVersion":"arkdeck.job-acceptance/1"}"""));
                    }
                    if (Operation(document) != "flash.full-restore@1") return null;
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    if (!document.ContainsKey("reviewedPlanDigest")) return Failure(request, "invalidInput", "a destructive Flash needs its reviewed plan digest");
                    var id = "job-" + Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());
                    _debugJobs.Add((id, "flash.full-restore@1", "queued", Param("requestJson")!));
                    return Success(request, Parse($$"""{"deduplicated":false,"jobId":"{{id}}","newDispatchCount":0,"schemaVersion":"arkdeck.job-acceptance/1"}"""));
                }
                case "job.run" when Param("jobId") == VerifyJobId && scenario is FlashVerifyExit7 or FlashVerifyExit9:
                    return Success(request, Parse(JobJson((VerifyJobId, "flash.verify@1", "succeeded", "2026-09-30T08:06:00Z"), list: false)));
                case "job.show" when Param("jobId") == VerifyJobId && scenario is FlashVerifyExit7 or FlashVerifyExit9:
                    return VerifyJobShow(request, scenario == FlashVerifyExit7);
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

        private const string VerifyPlanJson =
            """{"executionMode":"planOnly","jobAdmitted":false,"dispatchDisposition":"notDispatched","materializedPlanDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","operation":"flash.verify@1","bindingRevision":3,"providerId":"arkforge","effectiveEffect":"readOnly","targetId":"TGT-FIXTURE-1","inputs":{},"steps":[{"stepId":"verify-readback","kind":"read","effect":"readOnly"}]}""";

        /// <summary><c>job.show</c> of the scripted verify, with the verification document on the
        /// status object the Flash page reads as <c>maintenanceResult</c>.</summary>
        private byte[] VerifyJobShow(JsonObject request, bool failed)
        {
            var status = JobJson((VerifyJobId, "flash.verify@1", "succeeded", "2026-09-30T08:06:00Z"), list: false);
            const string slot = "\"processProgress\":null";
            var withResult = status.Replace(slot, slot + ",\"maintenanceResult\":" + VerifyMaintenanceJson(failed), StringComparison.Ordinal);
            if (withResult == status) throw new InvalidOperationException("verify status has no processProgress slot");
            var digest = Sha256Hex(Encoding.UTF8.GetBytes(VerifyJobId));
            var json = "{"
                + "\"actualStepKinds\":null,"
                + "\"catalogDigest\":\"508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684\","
                + "\"events\":{\"jobId\":\"" + VerifyJobId + "\",\"method\":\"job.events\"},"
                + "\"evidence\":{\"jobId\":\"" + VerifyJobId + "\",\"method\":\"job.evidence\"},"
                + "\"job\":" + withResult + ","
                + "\"materializedBindingRevision\":3,"
                + "\"materializedPlanDigest\":\"" + digest + "\","
                + "\"materializedStableIdentitySha256\":null,"
                + "\"providerId\":\"arkforge\","
                + "\"ringCoverage\":null,"
                + "\"schemaVersion\":\"arkdeck.job/1\","
                + "\"screenSequence\":null,"
                + "\"timeline\":{\"entries\":[\"jobCreated\",\"finalized\"],\"kind\":\"inline\"}"
                + "}";
            return Success(request, Parse(json));
        }

        private static string VerifyMaintenanceJson(bool failed)
        {
            var hash = new string('a', 64);
            var exitCode = failed ? 7 : 9;
            var outcome = failed ? "failed" : "partial";
            var skipped = failed ? 0 : 1;
            var failCount = failed ? 1 : 0;
            var rowOutcome = failed ? "failed" : "typedSkip";
            var reason = failed ? "content-mismatch" : "mounted-writable-after-boot";
            return "{\"schema\":\"arkforge.flash-verification/v1\",\"source_job_id\":\"" + VerifySourceJobId
                + "\",\"source_plan_id\":\"PLAN-1\",\"source_plan_sha256\":\"" + hash
                + "\",\"exit_code\":" + exitCode + ",\"outcome\":\"" + outcome
                + "\",\"verified\":0,\"skipped\":" + skipped + ",\"failed\":" + failCount
                + ",\"targets\":[{\"target\":\"userdata\",\"range_start\":4096,\"range_length\":4096,\"expected_sha256\":\""
                + hash + "\",\"observed_sha256\":null,\"verification_strength\":null,\"outcome\":\""
                + rowOutcome + "\",\"reason\":\"" + reason + "\"}]}";
        }
    }
}
