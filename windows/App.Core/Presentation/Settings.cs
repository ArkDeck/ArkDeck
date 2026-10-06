using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>What <c>health</c> and <c>doctor</c> say about the Runtime itself (the Settings
/// Runtime tab): identity, protocol and each check as the daemon reports it.</summary>
public sealed record RuntimeFacts(
    string Status,
    string ProtocolVersion,
    string ContractIdentity,
    string CatalogDigest,
    int PublishedMethodCount,
    IReadOnlyList<string> Providers)
{
    public static RuntimeFacts Parse(JsonValue value)
    {
        var h = TypedMethods.ParseHealthResult(value);
        return new(h.Status, h.ProtocolVersion, h.ContractIdentity, h.CatalogDigest, h.PublishedMethods.Count, h.Providers);
    }
}

/// <summary>The <c>doctor</c> checks, one line each, as the daemon states them.</summary>
public sealed record RuntimeChecks(
    string Overall,
    long AvailableOperations,
    long Operations,
    string HdcAvailability,
    string HdcReasonCode,
    bool HdcConfigured,
    string HdcOwnership,
    string HdcServerHealth,
    IReadOnlyList<string> RegisteredProviders,
    bool TargetConfigured,
    long? AdoptedTargetCount,
    bool RecoveryChecked,
    long? OutstandingCleanupCount,
    string SessionOutputAvailability,
    string SessionOutputReasonCode,
    bool RuntimeArtifactsConfigured)
{
    public static RuntimeChecks Parse(JsonValue value)
    {
        var d = TypedMethods.ParseDoctorResult(value);
        var c = d.Checks;
        return new(d.Overall, c.Catalog.AvailableOperationCount, c.Catalog.OperationCount,
            c.Hdc.Availability, c.Hdc.ReasonCode, c.Hdc.Configured, c.Hdc.Ownership, c.Hdc.ServerHealth,
            c.Providers.Registered, c.Target.Configured, c.Target.AdoptedTargetCount,
            c.Recovery.Checked, c.Recovery.OutstandingCleanupCount,
            c.Storage.SessionOutput.Availability, c.Storage.SessionOutput.ReasonCode, c.Storage.RuntimeArtifacts.Configured);
    }
}

/// <summary><c>runtime.hdc.status</c>: the selected HDC and its server, as the Runtime measured them.</summary>
public sealed record HdcStatus(
    string Availability,
    string ReasonCode,
    string ServerHealth,
    string Ownership,
    string? ExecutablePath,
    string? ExecutableSha256,
    string? ExecutableSource,
    string? ClientVersion,
    string? DaemonVersion,
    string? Endpoint)
{
    public static HdcStatus Parse(JsonValue value)
    {
        var o = Json.Object(value, "an HDC status");
        return new(
            TypedJson.Required(o, "availability", TypedJson.String),
            TypedJson.Required(o, "reasonCode", TypedJson.String),
            TypedJson.Required(o, "serverHealth", TypedJson.String),
            TypedJson.Required(o, "ownership", TypedJson.String),
            Json.NullableString(o, "executablePath"),
            Json.NullableString(o, "executableSHA256"),
            Json.NullableString(o, "executableSource"),
            Json.NullableString(o, "clientVersion"),
            Json.NullableString(o, "daemonVersion"),
            Json.NullableString(o, "endpoint"));
    }
}

/// <summary>One registered tool of <c>runtime.tool.list</c>.</summary>
public sealed record ToolSummary(string ToolRef, string Kind, string State, string Platform, string Selected)
{
    public static IReadOnlyList<ToolSummary> ParsePage(JsonValue value)
    {
        var page = Json.Object(value, "a tool page");
        return TypedJson.Required(page, "items", v => TypedJson.List(v, item =>
        {
            var o = Json.Object(item, "a tool");
            return new ToolSummary(
                TypedJson.Required(o, "toolRef", TypedJson.String),
                TypedJson.Required(o, "kind", TypedJson.String),
                TypedJson.Required(o, "state", TypedJson.String),
                TypedJson.Required(o, "platform", TypedJson.String),
                TypedJson.Required(o, "selected", v => TypedJson.Bool(v) ? "true" : "false"));
        }));
    }
}

/// <summary>One complete published Bootstrap Bundle projection, for display only.</summary>
public sealed record RuntimeBundle(string BundleRef, string Kind, string Platform, string Version, string State,
    string ContentDigest, string ByteCount, string EntryCount, string Generation, string RegisteredAtUtc,
    bool ContentRetained, RuntimeBundleTrust Trust, IReadOnlyList<RuntimeBundleReference> References)
{
    private static readonly string[] Keys = ["schemaVersion", "bundleRef", "kind", "platform", "version", "state",
        "contentDigest", "digestAlgorithm", "contentSchemaVersion", "byteCount", "entryCount", "generation",
        "registeredAtUTC", "contentRetained", "trust", "references"];

    public static RuntimeBundle Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Runtime Bundle");
        string Text(string key) => TypedJson.Required(o, key, TypedJson.String);
        if (!o.Members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal).SetEquals(Keys)
            || Text("schemaVersion") != "arkdeck.runtime-bundle/1" || Text("contentSchemaVersion") != "arkdeck.bundle-content/1"
            || Text("digestAlgorithm") != "sha256-jcs") throw Invalid();
        var digest = Text("contentDigest");
        if (digest.Length != 64 || digest.Any(c => c is not (>= '0' and <= '9') and not (>= 'a' and <= 'f'))
            || Text("bundleRef") != "bundle:sha256:" + digest) throw Invalid();
        string Count(string key)
        {
            var text = Text(key);
            if (!ulong.TryParse(text, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var count)
                || count.ToString(System.Globalization.CultureInfo.InvariantCulture) != text) throw Invalid();
            return text;
        }
        var trust = Json.Object(o["trust"], "Runtime Bundle trust");
        if (!trust.Members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal)
            .SetEquals(["policy", "signature", "teamIdentifier", "executionAssessment"])) throw Invalid();
        string T(string key) => TypedJson.Required(trust, key, TypedJson.String);
        var references = TypedJson.Required(o, "references", v => TypedJson.List(v, row =>
        {
            var owner = Json.Object(row, "a Bundle reference");
            if (!owner.Members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal).SetEquals(["kind", "id"])) throw Invalid();
            return new RuntimeBundleReference(TypedJson.Required(owner, "kind", TypedJson.String), TypedJson.Required(owner, "id", TypedJson.String));
        }));
        return new(Text("bundleRef"), Text("kind"), Text("platform"), Text("version"), Text("state"), digest,
            Count("byteCount"), Count("entryCount"), Count("generation"), Text("registeredAtUTC"),
            TypedJson.Required(o, "contentRetained", TypedJson.Bool), new(T("policy"), T("signature"), T("teamIdentifier"), T("executionAssessment")), references);
    }

    internal static ContractException Invalid() => new(ContractErrorKind.SchemaMismatch, "Runtime Bundle inventory is unreadable");
}

