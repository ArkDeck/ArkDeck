using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>The original adopted scope of one interactive capture; it is never a capability.</summary>
public sealed record DiagnosticCaptureTarget(string TargetId, long BindingRevision, string Title)
{
    public TargetSummary Summary => new(TargetId, null, "", BindingRevision, "", "");

    public static DiagnosticCaptureTarget? From(IReadOnlyList<DeviceCandidate> candidates)
    {
        var adopted = candidates.Where(c => c.AdoptedTargetId is not null).ToArray();
        return adopted is [var candidate] && !candidate.Stale && candidate.AuthorizationState == "Connected"
            && candidate.BindingRevision is { } revision
            ? new(candidate.AdoptedTargetId!, revision, candidate.DisplayName ?? candidate.DeviceName ?? candidate.AdoptedTargetId!) : null;
    }
}

public sealed record DiagnosticCaptureMarker(string MarkerId, string AtHostUtc, long OffsetMs, string? Label);

/// <summary>A closed Runtime control projection, validated before it can enable any action.</summary>
public sealed record DiagnosticCaptureSnapshot(string JobId, string TargetId, long BindingRevision, string State,
    string JobState, bool OutcomeUnknown, bool ControlAvailable, long MaximumSeconds, long MaximumMarkers,
    long ElapsedMs, bool StopRequested, string? ArmedAtHostUtc, string? EndedAtHostUtc, IReadOnlyList<DiagnosticCaptureMarker> Markers)
{
    private static readonly string[] Members = ["schemaVersion", "jobId", "targetId", "bindingRevision", "state", "jobState",
        "outcomeUnknown", "controlAvailable", "maximumSeconds", "maximumMarkers", "elapsedMs", "stopRequested",
        "armedAtHostUTC", "endedAtHostUTC", "markers"];
    private static readonly string[] States = ["preparing", "recording", "finalizing", "interrupted", "closed"];
    private static readonly string[] JobStates = ["planned", "queued", "preflight", "running", "waitingForDevice", "waitingForHuman",
        "waitingForRecovery", "finalizing", "succeeded", "failed", "cancelled", "interrupted", "recovered"];
    public bool IsTerminal => JobSummary.TerminalStates.Contains(JobState);

    public static DiagnosticCaptureSnapshot Parse(JsonValue value, string jobId, DiagnosticCaptureTarget target)
    {
        var o = Json.Object(value, "a Diagnostic Session status");
        if (!o.Members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal).SetEquals(Members)
            || TypedJson.Required(o, "schemaVersion", TypedJson.String) != "1.0.0") throw Invalid();
        var markers = TypedJson.Required(o, "markers", v => TypedJson.List(v, row =>
        {
            var m = Json.Object(row, "a session marker");
            var keys = m.Members.Select(p => p.Key).ToHashSet(StringComparer.Ordinal);
            if (!keys.SetEquals(["markerId", "atHostUTC", "offsetMs"]) && !keys.SetEquals(["markerId", "atHostUTC", "offsetMs", "label"])) throw Invalid();
            return new DiagnosticCaptureMarker(TypedJson.Required(m, "markerId", TypedJson.String),
                TypedJson.Required(m, "atHostUTC", TypedJson.String), TypedJson.Required(m, "offsetMs", TypedJson.Int64), Json.OptionalString(m, "label"));
        }));
        var snapshot = new DiagnosticCaptureSnapshot(TypedJson.Required(o, "jobId", TypedJson.String), TypedJson.Required(o, "targetId", TypedJson.String),
            TypedJson.Required(o, "bindingRevision", TypedJson.Int64), TypedJson.Required(o, "state", TypedJson.String),
            TypedJson.Required(o, "jobState", TypedJson.String), TypedJson.Required(o, "outcomeUnknown", TypedJson.Bool),
            TypedJson.Required(o, "controlAvailable", TypedJson.Bool), TypedJson.Required(o, "maximumSeconds", TypedJson.Int64),
            TypedJson.Required(o, "maximumMarkers", TypedJson.Int64), TypedJson.Required(o, "elapsedMs", TypedJson.Int64),
            TypedJson.Required(o, "stopRequested", TypedJson.Bool), Json.NullableString(o, "armedAtHostUTC"), Json.NullableString(o, "endedAtHostUTC"), markers);
        snapshot.Validate(jobId, target);
        return snapshot;
    }

    public void Validate(string jobId, DiagnosticCaptureTarget target)
    {
        if (JobId != jobId || TargetId != target.TargetId || BindingRevision != target.BindingRevision
            || !States.Contains(State) || !JobStates.Contains(JobState) || (State == "closed" && !IsTerminal)
            || MaximumSeconds is < 1 or > 120 || MaximumMarkers is < 1 or > 200
            || ElapsedMs < 0 || ElapsedMs > MaximumSeconds * 1000 || Markers.Count > MaximumMarkers
            || Markers.Select(m => m.MarkerId).Distinct(StringComparer.Ordinal).Count() != Markers.Count
            || Markers.Any(m => string.IsNullOrEmpty(m.MarkerId) || !DiagnosticInstant.IsValid(m.AtHostUtc) || m.OffsetMs < 0 || m.OffsetMs > MaximumSeconds * 1000)
            || (ArmedAtHostUtc is not null && !DiagnosticInstant.IsValid(ArmedAtHostUtc))
            || (EndedAtHostUtc is not null && !DiagnosticInstant.IsValid(EndedAtHostUtc))
            || (State == "recording" && (!ControlAvailable || ArmedAtHostUtc is null || OutcomeUnknown))) throw Invalid();
    }

    private static DiagnosticCaptureFailure Invalid() => new("diagnostics_invalid_session_snapshot", true);
}

