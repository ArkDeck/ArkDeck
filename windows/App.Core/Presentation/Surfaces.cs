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
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>What <c>trace.inspect</c> answered for one Job's raw Trace.</summary>
public sealed record TraceInspectionState(string JobId, string ArtifactId, Loaded<TraceInspection> Inspection,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>
/// Reads each surface through the channel. The loaders only call methods and keep the
/// answers: no state is derived beyond "which answer came back". Once a call finds the
/// daemon unavailable, the remaining calls of the same refresh are not made (nothing could
/// answer them) and report the same failure.
/// </summary>
public sealed class SurfaceLoader(IControlChannel channel)
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

    /// <summary>The History detail of one Job: <c>job.status</c> and every <c>artifact.list</c>
    /// page of the Job (macOS <c>RuntimeAppReadResources.artifactInventory</c>).</summary>
    public async Task<HistoryDetailState> HistoryDetailAsync(string jobId)
    {
        var run = new Run(channel);
        var status = await run.Load(c => c.RequestAsync("job.status", Params(("jobId", new JsonString(jobId)))), JobSummary.Parse,
            CliCommands.ForJob(CliCommands.JobStatus, jobId));
        var artifacts = await run.LoadPages(c => ArtifactPagesAsync(c, jobId), CliCommands.ArtifactListForJob(jobId));
        return new(jobId, status, artifacts, run.DaemonFailure, run.Reached);
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
