using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>The CLI command each surface's data is also read with
/// (openspec/contracts/cli-feature-coverage.json targetCommand of the surface's feature).</summary>
public static class CliCommands
{
    public const string Doctor = "arkdeck doctor";                    // app.overview.main, doctor
    public const string RuntimeHealth = "arkdeck runtime health";     // app.overview.environment, health
    public const string DeviceCandidates = "arkdeck device candidates"; // app.device.details
    public const string JobList = "arkdeck job list";                 // app.history.list, job.list
    public const string JobStatus = "arkdeck job status --job <job-id>"; // job.status
    public const string JobEvents = "arkdeck job events --job <job-id>"; // job.events
    public const string TargetList = "arkdeck target list";           // target.list
    public const string TargetShow = "arkdeck target show --target <target-id>"; // target.show, app.device.details
    public const string TargetAvailability = "arkdeck target availability --target <target-id>"; // target.availability
    public const string TargetDisplayNameSet = "arkdeck target display-name set --target <target-id> --expected-generation <n> --name <text>"; // app.device.rename
    public const string TargetDisplayNameClear = "arkdeck target display-name clear --target <target-id> --expected-generation <n>"; // target.display-name.clear
    public const string ArtifactList = "arkdeck artifact list (--job <id> | --import <id>)"; // artifact.list, app.history.detail
    public const string ArtifactRead = "arkdeck artifact read --artifact <artifact-id> (--job <id> | --import <id>)"; // artifact.read, app.history.export
    public const string TraceInspect = "arkdeck trace inspect --job <job-id> --artifact <artifact-id> --allow-sensitive"; // trace.inspect

    public const string RuntimeServiceStatus = "arkdeck runtime service status";   // runtime.service.status
    public const string RuntimeServiceVerify = "arkdeck runtime service verify";   // runtime.service.verify
    public const string RuntimeServiceRestart = "arkdeck runtime service restart"; // runtime.service.restart
    public const string RuntimeSigningStatus = "arkdeck runtime signing status";   // app.settings.toolchains
    public const string RuntimeHdcStatus = "arkdeck runtime hdc status";           // runtime.hdc.status
    public const string RuntimeToolList = "arkdeck runtime tool list";             // runtime.tool.list, app.settings.toolchains
    public const string RuntimeStorageStatus = "arkdeck runtime storage status";   // runtime.storage.status, app.settings.storage
    public const string TraceCacheStatus = "arkdeck trace cache status";           // trace.cache.status, app.settings.traceCache
    public const string WorkspaceProjectList = "arkdeck workspace project list";   // workspace.project.list
    public const string WorkspaceProjectRegister = "arkdeck workspace project register --registration-request-id <id> --kind <arkdeck|openharmony> --root <absolute-path>"; // workspace.project.register
    public const string WorkspaceProjectShow = "arkdeck workspace project show --project <project-ref>"; // workspace.project.show
    public const string WorkspacePresetList = "arkdeck workspace preset list --project <project-ref>";   // workspace.preset.list

    public const string JobCancel = "arkdeck job cancel --job <job-id>";           // job.cancel
    public const string JobResult = "arkdeck job result --job <job-id>";           // job.result
    public const string JobEvidence = "arkdeck job evidence --job <job-id>";       // job.evidence
    public const string SessionList = "arkdeck session list";                      // session.list
    public const string SessionShow = "arkdeck session show --session <session-id>"; // session.show
    public const string SessionPin = "arkdeck session pin --session <session-id> --expected-generation <non-negative-integer>"; // session.pin
    public const string SessionUnpin = "arkdeck session unpin --session <session-id> --expected-generation <non-negative-integer>"; // session.unpin
    public const string SessionCleanupPreview = "arkdeck session cleanup preview"; // session.cleanup.preview
    public const string SessionCleanupApply = "arkdeck session cleanup apply --preview-id <id> --preview-digest <sha256>"; // session.cleanup.apply
    public const string SessionExportPreview = "arkdeck session export preview --session <session-id> --destination <new-directory>"; // session.export.preview
    public const string SessionExportApply = "arkdeck session export apply --preview-id <id> --preview-digest <sha256>"; // session.export.apply

