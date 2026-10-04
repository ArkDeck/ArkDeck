using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary>Overview's run record and Run It Again: two read-only <c>observe.device@1</c> runs on
    /// one thread (their typed inputs reported), a failed destructive Flash, a diagnostics capture
    /// whose outcome is unknown, and a Trace capture that reported no typed inputs. A prepared
    /// continuation is planned (read-only), submitted as a new Job and run to success.</summary>
    public const string Continue = "continue";

    public const string ContinueObserveJobId = "job-0000000000000000000000000000c001";
    public const string ContinueObserveOlderJobId = "job-0000000000000000000000000000c002";
    public const string ContinueFlashJobId = "job-0000000000000000000000000000c003";
    public const string ContinueUnknownJobId = "job-0000000000000000000000000000c004";
    public const string ContinueUnreportedJobId = "job-0000000000000000000000000000c005";
    public const string ContinueThreadId = "t-observe-0001";

    private static readonly (string Id, string Operation, string State, string Created)[] ContinueJobs =
    [
        (ContinueObserveJobId, "observe.device@1", "succeeded", "2026-09-30T08:10:00Z"),
        (ContinueObserveOlderJobId, "observe.device@1", "succeeded", "2026-09-30T08:05:00Z"),
        (ContinueFlashJobId, "flash.full-restore@1", "failed", "2026-09-30T08:03:00Z"),
        (ContinueUnknownJobId, "capture.diagnostics@1", "interrupted", "2026-09-30T08:01:00Z"),
        (ContinueUnreportedJobId, "trace.capture@1", "succeeded", "2026-09-30T07:59:00Z"),
    ];

    /// <summary>The facts of <see cref="Continue"/>'s Jobs the generic projection cannot carry.</summary>
    private static string ContinueFacts(string jobId, string json) => jobId switch
    {
        ContinueObserveJobId or ContinueObserveOlderJobId => json.Replace("\"threadId\":null", $"\"threadId\":\"{ContinueThreadId}\"", StringComparison.Ordinal),
        ContinueFlashJobId => json.Replace("\"actualEffect\":\"readOnly\"", "\"actualEffect\":\"destructive\"", StringComparison.Ordinal)
            .Replace("\"workspaceKind\":\"device\"", "\"workspaceKind\":\"flash\"", StringComparison.Ordinal),
        ContinueUnknownJobId => json.Replace("\"outcomeUnknown\":false", "\"outcomeUnknown\":true", StringComparison.Ordinal),
        _ => json,
    };

    /// <summary>The evidence facts of <see cref="Continue"/>'s Jobs: the observation's typed input,
    /// the Flash's effect, the Trace capture's unreported inputs.</summary>
    private static string ContinueEvidence(string jobId, string json) => jobId switch
    {
        ContinueObserveJobId or ContinueObserveOlderJobId => json.Replace("\"parameters\":{}", "\"parameters\":{\"refreshServerFacts\":true}", StringComparison.Ordinal),
        ContinueFlashJobId => json.Replace("\"actualEffect\":\"readOnly\"", "\"actualEffect\":\"destructive\"", StringComparison.Ordinal),
        ContinueUnreportedJobId => json.Replace("\"parameters\":{}", "\"parameters\":null", StringComparison.Ordinal),
        _ => json,
    };

    private sealed partial class Script
    {
        private readonly List<(string Id, string Operation, string State, string Created)> _continued = [];

        /// <summary>A route of the <c>continue</c> scenario, or null when the method is not one.</summary>
        private byte[]? ContinueRoute(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) && p is JsonObject o ? o : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            switch (method)
            {
                case "job.plan":
                {
                    if (Request(Param("requestJson")) is not { } document) return Failure(request, "invalidInput", "requestJson is not a runtime operation request");
                    if (Operation(document) != "observe.device@1") return Failure(request, "rejected", "not scripted");
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    return Success(request, new JsonObject(
                    [
                        new("authorizationPolicy", new JsonString("defaultReadOnlyPolicy")),
                        new("bindingRevision", JsonNumber.FromInt64(3)),
                        new("catalogDigest", new JsonString("508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684")),
                        new("dispatchDisposition", new JsonString("notDispatched")),
                        new("effectiveEffect", new JsonString("readOnly")),
                        new("executionMode", new JsonString("planOnly")),
                        new("inputs", document["inputs"]),
                        new("jobAdmitted", JsonBool.False),
                        new("materializedPlanDigest", new JsonString(Sha256Hex(System.Text.Encoding.UTF8.GetBytes(document.ToString())))),
                        new("operation", new JsonString("observe.device@1")),
                        new("providerAdmissionBlocker", JsonNull.Instance),
                        new("providerId", new JsonString("hdc")),
                        new("requestFingerprintSha256", new JsonString(Sha256Hex(System.Text.Encoding.UTF8.GetBytes("fingerprint" + document)))),
                        new("schemaVersion", new JsonString("arkdeck.job-plan/1")),
                        new("stableIdentitySha256", new JsonString(Sha256Hex(System.Text.Encoding.UTF8.GetBytes(FixtureTargetId)))),
                        new("steps", Parse("""[{"binding":"confirmedDevice","cancellation":"immediate","effect":"readOnly","kind":"probeDevice","optional":false,"stepId":"probe-device"}]""")),
                        new("targetId", new JsonString(FixtureTargetId)),
                    ]));
                }
                case "job.submit":
                {
                    if (Request(Param("requestJson")) is not { } document) return Failure(request, "invalidInput", "requestJson is not a runtime operation request");
                    if (Operation(document) != "observe.device@1") return Failure(request, "rejected", "not scripted");
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    var id = "job-0000000000000000000000000000c1" + _continued.Count.ToString("x2", System.Globalization.CultureInfo.InvariantCulture);
                    _continued.Add((id, "observe.device@1", "queued", "2026-09-30T08:20:00Z"));
                    return Success(request, Parse($$"""{"deduplicated":false,"jobId":"{{id}}","newDispatchCount":0,"schemaVersion":"arkdeck.job-acceptance/1"}"""));
                }
                case "job.run":
                {
                    var index = _continued.FindIndex(j => j.Id == Param("jobId"));
                    if (index < 0) return Failure(request, "notFound", "unknown job " + Param("jobId"));
                    _continued[index] = _continued[index] with { State = "succeeded" };
                    return Success(request, Parse(JobJson(_continued[index], list: false)));
                }
                default:
                    return null;
            }
        }
    }
}
