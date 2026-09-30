using System.Security.Cryptography;
using System.Text;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

/// <summary>
/// The scripted test transport (<c>--test-transport &lt;scenario&gt;</c>): an in-process peer
/// that answers ClientKit's frames, so the UIA tests can put the App into states the real
/// daemon cannot be made to show on demand. It replaces only the authenticated pipe: every
/// frame still goes through ClientKit's codec, the health preflight and the method schemas,
/// so a reply the contract refuses is refused here too. The window shows a banner whenever
/// it is in use; nothing it answers is presented as Runtime data.
/// </summary>
public static class ScriptedDaemon
{
    /// <summary>Nothing answers: every connection closes before the health reply.</summary>
    public const string Unavailable = "unavailable";

    /// <summary>A peer that speaks another control contract (health names another identity).</summary>
    public const string ContractMismatch = "contract-mismatch";

    /// <summary>The Windows daemon's read-only foundation (a private endpoint, no state root),
    /// answering as the real one does: health and a blocked doctor; <c>device.observations</c>
    /// refused with <c>hdc.notConfigured</c>; the Job methods refused because no Job owner is
    /// composed; the Target, Artifact and Trace inspection owners absent.</summary>
    public const string Foundation = "foundation";

    /// <summary><see cref="Unavailable"/> for the first two connections (the start reads the
    /// Overview and the Job Inspector, one connection each before the refresh stops), then
    /// <see cref="Foundation"/>: the recovery banner appears, then goes away after Retry.</summary>
    public const string Recovers = "recovers";

    /// <summary><see cref="Foundation"/> for the first four connections (the start reads the
    /// Overview's health, doctor and Jobs and the Job Inspector's Jobs), then nothing answers:
    /// the daemon goes away while the App shows its data.</summary>
    public const string Outage = "outage";

    /// <summary>A daemon with a Job store, an Artifact owner and devices: three candidates, one
    /// adopted Target, three Jobs (a running one whose state advances on each
    /// <c>job.status</c> read) with their Artifacts; no Trace inspector, so
    /// <c>trace.inspect</c> is refused as on Windows today.</summary>
    public const string Jobs = "jobs";

    /// <summary>The Windows daemon as <c>origin/main</c> composes it over a development state
    /// root (TASK-XPA-004): the Target store holds the Swift adoption oracle's Target, whose
    /// display name can be set and cleared; no HDC (<c>device.observations</c> refused), no
    /// Job owner, no Artifact owner, no Trace inspector.</summary>
    public const string DevelopmentRoot = "targets";

    /// <summary><see cref="Jobs"/> with a Trace inspector: <c>trace.inspect</c> answers the
    /// recorded ArkTrace projection (rust/tests/fixtures/trace-inspect, "base").</summary>
    public const string Inspector = "inspector";

    public static readonly IReadOnlyList<string> Scenarios = [Unavailable, ContractMismatch, Foundation, Recovers, Outage, Jobs, DevelopmentRoot, Inspector];

    public const string RunningJobId = "job-0000000000000000000000000000a001";
    public const string FailedJobId = "job-0000000000000000000000000000a002";
    public const string TraceJobId = "job-0000000000000000000000000000a003";
    public static readonly IReadOnlyList<string> RunningJobStates = ["running", "waitingForDevice", "running", "succeeded"];

    /// <summary>The Target of <see cref="Jobs"/> (the adopted candidate's).</summary>
    public const string FixtureTargetId = "TGT-FIXTURE-1";

    /// <summary>The Swift adoption oracle's Target (rust/tests/fixtures/target-adoption).</summary>
    public const string OracleTargetId = "TGT-3ba3f5f43b92";

    /// <summary>The Artifacts of <see cref="Jobs"/>: (Job, id, name, media type, privacy,
    /// status, source operation, bytes). The raw Trace spans two export chunks.</summary>
    public static readonly IReadOnlyList<ScriptedArtifact> Artifacts =
    [
        new(FailedJobId, "ART-00000000000000000000000000000b01", "flash-log.txt", "text/plain", "standard", "published", "flash.images@1",
            Encoding.UTF8.GetBytes("flash.images@1: write verification mismatch on partition system\n")),
        new(FailedJobId, "ART-00000000000000000000000000000b02", "partition-table.json", "application/json", "standard", "missing", "flash.images@1", []),
        new(TraceJobId, "ART-00000000000000000000000000000c01", "trace.htrace", "application/octet-stream", "sensitive", "published", "trace.capture@1",
            Enumerable.Range(0, 300_000).Select(i => (byte)(i * 31 % 251)).ToArray()),
        new(TraceJobId, "ART-00000000000000000000000000000c02", "trace-config.json", "application/json", "standard", "published", "trace.capture@1",
            Encoding.UTF8.GetBytes("{\"durationSeconds\":5,\"tags\":[\"sched\",\"freq\"]}\n")),
    ];

