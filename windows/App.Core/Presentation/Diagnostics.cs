using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// What the Diagnostics page shows (macOS <c>DiagnosticsWorkspaceViewModel</c>): no record open,
/// a <c>capture.diagnostics@1</c> session read from its verified Artifacts, or a verified
/// <c>analyzer.summarize-hilog@1</c> summary — or the reason either could not be read. Opening a
/// record reads it; nothing here submits, runs or replays a Job.
/// </summary>
public sealed record DiagnosticsState(
    DiagnosticJobContext? Context,
    DiagnosticSessionLoad? Session,
    DiagnosticHilogSummaryLoad? Hilog,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached)
{
    /// <summary>No Diagnostic Session capture provider is composed into the App (macOS
    /// <c>captureUnavailableReasonCode</c>): arm, append-marker and stop are not connected.</summary>
    public const string CaptureUnavailableReasonCode = "diagnostic_session_capture_not_connected";

    public bool IsHilogSummaryContext => Context?.OperationReference == DiagnosticHilogSummary.OperationReference;

    /// <summary>The reason the open record could not be read, or null.</summary>
    public string? LoadError => Session?.UnavailableReason ?? Hilog?.UnavailableReason;

    /// <summary>The Diagnostics context of a Job whose workspace is Diagnostics, or of any
    /// <c>capture.diagnostics@1</c> Job (macOS: Open Diagnostics), else null.</summary>
    public static DiagnosticJobContext? ContextOf(JobSummary job) =>
        IsDiagnosticsRecord(job.Operation, job.WorkspaceKind)
            ? new DiagnosticJobContext(job.JobId, job.Operation, job.TargetId, job.SessionId, job.State, job.ExecutionMode)
            : null;

    /// <summary>macOS <c>RuntimeWorkspaceKindProjection</c>: the Runtime's own
    /// <c>workspaceKind</c>, else the operations whose reference alone is Diagnostics.</summary>
    public static bool IsDiagnosticsRecord(string operation, string? workspaceKind)
    {
        if (operation == DiagnosticSessionOfflineInspector.OperationReference) return true;
        if (workspaceKind is not null) return workspaceKind == "diagnostics";
        var id = operation.Split('@')[0];
        return id is "analyzer.summarize-hilog" or "analyzer.extract-crash-signature";
    }
}

public sealed partial class SurfaceLoader
{
    /// <summary>The bound a caller of the Artifact reader may lower, never raise (macOS
    /// <c>readArtifact</c>).</summary>
    public const int DiagnosticsReadCeiling = 16 * 1_024 * 1_024;

    /// <summary>Reads one History record into Diagnostics: <c>job.show</c> (its correlation and
    /// timeline), every <c>artifact.list</c> page, <c>job.evidence</c>, then the record's own
    /// reader — the session inspector or the HiLog summary verifier — over Artifacts read and
    /// checked against their digests (macOS <c>RuntimeJobDetailXPCProvider</c> and
    /// <c>DiagnosticSessionApplicationReader</c> / <c>DiagnosticHilogSummaryReader</c>).</summary>
    public async Task<DiagnosticsState> DiagnosticsAsync(DiagnosticJobContext? context)
    {
        if (context is null) return new(null, null, null, null, false);
        var (detail, rows, failure, reached) = await DiagnosticDetailAsync(context).ConfigureAwait(false);
        if (failure is not null) return new(context, null, null, failure, reached);
        var reader = DiagnosticReader(context.JobId, rows);
        if (context.OperationReference == DiagnosticHilogSummary.OperationReference)
        {
            var hilog = await DiagnosticHilogSummary.LoadAsync(context, detail, reader).ConfigureAwait(false);
            return new(context, null, hilog, null, reached);
        }
        var session = await DiagnosticSessionApplication.LoadAsync(context, detail, reader).ConfigureAwait(false);
        return new(context, session, null, null, reached);
    }

    /// <summary>A bounded local text preview of one session Artifact, an explicit local action
    /// (macOS <c>preview</c>): the preview, or the reason it is not shown.</summary>
    public async Task<(DiagnosticArtifactOfflinePreview? Preview, string? Failure)> DiagnosticPreviewAsync(
        DiagnosticJobContext context, DiagnosticSessionPresentation session, DiagnosticJobArtifact artifact)
    {
        if (!session.Artifacts.Contains(artifact) || artifact.MediaType is not ("text/plain" or "application/json")) return (null, null);
        var rows = await ArtifactRowsAsync(context.JobId).ConfigureAwait(false);
        if (rows is null) return (null, "Artifact preview failed: the Job's Artifacts could not be listed");
        var read = await DiagnosticReader(context.JobId, rows)(artifact, DiagnosticArtifactTextPreview.MaximumBytes, artifact.Privacy == "sensitive").ConfigureAwait(false);
        if (read.Bytes is not { } bytes) return (null, read.FailureReason);
        try
        {
            if (artifact.ByteCount < 0 || artifact.ByteCount > DiagnosticSessionOfflineInspector.MaximumSafeInteger)
            {
                return (null, DiagnosticSessionText.InvalidStructuredText);
            }
            var metadata = DiagnosticArtifactMetadata.Create(artifact.ArtifactId, artifact.Name, artifact.MediaType, artifact.Privacy, artifact.Status,
                artifact.StatusDetail, artifact.SourceOperation, artifact.ByteCount, artifact.Status == "published" ? artifact.Sha256 : null);
            return (DiagnosticSessionOfflineInspector.Preview(DiagnosticOfflineArtifact.Bind(metadata, bytes), contentAccessExplicit: true), null);
        }
        catch (DiagnosticSessionException)
        {
            return (null, DiagnosticSessionText.InvalidStructuredText);
        }
    }

