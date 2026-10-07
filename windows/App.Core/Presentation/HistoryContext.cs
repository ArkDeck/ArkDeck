using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>The workspace a Job belongs to (macOS <c>RuntimeWorkspaceKind</c>).</summary>
public enum WorkspaceKind
{
    Flash,
    Viewer,
    Trace,
    Diagnostics,
    Debug,
    Device,
}

/// <summary>
/// The immutable context History hands a workspace when a record is reopened (macOS
/// <c>RuntimeHistoryWorkspaceContext</c>): the Job's identity, its Target and binding, its
/// typed inputs and its Artifacts. It is not a request: no workspace submits, runs, retries,
/// cancels or replays the historical Job from it.
/// </summary>
public sealed record HistoryWorkspaceContext(
    string JobId,
    string OperationReference,
    string TargetId,
    string State,
    string? ExecutionMode,
    string? SessionId,
    WorkspaceKind Kind,
    long? BindingRevision,
    JsonObject? TypedParameters,
    IReadOnlyList<ArtifactSummary> Artifacts)
{
    public const string CaptureDiagnostics = "capture.diagnostics@1";

    /// <summary>The context of a Job whose detail was read, or null when its workspace cannot be
    /// told (macOS: the Job's own <c>workspaceKind</c>, else the operations whose reference alone
    /// names one, else the typed diagnostics inputs of its evidence).</summary>
    public static HistoryWorkspaceContext? Of(JobSummary job, JobEvidenceFacts? evidence, IReadOnlyList<ArtifactSummary>? artifacts)
    {
        var kind = Parse(job.WorkspaceKind) ?? UnambiguousKind(job.Operation) ?? KindFromInputs(job.Operation, evidence?.Parameters);
        return kind is { } k
            ? new HistoryWorkspaceContext(job.JobId, job.Operation, job.TargetId, job.State, job.ExecutionMode, job.SessionId, k,
                evidence?.BindingRevision ?? evidence?.ObservedBindingRevision, evidence?.Parameters, artifacts ?? [])
            : null;
    }

    public DiagnosticJobContext Diagnostics => new(JobId, OperationReference, TargetId, SessionId, State, ExecutionMode);

    public static WorkspaceKind? Parse(string? kind) => kind switch
    {
        "flash" => WorkspaceKind.Flash,
        "viewer" => WorkspaceKind.Viewer,
        "trace" => WorkspaceKind.Trace,
        "diagnostics" => WorkspaceKind.Diagnostics,
        "debug" => WorkspaceKind.Debug,
        "device" => WorkspaceKind.Device,
        _ => null,
    };

    public static string Name(WorkspaceKind kind) => kind switch
    {
        WorkspaceKind.Flash => "flash",
        WorkspaceKind.Viewer => "viewer",
        WorkspaceKind.Trace => "trace",
        WorkspaceKind.Diagnostics => "diagnostics",
        WorkspaceKind.Debug => "debug",
        _ => "device",
    };

    /// <summary>macOS <c>unambiguousKind(forOperation:)</c>: <c>capture.diagnostics</c> stays unknown.</summary>
    public static WorkspaceKind? UnambiguousKind(string reference)
    {
        // ArkForgeFlashOperation.containsDurableRecordReference.
        if (reference is "flash.full-restore@1" or "flash.dayu200" or "flash.dayu200@1") return WorkspaceKind.Flash;
        var id = reference.Split('@')[0];
        return id switch
        {
            "debug.hap" or "debug.template" or "deploy.native-library.app-owned" or "port-forward.create" or "port-forward.remove" => WorkspaceKind.Debug,
            "input.tap" or "input.long-press" or "input.swipe" or "capture.screen-sequence" => WorkspaceKind.Device,
            "observe.device" or "observe.devices" => WorkspaceKind.Viewer,
            "analyzer.analyze-trace" or "analyzer.summarize-trace" => WorkspaceKind.Trace,
            "capture.diagnostic-session" or "analyzer.extract-crash-signature" or "analyzer.summarize-hilog" => WorkspaceKind.Diagnostics,
            _ => null,
        };
    }

    /// <summary>macOS <c>diagnosticsKind(inputs:)</c> over the typed inputs a
    /// <c>capture.diagnostics@1</c> record carries; null when none of them is present.</summary>
    public static WorkspaceKind? KindFromInputs(string reference, JsonObject? inputs)
    {
        if (reference.Split('@')[0] != "capture.diagnostics" || inputs is null) return null;
        string[] booleans = ["uiComponentTree", "uiDump", "advancedDump", "uiScreenshot", "captureHilog", "crashLogs"];
        string[] arrays = ["hilogFilters", "traceCategories"];
        if (!inputs.Members.Any(m => booleans.Contains(m.Key) || arrays.Contains(m.Key))) return null;
        bool On(string key) => inputs.TryGetValue(key, out var v) && v is JsonBool { Value: true };
        bool Some(string key) => inputs.TryGetValue(key, out var v) && v is JsonArray { Items.Count: > 0 };
        if (On("uiComponentTree") || On("uiDump") || On("advancedDump")) return WorkspaceKind.Viewer;
        if (Some("traceCategories")) return WorkspaceKind.Trace;
        if (On("uiScreenshot") && !On("captureHilog") && !On("crashLogs") && !Some("hilogFilters")) return WorkspaceKind.Device;
        return WorkspaceKind.Diagnostics;
    }

    /// <summary>The Debug tab that ran the operation (macOS <c>rememberHistoryContext</c>).</summary>
    public string DebugTab => OperationReference.Split('@')[0] switch
    {
        "debug.hap" => "apps",
        "port-forward.create" or "port-forward.remove" => "network",
        "capture.diagnostics" => "logs",
        "debug.template" => "commands",
        _ => "artifacts",
    };
}
