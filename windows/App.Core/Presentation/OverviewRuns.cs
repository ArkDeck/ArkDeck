using System.Globalization;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>Whether a finished run may be offered as "run it again", and when not, why (macOS
/// <c>OverviewRunResumeDisposition</c>). Every refusal names itself; none is an enabled guess.</summary>
public enum ResumeDisposition
{
    /// <summary>Terminal, read-only or host-only, and its typed inputs were reported.</summary>
    Resumable,
    /// <summary>Terminal, but its effect grade re-enters the workspace's authorization gate.</summary>
    RequiresAuthorization,
    /// <summary>The external effect is unknown: an unknown intent is never replayed.</summary>
    NeverReplayed,
    /// <summary>Still running.</summary>
    NotTerminal,
    /// <summary>The Runtime recorded no effect grade.</summary>
    EffectUnknown,
    /// <summary>The run did not report its typed inputs.</summary>
    ParametersNotReported,
    /// <summary>The run's evidence has not been read yet.</summary>
    DetailNotLoaded,
}

/// <summary>One line of work (macOS <c>OverviewRunThread</c>): the runs a workspace filed under
/// one thread, oldest first; a run without a thread is its own line.</summary>
public sealed record OverviewRunThread(
    string Id,
    string? ThreadId,
    string TargetId,
    IReadOnlyList<string> OperationReferences,
    IReadOnlyList<JobSummary> Runs,
    bool NeedsAttention,
    string? FirstActivityUtc,
    string? LastActivityUtc)
{
    internal DateTimeOffset? SortKey => Runs.Select(OverviewRuns.ActivityDate).Where(d => d is not null).Max();
}

/// <summary>
/// The Overview's run record (macOS <c>OverviewRunRecordProjection</c> and the record view's
/// helpers): which runs belong to one line of work, which one is shown first, and whether a
/// finished run may be offered again.
/// </summary>
public static class OverviewRuns
{
    /// <summary>Effect grades a workspace may repeat without re-entering an authorization gate.</summary>
    public static readonly IReadOnlySet<string> RepeatableEffects = new HashSet<string>(StringComparer.Ordinal) { "readOnly", "hostOnly" };

    /// <summary>macOS <c>needsAttention</c>: an unknown outcome or a wait on a person, unless the
    /// Runtime established a later epoch.</summary>
    public static bool NeedsAttention(JobSummary job) =>
        !JobRecovery.HasEstablishedCurrentEpoch(job) && (job.OutcomeUnknown || job.WaitingForHuman);

    /// <summary>When the run last moved: finished, else started, else created.</summary>
    public static DateTimeOffset? ActivityDate(JobSummary job) =>
        DateTimeOffset.TryParse(job.FinishedAtUtc ?? job.StartedAtUtc ?? job.CreatedAtUtc, CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out var date) ? date : null;

    /// <summary>Lines of work, those that need a person first, then the most recently active;
    /// truncated by whole lines to <paramref name="limit"/> (History keeps the rest).</summary>
    public static IReadOnlyList<OverviewRunThread> Threads(IEnumerable<JobSummary> jobs, int limit = 4)
    {
        var order = new List<string>();
        var grouped = new Dictionary<string, List<JobSummary>>(StringComparer.Ordinal);
        foreach (var job in jobs)
        {
            var key = job.ThreadId is { } thread ? "thread:" + thread : "run:" + job.JobId;
            if (!grouped.TryGetValue(key, out var members))
            {
                grouped[key] = members = [];
                order.Add(key);
            }
            members.Add(job);
        }
        var threads = order.Select(key =>
        {
            var runs = grouped[key].OrderBy(r => ActivityDate(r) ?? DateTimeOffset.MinValue).ToArray();
            var references = runs.Select(r => r.Operation).Distinct(StringComparer.Ordinal).ToArray();
            var stamps = runs.Select(r => (string?)r.CreatedAtUtc ?? r.StartedAtUtc ?? r.FinishedAtUtc).ToArray();
            return new OverviewRunThread(key, runs[0].ThreadId, runs[0].TargetId, references, runs,
                runs.Any(r => NeedsAttention(r) || r.OutstandingResidueCount > 0),
                stamps.FirstOrDefault(), runs.Select(r => r.FinishedAtUtc).LastOrDefault(f => f is not null) ?? stamps.LastOrDefault());
        }).ToArray();
        var ranked = threads.Select((thread, index) => (thread, index))
            .OrderBy(p => p.thread.NeedsAttention ? 0 : 1)
            .ThenBy(p => p.thread.SortKey is null ? 1 : 0)
            .ThenByDescending(p => p.thread.SortKey ?? DateTimeOffset.MinValue)
            .ThenBy(p => p.index)
            .Select(p => p.thread);
        return (limit >= 0 ? ranked.Take(limit) : ranked).ToArray();
    }

    /// <summary>The run shown without another click: the latest unresolved one, else the latest.</summary>
    public static JobSummary? Featured(OverviewRunThread thread) =>
        thread.Runs.LastOrDefault(r => NeedsAttention(r) || r.OutstandingResidueCount > 0) ?? thread.Runs.LastOrDefault();

    /// <summary>The line's other runs, newest first, at most <paramref name="limit"/>.</summary>
    public static IReadOnlyList<JobSummary> Additional(OverviewRunThread thread, JobSummary featured, int limit = 3) =>
        limit <= 0 ? [] : thread.Runs.Where(r => r.JobId != featured.JobId).TakeLast(limit).Reverse().ToArray();

    /// <summary>macOS <c>resumeDisposition</c>: <paramref name="parametersReported"/> is null
    /// until the run's evidence was read.</summary>
    public static ResumeDisposition Disposition(JobSummary job, bool? parametersReported)
    {
        if (job.OutcomeUnknown && !JobRecovery.HasEstablishedCurrentEpoch(job)) return ResumeDisposition.NeverReplayed;
        if (!JobSummary.TerminalStates.Contains(job.State)) return ResumeDisposition.NotTerminal;
        if (job.ActualEffect is not { Length: > 0 } effect) return ResumeDisposition.EffectUnknown;
        if (!RepeatableEffects.Contains(effect)) return ResumeDisposition.RequiresAuthorization;
        return parametersReported switch
        {
            null => ResumeDisposition.DetailNotLoaded,
            false => ResumeDisposition.ParametersNotReported,
            true => ResumeDisposition.Resumable,
        };
    }

    /// <summary>The record view's workspace of a run (macOS
    /// <c>OverviewActionProjection.workspaceKind</c>): the operation, and for the shared
    /// diagnostics operation the inputs it asked for; null when they do not settle it.</summary>
    public static WorkspaceKind? TitleKind(string operation, JsonObject? parameters)
    {
        if (operation is "flash.full-restore@1" or "flash.dayu200" or "flash.dayu200@1") return WorkspaceKind.Flash;
        bool On(string key) => parameters is not null && parameters.TryGetValue(key, out var v) && v is JsonBool { Value: true };
        return operation.Split('@')[0] switch
        {
            "debug.hap" => WorkspaceKind.Debug,
            "input.tap" or "input.long-press" or "input.swipe" => WorkspaceKind.Device,
            "capture.diagnostics" when On("uiComponentTree") || On("advancedDump") => WorkspaceKind.Viewer,
            "capture.diagnostics" when parameters is not null && parameters.TryGetValue("traceCategories", out var t) && t is JsonArray { Items.Count: > 0 } => WorkspaceKind.Trace,
            "capture.diagnostics" when On("uiScreenshot") && !On("uiDump") => WorkspaceKind.Device,
            _ => null,
        };
    }

    /// <summary>The workspace "Open Workspace" goes to (macOS <c>resolvedWorkspaceKind</c>, else
    /// the inputs): null when neither settles it.</summary>
    public static WorkspaceKind? OpenKind(JobSummary job, JsonObject? parameters) =>
        HistoryWorkspaceContext.Parse(job.WorkspaceKind) ?? HistoryWorkspaceContext.UnambiguousKind(job.Operation)
        ?? HistoryWorkspaceContext.KindFromInputs(job.Operation, parameters);

    /// <summary>The operation without its version.</summary>
    public static string DisplayedOperation(string reference) => reference.Split('@')[0];
}

/// <summary>
/// A new read-only request prepared from a finished run (macOS
/// <c>RuntimeWorkspaceContinuation</c>): its typed inputs exactly as reported, for the same
/// Target at the same binding. Not a replay: no authority, Artifact lease, marker time or Runtime
/// session is carried, and nothing is submitted until the person starts it.
/// </summary>
public sealed record WorkspaceContinuation(JobSummary SourceJob, WorkspaceKind Kind, long BindingRevision, JsonObject Inputs)
{
    /// <summary>The closed scope: the two published device-bound observation operations.</summary>
    public const string ObserveDevice = "observe.device@1";

    public static readonly IReadOnlyList<string> Operations = [ObserveDevice, HistoryWorkspaceContext.CaptureDiagnostics];

    public const string ClientName = "arkdeck-overview-continuation";

    /// <summary>The draft, or the reason code macOS states when none can be prepared.</summary>
    public static (WorkspaceContinuation? Draft, string? Failure) Prepare(JobSummary job, JobEvidenceFacts? evidence, string? currentTargetId, long? currentBindingRevision)
    {
        if (OverviewRuns.Disposition(job, evidence is null ? null : evidence.Parameters is not null) != ResumeDisposition.Resumable)
        {
            return (null, "continuation_source_not_repeatable");
        }
        if (!Operations.Contains(job.Operation) || evidence?.Parameters is not { } inputs || evidence.ActualEffect != job.ActualEffect
            || (HistoryWorkspaceContext.Parse(job.WorkspaceKind) ?? HistoryWorkspaceContext.UnambiguousKind(job.Operation)
                ?? HistoryWorkspaceContext.KindFromInputs(job.Operation, inputs)) is not { } kind)
        {
            return (null, "continuation_typed_source_unavailable");
        }
        if (currentTargetId != job.TargetId || evidence.BindingRevision is not ({ } recorded and > 0) || currentBindingRevision != recorded)
        {
            return (null, "continuation_target_or_binding_changed");
        }
        if (!inputs.Members.All(m => m.Value is JsonBool or JsonString || (m.Value is JsonNumber n && n.TryGetInt64(out _))
                                     || (m.Value is JsonArray a && a.Items.All(i => i is JsonString))))
        {
            return (null, "continuation_inputs_not_read_only_or_invalid");
        }
        if (inputs.TryGetValue("markers", out var markers) && markers is JsonArray { Items.Count: > 0 })
        {
            return (null, "continuation_markers_require_new_capture_times");
        }
        return (new WorkspaceContinuation(job, kind, recorded, inputs), null);
    }

    /// <summary>A fresh request with a new request ID and idempotency key; the source Job and its
    /// thread go along as provenance only.</summary>
    public RuntimeRequest Request()
    {
        var provenance = new List<(string, JsonValue)> { ("arkdeck.continuedFromJob", new JsonString(SourceJob.JobId)) };
        if (SourceJob.ThreadId is { } thread) provenance.Add(("arkdeck.threadId", new JsonString(thread)));
        return RuntimeRequest.Build("continue-ui", SourceJob.Operation == ObserveDevice ? "observe.device" : "capture.diagnostics", 1, SourceJob.TargetId, BindingRevision,
            Inputs.Members.Select(m => (m.Key, m.Value)), ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], ClientName, provenance: provenance);
    }
}
