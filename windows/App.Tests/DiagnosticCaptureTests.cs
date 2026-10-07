using System.Text;
using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>One-session coordination using only task-private fake providers, never Runtime or hardware.</summary>
[TestClass]
public sealed class DiagnosticCaptureTests
{
    private static readonly DiagnosticCaptureTarget Target = new("target-fixture", 3, "Bench");
    private const string Job = "job-fixture";
    private static Task NoMonitor() => Task.FromCanceled(new CancellationToken(true));
    private static DiagnosticCaptureSnapshot Recording() => new(Job, Target.TargetId, 3, "recording", "running", false, true,
        60, 50, 10, false, "2026-10-07T00:00:00.000Z", null, []);
    private static HistoryWorkspaceContext Context() => new(Job, DiagnosticCaptureProvider.Operation, Target.TargetId, "succeeded", "execute",
        "session-fixture", WorkspaceKind.Diagnostics, 3, null, []);

    [TestMethod]
    public void RequestContainsOnlyPublishedInputsAndOriginalBinding()
    {
        var request = (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(DiagnosticCaptureProvider.Request(Target, 60).Json));
        Assert.AreEqual(DiagnosticCaptureProvider.ClientName, ((JsonString)request["clientContext"]["clientName"]).Value);
        Assert.AreEqual(Target.TargetId, ((JsonString)request["target"]["targetId"]).Value);
        Assert.AreEqual(3L, TypedJson.Int64(request["target"]["expectedBindingRevision"]));
        CollectionAssert.AreEquivalent(new[] { "durationSeconds", "traceCategories", "traceBufferKB", "hilogFilters", "maximumMarkers", "totalArtifactByteBudget", "redactionProfile" },
            ((JsonObject)request["inputs"]).Members.Select(m => m.Key).ToArray());
        Assert.AreEqual(128L * 1024 * 1024, TypedJson.Int64(request["inputs"]["totalArtifactByteBudget"]));
        Assert.IsFalse(request.ContainsKey("authorization"));
        Assert.IsFalse(request.ContainsKey("campaignReservation"));
        Assert.ThrowsExactly<DiagnosticCaptureFailure>(() => DiagnosticCaptureProvider.Request(Target, 121));
    }

    [TestMethod]
    public async Task RecordingRequiresRuntimeReadinessAndControlsKeepOriginalTarget()
    {
        var provider = new Provider();
        var session = new DiagnosticCaptureSession(provider, NoMonitor);
        await session.MarkAsync();
        Assert.AreEqual(0, provider.Marks);
        await session.StartAsync(Target, 60);
        session.SelectionChanged(Target with { TargetId = "another-target", BindingRevision = 4 });
        Assert.AreEqual(Target, session.Target);
        Assert.IsTrue(session.CanMark);
        await session.MarkAsync();
        await session.StopAsync();
        Assert.AreEqual((1, 1, 1, 1), (provider.Submits, provider.Runs, provider.Marks, provider.Stops));
        Assert.AreEqual(Target, provider.LastTarget);
        Assert.AreEqual((Job, Target.TargetId, (long?)3), (session.CompletedContext!.JobId, session.CompletedContext.TargetId, session.CompletedContext.BindingRevision));
        Assert.IsFalse(session.CanStop);
        await session.StopAsync();
        Assert.AreEqual(1, provider.Stops);
    }

    [TestMethod]
    public async Task LostMarkerAnswerReadsBackOnceWithoutResending()
    {
        var provider = new Provider { LostMark = true };
        var session = new DiagnosticCaptureSession(provider, NoMonitor);
        await session.StartAsync(Target, 60);
        var before = provider.Reads;
        await session.MarkAsync();
        Assert.AreEqual(1, provider.Marks);
        Assert.AreEqual(before + 1, provider.Reads);
        Assert.AreEqual(1, session.Snapshot!.Markers.Count);
        Assert.AreEqual(provider.LastMarker, session.Snapshot.Markers[0].MarkerId);
    }

    [TestMethod]
    public async Task MissingLostControlProofStaysReadonlyAndNeverReplaysStopCancelOrMarker()
    {
        foreach (var action in new[] { "mark", "stop", "cancel" })
        {
            var provider = new Provider { UnsettledControl = action };
            if (action == "cancel") provider.Current = Recording() with { State = "preparing", JobState = "preflight", ControlAvailable = false, ArmedAtHostUtc = null, ElapsedMs = 0 };
            var session = new DiagnosticCaptureSession(provider, NoMonitor);
            await session.StartAsync(Target, 60);
            Task Invoke() => action == "mark" ? session.MarkAsync() : action == "stop" ? session.StopAsync() : session.CancelPreparationAsync();
            await Invoke(); await session.RefreshAsync(); await Invoke();
            Assert.AreEqual(DiagnosticCapturePhase.Uncertain, session.Phase, action);
            Assert.IsFalse(session.CanMark, action); Assert.IsFalse(session.CanStop, action); Assert.IsFalse(session.CanCancelPreparation, action);
            Assert.AreEqual(1, provider.Marks + provider.Stops + provider.Cancels, action);
            Assert.AreEqual((1, 1), (provider.Submits, provider.Runs), action);
        }
    }

