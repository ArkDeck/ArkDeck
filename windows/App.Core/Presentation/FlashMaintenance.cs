using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

public sealed record FlashVerifiedPartition(string Target, long RangeStart, long RangeLength, string ExpectedSha256,
    string? ObservedSha256, string Outcome, string? Strength, string? Reason);

public sealed record FlashVerification(string SourceJobId, string SourcePlanId, string SourcePlanSha256, int ExitCode,
    string Outcome, int Verified, int Skipped, int Failed, IReadOnlyList<FlashVerifiedPartition> Targets)
{
    public static FlashVerification Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Flash verification");
        string Text(string key) => TypedJson.Required(o, key, TypedJson.String);
        int Count(string key) => checked((int)TypedJson.Required(o, key, TypedJson.Int64));
        var targets = TypedJson.Required(o, "targets", v => TypedJson.List(v, row =>
        {
            var t = Json.Object(row, "a partition verification");
            return new FlashVerifiedPartition(TypedJson.Required(t, "target", TypedJson.String),
                TypedJson.Required(t, "range_start", TypedJson.Int64), TypedJson.Required(t, "range_length", TypedJson.Int64),
                TypedJson.Required(t, "expected_sha256", TypedJson.String), Json.NullableString(t, "observed_sha256"),
                TypedJson.Required(t, "outcome", TypedJson.String), Json.NullableString(t, "verification_strength"), Json.NullableString(t, "reason"));
        }));
        var result = new FlashVerification(Text("source_job_id"), Text("source_plan_id"), Text("source_plan_sha256"), Count("exit_code"),
            Text("outcome"), Count("verified"), Count("skipped"), Count("failed"), targets);
        if (Text("schema") != "arkforge.flash-verification/v1" || string.IsNullOrEmpty(result.SourceJobId) || string.IsNullOrEmpty(result.SourcePlanId)
            || !FlashOperations.Sha256().IsMatch(result.SourcePlanSha256) || targets.Count == 0 || targets.Select(t => t.Target).Distinct().Count() != targets.Count
            || result.Verified != targets.Count(t => t.Outcome == "verified") || result.Skipped != targets.Count(t => t.Outcome == "typedSkip")
            || result.Failed != targets.Count(t => t.Outcome == "failed") || result.Verified + result.Skipped + result.Failed != targets.Count
            || result.ExitCode != (result.Failed > 0 ? 7 : result.Skipped > 0 ? 9 : 0)
            || result.Outcome != (result.Failed > 0 ? "failed" : result.Skipped > 0 ? "partial" : "verified")
            || targets.Any(t => t.RangeStart < 0 || t.RangeStart % 512 != 0 || t.RangeLength is <= 0 or > 17179869184
                || t.RangeStart > long.MaxValue - t.RangeLength || !FlashOperations.Sha256().IsMatch(t.ExpectedSha256)
                || (t.ObservedSha256 is { } h && !FlashOperations.Sha256().IsMatch(h)) || !(t.Outcome switch
                {
                    "verified" => t.ObservedSha256 == t.ExpectedSha256 && t.Strength == "fullHash",
                    "typedSkip" => t.Reason == "mounted-writable-after-boot" && t.ObservedSha256 is null && t.Strength is null,
                    "failed" => !string.IsNullOrEmpty(t.Reason) && t.Strength is null,
                    _ => false,
                }))) throw Invalid();
        return result;
    }
    internal static ContractException Invalid() => new(ContractErrorKind.SchemaMismatch, "Invalid Flash maintenance result");
}

