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

    /// <summary>The Windows daemon as it answers today (the read-only foundation): health and
    /// a blocked doctor; <c>device.observations</c> refused with <c>hdc.notConfigured</c>; the
    /// Job methods refused because no Job owner is composed.</summary>
    public const string Foundation = "foundation";

    /// <summary><see cref="Unavailable"/> for the first two connections (the start reads the
    /// Overview and the Job Inspector, one connection each before the refresh stops), then
    /// <see cref="Foundation"/>: the recovery banner appears, then goes away after Retry.</summary>
    public const string Recovers = "recovers";

    /// <summary><see cref="Foundation"/> for the first four connections (the start reads the
    /// Overview's health, doctor and Jobs and the Job Inspector's Jobs), then nothing answers:
    /// the daemon goes away while the App shows its data.</summary>
    public const string Outage = "outage";

    /// <summary>A daemon with a Job store and devices: three candidates, three Jobs, and a
    /// running Job whose state advances on each <c>job.status</c> read.</summary>
    public const string Jobs = "jobs";

    public static readonly IReadOnlyList<string> Scenarios = [Unavailable, ContractMismatch, Foundation, Recovers, Outage, Jobs];

    public const string RunningJobId = "job-0000000000000000000000000000a001";
    public static readonly IReadOnlyList<string> RunningJobStates = ["running", "waitingForDevice", "running", "succeeded"];

    public static IControlChannel Channel(string scenario)
    {
        if (!Scenarios.Contains(scenario)) throw new ArgumentException($"unknown test transport scenario {scenario}", nameof(scenario));
        var script = new Script(scenario);
        return new StreamChannel(script.Connect, DaemonConfiguration.CallBudget);
    }

    private sealed class Script(string scenario)
    {
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
            return new Peer(request => Answer(mode, request));
        }

        private byte[]? Answer(string mode, JsonObject request)
        {
            var method = ((JsonString)request["method"]).Value;
            return mode switch
            {
                Unavailable => null,
                ContractMismatch => Success(request, Health(new string('0', 64))),
                Foundation => method switch
                {
                    "health" => Success(request, Health(ControlContract.ContractIdentity)),
                    "doctor" => Success(request, Parse(BlockedDoctor)),
                    "device.observations" => Failure(request, "rejected", "hdc.notConfigured"),
                    _ when method.StartsWith("job.", StringComparison.Ordinal) => Failure(request, "rejected", "The Job owner is not configured"),
                    _ => Failure(request, "rejected", "this method is unavailable in the read-only Rust foundation"),
                },
                _ => method switch
                {
                    "health" => Success(request, Health(ControlContract.ContractIdentity)),
                    "doctor" => Success(request, Parse(HealthyDoctor)),
                    "device.observations" => Success(request, Parse(Observations)),
                    "job.list" => Success(request, Parse(JobPage([.. JobsNow().Select(j => JobJson(j, list: true))]))),
                    "job.status" => JobStatus(request),
                    "job.events" => JobEvents(request),
                    _ => Failure(request, "rejected", "not scripted"),
                },
            };
        }

        private (string Id, string Operation, string State, string Created)[] JobsNow() =>
        [
            (RunningJobId, "observe.device@1", RunningJobStates[Math.Min(_statusReads, RunningJobStates.Count - 1)], "2026-09-30T08:02:00Z"),
            ("job-0000000000000000000000000000a002", "flash.images@1", "failed", "2026-09-30T08:01:00Z"),
            ("job-0000000000000000000000000000a003", "trace.capture@1", "succeeded", "2026-09-30T08:00:00Z"),
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
    }

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

    private static byte[] Failure(JsonObject request, string code, string message) =>
        Wire.EncodeFrame(new JsonObject(
        [
            new("id", request["id"]),
            new("ok", JsonBool.False),
            new("error", new JsonObject([new("code", new JsonString(code)), new("message", new JsonString(message))])),
        ]), ControlContract.MaxResponseBytes);

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
