using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>One Session of the Session catalog (<c>session.list|show|pin|unpin</c>). The
/// generation guards a pin or unpin: one the catalog changed meanwhile is refused.</summary>
public sealed record SessionSummary(
    string SessionId,
    string CompletedAtUtc,
    string ExpiresAtUtc,
    string Generation,
    bool Pinned,
    string PolicyGeneration,
    string SizeBytes)
{
    public static SessionSummary Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Session");
        return new(
            TypedJson.Required(o, "sessionId", TypedJson.String),
            TypedJson.Required(o, "completedAtUtc", TypedJson.String),
            TypedJson.Required(o, "expiresAtUtc", TypedJson.String),
            TypedJson.Required(o, "generation", TypedJson.String),
            TypedJson.Required(o, "pinned", TypedJson.Bool),
            TypedJson.Required(o, "policyGeneration", TypedJson.String),
            TypedJson.Required(o, "sizeBytes", TypedJson.String));
    }

    public static (IReadOnlyList<SessionSummary> Items, string? NextCursor) ParsePage(JsonValue value)
    {
        var page = Json.Object(value, "a Session page");
        var more = TypedJson.Required(page, "hasMore", TypedJson.Bool);
        var cursor = Json.NullableString(page, "nextCursor");
        if (more != cursor is not null) throw new ContractException(ContractErrorKind.SchemaMismatch, "a cursor without more rows, or more rows without a cursor");
        return (TypedJson.Required(page, "items", v => TypedJson.List(v, Parse)), cursor);
    }
}

/// <summary>One Session of a cleanup preview: what the Runtime would do with it and why.</summary>
public sealed record CleanupSession(string SessionId, string Disposition, string Reason, string SizeBytes, bool Pinned, bool ActiveLease, int ArtifactCount);

/// <summary><c>session.cleanup.preview</c>: the exact removal a later apply may perform
/// (bound by its id and digest), and what it reclaims.</summary>
public sealed record CleanupPreview(
    string PreviewId,
    string PreviewDigest,
    string CurrentBytes,
    string ProjectedBytes,
    string ReclaimBytes,
    string SafetyTargetBytes,
    string ExpiresAtUtc,
    bool BlocksNewHeavyWriters,
    IReadOnlyList<CleanupSession> Sessions)
{
    public IEnumerable<CleanupSession> Reclaimed => Sessions.Where(s => s.Disposition == "reclaim");

    public static CleanupPreview Parse(JsonValue value)
    {
        var o = Json.Object(value, "a cleanup preview");
        string S(string key) => TypedJson.Required(o, key, TypedJson.String);
        return new(S("previewId"), S("previewDigest"), S("currentBytes"), S("projectedBytes"), S("reclaimBytes"), S("safetyTargetBytes"),
            S("expiresAtUtc"), TypedJson.Required(o, "blocksNewHeavyWriters", TypedJson.Bool),
            TypedJson.Required(o, "sessions", v => TypedJson.List(v, item =>
            {
                var s = Json.Object(item, "a cleanup Session");
                return new CleanupSession(
                    TypedJson.Required(s, "sessionId", TypedJson.String),
                    TypedJson.Required(s, "disposition", TypedJson.String),
                    TypedJson.Required(s, "reason", TypedJson.String),
                    TypedJson.Required(s, "sizeBytes", TypedJson.String),
                    TypedJson.Required(s, "pinned", TypedJson.Bool),
                    TypedJson.Required(s, "activeLease", TypedJson.Bool),
                    TypedJson.Required(s, "artifacts", a => a is JsonArray list ? list.Items.Count : 0));
            })));
    }
}

/// <summary><c>session.cleanup.apply</c>: what was removed.</summary>
public sealed record CleanupResult(string ReclaimedBytes, string RemainingBytes, IReadOnlyList<string> RemovedSessionIds)
{
    public static CleanupResult Parse(JsonValue value)
    {
        var o = Json.Object(value, "a cleanup result");
        return new(
            TypedJson.Required(o, "reclaimedBytes", TypedJson.String),
            TypedJson.Required(o, "remainingBytes", TypedJson.String),
            TypedJson.Required(o, "removedSessionIds", v => TypedJson.List(v, TypedJson.String)));
    }
}

