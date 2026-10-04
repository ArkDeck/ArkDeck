using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>macOS <c>HistoryActivityFilter</c>: the workspace a record belongs to, or other.</summary>
public enum HistoryActivity
{
    All,
    Flash,
    Viewer,
    Trace,
    Diagnostics,
    Debug,
    Device,
    Other,
}

/// <summary>macOS <c>HistoryStatusFilter</c>.</summary>
public enum HistoryStatus
{
    All,
    Active,
    NeedsAttention,
    Succeeded,
    Failed,
    Interrupted,
    Cancelled,
}

/// <summary>macOS <c>HistoryModeFilter</c>.</summary>
public enum HistoryMode
{
    All,
    Execute,
    Planned,
    Simulated,
    Unknown,
}

/// <summary>macOS <c>HistoryTimeFilter</c>.</summary>
public enum HistoryTime
{
    AnyTime,
    LastHour,
    LastDay,
    LastWeek,
}

/// <summary>
/// The History list's filters (macOS <c>RuntimeHistoryView.matchesFilters</c> and
/// <c>RuntimeHistoryFilterQuery</c>): activity, a search over the Job, Session, operation, Target,
/// state and mode, status, mode, Session, Target and time. The wire names are the Runtime's
/// saved-filter names (<c>history.filter.*</c>).
/// </summary>
public sealed record HistoryFilterQuery(
    string Search = "",
    HistoryStatus Status = HistoryStatus.All,
    HistoryMode Mode = HistoryMode.All,
    string? SessionId = null,
    string? TargetId = null,
    HistoryTime Time = HistoryTime.AnyTime,
    HistoryActivity Activity = HistoryActivity.All)
{
    public static readonly HistoryFilterQuery None = new();

    public static string Name<T>(T value) where T : struct, Enum
    {
        var name = value.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    public static T Parse<T>(string? name, T fallback) where T : struct, Enum =>
        name is { Length: > 0 } && Enum.TryParse<T>(char.ToUpperInvariant(name[0]) + name[1..], out var value) && Name(value) == name ? value : fallback;

    public static TimeSpan? Interval(HistoryTime time) => time switch
    {
        HistoryTime.LastHour => TimeSpan.FromHours(1),
        HistoryTime.LastDay => TimeSpan.FromDays(1),
        HistoryTime.LastWeek => TimeSpan.FromDays(7),
        _ => null,
    };

    /// <summary>The record's activity (macOS: the Runtime's <c>workspaceKind</c>, else the
    /// operation whose reference alone names one; other otherwise).</summary>
    public static HistoryActivity ActivityOf(JobSummary job) =>
        (HistoryWorkspaceContext.Parse(job.WorkspaceKind) ?? HistoryWorkspaceContext.UnambiguousKind(job.Operation)) switch
        {
            WorkspaceKind.Flash => HistoryActivity.Flash,
            WorkspaceKind.Viewer => HistoryActivity.Viewer,
            WorkspaceKind.Trace => HistoryActivity.Trace,
            WorkspaceKind.Diagnostics => HistoryActivity.Diagnostics,
            WorkspaceKind.Debug => HistoryActivity.Debug,
            WorkspaceKind.Device => HistoryActivity.Device,
            _ => HistoryActivity.Other,
        };

    /// <summary>The record's date: finished, else started, else created (macOS <c>activityDate</c>).</summary>
    public static DateTimeOffset? DateOf(JobSummary job) =>
        DateTimeOffset.TryParse(job.FinishedAtUtc ?? job.CreatedAtUtc, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var at) ? at : null;

    public bool Matches(JobSummary job, DateTimeOffset now)
    {
        if (Activity != HistoryActivity.All && Activity != ActivityOf(job)) return false;
        var query = Search.Trim();
        if (query.Length > 0 && !new[] { job.JobId, job.SessionId ?? "", job.Operation, job.TargetId, job.State, job.ExecutionMode }
                .Any(v => v.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
        {
            return false;
        }
        var matchesStatus = Status switch
        {
            HistoryStatus.Active => job.IsActive,
            HistoryStatus.NeedsAttention => (!JobRecovery.HasEstablishedCurrentEpoch(job) && (job.OutcomeUnknown || job.WaitingForHuman)) || job.OutstandingResidueCount > 0,
            HistoryStatus.Succeeded => job.State == "succeeded",
            HistoryStatus.Failed => job.State == "failed",
            HistoryStatus.Interrupted => job.State == "interrupted",
            HistoryStatus.Cancelled => job.State == "cancelled",
            _ => true,
        };
        if (!matchesStatus) return false;
        var matchesMode = Mode switch
        {
            HistoryMode.Execute => job.ExecutionMode == "execute",
            HistoryMode.Planned => job.ExecutionMode is "planOnly" or "planned",
            HistoryMode.Simulated => job.ExecutionMode == "simulated",
            HistoryMode.Unknown => job.ExecutionMode.Length == 0,
            _ => true,
        };
        if (!matchesMode) return false;
        if (SessionId is not null && job.SessionId != SessionId) return false;
        if (TargetId is not null && job.TargetId != TargetId) return false;
        if (Interval(Time) is { } interval && (DateOf(job) is not { } at || at < now - interval || at > now)) return false;
        return true;
    }

    /// <summary>Newest first, then by Job descending (macOS <c>makeFilteredJobs</c>).</summary>
    public IReadOnlyList<JobSummary> Apply(IEnumerable<JobSummary> jobs, DateTimeOffset now) =>
        jobs.Where(j => Matches(j, now))
            .OrderByDescending(j => DateOf(j) ?? DateTimeOffset.MinValue).ThenByDescending(j => j.JobId, StringComparer.Ordinal)
            .ToArray();

    public JsonObject ToWire(string expectedGeneration) => new(
    [
        new("activity", new JsonString(Name(Activity))),
        new("expectedGeneration", new JsonString(expectedGeneration)),
        new("mode", new JsonString(Name(Mode))),
        new("search", new JsonString(Search)),
        new("sessionId", SessionId is null ? JsonNull.Instance : new JsonString(SessionId)),
        new("status", new JsonString(Name(Status))),
        new("targetId", TargetId is null ? JsonNull.Instance : new JsonString(TargetId)),
        new("timeRange", new JsonString(Name(Time))),
    ]);

    public static HistoryFilterQuery FromWire(JsonObject q) => new(
        TypedJson.Required(q, "search", TypedJson.String),
        Parse(TypedJson.Required(q, "status", TypedJson.String), HistoryStatus.All),
        Parse(TypedJson.Required(q, "mode", TypedJson.String), HistoryMode.All),
        q.TryGetValue("sessionId", out var s) && s is JsonString session ? session.Value : null,
        q.TryGetValue("targetId", out var t) && t is JsonString target ? target.Value : null,
        Parse(TypedJson.Required(q, "timeRange", TypedJson.String), HistoryTime.AnyTime),
        Parse(TypedJson.Required(q, "activity", TypedJson.String), HistoryActivity.All));
}

/// <summary>The Runtime's one saved History filter (macOS <c>RuntimeHistoryFilterResource</c>):
/// its generation, the query or none, and when it changed.</summary>
public sealed record SavedHistoryFilter(ulong Generation, HistoryFilterQuery? Query, string? UpdatedAtUtc)
{
    /// <summary>macOS <c>RuntimeHistoryFilterResponseDecoding.list</c>: generation 1 has no update
    /// time, a later one has; at most one filter, of the same generation and time.</summary>
    public static SavedHistoryFilter ParseList(JsonValue value)
    {
        var o = Json.Object(value, "the saved History filter list");
        if (o.Members.Select(m => m.Key).OrderBy(k => k, StringComparer.Ordinal).SequenceEqual(new[] { "filters", "generation", "schemaVersion", "updatedAtUtc" }) is false
            || TypedJson.Required(o, "schemaVersion", TypedJson.String) != "arkdeck.history-filter-list/1")
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "an invalid History filter list");
        }
        var generation = GenerationOf(o);
        var updated = o["updatedAtUtc"] is JsonString u ? u.Value : null;
        if ((generation == 1) != (updated is null)) throw new ContractException(ContractErrorKind.SchemaMismatch, "an impossible History filter generation");
        var filters = TypedJson.Required(o, "filters", v => TypedJson.List(v, item => ParseResource(item)));
        if (filters.Count > 1) throw new ContractException(ContractErrorKind.SchemaMismatch, "more than one saved History filter");
        if (filters is [var row])
        {
            if (row.Generation != generation || row.UpdatedAtUtc != updated || row.Query is null)
            {
                throw new ContractException(ContractErrorKind.SchemaMismatch, "a drifting History filter list");
            }
            return row;
        }
        return new(generation, null, updated);
    }

    public static SavedHistoryFilter ParseResource(JsonValue value)
    {
        var o = Json.Object(value, "a saved History filter");
        if (TypedJson.Required(o, "schemaVersion", TypedJson.String) != "arkdeck.history-filter/1")
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "a History filter of another schema");
        }
        var query = o.TryGetValue("query", out var q) && q is JsonObject wire ? HistoryFilterQuery.FromWire(wire) : null;
        return new(GenerationOf(o), query, o.TryGetValue("updatedAtUtc", out var u) && u is JsonString s ? s.Value : null);
    }

    private static ulong GenerationOf(JsonObject o)
    {
        var text = TypedJson.Required(o, "generation", TypedJson.String);
        return ulong.TryParse(text, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var g) && g >= 1 && g.ToString(System.Globalization.CultureInfo.InvariantCulture) == text
            ? g
            : throw new ContractException(ContractErrorKind.SchemaMismatch, "a non-canonical History filter generation");
    }
}