public sealed record RuntimeBundleTrust(string Policy, string Signature, string TeamIdentifier, string ExecutionAssessment);
public sealed record RuntimeBundleReference(string Kind, string Id);

/// <summary><c>runtime.storage.status</c>: the Runtime's Artifact store and the Session output root.</summary>
public sealed record StorageStatus(
    string ArtifactUsedBytes,
    string ArtifactRemainingBytes,
    string ArtifactTotalBytes,
    string ArtifactPolicy,
    string SessionRootKind,
    string SessionRootPath,
    string QuotaBytes,
    string SafetyMarginBytes,
    string RetentionDays,
    string SessionUsedBytes,
    string SessionCount,
    string PinnedSessionCount,
    string PinnedBytes,
    string UnaccountedSessionCount,
    bool MeasurementIncomplete,
    string Generation = "0")
{
    public static StorageStatus Parse(JsonValue value)
    {
        var o = Json.Object(value, "a storage status");
        var artifacts = TypedJson.Required(o, "artifactDomain", v => Json.Object(v, "artifactDomain"));
        var session = TypedJson.Required(o, "sessionDomain", v => Json.Object(v, "sessionDomain"));
        var policy = TypedJson.Required(session, "policy", v => Json.Object(v, "policy"));
        var usage = TypedJson.Required(session, "usage", v => Json.Object(v, "usage"));
        string S(JsonObject from, string key) => TypedJson.Required(from, key, TypedJson.String);
        return new(S(artifacts, "usedBytes"), S(artifacts, "remainingBytes"), S(artifacts, "totalBytes"), S(artifacts, "policy"),
            S(session, "rootKind"), S(session, "rootPath"),
            S(policy, "totalQuotaBytes"), S(policy, "safetyMarginBytes"), S(policy, "retentionDays"),
            S(usage, "usedBytes"), S(usage, "sessionCount"), S(usage, "pinnedSessionCount"), S(usage, "pinnedBytes"),
            S(usage, "unaccountedSessionCount"), TypedJson.Required(usage, "measurementIncomplete", TypedJson.Bool),
            S(session, "generation"));
    }

    public const ulong Gibibyte = 1UL << 30;

    /// <summary>macOS <c>savePolicy</c>'s check of the drafts (GiB, GiB, days): whole numbers, the
    /// quota above the margin, both positive, and no overflow in bytes; null otherwise. The
    /// Runtime still decides whether it accepts them.</summary>
    public static (ulong QuotaBytes, ulong MarginBytes, ulong RetentionDays)? Draft(string quotaGiB, string marginGiB, string retentionDays)
    {
        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        const System.Globalization.NumberStyles digits = System.Globalization.NumberStyles.None;
        if (!ulong.TryParse(quotaGiB.Trim(), digits, invariant, out var quota) || !ulong.TryParse(marginGiB.Trim(), digits, invariant, out var margin)
            || !ulong.TryParse(retentionDays.Trim(), digits, invariant, out var retention)
            || quota <= margin || margin == 0 || retention == 0 || quota > ulong.MaxValue / Gibibyte)
        {
            return null;
        }
        return (quota * Gibibyte, margin * Gibibyte, retention);
    }

    /// <summary>A byte figure as whole GiB, for the policy drafts.</summary>
    public static string GiB(string bytes) =>
        ulong.TryParse(bytes, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var b)
            ? (b / Gibibyte).ToString(System.Globalization.CultureInfo.InvariantCulture) : "";
}