public sealed class DiagnosticCaptureFailure(string message, bool uncertain = false) : Exception(message)
{
    public bool Uncertain { get; } = uncertain;
}

public interface IDiagnosticCaptureProvider
{
    Task PreflightAsync(DiagnosticCaptureTarget target);
    Task<string> SubmitAsync(DiagnosticCaptureTarget target, int durationSeconds);
    Task RunOnceAsync(string jobId);
    Task<DiagnosticCaptureSnapshot> StatusAsync(string jobId, DiagnosticCaptureTarget target);
    Task<DiagnosticCaptureSnapshot> MarkAsync(string jobId, string markerId, DiagnosticCaptureTarget target);
    Task<DiagnosticCaptureSnapshot> StopAsync(string jobId, DiagnosticCaptureTarget target);
    Task CancelPreparationAsync(string jobId);
    Task<HistoryWorkspaceContext> HistoryAsync(string jobId, DiagnosticCaptureTarget target);
}

/// <summary>Only published typed operations over the authenticated ClientKit channel. No retry, timestamps or authority are sent.</summary>
public sealed class DiagnosticCaptureProvider(SurfaceLoader loader) : IDiagnosticCaptureProvider
{
    public const string Operation = "capture.diagnostic-session@1";
    public const string ClientName = "ArkDeckApp.DiagnosticsWorkspace";
    public const long ByteBudget = 128 * 1024 * 1024;
    private readonly IControlChannel _channel = loader.Channel;
    private TimeSpan? _runBudget;
    private DeviceScreenTarget? _preparedTarget;
    private string? _catalog;
    private (RuntimeRequest Request, JsonObject Document, string JobId, DeviceScreenTarget Target)? _accepted;

    public static RuntimeRequest Request(DiagnosticCaptureTarget target, int durationSeconds)
    {
        if (durationSeconds is < 1 or > 120) throw new DiagnosticCaptureFailure("diagnostics_invalid_recording_duration");
        return RuntimeRequest.Build("diagnostics", "capture.diagnostic-session", 1, target.TargetId, target.BindingRevision,
        [
            ("durationSeconds", JsonNumber.FromInt64(durationSeconds)), ("traceCategories", new JsonArray([new JsonString("ohos")])),
            ("traceBufferKB", JsonNumber.FromInt64(8192)), ("hilogFilters", new JsonArray([])), ("maximumMarkers", JsonNumber.FromInt64(50)),
            ("totalArtifactByteBudget", JsonNumber.FromInt64(ByteBudget)), ("redactionProfile", new JsonString("standard")),
        ], ["hardwareEvidence"], ClientName);
    }

