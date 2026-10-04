using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>The global Job recovery banner's rules (macOS <c>requiresRecoveryGuidance</c> and
/// <c>GlobalRecoveryBannerView</c>).</summary>
[TestClass]
public sealed class JobRecoveryTests
{
    private static JobSummary Job(string id, string state, bool unknown = false, bool human = false, string? superseded = null, string? resolved = null) =>
        new(id, "flash.full-restore@1", "TGT-1", state, unknown, human, "execute", "2026-09-30T00:00:00Z", null, null, null, superseded, resolved);

    [TestMethod]
    public void OnlyRecordsThatNeedAPersonNowAreShownMostUrgentFirst()
    {
        var ordered = JobRecovery.Ordered([
            Job("a", "succeeded"),
            Job("b", "waitingForRecovery"),
            Job("c", "running", human: true),
            Job("d", "interrupted", unknown: true),
            Job("e", "waitingForRecovery", unknown: true, superseded: "epoch-2"),
            Job("f", "userAbandonRequested", resolved: "alias-1"),
            Job("g", "resumeAtConfirmedSafeBoundary"),
            Job("h", "awaitingRebindConfirmation"),
        ]);
        CollectionAssert.AreEqual(new[] { "d", "c", "b", "g", "h" }, ordered.Select(j => j.JobId).ToArray());
        CollectionAssert.AreEqual(new[] { "jobRecovery.outcomeUnknown.title", "jobRecovery.humanRequired.title", "jobRecovery.waiting.title", "jobRecovery.resumeSafe.title", "jobRecovery.waiting.title" },
            ordered.Select(JobRecovery.TitleKey).ToArray());
        Assert.AreEqual("jobRecovery.archivePending.guidance", JobRecovery.GuidanceKey(Job("x", "userAbandonRequested")));
    }

    [TestMethod]
    public async Task TheRecoveryScenarioHasTwoRecordsToReview()
    {
        var history = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Recovery)).HistoryAsync();
        CollectionAssert.AreEqual(new[] { ScriptedDaemon.WaitingForRecoveryJobId, ScriptedDaemon.ResumeSafeJobId },
            JobRecovery.Ordered(history.Jobs.Value!).Select(j => j.JobId).OrderBy(j => j).ToArray());
    }
}
