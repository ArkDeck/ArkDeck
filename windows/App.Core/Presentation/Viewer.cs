using System.Diagnostics;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// The UI dump Viewer's Runtime facts and its two captures, as the macOS
/// <c>UIDumpApplicationFacade</c> has them: a view capture is the typed
/// <c>capture.diagnostics@1</c> with the UI dump preset (<c>DiagnosticCapturePreset.uiDump</c>:
/// screenshot, component tree and dump, every other leg off) on a Connected adopted Target, its
/// same-Job Artifacts read and verified, then parsed and hit-tested on the host
/// (<see cref="UIDumpCapture"/>); a component's Advanced Dump is the preset's
/// <c>componentDetail</c> for its window and component.
/// </summary>
public static class ViewerOperations
{
    public const string Reference = "capture.diagnostics@1";

    /// <summary>The macOS Viewer submits as the Debug logs workspace (<c>debugLogsWorkspace</c>).</summary>
    public const string Client = "ArkDeckApp.DebugWorkspace.Logs";

    /// <summary>The largest capture Artifact the Viewer reads (macOS 32 MiB).</summary>
    public const long MaximumArtifactBytes = 32L * 1024 * 1024;

    public const string AdvancedDumpName = "advanced-dump.txt";
}

/// <summary>An adopted Target and whether a view can be captured from it now: Connected when
/// exactly one current authorized route reaches it, else the macOS reason.</summary>
public sealed record ViewerTarget(TargetSummary Target, string? Name, string? BlockedReason)
{
    public string TargetId => Target.TargetId;

    public bool Connected => BlockedReason is null;

    public string Title => Name ?? Target.DisplayName ?? Target.TargetId;

    /// <summary>macOS <c>targetConnections</c> over the device observation.</summary>
    public static IReadOnlyList<ViewerTarget> Join(IReadOnlyList<TargetSummary> targets, Loaded<IReadOnlyList<DeviceCandidate>> observation)
    {
        string? failure = observation.Unavailable is { } why ? "Could not read current device state: " + why.Detail : null;
        var routes = new Dictionary<string, DeviceCandidate>(StringComparer.Ordinal);
        foreach (var candidate in observation.Value ?? [])
        {
            if (candidate.AdoptedTargetId is not { } id) continue;
            if (!routes.TryAdd(id, candidate))
            {
                failure = $"Runtime reported more than one current route for target {id}";
                routes.Clear();
                break;
            }
        }
        return targets.Select(target =>
        {
            if (failure is null && routes.TryGetValue(target.TargetId, out var candidate))
            {
                var reason = candidate.AuthorizationState == "Connected" && !candidate.Stale ? null
                    : candidate.Stale ? $"HDC reported {candidate.AuthorizationState}, but that observation is stale"
                    : $"HDC reported {candidate.AuthorizationState}";
                return new ViewerTarget(target, candidate.DisplayName ?? candidate.DeviceName, reason);
            }
            return new ViewerTarget(target, null, failure ?? "No current HDC route was reported for this target");
        }).ToArray();
    }
}