    public async Task PreflightAsync(DiagnosticCaptureTarget target)
    {
        _runBudget = null;
        _accepted = null;
        _catalog = RuntimeFacts.Parse(await ReadAsync("health", SurfaceLoader.Params()).ConfigureAwait(false)).CatalogDigest;
        _preparedTarget = await ReadyTargetAsync(target).ConfigureAwait(false);
        if (_channel is not IRuntimeJobChannel || _channel is not IDiagnosticSessionChannel)
            throw new DiagnosticCaptureFailure("diagnostics_session_control_unavailable");
        var facts = (await SurfaceLoader.OperationsAsync(_channel, [Operation]).ConfigureAwait(false)).Single();
        if (facts.Reference != Operation || !facts.IsAvailable || facts.TimeoutSeconds != 600)
            throw new DiagnosticCaptureFailure(string.Join("; ", facts.Availability.Reasons.Prepend("diagnostics_session_operation_unavailable")));
        var probe = TraceProbe.Parse(await ReadAsync("trace.probe", SurfaceLoader.Params(("targetId", new JsonString(target.TargetId)))).ConfigureAwait(false), target.Summary);
        if (!probe.IsCaptureEligible || !probe.SupportedTags.Contains("ohos")) throw new DiagnosticCaptureFailure("diagnostics_trace_adapter_unavailable");
        var quota = Json.Object(await ReadAsync("artifact.quota", SurfaceLoader.Params()).ConfigureAwait(false), "Artifact quota");
        if (TypedJson.Required(quota, "remainingBytes", TypedJson.Int64) < ByteBudget) throw new DiagnosticCaptureFailure("diagnostics_artifact_headroom_insufficient");
        await ClosedTargetJobsAsync(target).ConfigureAwait(false);
        _runBudget = TimeSpan.FromSeconds(facts.TimeoutSeconds + 60);
    }

    public async Task<string> SubmitAsync(DiagnosticCaptureTarget target, int durationSeconds)
    {
        var fresh = await ReadyTargetAsync(target).ConfigureAwait(false);
        if (_preparedTarget is not { } prepared || !fresh.SameBinding(prepared) || _runBudget is null)
            throw new DiagnosticCaptureFailure("diagnostics_target_binding_changed");
        var catalog = RuntimeFacts.Parse(await ReadAsync("health", SurfaceLoader.Params()).ConfigureAwait(false)).CatalogDigest;
        if (catalog != _catalog) throw new DiagnosticCaptureFailure("diagnostics_catalog_changed");
        var request = Request(target, durationSeconds);
        var acceptance = Json.Object(await ReadAsync("job.submit", SurfaceLoader.Params(("requestJson", new JsonString(request.Json)))).ConfigureAwait(false), "a Diagnostic Job acceptance");
        try
        {
            var id = JobAcceptance.Parse(acceptance).JobId;
            if (acceptance["deduplicated"] is not JsonBool { Value: false } || TypedJson.Int64(acceptance["newDispatchCount"]) != 0)
                throw new DiagnosticCaptureFailure("diagnostics_submit_unconfirmed", true);
            var document = Json.Object(await ReadAsync("job.show", SurfaceLoader.Params(("jobId", new JsonString(id)))).ConfigureAwait(false), "the accepted Diagnostic Job");
            if (!DeviceOperations.AcceptedRequest(document, request, id, fresh, Operation) || Json.OptionalString(document, "catalogDigest") != catalog)
                throw new DiagnosticCaptureFailure("diagnostics_accepted_request_unconfirmed", true);
            _accepted = (request, document, id, fresh);
            return id;
        }
        catch (Exception error) { throw new DiagnosticCaptureFailure(error.Message, true); }
    }

