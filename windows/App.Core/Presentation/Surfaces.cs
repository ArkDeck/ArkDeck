using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
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

    public static string ForJob(string template, string jobId) => template.Replace("<job-id>", jobId, StringComparison.Ordinal);
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

public sealed record DeviceState(Loaded<IReadOnlyList<DeviceCandidate>> Candidates, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

public sealed record HistoryState(Loaded<IReadOnlyList<JobSummary>> Jobs, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

public sealed record JobDetailState(string JobId, Loaded<JobSummary> Status, Loaded<IReadOnlyList<JobEvent>> Events,
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

    public async Task<OverviewState> OverviewAsync()
    {
        var run = new Run(channel);
        var health = await run.Load(c => c.HealthAsync(), HealthFacts.Parse, CliCommands.RuntimeHealth);
        var doctor = await run.Load(c => c.RequestAsync("doctor", Params(("deep", JsonBool.False))), DoctorFacts.Parse, CliCommands.Doctor);
        var recent = await run.Load(c => c.RequestAsync("job.list", Params(("pageSize", JsonNumber.FromInt64(OverviewRecentCount)))),
            JobSummary.ParsePage, CliCommands.JobList);
        return new(health, doctor, recent, run.DaemonFailure, run.Reached);
    }

    public async Task<DeviceState> DeviceAsync()
    {
        var run = new Run(channel);
        var candidates = await run.Load(c => c.RequestAsync("device.observations"), DeviceCandidate.ParseAll, CliCommands.DeviceCandidates);
        return new(candidates, run.DaemonFailure, run.Reached);
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

    private static JsonObject Params(params (string Key, JsonValue Value)[] members) =>
        new(members.Select(m => new KeyValuePair<string, JsonValue>(m.Key, m.Value)));

    private sealed class Run(IControlChannel channel)
    {
        public ControlFailure? DaemonFailure { get; private set; }

        public bool Reached { get; private set; }

        public async Task<Loaded<T>> Load<T>(Func<IControlChannel, Task<ControlResult>> call, Func<JsonValue, T> parse, string cli)
            where T : class
        {
            if (DaemonFailure is { } known) return Loaded<T>.Not(Unavailable.From(known, cli));
            var loaded = await Loaded<T>.From(call(channel), parse, cli).ConfigureAwait(false);
            if (loaded.Unavailable is { IsDaemonUnavailable: true } why) DaemonFailure = why.Failure;
            else Reached = true;
            return loaded;
        }
    }
}
