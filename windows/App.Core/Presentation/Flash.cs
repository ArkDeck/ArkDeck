using System.Text.RegularExpressions;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// The Flash workspace's Runtime facts and its one action, as the macOS
/// <c>FlashApplicationFacade</c> has them: a full restore of one DAYU200 image archive onto one
/// adopted Target (<c>flash.full-restore@1</c>), reviewed on the host (<see cref="FlashArchive"/>),
/// imported for its lease, planned by the Runtime (plan only), then submitted exactly as reviewed
/// with one fully named primary button. Nothing else is sent: no mode, no free text.
/// </summary>
public static partial class FlashOperations
{
    public const string Reference = "flash.full-restore@1";
    public const string ProfileReference = "dayu200";
    public const string Client = "ArkDeckApp.FlashWorkspace";

    /// <summary>The Flash operations whose Jobs the workspace shows (the canonical reference and
    /// its alias).</summary>
    public static readonly IReadOnlySet<string> JobOperations = new HashSet<string>(StringComparer.Ordinal) { Reference, "flash.dayu200" };

    /// <summary>States after which the live status stops (macOS <c>isTerminalLiveState</c>).</summary>
    public static readonly IReadOnlySet<string> LiveTerminalStates = new HashSet<string>(StringComparer.Ordinal)
    {
        "succeeded", "failed", "cancelled", "recovered", "interrupted", "waitingForRecovery", "awaitingRebindConfirmation", "userAbandonRequested",
    };

    /// <summary>The Catalog review the macOS App compiles in (<c>FlashReviewCatalogGenerated</c>,
    /// generated from <c>arkdeck-hoststore</c>'s <c>flash_catalog_review</c>): the selected steps
    /// with their cancellation, and the step-set digest.</summary>
    public static readonly Lazy<FlashCatalogReview> CatalogReview = new(() =>
    {
        using var stream = typeof(FlashOperations).Assembly.GetManifestResourceStream("ArkDeck.Catalog.flash-catalog-review.json")
                           ?? throw new InvalidOperationException("the Flash Catalog review is missing");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return FlashCatalogReview.Parse(StrictJson.Parse(buffer.ToArray()));
    });

    [GeneratedRegex("^[0-9a-f]{64}$")]
    internal static partial Regex Sha256();
}

public sealed record FlashStep(string Id, string Kind, string Effect, string Cancellation, bool IsOptional);

public sealed record FlashCatalogReview(string CatalogDigest, string Operation, string ProviderId, string StepSetDigest, IReadOnlyList<FlashStep> Steps)
{
    public static FlashCatalogReview Parse(JsonValue value)
    {
        var o = Json.Object(value, "the Flash Catalog review");
        return new(
            TypedJson.Required(o, "catalogDigest", TypedJson.String),
            TypedJson.Required(o, "operation", TypedJson.String),
            TypedJson.Required(o, "providerId", TypedJson.String),
            TypedJson.Required(o, "stepSetDigestSHA256", TypedJson.String),
            TypedJson.Required(o, "steps", v => TypedJson.List(v, row =>
            {
                var step = Json.Object(row, "a Flash step");
                return new FlashStep(
                    TypedJson.Required(step, "stepId", TypedJson.String),
                    TypedJson.Required(step, "kind", TypedJson.String),
                    TypedJson.Required(step, "effect", TypedJson.String),
                    TypedJson.Required(step, "cancellation", TypedJson.String),
                    TypedJson.Required(step, "optional", TypedJson.Bool));
            })));
    }

    /// <summary>The highest effect of the plan (hostOnly &lt; readOnly &lt; deviceMutation &lt; destructive).</summary>
    public string HighestEffect => Steps.Select(s => s.Effect).MaxBy(EffectRank) ?? "hostOnly";

    public static int EffectRank(string effect) => effect switch
    {
        "readOnly" => 1,
        "deviceMutation" => 2,
        "destructive" => 3,
        _ => 0,
    };