    public static IControlChannel Channel(string scenario)
    {
        if (!Scenarios.Contains(scenario)) throw new ArgumentException($"unknown test transport scenario {scenario}", nameof(scenario));
        var script = new Script(scenario);
        return new StreamChannel(script.Connect, DaemonConfiguration.CallBudget);
    }

    private sealed class Script(string scenario)
    {
        private readonly object _gate = new();
        private readonly Dictionary<string, (string? Name, long Generation)> _names = new(StringComparer.Ordinal)
        {
            [OracleTargetId] = (null, 1),
            [FixtureTargetId] = ("Bench board", 1),
        };
        private int _connections;
        private int _statusReads;

        public Stream Connect()
        {
            var connection = Interlocked.Increment(ref _connections);
            var mode = scenario switch
            {
                Recovers => connection <= 2 ? Unavailable : Foundation,
                Outage => connection <= 4 ? Foundation : Unavailable,
                _ => scenario,
            };
            return new Peer(request =>
            {
                lock (_gate) return Answer(mode, request);
            });
        }

        private byte[]? Answer(string mode, JsonObject request)
        {
            var method = ((JsonString)request["method"]).Value;
            if (mode == Unavailable) return null;
            if (mode == ContractMismatch) return Success(request, Health(new string('0', 64)));
            if (method == "health") return Success(request, Health(ControlContract.ContractIdentity));
            return mode switch
            {
                Foundation => method switch
                {
                    "doctor" => Success(request, Parse(BlockedDoctor)),
                    "device.observations" => Failure(request, "rejected", "hdc.notConfigured"),
                    _ when method.StartsWith("job.", StringComparison.Ordinal) => Failure(request, "rejected", "The Job owner is not configured"),
                    _ when method.StartsWith("target.", StringComparison.Ordinal) => Failure(request, "internalError", "Target owner is not configured"),
                    _ when method.StartsWith("artifact.", StringComparison.Ordinal) => ArtifactOwnerAbsent(request),
                    "trace.inspect" => NoTraceInspector(request),
                    _ when method.StartsWith("workspace.", StringComparison.Ordinal) => Failure(request, "operationUnavailable", "workspace project owner is unavailable",
                        Details(method.StartsWith("workspace.preset", StringComparison.Ordinal) ? "workspacePresetOwner" : "workspaceProjectOwner")),
                    _ => SettingsOwnerAbsent(request, method),
                },
                DevelopmentRoot => method switch
                {
                    "doctor" => Success(request, Parse(BlockedDoctor)),
                    "device.observations" => Failure(request, "rejected", "hdc.notConfigured"),
                    _ when method.StartsWith("job.", StringComparison.Ordinal) => Failure(request, "rejected", "The Job owner is not configured"),
                    _ when method.StartsWith("target.", StringComparison.Ordinal) => Target(request, method, [OracleTargetId]),
                    _ when method.StartsWith("artifact.", StringComparison.Ordinal) => ArtifactOwnerAbsent(request),
                    "trace.inspect" => NoTraceInspector(request),
                    _ when method.StartsWith("workspace.", StringComparison.Ordinal) => Workspace(request, method),
                    _ => SettingsOwnerAbsent(request, method),
                },
                _ => method switch
                {
                    "doctor" => Success(request, Parse(HealthyDoctor)),
                    "device.observations" => Success(request, Parse(Observations)),
                    "job.list" => Success(request, Parse(JobPage([.. JobsNow().Select(j => JobJson(j, list: true))]))),
                    "job.status" => JobStatus(request),
                    "job.events" => JobEvents(request),
                    _ when method.StartsWith("target.", StringComparison.Ordinal) => Target(request, method, [FixtureTargetId]),
                    "artifact.list" => ArtifactList(request),
                    "artifact.read" => ArtifactRead(request),
                    "trace.inspect" => mode == Inspector ? TraceInspect(request) : NoTraceInspector(request),
                    _ when method.StartsWith("workspace.", StringComparison.Ordinal) => Workspace(request, method),
                    "runtime.hdc.status" => Success(request, Parse(HdcStatusJson)),
                    "runtime.tool.list" => Success(request, Parse(ToolPageJson)),
                    "runtime.storage.status" => Success(request, Parse(StorageJson)),
                    "trace.cache.status" => Success(request, Parse(TraceCacheJson)),
                    _ => Failure(request, "rejected", "not scripted"),
                },
            };
        }

        private (string Id, string Operation, string State, string Created)[] JobsNow() =>
        [
            (RunningJobId, "observe.device@1", RunningJobStates[Math.Min(_statusReads, RunningJobStates.Count - 1)], "2026-09-30T08:02:00Z"),
            (FailedJobId, "flash.images@1", "failed", "2026-09-30T08:01:00Z"),
            (TraceJobId, "trace.capture@1", "succeeded", "2026-09-30T08:00:00Z"),
        ];

