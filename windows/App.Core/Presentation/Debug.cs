using System.Security.Cryptography;
using System.Text.RegularExpressions;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// The Debug workspace's Runtime facts and its closed typed actions, as the macOS
/// <c>DebugApplicationFacade</c> has them: bounded HiLog capture (<c>capture.diagnostics@1</c>),
/// one target-bound HAP lifecycle (<c>debug.hap@1</c>), one app-owned native-library deployment
/// (<c>deploy.native-library.app-owned@1</c>, planned and reviewed before it is submitted), typed
/// port rules (<c>port-forward.create|remove@1</c>) and four read-only templates
/// (<c>debug.template@1</c>). There is no executable, argv, device path or authority input.
/// </summary>
public static partial class DebugOperations
{
    public const string CaptureDiagnostics = "capture.diagnostics@1";
    public const string DebugHap = "debug.hap@1";
    public const string DebugTemplate = "debug.template@1";
    public const string NativeLibrary = "deploy.native-library.app-owned@1";
    public const string CreatePortForward = "port-forward.create@1";
    public const string RemovePortForward = "port-forward.remove@1";

    public static readonly IReadOnlyList<string> All = [CaptureDiagnostics, DebugHap, DebugTemplate, NativeLibrary, CreatePortForward, RemovePortForward];

    /// <summary>The workspace client names the daemon reads with the operation
    /// (<c>ArkDeckAgentClientName</c>): each tab is its own subject.</summary>
    public const string LogsClient = "ArkDeckApp.DebugWorkspace.Logs";
    public const string ArtifactsClient = "ArkDeckApp.DebugWorkspace.Artifacts";
    public const string AppsClient = "ArkDeckApp.DebugWorkspace.Apps";
    public const string NetworkClient = "ArkDeckApp.DebugWorkspace.Network";
    public const string CommandsClient = "ArkDeckApp.DebugWorkspace.Commands";

    /// <summary>The exact read-only template set the daemon implements; none accepts text.</summary>
    public static readonly IReadOnlyList<string> Templates = ["device.packageInventory", "device.debugParameterRead", "device.windowInventory", "device.uptime"];

    public const int MaximumAdditionalPackages = 16;

    // DebugTypedValueValidator: the same character policies as the macOS App and the CLI.
    public static bool IsSafeHilogComponent(string value) => value.Length is > 0 and <= 200 && HilogComponent().IsMatch(value);

    public static bool IsSafeTypedIdentifier(string value) => IsSafeHilogComponent(value);

    public static bool IsValidBundleName(string value) => value.Length <= 200 && BundleName().IsMatch(value);

    public static bool IsValidAbilityName(string value) => value.Length <= 200 && AbilityName().IsMatch(value);

    public static bool IsValidNativeLibraryName(string value) => value.Length <= 128 && NativeLibraryName().IsMatch(value);

    /// <summary>A package the HAP lifecycle accepts: a safe <c>.hap</c> entry, or <c>.hap</c>/<c>.hsp</c>
    /// for an additional package (<c>DebugHAPPackageSelection.isSafeName</c>).</summary>
    public static bool IsSafePackageName(string name, bool allowsHsp) =>
        name.Length <= 128 && (allowsHsp ? AdditionalPackage().IsMatch(name) : EntryPackage().IsMatch(name));

    /// <summary>Why a package set cannot be chosen (the macOS failure keys
    /// <c>debug.apps.selection.&lt;reason&gt;</c>), or null.</summary>
    public static string? PackageSelectionFailure(string entry, IReadOnlyList<string> additional)
    {
        if (!IsSafePackageName(Path.GetFileName(entry), allowsHsp: false)) return "invalidEntry";
        if (additional.Count > MaximumAdditionalPackages) return "tooManyPackages";
        if (!additional.All(p => IsSafePackageName(Path.GetFileName(p), allowsHsp: true))) return "invalidAdditional";
        var paths = additional.Prepend(entry).Select(p => Path.GetFullPath(p).ToUpperInvariant()).ToArray();
        return paths.Distinct().Count() == paths.Length ? null : "duplicatePackage";
    }