/// <summary>The Viewer: the operation's facts, the Targets with their routes, the recent
/// diagnostics Jobs.</summary>
public sealed record ViewerState(
    OperationFacts Operation,
    Loaded<IReadOnlyList<TargetSummary>> Targets,
    IReadOnlyList<ViewerTarget> JoinedTargets,
    Loaded<IReadOnlyList<RecentJob>> Jobs,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>How long each step of a capture took (the macOS footer's signposts).</summary>
public sealed record ViewerCaptureMetrics(long? SubmitMilliseconds, long? RunMilliseconds, long ListMilliseconds, long ReadMilliseconds,
    long ReadBytes, long ParseMilliseconds);

/// <summary>A captured view (its Job, the parsed capture and the timings), or why not.</summary>
public sealed record ViewerCaptureOutcome(string? JobId, ViewerCapture? Capture, ViewerCaptureMetrics? Metrics, string? Failure,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>A component's Advanced Dump fields, or why not.</summary>
public sealed record ViewerAdvancedDumpOutcome(IReadOnlyList<ViewerDumpField>? Fields, string? Failure, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

public sealed partial class SurfaceLoader
{
    /// <summary>The Viewer (macOS <c>refresh</c>): the operation's facts, the Targets joined with
    /// the device observation, and the recent diagnostics Jobs.</summary>
    public async Task<ViewerState> ViewerAsync()
    {
        var run = new Run(channel);
        OperationFacts operation;
        try
        {
            operation = (await OperationsAsync(channel, [ViewerOperations.Reference]).ConfigureAwait(false))[0];
        }
        catch (ControlClientException error) when (error.Failure.ShowsRecoveryBanner)
        {
            operation = OperationFacts.Unread(ViewerOperations.Reference, [error.Failure.Message]);
        }
        var targets = await run.Load(c => c.RequestAsync("target.list"), TargetSummary.ParseAll, CliCommands.TargetList);
        var observation = await run.Load(c => c.RequestAsync("device.observations"), DeviceCandidate.ParseAll, CliCommands.DeviceCandidates);
        var jobs = await run.Load(c => c.RequestAsync("job.list", RecentJobParams()),
            v => (IReadOnlyList<RecentJob>)RecentJob.ParsePage(v).Where(j => j.Operation == ViewerOperations.Reference).ToArray(), CliCommands.JobList);
        return new(operation, targets, ViewerTarget.Join(targets.Value ?? [], observation), jobs, run.DaemonFailure, run.Reached);
    }

    /// <summary>Captures the view of a Connected Target (macOS <c>recapture</c>): the UI dump
    /// preset submitted, run to its end, its terminal facts checked (succeeded, known outcome,
    /// no person waited for, no residue), then its capture loaded.</summary>
    public async Task<ViewerCaptureOutcome> CaptureViewAsync(TargetSummary target)
    {
        var request = RuntimeRequest.Build("viewer-capture-ui", "capture.diagnostics", 1, target.TargetId, target.BindingRevision,
        [
            ("durationSeconds", JsonNumber.FromInt64(1)),
            ("captureHilog", JsonBool.False),
            ("hilogFilters", new JsonArray([])),
            ("uiDump", JsonBool.True),
            ("crashLogs", JsonBool.False),
            ("uiScreenshot", JsonBool.True),
            ("uiComponentTree", JsonBool.True),
            ("redactionProfile", new JsonString("standard")),
        ], ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], ViewerOperations.Client);
        var clock = Stopwatch.StartNew();
        var submitted = await SubmitAsync(request, CliCommands.UiDumpCapture).ConfigureAwait(false);
        var submit = clock.ElapsedMilliseconds;
        if (submitted.Answer.Value is not { } accepted)
        {
            return new(null, null, null, "Runtime refused the request: " + submitted.Answer.Unavailable?.Detail, submitted.DaemonFailure, submitted.Reached);
        }
        clock.Restart();
        var terminal = await SafeTerminalAsync(accepted.JobId, "Viewer capture").ConfigureAwait(false);
        var ran = clock.ElapsedMilliseconds;
        if (terminal is not null) return new(accepted.JobId, null, null, terminal.Value.Failure, terminal.Value.DaemonFailure, true);
        return await LoadViewCaptureAsync(accepted.JobId, target, submit, ran).ConfigureAwait(false);
    }

    /// <summary>A capture Job's view, from its verified same-Job Artifacts (macOS
    /// <c>loadCapture</c>): exactly one <c>screenshot.png</c> and one <c>ui-tree.json</c>, at most
    /// one <c>ui-dump.json</c>, each published, sensitive and at most 32 MiB, read and parsed.</summary>
    public async Task<ViewerCaptureOutcome> LoadViewCaptureAsync(string jobId, TargetSummary target, long? submitMilliseconds = null, long? runMilliseconds = null)
    {
        var run = new Run(channel);
        var clock = Stopwatch.StartNew();
        var listed = await run.LoadPages(c => ArtifactPagesAsync(c, jobId), CliCommands.ArtifactListForJob(jobId));
        var list = clock.ElapsedMilliseconds;
        if (listed.Value is not { } rows) return new(jobId, null, null, listed.Unavailable?.Detail ?? "Viewer Artifacts are unavailable", run.DaemonFailure, run.Reached);
        UIDumpSelection selection;
        try
        {
            selection = UIDumpCapture.SelectArtifacts(jobId, rows.Select(r => UIDumpArtifactEntry.FromSummary(r)).ToArray());
        }
        catch (UIDumpDerivationException error)
        {
            return new(jobId, null, null, "Viewer capture is missing exactly one of its Artifacts: " + error.Message, run.DaemonFailure, true);
        }
        var sources = new[] { selection.Screenshot, selection.Tree, selection.RawDump }.OfType<UIDumpSource>().ToArray();
        if (sources.Any(s => s.ByteCount > ViewerOperations.MaximumArtifactBytes))
        {
            return new(jobId, null, null, "Viewer Artifact exceeds the 32 MiB read bound", run.DaemonFailure, true);
        }
        clock.Restart();
        var bytes = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var reader = new ArtifactExporter(channel);
        foreach (var source in sources)
        {
            var artifact = rows.First(r => r.ArtifactId == source.ArtifactId);
            var (data, failure) = await reader.ReadAsync(jobId, artifact, allowSensitive: true).ConfigureAwait(false);
            if (data is null) return new(jobId, null, null, failure!.Detail, failure.Failure?.Kind == ControlFailureKind.DaemonUnavailable ? failure.Failure : run.DaemonFailure, true);
            bytes[source.ArtifactId] = data;
        }
        var read = clock.ElapsedMilliseconds;
        clock.Restart();
        try
        {
            var inspection = UIDumpCapture.Derive(selection, bytes[selection.Screenshot.ArtifactId], bytes[selection.Tree.ArtifactId],
                selection.RawDump is { } raw ? bytes[raw.ArtifactId] : null,
                new ViewerCaptureIdentity(jobId, target.TargetId, target.BindingRevision, selection.ObservedToUtc ?? selection.ObservedFromUtc ?? ""));
            var metrics = new ViewerCaptureMetrics(submitMilliseconds, runMilliseconds, list, read, bytes.Values.Sum(b => (long)b.Length), clock.ElapsedMilliseconds);
            return new(jobId, inspection.Capture, metrics, null, run.DaemonFailure, true);
        }
        catch (UIDumpDerivationException error)
        {
            return new(jobId, null, null, "Viewer offline inspection rejected the published Artifact set: " + error.Message, run.DaemonFailure, true);
        }
    }

    /// <summary>One component's Advanced Dump (macOS <c>advancedDump</c>): the component-detail
    /// preset for its window and component, run, checked, and its one <c>advanced-dump.txt</c>
    /// read and parsed.</summary>
    public async Task<ViewerAdvancedDumpOutcome> AdvancedDumpAsync(TargetSummary target, ViewerAdvancedDumpSelection selection)
    {
        bool Identifier(string value) => value.Length is > 0 and <= 20 && value.All(char.IsAsciiDigit);
        if (!Identifier(selection.WindowId) || !Identifier(selection.ComponentId))
        {
            return new(null, "windowId and componentId must be 1...20 ASCII decimal digits", null, false);
        }
        var request = RuntimeRequest.Build("viewer-advanced-dump", "capture.diagnostics", 1, target.TargetId, target.BindingRevision,
        [
            ("durationSeconds", JsonNumber.FromInt64(1)),
            ("captureHilog", JsonBool.False),
            ("hilogFilters", new JsonArray([])),
            ("uiDump", JsonBool.False),
            ("crashLogs", JsonBool.False),
            ("uiScreenshot", JsonBool.False),
            ("uiComponentTree", JsonBool.False),
            ("redactionProfile", new JsonString("standard")),
            ("advancedDump", JsonBool.True),
            ("windowId", new JsonString(selection.WindowId)),
            ("componentId", new JsonString(selection.ComponentId)),
        ], ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], ViewerOperations.Client);
        var submitted = await SubmitAsync(request, CliCommands.UiDumpComponentDetail).ConfigureAwait(false);
        if (submitted.Answer.Value is not { } accepted)
        {
            return new(null, "Runtime refused the request: " + submitted.Answer.Unavailable?.Detail, submitted.DaemonFailure, submitted.Reached);
        }
        if (await SafeTerminalAsync(accepted.JobId, "Advanced Dump").ConfigureAwait(false) is { } unsafeEnd)
        {
            return new(null, unsafeEnd.Failure, unsafeEnd.DaemonFailure, true);
        }
        var run = new Run(channel);
        var listed = await run.LoadPages(c => ArtifactPagesAsync(c, accepted.JobId), CliCommands.ArtifactListForJob(accepted.JobId));
        var matches = (listed.Value ?? []).Where(a => a.Name == ViewerOperations.AdvancedDumpName).ToArray();
        if (matches is not [{ MediaType: "text/plain", IsPublished: true, IsSensitive: true } artifact] || artifact.ByteCount > ViewerOperations.MaximumArtifactBytes)
        {
            return new(null, $"Viewer capture is missing exactly one {ViewerOperations.AdvancedDumpName} Artifact", run.DaemonFailure, true);
        }
        var (data, failure) = await new ArtifactExporter(channel).ReadAsync(accepted.JobId, artifact, allowSensitive: true).ConfigureAwait(false);
        if (data is null) return new(null, failure!.Detail, run.DaemonFailure, true);
        try
        {
            return new(UIDumpCapture.ParseAdvancedDump(data), null, run.DaemonFailure, true);
        }
        catch (Exception error) when (error is UIDumpCaptureException or UIDumpDerivationException or FormatException)
        {
            return new(null, error.Message, run.DaemonFailure, true);
        }
    }

    /// <summary>Runs an admitted capture to its end and checks its terminal facts; null when it
    /// ended safely (succeeded, known outcome, nobody waited for, no residue).</summary>
    private async Task<(string Failure, ControlFailure? DaemonFailure)?> SafeTerminalAsync(string jobId, string label)
    {
        var shown = await RunAndShowAsync(jobId, CliCommands.UiDumpCapture).ConfigureAwait(false);
        if (shown.Answer.Value is not { } job) return ("Runtime refused the request: " + shown.Answer.Unavailable?.Detail, shown.DaemonFailure);
        var status = job.Status;
        var waiting = status.TryGetValue("waitingForHuman", out var w) && w is JsonBool { Value: true };
        var residue = status.TryGetValue("outstandingResidueCount", out var r) && r is JsonNumber n && n.TryGetInt64(out var count) ? count : 0;
        return job.Terminal is { State: "succeeded", OutcomeUnknown: false } && !waiting && residue == 0
            ? null
            : ($"{label} did not produce a safe terminal result ({job.Terminal.State})", shown.DaemonFailure);
    }
}
