using System.Globalization;
using System.Text;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

public sealed record DeviceScreenGate(DeviceScreenTarget? Target, IReadOnlyList<OperationFacts> Operations, string? Refusal, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached)
{
    public string? RefusalFor(string operation) => Refusal ?? (Operations.SingleOrDefault(o => o.Reference == operation) is { IsAvailable: true }
        ? null : string.Join(", ", Operations.FirstOrDefault(o => o.Reference == operation)?.Availability.Reasons ?? ["Operation availability is unreadable"]));
}

public sealed record DeviceCaptureOutcome(DeviceScreenFrame? Frame, string? Failure, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

public static class DeviceOperations
{
    public const string Client = "ArkDeckApp.Toolkit.DeviceControl";
    public const string Capture = "capture.diagnostics@1";
    public const string Recording = "capture.screen-sequence@1";
    public static readonly IReadOnlyList<string> All = [Capture, "input.tap@1", "input.long-press@1", "input.swipe@1", "input.keyboard@1", Recording];
    public const string CaptureCli = "arkdeck screen capture --target <target-id>";
    public const string InputCli = "arkdeck input ... --target <target-id>";
    public const string RecordingCli = "arkdeck screen record --target <target-id> --frames <count>";

    public static TimeSpan? RunCallBudget(OperationFacts descriptor, string operation) => All.Contains(operation) && descriptor.Reference == operation
        && descriptor.IsAvailable && descriptor.TimeoutSeconds is >= 1 and <= 900
        ? TimeSpan.FromSeconds(descriptor.TimeoutSeconds) + DaemonConfiguration.CallBudget : null;

    public static RuntimeRequest Screenshot(DeviceScreenTarget target) => RuntimeRequest.Build("toolkit-screen", "capture.diagnostics", 1, target.TargetId, target.BindingRevision,
    [
        ("durationSeconds", JsonNumber.FromInt64(1)), ("captureHilog", JsonBool.False), ("hilogFilters", new JsonArray([])),
        ("uiDump", JsonBool.False), ("crashLogs", JsonBool.False), ("uiScreenshot", JsonBool.True), ("uiComponentTree", JsonBool.False),
        ("redactionProfile", new JsonString("standard")),
    ], ["rawArtifacts", "hardwareEvidence"], Client);

    public static RuntimeRequest Gesture(DeviceScreenTarget target, DeviceGestureRequest gesture)
    {
        if (!gesture.IsValid) throw new ArgumentException("Gesture is outside its published coordinate or duration bounds");
        return RuntimeRequest.Build("toolkit-input", gesture.Gesture == DeviceGesture.Tap ? "input.tap" : gesture.Gesture == DeviceGesture.LongPress ? "input.long-press" : "input.swipe",
            1, target.TargetId, target.BindingRevision, gesture.Inputs, ["hardwareEvidence"], Client);
    }

    internal static bool StatusMatches(JobShown shown, string jobId, DeviceScreenTarget target, string operation, bool requireSuccess)
    {
        var status = shown.Status;
        return Json.OptionalString(status, "jobId") == jobId && Json.OptionalString(status, "targetId") == target.TargetId
            && Json.OptionalString(status, "operation") == operation && !shown.Terminal.OutcomeUnknown
            && status.TryGetValue("waitingForHuman", out var human) && human is JsonBool { Value: false }
            && status.TryGetValue("outstandingResidueCount", out var residue) && residue is JsonNumber n && n.TryGetInt64(out var count) && count == 0
            && (!requireSuccess || shown.Terminal.Succeeded);
    }

    internal static bool AcceptedRequest(JsonObject document, RuntimeRequest request, string jobId, DeviceScreenTarget target, string operation)
        => RequestMatches(document, request, jobId, target, operation) && Json.OptionalString((JsonObject)document["job"], "state") is "queued" or "preflight";

    // Rust OperationRequest.canonical_value omits nil fields and stores this whole typed
    // request. Compare JSON values, including outputs/client provenance, rather than text
    // spelling or a selected subset. No extra or missing field may authorize a run.
    internal static bool RequestMatches(JsonObject document, RuntimeRequest request, string jobId, DeviceScreenTarget target, string operation)
    {
        var expected = (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(request.Json));
        if (Json.OptionalString(document, "schemaVersion") != "arkdeck.job/1" || document["request"] is not JsonObject stored || document["job"] is not JsonObject status) return false;
        return Json.OptionalString(status, "jobId") == jobId && Json.OptionalString(status, "operation") == operation && Json.OptionalString(status, "targetId") == target.TargetId
            && status["outcomeUnknown"] is JsonBool { Value: false }
            && status["waitingForHuman"] is JsonBool { Value: false } && TypedJson.Int64(status["outstandingResidueCount"]) == 0
            && document["materializedBindingRevision"] is JsonNumber revision && revision.TryGetInt64(out var bound) && bound == target.BindingRevision
            && Json.OptionalString(document, "materializedStableIdentitySha256") == target.StableIdentitySha256
            && Json.OptionalString(document, "catalogDigest") is { } catalog && ArtifactSummary.IsSha256(catalog)
            && Json.OptionalString(document, "materializedPlanDigest") is { } plan && ArtifactSummary.IsSha256(plan)
            && Json.OptionalString(document, "providerId") == "hdc" && stored.Equals(expected);
    }
}

internal sealed record DeviceProduct(ArtifactSummary Artifact, string TargetId, long Revision, string Identity)
{
    public static DeviceProduct Parse(JsonValue value)
    {
        var row = Json.Object(value, "a Device Artifact");
        var binding = TypedJson.Required(row, "binding", v => Json.Object(v, "an Artifact binding"));
        return new(ArtifactSummary.Parse(row), TypedJson.Required(binding, "targetId", TypedJson.String),
            TypedJson.Required(binding, "bindingRevision", TypedJson.Int64), TypedJson.Required(binding, "stableIdentitySha256", TypedJson.String));
    }
    public bool Matches(string jobId, DeviceScreenTarget target, string operation, string privacy = "sensitive") => Artifact.OwnerKind == "job" && Artifact.OwnerId == jobId
        && Artifact.SourceOperation == operation && Artifact.ProviderId == "hdc" && Artifact.IsPublished && Artifact.Privacy == privacy
        && Artifact.ByteCount > 0 && TargetId == target.TargetId && Revision == target.BindingRevision && Identity == target.StableIdentitySha256;
}

public sealed partial class SurfaceLoader
{
    /// <summary>Fresh public projections, not an authorization decision. Runtime still owns capability and dispatch.</summary>
    public async Task<DeviceScreenGate> DeviceScreenGateAsync(string? targetId, DeviceScreenTarget? expected = null)
    {
        var state = await DeviceAsync().ConfigureAwait(false);
        var facts = await OperationsAsync(channel, DeviceOperations.All).ConfigureAwait(false);
        if ((state.Targets.Unavailable ?? state.Candidates.Unavailable) is { } failure) return new(null, facts, failure.Detail, state.DaemonFailure, state.Reached);
        var targets = state.Targets.Value!;
        if (targetId is null && targets.Count == 1) targetId = targets[0].TargetId;
        var targetsHere = targets.Where(t => t.TargetId == targetId).ToArray();
        if (targetsHere.Length != 1) return new(null, facts, "Choose exactly one adopted Target; a device is never guessed", state.DaemonFailure, true);
        var routes = state.Candidates.Value!.Where(c => c.AdoptedTargetId == targetId).ToArray();
        if (routes is not [{ AuthorizationState: "Connected", Stale: false } route] || route.BindingRevision != targetsHere[0].BindingRevision)
            return new(null, facts, "The adopted Target has no unique current Connected binding", state.DaemonFailure, true);
        var details = await TargetAsync(targetId!).ConfigureAwait(false);
        if (details.Detail.Value is not { } detail || DeviceScreenTarget.Of(detail) is not { } target || target.BindingRevision != targetsHere[0].BindingRevision)
            return new(null, facts, details.Detail.Unavailable?.Detail ?? "The Target identity or binding changed", details.DaemonFailure, details.Reached);
        if (details.Availability.Value is not { BindingState: "ready" } availability || availability.TargetId != target.TargetId)
            return new(null, facts, "The adopted Target binding is not ready", details.DaemonFailure, details.Reached);
        if (expected is not null && !target.SameBinding(expected)) return new(null, facts, "The Target identity or binding changed; capture a new picture", details.DaemonFailure, true);
        return new(target, facts, null, details.DaemonFailure, true);
    }

    public async Task<DeviceCaptureOutcome> CaptureDeviceScreenAsync(DeviceScreenTarget target)
    {
        var gate = await DeviceScreenGateAsync(target.TargetId, target).ConfigureAwait(false);
        if (gate.RefusalFor(DeviceOperations.Capture) is { } refusal) return new(null, refusal, gate.DaemonFailure, gate.Reached);
        var execution = await ExecuteDeviceOnceAsync(DeviceOperations.Screenshot(target), target, DeviceOperations.Capture, gate).ConfigureAwait(false);
        if (execution.Shown is null || !execution.Shown.Terminal.Succeeded) return new(null, execution.Detail, execution.Failure, true);
        return await ReadDeviceFrameAsync(execution.Shown, target, historical: false).ConfigureAwait(false);
    }

    /// <summary>Reads a historical immutable capture; no submit/run, and no current-input liveness.</summary>
    public async Task<DeviceCaptureOutcome> LoadDeviceHistoryAsync(HistoryWorkspaceContext context)
    {
        if (context.OperationReference != DeviceOperations.Capture || string.IsNullOrEmpty(context.JobId) || string.IsNullOrEmpty(context.TargetId))
            return new(null, "The historical record is not a screenshot capture", null, false);
        var shown = await ShowAsync(context.JobId, DeviceOperations.CaptureCli).ConfigureAwait(false);
        if (shown.Answer.Value is not { Document: { } document } job) return new(null, "The historical capture could not be read", shown.DaemonFailure, shown.Reached);
        try
        {
            var revision = TypedJson.Required(document, "materializedBindingRevision", TypedJson.Int64);
            var identity = TypedJson.Required(document, "materializedStableIdentitySha256", TypedJson.String);
            if (context.BindingRevision is { } old && revision != old || revision < 1 || !ArtifactSummary.IsSha256(identity)) throw new InvalidDataException("The historical capture binding is unreadable");
            var target = new DeviceScreenTarget(context.TargetId, revision, identity, context.TargetId);
            if (!DeviceOperations.StatusMatches(job, context.JobId, target, DeviceOperations.Capture, requireSuccess: true))
                return new(null, "The historical screenshot Job is not a confirmed capture", shown.DaemonFailure, shown.Reached);
            return await ReadDeviceFrameAsync(job, target, historical: true).ConfigureAwait(false);
        }
        catch (Exception error) when (DeviceReadError(error)) { return new(null, "The historical screenshot identity is unreadable", null, true); }
    }

    public async Task<DeviceInputOutcome> SendDeviceGestureAsync(DeviceScreenTarget target, DeviceGestureRequest gesture)
    {
        if (!gesture.IsValid) return new(DeviceInputVerdict.Failed, null, "Gesture is outside the published bounds");
        var gate = await DeviceScreenGateAsync(target.TargetId, target).ConfigureAwait(false);
        if (gate.RefusalFor(gesture.OperationId + "@1") is { } refusal) return new(DeviceInputVerdict.Failed, null, refusal, gate.DaemonFailure);
        return InputOutcome(await ExecuteDeviceOnceAsync(DeviceOperations.Gesture(target, gesture), target, gesture.OperationId + "@1", gate).ConfigureAwait(false), "inject-pointer-input");
    }

    public async Task<DeviceInputOutcome> SendDeviceKeyboardAsync(DeviceScreenTarget target, DeviceKeyboardCommand command)
    {
        if (!command.IsValid) return new(DeviceInputVerdict.Failed, null, "Keyboard input requires bounded text and clipboard consent");
        var gate = await DeviceScreenGateAsync(target.TargetId, target).ConfigureAwait(false);
        if (gate.RefusalFor("input.keyboard@1") is { } refusal) return new(DeviceInputVerdict.Failed, null, refusal, gate.DaemonFailure);
        var epoch = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        var lease = await new DeviceKeyboardUpload(channel).UploadAsync(command, target).ConfigureAwait(false);
        if (lease is null) return new(DeviceInputVerdict.Failed, null, "Private keyboard upload was not confirmed; no input Job was submitted");
        var request = RuntimeRequest.Build("toolkit-keyboard", "input.keyboard", 1, target.TargetId, target.BindingRevision,
            [("keyboardArtifactLease", new JsonString(lease)), ("inputEpochUtc", new JsonString(epoch))], ["hardwareEvidence"], DeviceOperations.Client);
        var execution = await ExecuteDeviceOnceAsync(request, target, "input.keyboard@1", gate).ConfigureAwait(false);
        // Arbitrary service text must never expose uploaded private input.
        var outcome = InputOutcome(execution, "inject-keyboard-input");
        const string privateFailure = "Private keyboard outcome was not confirmed; inspect its Job";
        return outcome with { DaemonFailure = outcome.DaemonFailure is { } failure ? failure with
            { Message = privateFailure, Remote = failure.Remote is null ? null : new WireError("privateInputUnconfirmed", privateFailure, null) } : null,
            Detail = outcome.Verdict == DeviceInputVerdict.Confirmed
            ? "Injector accepted the keyboard input; this does not prove the application reacted" : outcome.Verdict == DeviceInputVerdict.Unknown
                ? "Keyboard outcome is unresolved; it is never resent" : "Keyboard input was not confirmed; inspect its Job" };
    }

    private static DeviceInputOutcome InputOutcome(DeviceExecution execution, string step)
    {
        var job = execution.Shown;
        var verdict = execution.Unknown ? DeviceInputVerdict.Unknown : job?.Terminal.Succeeded == true
            && job.Terminal.Timeline.Any(t => t.StartsWith("verified " + step + " ", StringComparison.Ordinal)) ? DeviceInputVerdict.Confirmed
            : job?.Terminal.Succeeded == true ? DeviceInputVerdict.Unknown : DeviceInputVerdict.Failed;
        return new(verdict, execution.JobId, verdict == DeviceInputVerdict.Confirmed ? "Injector accepted the input; this does not prove the application reacted" : execution.Detail, execution.Failure);
    }

    private sealed record DeviceExecution(string? JobId, JobShown? Shown, bool Unknown, string Detail, ControlFailure? Failure);

    /// <summary>One submit and one run. Lost/invalid replies never grant a second run.</summary>
    private async Task<DeviceExecution> ExecuteDeviceOnceAsync(RuntimeRequest request, DeviceScreenTarget target, string operation, DeviceScreenGate gate)
    {
        var descriptors = gate.Operations.Where(f => f.Reference == operation).ToArray();
        if (descriptors is not [var descriptor] || DeviceOperations.RunCallBudget(descriptor, operation) is not { } callBudget || channel is not IRuntimeJobChannel runChannel)
            return new(null, null, false, "The matching published operation deadline or bounded Job channel is unavailable", null);
        string? jobId = null;
        try
        {
            var submitted = await channel.RequestAsync("job.submit", Params(("requestJson", new JsonString(request.Json)))).ConfigureAwait(false);
            if (submitted.Failure is { } refused) return new(null, null, refused.Kind is ControlFailureKind.OutcomeUnknown or ControlFailureKind.ConnectionUnusable,
                "Runtime did not confirm submission; the request is never resent", refused);
            var acceptance = Json.Object(submitted.Value!, "a Device acceptance");
            jobId = JobAcceptance.Parse(acceptance).JobId;
            if (acceptance["deduplicated"] is not JsonBool { Value: false } || TypedJson.Int64(acceptance["newDispatchCount"]) != 0)
                return new(jobId, null, true, "Runtime did not confirm a new input intent; inspect History", null);
            var accepted = await channel.RequestAsync("job.show", Params(("jobId", new JsonString(jobId)))).ConfigureAwait(false);
            var acceptedDocument = accepted.Failure is null ? Json.Object(accepted.Value!, "the accepted Device Job") : null;
            if (acceptedDocument is null || !DeviceOperations.AcceptedRequest(acceptedDocument, request, jobId, target, operation))
                return new(jobId, null, true, "The accepted Device request could not be confirmed; no run was sent", accepted.Failure);
            var ran = await runChannel.RunJobOnceAsync(jobId, callBudget).ConfigureAwait(false);
            var shown = await ShowAsync(jobId, DeviceOperations.InputCli).ConfigureAwait(false);
            if (shown.Answer.Value is not { } terminal || !DeviceOperations.StatusMatches(terminal, jobId, target, operation, requireSuccess: false)
                || !JobSummary.TerminalStates.Contains(terminal.Terminal.State) || terminal.Document is not { } finalDocument
                || !DeviceOperations.RequestMatches(finalDocument, request, jobId, target, operation)
                || !new[] { "catalogDigest", "providerId", "materializedPlanDigest", "materializedBindingRevision", "materializedStableIdentitySha256" }
                    .All(k => finalDocument[k].Equals(acceptedDocument[k])))
                return new(jobId, null, true, "The Device outcome is unresolved; inspect History, never resend", shown.DaemonFailure ?? ran.Failure);
            return new(jobId, terminal, false, terminal.Terminal.Succeeded ? "Completed" : terminal.Terminal.FailureCode ?? terminal.Terminal.State, shown.DaemonFailure);
        }
        catch (Exception error) when (DeviceReadError(error)) { return new(jobId, null, true, "The Device reply was invalid; inspect History, never resend", null); }
    }

    private async Task<DeviceCaptureOutcome> ReadDeviceFrameAsync(JobShown job, DeviceScreenTarget target, bool historical)
    {
        try
        {
            var rows = await DeviceProductsAsync(job.Terminal.JobId).ConfigureAwait(false);
            var screenshots = rows.Where(r => r.Artifact.Name is "screenshot.png" or "screenshot.jpeg").ToArray();
            if (screenshots is not [var source] || !source.Matches(job.Terminal.JobId, target, DeviceOperations.Capture)
                || source.Artifact.ByteCount > DeviceScreenImages.MaximumBytes
                || source.Artifact.MediaType != (source.Artifact.Name.EndsWith(".png", StringComparison.Ordinal) ? "image/png" : "image/jpeg"))
                return new(null, "The capture has no unique verified same-Job screenshot", null, true);
            var read = await new ArtifactExporter(channel).ReadAsync(job.Terminal.JobId, source.Artifact, allowSensitive: true).ConfigureAwait(false);
            if (read.Bytes is null) return new(null, "The complete screenshot digest could not be verified", read.Failure?.Failure, true);
            var size = DeviceScreenImages.Dimensions(read.Bytes);
            return new(new(read.Bytes, size.Width, size.Height, job.Terminal.JobId, source.Artifact.ArtifactId, source.Artifact.Digest!, target,
                Json.OptionalString(job.Status, "finishedAtUtc") ?? source.Artifact.CreatedAtUtc, historical), null, null, true);
        }
        catch (Exception error) when (DeviceReadError(error)) { return new(null, "The published screenshot is unreadable: " + error.Message, null, true); }
    }

    private async Task<IReadOnlyList<DeviceProduct>> DeviceProductsAsync(string jobId)
    {
        var rows = new List<DeviceProduct>();
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null, revision = null;
        for (var page = 0; page < ArtifactPageLimit; page++)
        {
            var parameters = cursor is null ? Params(("owner", JobOwner(jobId)), ("pageSize", JsonNumber.FromInt64(ArtifactPageSize)))
                : Params(("owner", JobOwner(jobId)), ("pageSize", JsonNumber.FromInt64(ArtifactPageSize)), ("cursor", new JsonString(cursor)));
            var result = await channel.RequestAsync("artifact.list", parameters).ConfigureAwait(false);
            if (result.Failure is not null) throw new InvalidDataException("Artifact inventory was refused");
            var value = Json.Object(result.Value!, "a Device Artifact page");
            _ = ArtifactSummary.ParsePage(value, jobId);
            var snapshot = TypedJson.Required(value, "snapshotRevision", TypedJson.String);
            if (revision is not null && revision != snapshot) throw new InvalidDataException("Artifact inventory snapshot changed");
            revision = snapshot;
            foreach (var row in TypedJson.Required(value, "items", v => TypedJson.List(v, DeviceProduct.Parse)))
            {
                if (!ids.Add(row.Artifact.ArtifactId)) throw new InvalidDataException("Artifact inventory repeated a product");
                rows.Add(row);
            }
            cursor = Json.NullableString(value, "nextCursor");
            if (cursor is null) return rows;
            if (!cursors.Add(cursor)) throw new InvalidDataException("Artifact inventory repeated a cursor");
        }
        throw new InvalidDataException("Artifact inventory exceeded its bounded page count");
    }

    private static bool DeviceReadError(Exception error) => error is ContractException or MalformedJsonException or InvalidDataException or InvalidCastException or KeyNotFoundException
        or FormatException or InvalidOperationException or ArgumentException;
}