    /// <summary>Two decimal ports, 1024–65535 each: the macOS <c>DebugPortRuleValidator</c>
    /// failure (<c>debug.network.validation.&lt;failure&gt;</c>), or null for a valid rule.</summary>
    public static string? PortRuleFailure(string local, string remote, out int localPort, out int remotePort)
    {
        remotePort = 0;
        if (!Decimal(local, out localPort)) return "localPortNotNumeric";
        if (localPort is < 1024 or > 65535) return "localPortOutOfRange";
        if (!Decimal(remote, out remotePort)) return "remotePortNotNumeric";
        return remotePort is < 1024 or > 65535 ? "remotePortOutOfRange" : null;
    }

    private static bool Decimal(string text, out int value)
    {
        value = 0;
        return text.Length is > 0 and <= 9 && text.All(char.IsAsciiDigit) && int.TryParse(text, out value);
    }

    [GeneratedRegex(@"^[\p{L}\p{N}._:-]+$")]
    private static partial Regex HilogComponent();

    [GeneratedRegex(@"^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+$")]
    private static partial Regex BundleName();

    [GeneratedRegex(@"^[a-zA-Z][a-zA-Z0-9_.]*$")]
    private static partial Regex AbilityName();

    [GeneratedRegex(@"^lib[A-Za-z0-9_.-]+\.so$")]
    private static partial Regex NativeLibraryName();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]*\.hap$")]
    private static partial Regex EntryPackage();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]*\.(hap|hsp)$")]
    private static partial Regex AdditionalPackage();
}

/// <summary>One active port rule the Runtime reports for a Target (<c>debug.probe</c>).</summary>
public sealed record DebugPortRule(string Direction, int LocalPort, int RemotePort);

/// <summary>What <c>debug.probe</c> read from the Target: its packages, its active port rules
/// and the probe's warnings, bound to the Target and binding revision it was read for.</summary>
public sealed record DebugProbe(string TargetId, long BindingRevision, IReadOnlyList<string> Packages, IReadOnlyList<DebugPortRule> PortRules,
    IReadOnlyList<string> Warnings)
{
    public static DebugProbe Parse(JsonValue value, TargetSummary target)
    {
        var o = Json.Object(value, "a Debug probe");
        if (TypedJson.Required(o, "targetId", TypedJson.String) != target.TargetId
            || TypedJson.Required(o, "bindingRevision", TypedJson.Int64) != target.BindingRevision)
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned mismatched Debug probe facts");
        }
        var packages = TypedJson.Required(o, "packages", v => TypedJson.List(v, TypedJson.String));
        if (packages.Distinct(StringComparer.Ordinal).Count() != packages.Count || !packages.All(DebugOperations.IsSafeTypedIdentifier))
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned mismatched Debug probe facts");
        }
        var rules = TypedJson.Required(o, "portRules", v => TypedJson.List(v, row =>
        {
            var r = Json.Object(row, "a port rule");
            var direction = TypedJson.Required(r, "direction", TypedJson.String);
            var local = TypedJson.Required(r, "localPort", TypedJson.Int64);
            var remote = TypedJson.Required(r, "remotePort", TypedJson.Int64);
            if (direction is not ("forward" or "reverse") || local is < 1024 or > 65535 || remote is < 1024 or > 65535)
            {
                throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned malformed port rules");
            }
            return new DebugPortRule(direction, (int)local, (int)remote);
        }));
        return new(target.TargetId, target.BindingRevision, packages, rules, TypedJson.Required(o, "warnings", v => TypedJson.List(v, TypedJson.String)));
    }
}

/// <summary>The Debug workspace: the six operations' facts, the adopted Targets, the recent
/// Debug Jobs with their Artifacts, and the selected Target's probe.</summary>
public sealed record DebugState(
    IReadOnlyList<OperationFacts> Operations,
    Loaded<IReadOnlyList<TargetSummary>> Targets,
    Loaded<IReadOnlyList<RecentJob>> Jobs,
    Loaded<DebugProbe>? Probe,
    IReadOnlyDictionary<string, IReadOnlyList<ArtifactSummary>> ArtifactsByJob,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached)
{
    public OperationFacts? Operation(string reference) => Operations.FirstOrDefault(o => o.Reference == reference);

    /// <summary>The published Artifacts of a workspace's Jobs on the Target (macOS
    /// <c>runtimeArtifactRows</c>).</summary>
    public IReadOnlyList<(string JobId, ArtifactSummary Artifact)> ArtifactsOf(string operation, string? targetId) =>
        (Jobs.Value ?? []).Where(j => j.Operation == operation && (targetId is null || j.TargetId == targetId))
            .SelectMany(j => ArtifactsByJob.TryGetValue(j.JobId, out var rows) ? rows.Select(a => (j.JobId, a)) : [])
            .ToArray();
}