    private async Task<DeviceScreenTarget> ReadyTargetAsync(DiagnosticCaptureTarget expected)
    {
        var devices = await loader.DeviceAsync().ConfigureAwait(false);
        var selected = devices.Candidates.Value is { } candidates ? DiagnosticCaptureTarget.From(candidates) : null;
        var targets = devices.Targets.Value?.Where(t => t.TargetId == expected.TargetId).ToArray();
        if (selected?.TargetId != expected.TargetId || selected.BindingRevision != expected.BindingRevision
            || targets is not [var summary] || summary.BindingRevision != expected.BindingRevision)
            throw new DiagnosticCaptureFailure("diagnostics_target_binding_changed");
        var details = await loader.TargetAsync(expected.TargetId).ConfigureAwait(false);
        if (details.Detail.Value is not { } detail || DeviceScreenTarget.Of(detail) is not { } target
            || target.TargetId != expected.TargetId || target.BindingRevision != expected.BindingRevision
            || details.Availability.Value is not { BindingState: "ready" } availability || availability.TargetId != expected.TargetId)
            throw new DiagnosticCaptureFailure("diagnostics_target_binding_unavailable");
        return target;
    }

    // A complete bounded same-Target snapshot, rather than a recent-Jobs heuristic.
    private async Task ClosedTargetJobsAsync(DiagnosticCaptureTarget target)
    {
        string? cursor = null, snapshot = null;
        var seenCursors = new HashSet<string>(StringComparer.Ordinal);
        var seenJobs = new HashSet<string>(StringComparer.Ordinal);
        for (var pageNumber = 0; pageNumber < 64; pageNumber++)
        {
            var members = new List<(string Key, JsonValue Value)> { ("target", new JsonString(target.TargetId)),
                ("includeTimeline", JsonBool.False), ("order", new JsonString("createdAtDescJobIdAsc")), ("pageSize", JsonNumber.FromInt64(250)) };
            if (cursor is not null) members.Add(("cursor", new JsonString(cursor)));
            var page = Json.Object(await ReadAsync("job.list", SurfaceLoader.Params([.. members])).ConfigureAwait(false), "a Diagnostic preflight Job page");
            var revision = TypedJson.Required(page, "snapshotRevision", TypedJson.String);
            var more = TypedJson.Required(page, "hasMore", TypedJson.Bool);
            var next = Json.NullableString(page, "nextCursor");
            if (Json.OptionalString(page, "pageKind") != "snapshot" || Json.OptionalString(page, "order") != "createdAtDescJobIdAsc"
                || string.IsNullOrEmpty(revision) || (snapshot is not null && revision != snapshot) || more != (next is not null))
                throw new DiagnosticCaptureFailure("diagnostics_job_snapshot_incomplete");
            snapshot = revision;
            foreach (var job in RecentJob.ParsePage(page))
            {
                if (job.TargetId != target.TargetId || !seenJobs.Add(job.JobId)) throw new DiagnosticCaptureFailure("diagnostics_job_snapshot_incomplete");
                if (job.IsActive || job.OutcomeUnknown || job.ResidueCount != 0 || job.WaitingForHuman)
                    throw new DiagnosticCaptureFailure("diagnostics_target_has_unfinished_job");
            }
            if (!more) return;
            if (string.IsNullOrEmpty(next) || !seenCursors.Add(next)) throw new DiagnosticCaptureFailure("diagnostics_job_snapshot_incomplete");
            cursor = next;
        }
        throw new DiagnosticCaptureFailure("diagnostics_job_snapshot_incomplete");
    }

    public async Task RunOnceAsync(string jobId)
    {
        if (_runBudget is not { } budget || _accepted?.JobId != jobId || _channel is not IRuntimeJobChannel runs) throw new DiagnosticCaptureFailure("diagnostics_run_not_preflighted");
        _ = Value(await runs.RunJobOnceAsync(jobId, budget).ConfigureAwait(false));
    }