public sealed record FlashMaintenanceResult(int ExitCode, string Outcome, string SourceJobId, string? RestorationJobId,
    bool OutcomeUnknown, string? Reason, FlashVerification? Verification)
{
    public static FlashMaintenanceResult Parse(JsonValue value)
    {
        var o = Json.Object(value, "a maintenance result");
        var schema = TypedJson.Required(o, "schema", TypedJson.String);
        if (schema == "arkforge.flash-verification/v1")
        {
            var verification = FlashVerification.Parse(value);
            return new(verification.ExitCode, verification.Outcome, verification.SourceJobId, null, false, null, verification);
        }
        if (schema != "arkforge.boot-loop-restoration/v1") throw FlashVerification.Invalid();
        string? OptionalText(string key) => !o.TryGetValue(key, out var rawText) || rawText is JsonNull ? null : TypedJson.String(rawText);
        var result = new FlashMaintenanceResult(checked((int)TypedJson.Required(o, "exit_code", TypedJson.Int64)),
            TypedJson.Required(o, "outcome", TypedJson.String), TypedJson.Required(o, "source_job_id", TypedJson.String),
            OptionalText("restoration_job_id"), TypedJson.Required(o, "outcome_unknown", TypedJson.Bool), OptionalText("reason"),
            o.TryGetValue("verification", out var raw) && raw is not JsonNull ? FlashVerification.Parse(raw) : null);
        if (result.ExitCode == 0 && result.Verification is { } v && v.Targets.Count == 1)
        {
            var t = v.Targets[0];
            if (result.Outcome != "verified" || result.OutcomeUnknown || string.IsNullOrEmpty(result.RestorationJobId)
                || result.RestorationJobId == result.SourceJobId || result.RestorationJobId != v.SourceJobId || v.ExitCode != 0
                || t.Target != "ramdisk" || t.RangeStart != 121634816 || t.RangeLength != 4194304
                || t.ExpectedSha256 != "bdd1f4eacbe545f5a553b529980bc487723d37554148058dd551c241abf86de4") throw FlashVerification.Invalid();
        }
        else if (result.ExitCode != 1 || result.Outcome != "stopped" || string.IsNullOrEmpty(result.Reason) || result.Verification is not null)
            throw FlashVerification.Invalid();
        return result;
    }
}

public sealed partial class SurfaceLoader
{
    /// <summary>Only typed Job requests reach the daemon. No capabilities or shell arguments originate here.
    /// A failed run is never resubmitted; the retained Job remains the source of truth.</summary>
    public async Task<(FlashRunStatus? Status, string? Failure)> FlashMaintenanceAsync(string sourceJobId, TargetSummary target,
        string? originalArchive, int budgetMs, CancellationToken cancellation = default)
    {
        if (sourceJobId.Length is < 1 or > 128 || !char.IsAsciiLetterOrDigit(sourceJobId[0])
            || sourceJobId.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '_' or '-'))
            || target.BindingRevision <= 0 || budgetMs is < 1000 or > 600000)
            return (null, "Invalid maintenance parameters (exit 2); no request or record was created");
        var operation = originalArchive is null ? "flash.verify" : "flash.restore-boot-loop";
        var inputs = new List<(string, JsonValue)> { ("sourceJobId", new JsonString(sourceJobId)), ("budgetMs", JsonNumber.FromInt64(budgetMs)) };
        if (originalArchive is not null)
        {
            var review = await Task.Run(() => FlashArchive.Review(originalArchive, FlashOperations.ProfileReference), cancellation).ConfigureAwait(false);
            if (review.Reviewed is null) return (null, "The original image bundle could not be read; no restoration was submitted");
            var imported = await new ImportUploader(channel).UploadAsync(originalArchive, ImportKind.FlashBundle, target, null, cancellation, name: "images.tar.gz").ConfigureAwait(false);
            if (imported.Committed?.Receipt?.Lease is not { Length: > 0 } lease)
                return (null, imported.Failure?.Detail ?? "Runtime returned no original image lease");
            inputs.Add(("artifactLease", new JsonString(lease)));
        }
        var request = RuntimeRequest.Build("maintenance-ui", originalArchive is null ? "flash.verify" : "flash.restore-boot-loop", 1, target.TargetId, target.BindingRevision,
            inputs, ["rawArtifacts", "derivedArtifacts"], FlashOperations.Client);
        var planned = await PlanAsync(request, CliCommands.JobPlan).ConfigureAwait(false);
        if (planned.Answer.Value is not { } plan) return (null, planned.Answer.Unavailable?.Detail ?? "Maintenance plan unavailable");
        if (plan.Operation != operation + "@1" || plan.TargetId != target.TargetId || plan.BindingRevision != target.BindingRevision || plan.ProviderId != "arkforge"
            || plan.EffectiveEffect != (originalArchive is null ? "readOnly" : "destructive")) return (null, "Runtime returned a mismatched maintenance plan");
        var admitted = await SubmitAsync(request.Reviewed(plan.PlanDigest), CliCommands.JobSubmit).ConfigureAwait(false);
        if (admitted.Answer.Value is not { } job) return (null, admitted.Answer.Unavailable?.Detail ?? "Maintenance admission stopped");
        var ran = await RunFlashAsync(job.JobId).ConfigureAwait(false);
        return (ran.Answer.Value, ran.Answer.Unavailable?.Detail);
    }
}