/// <summary>A native library the Runtime imported and planned, ready for the person to review:
/// the Import's validation facts, the plan's digest and steps, and the exact request (the plan
/// digest pinned) that will be submitted — the App cannot change it after the review.</summary>
public sealed record NativeLibraryPreparation(
    string TargetId,
    long BindingRevision,
    string LibraryName,
    long ByteCount,
    string Sha256,
    string Abi,
    long ElfClassBits,
    long Machine,
    string BuildId,
    string TargetBundle,
    string VerificationProfile,
    string RollbackPolicy,
    string PlanDigest,
    IReadOnlyList<OperationStep> Steps,
    RuntimeRequest Reviewed);

/// <summary>A preparation, or why it could not be made.</summary>
public sealed record NativeLibraryOutcome(NativeLibraryPreparation? Prepared, Unavailable? Failure, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

/// <summary>A submission, or why not.</summary>
public sealed record SubmitOutcome(string? JobId, Unavailable? Failure, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached)
{
    public static SubmitOutcome From(SessionActionState<JobAcceptance> state) =>
        new(state.Answer.Value?.JobId, state.Answer.Unavailable, state.DaemonFailure, state.Reached);

    public static SubmitOutcome Refused(string reason, string cli) => new(null, new Unavailable("invalidInput", reason, cli, null), null, false);
}

public sealed partial class SurfaceLoader
{
    /// <summary>The Debug workspace (macOS <c>refreshWorkspace</c>): the operations' facts, the
    /// Targets, the recent Debug Jobs (and the Artifacts of the newest six), and the selected
    /// Target's <c>debug.probe</c> (the first Target when none is selected).</summary>
    public async Task<DebugState> DebugAsync(string? targetId)
    {
        var run = new Run(channel);
        IReadOnlyList<OperationFacts> operations;
        try
        {
            operations = await OperationsAsync(channel, DebugOperations.All).ConfigureAwait(false);
        }
        catch (ControlClientException error) when (error.Failure.ShowsRecoveryBanner)
        {
            operations = DebugOperations.All.Select(r => OperationFacts.Unread(r, [error.Failure.Message])).ToArray();
        }
        var targets = await run.Load(c => c.RequestAsync("target.list"), TargetSummary.ParseAll, CliCommands.TargetList);
        var jobs = await run.Load(c => c.RequestAsync("job.list", RecentJobParams()),
            v => (IReadOnlyList<RecentJob>)RecentJob.ParsePage(v).Where(j => DebugOperations.All.Contains(j.Operation)).ToArray(), CliCommands.JobList);
        var artifacts = new Dictionary<string, IReadOnlyList<ArtifactSummary>>(StringComparer.Ordinal);
        foreach (var job in (jobs.Value ?? []).Take(6))
        {
            var rows = await run.LoadPages(c => ArtifactPagesAsync(c, job.JobId), CliCommands.ArtifactListForJob(job.JobId));
            if (rows.Value is { } published) artifacts[job.JobId] = published;
        }
        Loaded<DebugProbe>? probe = null;
        if (targets.Value is { Count: > 0 } all && (all.FirstOrDefault(t => t.TargetId == targetId) ?? all[0]) is { } target)
        {
            probe = await run.Load(c => c.RequestAsync("debug.probe", Params(("targetId", new JsonString(target.TargetId)))),
                v => DebugProbe.Parse(v, target), CliCommands.DebugProbe);
        }
        return new(operations, targets, jobs, probe, artifacts, run.DaemonFailure, run.Reached);
    }

    /// <summary>A bounded HiLog capture (<c>capture.diagnostics@1</c> with the Debug logs preset:
    /// HiLog on at its descriptor default, every other leg off, read-only).</summary>
    public Task<SubmitOutcome> SubmitLogsAsync(TargetSummary target, int durationSeconds, IReadOnlyList<string> filters)
    {
        if (durationSeconds is < 1 or > 600 || filters.Count > 16 || !filters.All(DebugOperations.IsSafeHilogComponent))
        {
            return Task.FromResult(SubmitOutcome.Refused("HiLog request is outside the published bounds", CliCommands.DebugLogs));
        }
        var request = RuntimeRequest.Build("debug-logs-ui", "capture.diagnostics", 1, target.TargetId, target.BindingRevision,
        [
            ("durationSeconds", JsonNumber.FromInt64(durationSeconds)),
            ("hilogFilters", new JsonArray(filters.Select(f => (JsonValue)new JsonString(f)))),
            ("uiDump", JsonBool.False),
            ("crashLogs", JsonBool.False),
            ("uiScreenshot", JsonBool.False),
            ("uiComponentTree", JsonBool.False),
            ("redactionProfile", new JsonString("standard")),
        ], ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], DebugOperations.LogsClient);
        return SubmitTypedAsync(request, CliCommands.DebugLogs);
    }

    /// <summary>One typed port rule (<c>port-forward.create|remove@1</c>).</summary>
    public Task<SubmitOutcome> SubmitPortRuleAsync(TargetSummary target, DebugPortRule rule, bool removing)
    {
        if (rule.Direction is not ("forward" or "reverse") || rule.LocalPort is < 1024 or > 65535 || rule.RemotePort is < 1024 or > 65535)
        {
            return Task.FromResult(SubmitOutcome.Refused("Port rule is outside the published bounds", CliCommands.DebugPortForward));
        }
        var request = RuntimeRequest.Build("debug-network-ui", removing ? "port-forward.remove" : "port-forward.create", 1, target.TargetId,
            target.BindingRevision,
            [("direction", new JsonString(rule.Direction)), ("localPort", JsonNumber.FromInt64(rule.LocalPort)), ("remotePort", JsonNumber.FromInt64(rule.RemotePort))],
            ["derivedArtifacts", "hardwareEvidence"], DebugOperations.NetworkClient);
        return SubmitTypedAsync(request, CliCommands.DebugPortForward);
    }

    /// <summary>One read-only template (<c>debug.template@1</c>) of the closed set.</summary>
    public Task<SubmitOutcome> SubmitTemplateAsync(TargetSummary target, string templateId)
    {
        if (!DebugOperations.Templates.Contains(templateId) || target.BindingRevision < 1)
        {
            return Task.FromResult(SubmitOutcome.Refused("Unknown Debug template", CliCommands.DebugTemplate));
        }
        var request = RuntimeRequest.Build("debug-template-ui", "debug.template", 1, target.TargetId, target.BindingRevision,
            [("templateId", new JsonString(templateId))], ["rawArtifacts", "derivedArtifacts"], DebugOperations.CommandsClient);
        return SubmitTypedAsync(request, CliCommands.DebugTemplate);
    }

    /// <summary>One HAP lifecycle (<c>debug.hap@1</c>), as the macOS App submits it: the closed
    /// request dimensions checked first, every package inspected (safe name, 1 byte to 64 MiB,
    /// no two with the same bytes) before the first upload, each package imported
    /// (<see cref="ImportUploader"/>, kind <c>hap</c>) for its lease, then the typed request.
    /// No local path is sent to the Runtime.</summary>
    public async Task<SubmitOutcome> SubmitHapAsync(TargetSummary target, string entry, IReadOnlyList<string> additional, string bundleName,
        string abilityName, string cleanupPolicy, string postRunState, bool captureDiagnostics, int diagnosticsSeconds, CancellationToken cancellation)
    {
        var cli = CliCommands.DebugHap;
        if (DebugOperations.PackageSelectionFailure(entry, additional) is { } selection)
        {
            return SubmitOutcome.Refused(selection switch
            {
                "invalidEntry" => "Choose one entry .hap with a safe basename",
                "invalidAdditional" => "Choose additional .hap or .hsp packages with safe basenames",
                "tooManyPackages" => "Choose at most 16 additional packages",
                _ => "Select each package only once; duplicate files or bytes were found",
            }, cli);
        }
        if (!DebugOperations.IsValidBundleName(bundleName) || !DebugOperations.IsValidAbilityName(abilityName)
            || cleanupPolicy is not ("uninstall" or "retain") || postRunState is not ("stopped" or "running") || diagnosticsSeconds is < 1 or > 300)
        {
            return SubmitOutcome.Refused("HAP request is outside the published bounds", cli);
        }
        var files = additional.Prepend(entry).ToArray();
        var digests = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            var info = new FileInfo(file);
            if (!info.Exists) return SubmitOutcome.Refused("The selected package is not a readable regular file", cli);
            if (info.Length is < 1 or > 64L * 1024 * 1024) return SubmitOutcome.Refused("Each selected package must be between 1 byte and 64 MiB", cli);
            await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (!digests.Add(Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellation).ConfigureAwait(false))))
            {
                return SubmitOutcome.Refused("Select each package only once; duplicate files or bytes were found", cli);
            }
        }
        var leases = new List<string>();
        foreach (var file in files)
        {
            var imported = await new ImportUploader(channel).UploadAsync(file, ImportKind.Hap, target, null, cancellation).ConfigureAwait(false);
            if (imported.Cancelled) return SubmitOutcome.Refused("The HAP upload was cancelled", cli);
            if (imported.Failure is { } why) return new(null, why, imported.DaemonFailure, imported.Reached);
            if (imported.Committed?.Receipt?.Lease is not { Length: > 0 } lease) return SubmitOutcome.Refused("Runtime returned no HAP Import lease", cli);
            leases.Add(lease);
        }
        var inputs = new List<(string, JsonValue)>
        {
            ("hapArtifactLease", new JsonString(leases[0])),
            ("bundleName", new JsonString(bundleName)),
            ("abilityName", new JsonString(abilityName)),
            ("installPolicy", new JsonString("installOrReplace")),
            ("cleanupPolicy", new JsonString(cleanupPolicy)),
            ("postRunAbilityState", new JsonString(postRunState)),
            ("captureDiagnostics", JsonBool.Of(captureDiagnostics)),
            ("diagnosticsDurationSeconds", JsonNumber.FromInt64(diagnosticsSeconds)),
            ("portForwardProfile", new JsonString("none")),
        };
        // Absent when there is none, so the published single-package plan is unchanged.
        if (leases.Count > 1) inputs.Add(("additionalHapArtifactLeases", new JsonArray(leases.Skip(1).Select(l => (JsonValue)new JsonString(l)))));
        var request = RuntimeRequest.Build("debug-hap-ui", "debug.hap", 1, target.TargetId, target.BindingRevision, inputs,
            ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], DebugOperations.AppsClient);
        return await SubmitTypedAsync(request, cli).ConfigureAwait(false);
    }

    /// <summary>
    /// Prepares one app-owned native library for review (macOS <c>prepareNativeLibrary</c>): the
    /// file is imported (<see cref="ImportUploader"/>, kind <c>native-library</c>; the Runtime
    /// validates the signed OpenHarmony ELF and reports its ABI, class, machine and build ID), the
    /// typed request is planned with the ABI the Runtime observed (<c>job.plan</c>), and the plan
    /// is checked to be exactly that request on that Target and binding: plan only, not admitted,
    /// not dispatched, the HDC provider, a device mutation, the published steps. The reviewed
    /// request pins the plan digest.
    /// </summary>
    public async Task<NativeLibraryOutcome> PrepareNativeLibraryAsync(TargetSummary target, string file, string targetBundle,
        string libraryName, string verificationProfile, string rollbackPolicy, IReadOnlyList<OperationStep> publishedSteps,
        CancellationToken cancellation)
    {
        var cli = CliCommands.DebugNativeLibrary;
        NativeLibraryOutcome Refused(string reason) => new(null, new Unavailable("invalidInput", reason, cli, null), null, false);
        if (!DebugOperations.IsValidBundleName(targetBundle) || !DebugOperations.IsValidNativeLibraryName(libraryName)
            || verificationProfile is not ("hashOnly" or "hashAndProcess" or "hashProcessAndMaps") || rollbackPolicy is not ("autoRollback" or "retainBackup"))
        {
            return Refused("Complete the bundle, library name and published verification settings");
        }
        var imported = await new ImportUploader(channel).UploadAsync(file, ImportKind.NativeLibrary, target, null, cancellation).ConfigureAwait(false);
        if (imported.Cancelled) return Refused("The native-library upload was cancelled");
        if (imported.Failure is { } failed) return new(null, failed, imported.DaemonFailure, imported.Reached);
        var import = imported.Committed!;
        var receipt = import.Receipt!;
        if (receipt.Lease is not { Length: > 0 } lease
            || receipt.Fact("abi") is not JsonString { Value: var abi }
            || receipt.Fact("elfClassBits") is not JsonNumber bits || !bits.TryGetInt64(out var elfClassBits)
            || receipt.Fact("machine") is not JsonNumber machineNumber || !machineNumber.TryGetInt64(out var machine)
            || receipt.Fact("buildId") is not JsonString { Value: var buildId })
        {
            return Refused("Runtime Import differs from the selected native library");
        }
        var request = RuntimeRequest.Build("debug-native-ui", "deploy.native-library.app-owned", 1, target.TargetId, target.BindingRevision,
        [
            ("libraryArtifactLease", new JsonString(lease)),
            ("targetBundle", new JsonString(targetBundle)),
            ("libraryLogicalName", new JsonString(libraryName)),
            ("expectedABI", new JsonString(abi)),
            ("restartProfile", new JsonString("restartAbility")),
            ("verificationProfile", new JsonString(verificationProfile)),
            ("rollbackPolicy", new JsonString(rollbackPolicy)),
        ], ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], DebugOperations.ArtifactsClient, threaded: false);
        var planned = await PlanAsync(request, cli).ConfigureAwait(false);
        if (planned.Answer.Unavailable is { } refused) return new(null, refused, planned.DaemonFailure, planned.Reached);
        var plan = planned.Answer.Value!;
        if (plan.AdmissionBlocker is { Length: > 0 } blocker) return new(null, new Unavailable("rejected", blocker, cli, null), planned.DaemonFailure, true);
        string? Input(string key) => Json.OptionalString(plan.Inputs, key);
        var matches = plan.Operation == DebugOperations.NativeLibrary && plan.BindingRevision == target.BindingRevision
                      && plan.ProviderId == "hdc" && plan.EffectiveEffect == "deviceMutation"
                      && Input("libraryArtifactLease") == lease && Input("targetBundle") == targetBundle && Input("libraryLogicalName") == libraryName
                      && Input("expectedABI") == abi && Input("restartProfile") == "restartAbility"
                      && Input("verificationProfile") == verificationProfile && Input("rollbackPolicy") == rollbackPolicy;
        if (!matches) return new(null, new Unavailable(Unavailable.ResultUnreadableCode, "Runtime plan facts no longer match the selected target and library", cli, null), null, true);
        if (publishedSteps.Count > 0 && !plan.Steps.Select(s => (s.Id, s.Kind, s.Effect)).SequenceEqual(publishedSteps.Select(s => (s.Id, s.Kind, s.Effect))))
        {
            return new(null, new Unavailable(Unavailable.ResultUnreadableCode, "Runtime plan steps no longer match the published native-library operation", cli, null), null, true);
        }
        return new(new NativeLibraryPreparation(target.TargetId, target.BindingRevision, libraryName, import.ByteCount, import.Sha256, abi, elfClassBits,
            machine, buildId, targetBundle, verificationProfile, rollbackPolicy, plan.PlanDigest, plan.Steps, request.Reviewed(plan.PlanDigest)),
            null, planned.DaemonFailure, true);
    }

    /// <summary>Submits the reviewed native-library request, exactly as reviewed.</summary>
    public Task<SubmitOutcome> SubmitNativeLibraryAsync(NativeLibraryPreparation preparation) =>
        SubmitTypedAsync(preparation.Reviewed, CliCommands.DebugNativeLibrary);

    private async Task<SubmitOutcome> SubmitTypedAsync(RuntimeRequest request, string cli) =>
        SubmitOutcome.From(await SubmitAsync(request, cli).ConfigureAwait(false));
}