    public const string AgentList = "arkdeck agent list";                          // agent.list
    public const string AgentStatus = "arkdeck agent status (--execution-id <id>)"; // agent.status
    public const string AgentResume = "arkdeck agent resume (--resume-reference <ref> | --resume-token <token>)"; // agent.resume, app.overview.resume
    public const string AgentAbandon = "arkdeck agent abandon --expected-generation <n> (--execution-id <id>)"; // agent.abandon
    public const string HumanActionList = "arkdeck human-action list";             // human-action.list, app.shell.recovery
    public const string HumanActionShow = "arkdeck human-action show --human-action <id>"; // human-action.show
    public const string HumanActionResume = "arkdeck human-action resume --human-action <id> --resume-reference <ref>"; // human-action.resume
    public const string ImportList = "arkdeck artifact import list";               // artifact.import.list
    public const string ImportInspect = "arkdeck artifact import inspect (--import <id> | --import-request-id <id>)"; // artifact.import.inspect
    public const string ImportRelease = "arkdeck artifact import release --import <id> --generation <generation>"; // artifact.import.release
    public const string ImportHap = "arkdeck artifact import hap --import-request-id <id> --target <target-id> --file <path>"; // artifact.import.begin|append|commit
    public const string ImportFlashBundle = "arkdeck artifact import flash-bundle --import-request-id <id> --target <target-id> --file <path>"; // artifact.import.flash-bundle
    public const string ImportWorkspacePatch = "arkdeck artifact import workspace-patch --import-request-id <id> --target <target-id> --file <path>"; // artifact.import.workspace-patch
    public const string ImportNativeLibrary = "arkdeck artifact import native-library ..."; // app.debug.artifacts
    public const string DebugProbe = "arkdeck debug probe --target <target-id>";   // debug.probe
    public const string DebugLogs = "arkdeck debug logs --inputs-file <path>";     // capture.diagnostics@1 (the Debug logs preset)
    public const string DebugHap = "arkdeck debug hap --inputs-file <path>";       // debug.hap@1
    public const string DebugNativeLibrary = "arkdeck debug native deploy --inputs-file <path>"; // deploy.native-library.app-owned@1
    public const string DebugTemplate = "arkdeck debug template run --inputs-file <path>"; // debug.template@1
    public const string DebugPortForward = "arkdeck port-forward create --inputs-file <path>"; // port-forward.create|remove@1
    public const string DebugPortForwardRemove = "arkdeck port-forward remove --inputs-file <path>";
    public const string JobRun = "arkdeck job run --job <job-id>";                // job.run

    public static string ForExecution(string template, string executionId) =>
        template.Replace("(--execution-id <id>)", "--execution-id " + executionId, StringComparison.Ordinal);

    public static string ForHumanAction(string template, string actionId) =>
        template.Replace("--human-action <id>", "--human-action " + actionId, StringComparison.Ordinal);

    public static string ForImportId(string template, string importId) =>
        template.Replace("(--import <id> | --import-request-id <id>)", "--import " + importId, StringComparison.Ordinal)
            .Replace("--import <id>", "--import " + importId, StringComparison.Ordinal);

    /// <summary>The CLI command that uploads an Import of <paramref name="kind"/>.</summary>
    public static string ForImport(string kind) => kind switch
    {
        ImportKind.FlashBundle => ImportFlashBundle,
        ImportKind.WorkspacePatch => ImportWorkspacePatch,
        ImportKind.NativeLibrary => ImportNativeLibrary,
        _ => ImportHap,
    };

    public static string ForSession(string template, string sessionId) => template.Replace("<session-id>", sessionId, StringComparison.Ordinal);

    public static string ForProject(string template, string projectRef) => template.Replace("<project-ref>", projectRef, StringComparison.Ordinal);

    public static string ForJob(string template, string jobId) => template.Replace("<job-id>", jobId, StringComparison.Ordinal);

    public static string ForTarget(string template, string targetId) => template.Replace("<target-id>", targetId, StringComparison.Ordinal);

    /// <summary>One Job's Artifacts: the <c>--job</c> form of <see cref="ArtifactList"/>.</summary>
    public static string ArtifactListForJob(string jobId) => $"arkdeck artifact list --job {jobId}";

    /// <summary>One Job Artifact's bytes: the <c>--job</c> form of <see cref="ArtifactRead"/>.</summary>
    public static string ArtifactReadForJob(string jobId, string artifactId) => $"arkdeck artifact read --artifact {artifactId} --job {jobId}";