/// <summary>What a generation-bound storage write left: the Runtime's storage as it now stands,
/// and whether another writer published first (macOS <c>publish</c> reads the owner's state back
/// on <c>resourceConflict</c> and never re-sends).</summary>
public sealed record StorageWrite(StorageStatus Status, bool Superseded);

/// <summary><c>trace.cache.purge</c>: what the Runtime removed (inactive derived databases only;
/// never an original Trace), checked as macOS <c>RuntimeTraceCacheResponseDecoding.purge</c>.</summary>
public sealed record TraceCachePurge(long RemovedEntryCount, long SkippedActiveEntryCount, long EntriesBefore, long EntriesAfter, string BytesAfter)
{
    public static TraceCachePurge Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Trace cache purge");
        string[] keys = ["schemaVersion", "before", "after", "recoveredPrivateDirectoryCount", "removedOrphanOwnerMarkerCount", "removedEntryCount",
            "skippedActiveEntryCount", "purgeScope", "originalTraceArtifactRemovalCount"];
        if (!o.Members.Select(m => m.Key).ToHashSet().SetEquals(keys)
            || TypedJson.Required(o, "schemaVersion", TypedJson.String) != "arkdeck.trace-cache-purge/1"
            || TypedJson.Required(o, "purgeScope", TypedJson.String) != "inactiveDerivedDatabases"
            || TypedJson.Required(o, "originalTraceArtifactRemovalCount", TypedJson.Int64) != 0)
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "ArkDeck Runtime returned an invalid Trace cache purge report");
        }
        var before = TypedJson.Required(o, "before", v => Json.Object(v, "before"));
        var after = TypedJson.Required(o, "after", v => Json.Object(v, "after"));
        long Count(JsonObject from, string key)
        {
            var n = TypedJson.Required(from, key, TypedJson.Int64);
            return n >= 0 ? n : throw new ContractException(ContractErrorKind.SchemaMismatch, "a negative Trace cache count");
        }
        Count(o, "recoveredPrivateDirectoryCount");
        Count(o, "removedOrphanOwnerMarkerCount");
        return new(Count(o, "removedEntryCount"), Count(o, "skippedActiveEntryCount"), Count(before, "entryCount"), Count(after, "entryCount"),
            TypedJson.Required(after, "totalByteCount", TypedJson.String));
    }
}


/// <summary><c>trace.cache.status</c>: the derived Trace cache's entries and bytes.</summary>
public sealed record TraceCacheStatus(long EntryCount, long ActiveEntryCount, long InactiveEntryCount, string TotalByteCount, string PurgeScope)
{
    public static TraceCacheStatus Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Trace cache status");
        return new(
            TypedJson.Required(o, "entryCount", TypedJson.Int64),
            TypedJson.Required(o, "activeEntryCount", TypedJson.Int64),
            TypedJson.Required(o, "inactiveEntryCount", TypedJson.Int64),
            TypedJson.Required(o, "totalByteCount", TypedJson.String),
            TypedJson.Required(o, "purgeScope", TypedJson.String));
    }
}

