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
public static partial class ScriptedDaemon
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

    /// <summary><see cref="Foundation"/> for the first five connections (the start reads the
    /// Overview's health, doctor, Jobs and device observations and the Job Inspector's Jobs), then nothing answers:
    /// the daemon goes away while the App shows its data.</summary>
    public const string Outage = "outage";

    /// <summary><see cref="Jobs"/> with two records that need a person now (a Flash waiting for
    /// recovery, a HAP debug run to resume at a confirmed safe boundary): the global Job
    /// recovery banner shows them.</summary>
    public const string Recovery = "recovery";

    public const string WaitingForRecoveryJobId = "job-0000000000000000000000000000a0f1";
    public const string ResumeSafeJobId = "job-0000000000000000000000000000a0f2";

    /// <summary>A capture of <see cref="Recovery"/> with a published <c>capture.log</c> and two
    /// device cleanup items left.</summary>
    public const string LogJobId = "job-0000000000000000000000000000a0f3";

    /// <summary>A Flash of <see cref="Recovery"/> whose outcome stays unknown, superseded by a
    /// later confirmed recovery epoch (so it needs no one now).</summary>
    public const string SupersededJobId = "job-0000000000000000000000000000a0f4";

    public const string SupersedingEpochId = "epoch-0000000000000000000000000000e001";

    /// <summary>A daemon with a Job store, an Artifact owner and devices: three candidates, one
    /// adopted Target, three Jobs (a running one whose state advances on each
    /// <c>job.status</c> read) with their Artifacts; no Trace inspector, so
    /// <c>trace.inspect</c> is refused as on Windows today.</summary>
    public const string Jobs = "jobs";

    /// <summary>The Windows daemon over a development state root, with the Target owners
    /// (TASK-XPA-004) and the Job and Session owners (TASK-XPA-005, #2385): the Target store holds
    /// the Swift adoption oracle's Target, whose display name can be set and cleared; the Job
    /// store is empty; the Session catalog holds the recorded observe.device@1 Sessions, which
    /// can be pinned, exported and cleaned up; no HDC (<c>device.observations</c> refused), no
    /// Artifact of a Job, no Trace inspector.</summary>
    public const string DevelopmentRoot = "targets";

    /// <summary><see cref="Jobs"/> with a Trace inspector: <c>trace.inspect</c> answers the
    /// recorded ArkTrace projection (rust/tests/fixtures/trace-inspect, "base").</summary>
    public const string Inspector = "inspector";

    public static readonly IReadOnlyList<string> Scenarios = [Unavailable, ContractMismatch, Foundation, Recovers, Outage, Jobs, DevelopmentRoot, Inspector, Flash, Viewer, Diagnostics, Recovery];

    public const string RunningJobId = "job-0000000000000000000000000000a001";
    public const string FailedJobId = "job-0000000000000000000000000000a002";
    public const string TraceJobId = "job-0000000000000000000000000000a003";

    /// <summary>A queued Job of <see cref="Jobs"/> that stays queued until it is cancelled.</summary>
    public const string QueuedJobId = "job-0000000000000000000000000000a004";

    /// <summary>The recorded Swift observe.device@1 Sessions (rust/tests/fixtures/observe-device/sessions),
    /// as the Windows Session owner lists them.</summary>
    public const string ObservedSessionId = "session-job-0f77f8c52864d676372962eccb17389c";

    public const string FailedSessionId = "session-job-efd52ab9c633074171a19ddd916fffd9";
    /// <summary>The agent executions of <see cref="Jobs"/> (the recorded Swift human-action
    /// corpus, rust/tests/fixtures/agent-human-action): one waiting for a device to be connected,
    /// one waiting for a person to pick one of two devices, one completed.</summary>
    public const string ConnectExecutionId = "har-connect";

    public const string AmbiguousExecutionId = "har-ambiguous";

    public const string CompletedExecutionId = "har-completed";

    /// <summary>The committed Import of <see cref="Jobs"/>.</summary>
    public const string CommittedImportId = "imp-dcb7943f-d934-43da-b290-65d0066cae35";

    /// <summary>The Windows daemon's <c>trace.probe</c> without an HDC (measured).</summary>
    public const string TraceProbeRefusal = "Trace Runtime probing is not configured";

    /// <summary>The Windows daemon's flash-bundle validator refusing content that is not a DAYU200
    /// images archive (measured).</summary>
    public const string FlashContentRefusal = "Import content failed its registered format validator";

    /// <summary>The Windows daemon's <c>job.plan</c> of a Flash without an ArkForge lane (measured).</summary>
    public const string FlashLaneAbsence = "flash.full-restore@1 is runtime unavailable: no ArkForge lane: ARKDECK_ARKFORGE_BUNDLE_PATH is unset, "
        + "so this daemon performs no Rockchip writes. canonical ArkForge Flash refuses before authorization";

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
        new(LogJobId, "ART-00000000000000000000000000000d01", "capture.log", "text/plain", "standard", "published", "capture.diagnostics@1",
            Encoding.UTF8.GetBytes(string.Concat(Enumerable.Range(1, 250).Select(i => $"capture line {i}\n")))),
    ];

    public static IControlChannel Channel(string scenario)
    {
        if (!Scenarios.Contains(scenario)) throw new ArgumentException($"unknown test transport scenario {scenario}", nameof(scenario));
        var script = new Script(scenario);
        return new StreamChannel(script.Connect, DaemonConfiguration.CallBudget);
    }

    private sealed partial class Script(string scenario)
    {
        private readonly object _gate = new();
        private readonly Dictionary<string, (string? Name, long Generation)> _names = new(StringComparer.Ordinal)
        {
            [OracleTargetId] = (null, 1),
            [FixtureTargetId] = ("Bench board", 1),
        };
        private int _connections;
        private int _statusReads;
        private bool _queuedCancelled;
        private readonly List<(string Id, string Completed, string Expires, long Generation, bool Pinned, string Size)> _sessions = [];
        private readonly Dictionary<string, (string State, long Generation, bool Resolved)> _executions = new(StringComparer.Ordinal)
        {
            [ConnectExecutionId] = ("waitingForHuman", 4, false),
            [AmbiguousExecutionId] = ("waitingForHuman", 3, false),
            [CompletedExecutionId] = ("completed", 12, true),
        };
        private readonly Dictionary<string, JsonObject> _imports = new(StringComparer.Ordinal);
        // The Imports whose first chunk opens a ZIP container (a HAP's publication check).
        private readonly HashSet<string> _zipImports = new(StringComparer.Ordinal);
        private readonly Dictionary<string, MemoryStream> _flashBundles = new(StringComparer.Ordinal);
        private long _catalogGeneration = 2;
        private string? _cleanupPreviewId;

        public Stream Connect()
        {
            var connection = Interlocked.Increment(ref _connections);
            var mode = scenario switch
            {
                Recovers => connection <= 2 ? Unavailable : Foundation,
                Recovery => Jobs,
                Outage => connection <= 5 ? Foundation : Unavailable,
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
                    _ when method.StartsWith("artifact.import.", StringComparison.Ordinal) => Failure(request, "operationUnavailable", "Import owner services are unavailable", Details("importOwner")),
                    _ when method.StartsWith("artifact.", StringComparison.Ordinal) => ArtifactOwnerAbsent(request),
                    "trace.inspect" => NoTraceInspector(request),
                    "trace.probe" => Failure(request, "internalError", TraceProbeRefusal),
                    _ when method.StartsWith("workspace.", StringComparison.Ordinal) => Failure(request, "operationUnavailable", "workspace project owner is unavailable",
                        Details(method.StartsWith("workspace.preset", StringComparison.Ordinal) ? "workspacePresetOwner" : "workspaceProjectOwner")),
                    // No state root, so no agent execution owner (measured on #2391's daemon).
                    _ when method.StartsWith("agent.", StringComparison.Ordinal) || method.StartsWith("human-action.", StringComparison.Ordinal) =>
                        Failure(request, "operationUnavailable", "AgentExecution owner is unavailable", Details("preAdmission")),
                    _ => SettingsOwnerAbsent(request, method),
                },
                DevelopmentRoot => method switch
                {
                    "doctor" => Success(request, Parse(BlockedDoctor)),
                    "device.observations" => Failure(request, "rejected", "hdc.notConfigured"),
                    "job.list" => Success(request, Parse(JobPage([]))),
                    _ when method.StartsWith("job.", StringComparison.Ordinal) => Failure(request, "notFound",
                        "unknown job " + (request.TryGetValue("params", out var jp) && jp is JsonObject jo && jo.TryGetValue("jobId", out var jid) ? ((JsonString)jid).Value : "")),
                    _ when method.StartsWith("session.", StringComparison.Ordinal) => Session(request, method, recorded: true),
                    "runtime.storage.status" => Success(request, Parse(RecordedStorageJson(Recorded()))),
                    "trace.cache.status" => Success(request, Parse("""{"activeEntryCount":0,"entryCount":0,"inactiveEntryCount":0,"purgeScope":"inactiveDerivedDatabases","schemaVersion":"arkdeck.trace-cache-status/1","totalByteCount":"0"}""")),
                    _ when method.StartsWith("target.", StringComparison.Ordinal) => Target(request, method, [OracleTargetId]),
                    "agent.list" => Success(request, Parse(AgentPage([]))),
                    "human-action.list" => Success(request, Parse(HumanActionPage([]))),
                    _ when method.StartsWith("agent.", StringComparison.Ordinal) || method.StartsWith("human-action.", StringComparison.Ordinal) =>
                        Failure(request, "resourceNotFound", "human action does not exist", Details("preAdmission")),
                    _ when method.StartsWith("artifact.import.", StringComparison.Ordinal) => Import(request, method, OracleTargetId, 1),
                    _ when method.StartsWith("artifact.", StringComparison.Ordinal) => ArtifactOwnerAbsent(request),
                    "trace.inspect" => NoTraceInspector(request),
                    "trace.probe" => Failure(request, "internalError", TraceProbeRefusal),
                    _ when method.StartsWith("workspace.", StringComparison.Ordinal) => Workspace(request, method),
                    _ => SettingsOwnerAbsent(request, method),
                },
                _ => (mode == Flash ? FlashRoute(request, method) : null) ?? (mode == Viewer ? ViewerRoute(request, method) : null) ?? (mode == Diagnostics ? DiagnosticsRoute(request, method) : null) ?? Debug(request, method) ?? method switch
                {
                    "doctor" => Success(request, Parse(HealthyDoctor)),
                    "device.observations" => Success(request, Parse(Observations)),
                    "job.list" => Success(request, Parse(JobPage([.. DebugJobRows(), .. JobsNow().Select(j => JobJson(j, list: true))]))),
                    "job.status" => JobStatus(request),
                    "job.events" => JobEvents(request),
                    _ when method.StartsWith("target.", StringComparison.Ordinal) => Target(request, method, [FixtureTargetId]),
                    "artifact.list" => ArtifactList(request),
                    "artifact.read" => ArtifactRead(request),
                    "trace.inspect" => mode == Inspector ? TraceInspect(request) : NoTraceInspector(request),
                    "trace.probe" => Failure(request, "internalError", TraceProbeRefusal),
                    "job.cancel" => JobCancel(request),
                    "job.result" => JobResult(request),
                    "job.evidence" => JobEvidence(request),
                    _ when method.StartsWith("session.", StringComparison.Ordinal) => Session(request, method, recorded: false),
                    _ when method.StartsWith("agent.", StringComparison.Ordinal) || method.StartsWith("human-action.", StringComparison.Ordinal) => Agent(request, method),
                    _ when method.StartsWith("artifact.import.", StringComparison.Ordinal) => Import(request, method, FixtureTargetId, 3),
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
            (QueuedJobId, "observe.device@1", _queuedCancelled ? "cancelled" : "queued", "2026-09-30T08:04:00Z"),
            .. scenario == Recovery
                ? new[] { (ResumeSafeJobId, "debug.hap@1", "resumeAtConfirmedSafeBoundary", "2026-09-30T07:58:00Z"),
                          (WaitingForRecoveryJobId, "flash.full-restore@1", "waitingForRecovery", "2026-09-30T07:59:00Z"),
                          (LogJobId, "capture.diagnostics@1", "succeeded", "2026-09-30T07:57:00Z"),
                          (SupersededJobId, "flash.full-restore@1", "interrupted", "2026-09-30T07:56:00Z") }
                : [],
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
            if (jobId is not (RunningJobId or FailedJobId or TraceJobId or LogJobId)) return Failure(request, "notFound", "no such Job", ArtifactDetails);
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

        /// <summary><c>job.cancel</c>: the queued Job is cancelled at once (it never ran); an
        /// active one is asked to stop at a safe boundary.</summary>
        private byte[] JobCancel(JsonObject request)
        {
            var id = ((JsonString)request["params"]["jobId"]).Value;
            var job = JobsNow().FirstOrDefault(j => j.Id == id);
            if (job.Id is null) return Failure(request, "notFound", "unknown job " + id);
            if (id == QueuedJobId) _queuedCancelled = true;
            return Success(request, new JsonObject([new("cancelRequested", JsonBool.Of(!Presentation.JobSummary.TerminalStates.Contains(job.State)))]));
        }

        /// <summary><c>job.result</c> as the Runtime answers it: a terminal Job's verified
        /// Artifacts and evidence; for any other, <c>resultNotReady</c>.</summary>
        private byte[] JobResult(JsonObject request)
        {
            var id = ((JsonString)request["params"]["jobId"]).Value;
            var job = JobsNow().FirstOrDefault(j => j.Id == id);
            if (job.Id is null) return Failure(request, "notFound", "unknown job " + id);
            if (!Presentation.JobSummary.TerminalStates.Contains(job.State))
            {
                return Failure(request, "resultNotReady", "the Job has no terminal result yet", new JsonObject(
                [
                    new("jobId", new JsonString(id)),
                    new("newDispatchCount", JsonNumber.FromInt64(0)),
                    new("nextAction", Parse($$"""{"kind":"wait","owner":{"id":"{{id}}","kind":"job"},"reasonCode":"job.running","resource":{"id":"{{id}}","kind":"job"},"retryAfter":"250ms"}""")),
                    new("phase", new JsonString("preAdmission")),
                    new("state", new JsonString(job.State)),
                ]));
            }
            var artifacts = Artifacts.Where(a => a.JobId == id).Select(a => (JsonValue)Parse($$"""
                {"artifactId":"{{a.Id}}","byteCount":"{{a.Bytes.Length}}","bytesVerified":{{(a.Status == "published" ? "true" : "false")}},"mediaType":"{{a.MediaType}}","name":"{{a.Name}}","owner":{"id":"{{id}}","kind":"job"},"privacy":"{{a.Privacy}}","reference":"arkdeck-artifact://{{id}}/{{a.Id}}","sha256":"{{a.Sha256}}","status":"{{a.Status}}"}
                """));
            return Success(request, new JsonObject(
            [
                new("artifacts", new JsonArray(artifacts)),
                new("cleanup", new JsonArray([])),
                new("evidence", Evidence(job)),
                new("job", Parse(JobJson(job, list: false))),
                new("nextAction", JsonNull.Instance),
                new("outcomeUnknown", JsonBool.False),
                new("schemaVersion", new JsonString("arkdeck.job-result/1")),
                new("terminal", JsonBool.True),
            ]));
        }

        private byte[] JobEvidence(JsonObject request)
        {
            var id = ((JsonString)request["params"]["jobId"]).Value;
            var job = JobsNow().FirstOrDefault(j => j.Id == id);
            return job.Id is null ? Failure(request, "notFound", "unknown job " + id) : Success(request, Evidence(job));
        }

        /// <summary>The recorded Swift evidence of an observe.device@1 Job (rust/tests/fixtures/observe-device,
        /// "observed.evidence"), restated for this Job.</summary>
        private static JsonObject Evidence((string Id, string Operation, string State, string Created) job)
        {
            var terminal = Presentation.JobSummary.TerminalStates.Contains(job.State);
            return (JsonObject)Parse($$"""
                {"actualEffect":{{(terminal ? "\"readOnly\"" : "null")}},"actualStepKinds":{{(terminal ? "[\"probeHostTool\",\"probeHDCServer\",\"probeDevice\"]" : "null")}},"artifacts":[],"authority":{"admittedAtUtc":"{{job.Created}}","consumptionFingerprintSha256":null,"kind":"defaultReadOnlyPolicy","recoveryEpoch":null,"reference":"default-read-only-policy","validUntilUtc":null},"bindingRevision":3,"blockers":{{(job.State == "failed" ? "[\"executionFailed\"]" : "[]")}},"catalogDigest":"508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684","executionMode":"execute","finishedAtUtc":{{(terminal ? $"\"{job.Created}\"" : "null")}},"firstEvidenceStepAtUtc":{{(terminal ? $"\"{job.Created}\"" : "null")}},"inventoryAvailable":true,"jobId":"{{job.Id}}","missingRequiredArtifacts":[],"observation":null,"operationReference":"{{job.Operation}}","outcomeUnknown":false,"parameters":{},"providerId":"hdc","recoveryEpoch":null,"schemaVersion":"arkdeck.job-evidence/1","startedAtUtc":"{{job.Created}}","status":"{{(job.State == "succeeded" ? "verified" : terminal ? job.State : "resultNotReady")}}","targetId":"TGT-FIXTURE-1","terminalState":{{(terminal ? $"\"{job.State}\"" : "null")}},"traceProbeAfter":null,"traceProbeBefore":null}
                """);
        }

        /// <summary>The recorded Sessions (as the Windows Session owner lists them over the
        /// fixture), or the scripted Jobs' Sessions; both kept in this Script's catalog.</summary>
        private List<(string Id, string Completed, string Expires, long Generation, bool Pinned, string Size)> Catalog(bool recorded)
        {
            if (_sessions.Count == 0)
            {
                if (recorded)
                {
                    _sessions.Add((ObservedSessionId, "2026-09-14T00:00:00Z", "2026-12-13T00:00:00Z", 2, false, "13586"));
                    _sessions.Add((FailedSessionId, "2026-09-14T00:00:00Z", "2026-12-13T00:00:00Z", 2, false, "7013"));
                }
                else
                {
                    _sessions.Add(("session-" + TraceJobId, "2026-09-30T08:00:00Z", "2026-09-29T08:00:00Z", 1, false, "300512"));
                    _sessions.Add(("session-" + FailedJobId, "2026-09-30T08:01:00Z", "2026-12-29T08:01:00Z", 1, true, "4096"));
                }
            }
            return _sessions;
        }

        private List<(string Id, string Completed, string Expires, long Generation, bool Pinned, string Size)> Recorded() => Catalog(recorded: true);

        private static string SessionJson((string Id, string Completed, string Expires, long Generation, bool Pinned, string Size) s) => $$"""
            {"completedAtUtc":"{{s.Completed}}","expiresAtUtc":"{{s.Expires}}","generation":"{{s.Generation}}","pinned":{{(s.Pinned ? "true" : "false")}},"policyGeneration":"1","schemaVersion":"arkdeck.session/1","sessionId":"{{s.Id}}","sizeBytes":"{{s.Size}}"}
            """;

        /// <summary>The Session owner (TASK-XPA-005 H3b): the catalog, generation-guarded pin
        /// and unpin, the cleanup preview-then-apply and the export preview-then-apply, as the
        /// Windows daemon answered them over the recorded Sessions.</summary>
        private byte[] Session(JsonObject request, string method, bool recorded)
        {
            var catalog = Catalog(recorded);
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            var details = new JsonObject([new("newDispatchCount", JsonNumber.FromInt64(0)), new("phase", new JsonString("sessionOwner"))]);
            switch (method)
            {
                case "session.list":
                    return Success(request, Parse($$"""
                        {"hasMore":false,"items":[{{string.Join(",", catalog.Select(SessionJson))}}],"nextCursor":null,"order":"completedAtDescSessionIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"4c48c179-cf2c-4baa-941d-96b1c439e9ce"}
                        """));
                case "session.show" or "session.pin" or "session.unpin" or "session.export.preview":
                {
                    var index = catalog.FindIndex(s => s.Id == Param("sessionId"));
                    if (index < 0) return Failure(request, "resourceNotFound", "Session is not in the catalog", details);
                    var session = catalog[index];
                    if (method == "session.show") return Success(request, Parse(SessionJson(session)));
                    if (method == "session.export.preview")
                    {
                        var destination = Param("destinationPath") ?? "";
                        return Success(request, Parse($$$"""
                            {"allowSensitive":false,"artifacts":[],"catalogStatus":{"blocker":null,"complete":true,"measurementIncomplete":false,"unaccountedSessionCount":"0","usedBytes":"20599"},"confirmationRequired":true,"createdAtUtc":"2026-09-30T10:11:17Z","destination":{"expectedState":"absent","parentDevice":"1736215490155947674","parentInode":"41095346600272962","path":{{{Quote(destination)}}},"volumeIdentity":"uuid:7b793737-7c74-481d-a8e2-c3560ae073f3"},"deviceIdentifierPolicy":"redact","digestAlgorithm":"sha256-jcs","estimatedBytes":"4672","expiresAtUtc":"2026-09-30T10:21:17Z","generation":"{{{_catalogGeneration}}}","newDispatchCount":0,"policyGeneration":"1","previewDigest":"9ea90421f897ee80c1719aa1b02d78e75505ea648fe95f967c2796ffeb6c0c12","previewId":"84810dd9-9897-4cfe-810c-3c48ab1d31a1","schemaVersion":"arkdeck.session-export-preview/1","sensitiveDefaultExcluded":true,"sessionId":"{{{session.Id}}}","source":{"jobId":"{{{session.Id["session-".Length..]}}}","journalSha256":"1d97fa23a3819289a720d379233a5b4b42ec7f6c589f224624ad4ab6a65fd69c","manifestSha256":"fcd29f3f78aa58ae3fc82aecd1d5c1f1d3f11d546862c05bfb1763f2a61d5c3d","rootDevice":"1736215490155947674","rootInode":"48695170971460554","sessionDevice":"1736215490155947674","sessionInode":"49258120924882116","volumeIdentity":"uuid:7b793737-7c74-481d-a8e2-c3560ae073f3"}}
                            """));
                    }
                    if (Param("expectedGeneration") != session.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    {
                        return Failure(request, "resourceConflict", "Session catalog generation changed", details);
                    }
                    session = session with { Generation = session.Generation + 1, Pinned = method == "session.pin" };
                    catalog[index] = session;
                    _catalogGeneration++;
                    return Success(request, Parse(SessionJson(session)));
                }
                case "session.export.apply":
                    if (Param("previewId") != "84810dd9-9897-4cfe-810c-3c48ab1d31a1") return Failure(request, "resourceConflict", "export preview is stale", details);
                    return Success(request, Parse($$"""
                        {"catalogStatus":{"blocker":null,"complete":true,"measurementIncomplete":false,"unaccountedSessionCount":"0","usedBytes":"20599"},"deviceIdentifierPolicy":"redact","evidenceClass":"derivedExport","excludedArtifactIds":[],"exportedPath":"C:\\Exports\\session","generation":"{{_catalogGeneration}}","newDispatchCount":0,"previewDigest":"9ea90421f897ee80c1719aa1b02d78e75505ea648fe95f967c2796ffeb6c0c12","previewId":"84810dd9-9897-4cfe-810c-3c48ab1d31a1","publishedAtUtc":"2026-09-30T10:11:17Z","resultGeneration":"{{_catalogGeneration}}","schemaVersion":"arkdeck.session-export-result/1","sessionId":"{{catalog[0].Id}}","source":{"jobId":"{{catalog[0].Id["session-".Length..]}}","journalSha256":"1d97fa23a3819289a720d379233a5b4b42ec7f6c589f224624ad4ab6a65fd69c","manifestSha256":"fcd29f3f78aa58ae3fc82aecd1d5c1f1d3f11d546862c05bfb1763f2a61d5c3d","rootDevice":"1736215490155947674","rootInode":"48695170971460554","sessionDevice":"1736215490155947674","sessionInode":"49258120924882116","volumeIdentity":"uuid:7b793737-7c74-481d-a8e2-c3560ae073f3"},"sourceArtifactIds":[]}
                        """));
                case "session.cleanup.preview":
                {
                    _cleanupPreviewId = "9bee03f1-41a0-4fe8-9660-ef746acc2319-" + _catalogGeneration;
                    var rows = catalog.Select(s => $$"""
                        {"activeLease":false,"artifacts":[],"disposition":"{{(s.Pinned ? "retain" : "reclaim")}}","expiresAtUtc":"{{s.Expires}}","pinned":{{(s.Pinned ? "true" : "false")}},"reason":"{{(s.Pinned ? "pinned" : "expiredQuotaPressure")}}","sessionId":"{{s.Id}}","sizeBytes":"{{s.Size}}"}
                        """);
                    var reclaim = catalog.Where(s => !s.Pinned).Sum(s => long.Parse(s.Size, System.Globalization.CultureInfo.InvariantCulture));
                    var current = catalog.Sum(s => long.Parse(s.Size, System.Globalization.CultureInfo.InvariantCulture));
                    return Success(request, Parse($$"""
                        {"blocksNewHeavyWriters":true,"confirmationRequired":true,"createdAtUtc":"2026-09-30T10:11:17Z","currentBytes":"{{current}}","digestAlgorithm":"sha256-jcs","expiresAtUtc":"2026-09-30T10:21:17Z","generation":"{{_catalogGeneration}}","newDispatchCount":0,"policyGeneration":"2","previewDigest":"239d73c4cd46906fc2b9ba23844a0162993e9dfbb522573d2d1d0a734d867147","previewId":"{{_cleanupPreviewId}}","projectedBytes":"{{current - reclaim}}","reclaimBytes":"{{reclaim}}","safetyTargetBytes":"1","schemaVersion":"arkdeck.session-cleanup-preview/1","sessions":[{{string.Join(",", rows)}}]}
                        """));
                }
                case "session.cleanup.apply":
                {
                    if (_cleanupPreviewId is null || Param("previewId") != _cleanupPreviewId) return Failure(request, "resourceConflict", "cleanup preview is stale", details);
                    var removed = catalog.Where(s => !s.Pinned).ToList();
                    catalog.RemoveAll(s => !s.Pinned);
                    _catalogGeneration++;
                    _cleanupPreviewId = null;
                    var reclaimed = removed.Sum(s => long.Parse(s.Size, System.Globalization.CultureInfo.InvariantCulture));
                    var remaining = catalog.Sum(s => long.Parse(s.Size, System.Globalization.CultureInfo.InvariantCulture));
                    return Success(request, Parse($$"""
                        {"appliedAtUtc":"2026-09-30T10:11:17Z","generation":"{{_catalogGeneration - 1}}","newDispatchCount":0,"previewDigest":"239d73c4cd46906fc2b9ba23844a0162993e9dfbb522573d2d1d0a734d867147","previewId":"{{Param("previewId")}}","reclaimedBytes":"{{reclaimed}}","remainingBytes":"{{remaining}}","removedArtifacts":[],"removedSessionIds":[{{string.Join(",", removed.Select(s => $"\"{s.Id}\""))}}],"resultGeneration":"{{_catalogGeneration}}","schemaVersion":"arkdeck.session-cleanup-result/1"}
                        """));
                }
                default:
                    return Failure(request, "rejected", "not scripted");
            }
        }

        /// <summary>The storage status the Windows daemon answered over the recorded Sessions.</summary>
        private static string RecordedStorageJson(List<(string Id, string Completed, string Expires, long Generation, bool Pinned, string Size)> sessions)
        {
            var used = sessions.Sum(s => long.Parse(s.Size, System.Globalization.CultureInfo.InvariantCulture));
            var pinned = sessions.Where(s => s.Pinned).ToList();
            return $$$"""
                {"artifactDomain":{"policy":"refuseNewWorkNeverEvict","remainingBytes":"8589934592","rootReference":"arkdeck-runtime://artifacts","schemaVersion":"arkdeck.artifact-storage-status/1","totalBytes":"8589934592","usedBytes":"0"},"schemaVersion":"arkdeck.runtime-storage/1","sessionDomain":{"catalogGeneration":"2","generation":"1","policy":{"retentionDays":"90","safetyMarginBytes":"2147483648","totalQuotaBytes":"21474836480"},"rootKind":"default","rootPath":"C:\\Users\\Example\\AppData\\Local\\Temp\\ad-root\\sessions","schemaVersion":"arkdeck.session-storage-status/1","usage":{"measurementIncomplete":false,"pinnedBytes":"{{{pinned.Sum(s => long.Parse(s.Size, System.Globalization.CultureInfo.InvariantCulture))}}}","pinnedSessionCount":"{{{pinned.Count}}}","sessionCount":"{{{sessions.Count}}}","unaccountedSessionCount":"0","usedBytes":"{{{used}}}"
                """ + "}}}";
        }

        /// <summary>The Settings reads of the Windows daemon without their owners (its real answers).</summary>
        private static byte[] SettingsOwnerAbsent(JsonObject request, string method) => method switch
        {
            "runtime.tool.list" or "runtime.bundle.list" => Failure(request, "operationUnavailable", "Bootstrap bundle list owner is not configured", Details("bootstrapRegistryOwner")),
            "runtime.storage.status" => Failure(request, "rejected", "Runtime storage owners are not configured", Details("runtimeStorageOwner")),
            _ when method.StartsWith("session.", StringComparison.Ordinal) => Failure(request, "rejected", "Session owner is not configured"),
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

        /// <summary>The content of a flash-bundle Import through the host's DAYU200 import policy,
        /// as the Windows daemon's registered validator reads it.</summary>
        private bool IsFlashBundle(string id)
        {
            var path = Path.Combine(Path.GetTempPath(), "arkdeck-scripted-" + Guid.NewGuid().ToString("N") + ".tar.gz");
            try
            {
                File.WriteAllBytes(path, _flashBundles.TryGetValue(id, out var bundle) ? bundle.ToArray() : []);
                return Presentation.FlashArchive.ValidateForImport(path).Error is null;
            }
            finally
            {
                File.Delete(path);
            }
        }

        private static JsonObject Details(string phase) => new(
        [
            new("newDispatchCount", JsonNumber.FromInt64(0)),
            new("phase", new JsonString(phase)),
        ]);

        // ---- Agent executions and human actions (the recorded Swift corpus) ----

        private static string HumanActionJson(string execution, string status)
        {
            var (id, category, minimum, reason, choices, schema, resume) = execution == AmbiguousExecutionId
                ? ("<har-3>", "ambiguousIdentity", "human.confirmDeviceIdentity", "device.identityAmbiguous",
                    """[{"candidateKey":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","value":"<candidate-1>"},{"candidateKey":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","value":"<candidate-2>"}]""",
                    """{"enum":["<candidate-1>","<candidate-2>"],"type":"string"}""", "<resume-3>")
                : ("<har-1>", "physicalConnection", "human.connectOrPowerDevice", "device.notObserved", "[]", "null", "<resume-1>");
            return $$"""
                {"actionId":"{{id}}","category":"{{category}}","choices":{{choices}},"createdAt":"2026-09-14T00:00:00.000Z","expiresAt":"2026-09-14T00:05:00.000Z","minimumAction":"{{minimum}}","newDispatchCount":0,"owner":{"id":"{{execution}}","kind":"agentExecution"},"reasonCode":"{{reason}}","resumeReference":"{{resume}}","schemaVersion":"arkdeck.human-action/1","selectionSchema":{{schema}},"status":"{{status}}"}
                """;
        }

        private string ExecutionJson(string id, bool withHumanAction)
        {
            var (state, generation, resolved) = _executions[id];
            var waiting = state == "waitingForHuman";
            var job = state is "jobOwned" or "completed" ? "job-d166d1a72b51eb3b14528dae5cac37ee" : null;
            var next = waiting
                ? $$"""{"expiresAt":"2026-09-14T00:05:00.000Z","kind":"humanAction","owner":{"id":"{{id}}","kind":"agentExecution"},"reasonCode":"{{(id == AmbiguousExecutionId ? "device.identityAmbiguous" : "device.notObserved")}}","resource":{"id":"{{(id == AmbiguousExecutionId ? "<har-3>" : "<har-1>")}}","kind":"humanAction"},"resumeReference":"{{(id == AmbiguousExecutionId ? "<resume-3>" : "<resume-1>")}}"}"""
                : state == "jobOwned" ? $$"""{"kind":"wait","owner":{"id":"{{job}}","kind":"job"},"reasonCode":"job.running","resource":{"id":"{{job}}","kind":"job"},"retryAfter":"250ms"}""" : "null";
            var human = withHumanAction ? (waiting || resolved && id != CompletedExecutionId ? HumanActionJson(id, waiting ? "waiting" : "resolved") : "null") + "," : "";
            return $$"""
                {"bindingRevision":{{(job is null ? "null" : "1")}},"catalogDigest":"508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684","createdAt":"2026-09-14T00:00:00.000Z","deadline":"2026-09-14T00:05:00.000Z","executionId":"{{id}}","failureCode":null,"generation":"{{generation}}",{{(withHumanAction ? "\"humanAction\":" + human : "")}}"jobId":{{(job is null ? "null" : $"\"{job}\"")}},"jobState":{{(job is null ? "null" : state == "completed" ? "\"succeeded\"" : "\"running\"")}},"lastObservedAt":"2026-09-14T00:00:00.000Z","nextAction":{{next}},"operation":"observe.device@1","outcomeUnknown":false,"schemaVersion":"arkdeck.agent-execution/1","state":"{{state}}","targetId":{{(job is null ? "null" : "\"TGT-3ba3f5f43b92\"")}}}
                """;
        }

        /// <summary>The recorded answer of a resume that handed the execution to its Job
        /// (agent-human-action "connect.resume").</summary>
        private static string ResumedJson(string id, long generation) => $$"""
            {"bindingRevision":1,"catalogDigest":"508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684","createdAt":"2026-09-14T00:00:00.000Z","deadline":"2026-09-14T00:05:00.000Z","executionId":"{{id}}","failureCode":null,"generation":"{{generation}}","humanAction":null,"job":{"jobId":"job-d166d1a72b51eb3b14528dae5cac37ee","outcome":"running","outcomeUnknown":false,"outstandingResidueCount":null,"sessionPublication":{"catalogGeneration":null,"manifestSha256":null,"reasonCode":"noCurrentPublicationRecord","state":"unavailable"},"state":"running","waitingForHuman":false},"jobId":"job-d166d1a72b51eb3b14528dae5cac37ee","jobState":"running","lastObservedAt":"2026-09-14T00:00:00.000Z","nextAction":{"kind":"wait","owner":{"id":"job-d166d1a72b51eb3b14528dae5cac37ee","kind":"job"},"reasonCode":"job.running","resource":{"id":"job-d166d1a72b51eb3b14528dae5cac37ee","kind":"job"},"retryAfter":"250ms"},"operation":"observe.device@1","outcomeUnknown":false,"schemaVersion":"arkdeck.agent-execution/1","state":"jobOwned","targetId":"TGT-3ba3f5f43b92"}
            """;

        private static string AgentPage(IEnumerable<string> rows) => $$"""
            {"hasMore":false,"items":[{{string.Join(",", rows)}}],"nextCursor":null,"order":"createdAtDescExecutionIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"5a1d7a4e-0000-4000-8000-000000000003"}
            """;

        private static string HumanActionPage(IEnumerable<string> rows) => $$"""
            {"hasMore":false,"items":[{{string.Join(",", rows)}}],"nextCursor":null,"order":"createdAtDescActionIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"5a1d7a4e-0000-4000-8000-000000000004"}
            """;

        /// <summary>The agent execution owner (TASK-XPA-005 S1) over the recorded executions:
        /// status, list, the human actions, resume (the selection must be one of the action's
        /// values; a physical action takes none) and generation-guarded abandon.</summary>
        private byte[] Agent(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            var pre = Details("preAdmission");
            string? ExecutionOf(string? action) => action switch { "<har-1>" => ConnectExecutionId, "<har-3>" => AmbiguousExecutionId, _ => null };
            switch (method)
            {
                case "agent.list":
                    return Success(request, Parse(AgentPage(_executions.Keys.Select(id => ExecutionJson(id, withHumanAction: false)))));
                case "agent.status":
                {
                    var id = Param("executionId");
                    return id is not null && _executions.ContainsKey(id) ? Success(request, Parse(ExecutionJson(id, withHumanAction: true)))
                        : Failure(request, "resourceNotFound", "agent execution does not exist", Details("agentExecutionOwner"));
                }
                case "human-action.list":
                    return Success(request, Parse(HumanActionPage(_executions.Where(e => e.Value.State == "waitingForHuman").Select(e => HumanActionJson(e.Key, "waiting")))));
                case "human-action.show":
                {
                    var execution = ExecutionOf(Param("humanAction"));
                    if (execution is null) return Failure(request, "resourceNotFound", "human action does not exist", pre);
                    return Success(request, Parse(HumanActionJson(execution, _executions[execution].State == "waitingForHuman" ? "waiting" : "resolved")));
                }
                case "human-action.resume" or "agent.resume":
                {
                    var execution = method == "agent.resume"
                        ? Param("resumeReference") switch { "<resume-1>" => ConnectExecutionId, "<resume-3>" => AmbiguousExecutionId, _ => null }
                        : ExecutionOf(Param("humanAction"));
                    if (execution is null) return Failure(request, "resourceNotFound", "human action does not exist", pre);
                    var selection = Param("selection");
                    if (execution == ConnectExecutionId && selection is not null) return Failure(request, "invalidInput", "this physical action accepts no selection", pre);
                    if (execution == AmbiguousExecutionId && selection is not ("<candidate-1>" or "<candidate-2>"))
                    {
                        return Failure(request, "invalidInput", "selection must be an opaque value from this action's schema", pre);
                    }
                    var (state, generation, _) = _executions[execution];
                    if (state != "waitingForHuman") return Failure(request, "resourceConflict", "the human action is no longer waiting", pre);
                    _executions[execution] = ("jobOwned", generation + 6, true);
                    return Success(request, Parse(ResumedJson(execution, generation + 6)));
                }
                case "agent.abandon":
                {
                    var id = Param("executionId");
                    if (id is null || !_executions.TryGetValue(id, out var current)) return Failure(request, "resourceNotFound", "agent execution does not exist", Details("agentExecutionOwner"));
                    if (Param("expectedGeneration") != current.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    {
                        return Failure(request, "resourceConflict", "execution generation changed", Details("agentExecutionOwner"));
                    }
                    _executions[id] = ("abandoned", current.Generation + 1, current.Resolved);
                    return Success(request, Parse($$"""
                        {"bindingRevision":null,"catalogDigest":"508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684","createdAt":"2026-09-14T00:00:00.000Z","deadline":"2026-09-14T00:05:00.000Z","executionId":"{{id}}","failureCode":null,"generation":"{{current.Generation + 1}}","humanAction":null,"jobId":null,"jobState":null,"lastObservedAt":"2026-09-14T00:00:00.000Z","nextAction":null,"operation":"observe.device@1","outcomeUnknown":false,"schemaVersion":"arkdeck.agent-execution/1","state":"abandoned","targetId":null}
                        """));
                }
                default:
                    return Failure(request, "rejected", "not scripted");
            }
        }

        // ---- Imports (the recorded Swift upload, rust/tests/fixtures/import-upload-current) ----

        private static JsonObject ImportJson(string id, JsonObject metadata, long generation, string state, long offset, JsonValue receipt) => new(
        [
            new("createdAtUtc", new JsonString("2026-09-01T00:00:00Z")),
            new("generation", new JsonString(generation.ToString(System.Globalization.CultureInfo.InvariantCulture))),
            new("importId", new JsonString(id)),
            new("importRequestId", metadata["importRequestId"]),
            new("maximumChunkBytes", new JsonString("2097152")),
            new("metadata", metadata),
            new("metadataFingerprint", new JsonString(Sha256Hex(Encoding.UTF8.GetBytes(metadata.ToString())))),
            new("nextOffset", new JsonString(offset.ToString(System.Globalization.CultureInfo.InvariantCulture))),
            new("receipt", receipt),
            new("schemaVersion", new JsonString("arkdeck.import/1")),
            new("state", new JsonString(state)),
            new("updatedAtUtc", new JsonString("2026-09-01T00:00:00Z")),
        ]);

        private static JsonObject Receipt(string id, JsonObject metadata, long generation) => (JsonObject)Parse($$"""
            {"artifactDigest":"{{((JsonString)metadata["sha256"]).Value}}","artifactId":"ART-{{Sha256Hex(Encoding.UTF8.GetBytes(id))[..32]}}","bindingRevision":"{{((JsonString)metadata["bindingRevision"]).Value}}","byteCount":"{{((JsonString)metadata["byteCount"]).Value}}","generation":"{{generation}}","importId":"{{id}}","importRequestId":"{{((JsonString)metadata["importRequestId"]).Value}}","lease":"lease-v1:{{id}}:ART-{{Sha256Hex(Encoding.UTF8.GetBytes(id))[..32]}}","mediaType":"{{(((JsonString)metadata["kind"]).Value == "hap" ? "application/vnd.openharmony.hap" : "application/octet-stream")}}","name":"{{((JsonString)metadata["name"]).Value}}","owner":{"id":"{{id}}","kind":"import"},"privacy":"standard","schemaVersion":"arkdeck.import-receipt/1","targetId":"{{((JsonString)metadata["targetId"]).Value}}","validation":{"kind":"{{((JsonString)metadata["kind"]).Value}}"{{NativeFacts(metadata)}}
            """ + "}}");

        /// <summary>A native library's ELF facts as the Runtime's Import validation reports them
        /// (the deploy-native-library oracle's library: arm64-v8a, ELF64, machine 183).</summary>
        private static string NativeFacts(JsonObject metadata) => ((JsonString)metadata["kind"]).Value == "native-library"
            ? ",\"abi\":\"arm64-v8a\",\"buildId\":\"00112233445566778899aabbccddeeff10213243\",\"elfClassBits\":64,\"machine\":183"
            : "";

        private JsonObject Get(string id) => _imports[id];

        /// <summary>The Import owner (TASK-XPA-008 H3) over one adopted Target: begin, bounded
        /// appends (offset, count and SHA-256 checked), commit (a flash bundle refused before
        /// anything is published), abort, list, inspect and generation-guarded release.</summary>
        private byte[] Import(JsonObject request, string method, string target, long binding)
        {
            if (_imports.Count == 0 && target == FixtureTargetId)
            {
                var metadata = (JsonObject)Parse($$"""
                    {"bindingRevision":"3","byteCount":"4096","deviceProfile":null,"importRequestId":"rust-import-upload","kind":"hap","name":"fixture.hap","schemaVersion":"arkdeck.import-intent/1","sha256":"399a301718f951e835b8630ac1666120b96eefb28da9e37f568596a227a9b67a","targetId":"{{FixtureTargetId}}"}
                    """);
                _imports[CommittedImportId] = ImportJson(CommittedImportId, metadata, 2, "committed", 4096, Receipt(CommittedImportId, metadata, 2));
            }
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            var owner = Details("importOwner");
            JsonObject Meta(JsonObject import) => (JsonObject)import["metadata"];
            long Long(JsonObject o, string key) => long.Parse(((JsonString)o[key]).Value, System.Globalization.CultureInfo.InvariantCulture);
            switch (method)
            {
                case "artifact.import.list":
                    return Success(request, Parse($$"""
                        {"hasMore":false,"items":[{{string.Join(",", _imports.Values.Select(i => i.ToString()))}}],"nextCursor":null,"order":"createdAtDescImportIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"5a1d7a4e-0000-4000-8000-000000000005"}
                        """));
                case "artifact.import.inspect":
                    return Param("importId") is { } inspected && _imports.TryGetValue(inspected, out var shown) ? Success(request, shown)
                        : Failure(request, "resourceNotFound", "Import does not exist", owner);
                case "artifact.import.begin":
                {
                    if (Param("targetId") != target || Param("bindingRevision") != binding.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    {
                        return Failure(request, "resourceConflict", "the exact target binding is no longer current", owner);
                    }
                    var metadata = new JsonObject(parameters.Members.Where(m => m.Key is not ("artifactId" or "owner")));
                    var id = "imp-" + Guid.NewGuid().ToString("D");
                    _imports[id] = ImportJson(id, metadata, 1, "inProgress", 0, JsonNull.Instance);
                    return Success(request, _imports[id]);
                }
                case "artifact.import.append":
                {
                    if (Param("importId") is not { } id || !_imports.TryGetValue(id, out var import)) return Failure(request, "resourceNotFound", "Import does not exist", owner);
                    var bytes = Convert.FromBase64String(Param("base64") ?? "");
                    var offset = Long(import, "nextOffset");
                    if (Param("offset") != offset.ToString(System.Globalization.CultureInfo.InvariantCulture) || Param("sha256") != Sha256Hex(bytes)
                        || Param("byteCount") != bytes.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) || offset + bytes.Length > Long(Meta(import), "byteCount"))
                    {
                        return Failure(request, "invalidInput", "Import append requires exact bounded bytes, offset and digest", owner);
                    }
                    if (offset == 0 && bytes.AsSpan().StartsWith("PK\u0003\u0004"u8)) _zipImports.Add(id);
                    if (((JsonString)Meta(import)["kind"]).Value == "flash-bundle")
                    {
                        if (!_flashBundles.TryGetValue(id, out var bundle)) _flashBundles[id] = bundle = new MemoryStream();
                        bundle.Write(bytes);
                    }
                    _imports[id] = ImportJson(id, Meta(import), 1, "inProgress", offset + bytes.Length, JsonNull.Instance);
                    return Success(request, _imports[id]);
                }
                case "artifact.import.commit":
                {
                    if (Param("importId") is not { } id || !_imports.TryGetValue(id, out var import)) return Failure(request, "resourceNotFound", "Import does not exist", owner);
                    if (Long(import, "nextOffset") != Long(Meta(import), "byteCount")) return Failure(request, "invalidInput", "Import is incomplete", owner);
                    if (((JsonString)Meta(import)["kind"]).Value == "flash-bundle" && scenario != Flash && !IsFlashBundle(id))
                    {
                        return Failure(request, "invalidInput", FlashContentRefusal, Details("importOwner"));
                    }
                    if (((JsonString)Meta(import)["kind"]).Value == "hap" && !_zipImports.Contains(id))
                    {
                        return Failure(request, "invalidInput", "Import is not a ZIP-based HAP/HSP container", owner);
                    }
                    _imports[id] = ImportJson(id, Meta(import), 2, "committed", Long(import, "nextOffset"), Receipt(id, Meta(import), 2));
                    return Success(request, _imports[id]);
                }
                case "artifact.import.abort":
                {
                    var match = _imports.FirstOrDefault(i => ((JsonString)i.Value["importRequestId"]).Value == Param("importRequestId"));
                    if (match.Key is null) return Failure(request, "resourceNotFound", "Import does not exist", owner);
                    if (((JsonString)match.Value["state"]).Value != "inProgress") return Failure(request, "resourceConflict", "Import is no longer in progress", owner);
                    _imports[match.Key] = ImportJson(match.Key, Meta(match.Value), 2, "aborted", Long(match.Value, "nextOffset"), JsonNull.Instance);
                    return Success(request, _imports[match.Key]);
                }
                case "artifact.import.release":
                {
                    if (Param("importId") is not { } id || !_imports.TryGetValue(id, out var import)) return Failure(request, "resourceNotFound", "Import does not exist", owner);
                    var state = ((JsonString)import["state"]).Value;
                    if (import["receipt"] is not JsonObject receipt) return Failure(request, "resourceConflict", "Import generation changed", owner);
                    // A release of the committed generation, repeated, answers the same release (measured).
                    var released = state == "released" && Param("generation") == ((JsonString)receipt["generation"]).Value;
                    if (!released && (state != "committed" || Param("generation") != ((JsonString)import["generation"]).Value))
                    {
                        return Failure(request, "resourceConflict", "Import generation changed", owner);
                    }
                    _imports[id] = ImportJson(id, Meta(import), 3, "released", Long(import, "nextOffset"), receipt);
                    return Success(request, Parse($$"""
                        {"artifactId":"{{((JsonString)receipt["artifactId"]).Value}}","generation":"3","importId":"{{id}}","importRequestId":"{{((JsonString)import["importRequestId"]).Value}}","lease":"{{((JsonString)receipt["lease"]).Value}}","owner":{"id":"{{id}}","kind":"import"},"releasedAtUtc":"2026-09-30T08:10:00Z","releasedGeneration":"2","retention":{"class":"default","deadlineUtc":"2026-10-07T08:10:00Z","pinned":false},"schemaVersion":"arkdeck.import-release/1","state":"released"}
                        """));
                }
                default:
                    return Failure(request, "rejected", "not scripted");
            }
        }

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
        return RecoveryFacts(job.Id, $$$"""
            {"actualEffect":"readOnly","createdAtUtc":"{{{job.Created}}}",{{{listOnly}}}"executionMode":"execute","failure":null,"finishedAtUtc":{{{finished}}},"jobId":"{{{job.Id}}}","nextAction":{{{next}}},"operation":"{{{job.Operation}}}","outcome":"{{{job.State}}}","outcomeUnknown":false,"outstandingResidueCount":0,"processProgress":null,"recoveryEpochId":null,"resolvedByTargetAliasResolutionId":null,"schemaVersion":"{{{schema}}}","sessionId":"session-{{{job.Id}}}","sessionPublication":{"catalogGeneration":null,"manifestSha256":null,"reasonCode":"noCurrentPublicationRecord","state":"unavailable"},"startedAtUtc":"{{{job.Created}}}","state":"{{{job.State}}}","supersededByRecoveryEpochId":null,"targetId":"TGT-FIXTURE-1","threadId":null,"waitingForHuman":{{{(job.State == "waitingForDevice" ? "true" : "false")}}},"workspaceKind":"device"}
            """);
    }

    /// <summary>The recorded facts of <see cref="Recovery"/>'s Jobs the generic projection cannot
    /// carry: the superseded Flash's unknown outcome and its epoch, the capture's residue.</summary>
    private static string RecoveryFacts(string jobId, string json) => jobId switch
    {
        SupersededJobId => json.Replace("\"outcomeUnknown\":false", "\"outcomeUnknown\":true", StringComparison.Ordinal)
            .Replace("\"supersededByRecoveryEpochId\":null", $"\"supersededByRecoveryEpochId\":\"{SupersedingEpochId}\"", StringComparison.Ordinal),
        LogJobId => json.Replace("\"outstandingResidueCount\":0", "\"outstandingResidueCount\":2", StringComparison.Ordinal),
        _ => json,
    };

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