        private byte[] JobStatus(JsonObject request)
        {
            var id = ((JsonString)request["params"]["jobId"]).Value;
            if (id == RunningJobId)
            {
                var job = JobsNow()[0];
                _statusReads++;
                return Success(request, Parse(JobJson(job, list: false)));
            }
            var other = JobsNow().FirstOrDefault(j => j.Id == id);
            return other.Id is null ? Failure(request, "notFound", "no such Job") : Success(request, Parse(JobJson(other, list: false)));
        }

        private byte[] JobEvents(JsonObject request)
        {
            var id = ((JsonString)request["params"]["jobId"]).Value;
            var job = JobsNow().FirstOrDefault(j => j.Id == id);
            if (job.Id is null) return Failure(request, "notFound", "no such Job");
            var path = id == RunningJobId
                ? new[] { "queued", "preflight" }.Concat(RunningJobStates.Take(Math.Max(1, Math.Min(_statusReads, RunningJobStates.Count)))).ToArray()
                : ["queued", "preflight", "running", job.State];
            var items = new List<string>();
            for (var i = 1; i < path.Length; i++)
            {
                items.Add($$"""
                {"cursor":"c-{{i}}","data":{"attempt":null,"bindingRevision":null,"fromState":"{{path[i - 1]}}","jobId":"{{id}}","journalKind":"stateTransition","sessionId":"session-{{id}}","stepId":null,"timestamp":"2026-09-30T08:0{{i}}:00Z","toState":"{{path[i]}}"},"eventId":"t-{{i}}","runtimeRevision":"{{i}}","streamPosition":"{{i}}","type":"stateChanged"}
                """);
            }
            return Success(request, Parse($$"""
                {"hasMore":false,"items":[{{string.Join(",", items)}}],"nextCursor":"c-end","order":"streamPositionAsc","pageKind":"eventStream","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"{{path.Length}}"}
                """));
        }

        /// <summary>The Target owner over a Target store holding <paramref name="known"/>, as
        /// the Windows daemon's (TASK-XPA-004) answers: list, show, availability, and the
        /// generation-guarded display name set and clear.</summary>
        private byte[] Target(JsonObject request, string method, string[] known)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            if (method == "target.list") return Success(request, Parse("[" + string.Join(",", known.Select(TargetRow)) + "]"));
            var id = parameters.TryGetValue("targetId", out var t) ? ((JsonString)t).Value : "";
            var writes = method is "target.display-name.set" or "target.display-name.clear";
            if (!known.Contains(id))
            {
                return writes ? Failure(request, "notFound", "Target not found", NameOwnerDetails) : Failure(request, "notFound", "Target not found");
            }
            switch (method)
            {
                case "target.show":
                    return Success(request, Parse(TargetShow(id)));
                case "target.availability":
                    return Success(request, Parse(TargetAvailability(id)));
                case "target.display-name.set":
                case "target.display-name.clear":
                    var current = _names[id];
                    var expected = parameters.TryGetValue("expectedGeneration", out var g) ? ((JsonString)g).Value : "";
                    if (expected != current.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    {
                        return Failure(request, "resourceConflict", "Target display-name generation changed or is exhausted", NameOwnerDetails);
                    }
                    string? name = null;
                    if (method == "target.display-name.set")
                    {
                        name = parameters.TryGetValue("name", out var n) ? ((JsonString)n).Value : "";
                        if (string.IsNullOrWhiteSpace(name)) return Failure(request, "invalidInput", "Display name must be nonblank bounded text", NameOwnerDetails);
                    }
                    _names[id] = (name, current.Generation + 1);
                    return Success(request, new JsonObject(
                    [
                        new("generation", new JsonString((current.Generation + 1).ToString(System.Globalization.CultureInfo.InvariantCulture))),
                        new("name", name is null ? JsonNull.Instance : new JsonString(name)),
                        new("schemaVersion", new JsonString("arkdeck.target-display-name/1")),
                        new("targetId", new JsonString(id)),
                        new("updatedAtUtc", new JsonString("2026-09-30T08:05:00Z")),
                    ]));
                default:
                    return Failure(request, "rejected", "not scripted");
            }
        }

        private static readonly JsonObject NameOwnerDetails = new(
        [
            new("newDispatchCount", JsonNumber.FromInt64(0)),
            new("phase", new JsonString("targetDisplayNameOwner")),
        ]);

        private (string Connect, long Binding, string Adopted, string Tool, string? Facts) TargetFacts(string id) => id == OracleTargetId
            ? ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1, "2026-09-14T00:00:00Z", "3.2.0d", null)
            : ("fixture-serial-1", 3, "2026-09-29T10:00:00Z", "3.2.0f",
                """{"confirmedAtUtc":"2026-09-30T08:00:00Z","firmware":"OpenHarmony 6.0","model":"DAYU200","targetId":"TGT-FIXTURE-1","transport":"usb"}""");