/// <summary>One Artifact of a Session export preview and whether it is written.</summary>
public sealed record ExportArtifact(string ArtifactId, string Role, string Privacy, string Disposition, string Transformation, string ByteCount);

/// <summary><c>session.export.preview</c>: the destination the Runtime proved (absent, on a
/// known volume), what it writes, and the tuple a later apply must name.</summary>
public sealed record SessionExportPreview(
    string PreviewId,
    string PreviewDigest,
    string SessionId,
    string DestinationPath,
    string EstimatedBytes,
    string DeviceIdentifierPolicy,
    bool SensitiveDefaultExcluded,
    string ExpiresAtUtc,
    string? CatalogBlocker,
    IReadOnlyList<ExportArtifact> Artifacts)
{
    public static SessionExportPreview Parse(JsonValue value)
    {
        var o = Json.Object(value, "an export preview");
        var destination = TypedJson.Required(o, "destination", v => Json.Object(v, "destination"));
        var catalog = TypedJson.Required(o, "catalogStatus", v => Json.Object(v, "catalogStatus"));
        string S(string key) => TypedJson.Required(o, key, TypedJson.String);
        return new(S("previewId"), S("previewDigest"), S("sessionId"),
            TypedJson.Required(destination, "path", TypedJson.String),
            S("estimatedBytes"), S("deviceIdentifierPolicy"),
            TypedJson.Required(o, "sensitiveDefaultExcluded", TypedJson.Bool), S("expiresAtUtc"),
            Json.NullableString(catalog, "blocker"),
            TypedJson.Required(o, "artifacts", v => TypedJson.List(v, item =>
            {
                var a = Json.Object(item, "an export Artifact");
                string A(string key) => TypedJson.Required(a, key, TypedJson.String);
                return new ExportArtifact(A("artifactId"), A("role"), A("privacy"), A("disposition"), A("transformation"), A("byteCount"));
            })));
    }
}

/// <summary><c>session.export.apply</c>: where the Runtime wrote the export.</summary>
public sealed record SessionExportResult(string ExportedPath, string PublishedAtUtc, int ExcludedArtifactCount)
{
    public static SessionExportResult Parse(JsonValue value)
    {
        var o = Json.Object(value, "an export result");
        return new(
            TypedJson.Required(o, "exportedPath", TypedJson.String),
            TypedJson.Required(o, "publishedAtUtc", TypedJson.String),
            TypedJson.Required(o, "excludedArtifactIds", v => v is JsonArray a ? a.Items.Count : 0));
    }
}

/// <summary>One Artifact a terminal Job's result names, and whether its bytes were verified.</summary>
public sealed record ResultArtifact(string Name, string Privacy, string ByteCount, bool BytesVerified, string Status);

/// <summary><c>job.result</c> of a terminal Job: the Artifacts the Runtime verified and the
/// cleanup it still owes.</summary>
public sealed record JobResultFacts(bool Terminal, bool OutcomeUnknown, IReadOnlyList<ResultArtifact> Artifacts, int CleanupCount)
{
    public static JobResultFacts Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Job result");
        return new(
            TypedJson.Required(o, "terminal", TypedJson.Bool),
            TypedJson.Required(o, "outcomeUnknown", TypedJson.Bool),
            TypedJson.Required(o, "artifacts", v => TypedJson.List(v, item =>
            {
                var a = Json.Object(item, "a result Artifact");
                return new ResultArtifact(
                    TypedJson.Required(a, "name", TypedJson.String),
                    TypedJson.Required(a, "privacy", TypedJson.String),
                    TypedJson.Required(a, "byteCount", TypedJson.String),
                    TypedJson.Required(a, "bytesVerified", TypedJson.Bool),
                    TypedJson.Required(a, "status", TypedJson.String));
            })),
            TypedJson.Required(o, "cleanup", v => v is JsonArray a ? a.Items.Count : 0));
    }
}

