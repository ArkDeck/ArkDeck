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
                TypedJson.Required(o, "selected", Json.Text));
        }));
    }
}

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
    bool MeasurementIncomplete)
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
            S(usage, "unaccountedSessionCount"), TypedJson.Required(usage, "measurementIncomplete", TypedJson.Bool));
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
    /// <summary>The Settings tabs: the Runtime's <c>health</c> and <c>doctor</c>, the HDC and
    /// tool registry, storage, the Trace cache and the workspace projects, each as it came.
    /// Everything here is read; changing a setting is the CLI's (the tabs name the command).</summary>
    public async Task<SettingsState> SettingsAsync()
    {
        var run = new Run(channel);
        var runtime = await run.Load(c => c.HealthAsync(), RuntimeFacts.Parse, CliCommands.RuntimeHealth);
        var doctorReply = await run.Load(c => c.RequestAsync("doctor", Params(("deep", JsonBool.False))), v => v, CliCommands.Doctor);
        var checks = Reparse(doctorReply, RuntimeChecks.Parse);
        var doctor = Reparse(doctorReply, DoctorFacts.Parse);
        var hdc = await run.Load(c => c.RequestAsync("runtime.hdc.status"), HdcStatus.Parse, CliCommands.RuntimeHdcStatus);
        var tools = await run.Load(c => c.RequestAsync("runtime.tool.list"), ToolSummary.ParsePage, CliCommands.RuntimeToolList);
        var storage = await run.Load(c => c.RequestAsync("runtime.storage.status"), StorageStatus.Parse, CliCommands.RuntimeStorageStatus);
        var cache = await run.Load(c => c.RequestAsync("trace.cache.status"), TraceCacheStatus.Parse, CliCommands.TraceCacheStatus);
        var projects = await run.Load(c => c.RequestAsync("workspace.project.list"), WorkspaceProject.ParseList, CliCommands.WorkspaceProjectList);
        return new(runtime, checks, doctor, hdc, tools, storage, cache, projects, run.DaemonFailure, run.Reached);
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