        private string TargetRow(string id)
        {
            var (_, binding, adopted, tool, _) = TargetFacts(id);
            var (name, generation) = _names[id];
            return $$"""{"adoptedAtUtc":"{{adopted}}","bindingRevision":{{binding}},"displayName":{{Quote(name)}},"displayNameGeneration":"{{generation}}","targetId":"{{id}}","toolVersion":"{{tool}}"}""";
        }

        private string TargetShow(string id)
        {
            var (connect, binding, adopted, tool, facts) = TargetFacts(id);
            var (name, generation) = _names[id];
            return $$"""{"adoptedAtUtc":"{{adopted}}","bindingRevision":{{binding}},"connectKey":"{{connect}}","displayName":{{Quote(name)}},"displayNameGeneration":"{{generation}}","live":null,"observedFacts":{{facts ?? "null"}},"schemaVersion":"arkdeck.target/1","stablePhysicalIdentitySha256":"{{Sha256Hex(Encoding.ASCII.GetBytes(connect))}}","targetId":"{{id}}","toolVersion":"{{tool}}"}""";
        }

        private string TargetAvailability(string id)
        {
            var (connect, binding, adopted, tool, _) = TargetFacts(id);
            return $$$"""
                {"binding":{"adoptedAtUtc":"{{{adopted}}}","bindingRevision":{{{binding}}},"stablePhysicalIdentitySha256":"{{{Sha256Hex(Encoding.ASCII.GetBytes(connect))}}}","state":"ready","toolVersion":"{{{tool}}}"},"observedAtUtc":"2026-09-30T08:00:00Z","operations":{"items":[{"availability":"unavailable","reasonCodes":["provider_not_registered"],"reasons":["provider hdc is not registered"],"reference":"observe.device@1"},{"availability":"unavailable","reasonCodes":["provider_not_registered"],"reasons":["provider hdc is not registered"],"reference":"trace.capture@1"},{"availability":"unavailable","reasonCodes":["provider_not_registered"],"reasons":["provider arkforge is not registered"],"reference":"flash.dayu200"}],"reason":"operation availability is computed per host; no target-scoped resolver exists","reasonCode":"target_scoped_operation_availability_unavailable","scope":"host","targetResolution":"unresolved"},"presence":{"observationHealth":null,"observedAtUtc":null,"reason":"the Runtime has no device observation source configured","reasonCode":"device_observation_unavailable","state":"unresolved"},"profile":{"reason":"no target-to-profile resolver exists; catalog profiles are published but unmatched","reasonCode":"profile_resolver_unavailable","state":"unresolved"},"targetId":"{{{id}}}","tool":{"reason":"Runtime has no managed HDC server","reasonCode":"runtime_tool_unavailable","state":"absent"}}
                """;
        }

        private static byte[] ArtifactList(JsonObject request)
        {
            var owner = (JsonObject)request["params"]["owner"];
            var jobId = ((JsonString)owner["id"]).Value;
            if (jobId is not (RunningJobId or FailedJobId or TraceJobId)) return Failure(request, "notFound", "no such Job", ArtifactDetails);
            var rows = Artifacts.Where(a => a.JobId == jobId).OrderBy(a => a.Id, StringComparer.Ordinal).Select(a => a.Json());
            return Success(request, Parse($$"""
                {"hasMore":false,"items":[{{string.Join(",", rows)}}],"nextCursor":null,"order":"createdAtDescArtifactIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"0f5e0c1a-0000-4000-8000-000000000001"}
                """));
        }

        private static byte[] ArtifactRead(JsonObject request)
        {
            var parameters = (JsonObject)request["params"];
            var jobId = ((JsonString)((JsonObject)parameters["owner"])["id"]).Value;
            var artifactId = ((JsonString)parameters["artifactId"]).Value;
            var artifact = Artifacts.FirstOrDefault(a => a.JobId == jobId && a.Id == artifactId);
            if (artifact is null || artifact.Status != "published") return Failure(request, "resourceNotFound", "no published Artifact", ArtifactDetails);
            var allow = parameters.TryGetValue("allowSensitive", out var s) && s is JsonBool { Value: true };
            if (artifact.Privacy == "sensitive" && !allow) return Failure(request, "sensitiveAccessDenied", "Sensitive Artifact access requires allowSensitive", ArtifactDetails);
            var offset = (int)TypedJson.Int64(parameters["offset"]);
            var max = (int)TypedJson.Int64(parameters["maxBytes"]);
            var count = Math.Max(0, Math.Min(max, artifact.Bytes.Length - offset));
            var next = offset + count;
            return Success(request, new JsonObject(
            [
                new("artifactDigest", new JsonString(artifact.Sha256)),
                new("artifactId", new JsonString(artifact.Id)),
                new("base64", new JsonString(Convert.ToBase64String(artifact.Bytes, offset, count))),
                new("byteCount", JsonNumber.FromInt64(count)),
                new("eof", JsonBool.Of(next == artifact.Bytes.Length)),
                new("nextOffset", JsonNumber.FromInt64(next)),
                new("offset", JsonNumber.FromInt64(offset)),
                new("totalByteCount", JsonNumber.FromInt64(artifact.Bytes.Length)),
            ]));
        }