/// <summary><c>job.evidence</c>, the facts the macOS History evidence section shows.</summary>
public sealed record JobEvidenceFacts(
    string Status,
    string ProviderId,
    string CatalogDigest,
    long? BindingRevision,
    string? AuthorityKind,
    string? AuthorityReference,
    string? TerminalState,
    string ExecutionMode,
    string? ActualEffect,
    string? FirstEvidenceStepAtUtc,
    IReadOnlyList<string>? ActualStepKinds,
    IReadOnlyList<string> Blockers,
    IReadOnlyList<string> MissingRequiredArtifacts,
    string? ObservedFirmware = null,
    long? ObservedBindingRevision = null)
{
    public static JobEvidenceFacts Parse(JsonValue value)
    {
        var o = Json.Object(value, "Job evidence");
        var authority = o.TryGetValue("authority", out var a) && a is JsonObject ao ? ao : null;
        var observation = o.TryGetValue("observation", out var ob) && ob is JsonObject oo ? oo : null;
        return new(
            TypedJson.Required(o, "status", TypedJson.String),
            TypedJson.Required(o, "providerId", TypedJson.String),
            TypedJson.Required(o, "catalogDigest", TypedJson.String),
            TypedJson.Required(o, "bindingRevision", v => v is JsonNull ? (long?)null : TypedJson.Int64(v)),
            authority is null ? null : Json.OptionalString(authority, "kind"),
            authority is null ? null : Json.OptionalString(authority, "reference"),
            Json.OptionalString(o, "terminalState"),
            TypedJson.Required(o, "executionMode", TypedJson.String),
            Json.NullableString(o, "actualEffect"),
            Json.NullableString(o, "firstEvidenceStepAtUtc"),
            TypedJson.Required(o, "actualStepKinds", v => v is JsonNull ? null : TypedJson.List(v, TypedJson.String)),
            TypedJson.Required(o, "blockers", v => TypedJson.List(v, TypedJson.String)),
            TypedJson.Required(o, "missingRequiredArtifacts", v => TypedJson.List(v, TypedJson.String)),
            observation is null ? null : Json.OptionalString(observation, "firmware"),
            observation is not null && observation.TryGetValue("bindingRevision", out var observed) && observed is JsonNumber n && n.TryGetInt64(out var revision)
                ? revision : null);
    }
}