    public async Task<DiagnosticCaptureSnapshot> StatusAsync(string jobId, DiagnosticCaptureTarget target)
    { Owner(jobId, target); return Snapshot(Value(await Controls.StatusAsync(jobId).ConfigureAwait(false)), jobId, target); }
    public async Task<DiagnosticCaptureSnapshot> MarkAsync(string jobId, string markerId, DiagnosticCaptureTarget target)
    { Owner(jobId, target); return Snapshot(Value(await Controls.MarkAsync(jobId, markerId).ConfigureAwait(false)), jobId, target); }
    public async Task<DiagnosticCaptureSnapshot> StopAsync(string jobId, DiagnosticCaptureTarget target)
    { Owner(jobId, target); return Snapshot(Value(await Controls.StopAsync(jobId).ConfigureAwait(false)), jobId, target); }
    public async Task CancelPreparationAsync(string jobId)
    { Owner(jobId); _ = Value(await Controls.CancelPreparationAsync(jobId).ConfigureAwait(false)); }
    private void Owner(string jobId, DiagnosticCaptureTarget? target = null)
    {
        if (_accepted is not { } accepted || accepted.JobId != jobId
            || (target is not null && (target.TargetId != accepted.Target.TargetId || target.BindingRevision != accepted.Target.BindingRevision)))
            throw new DiagnosticCaptureFailure("diagnostics_session_owner_mismatch");
    }
    private DiagnosticCaptureSnapshot Snapshot(JsonValue value, string jobId, DiagnosticCaptureTarget target)
    {
        var snapshot = DiagnosticCaptureSnapshot.Parse(value, jobId, target);
        var request = (JsonObject)StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(_accepted!.Value.Request.Json));
        if (snapshot.MaximumSeconds != TypedJson.Int64(request["inputs"]["durationSeconds"]) || snapshot.MaximumMarkers != 50)
            throw new DiagnosticCaptureFailure("diagnostics_session_budget_mismatch", true);
        return snapshot;
    }
    private IDiagnosticSessionChannel Controls => _channel as IDiagnosticSessionChannel ?? throw new DiagnosticCaptureFailure("diagnostics_session_control_unavailable");

    public async Task<HistoryWorkspaceContext> HistoryAsync(string jobId, DiagnosticCaptureTarget target)
    {
        var final = await loader.ShowAsync(jobId, "arkdeck diagnostics inspect --job <job-id>").ConfigureAwait(false);
        if (_accepted is not { } accepted || final.Answer.Value is not { Document: { } document } shown
            || accepted.JobId != jobId || !DeviceOperations.StatusMatches(shown, jobId, accepted.Target, Operation, requireSuccess: false)
            || !DeviceOperations.RequestMatches(document, accepted.Request, jobId, accepted.Target, Operation)
            || !new[] { "catalogDigest", "providerId", "materializedPlanDigest", "materializedBindingRevision", "materializedStableIdentitySha256" }
                .All(key => document[key].Equals(accepted.Document[key]))) throw new DiagnosticCaptureFailure("diagnostics_history_scope_unconfirmed", true);
        var detail = await loader.HistoryDetailAsync(jobId).ConfigureAwait(false);
        if (detail.Status.Value is not { } job || job.JobId != jobId || job.Operation != Operation || job.TargetId != target.TargetId
            || job.State != shown.Terminal.State || job.ExecutionMode != "execute" || !JobSummary.TerminalStates.Contains(job.State)
            || detail.Evidence.Value is not { } evidence || evidence.BindingRevision != target.BindingRevision || evidence.TerminalState != job.State
            || evidence.ExecutionMode != "execute" || evidence.CatalogDigest != Json.OptionalString(accepted.Document, "catalogDigest")
            || evidence.ProviderId != "hdc" || evidence.Parameters is not { } parameters
            || !parameters.Equals(((JsonObject)StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(accepted.Request.Json)))["inputs"])
            || detail.Artifacts.Value is not { } artifacts
            || HistoryWorkspaceContext.Of(job, detail.Evidence.Value, artifacts) is not { } context || context.BindingRevision != target.BindingRevision)
            throw new DiagnosticCaptureFailure("diagnostics_history_scope_unconfirmed", true);
        return context;
    }

    private async Task<JsonValue> ReadAsync(string method, JsonObject parameters) => Value(await _channel.RequestAsync(method, parameters).ConfigureAwait(false));
    private static JsonValue Value(ControlResult reply) => reply.Failure is { } failure
        ? throw new DiagnosticCaptureFailure(failure.Message, failure.Kind != ControlFailureKind.Remote && failure.Kind != ControlFailureKind.InvalidRequest)
        : reply.Value ?? throw new DiagnosticCaptureFailure("diagnostics_session_reply_unreadable", true);
}

public enum DiagnosticCapturePhase { Idle, Checking, Submitting, Active, Finished, Unavailable, Uncertain }

