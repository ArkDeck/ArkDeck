using System.Text;
using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Published framed control flow with task-private scripted records; this is software coverage only.</summary>
[TestClass]
public sealed class DiagnosticCaptureTransportTests
{
    private static readonly DiagnosticCaptureTarget Target = new(ScriptedDaemon.OracleTargetId, 1, "Bench");
    private static Task NoMonitor() => Task.FromCanceled(new CancellationToken(true));

    [TestMethod]
    public async Task ArmMarkStopReadsItsOwnCompletedSessionWithoutReplay()
    {
        var channel = new Channel();
        var session = new DiagnosticCaptureSession(new DiagnosticCaptureProvider(new(channel)), NoMonitor);
        await session.StartAsync(Target, 60);
        Assert.IsTrue(session.CanMark, session.Failure);
        Assert.AreEqual(TimeSpan.FromSeconds(660), channel.RunBudget);
        await session.MarkAsync();
        Assert.AreEqual(1, session.Snapshot!.Markers.Count);
        await session.StopAsync();
        Assert.AreEqual(DiagnosticCapturePhase.Finished, session.Phase, session.Failure);
        Assert.IsNotNull(session.CompletedContext, session.Failure);
        Assert.AreEqual(DiagnosticCaptureProvider.Operation, session.CompletedContext.OperationReference);
        var detail = await new SurfaceLoader(channel).DiagnosticsAsync(session.CompletedContext.Diagnostics);
        Assert.IsNotNull(detail.Session?.Presentation, detail.LoadError);
        Assert.IsInstanceOfType<DiagnosticAlignment.CannotAlign>(detail.Session.Presentation.Reading.Alignment);
        Assert.IsNotNull(detail.Session.Presentation.Reading.ClockObservation);
        var mutations = channel.Mutations;
        _ = await new SurfaceLoader(channel).DiagnosticsAsync(session.CompletedContext.Diagnostics);
        Assert.AreEqual(mutations, channel.Mutations, "Historical reads do not submit/run/control a session");
        Assert.AreEqual((1, 1, 1, 1), (channel.Submits, channel.Runs, channel.Marks, channel.Stops));
    }

    [TestMethod]
    public async Task EveryAcceptedIntentAndMaterializedScopeDriftRefusesRun()
    {
        foreach (var drift in new[] { "deduplicated", "dispatch", "inputs", "outputs", "identity", "revision", "catalog", "provider", "plan", "state" })
        {
            var channel = new Channel { AcceptanceDrift = drift };
            var session = new DiagnosticCaptureSession(new DiagnosticCaptureProvider(new(channel)), NoMonitor);
            await session.StartAsync(Target, 60);
            Assert.AreEqual(DiagnosticCapturePhase.Uncertain, session.Phase, drift + ": " + session.Failure);
            Assert.AreEqual((1, 0), (channel.Submits, channel.Runs), drift);
            await session.StartAsync(Target, 60);
            Assert.AreEqual(1, channel.Submits, drift + " must never resend an unconfirmed intent");
        }
    }

    [TestMethod]
    public async Task ActiveJobOnLaterSnapshotPageAndIncompletePagesBlockSubmission()
    {
        foreach (var mode in new[] { "older-active", "changed-revision", "cursor-cycle", "unfinished", "wrong-target", "duplicate-job" })
        {
            var channel = new Channel { Paging = mode };
            var session = new DiagnosticCaptureSession(new DiagnosticCaptureProvider(new(channel)), NoMonitor);
            await session.StartAsync(Target, 60);
            Assert.AreEqual(DiagnosticCapturePhase.Unavailable, session.Phase, mode);
            Assert.AreEqual((0, 0), (channel.Submits, channel.Runs), mode);
            Assert.IsTrue(channel.Pages >= 1, mode);
        }
    }

    [TestMethod]
    public async Task FreshUniqueConnectedReadyBindingIsRecheckedAfterPreflight()
    {
        foreach (var mode in new[] { "revision", "identity", "offline", "unready" })
        {
            var channel = new Channel { FreshTargetDrift = mode };
            var session = new DiagnosticCaptureSession(new DiagnosticCaptureProvider(new(channel)), NoMonitor);
            await session.StartAsync(Target, 60);
            Assert.AreEqual(DiagnosticCapturePhase.Unavailable, session.Phase, mode + ": " + session.Failure);
            Assert.AreEqual((0, 0), (channel.Submits, channel.Runs), mode);
        }
    }

    [TestMethod]
    public async Task CompletedScopeDriftNeverPromotesHistoryOrReplays()
    {
        foreach (var mode in new[] { "identity", "revision", "plan", "catalog", "provider", "outputs" })
        {
            var channel = new Channel { FinalDrift = mode };
            var session = new DiagnosticCaptureSession(new DiagnosticCaptureProvider(new(channel)), NoMonitor);
            await session.StartAsync(Target, 60); await session.StopAsync();
            Assert.IsNull(session.CompletedContext, mode);
            Assert.IsNotNull(session.Failure, mode);
            Assert.AreEqual((1, 1, 1), (channel.Submits, channel.Runs, channel.Stops), mode);
        }
    }

    [TestMethod]
    public async Task AnotherJobOrBindingCannotUseTheAcceptedControlLane()
    {
        var channel = new Channel();
        var provider = new DiagnosticCaptureProvider(new(channel));
        await provider.PreflightAsync(Target);
        var id = await provider.SubmitAsync(Target, 60);
        await Assert.ThrowsExactlyAsync<DiagnosticCaptureFailure>(() => provider.MarkAsync("different-job", "marker", Target));
        await Assert.ThrowsExactlyAsync<DiagnosticCaptureFailure>(() => provider.StopAsync(id, Target with { BindingRevision = 2 }));
        await Assert.ThrowsExactlyAsync<DiagnosticCaptureFailure>(() => provider.CancelPreparationAsync("different-job"));
        Assert.AreEqual((0, 0), (channel.Marks, channel.Stops));
        Assert.AreEqual(0, channel.Runs);
    }