public sealed record SessionsState(Loaded<IReadOnlyList<SessionSummary>> Sessions, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

/// <summary>The answer to one Session action (a read, pin, preview or apply).</summary>
public sealed record SessionActionState<T>(Loaded<T> Answer, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached) where T : class;

/// <summary>What <c>job.cancel</c> answered: whether the Runtime accepted the request. A
/// request is not a terminal outcome; the Job's state is read back.</summary>
public sealed record CancelAnswer(bool Requested)
{
    public static CancelAnswer Parse(JsonValue value) =>
        new(TypedJson.Required(Json.Object(value, "a cancellation"), "cancelRequested", TypedJson.Bool));
}

public sealed partial class SurfaceLoader
{
    public const int SessionPageSize = 200;
    public const int SessionPageLimit = 16;

    /// <summary>The Session catalog, every page (<c>session.list</c>).</summary>
    public async Task<SessionsState> SessionsAsync()
    {
        var run = new Run(channel);
        var sessions = await run.LoadPages(async c =>
        {
            var items = new List<SessionSummary>();
            var cursors = new HashSet<string>(StringComparer.Ordinal);
            string? cursor = null;
            for (var page = 0; page < SessionPageLimit; page++)
            {
                var parameters = cursor is null
                    ? Params(("pageSize", JsonNumber.FromInt64(SessionPageSize)))
                    : Params(("pageSize", JsonNumber.FromInt64(SessionPageSize)), ("cursor", new JsonString(cursor)));
                var result = await c.RequestAsync("session.list", parameters).ConfigureAwait(false);
                if (result.Failure is { } failure) return ((IReadOnlyList<SessionSummary>?)null, failure);
                var (rows, next) = SessionSummary.ParsePage(result.Value!);
                items.AddRange(rows);
                if (next is null) return (items, null);
                if (!cursors.Add(next)) throw new ContractException(ContractErrorKind.SchemaMismatch, "session.list repeated a cursor");
                cursor = next;
            }
            throw new ContractException(ContractErrorKind.SchemaMismatch, $"session.list returned more than {SessionPageLimit} pages");
        }, CliCommands.SessionList);
        return new(sessions, run.DaemonFailure, run.Reached);
    }

    public Task<SessionActionState<SessionSummary>> SessionAsync(string sessionId) =>
        Action("session.show", Params(("sessionId", new JsonString(sessionId))), SessionSummary.Parse, CliCommands.ForSession(CliCommands.SessionShow, sessionId));

    /// <summary>Pins or unpins a Session (<c>session.pin|unpin</c>), guarded by the generation
    /// the App read.</summary>
    public Task<SessionActionState<SessionSummary>> PinSessionAsync(SessionSummary session, bool pin) =>
        Action(pin ? "session.pin" : "session.unpin",
            Params(("sessionId", new JsonString(session.SessionId)), ("expectedGeneration", new JsonString(session.Generation))),
            SessionSummary.Parse, CliCommands.ForSession(pin ? CliCommands.SessionPin : CliCommands.SessionUnpin, session.SessionId));

    public Task<SessionActionState<CleanupPreview>> CleanupPreviewAsync() =>
        Action("session.cleanup.preview", null, CleanupPreview.Parse, CliCommands.SessionCleanupPreview);

    /// <summary>Applies exactly the cleanup the person reviewed: the preview's id and digest.</summary>
    public Task<SessionActionState<CleanupResult>> CleanupApplyAsync(CleanupPreview preview) =>
        Action("session.cleanup.apply",
            Params(("previewId", new JsonString(preview.PreviewId)), ("previewDigest", new JsonString(preview.PreviewDigest))),
            CleanupResult.Parse, CliCommands.SessionCleanupApply);

    /// <summary>Asks the Runtime to prove a new export destination (a directory that must not
    /// exist yet) and list what it would write; sensitive Artifacts stay excluded.</summary>
    public Task<SessionActionState<SessionExportPreview>> ExportPreviewAsync(string sessionId, string destinationPath) =>
        Action("session.export.preview",
            Params(("sessionId", new JsonString(sessionId)), ("destinationPath", new JsonString(destinationPath)), ("allowSensitive", JsonBool.False)),
            SessionExportPreview.Parse, CliCommands.ForSession(CliCommands.SessionExportPreview, sessionId));

    /// <summary>Has the Runtime write exactly the export the person reviewed.</summary>
    public Task<SessionActionState<SessionExportResult>> ExportApplyAsync(SessionExportPreview preview) =>
        Action("session.export.apply",
            Params(("previewId", new JsonString(preview.PreviewId)), ("previewDigest", new JsonString(preview.PreviewDigest))),
            SessionExportResult.Parse, CliCommands.SessionExportApply);

    /// <summary>Requests cancellation of a queued or active Job (<c>job.cancel</c>).</summary>
    public Task<SessionActionState<CancelAnswer>> CancelJobAsync(string jobId) =>
        Action("job.cancel", Params(("jobId", new JsonString(jobId))), CancelAnswer.Parse, CliCommands.ForJob(CliCommands.JobCancel, jobId));

    public Task<SessionActionState<JobResultFacts>> JobResultAsync(string jobId) =>
        Action("job.result", Params(("jobId", new JsonString(jobId))), JobResultFacts.Parse, CliCommands.ForJob(CliCommands.JobResult, jobId));

    public Task<SessionActionState<JobEvidenceFacts>> JobEvidenceAsync(string jobId) =>
        Action("job.evidence", Params(("jobId", new JsonString(jobId))), JobEvidenceFacts.Parse, CliCommands.ForJob(CliCommands.JobEvidence, jobId));

    private async Task<SessionActionState<T>> Action<T>(string method, JsonObject? parameters, Func<JsonValue, T> parse, string cli) where T : class
    {
        var run = new Run(channel);
        var answer = await run.Load(c => c.RequestAsync(method, parameters), parse, cli);
        return new(answer, run.DaemonFailure, run.Reached);
    }
}
