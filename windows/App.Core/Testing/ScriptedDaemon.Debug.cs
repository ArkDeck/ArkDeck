using System.Text;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary>The Debug workspace answers (<c>Recorded/debug-workspace.json</c>): the six
    /// operations' measured descriptions (available), the recorded probe, native-library plan and
    /// run answers of the Swift oracles.</summary>
    private static readonly Lazy<JsonObject> DebugRecorded = new(() =>
    {
        using var stream = typeof(ScriptedDaemon).Assembly.GetManifestResourceStream("ArkDeck.Recorded.debug-workspace.json")
                           ?? throw new InvalidOperationException("the recorded Debug workspace answers are missing");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return (JsonObject)StrictJson.Parse(buffer.ToArray());
    });

    private sealed partial class Script
    {
        private readonly List<(string Id, string Operation, string State, string Request)> _debugJobs = [];
        private readonly List<(string Direction, long Local, long Remote)> _portRules = [("forward", 9000, 9001), ("reverse", 9100, 9101)];

        /// <summary>A Debug route of the <c>jobs</c> scenario, or null when the method is not one.</summary>
        private byte[]? Debug(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            var recorded = DebugRecorded.Value;
            switch (method)
            {
                case "operation.list":
                    return Success(request, recorded["list"]);
                case "operation.describe":
                    return Param("reference") is { } reference && ((JsonObject)recorded["operations"]).TryGetValue(reference, out var described)
                        ? Success(request, described)
                        : Failure(request, "notFound", "unknown operation reference");
                case "debug.probe":
                    if (Param("targetId") != FixtureTargetId) return Failure(request, "notFound", "the Target is not adopted");
                    return Success(request, Parse($$"""
                        {"bindingRevision":3,"packages":["com.example.alpha","com.example.zeta"],"portRules":[{{string.Join(",", _portRules.Select(r => $$"""{"direction":"{{r.Direction}}","localPort":{{r.Local}},"remotePort":{{r.Remote}}}"""))}}],"schemaVersion":"arkdeck.debug-probe/1","targetId":"{{FixtureTargetId}}","warnings":[]}
                        """));
                case "job.plan":
                {
                    if (Request(Param("requestJson")) is not { } document) return Failure(request, "invalidInput", "requestJson is not a runtime operation request");
                    if (Operation(document) == "flash.full-restore@1") return Failure(request, "invalidInput", FlashLaneAbsence, Details("preAdmission"));
                    if (Operation(document) != "deploy.native-library.app-owned@1") return Failure(request, "rejected", "not scripted");
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    var plan = (JsonObject)recorded["plan"];
                    var members = plan.Members.Where(m => m.Key is not ("inputs" or "targetId" or "bindingRevision")).ToList();
                    members.Add(new("inputs", document["inputs"]));
                    members.Add(new("targetId", new JsonString(FixtureTargetId)));
                    members.Add(new("bindingRevision", JsonNumber.FromInt64(3)));
                    return Success(request, new JsonObject(members));
                }
                case "job.submit":
                {
                    if (Request(Param("requestJson")) is not { } document) return Failure(request, "invalidInput", "requestJson is not a runtime operation request");
                    var operation = Operation(document);
                    if (!((JsonObject)recorded["runs"]).ContainsKey(operation)) return Failure(request, "rejected", "not scripted");
                    if (Target(document) is not (FixtureTargetId, 3)) return Failure(request, "invalidInput", "the exact target binding is no longer current");
                    var id = "job-" + Convert.ToHexStringLower(Guid.NewGuid().ToByteArray());
                    _debugJobs.Add((id, operation, "queued", Param("requestJson")!));
                    return Success(request, Parse($$"""{"deduplicated":false,"jobId":"{{id}}","newDispatchCount":0,"schemaVersion":"arkdeck.job-acceptance/1"}"""));
                }
                case "job.run":
                {
                    var index = _debugJobs.FindIndex(j => j.Id == Param("jobId"));
                    if (index < 0) return null;
                    var job = _debugJobs[index];
                    if (job.State == "queued")
                    {
                        _debugJobs[index] = job with { State = "succeeded" };
                        ApplyPortRule(job);
                    }
                    return Success(request, DebugStatus(_debugJobs[index]));
                }
                case "job.show":
                {
                    var job = _debugJobs.FirstOrDefault(j => j.Id == Param("jobId"));
                    if (job.Id is null) return null;
                    return Success(request, new JsonObject(
                    [
                        new("actualStepKinds", JsonNull.Instance),
                        new("catalogDigest", new JsonString("508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684")),
                        new("events", Parse($$"""{"jobId":"{{job.Id}}","method":"job.events"}""")),
                        new("evidence", Parse($$"""{"jobId":"{{job.Id}}","method":"job.evidence"}""")),
                        new("job", DebugStatus(job)),
                        new("materializedBindingRevision", JsonNumber.FromInt64(3)),
                        new("materializedPlanDigest", new JsonString(Sha256Hex(Encoding.UTF8.GetBytes(job.Request)))),
                        new("materializedStableIdentitySha256", new JsonString(Sha256Hex(Encoding.UTF8.GetBytes(FixtureTargetId)))),
                        new("providerId", new JsonString("hdc")),
                        new("request", StoredRequest(job.Request)),
                        new("ringCoverage", JsonNull.Instance),
                        new("schemaVersion", new JsonString("arkdeck.job/1")),
                        new("screenSequence", JsonNull.Instance),
                        new("timeline", Parse(job.State == "queued"
                            ? """{"entries":["jobCreated"],"kind":"inline"}"""
                            : $$"""{"entries":["jobCreated","queued->preflight","preflight->running","running->{{job.State}}"],"kind":"inline"}""")),
                    ]));
                }
                case "job.cancel":
                {
                    var index = _debugJobs.FindIndex(j => j.Id == Param("jobId"));
                    if (index < 0) return null;
                    var active = _debugJobs[index].State == "queued";
                    if (active) _debugJobs[index] = _debugJobs[index] with { State = "cancelled" };
                    return Success(request, new JsonObject([new("cancelRequested", JsonBool.Of(active))]));
                }
                case "artifact.list":
                {
                    var owner = (JsonObject)parameters["owner"];
                    var job = _debugJobs.FirstOrDefault(j => j.Id == ((JsonString)owner["id"]).Value);
                    if (job.Id is null) return null;
                    return Success(request, Parse($$"""
                        {"hasMore":false,"items":[],"nextCursor":null,"order":"createdAtDescArtifactIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"0f5e0c1a-0000-4000-8000-000000000009"}
                        """));
                }
                default:
                    return null;
            }
        }

        /// <summary>The Debug Jobs as <c>job.list</c> rows, newest first.</summary>
        private IEnumerable<string> DebugJobRows() => Enumerable.Reverse(_debugJobs)
            .Select(j => JobJson((j.Id, j.Operation, j.State, "2026-09-30T09:00:00Z"), list: true));

        private JsonObject DebugStatus((string Id, string Operation, string State, string Request) job)
        {
            if (job.State == "queued") return (JsonObject)Parse(JobJson((job.Id, job.Operation, job.State, "2026-09-30T09:00:00Z"), list: false));
            var recorded = job.Operation == "flash.full-restore@1" ? FlashRun : (JsonObject)((JsonObject)DebugRecorded.Value["runs"])[job.Operation];
            var text = recorded.ToString().Replace((((JsonString)recorded["jobId"]).Value), job.Id, StringComparison.Ordinal)
                .Replace(OracleTargetId, FixtureTargetId, StringComparison.Ordinal);
            var status = (JsonObject)Parse(text);
            if (job.State == "succeeded") return status;
            var members = status.Members.Where(m => m.Key is not ("state" or "outcome" or "failure")).ToList();
            members.Add(new("state", new JsonString(job.State)));
            members.Add(new("outcome", new JsonString(job.State)));
            members.Add(new("failure", Parse("""{"category":"cancelled","code":"cancelled","recovery":"none","retryability":"notAutomatic","schemaVersion":"1.0.0"}""")));
            return new JsonObject(members);
        }

        private void ApplyPortRule((string Id, string Operation, string State, string Request) job)
        {
            if (job.Operation is not ("port-forward.create@1" or "port-forward.remove@1")) return;
            var inputs = (JsonObject)((JsonObject)Parse(job.Request))["inputs"];
            var rule = (((JsonString)inputs["direction"]).Value, TypedJson.Int64(inputs["localPort"]), TypedJson.Int64(inputs["remotePort"]));
            if (job.Operation == "port-forward.create@1") _portRules.Add(rule);
            else _portRules.Remove(rule);
        }

        /// <summary>A request as a Job stores it: the reviewed plan digest is consumed at admission,
        /// and a client context carries its (possibly empty) provenance.</summary>
        private static JsonObject StoredRequest(string json)
        {
            var members = ((JsonObject)Parse(json)).Members.Where(m => m.Key != "reviewedPlanDigest").ToList();
            var index = members.FindIndex(m => m.Key == "clientContext");
            if (index >= 0 && members[index].Value is JsonObject context && !context.ContainsKey("provenance"))
            {
                members[index] = new("clientContext", new JsonObject(context.Members.Append(new("provenance", new JsonObject()))));
            }
            return new JsonObject(members);
        }

        private static JsonObject? Request(string? json)
        {
            try
            {
                return json is null ? null : Parse(json) as JsonObject is { } o && o.TryGetValue("documentType", out var t) && t is JsonString { Value: "runtime-operation-request" } ? o : null;
            }
            catch (Exception error) when (error is MalformedJsonException or FormatException)
            {
                return null;
            }
        }

        private static string Operation(JsonObject document)
        {
            var operation = (JsonObject)document["operation"];
            return $"{((JsonString)operation["id"]).Value}@{TypedJson.Int64(operation["version"])}";
        }

        private static (string, long) Target(JsonObject document)
        {
            var target = (JsonObject)document["target"];
            return (((JsonString)target["targetId"]).Value,
                target.TryGetValue("expectedBindingRevision", out var revision) ? TypedJson.Int64(revision) : 0);
        }
    }
}