    private sealed class Channel : IControlChannel, IRuntimeJobChannel, IDiagnosticSessionChannel
    {
        private readonly IControlChannel _inner = ScriptedDaemon.Channel(ScriptedDaemon.DiagnosticCapture);
        public int Submits, Runs, Marks, Stops, Pages;
        private int _targetReads;
        public TimeSpan RunBudget;
        public string? AcceptanceDrift, FinalDrift, Paging, FreshTargetDrift;
        public int Mutations => Submits + Runs + Marks + Stops;
        public Task<ControlResult> HealthAsync() => _inner.HealthAsync();
        private static JsonObject Parse(string json) => (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(json));
        private static JsonObject With(JsonObject original, string key, JsonValue value) => new(original.Members.Select(p => p.Key == key ? new KeyValuePair<string, JsonValue>(key, value) : p));
        public async Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null)
        {
            if (method == "job.submit") Submits++;
            if (method == "job.list" && Paging is { } paging)
            {
                Pages++;
                var target = paging == "wrong-target" ? "other-target" : Target.TargetId;
                var state = paging == "older-active" && Pages == 2 ? "running" : "succeeded";
                var more = Pages == 1 || paging is "cursor-cycle" or "unfinished";
                var cursor = paging == "unfinished" ? "null" : more ? "\"next-page\"" : "null";
                var revision = paging == "changed-revision" && Pages == 2 ? "changed" : "original";
                var id = paging == "duplicate-job" ? "same-job" : "job-page-" + Pages;
                return ControlResult.Success(Parse($$"""{"schemaVersion":"arkdeck.cli.page/1","pageKind":"snapshot","order":"createdAtDescJobIdAsc","snapshotRevision":"{{revision}}","hasMore":{{(more?"true":"false")}},"nextCursor":{{cursor}},"items":[{"schemaVersion":"arkdeck.job-summary/1","jobId":"{{id}}","operation":"observe.device@1","targetId":"{{target}}","state":"{{state}}","waitingForHuman":false,"outcomeUnknown":false,"failure":null,"outstandingResidueCount":0}]}"""));
            }
            var result = await _inner.RequestAsync(method, parameters);
            if (result.Value is not JsonObject o) return result;
            if (method == "device.observations") _targetReads++;
            if (_targetReads >= 2 && FreshTargetDrift is { } fresh)
            {
                if (method == "target.show" && fresh == "identity") o = With(o, "stablePhysicalIdentitySha256", new JsonString(new string('b', 64)));
                if (method == "device.observations" && fresh is "revision" or "offline")
                    o = Parse(o.ToString().Replace(fresh == "revision" ? "\"bindingRevision\":1" : "\"Connected\"", fresh == "revision" ? "\"bindingRevision\":2" : "\"Offline\"", StringComparison.Ordinal));
                if (method == "target.availability" && fresh == "unready") o = With(o, "binding", With((JsonObject)o["binding"], "state", new JsonString("absent")));
            }
            if (method == "job.submit" && AcceptanceDrift == "deduplicated") o = With(o, "deduplicated", JsonBool.True);
            if (method == "job.submit" && AcceptanceDrift == "dispatch") o = With(o, "newDispatchCount", JsonNumber.FromInt64(1));
            var drift = Stops > 0 ? FinalDrift : AcceptanceDrift;
            if (method == "job.show" && drift is { } change)
            {
                o = change switch
                {
                    "identity" => With(o, "materializedStableIdentitySha256", new JsonString(new string('b', 64))),
                    "revision" => With(o, "materializedBindingRevision", JsonNumber.FromInt64(2)),
                    "catalog" => With(o, "catalogDigest", new JsonString(new string('b', 64))),
                    "provider" => With(o, "providerId", new JsonString("arkforge")),
                    "plan" => With(o, "materializedPlanDigest", new JsonString(Stops > 0 ? new string('b', 64) : "invalid-plan")),
                    "state" => With(o, "job", With((JsonObject)o["job"], "state", new JsonString("running"))),
                    "inputs" => With(o, "request", With((JsonObject)o["request"], "inputs", new JsonObject())),
                    "outputs" => With(o, "request", With((JsonObject)o["request"], "requestedOutputs", new JsonArray([]))),
                    _ => o,
                };
            }
            return ControlResult.Success(o);
        }
        public Task<ControlResult> RunJobOnceAsync(string jobId, TimeSpan callBudget) { Runs++; RunBudget = callBudget; return ((IRuntimeJobChannel)_inner).RunJobOnceAsync(jobId, callBudget); }
        public Task<ControlResult> StatusAsync(string jobId) => ((IDiagnosticSessionChannel)_inner).StatusAsync(jobId);
        public Task<ControlResult> MarkAsync(string jobId, string markerId) { Marks++; return ((IDiagnosticSessionChannel)_inner).MarkAsync(jobId, markerId); }
        public Task<ControlResult> StopAsync(string jobId) { Stops++; return ((IDiagnosticSessionChannel)_inner).StopAsync(jobId); }
        public Task<ControlResult> CancelPreparationAsync(string jobId) => ((IDiagnosticSessionChannel)_inner).CancelPreparationAsync(jobId);
    }
}