/// <summary>One registered workspace project (<c>workspace.project.list|show</c>). The root
/// path is never part of the projection; the Runtime keeps it.</summary>
public sealed record WorkspaceProject(
    string ProjectRef,
    string Kind,
    string Availability,
    string ConfigurationStatus,
    string? ReasonCode,
    string? Reason,
    string Generation,
    string RegisteredAtUtc,
    string UpdatedAtUtc,
    IReadOnlyList<string> PresetRefs,
    IReadOnlyList<OperationAvailability> Operations)
{
    public static WorkspaceProject Parse(JsonValue value)
    {
        var o = Json.Object(value, "a workspace project");
        return new(
            TypedJson.Required(o, "projectRef", TypedJson.String),
            TypedJson.Required(o, "kind", TypedJson.String),
            TypedJson.Required(o, "availability", TypedJson.String),
            TypedJson.Required(o, "configurationStatus", TypedJson.String),
            Json.NullableString(o, "reasonCode"),
            Json.NullableString(o, "reason"),
            TypedJson.Required(o, "generation", TypedJson.String),
            TypedJson.Required(o, "registeredAtUtc", TypedJson.String),
            TypedJson.Required(o, "updatedAtUtc", TypedJson.String),
            TypedJson.Required(o, "presetRefs", v => TypedJson.List(v, p => TypedJson.Required(Json.Object(p, "a preset reference"), "presetRef", TypedJson.String))),
            TypedJson.Required(o, "operations", v => TypedJson.List(v, item =>
            {
                var i = Json.Object(item, "an operation");
                var code = Json.NullableString(i, "reasonCode");
                return new OperationAvailability(
                    TypedJson.Required(i, "reference", TypedJson.String),
                    TypedJson.Required(i, "availability", TypedJson.String),
                    code is null ? [] : [code]);
            })));
    }

    public static IReadOnlyList<WorkspaceProject> ParseList(JsonValue value) =>
        TypedJson.Required(Json.Object(value, "a project list"), "projects", v => TypedJson.List(v, Parse));
}

/// <summary>One preset of a workspace project (<c>workspace.preset.list</c>).</summary>
public sealed record WorkspacePreset(
    string PresetRef,
    string Kind,
    string TemplateRef,
    long TimeoutSeconds,
    string ConfigurationStatus,
    string? ToolchainRef,
    string Generation,
    IReadOnlyList<KeyValuePair<string, string>> Constraints)
{
    public static IReadOnlyList<WorkspacePreset> ParseList(JsonValue value) =>
        TypedJson.Required(Json.Object(value, "a preset list"), "presets", v => TypedJson.List(v, item =>
        {
            var o = Json.Object(item, "a preset");
            var constraints = TypedJson.Required(o, "constraints", c => Json.Object(c, "constraints"));
            return new WorkspacePreset(
                TypedJson.Required(o, "presetRef", TypedJson.String),
                TypedJson.Required(o, "kind", TypedJson.String),
                TypedJson.Required(o, "templateRef", TypedJson.String),
                TypedJson.Required(o, "timeoutSeconds", TypedJson.Int64),
                TypedJson.Required(o, "configurationStatus", TypedJson.String),
                Json.NullableString(o, "toolchainRef"),
                TypedJson.Required(o, "generation", TypedJson.String),
                constraints.Members.Select(m => new KeyValuePair<string, string>(m.Key, Json.Text(m.Value))).ToArray());
        }));
}