    public static string TraceInspectFor(string jobId, string artifactId) =>
        TraceInspect.Replace("<job-id>", jobId, StringComparison.Ordinal).Replace("<artifact-id>", artifactId, StringComparison.Ordinal);
}

/// <summary>What one refresh of a surface found. <see cref="DaemonFailure"/> is the first
/// daemon-unavailable failure (the shell's recovery banner); <see cref="Reached"/> is true
/// when at least one call was answered by the daemon (the banner goes away).</summary>
public abstract record SurfaceState(ControlFailure? DaemonFailure, bool Reached);

public sealed record OverviewState(
    Loaded<HealthFacts> Health,
    Loaded<DoctorFacts> Doctor,
    Loaded<IReadOnlyList<JobSummary>> Recent,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached);

public sealed record DeviceState(
    Loaded<IReadOnlyList<DeviceCandidate>> Candidates,
    Loaded<IReadOnlyList<TargetSummary>> Targets,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached);

public sealed record TargetDetailState(string TargetId, Loaded<TargetDetail> Detail, Loaded<TargetAvailability> Availability,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>The answer to one rename or clear of a Target's display name.</summary>
public sealed record DisplayNameState(Loaded<DisplayNameChange> Change, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

public sealed record HistoryState(Loaded<IReadOnlyList<JobSummary>> Jobs, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

public sealed record JobDetailState(string JobId, Loaded<JobSummary> Status, Loaded<IReadOnlyList<JobEvent>> Events,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>The History detail of one Job: its status and its Artifacts.</summary>
public sealed record HistoryDetailState(string JobId, Loaded<JobSummary> Status, Loaded<IReadOnlyList<ArtifactSummary>> Artifacts,
    Loaded<JobEvidenceFacts> Evidence, ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>What <c>trace.inspect</c> answered for one Job's raw Trace.</summary>
public sealed record TraceInspectionState(string JobId, string ArtifactId, Loaded<TraceInspection> Inspection,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>
/// Reads each surface through the channel. The loaders only call methods and keep the
/// answers: no state is derived beyond "which answer came back". Once a call finds the
/// daemon unavailable, the remaining calls of the same refresh are not made (nothing could
/// answer them) and report the same failure.
/// </summary>
public sealed partial class SurfaceLoader(IControlChannel channel)
{
    public const int OverviewRecentCount = 5;
    public const int HistoryPageSize = 100;
    public const int ArtifactPageSize = 1000;
    public const int ArtifactPageLimit = 16;

    /// <summary>The channel the loaders read through (the Artifact export reads through it too).</summary>
    public IControlChannel Channel => channel;

    public async Task<OverviewState> OverviewAsync()
    {
        var run = new Run(channel);
        var health = await run.Load(c => c.HealthAsync(), HealthFacts.Parse, CliCommands.RuntimeHealth);
        var doctor = await run.Load(c => c.RequestAsync("doctor", Params(("deep", JsonBool.False))), DoctorFacts.Parse, CliCommands.Doctor);
        var recent = await run.Load(c => c.RequestAsync("job.list", Params(("pageSize", JsonNumber.FromInt64(OverviewRecentCount)))),
            JobSummary.ParsePage, CliCommands.JobList);
        return new(health, doctor, recent, run.DaemonFailure, run.Reached);
    }

    /// <summary>The Device page: the candidates HDC observes and the Targets adopted before
    /// (the Target store answers without an HDC).</summary>
    public async Task<DeviceState> DeviceAsync()
    {
        var run = new Run(channel);
        var candidates = await run.Load(c => c.RequestAsync("device.observations"), DeviceCandidate.ParseAll, CliCommands.DeviceCandidates);
        var targets = await run.Load(c => c.RequestAsync("target.list"), TargetSummary.ParseAll, CliCommands.TargetList);
        return new(candidates, targets, run.DaemonFailure, run.Reached);
    }

    public async Task<TargetDetailState> TargetAsync(string targetId)
    {
        var run = new Run(channel);
        var id = new JsonString(targetId);
        var detail = await run.Load(c => c.RequestAsync("target.show", Params(("targetId", id))), TargetDetail.Parse,
            CliCommands.ForTarget(CliCommands.TargetShow, targetId));
        var availability = await run.Load(c => c.RequestAsync("target.availability", Params(("targetId", id))), TargetAvailability.Parse,
            CliCommands.ForTarget(CliCommands.TargetAvailability, targetId));
        return new(targetId, detail, availability, run.DaemonFailure, run.Reached);
    }

    /// <summary>Records a Target's display name in the Runtime (<c>target.display-name.set</c>),
    /// guarded by the generation the App last read: a name changed meanwhile is refused
    /// (<c>resourceConflict</c>), never overwritten. <paramref name="name"/> has passed
    /// <see cref="DisplayName.Normalize"/>.</summary>
    public async Task<DisplayNameState> RenameTargetAsync(string targetId, string name, string expectedGeneration)
    {
        var run = new Run(channel);
        var change = await run.Load(c => c.RequestAsync("target.display-name.set", Params(
                ("targetId", new JsonString(targetId)), ("name", new JsonString(name)), ("expectedGeneration", new JsonString(expectedGeneration)))),
            DisplayNameChange.Parse, CliCommands.ForTarget(CliCommands.TargetDisplayNameSet, targetId));
        return new(change, run.DaemonFailure, run.Reached);
    }

    /// <summary>Removes a Target's display name (<c>target.display-name.clear</c>), guarded by
    /// the generation the App last read.</summary>
    public async Task<DisplayNameState> ClearTargetNameAsync(string targetId, string expectedGeneration)
    {
        var run = new Run(channel);
        var change = await run.Load(c => c.RequestAsync("target.display-name.clear", Params(
                ("targetId", new JsonString(targetId)), ("expectedGeneration", new JsonString(expectedGeneration)))),
            DisplayNameChange.Parse, CliCommands.ForTarget(CliCommands.TargetDisplayNameClear, targetId));
        return new(change, run.DaemonFailure, run.Reached);
    }

    public async Task<HistoryState> HistoryAsync()
    {
        var run = new Run(channel);
        var jobs = await run.Load(c => c.RequestAsync("job.list", Params(("pageSize", JsonNumber.FromInt64(HistoryPageSize)))),
            JobSummary.ParsePage, CliCommands.JobList);
        return new(jobs, run.DaemonFailure, run.Reached);
    }

    public async Task<JobDetailState> JobAsync(string jobId)
    {
        var run = new Run(channel);
        var id = new JsonString(jobId);
        var status = await run.Load(c => c.RequestAsync("job.status", Params(("jobId", id))), JobSummary.Parse,
            CliCommands.ForJob(CliCommands.JobStatus, jobId));
        var events = await run.Load(c => c.RequestAsync("job.events", Params(("jobId", id))), JobEvent.ParsePage,
            CliCommands.ForJob(CliCommands.JobEvents, jobId));
        return new(jobId, status, events, run.DaemonFailure, run.Reached);
    }

    /// <summary>The History detail of one Job: <c>job.status</c>, every <c>artifact.list</c>
    /// page of the Job (macOS <c>RuntimeAppReadResources.artifactInventory</c>) and its
    /// <c>job.evidence</c> (the macOS History evidence section).</summary>
    public async Task<HistoryDetailState> HistoryDetailAsync(string jobId)
    {
        var run = new Run(channel);
        var status = await run.Load(c => c.RequestAsync("job.status", Params(("jobId", new JsonString(jobId)))), JobSummary.Parse,
            CliCommands.ForJob(CliCommands.JobStatus, jobId));
        var artifacts = await run.LoadPages(c => ArtifactPagesAsync(c, jobId), CliCommands.ArtifactListForJob(jobId));
        var evidence = await run.Load(c => c.RequestAsync("job.evidence", Params(("jobId", new JsonString(jobId)))), JobEvidenceFacts.Parse,
            CliCommands.ForJob(CliCommands.JobEvidence, jobId));
        return new(jobId, status, artifacts, evidence, run.DaemonFailure, run.Reached);
    }

    /// <summary>Asks the Runtime's Trace inspector about a Job's raw Trace (<c>trace.inspect</c>):
    /// the Runtime reads the Trace, the App shows the answer.</summary>
    public async Task<TraceInspectionState> InspectTraceAsync(string jobId, ArtifactSummary trace)
    {
        var run = new Run(channel);
        var inspection = await run.Load(c => c.RequestAsync("trace.inspect", Params(
                ("owner", JobOwner(jobId)), ("artifactId", new JsonString(trace.ArtifactId)), ("allowSensitive", JsonBool.Of(trace.IsSensitive)))),
            TraceInspection.Parse, CliCommands.TraceInspectFor(jobId, trace.ArtifactId));
        return new(jobId, trace.ArtifactId, inspection, run.DaemonFailure, run.Reached);
    }

    /// <summary>Every <c>artifact.list</c> page of one Job, each checked
    /// (<see cref="ArtifactSummary.ParsePage"/>) before its cursor is followed: the rows, or the
    /// first failure. A repeated cursor or more than <see cref="ArtifactPageLimit"/> pages is a
    /// <see cref="ContractException"/> (the result is unreadable).</summary>
    private static async Task<(IReadOnlyList<ArtifactSummary>? Items, ControlFailure? Failure)> ArtifactPagesAsync(IControlChannel c, string jobId)
    {
        var items = new List<ArtifactSummary>();
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null;
        for (var page = 0; page < ArtifactPageLimit; page++)
        {
            var parameters = cursor is null
                ? Params(("owner", JobOwner(jobId)), ("pageSize", JsonNumber.FromInt64(ArtifactPageSize)))
                : Params(("owner", JobOwner(jobId)), ("pageSize", JsonNumber.FromInt64(ArtifactPageSize)), ("cursor", new JsonString(cursor)));
            var result = await c.RequestAsync("artifact.list", parameters).ConfigureAwait(false);
            if (result.Failure is { } failure) return (null, failure);
            var (rows, next) = ArtifactSummary.ParsePage(result.Value!, jobId);
            items.AddRange(rows);
            if (next is null) return (items, null);
            if (!cursors.Add(next)) throw new ContractException(ContractErrorKind.SchemaMismatch, "artifact.list repeated a cursor");
            cursor = next;
        }
        throw new ContractException(ContractErrorKind.SchemaMismatch, $"artifact.list returned more than {ArtifactPageLimit} pages");
    }

    internal static JsonObject JobOwner(string jobId) => Params(("kind", new JsonString("job")), ("id", new JsonString(jobId)));

    internal static JsonObject Params(params (string Key, JsonValue Value)[] members) =>
        new(members.Select(m => new KeyValuePair<string, JsonValue>(m.Key, m.Value)));

    private sealed class Run(IControlChannel channel)
    {
        public ControlFailure? DaemonFailure { get; private set; }

        public bool Reached { get; private set; }

        public async Task<Loaded<T>> Load<T>(Func<IControlChannel, Task<ControlResult>> call, Func<JsonValue, T> parse, string cli)
            where T : class
        {
            if (DaemonFailure is { } known) return Loaded<T>.Not(Unavailable.From(known, cli));
            return Keep(await Loaded<T>.From(call(channel), parse, cli).ConfigureAwait(false));
        }

        /// <summary>A read of several pages: the rows, the first failure, or an unreadable page.</summary>
        public async Task<Loaded<IReadOnlyList<T>>> LoadPages<T>(
            Func<IControlChannel, Task<(IReadOnlyList<T>? Items, ControlFailure? Failure)>> call, string cli)
        {
            if (DaemonFailure is { } known) return Loaded<IReadOnlyList<T>>.Not(Unavailable.From(known, cli));
            try
            {
                var (items, failure) = await call(channel).ConfigureAwait(false);
                return Keep(failure is null ? Loaded<IReadOnlyList<T>>.Of(items!) : Loaded<IReadOnlyList<T>>.Not(Unavailable.From(failure, cli)));
            }
            catch (Exception error) when (error is InvalidCastException or KeyNotFoundException or FormatException
                                              or ContractException or InvalidOperationException)
            {
                return Keep(Loaded<IReadOnlyList<T>>.Not(Unavailable.Unreadable(error, cli)));
            }
        }

        private Loaded<T> Keep<T>(Loaded<T> loaded) where T : class
        {
            if (loaded.Unavailable is { IsDaemonUnavailable: true } why) DaemonFailure = why.Failure;
            else Reached = true;
            return loaded;
        }
    }
}