    /// <summary>The four plan stages (macOS stage bucketing): before the first device mutation
    /// (or, with none, the first destructive step); up to the first destructive step; the
    /// destructive steps; the rest.</summary>
    public IReadOnlyList<IReadOnlyList<FlashStep>> Stages()
    {
        var firstMutation = Steps.ToList().FindIndex(s => s.Effect == "deviceMutation");
        var firstDestructive = Steps.ToList().FindIndex(s => s.Effect == "destructive");
        var lastDestructive = Steps.ToList().FindLastIndex(s => s.Effect == "destructive");
        var loaderStart = firstMutation >= 0 ? firstMutation : firstDestructive >= 0 ? firstDestructive : Steps.Count;
        var writeStart = firstDestructive >= 0 ? firstDestructive : Steps.Count;
        var verifyStart = lastDestructive >= 0 ? lastDestructive + 1 : Steps.Count;
        return
        [
            Steps.Take(Math.Min(loaderStart, writeStart)).ToArray(),
            Steps.Skip(loaderStart).Take(Math.Max(0, writeStart - loaderStart)).ToArray(),
            Steps.Skip(writeStart).Take(Math.Max(0, verifyStart - writeStart)).ToArray(),
            Steps.Skip(verifyStart).ToArray(),
        ];
    }
}

/// <summary>What <c>flash.device-access</c> reports: the RockUSB devices observed and their modes,
/// and the macOS advisor's verdict, responsible party and minimum next step.</summary>
public sealed record FlashDeviceAccess(int ObservationCount, IReadOnlyList<string> ObservedModes)
{
    public string Verdict => ObservedModes.Contains("Loader") ? "accessible" : ObservationCount == 0 ? "offlineOrUnauthorized" : "protocolBlocked";

    public string Responsibility => Verdict switch
    {
        "permissionDenied" => "systemAdministrator",
        "driverUnavailable" or "malformedOutput" or "probeFailed" => "deviceOrToolVendor",
        _ => "user",
    };

    public string Remediation => Verdict switch
    {
        "offlineOrUnauthorized" => "reconnectOrEnterLoader",
        "permissionDenied" => "reviewDevicePermissionOutsideArkDeck",
        "driverUnavailable" => "repairDriverOutsideArkDeck",
        "malformedOutput" or "probeFailed" => "inspectControlledDiagnostics",
        _ => "chooseSupportedLoaderObservation",
    };

    public static FlashDeviceAccess Parse(JsonValue value)
    {
        var o = Json.Object(value, "Rockchip device access");
        var modes = TypedJson.Required(o, "observedModes", v => TypedJson.List(v, TypedJson.String));
        if (modes.Any(m => m is not ("Loader" or "Maskrom"))) throw new ContractException(ContractErrorKind.SchemaMismatch, "an unknown RockUSB mode");
        return new((int)TypedJson.Required(o, "observationCount", TypedJson.Int64), modes);
    }
}

/// <summary>What <c>flash.bootloader-status</c> reports about a board in Loader mode and its binding.</summary>
public sealed record FlashBootloaderStatus(string Disposition, int ObservationCount, string? Mode, string? TargetId, long? BindingRevision)
{
    public static FlashBootloaderStatus? TryParse(JsonValue value)
    {
        if (value is not JsonObject o) return null;
        var disposition = Json.OptionalString(o, "disposition");
        if (disposition is not ("absent" or "ambiguous" or "exactBoundTarget" or "targetBindingUnprepared" or "unbound")) return null;
        if (!o.TryGetValue("observationCount", out var count) || count is not JsonNumber n || !n.TryGetInt64(out var observed)) return null;
        var mode = Json.NullableString(o, "mode");
        if (mode is not (null or "loader" or "hdcNormal")) return null;
        long? revision = o.TryGetValue("bindingRevision", out var r) && r is JsonNumber rn && rn.TryGetInt64(out var value2) ? value2 : null;
        return new(disposition, (int)observed, mode, Json.NullableString(o, "targetId"), revision);
    }
}

/// <summary>One profile prerequisite and what the Runtime last observed of it
/// (<c>satisfied</c>, <c>unsatisfied</c> or <c>unknown</c>; the App never upgrades unknown).</summary>
public sealed record FlashPrerequisiteState(string Identifier, string Requirement, string Status)
{
    public bool Blocks => Requirement == "required" && Status != "satisfied";
}

/// <summary>The ArkForge lane's advisory pre-materialization (<c>flash.lanePlanPreview</c>).</summary>
public sealed record FlashLanePreview(string State, string? Detail)
{
    public static readonly FlashLanePreview Pending = new("pending", null);
}