public sealed partial class SurfaceLoader
{
    /// <summary>The Runtime's saved History filter (<c>history.filter.list</c>).</summary>
    public Task<SessionActionState<SavedHistoryFilter>> SavedHistoryFilterAsync() =>
        HistoryFilterAction("history.filter.list", null, SavedHistoryFilter.ParseList);

    /// <summary>Saves the filter, generation-guarded (<c>history.filter.save</c>).</summary>
    public Task<SessionActionState<SavedHistoryFilter>> SaveHistoryFilterAsync(HistoryFilterQuery query, ulong expectedGeneration) =>
        HistoryFilterAction("history.filter.save", query.ToWire(expectedGeneration.ToString(System.Globalization.CultureInfo.InvariantCulture)), SavedHistoryFilter.ParseResource);

    /// <summary>Deletes the saved filter, generation-guarded (<c>history.filter.delete</c>).</summary>
    public Task<SessionActionState<SavedHistoryFilter>> DeleteHistoryFilterAsync(ulong expectedGeneration) =>
        HistoryFilterAction("history.filter.delete", Params(("expectedGeneration", new JsonString(expectedGeneration.ToString(System.Globalization.CultureInfo.InvariantCulture)))),
            SavedHistoryFilter.ParseResource);

    private async Task<SessionActionState<SavedHistoryFilter>> HistoryFilterAction(string method, JsonObject? parameters, Func<JsonValue, SavedHistoryFilter> parse)
    {
        var run = new Run(channel);
        var answer = await run.Load(c => c.RequestAsync(method, parameters), parse, "arkdeck history filter " + method.Split('.')[^1]).ConfigureAwait(false);
        return new(answer, run.DaemonFailure, run.Reached);
    }