/// <summary>App-side one-shot coordination. Runtime snapshots alone establish recording; lost control replies cause only reads.</summary>
public sealed class DiagnosticCaptureSession(IDiagnosticCaptureProvider provider, Func<Task>? pause = null, TimeProvider? clock = null)
{
    public static readonly TimeSpan MonitoringBudget = TimeSpan.FromSeconds(660);
    private readonly object _gate = new();
    private readonly SemaphoreSlim _reads = new(1, 1);
    private readonly TimeProvider _clock = clock ?? TimeProvider.System;
    private readonly Func<Task> _pause = pause ?? (() => Task.Delay(TimeSpan.FromSeconds(1)));
    private Guid _generation;
    private long _revision;
    private bool _loadingHistory;
    private long? _submittedAt;
    private bool _deadlineExpired;
    private string? _pendingMarker;
    private bool _stopAttempted, _cancelAttempted, _pendingStop, _pendingCancel;
    public event Action? Changed;
    public DiagnosticCapturePhase Phase { get; private set; }
    public DiagnosticCaptureTarget? Target { get; private set; }
    public string? JobId { get; private set; }
    public DiagnosticCaptureSnapshot? Snapshot { get; private set; }
    public string? Failure { get; private set; }
    public bool IsControlling { get; private set; }
    public HistoryWorkspaceContext? CompletedContext { get; private set; }
    public bool CanStart { get { lock (_gate) return (Phase is DiagnosticCapturePhase.Idle or DiagnosticCapturePhase.Finished or DiagnosticCapturePhase.Unavailable) && !IsControlling && !_loadingHistory; } }
    public bool CanMark { get { lock (_gate) return WithinWindow() && Phase == DiagnosticCapturePhase.Active && !IsControlling && Snapshot is { State: "recording", ControlAvailable: true, StopRequested: false, OutcomeUnknown: false } s && s.Markers.Count < s.MaximumMarkers; } }
    public bool CanStop { get { lock (_gate) return WithinWindow() && !_stopAttempted && Phase == DiagnosticCapturePhase.Active && !IsControlling && Snapshot is { State: "preparing" or "recording", ControlAvailable: true, StopRequested: false, OutcomeUnknown: false }; } }
    public bool CanCancelPreparation { get { lock (_gate) return WithinWindow() && !_cancelAttempted && Phase == DiagnosticCapturePhase.Active && !IsControlling && Snapshot is { State: "preparing", ControlAvailable: false, OutcomeUnknown: false }; } }

    public void SelectionChanged(DiagnosticCaptureTarget? selection)
    {
        lock (_gate)
        {
            if (Phase != DiagnosticCapturePhase.Checking || (selection?.TargetId == Target?.TargetId && selection?.BindingRevision == Target?.BindingRevision)) return;
            _generation = Guid.NewGuid(); Phase = DiagnosticCapturePhase.Idle; Target = null;
        }
        Notify();
    }