    [TestMethod]
    public async Task UnknownSubmissionCannotStartAgainOrRunUnknownJob()
    {
        var provider = new Provider { UnknownSubmit = true };
        var session = new DiagnosticCaptureSession(provider, NoMonitor);
        await session.StartAsync(Target, 60);
        await session.StartAsync(Target, 60);
        Assert.AreEqual(DiagnosticCapturePhase.Uncertain, session.Phase);
        Assert.AreEqual((1, 0), (provider.Submits, provider.Runs));
        Assert.IsFalse(session.CanStart);
    }

    [TestMethod]
    public async Task SelectionChangeDuringPreflightSendsNoIntent()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var provider = new Provider { Preflight = async () => { entered.SetResult(); await release.Task; } };
        var session = new DiagnosticCaptureSession(provider, NoMonitor);
        var start = session.StartAsync(Target, 60);
        await entered.Task;
        session.SelectionChanged(Target with { BindingRevision = 4 });
        release.SetResult(); await start;
        Assert.AreEqual((0, 0), (provider.Submits, provider.Runs));
        Assert.AreEqual(DiagnosticCapturePhase.Idle, session.Phase);
    }

    [TestMethod]
    public async Task MismatchedRuntimeSnapshotCannotEnableControls()
    {
        var provider = new Provider { Current = Recording() with { BindingRevision = 4 } };
        var session = new DiagnosticCaptureSession(provider, NoMonitor);
        await session.StartAsync(Target, 60);
        Assert.AreEqual(DiagnosticCapturePhase.Uncertain, session.Phase);
        Assert.IsFalse(session.CanMark); Assert.IsFalse(session.CanStop);
        await session.MarkAsync();
        Assert.AreEqual(0, provider.Marks);
    }

    [TestMethod]
    public async Task ExpiredMonotonicWindowCannotBeRevivedByLateRead()
    {
        var clock = new Clock();
        var provider = new Provider();
        var session = new DiagnosticCaptureSession(provider, NoMonitor, clock);
        await session.StartAsync(Target, 60);
        clock.Advance(TimeSpan.FromSeconds(660));
        await session.RefreshAsync();
        Assert.AreEqual(DiagnosticCapturePhase.Uncertain, session.Phase);
        Assert.IsFalse(session.CanMark); Assert.IsFalse(session.CanStop);
        await session.MarkAsync(); await session.StopAsync();
        Assert.AreEqual((0, 0), (provider.Marks, provider.Stops));
        var before = provider.Reads;
        await session.RefreshAsync(automatic: true);
        Assert.AreEqual(before, provider.Reads, "No automatic call may begin after the original local observation bound");
    }

    [TestMethod]
    public async Task Fixed120SecondReadsDoNotMultiplyTheOriginalMonitoringWindow()
    {
        var clock = new Clock();
        var provider = new Provider { Status = () => { clock.Advance(TimeSpan.FromSeconds(120)); return Task.FromResult(Recording()); } };
        var session = new DiagnosticCaptureSession(provider, () => { clock.Advance(TimeSpan.FromSeconds(1)); return Task.CompletedTask; }, clock);
        await session.StartAsync(Target, 60);
        Assert.AreEqual(6, provider.Reads, "Calls are bounded by monotonic elapsed time, including late read duration");
        Assert.AreEqual(DiagnosticCapturePhase.Uncertain, session.Phase);
        Assert.IsFalse(session.CanMark); Assert.IsFalse(session.CanStop);
        Assert.AreEqual((1, 1), (provider.Submits, provider.Runs));
    }

    [TestMethod]
    public async Task CompletedTerminalSurvivesExpiredAutomaticRefreshWithoutAnotherRead()
    {
        var clock = new Clock();
        var provider = new Provider();
        var session = new DiagnosticCaptureSession(provider, NoMonitor, clock);
        await session.StartAsync(Target, 60);
        await session.StopAsync();
        var terminal = session.Snapshot;
        var context = session.CompletedContext;
        var reads = provider.Reads;
        clock.Advance(TimeSpan.FromSeconds(661));
        await session.RefreshAsync(automatic: true);
        Assert.AreSame(terminal, session.Snapshot);
        Assert.AreSame(context, session.CompletedContext);
        Assert.AreEqual(DiagnosticCapturePhase.Finished, session.Phase);
        Assert.IsNull(session.Failure);
        Assert.AreEqual(reads, provider.Reads);
        Assert.AreEqual((1, 1, 1), (provider.Submits, provider.Runs, provider.Histories));
    }

    [TestMethod]
    public async Task ConcurrentReadonlyRefreshCannotOverwriteTerminalAndHistoryLoadsOnce()
    {
        var provider = new Provider();
        var session = new DiagnosticCaptureSession(provider, NoMonitor);
        await session.StartAsync(Target, 60);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<DiagnosticCaptureSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var concurrent = 0; var maximum = 0;
        provider.Status = async () => { maximum = Math.Max(maximum, Interlocked.Increment(ref concurrent)); entered.TrySetResult(); var value = await release.Task; Interlocked.Decrement(ref concurrent); return value; };
        var first = session.RefreshAsync(); await entered.Task;
        var second = session.RefreshAsync();
        var terminal = Recording() with { State = "closed", JobState = "succeeded", ControlAvailable = false, StopRequested = true, EndedAtHostUtc = "2026-10-07T00:00:00.010Z" };
        release.SetResult(terminal); await Task.WhenAll(first, second);
        Assert.AreEqual(1, maximum);
        Assert.AreEqual(1, provider.Histories);
        provider.Status = () => Task.FromResult(Recording());
        await session.RefreshAsync();
        Assert.AreEqual("succeeded", session.Snapshot!.JobState);
        Assert.AreEqual(DiagnosticCapturePhase.Finished, session.Phase);
        Assert.IsFalse(session.CanMark);
    }

    [TestMethod]
    public async Task PreparingCancellationIsOnceOnlyAndLostAnswerReconcilesReadonly()
    {
        var provider = new Provider { Current = Recording() with { State = "preparing", JobState = "preflight", ControlAvailable = false, ArmedAtHostUtc = null, ElapsedMs = 0 } };
        var session = new DiagnosticCaptureSession(provider, NoMonitor);
        await session.StartAsync(Target, 60);
        Assert.IsTrue(session.CanCancelPreparation);
        await session.CancelPreparationAsync(); await session.CancelPreparationAsync();
        Assert.AreEqual(1, provider.Cancels);
        Assert.AreEqual("cancelled", session.Snapshot!.JobState);
        Assert.AreEqual(1, provider.Runs);
    }

    private sealed class Clock : TimeProvider
    {
        private long _timestamp;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => _timestamp;
        public void Advance(TimeSpan value) => _timestamp += (long)value.TotalMilliseconds;
    }

    private sealed class Provider : IDiagnosticCaptureProvider
    {
        public DiagnosticCaptureSnapshot Current = Recording();
        public Func<Task>? Preflight;
        public Func<Task<DiagnosticCaptureSnapshot>>? Status;
        public bool LostMark, UnknownSubmit;
        public string? UnsettledControl;
        public int Submits, Runs, Reads, Marks, Stops, Cancels, Histories;
        public DiagnosticCaptureTarget? LastTarget;
        public string? LastMarker;
        public Task PreflightAsync(DiagnosticCaptureTarget target) => Preflight?.Invoke() ?? Task.CompletedTask;
        public Task<string> SubmitAsync(DiagnosticCaptureTarget target, int durationSeconds)
        { Submits++; return UnknownSubmit ? Task.FromException<string>(new DiagnosticCaptureFailure("lost submit", true)) : Task.FromResult(Job); }
        // This task intentionally remains pending until the fake closes, like real job.run.
        private readonly TaskCompletionSource _run = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task RunOnceAsync(string jobId) { Runs++; return _run.Task; }
        public async Task<DiagnosticCaptureSnapshot> StatusAsync(string jobId, DiagnosticCaptureTarget target)
        { Reads++; LastTarget = target; return Status is null ? Current : await Status(); }
        public Task<DiagnosticCaptureSnapshot> MarkAsync(string jobId, string markerId, DiagnosticCaptureTarget target)
        {
            Marks++; LastTarget = target; LastMarker = markerId;
            if (UnsettledControl == "mark") return Task.FromException<DiagnosticCaptureSnapshot>(new DiagnosticCaptureFailure("lost mark without proof", true));
            Current = Current with { Markers = [.. Current.Markers, new(markerId, "2026-10-07T00:00:00.010Z", 10, null)] };
            return LostMark ? Task.FromException<DiagnosticCaptureSnapshot>(new DiagnosticCaptureFailure("lost mark", true)) : Task.FromResult(Current);
        }
        public Task<DiagnosticCaptureSnapshot> StopAsync(string jobId, DiagnosticCaptureTarget target)
        { Stops++; LastTarget = target; if (UnsettledControl == "stop") return Task.FromException<DiagnosticCaptureSnapshot>(new DiagnosticCaptureFailure("lost stop without proof", true)); Current = Current with { State = "closed", JobState = "succeeded", StopRequested = true, ControlAvailable = false, EndedAtHostUtc = "2026-10-07T00:00:00.010Z" }; return Task.FromResult(Current); }
        public Task CancelPreparationAsync(string jobId)
        { Cancels++; if (UnsettledControl == "cancel") return Task.FromException(new DiagnosticCaptureFailure("lost cancel without proof", true)); Current = Current with { State = "closed", JobState = "cancelled", ControlAvailable = false }; return Task.FromException(new DiagnosticCaptureFailure("lost cancel", true)); }
        public Task<HistoryWorkspaceContext> HistoryAsync(string jobId, DiagnosticCaptureTarget target) { Histories++; return Task.FromResult(Context() with { State = Current.IsTerminal ? Current.JobState : "succeeded" }); }
    }
}