        private static byte[] TraceInspect(JsonObject request)
        {
            var parameters = (JsonObject)request["params"];
            var jobId = ((JsonString)((JsonObject)parameters["owner"])["id"]).Value;
            var artifactId = ((JsonString)parameters["artifactId"]).Value;
            var trace = Artifacts.FirstOrDefault(a => a.JobId == jobId && a.Id == artifactId && a.Name == "trace.htrace");
            if (trace is null) return Failure(request, "notFound", "no raw Trace", TraceDetails);
            return Success(request, Parse($$$"""
                {"dataQuality":{"issues":[],"status":"ok"},"deviceEvidenceCreated":false,"engine":{"build":"fixture","name":"ArkTrace","sourceRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version":"4.3.7"},"owner":{"id":"{{{jobId}}}","kind":"job"},"parser":{"adapterVersion":"1","binarySha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","buildRecipeVersion":"1","name":"trace_streamer","upstreamRevision":"cccccccccccccccccccccccccccccccccccccccc","version":"fixture"},"schema":{"fingerprint":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","provenance":{"adapterVersion":"1","indexVersion":1,"upstreamDatabaseByteCount":"13","upstreamDatabaseSha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}},"schemaVersion":"arkdeck.trace-inspection/1","source":{"artifactDigest":"{{{trace.Sha256}}}","artifactId":"{{{trace.Id}}}","byteCount":"{{{trace.Bytes.Length}}}","mediaType":"application/octet-stream","name":"trace.htrace","privacy":"sensitive","sourceOperation":"trace.capture@1"},"storageMode":"ephemeral","trace":{"capabilities":{"cpuCounters":false,"cpuScheduling":true,"namedSlices":true,"processCounters":false,"threadStates":true},"durationNs":"5000000000"}}
                """));
        }

        private static readonly JsonObject ArtifactDetails = new(
        [
            new("newDispatchCount", JsonNumber.FromInt64(0)),
            new("phase", new JsonString("artifactOwner")),
        ]);

        private static readonly JsonObject TraceDetails = new(
        [
            new("deviceEvidenceCreated", JsonBool.False),
            new("newDispatchCount", JsonNumber.FromInt64(0)),
            new("phase", new JsonString("traceInspectionOwner")),
        ]);

        /// <summary>The Settings reads of the Windows daemon without their owners (its real answers).</summary>
        private static byte[] SettingsOwnerAbsent(JsonObject request, string method) => method switch
        {
            "runtime.tool.list" or "runtime.bundle.list" => Failure(request, "operationUnavailable", "Bootstrap bundle list owner is not configured", Details("bootstrapRegistryOwner")),
            "runtime.storage.status" => Failure(request, "rejected", "Runtime storage owners are not configured"),
            "trace.cache.status" => Failure(request, "rejected", "Trace cache owner is not configured"),
            _ => Failure(request, "rejected", "this method is unavailable in the read-only Rust foundation"),
        };

        /// <summary>The workspace project owner holding one registered project and its symbol
        /// preset, as the Windows daemon answers after registration (TASK-XPA-015).</summary>
        private static byte[] Workspace(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            var reference = parameters.TryGetValue("projectRef", out var r) ? ((JsonString)r).Value : null;
            var phase = method.StartsWith("workspace.preset", StringComparison.Ordinal) ? "workspacePresetOwner" : "workspaceProjectOwner";
            if (method == "workspace.project.list") return Success(request, Parse($$"""{"projects":[{{ProjectJson}}],"schemaVersion":"arkdeck.workspace-project-list/1"}"""));
            if (reference != ProjectRef) return Failure(request, "workspaceReferenceNotFound", "workspace project is not registered", Details(phase));
            return method switch
            {
                "workspace.project.show" => Success(request, Parse(ProjectJson)),
                "workspace.preset.list" => Success(request, Parse($$"""{"presets":[{{PresetJson}}],"projectRef":"{{ProjectRef}}","schemaVersion":"arkdeck.workspace-preset-list/1"}""")),
                _ => Failure(request, "rejected", "not scripted"),
            };
        }

        private static JsonObject Details(string phase) => new(
        [
            new("newDispatchCount", JsonNumber.FromInt64(0)),
            new("phase", new JsonString(phase)),
        ]);

        /// <summary>The Windows daemon without an Artifact owner (its real answer).</summary>
        private static byte[] ArtifactOwnerAbsent(JsonObject request) =>
            Failure(request, "operationUnavailable", "Artifact owner is not configured", ArtifactDetails);

