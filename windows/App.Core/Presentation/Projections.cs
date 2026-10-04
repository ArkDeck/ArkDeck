using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>The <c>health</c> facts the Overview shows.</summary>
public sealed record HealthFacts(string Status, string ProtocolVersion, string ContractIdentity, int PublishedMethodCount)
{
    public static HealthFacts Parse(JsonValue value)
    {
        var h = TypedMethods.ParseHealthResult(value);
        return new(h.Status, h.ProtocolVersion, h.ContractIdentity, h.PublishedMethods.Count);
    }
}

public sealed record DoctorFinding(string Code, string Severity, string Scope, string Summary);

/// <summary>The <c>doctor</c> report as the daemon states it (overall, counts, findings).</summary>
public sealed record DoctorFacts(
    string Overall,
    bool Ready,
    long Blockers,
    long Warnings,
    long Info,
    IReadOnlyList<DoctorFinding> Findings,
    string RuntimeProtocolVersion,
    long AvailableOperationCount,
    long OperationCount)
{
    public static DoctorFacts Parse(JsonValue value)
    {
        var d = TypedMethods.ParseDoctorResult(value);
        return new(d.Overall, d.Ready, d.FindingCounts.Blocker, d.FindingCounts.Warning, d.FindingCounts.Info,
            d.Findings.Select(f => new DoctorFinding(f.Code, f.Severity, f.Scope, f.Summary)).ToArray(),
            d.Checks.Runtime.ProtocolVersion, d.Checks.Catalog.AvailableOperationCount, d.Checks.Catalog.OperationCount);
    }
}

/// <summary>One <c>device.observations</c> candidate.</summary>
public sealed record DeviceCandidate(
    string CandidateKey,
    string AuthorizationState,
    bool Stale,
    string? DisplayName,
    string? AdoptedTargetId,
    long? BindingRevision,
    string? DeviceName,
    string? SystemVersion,
    string? Transport)
{
    /// <summary>The candidate's state as the macOS Device sidebar names it
    /// (<c>DeviceWorkspace.swift</c>): the catalogue key, or null for a state it has no name
    /// for (then the raw state is shown, as on macOS).</summary>
    public string? StateKey => Stale ? Strings.UiStrings.DeviceStateNeedsRecheck : AuthorizationState switch
    {
        "Connected" => AdoptedTargetId is null ? Strings.UiStrings.DeviceStateAuthorizedUnadopted : Strings.UiStrings.DeviceStateReady,
        "Unauthorized" => Strings.UiStrings.DeviceStateNeedsTrust,
        "Offline" => Strings.UiStrings.DeviceStateOffline,
        _ => null,
    };

    public string Title => DisplayName ?? DeviceName ?? CandidateKey;

    public static IReadOnlyList<DeviceCandidate> ParseAll(JsonValue value)
    {
        var r = TypedMethods.ParseDeviceObservationsResult(value);
        var stale = r.Health != "current";
        return r.Observations.Select(o => new DeviceCandidate(o.CandidateKey, o.AuthorizationState, stale, o.DisplayName,
            o.AdoptedTargetId, o.BindingRevision, o.DeviceInformation?.Name, o.DeviceInformation?.SystemVersion,
            o.DeviceInformation?.Transport)).ToArray();
    }
}

/// <summary>One Job as <c>job.list</c> and <c>job.status</c> project it (the members every
/// surface here shows; the method schemas validate the rest).</summary>
public sealed record JobSummary(
    string JobId,
    string Operation,
    string TargetId,
    string State,
    bool OutcomeUnknown,
    bool WaitingForHuman,
    string ExecutionMode,
    string CreatedAtUtc,
    string? FinishedAtUtc,
    string? SessionId = null,
    string? WorkspaceKind = null)
{
    /// <summary>The terminal Job states (spec/recovery/job-state-preflight.json, class
    /// "terminal"); every other state counts as active, as the macOS Job Inspector counts.</summary>
    public static readonly IReadOnlySet<string> TerminalStates =
        new HashSet<string>(StringComparer.Ordinal) { "planned", "succeeded", "failed", "cancelled", "interrupted", "recovered" };

    public bool IsActive => !TerminalStates.Contains(State);

    public static JobSummary Parse(JsonValue value)
    {
        if (value is not JsonObject o) throw new ContractException(ContractErrorKind.SchemaMismatch, "a Job is not an object");
        return new(
            TypedJson.Required(o, "jobId", TypedJson.String),
            TypedJson.Required(o, "operation", TypedJson.String),
            TypedJson.Required(o, "targetId", TypedJson.String),
            TypedJson.Required(o, "state", TypedJson.String),
            TypedJson.Required(o, "outcomeUnknown", TypedJson.Bool),
            TypedJson.Required(o, "waitingForHuman", TypedJson.Bool),
            TypedJson.Required(o, "executionMode", TypedJson.String),
            TypedJson.Required(o, "createdAtUtc", TypedJson.String),
            o.TryGetValue("finishedAtUtc", out var finished) && finished is JsonString f ? f.Value : null,
            o.TryGetValue("sessionId", out var session) && session is JsonString sid ? sid.Value : null,
            o.TryGetValue("workspaceKind", out var kind) && kind is JsonString k ? k.Value : null);
    }

    public static IReadOnlyList<JobSummary> ParsePage(JsonValue value)
    {
        if (value is not JsonObject page) throw new ContractException(ContractErrorKind.SchemaMismatch, "a Job page is not an object");
        return TypedJson.Required(page, "items", v => TypedJson.List(v, Parse));
    }
}

/// <summary>One <c>job.events</c> item.</summary>
public sealed record JobEvent(string EventId, string Type, string Timestamp, string? FromState, string? ToState, string JournalKind)
{
    public static IReadOnlyList<JobEvent> ParsePage(JsonValue value)
    {
        if (value is not JsonObject page) throw new ContractException(ContractErrorKind.SchemaMismatch, "an event page is not an object");
        return TypedJson.Required(page, "items", v => TypedJson.List(v, item =>
        {
            var o = (JsonObject)item;
            var data = (JsonObject)o["data"];
            return new JobEvent(
                TypedJson.Required(o, "eventId", TypedJson.String),
                TypedJson.Required(o, "type", TypedJson.String),
                TypedJson.Required(data, "timestamp", TypedJson.String),
                data.TryGetValue("fromState", out var from) && from is JsonString fs ? fs.Value : null,
                data.TryGetValue("toState", out var to) && to is JsonString ts ? ts.Value : null,
                TypedJson.Required(data, "journalKind", TypedJson.String));
        }));
    }
}
