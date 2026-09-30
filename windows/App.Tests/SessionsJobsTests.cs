using System.Text;
using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>
/// The Session catalog and the Job actions through ClientKit (TASK-XPA-020).
/// <see cref="ScriptedDaemon.DevelopmentRoot"/> answers as the Windows daemon with the Job and
/// Session owners over the recorded observe.device@1 Sessions (measured, see the run record);
/// <see cref="ScriptedDaemon.Jobs"/> adds a queued Job to cancel and terminal Jobs with results.
/// </summary>
[TestClass]
public sealed class SessionsJobsTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static SurfaceLoader Loader(string scenario) => new(ScriptedDaemon.Channel(scenario));

    [TestMethod]
    public async Task TheRecordedSessionsArePinnedByGeneration()
    {
        var loader = Loader(ScriptedDaemon.DevelopmentRoot);
        var sessions = (await loader.SessionsAsync()).Sessions.Value!;
        CollectionAssert.AreEqual(new[] { ScriptedDaemon.ObservedSessionId, ScriptedDaemon.FailedSessionId }, sessions.Select(s => s.SessionId).ToArray());
        var observed = sessions[0];
        Assert.AreEqual("13586", observed.SizeBytes);
        Assert.IsFalse(observed.Pinned);

        var pinned = await loader.PinSessionAsync(observed, pin: true);
        Assert.IsTrue(pinned.Answer.Value!.Pinned);
        Assert.AreEqual("3", pinned.Answer.Value.Generation);
        var stale = await loader.PinSessionAsync(observed, pin: true);
        Assert.AreEqual("unavailable(resourceConflict): Session catalog generation changed", stale.Answer.Unavailable!.ReasonText(English));
        Assert.AreEqual($"arkdeck session pin --session {observed.SessionId} --expected-generation <non-negative-integer>", stale.Answer.Unavailable.CliCommand);
        var unpinned = await loader.PinSessionAsync(pinned.Answer.Value, pin: false);
        Assert.IsFalse(unpinned.Answer.Value!.Pinned);
    }

    [TestMethod]
    public async Task CleanupAppliesExactlyThePreviewedRemoval()
    {
        var loader = Loader(ScriptedDaemon.DevelopmentRoot);
        var observed = (await loader.SessionsAsync()).Sessions.Value![0];
        await loader.PinSessionAsync(observed, pin: true);
        var preview = (await loader.CleanupPreviewAsync()).Answer.Value!;
        CollectionAssert.AreEqual(new[] { ScriptedDaemon.FailedSessionId }, preview.Reclaimed.Select(s => s.SessionId).ToArray(), "a pinned Session is kept");
        Assert.AreEqual("7013", preview.ReclaimBytes);
        Assert.AreEqual("expiredQuotaPressure", preview.Reclaimed.Single().Reason);
        var applied = (await loader.CleanupApplyAsync(preview)).Answer.Value!;
        CollectionAssert.AreEqual(new[] { ScriptedDaemon.FailedSessionId }, applied.RemovedSessionIds.ToArray());
        Assert.AreEqual("7013", applied.ReclaimedBytes);
        CollectionAssert.AreEqual(new[] { ScriptedDaemon.ObservedSessionId }, (await loader.SessionsAsync()).Sessions.Value!.Select(s => s.SessionId).ToArray());

        // The same preview cannot be applied twice.
        var again = await loader.CleanupApplyAsync(preview);
        Assert.AreEqual("resourceConflict", again.Answer.Unavailable!.ReasonCode);
    }

    [TestMethod]
    public async Task ExportIsPreviewedThenWrittenByTheRuntime()
    {
        var loader = Loader(ScriptedDaemon.DevelopmentRoot);
        var destination = @"C:\Exports\" + ScriptedDaemon.ObservedSessionId;
        var preview = (await loader.ExportPreviewAsync(ScriptedDaemon.ObservedSessionId, destination)).Answer.Value!;
        Assert.AreEqual(destination, preview.DestinationPath);
        Assert.AreEqual("4672", preview.EstimatedBytes);
        Assert.AreEqual("redact", preview.DeviceIdentifierPolicy);
        Assert.IsTrue(preview.SensitiveDefaultExcluded);
        var applied = (await loader.ExportApplyAsync(preview)).Answer.Value!;
        Assert.AreEqual(0, applied.ExcludedArtifactCount);

        var missing = await loader.ExportPreviewAsync("session-unknown", destination);
        Assert.AreEqual("resourceNotFound", missing.Answer.Unavailable!.ReasonCode);
        Assert.AreEqual("arkdeck session export preview --session session-unknown --destination <new-directory>", missing.Answer.Unavailable.CliCommand);
    }

    [TestMethod]
    public async Task TheFoundationHasNoSessionOwner()
    {
        var loader = Loader(ScriptedDaemon.Foundation);
        Assert.AreEqual("unavailable(rejected): Session owner is not configured", (await loader.SessionsAsync()).Sessions.Unavailable!.ReasonText(English));
        Assert.AreEqual("unavailable(rejected): Session owner is not configured", (await loader.CleanupPreviewAsync()).Answer.Unavailable!.ReasonText(English));
        Assert.AreEqual("arkdeck session cleanup preview", (await loader.CleanupPreviewAsync()).Answer.Unavailable!.CliCommand);
        var storage = (await loader.SettingsAsync()).Storage.Unavailable!;
        Assert.AreEqual("unavailable(rejected): Runtime storage owners are not configured", storage.ReasonText(English));
    }

    [TestMethod]
    public async Task TheDevelopmentRootsStorageIsTheRecordedSessionRoot()
    {
        var storage = (await Loader(ScriptedDaemon.DevelopmentRoot).SettingsAsync()).Storage.Value!;
        Assert.AreEqual("20599", storage.SessionUsedBytes);
        Assert.AreEqual("2", storage.SessionCount);
        Assert.AreEqual("90", storage.RetentionDays);
    }

    [TestMethod]
    public async Task AQueuedJobIsCancelledAndATerminalJobHasItsResult()
    {
        var loader = Loader(ScriptedDaemon.Jobs);
        var cancel = (await loader.CancelJobAsync(ScriptedDaemon.QueuedJobId)).Answer.Value!;
        Assert.IsTrue(cancel.Requested);
        Assert.AreEqual("cancelled", (await loader.JobAsync(ScriptedDaemon.QueuedJobId)).Status.Value!.State, "the state is read back, not assumed");

        var result = (await loader.JobResultAsync(ScriptedDaemon.TraceJobId)).Answer.Value!;
        Assert.IsTrue(result.Terminal);
        Assert.AreEqual(2, result.Artifacts.Count);
        Assert.AreEqual(0, result.CleanupCount);
        var notReady = (await loader.JobResultAsync(ScriptedDaemon.RunningJobId)).Answer.Unavailable!;
        Assert.AreEqual("unavailable(resultNotReady): the Job has no terminal result yet", notReady.ReasonText(English));
        Assert.AreEqual($"arkdeck job result --job {ScriptedDaemon.RunningJobId}", notReady.CliCommand);

        var evidence = (await loader.JobEvidenceAsync(ScriptedDaemon.FailedJobId)).Answer.Value!;
        Assert.AreEqual("failed", evidence.TerminalState);
        CollectionAssert.AreEqual(new[] { "executionFailed" }, evidence.Blockers.ToArray());
        var detail = await loader.HistoryDetailAsync(ScriptedDaemon.TraceJobId);
        Assert.AreEqual("verified", detail.Evidence.Value!.Status);
        Assert.AreEqual("defaultReadOnlyPolicy", detail.Evidence.Value.AuthorityKind);

        var unknown = await Loader(ScriptedDaemon.DevelopmentRoot).CancelJobAsync("job-00000000000000000000000000000000");
        Assert.AreEqual("unavailable(notFound): unknown job job-00000000000000000000000000000000", unknown.Answer.Unavailable!.ReasonText(English));
    }

    [TestMethod]
    public void EveryRecordedResultAndEvidenceIsReadable()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("rust", "tests", "fixtures", "observe-device", "cases.json")));
        var read = 0;
        foreach (var exchange in doc.RootElement.GetProperty("exchanges").EnumerateArray())
        {
            var method = exchange.GetProperty("method").GetString();
            var answer = exchange.GetProperty("answer");
            if (method is not ("job.result" or "job.evidence") || !answer.GetProperty("ok").GetBoolean()) continue;
            var value = StrictJson.Parse(Encoding.UTF8.GetBytes(answer.GetProperty("result").GetRawText()));
            if (method == "job.result") Assert.IsTrue(JobResultFacts.Parse(value).Terminal);
            else Assert.IsFalse(string.IsNullOrEmpty(JobEvidenceFacts.Parse(value).Status));
            read++;
        }
        Assert.AreEqual(7, read, "3 results and 4 evidence answers of the recorded observe.device@1 Jobs");
    }
}