/// <summary>Every tab of Settings, read in one refresh.</summary>
public sealed record SettingsState(
    Loaded<RuntimeFacts> Runtime,
    Loaded<RuntimeChecks> Checks,
    Loaded<DoctorFacts> Doctor,
    Loaded<HdcStatus> Hdc,
    Loaded<IReadOnlyList<ToolSummary>> Tools,
    Loaded<IReadOnlyList<RuntimeBundle>> Bundles,
    Loaded<StorageStatus> Storage,
    Loaded<TraceCacheStatus> TraceCache,
    Loaded<IReadOnlyList<WorkspaceProject>> Projects,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>One workspace project's detail and presets.</summary>
public sealed record ProjectState(string ProjectRef, Loaded<WorkspaceProject> Project, Loaded<IReadOnlyList<WorkspacePreset>> Presets,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

public sealed partial class SurfaceLoader
{
    public const string RuntimeBundleListCommand = "arkdeck runtime bundle list";
    public const int RuntimeBundlePageSize = 250;
    public const int RuntimeBundlePageLimit = 64;

    // A discovery snapshot is read completely or refused; earlier pages are never
    // shown as a complete registry when a continuation fails or changes identity.
    private static async Task<(IReadOnlyList<RuntimeBundle>? Items, ControlFailure? Failure)> BundlePagesAsync(IControlChannel c)
    {
        var rows = new List<RuntimeBundle>();
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null, revision = null, previousReference = null;
        for (var pageNumber = 0; pageNumber < RuntimeBundlePageLimit; pageNumber++)
        {
            var parameters = cursor is null ? Params(("pageSize", JsonNumber.FromInt64(RuntimeBundlePageSize)))
                : Params(("pageSize", JsonNumber.FromInt64(RuntimeBundlePageSize)), ("cursor", new JsonString(cursor)));
            var reply = await c.RequestAsync("runtime.bundle.list", parameters).ConfigureAwait(false);
            if (reply.Failure is { } failure) return (null, failure);
            var page = Json.Object(reply.Value!, "a Runtime Bundle page");
            if (!page.Members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal)
                .SetEquals(["schemaVersion", "pageKind", "order", "snapshotRevision", "items", "hasMore", "nextCursor"])
                || Json.OptionalString(page, "schemaVersion") != "arkdeck.cli.page/1"
                || Json.OptionalString(page, "pageKind") != "snapshot" || Json.OptionalString(page, "order") != "bundleRef:asc") throw RuntimeBundle.Invalid();
            var currentRevision = TypedJson.Required(page, "snapshotRevision", TypedJson.String);
            var more = TypedJson.Required(page, "hasMore", TypedJson.Bool);
            var next = Json.NullableString(page, "nextCursor");
            var items = TypedJson.Required(page, "items", v => TypedJson.List(v, RuntimeBundle.Parse));
            if (string.IsNullOrEmpty(currentRevision) || (revision is not null && revision != currentRevision)
                || more != (next is not null) || (more && (items.Count == 0 || string.IsNullOrEmpty(next)))
                || items.Count > RuntimeBundlePageSize) throw RuntimeBundle.Invalid();
            revision = currentRevision;
            foreach (var item in items)
            {
                if (previousReference is not null && StringComparer.Ordinal.Compare(previousReference, item.BundleRef) >= 0) throw RuntimeBundle.Invalid();
                rows.Add(item); previousReference = item.BundleRef;
            }
            if (!more) return (rows, null);
            if (!cursors.Add(next!)) throw RuntimeBundle.Invalid();
            cursor = next;
        }
        throw RuntimeBundle.Invalid();
    }

    /// <summary>The Settings tabs: the Runtime's <c>health</c> and <c>doctor</c>, the HDC and
    /// tool registry, storage, the Trace cache and the workspace projects, each as it came.
    /// Everything here is read; changing a setting is the CLI's (the tabs name the command).</summary>
    /// <summary>The storage policy, bound to the generation just read (macOS
    /// <c>updateStoragePolicy</c>): the Runtime validates and publishes it; another writer's
    /// earlier publication is read back, not overwritten.</summary>
    public Task<SessionActionState<StorageWrite>> SaveStoragePolicyAsync(ulong quotaBytes, ulong marginBytes, ulong retentionDays) =>
        StorageWriteAsync("runtime.storage.policy", generation => Params(("expectedGeneration", new JsonString(generation)),
            ("retentionDays", new JsonString(retentionDays.ToString(System.Globalization.CultureInfo.InvariantCulture))),
            ("safetyMarginBytes", new JsonString(marginBytes.ToString(System.Globalization.CultureInfo.InvariantCulture))),
            ("totalQuotaBytes", new JsonString(quotaBytes.ToString(System.Globalization.CultureInfo.InvariantCulture)))),
            CliCommands.RuntimeStoragePolicy);

    /// <summary>The Session output root (macOS <c>selectStorageRoot</c>), or the default again
    /// (<c>resetStorageRoot</c>) when <paramref name="rootPath"/> is null: the Runtime checks the
    /// folder.</summary>
    public Task<SessionActionState<StorageWrite>> SetStorageRootAsync(string? rootPath) =>
        StorageWriteAsync("runtime.storage.root", generation => rootPath is null
            ? Params(("expectedGeneration", new JsonString(generation)), ("resetToDefault", JsonBool.True))
            : Params(("expectedGeneration", new JsonString(generation)), ("rootPath", new JsonString(rootPath))),
            CliCommands.RuntimeStorageRoot);

    private async Task<SessionActionState<StorageWrite>> StorageWriteAsync(string method, Func<string, JsonObject> parameters, string cli)
    {
        var run = new Run(channel);
        var current = await run.Load(c => c.RequestAsync("runtime.storage.status"), StorageStatus.Parse, CliCommands.RuntimeStorageStatus);
        if (current.Unavailable is { } unread) return new(Loaded<StorageWrite>.Not(unread), run.DaemonFailure, run.Reached);
        var written = await run.Load(c => c.RequestAsync(method, parameters(current.Value!.Generation)), StorageStatus.Parse, cli);
        if (written.Value is { } status) return new(Loaded<StorageWrite>.Of(new(status, false)), run.DaemonFailure, run.Reached);
        if (written.Unavailable!.ReasonCode != "resourceConflict") return new(Loaded<StorageWrite>.Not(written.Unavailable), run.DaemonFailure, run.Reached);
        var won = await run.Load(c => c.RequestAsync("runtime.storage.status"), StorageStatus.Parse, CliCommands.RuntimeStorageStatus);
        return new(won.Value is { } now ? Loaded<StorageWrite>.Of(new(now, true)) : Loaded<StorageWrite>.Not(won.Unavailable!), run.DaemonFailure, run.Reached);
    }

    /// <summary>Removes the inactive derived Trace databases (macOS
    /// <c>purgeUnusedTraceCache</c>): never an original Trace or an entry in use.</summary>
    public Task<SessionActionState<TraceCachePurge>> PurgeTraceCacheAsync() =>
        Action("trace.cache.purge", null, TraceCachePurge.Parse, CliCommands.TraceCachePurge);

    public async Task<SettingsState> SettingsAsync()
    {
        var run = new Run(channel);
        var runtime = await run.Load(c => c.HealthAsync(), RuntimeFacts.Parse, CliCommands.RuntimeHealth);
        var doctorReply = await run.Load(c => c.RequestAsync("doctor", Params(("deep", JsonBool.False))), v => v, CliCommands.Doctor);
        var checks = Reparse(doctorReply, RuntimeChecks.Parse);
        var doctor = Reparse(doctorReply, DoctorFacts.Parse);
        var hdc = await run.Load(c => c.RequestAsync("runtime.hdc.status"), HdcStatus.Parse, CliCommands.RuntimeHdcStatus);
        var tools = await run.Load(c => c.RequestAsync("runtime.tool.list"), ToolSummary.ParsePage, CliCommands.RuntimeToolList);
        var bundles = await run.LoadPages(BundlePagesAsync, RuntimeBundleListCommand);
        var storage = await run.Load(c => c.RequestAsync("runtime.storage.status"), StorageStatus.Parse, CliCommands.RuntimeStorageStatus);
        var cache = await run.Load(c => c.RequestAsync("trace.cache.status"), TraceCacheStatus.Parse, CliCommands.TraceCacheStatus);
        var projects = await run.Load(c => c.RequestAsync("workspace.project.list"), WorkspaceProject.ParseList, CliCommands.WorkspaceProjectList);
        return new(runtime, checks, doctor, hdc, tools, bundles, storage, cache, projects, run.DaemonFailure, run.Reached);
    }

    public async Task<ProjectState> ProjectAsync(string projectRef)
    {
        var run = new Run(channel);
        var id = new JsonString(projectRef);
        var project = await run.Load(c => c.RequestAsync("workspace.project.show", Params(("projectRef", id))), WorkspaceProject.Parse,
            CliCommands.ForProject(CliCommands.WorkspaceProjectShow, projectRef));
        var presets = await run.Load(c => c.RequestAsync("workspace.preset.list", Params(("projectRef", id))), WorkspacePreset.ParseList,
            CliCommands.ForProject(CliCommands.WorkspacePresetList, projectRef));
        return new(projectRef, project, presets, run.DaemonFailure, run.Reached);
    }

    /// <summary>One reply read two ways (the doctor report feeds two projections).</summary>
    private static Loaded<T> Reparse<T>(Loaded<JsonValue> reply, Func<JsonValue, T> parse) where T : class
    {
        if (reply.Unavailable is { } why) return Loaded<T>.Not(why);
        try
        {
            return Loaded<T>.Of(parse(reply.Value!));
        }
        catch (Exception error) when (error is ContractException or InvalidCastException or KeyNotFoundException)
        {
            return Loaded<T>.Not(Unavailable.Unreadable(error, CliCommands.Doctor));
        }
    }
}