    private async Task<(DiagnosticJobDetail Detail, IReadOnlyList<ArtifactSummary> Rows, ControlFailure? Failure, bool Reached)> DiagnosticDetailAsync(
        DiagnosticJobContext context)
    {
        var jobId = context.JobId;
        var shown = await ShowAsync(jobId, CliCommands.ForJob(CliCommands.JobStatus, jobId)).ConfigureAwait(false);
        if (shown.DaemonFailure is { } down) return (new(jobId, null, null, [], null), [], down, shown.Reached);
        var correlation = shown.Answer.Value is { } job
            ? DiagnosticJobCorrelation.FromStatus(job.Status, jobId, context.OperationReference)
            : null;
        var timeline = shown.Answer.Value?.Terminal.Timeline ?? [];

        var run = new Run(channel);
        var listed = await run.LoadPages(c => ArtifactPagesAsync(c, jobId), CliCommands.ArtifactListForJob(jobId)).ConfigureAwait(false);
        var evidence = await run.Load(c => c.RequestAsync("job.evidence", Params(("jobId", new JsonString(jobId)))),
            v => new Box<DiagnosticJobEvidence?>(DiagnosticJobEvidence.Parse(v, jobId, context.OperationReference)),
            CliCommands.ForJob(CliCommands.JobEvidence, jobId)).ConfigureAwait(false);
        if (run.DaemonFailure is { } failure) return (new(jobId, null, null, [], null), [], failure, true);
        var rows = listed.Value;
        var artifacts = rows?.Select(r => DiagnosticJobArtifact.From(r, context.OperationReference)).ToArray();
        return (new(jobId, correlation, artifacts, timeline, evidence.Value?.Value), rows ?? [], null, true);
    }

    private async Task<IReadOnlyList<ArtifactSummary>?> ArtifactRowsAsync(string jobId)
    {
        var run = new Run(channel);
        var listed = await run.LoadPages(c => ArtifactPagesAsync(c, jobId), CliCommands.ArtifactListForJob(jobId)).ConfigureAwait(false);
        return listed.Value;
    }

    /// <summary>macOS <c>readArtifact</c> over the App's checked chunk reader: a published
    /// Artifact of this Job within the caller's bound, sensitive only on explicit opt-in, its
    /// SHA-256 the Runtime's digest.</summary>
    private DiagnosticArtifactReader DiagnosticReader(string jobId, IReadOnlyList<ArtifactSummary> rows) => async (artifact, maximumBytes, allowSensitive) =>
    {
        if (maximumBytes <= 0 || maximumBytes > DiagnosticsReadCeiling || artifact.Status != "published" || artifact.ByteCount < 0 || artifact.ByteCount > maximumBytes)
        {
            return DiagnosticArtifactRead.Failed("Artifact is unpublished or exceeds the bounded preview limit");
        }
        if (artifact.Privacy is not ("standard" or "sensitive") || (artifact.Privacy == "sensitive" && !allowSensitive))
        {
            return DiagnosticArtifactRead.Failed("Sensitive Artifact preview requires explicit opt-in");
        }
        var row = rows.FirstOrDefault(r => r.ArtifactId == artifact.ArtifactId && r.Name == artifact.Name);
        if (row is null) return DiagnosticArtifactRead.Failed("Artifact preview failed: the Artifact is not in the Job's inventory");
        var (bytes, failure) = await new ArtifactExporter(channel).ReadAsync(jobId, row, allowSensitive).ConfigureAwait(false);
        if (bytes is not null) return DiagnosticArtifactRead.Loaded(bytes);
        return DiagnosticArtifactRead.Failed(failure!.ReasonCode == ArtifactExporter.IntegrityCode && failure.Detail.Contains("SHA-256", StringComparison.Ordinal)
            ? "Artifact SHA-256 does not match Runtime metadata"
            : $"Artifact preview failed: {failure.ReasonCode}: {failure.Detail}");
    };

    /// <summary>A parsed value that may be null, so <see cref="Loaded{T}"/> can carry it.</summary>
    private sealed record Box<T>(T Value);
}

/// <summary>The fixed macOS texts the Diagnostics readers show that are not catalogue keys.</summary>
public static class DiagnosticSessionText
{
    /// <summary>The preview's refusal of structured text that is not valid UTF-8 (a catalogue
    /// key the page resolves).</summary>
    public const string InvalidStructuredText = "diagnostics.preview.invalidStructuredText";
}