        /// <summary>The Windows daemon without a Trace inspector (its real answer, the Swift oracle's bytes).</summary>
        private static byte[] NoTraceInspector(JsonObject request) =>
            Failure(request, "operationUnavailable", "Trace inspection is unavailable", TraceDetails);

        private static string Quote(string? value) => value is null ? "null" : Encoding.UTF8.GetString(CanonicalJson.Encode(new JsonString(value)));
    }

    /// <summary>One scripted Job Artifact and its bytes.</summary>
    public sealed record ScriptedArtifact(string JobId, string Id, string Name, string MediaType, string Privacy, string Status, string SourceOperation, byte[] Bytes)
    {
        public string Sha256 => Sha256Hex(Bytes);

        internal string Json()
        {
            var published = Status == "published";
            var digest = published ? $"\"{Sha256}\"" : "null";
            var lease = published ? $"\"lease-v1:{JobId}:{Id}\"" : "null";
            return $$"""
                {"artifactDigest":{{digest}},"artifactId":"{{Id}}","binding":{"bindingRevision":3,"stableIdentitySha256":null,"targetId":"TGT-FIXTURE-1"},"byteCount":{{Bytes.Length}},"createdAtUtc":"2026-09-30T08:03:00Z","lease":{{lease}},"mediaType":"{{MediaType}}","name":"{{Name}}","observationWindow":null,"owner":{"id":"{{JobId}}","kind":"job"},"privacy":"{{Privacy}}","providerId":"hdc","redactionApplied":false,"retention":{"class":"default","deadlineUtc":null,"pinned":false},"schemaVersion":"arkdeck.artifact/1","sourceOperation":"{{SourceOperation}}","status":"{{Status}}"}
                """;
        }
    }

    /// <summary>The registered project and preset (the real daemon's answers after
    /// registration; the root path is never part of them).</summary>
    public const string ProjectRef = "project-04dfc9a54d0e77e090fbb537";

    public const string PresetRef = "preset-f55cf38289a9c8bf32967f7d";

    private const string ProjectJson = """
        {"allowedFileGlobs":[],"availability":"unavailable","configurationStatus":"runtimeRestartRequired","generation":"1","kind":"openharmony","operations":[],"presetRefs":[],"projectRef":"project-04dfc9a54d0e77e090fbb537","reason":"restart the Runtime to compose the registered root before submitting a workspace Job","reasonCode":"workspace_runtime_restart_required","registeredAtUtc":"2026-09-30T08:40:07Z","schemaVersion":"arkdeck.workspace-project/1","updatedAtUtc":"2026-09-30T08:40:07Z"}
        """;

    private const string PresetJson = """
        {"configurationStatus":"runtimeRestartRequired","constraints":{"relativeSourceMap":"entry/build/sourceMaps.map"},"credentialRef":null,"generation":"1","kind":"symbol","presetRef":"preset-f55cf38289a9c8bf32967f7d","projectRef":"project-04dfc9a54d0e77e090fbb537","registeredAtUtc":"2026-09-30T08:40:07Z","schemaVersion":"arkdeck.workspace-preset/1","templateRef":"openharmony.arkts-symbol@1","timeoutSeconds":600,"toolchainGeneration":null,"toolchainRef":null,"updatedAtUtc":"2026-09-30T08:40:07Z"}
        """;

    private const string HdcStatusJson = """
        {"availability":"available","clientVersion":"3.2.0f","clientVersionSource":"probe","configuredExecutableSHA256":null,"daemonVersion":"3.2.0f","endpoint":"127.0.0.1:8710","endpointSource":"default","executablePath":"C:\\Tools\\hdc\\hdc.exe","executableSHA256":"1111111111111111111111111111111111111111111111111111111111111111","executableSource":"registered","generation":"1","healthReasonCode":"hdc.healthy","newDispatchCount":0,"observedAt":"2026-09-30T08:00:00Z","ownership":"managed","processId":4242,"reasonCode":"hdc.available","schemaVersion":"arkdeck.runtime-hdc-status/1","serverEndpointRef":null,"serverHealth":"healthy","serverVersion":null,"signature":null,"startupVersions":null}
        """;

    private const string ToolPageJson = """
        {"hasMore":false,"items":[{"contentDigest":"2222222222222222222222222222222222222222222222222222222222222222","contentRetained":true,"contentSchemaVersion":"1","digestAlgorithm":"sha256","generation":"1","kind":"hdc","platform":"windows-x64","references":[],"schemaVersion":"arkdeck.runtime-tool/1","selected":true,"source":"registered","state":"active","toolRef":"tool-hdc-3.2.0f","trust":{"codeDirectoryIdentitySHA256":null,"executionAssessment":"accepted","platformTrust":"trusted","policy":"registered","profileReferences":[],"registeredIdentity":true,"signature":"valid","signingIdentifier":null,"teamIdentifier":null,"toolVersion":"3.2.0f","versionSource":"probe"}}],"nextCursor":null,"order":"registeredAtAscToolRefAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"0f5e0c1a-0000-4000-8000-000000000002"}
        """;

    private const string StorageJson = """
        {"artifactDomain":{"policy":"runtimeManaged","remainingBytes":"9663676416","rootReference":"runtime-artifacts","schemaVersion":"arkdeck.runtime-artifact-storage/1","totalBytes":"10737418240","usedBytes":"1073741824"},"schemaVersion":"arkdeck.runtime-storage-status/1","sessionDomain":{"catalogGeneration":null,"generation":"1","policy":{"retentionDays":"30","safetyMarginBytes":"1073741824","totalQuotaBytes":"21474836480"},"rootKind":"default","rootPath":"C:\\Users\\Example\\AppData\\Local\\ArkDeck\\Sessions","schemaVersion":"arkdeck.session-storage/1","usage":{"measurementIncomplete":false,"pinnedBytes":"4096","pinnedSessionCount":"1","sessionCount":"3","unaccountedSessionCount":"0","usedBytes":"123456"}}}
        """;

    private const string TraceCacheJson = """
        {"activeEntryCount":1,"entryCount":2,"inactiveEntryCount":1,"purgeScope":"inactiveDerivedEntries","schemaVersion":"arkdeck.trace-cache-status/1","totalByteCount":"65536"}
        """;

    private static string Sha256Hex(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    private static JsonValue Health(string contractIdentity) => new JsonObject(
    [
        new("catalogDigest", new JsonString(new string('a', 64))),
        new("contractIdentity", new JsonString(contractIdentity)),
        new("protocolVersion", new JsonString(ControlContract.ProtocolVersion)),
        new("providers", new JsonArray([])),
        new("publishedMethods", new JsonArray(ControlContract.Methods.Select(m => (JsonValue)new JsonString(m)))),
        new("status", new JsonString("ok")),
    ]);

    private static string JobJson((string Id, string Operation, string State, string Created) job, bool list)
    {
        var terminal = ArkDeck.App.Core.Presentation.JobSummary.TerminalStates.Contains(job.State);
        var next = terminal
            ? $$$"""{"kind":"readResult","owner":{"id":"{{{job.Id}}}","kind":"job"},"reasonCode":"job.resultAvailable","resource":{"id":"{{{job.Id}}}","kind":"job"}}"""
            : $$$"""{"kind":"wait","owner":{"id":"{{{job.Id}}}","kind":"job"},"reasonCode":"job.running","resource":{"id":"{{{job.Id}}}","kind":"job"},"retryAfter":"250ms"}""";
        var listOnly = list ? "\"current\":true,\"timeline\":null," : string.Empty;
        var schema = list ? "arkdeck.job-summary/1" : "arkdeck.job-status/1";
        var finished = terminal ? $"\"{job.Created}\"" : "null";
        return $$$"""
            {"actualEffect":"readOnly","createdAtUtc":"{{{job.Created}}}",{{{listOnly}}}"executionMode":"execute","failure":null,"finishedAtUtc":{{{finished}}},"jobId":"{{{job.Id}}}","nextAction":{{{next}}},"operation":"{{{job.Operation}}}","outcome":"{{{job.State}}}","outcomeUnknown":false,"outstandingResidueCount":0,"processProgress":null,"recoveryEpochId":null,"resolvedByTargetAliasResolutionId":null,"schemaVersion":"{{{schema}}}","sessionId":"session-{{{job.Id}}}","sessionPublication":{"catalogGeneration":null,"manifestSha256":null,"reasonCode":"noCurrentPublicationRecord","state":"unavailable"},"startedAtUtc":"{{{job.Created}}}","state":"{{{job.State}}}","supersededByRecoveryEpochId":null,"targetId":"TGT-FIXTURE-1","threadId":null,"waitingForHuman":{{{(job.State == "waitingForDevice" ? "true" : "false")}}},"workspaceKind":"device"}
            """;
    }

    private static string JobPage(string[] items) => $$"""
        {"hasMore":false,"items":[{{string.Join(",", items)}}],"nextCursor":null,"order":"createdAtDescJobIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"r1"}
        """;

    private const string Checks = """
        "checks":{"catalog":{"availableOperationCount":0,"digest":"508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684","operationCount":30,"unavailableOperationCount":30},"hdc":{"availability":"unavailable","checked":false,"configured":false,"ownership":"unknown","reasonCode":"hdc.notConfigured","serverHealth":"unknown"},"providers":{"registered":[]},"recovery":{"checked":false,"outstandingCleanupCount":null},"runtime":{"protocolVersion":"1.0.0","runtimeRequestSchemaVersion":"1.0.0"},"storage":{"runtimeArtifacts":{"checked":false,"configured":false,"remainingBytes":null,"totalBytes":null,"usedBytes":null},"sessionOutput":{"availability":"unavailable","checked":false,"reasonCode":"storage.sessionOutputOwnerNotPublished"}},"target":{"adoptedTargetCount":null,"bootstrapConfigured":false,"configured":false}}
        """;

    private const string BlockedDoctor = "{" + Checks + """
        ,"findingCounts":{"blocker":2,"info":1,"warning":0},"findings":[{"code":"runtime.controlReady","scope":"runtime","severity":"info","summary":"the target control protocol is serving bounded diagnostic requests"},{"code":"provider.noneRegistered","scope":"provider","severity":"blocker","summary":"the Runtime has no registered provider"},{"code":"hdc.notConfigured","scope":"hdc","severity":"blocker","summary":"the Runtime has no bounded HDC status observer"}],"mode":"standard","observedAt":"2026-09-30T08:00:00Z","overall":"blocked","ready":false,"schemaVersion":"arkdeck.doctor-report/1"}
        """;

    private const string HealthyDoctor = "{" + Checks + """
        ,"findingCounts":{"blocker":0,"info":1,"warning":0},"findings":[{"code":"runtime.controlReady","scope":"runtime","severity":"info","summary":"the target control protocol is serving bounded diagnostic requests"}],"mode":"standard","observedAt":"2026-09-30T08:00:00Z","overall":"healthy","ready":true,"schemaVersion":"arkdeck.doctor-report/1"}
        """;

    private const string Observations = """
        {"health":"current","observations":[{"adoptedTargetId":"TGT-FIXTURE-1","authorizationState":"Connected","bindingRevision":3,"candidateKey":"fixture-serial-1","deviceInformation":{"name":"DAYU200","observedAtUtc":"2026-09-30T08:00:00Z","systemVersion":"OpenHarmony 6.0","transport":"usb"},"displayName":"Bench board","displayNameGeneration":"1","observationContinuity":"generationScoped","observationId":"obs-1","observedFacts":null},{"adoptedTargetId":null,"authorizationState":"Unauthorized","bindingRevision":null,"candidateKey":"fixture-serial-2","deviceInformation":null,"displayName":null,"displayNameGeneration":"0","observationContinuity":"generationScoped","observationId":"obs-2","observedFacts":null},{"adoptedTargetId":null,"authorizationState":"Offline","bindingRevision":null,"candidateKey":"fixture-serial-3","deviceInformation":null,"displayName":null,"displayNameGeneration":"0","observationContinuity":"generationScoped","observationId":"obs-3","observedFacts":null}],"observedAtUtc":"2026-09-30T08:00:00Z","schemaVersion":"arkdeck.device-observations/1","snapshotGeneration":"1"}
        """;

    private static JsonValue Parse(string json) => StrictJson.Parse(Encoding.UTF8.GetBytes(json.Trim()));

    private static byte[] Success(JsonObject request, JsonValue result) =>
        Wire.EncodeFrame(new JsonObject([new("id", request["id"]), new("ok", JsonBool.True), new("result", result)]), ControlContract.MaxResponseBytes);

    private static byte[] Failure(JsonObject request, string code, string message, JsonObject? details = null)
    {
        var error = new List<KeyValuePair<string, JsonValue>> { new("code", new JsonString(code)) };
        if (details is not null) error.Add(new("details", details));
        error.Add(new("message", new JsonString(message)));
        return Wire.EncodeFrame(new JsonObject(
        [
            new("id", request["id"]),
            new("ok", JsonBool.False),
            new("error", new JsonObject(error)),
        ]), ControlContract.MaxResponseBytes);
    }

    /// <summary>One connection: each complete request frame gets its scripted reply; a null
    /// reply closes the connection (the client then reads end of stream).</summary>
    private sealed class Peer(Func<JsonObject, byte[]?> answer) : Stream
    {
        private readonly MemoryStream _received = new();
        private readonly Queue<byte> _outgoing = new();
        private int _consumed;

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => true;

        public override long Length => throw new NotSupportedException();

        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var count = Math.Min(buffer.Length, _outgoing.Count);
            for (var i = 0; i < count; i++) buffer.Span[i] = _outgoing.Dequeue();
            return ValueTask.FromResult(count);
        }

        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            _received.Write(buffer.Span);
            var all = _received.ToArray();
            while (true)
            {
                var end = Array.IndexOf(all, (byte)'\n', _consumed);
                if (end < 0) break;
                var frame = (JsonObject)StrictJson.Parse(all.AsSpan(_consumed, end - _consumed));
                _consumed = end + 1;
                if (answer(frame) is { } reply)
                {
                    foreach (var b in reply) _outgoing.Enqueue(b);
                }
            }
            return ValueTask.CompletedTask;
        }

        public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

        public override void Write(byte[] buffer, int offset, int count) => WriteAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

        public override void Flush() { }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