    public async Task StartAsync(DiagnosticCaptureTarget target, int durationSeconds)
    {
        Guid ticket;
        lock (_gate)
        {
            if (!CanStart) return;
            ticket = _generation = Guid.NewGuid(); Phase = DiagnosticCapturePhase.Checking; Target = target;
            JobId = null; Snapshot = null; Failure = null; CompletedContext = null; _submittedAt = null; _deadlineExpired = false;
            _pendingMarker = null; _stopAttempted = _cancelAttempted = _pendingStop = _pendingCancel = false;
        }
        Notify();
        try
        {
            await provider.PreflightAsync(target).ConfigureAwait(false);
            lock (_gate) { if (_generation != ticket) return; Phase = DiagnosticCapturePhase.Submitting; _submittedAt = _clock.GetTimestamp(); }
            Notify();
            var accepted = await provider.SubmitAsync(target, durationSeconds).ConfigureAwait(false);
            if (string.IsNullOrEmpty(accepted)) throw new DiagnosticCaptureFailure("diagnostics_submit_unidentified", true);
            lock (_gate) { if (_generation != ticket) return; JobId = accepted; Phase = DiagnosticCapturePhase.Active; }
            Notify();
            _ = RunAsync(accepted, ticket);
            await RefreshAsync(automatic: true).ConfigureAwait(false);
            _ = MonitorAsync(ticket);
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (_generation != ticket) return;
                Failure = error.Message;
                Phase = Phase == DiagnosticCapturePhase.Submitting && error is not DiagnosticCaptureFailure { Uncertain: false }
                    ? DiagnosticCapturePhase.Uncertain : DiagnosticCapturePhase.Unavailable;
            }
            Notify();
        }
    }

    public Task MarkAsync() => ControlAsync("mark");
    public Task StopAsync() => ControlAsync("stop");
    public Task CancelPreparationAsync() => ControlAsync("cancel");

    private async Task ControlAsync(string action)
    {
        string jobId; DiagnosticCaptureTarget target; Guid ticket; string? markerId = null;
        lock (_gate)
        {
            var allowed = action switch { "mark" => CanMark, "stop" => CanStop, _ => CanCancelPreparation };
            if (!allowed || JobId is not { } id || Target is not { } original) { Failure = "diagnostics_session_control_not_ready"; Notify(); return; }
            jobId = id; target = original; ticket = _generation; IsControlling = true; _revision++;
            if (action == "mark") _pendingMarker = markerId = Guid.NewGuid().ToString("D");
            if (action == "stop") _stopAttempted = _pendingStop = true;
            if (action == "cancel") _cancelAttempted = _pendingCancel = true;
        }
        Notify();
        try
        {
            if (action == "cancel") await provider.CancelPreparationAsync(jobId).ConfigureAwait(false);
            else
            {
                var fresh = action == "mark"
                    ? await provider.MarkAsync(jobId, markerId!, target).ConfigureAwait(false)
                    : await provider.StopAsync(jobId, target).ConfigureAwait(false);
                await PublishAsync(fresh, ticket).ConfigureAwait(false);
            }
        }
        catch (Exception error) { lock (_gate) { if (_generation == ticket) { Failure = error.Message; Phase = DiagnosticCapturePhase.Uncertain; } } }
        finally { lock (_gate) IsControlling = false; Notify(); }
        // A lost answer can never resend this marker, stop or cancellation.
        if (action == "cancel" || Phase == DiagnosticCapturePhase.Uncertain) await RefreshAsync().ConfigureAwait(false);
    }

    public async Task RefreshAsync(bool automatic = false)
    {
        // Status reads are serialized. An older concurrent read cannot replace a later
        // terminal/control snapshot. Control replies invalidate any in-flight read.
        await _reads.WaitAsync().ConfigureAwait(false);
        try
        {
            string jobId; DiagnosticCaptureTarget target; Guid ticket; long revision;
            lock (_gate)
            {
                if (IsControlling || JobId is not { } id || Target is not { } original) return;
                if (automatic && Snapshot?.IsTerminal == true) return;
                if (automatic && !WithinWindow()) { Phase = DiagnosticCapturePhase.Uncertain; Failure = "diagnostics_automatic_reads_ended"; return; }
                jobId = id; target = original; ticket = _generation; revision = _revision;
            }
            try
            {
                var fresh = await provider.StatusAsync(jobId, target).ConfigureAwait(false);
                lock (_gate) { if (_generation != ticket || _revision != revision || IsControlling) return; }
                await PublishAsync(fresh, ticket, revision).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                lock (_gate) { if (_generation != ticket || _revision != revision || Snapshot?.IsTerminal == true) return; Failure = error.Message; Phase = DiagnosticCapturePhase.Uncertain; }
                Notify();
            }
        }
        finally { _reads.Release(); }
    }

    private async Task PublishAsync(DiagnosticCaptureSnapshot fresh, Guid ticket, long? readRevision = null)
    {
        bool history; DiagnosticCaptureTarget target;
        lock (_gate)
        {
            if (_generation != ticket || (readRevision is { } revision && (_revision != revision || IsControlling)) || Target is not { } original || JobId is not { } jobId) return;
            target = original; fresh.Validate(jobId, target);
            if (Snapshot is { } previous && ((previous.IsTerminal && (!previous.Equals(fresh with { Markers = previous.Markers }) || !previous.Markers.SequenceEqual(fresh.Markers)))
                || previous.MaximumSeconds != fresh.MaximumSeconds || previous.MaximumMarkers != fresh.MaximumMarkers
                || (previous.ArmedAtHostUtc is not null && previous.ArmedAtHostUtc != fresh.ArmedAtHostUtc)
                || (previous.State == "recording" && fresh.State == "preparing")
                || (previous.State == "finalizing" && fresh.State is "preparing" or "recording")
                || (previous.StopRequested && !fresh.StopRequested) || fresh.Markers.Count < previous.Markers.Count
                || !previous.Markers.SequenceEqual(fresh.Markers.Take(previous.Markers.Count))))
                throw new DiagnosticCaptureFailure("diagnostics_session_snapshot_regressed", true);
            Snapshot = fresh; Failure = null;
            if (_pendingMarker is { } pending && (fresh.Markers.Any(m => m.MarkerId == pending) || fresh.IsTerminal)) _pendingMarker = null;
            if (fresh.StopRequested || fresh.IsTerminal) _pendingStop = false;
            if (fresh.IsTerminal) _pendingCancel = false;
            Phase = fresh.OutcomeUnknown || fresh.State == "interrupted" || _pendingMarker is not null || _pendingStop || _pendingCancel
                || (!fresh.IsTerminal && !WithinWindow()) ? DiagnosticCapturePhase.Uncertain
                : fresh.IsTerminal ? DiagnosticCapturePhase.Finished : DiagnosticCapturePhase.Active;
            if (_pendingMarker is not null || _pendingStop || _pendingCancel) Failure = "diagnostics_session_control_unconfirmed";
            if (!fresh.IsTerminal && _deadlineExpired) Failure = "diagnostics_automatic_reads_ended";
            history = fresh.IsTerminal && CompletedContext is null && !_loadingHistory;
            if (history) _loadingHistory = true;
        }
        Notify();
        if (!history) return;
        try
        {
            var context = await provider.HistoryAsync(fresh.JobId, target).ConfigureAwait(false);
            if (context.JobId != fresh.JobId || context.TargetId != target.TargetId || context.BindingRevision != target.BindingRevision
                || context.OperationReference != DiagnosticCaptureProvider.Operation || context.State != fresh.JobState) throw new DiagnosticCaptureFailure("diagnostics_history_scope_unconfirmed", true);
            lock (_gate) { if (_generation == ticket) CompletedContext = context; }
        }
        catch (Exception error) { lock (_gate) { if (_generation == ticket) Failure = error.Message; } }
        finally { lock (_gate) _loadingHistory = false; Notify(); }
    }

    private async Task RunAsync(string jobId, Guid ticket)
    {
        try { await provider.RunOnceAsync(jobId).ConfigureAwait(false); }
        catch (Exception error)
        {
            lock (_gate) { if (_generation != ticket || Snapshot?.IsTerminal == true) return; Failure = error.Message; Phase = DiagnosticCapturePhase.Uncertain; }
            Notify();
        }
        await RefreshAsync(automatic: true).ConfigureAwait(false);
    }

    private async Task MonitorAsync(Guid ticket)
    {
        while (true)
        {
            lock (_gate) { if (_generation != ticket || Snapshot?.IsTerminal == true) return; if (!WithinWindow()) break; }
            try { await _pause().ConfigureAwait(false); } catch (OperationCanceledException) { return; }
            lock (_gate) { if (_generation != ticket || Snapshot?.IsTerminal == true) return; if (!WithinWindow()) break; }
            await RefreshAsync(automatic: true).ConfigureAwait(false);
        }
        lock (_gate) { if (_generation != ticket || Snapshot?.IsTerminal == true) return; Phase = DiagnosticCapturePhase.Uncertain; Failure = "diagnostics_automatic_reads_ended"; }
        Notify();
    }

    // This is a local observation bound, not Runtime authority or a capture deadline.
    // Fixed 120s calls issued before it may finish later; their answer cannot revive controls.
    private bool WithinWindow()
    {
        if (_submittedAt is { } started && _clock.GetElapsedTime(started) >= MonitoringBudget) _deadlineExpired = true;
        return !_deadlineExpired;
    }

    private void Notify() => Changed?.Invoke();
}
