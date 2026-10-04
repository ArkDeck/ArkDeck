namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// The macOS global Job recovery banner's rules (<c>GlobalRecoveryBannerView</c> over
/// <c>RuntimeJobSummaryPresentation.requiresRecoveryGuidance</c>): a record needs a person now
/// when the Runtime has not established a later epoch for it and its outcome is unknown, it waits
/// for a person, or it waits for recovery, a rebind confirmation, a resume at a confirmed safe
/// boundary or an archive. Unknown outcomes come first, then waiting for a person, then the rest.
/// </summary>
public static class JobRecovery
{
    public static bool HasEstablishedCurrentEpoch(JobSummary job) =>
        job.SupersededByRecoveryEpochId is not null || job.ResolvedByTargetAliasResolutionId is not null;

    public static bool RequiresGuidance(JobSummary job) =>
        !HasEstablishedCurrentEpoch(job)
        && (job.OutcomeUnknown || job.WaitingForHuman
            || job.State is "waitingForRecovery" or "awaitingRebindConfirmation" or "resumeAtConfirmedSafeBoundary" or "userAbandonRequested");

    public static IReadOnlyList<JobSummary> Ordered(IEnumerable<JobSummary> jobs) =>
        jobs.Where(RequiresGuidance).Select((job, index) => (job, index)).OrderBy(p => Severity(p.job)).ThenBy(p => p.index).Select(p => p.job).ToArray();

    private static int Severity(JobSummary job) => job.OutcomeUnknown ? 0 : job.WaitingForHuman ? 1 : 2;

    private static string Kind(JobSummary job) =>
        job.OutcomeUnknown ? "outcomeUnknown"
        : job.WaitingForHuman ? "humanRequired"
        : job.State switch
        {
            "resumeAtConfirmedSafeBoundary" => "resumeSafe",
            "userAbandonRequested" => "archivePending",
            _ => "waiting",
        };

    public static string TitleKey(JobSummary job) => $"jobRecovery.{Kind(job)}.title";

    public static string GuidanceKey(JobSummary job) => $"jobRecovery.{Kind(job)}.guidance";
}