/// <summary>The reviewed plan: the archive's facts, the Target and binding it is for, the
/// prerequisites as observed, the Import lease and the Runtime's plan digest once the plan-only
/// preview passed, and the exact request that will be submitted.</summary>
public sealed record FlashPlan(
    FlashReviewedArchive Archive,
    TargetSummary Target,
    IReadOnlyList<FlashPrerequisiteState> Prerequisites,
    string? PlanDigest,
    RuntimeRequest? Request,
    string ArchivePath)
{
    public bool RuntimeAdmissionPreviewPassed => PlanDigest is not null;

    /// <summary>Required prerequisites not satisfied; none once the Runtime's plan-only
    /// preview passed (it re-probes them before any write).</summary>
    public IReadOnlyList<FlashPrerequisiteState> Blocking => RuntimeAdmissionPreviewPassed ? [] : Prerequisites.Where(p => p.Blocks).ToArray();
}

/// <summary>A preparation: the plan, or the local failure code and detail.</summary>
public sealed record FlashPreparation(FlashPlan? Plan, FlashReviewFailureCode? FailureCode, string? FailureDetail, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

/// <summary>A Flash Job's provider progress (<c>processProgress</c>).</summary>
public sealed record FlashProcessProgress(string StepId, string Phase, string? UnitName, int CompletedUnitCount, int TotalUnitCount, int? CurrentUnitPercent);

/// <summary>A Flash Job as <c>job.show</c> reads it: state, outcome, timeline and progress.</summary>
public sealed record FlashRunStatus(string JobId, string State, bool OutcomeUnknown, IReadOnlyList<string> Timeline, FlashProcessProgress? Progress)
{
    public bool IsLiveTerminal => OutcomeUnknown || FlashOperations.LiveTerminalStates.Contains(State);
}

public enum FlashPhase
{
    ImportingImage,
    ValidatingImage,
    EnteringBootloader,
    ExtractingImage,
    WritingPartition,
    VerifyingPartitions,
    RebootingDevice,
    ReconnectingDevice,
    VerifyingSystem,
}

/// <summary>The progress the page shows (macOS <c>FlashLiveProgressPresentation</c>).</summary>
public sealed record FlashLiveProgress(FlashPhase Phase, string? PartitionName = null, int? Completed = null, int? Total = null, int? CurrentPercent = null,
    double? WriteFraction = null)
{
    public int? WritePercent => WriteFraction is { } f ? Math.Clamp((int)Math.Floor(f * 100), 0, 100) : null;

    /// <summary>The prepare, write and verify stages (0, 1, 2).</summary>
    public int Stage => Phase switch
    {
        FlashPhase.WritingPartition => 1,
        FlashPhase.VerifyingPartitions or FlashPhase.RebootingDevice or FlashPhase.ReconnectingDevice or FlashPhase.VerifyingSystem => 2,
        _ => 0,
    };

    /// <summary>macOS <c>FlashLiveProgressProjector.project</c>.</summary>
    public static FlashLiveProgress Project(FlashRunStatus? status, IReadOnlyList<FlashPartitionRow> partitions)
    {
        if (status is null) return new(FlashPhase.ImportingImage);
        var steps = FlashOperations.CatalogReview.Value.Steps;
        if (status.Progress is { } progress && steps.FirstOrDefault(s => s.Id == progress.StepId)?.Kind == "flashPartition")
        {
            if (progress.Phase == "staging") return new(FlashPhase.ExtractingImage);
            return new(FlashPhase.WritingPartition, progress.UnitName, progress.CompletedUnitCount, progress.TotalUnitCount, progress.CurrentUnitPercent,
                Fraction(progress, partitions));
        }
        FlashStep? latest = null;
        for (var i = status.Timeline.Count - 1; i >= 0 && latest is null; i--)
        {
            latest = steps.FirstOrDefault(s => status.Timeline[i].Contains(s.Id, StringComparison.Ordinal));
        }
        var index = latest is null ? -1 : steps.ToList().IndexOf(latest);
        var overwrite = steps.ToList().FindIndex(s => s.Kind == "flashPartition");
        if (latest is null || overwrite < 0) return new(FlashPhase.ValidatingImage);
        return new(latest.Kind switch
        {
            "verifyArtifact" or "hashFile" or "requestConfirmation" => FlashPhase.ValidatingImage,
            "enterUpdater" or "waitForDisconnect" => FlashPhase.EnteringBootloader,
            "waitForReconnect" => index < overwrite ? FlashPhase.EnteringBootloader : FlashPhase.ReconnectingDevice,
            "probeDevice" => index < overwrite ? FlashPhase.EnteringBootloader : FlashPhase.VerifyingSystem,
            "flashPartition" => FlashPhase.ExtractingImage,
            "verifyRemoteState" => FlashPhase.VerifyingPartitions,
            "rebootDevice" => FlashPhase.RebootingDevice,
            "captureRemoteStdout" or "finalizeSession" => FlashPhase.VerifyingSystem,
            _ => index < overwrite ? FlashPhase.ValidatingImage : FlashPhase.VerifyingSystem,
        });
    }

    private static double Fraction(FlashProcessProgress progress, IReadOnlyList<FlashPartitionRow> partitions)
    {
        var current = (progress.CurrentUnitPercent ?? 0) / 100.0;
        var ordered = partitions.OrderBy(p => p.WriteOrder).ToArray();
        if (ordered.Length == progress.TotalUnitCount && progress.CompletedUnitCount == progress.TotalUnitCount) return 1;
        if (ordered.Length == progress.TotalUnitCount && progress.CompletedUnitCount < ordered.Length
            && ordered[progress.CompletedUnitCount].PartitionName == progress.UnitName)
        {
            var total = ordered.Sum(p => p.ImageSizeBytes);
            if (total <= 0) return 0;
            var done = ordered.Take(progress.CompletedUnitCount).Sum(p => p.ImageSizeBytes);
            return Math.Min(1, (done + ordered[progress.CompletedUnitCount].ImageSizeBytes * current) / total);
        }
        return Math.Min(1, (progress.CompletedUnitCount + current) / progress.TotalUnitCount);
    }
}

/// <summary>The Flash workspace: the operation's availability, the adopted Targets, the RockUSB
/// device access and bootloader status, and the Flash Jobs of the shared History.</summary>
public sealed record FlashState(
    OperationFacts Operation,
    Loaded<IReadOnlyList<TargetSummary>> Targets,
    Loaded<FlashDeviceAccess> DeviceAccess,
    FlashBootloaderStatus? Bootloader,
    Loaded<IReadOnlyList<RecentJob>> Jobs,
    FlashRunStatus? FocusedStatus,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached)
{
    /// <summary>The focused Flash Job (macOS <c>focusedFlashActivity</c>): outcome unknown,
    /// waiting for a person, needing recovery, active, else the newest.</summary>
    public RecentJob? Focused
    {
        get
        {
            var flash = (Jobs.Value ?? []).Where(j => FlashOperations.JobOperations.Contains(j.Operation)).ToArray();
            return flash.FirstOrDefault(j => j.OutcomeUnknown) ?? flash.FirstOrDefault(j => j.WaitingForHuman)
                ?? flash.FirstOrDefault(j => j.State is "waitingForRecovery" or "awaitingRebindConfirmation" or "userAbandonRequested")
                ?? flash.FirstOrDefault(j => j.IsActive) ?? flash.FirstOrDefault();
        }
    }

    public int FlashJobCount => (Jobs.Value ?? []).Count(j => FlashOperations.JobOperations.Contains(j.Operation));
}

public sealed partial class SurfaceLoader
{
    /// <summary>The Flash workspace (macOS <c>refresh</c>): device access, the operation's
    /// availability, the Targets, the bootloader status, the Flash Jobs (with the current one)
    /// and the focused Job's status.</summary>
    public async Task<FlashState> FlashAsync()
    {
        var run = new Run(channel);
        var access = await run.Load(c => c.RequestAsync("flash.device-access", Params()), FlashDeviceAccess.Parse, CliCommands.FlashDeviceAccess);
        OperationFacts operation;
        try
        {
            operation = (await OperationsAsync(channel, [FlashOperations.Reference]).ConfigureAwait(false))[0];
        }
        catch (ControlClientException error) when (error.Failure.ShowsRecoveryBanner)
        {
            operation = OperationFacts.Unread(FlashOperations.Reference, [error.Failure.Message]);
        }
        var targets = await run.Load(c => c.RequestAsync("target.list"), TargetSummary.ParseAll, CliCommands.TargetList);
        var bootloader = await run.Load(c => c.RequestAsync("flash.bootloader-status", Params()), v => FlashBootloaderStatus.TryParse(v) ?? throw new ContractException(ContractErrorKind.SchemaMismatch, "an invalid bootloader status"),
            CliCommands.FlashBootloaderStatus);
        var jobs = await run.Load(c => c.RequestAsync("job.list", Params(("includeCurrent", JsonBool.True), ("includeTimeline", JsonBool.False),
            ("order", new JsonString("createdAtDescJobIdAsc")), ("pageSize", JsonNumber.FromInt64(200)))), RecentJob.ParsePage, CliCommands.JobList);
        FlashRunStatus? focused = null;
        var state = new FlashState(operation, targets, access, bootloader.Value, jobs, null, run.DaemonFailure, run.Reached);
        if (state.Focused is { } job) focused = (await FlashStatusAsync(job.JobId).ConfigureAwait(false)).Answer.Value;
        return state with { FocusedStatus = focused };
    }

    /// <summary>
    /// Prepares the exact plan (macOS <c>preparePlan</c>): the host review of the archive
    /// (<see cref="FlashArchive.Review"/>), the Runtime's prerequisite observations (on failure
    /// every one stays unknown), the archive imported as a flash bundle for its lease, then the
    /// typed request planned (<c>job.plan</c>) and checked to be exactly the review: plan only,
    /// the ArkForge provider, destructive, the Target and binding, the review's inputs and steps.
    /// </summary>
    public async Task<FlashPreparation> PrepareFlashAsync(string archive, TargetSummary target, CancellationToken cancellation)
    {
        var review = await Task.Run(() => FlashArchive.Review(archive, FlashOperations.ProfileReference), cancellation).ConfigureAwait(false);
        if (review.Reviewed is not { } reviewed) return new(null, review.FailureCode, review.FailureDetail, null, false);
        var run = new Run(channel);
        var observed = await run.Load(c => c.RequestAsync("flash.prerequisites",
                Params(("profileReference", new JsonString(FlashOperations.ProfileReference)), ("targetId", new JsonString(target.TargetId)))),
            v => ParsePrerequisites(v, target), CliCommands.FlashPrerequisites);
        var prerequisites = reviewed.Prerequisites.Select(p => new FlashPrerequisiteState(p.Identifier, p.Requirement,
            observed.Value?.GetValueOrDefault(p.Identifier) ?? "unknown")).ToArray();
        FlashPreparation Failed(string detail) =>
            new(new FlashPlan(reviewed, target, prerequisites, null, null, archive), FlashReviewFailureCode.PlanMaterializationFailed, detail, run.DaemonFailure, run.Reached);

        var imported = await new ImportUploader(channel).UploadAsync(archive, ImportKind.FlashBundle, target, null, cancellation, name: "images.tar.gz").ConfigureAwait(false);
        if (imported.Cancelled) return Failed("The image upload was cancelled");
        if (imported.Failure is { } refused) return Failed(refused.Detail) with { DaemonFailure = imported.DaemonFailure ?? run.DaemonFailure };
        if (imported.Committed?.Receipt?.Lease is not { Length: > 0 } lease) return Failed("Runtime returned no Flash image lease");
        var request = RuntimeRequest.Build("flash-ui", "flash.full-restore", 1, target.TargetId, target.BindingRevision,
        [
            ("artifactLease", new JsonString(lease)),
            ("deviceProfileRef", new JsonString(FlashOperations.ProfileReference)),
            ("intent", new JsonString("fullRestore")),
            ("verification", new JsonString("full")),
        ], ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], FlashOperations.Client);
        var planned = await PlanAsync(request, CliCommands.FlashPlan).ConfigureAwait(false);
        if (planned.Answer.Unavailable is { } why) return Failed($"{why.ReasonCode}: {why.Detail}") with { DaemonFailure = planned.DaemonFailure };
        var plan = planned.Answer.Value!;
        if (plan.AdmissionBlocker is { Length: > 0 } blocker) return Failed(blocker);
        var catalog = FlashOperations.CatalogReview.Value;
        string? Input(string key) => Json.OptionalString(plan.Inputs, key);
        var matches = plan.Operation == FlashOperations.Reference && plan.ProviderId == "arkforge" && plan.EffectiveEffect == "destructive"
                      && plan.BindingRevision == target.BindingRevision && Input("artifactLease") == lease && Input("deviceProfileRef") == FlashOperations.ProfileReference
                      && Input("intent") == "fullRestore" && Input("verification") == "full"
                      && plan.Steps.Select(s => (s.Id, s.Kind, s.Effect)).SequenceEqual(catalog.Steps.Select(s => (s.Id, s.Kind, s.Effect)));
        if (!matches) return Failed("Runtime plan facts no longer match the reviewed image, target and steps");
        return new(new FlashPlan(reviewed, target, prerequisites, plan.PlanDigest, request.Reviewed(plan.PlanDigest), archive), null, null, planned.DaemonFailure, true);
    }

    private static IReadOnlyDictionary<string, string> ParsePrerequisites(JsonValue value, TargetSummary target)
    {
        var o = Json.Object(value, "Flash prerequisites");
        if (TypedJson.Required(o, "targetId", TypedJson.String) != target.TargetId
            || TypedJson.Required(o, "profileReference", TypedJson.String) != FlashOperations.ProfileReference)
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "prerequisites of another Target or profile");
        }
        return TypedJson.Required(o, "observations", v => TypedJson.List(v, row =>
        {
            var observation = Json.Object(row, "a prerequisite observation");
            var status = TypedJson.Required(observation, "status", TypedJson.String);
            if (status is not ("satisfied" or "unsatisfied" or "unknown")) throw new ContractException(ContractErrorKind.SchemaMismatch, "an unknown prerequisite status");
            return (Id: TypedJson.Required(observation, "identifier", TypedJson.String), Status: status);
        })).ToDictionary(p => p.Id, p => p.Status, StringComparer.Ordinal);
    }

    /// <summary>The ArkForge lane's advisory pre-materialization (<c>flash.lanePlanPreview</c>).</summary>
    public async Task<FlashLanePreview> FlashLanePreviewAsync(TargetSummary target, string archiveSha256)
    {
        var result = await channel.RequestAsync("flash.lanePlanPreview", Params(("archiveSha256", new JsonString(archiveSha256)),
            ("profileReference", new JsonString(FlashOperations.ProfileReference)), ("targetId", new JsonString(target.TargetId)))).ConfigureAwait(false);
        if (result.Failure is { } failure) return new("unavailable", failure.Message);
        if (result.Value is not JsonObject o) return new("unavailable", "Runtime returned no preview state");
        return Json.OptionalString(o, "state") switch
        {
            "available" when Json.OptionalString(o, "planSha256") is { } digest => new("available", digest),
            "bundleNotInLaneStore" => new("bundleNotInLaneStore", null),
            "laneNotComposed" => new("laneNotComposed", null),
            "deviceNotObserved" => new("deviceNotObserved", Json.OptionalString(o, "reason")),
            "planNotExecutable" => new("planNotExecutable", Json.OptionalString(o, "reason")),
            "previewFailed" => new("unavailable", Json.OptionalString(o, "reason") ?? "preview failed"),
            { } other => new("unavailable", "Runtime returned an unknown preview state: " + other),
            null => new("unavailable", "Runtime returned no preview state"),
        };
    }

    /// <summary>Binds the board in Loader mode to the selected Target before a submission
    /// (<c>flash.bind-current-loader</c>): the Target with its new binding revision.</summary>
    public async Task<(TargetSummary? Target, string? Failure)> BindLoaderAsync(TargetSummary target)
    {
        var bound = await Action("flash.bind-current-loader", Params(("expectedBindingRevision", JsonNumber.FromInt64(target.BindingRevision)),
            ("targetId", new JsonString(target.TargetId))), v => Json.Object(v, "a Loader binding"), CliCommands.FlashBindLoader).ConfigureAwait(false);
        if (bound.Answer.Unavailable is { } why) return (null, why.Detail);
        var o = bound.Answer.Value!;
        var revision = TypedJson.Required(o, "bindingRevision", TypedJson.Int64);
        if (Json.OptionalString(o, "targetId") != target.TargetId || TypedJson.Required(o, "previousBindingRevision", TypedJson.Int64) != target.BindingRevision
            || revision - target.BindingRevision is not (0 or 1) || Json.OptionalString(o, "selectionEvidenceSha256") is not { } evidence
            || !FlashOperations.Sha256().IsMatch(evidence))
        {
            return (null, "Runtime returned incomplete Loader binding facts");
        }
        return (target with { BindingRevision = revision }, null);
    }

    /// <summary>Submits the reviewed plan exactly as reviewed (the plan digest pinned).</summary>
    public async Task<SubmitOutcome> SubmitFlashAsync(FlashPlan plan)
    {
        if (plan.Request is not { } request || !plan.RuntimeAdmissionPreviewPassed)
        {
            return SubmitOutcome.Refused("Only a bound execute plan can be submitted", CliCommands.FlashRun);
        }
        return SubmitOutcome.From(await SubmitAsync(request, CliCommands.FlashRun).ConfigureAwait(false));
    }

    /// <summary>A Flash Job's status as <c>job.show</c> reads it (the live progress polls this).</summary>
    public async Task<SessionActionState<FlashRunStatus>> FlashStatusAsync(string jobId)
    {
        var cli = CliCommands.ForJob(CliCommands.JobStatus, jobId);
        var terminal = await ShowJobAsync(jobId, cli).ConfigureAwait(false);
        return terminal;
    }

    /// <summary>Runs the admitted Flash Job to its end (<c>job.run</c>, once), then reads it.</summary>
    public async Task<SessionActionState<FlashRunStatus>> RunFlashAsync(string jobId)
    {
        var cli = CliCommands.ForJob(CliCommands.JobRun, jobId);
        var ran = await Action("job.run", Params(("jobId", new JsonString(jobId))), v => Json.Object(v, "a Job status"), cli).ConfigureAwait(false);
        if (ran.Answer.Unavailable is { } refused) return new(Loaded<FlashRunStatus>.Not(refused), ran.DaemonFailure, ran.Reached);
        return await ShowJobAsync(jobId, cli).ConfigureAwait(false);
    }

    /// <summary>The postflight proof of a finished Flash (<c>job.evidence</c>).</summary>
    public Task<SessionActionState<JobEvidenceFacts>> FlashEvidenceAsync(string jobId) =>
        Action("job.evidence", Params(("jobId", new JsonString(jobId))), JobEvidenceFacts.Parse, CliCommands.ForJob(CliCommands.JobEvidence, jobId));

    private async Task<SessionActionState<FlashRunStatus>> ShowJobAsync(string jobId, string cli)
    {
        var shown = await ShowAsync(jobId, cli).ConfigureAwait(false);
        if (shown.Answer.Unavailable is { } why) return new(Loaded<FlashRunStatus>.Not(why), shown.DaemonFailure, shown.Reached);
        var (terminal, status) = shown.Answer.Value!;
        return new(Loaded<FlashRunStatus>.Of(new FlashRunStatus(jobId, terminal.State, terminal.OutcomeUnknown, terminal.Timeline, Progress(status))),
            shown.DaemonFailure, shown.Reached);
    }

    /// <summary>The provider progress a Flash status carries, or none when it is absent or not
    /// a valid observation (macOS <c>decodeProcessProgress</c>).</summary>
    private static FlashProcessProgress? Progress(JsonObject status)
    {
        if (!status.TryGetValue("processProgress", out var raw) || raw is not JsonObject p) return null;
        var step = Json.OptionalString(p, "stepId");
        var phase = Json.OptionalString(p, "phase");
        if (string.IsNullOrEmpty(step) || phase is null
            || !p.TryGetValue("completedUnitCount", out var c) || c is not JsonNumber cn || !cn.TryGetInt64(out var completed)
            || !p.TryGetValue("totalUnitCount", out var t) || t is not JsonNumber tn || !tn.TryGetInt64(out var total)
            || total <= 0 || completed < 0 || completed > total)
        {
            return null;
        }
        var unit = Json.NullableString(p, "unitName");
        int? percent = p.TryGetValue("currentUnitPercent", out var u) && u is JsonNumber un && un.TryGetInt64(out var value) ? (int)value : null;
        if (unit is { Length: 0 } || percent is < 0 or > 100) return null;
        return new FlashProcessProgress(step, phase, unit, (int)completed, (int)total, percent);
    }
}