    /// <summary>The next <c>job.list</c> page after <paramref name="cursor"/> (macOS Load Older).</summary>
    public Task<HistoryState> OlderHistoryAsync(string cursor) => HistoryPageAsync(cursor);

    private async Task<HistoryState> HistoryPageAsync(string? cursor)
    {
        var run = new Run(channel);
        var parameters = cursor is null
            ? Params(("pageSize", JsonNumber.FromInt64(HistoryPageSize)))
            : Params(("pageSize", JsonNumber.FromInt64(HistoryPageSize)), ("cursor", new JsonString(cursor)));
        var page = await run.Load(c => c.RequestAsync("job.list", parameters), JobPageFacts.Parse, CliCommands.JobList).ConfigureAwait(false);
        var jobs = page.Value is { } facts ? Loaded<IReadOnlyList<JobSummary>>.Of(facts.Items) : Loaded<IReadOnlyList<JobSummary>>.Not(page.Unavailable!);
        return new(jobs, run.DaemonFailure, run.Reached, page.Value?.NextCursor);
    }
}

/// <summary>One <c>job.list</c> page: its Jobs and the cursor of the next, if any.</summary>
public sealed record JobPageFacts(IReadOnlyList<JobSummary> Items, string? NextCursor)
{
    public static JobPageFacts Parse(JsonValue value)
    {
        var page = Json.Object(value, "a Job page");
        var items = JobSummary.ParsePage(value);
        var next = page.TryGetValue("nextCursor", out var c) && c is JsonString cursor ? cursor.Value : null;
        var more = page.TryGetValue("hasMore", out var h) && h is JsonBool { Value: true };
        if (more != (next is not null)) throw new ContractException(ContractErrorKind.SchemaMismatch, "job.list hasMore and nextCursor disagree");
        return new(items, next);
    }
}
