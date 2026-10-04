using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Overview's run record, Run It Again and the prepared continuation (macOS
/// <c>OverviewRunRecordContractTests</c>, <c>OverviewResumeSheet</c>,
/// <c>RuntimeWorkspaceContinuation</c>).</summary>
[TestClass]
public sealed class OverviewRunTests
{
    private static string Stamp(int minute) => $"2026-08-25T10:{minute:00}:00.000Z";

    private static JobSummary Job(string id, string? thread = null, string operation = "capture.diagnostics@1", string state = "succeeded",
        string? effect = "readOnly", bool unknown = false, bool waiting = false, long residue = 0, string? at = null, string? supersededBy = null) =>
        new(id, operation, "TGT-1", state, unknown, waiting, "execute", at ?? Stamp(0), at, null, null, supersededBy, null, residue, thread, effect, at);

    [TestMethod]
    public void RunsGroupByThreadAndUngroupedRunsStayOnTheirOwn()
    {
        var threads = OverviewRuns.Threads(
        [
            Job("job-1", "t-aaa", at: Stamp(1)), Job("job-2", "t-aaa", at: Stamp(3)), Job("job-3", "t-bbb", at: Stamp(2)),
            Job("job-4", at: Stamp(4)), Job("job-5", at: Stamp(5)),
        ], limit: 10);
        CollectionAssert.AreEqual(new[] { null, null, "t-aaa", "t-bbb" }, threads.Select(t => t.ThreadId).ToArray());
        CollectionAssert.AreEqual(new[] { "job-1", "job-2" }, threads.Single(t => t.ThreadId == "t-aaa").Runs.Select(r => r.JobId).ToArray(), "oldest first");
        CollectionAssert.AreEqual(new[] { "job-5", "job-4" }, threads.Where(t => t.ThreadId is null).Select(t => t.Runs.Single().JobId).ToArray(), "two lines, not one");
    }

    [TestMethod]
    public void ALineNeedingAPersonIsPinnedUntilTheRuntimeSettlesIt()
    {
        foreach (var needing in new[] { Job("job-old", "t-old", unknown: true, at: Stamp(1)), Job("job-old", "t-old", waiting: true, at: Stamp(1)), Job("job-old", "t-old", residue: 2, at: Stamp(1)) })
        {
            var threads = OverviewRuns.Threads([needing, Job("job-new", "t-new", at: Stamp(9))], limit: 10);
            CollectionAssert.AreEqual(new[] { "t-old", "t-new" }, threads.Select(t => t.ThreadId).ToArray());
            CollectionAssert.AreEqual(new[] { true, false }, threads.Select(t => t.NeedsAttention).ToArray());
        }
        var settled = OverviewRuns.Threads([Job("job-old", "t-old", unknown: true, at: Stamp(1), supersededBy: "epoch-1"), Job("job-new", "t-new", at: Stamp(9))], limit: 10);
        CollectionAssert.AreEqual(new[] { "t-new", "t-old" }, settled.Select(t => t.ThreadId).ToArray());
    }

    [TestMethod]
    public void TruncationKeepsWholeLinesAndTheFeaturedRunComesFirst()
    {
        var jobs = Enumerable.Range(1, 6).SelectMany(i => new[] { Job($"job-{i}-a", $"t-{i}", at: Stamp(i * 2)), Job($"job-{i}-b", $"t-{i}", at: Stamp(i * 2 + 1)) })
            .Append(Job("job-attention", "t-att", unknown: true, at: Stamp(0))).ToArray();
        var threads = OverviewRuns.Threads(jobs, limit: 3);
        Assert.AreEqual(3, threads.Count);
        Assert.AreEqual("t-att", threads[0].ThreadId);
        Assert.IsTrue(threads.Skip(1).All(t => t.Runs.Count == 2));

        var line = OverviewRuns.Threads(Enumerable.Range(1, 7).Select(i => Job($"job-{i}", "t-aaa", operation: i == 2 ? "debug.hap@1" : "capture.diagnostics@1", at: Stamp(i))), limit: 1).Single();
        CollectionAssert.AreEqual(new[] { "capture.diagnostics@1", "debug.hap@1" }, line.OperationReferences.ToArray());
        var featured = OverviewRuns.Featured(line)!;
        Assert.AreEqual("job-7", featured.JobId);
        CollectionAssert.AreEqual(new[] { "job-6", "job-5", "job-4" }, OverviewRuns.Additional(line, featured).Select(r => r.JobId).ToArray());

        var unresolved = OverviewRuns.Threads([Job("job-attention", "t-aaa", unknown: true, at: Stamp(1)), Job("job-later", "t-aaa", at: Stamp(2))], limit: 1).Single();
        Assert.AreEqual("job-attention", OverviewRuns.Featured(unresolved)!.JobId);
    }

    [TestMethod]
    public void EveryRefusalToRepeatARunNamesItself()
    {
        Assert.AreEqual(ResumeDisposition.NotTerminal, OverviewRuns.Disposition(Job("j", state: "running"), true));
        Assert.AreEqual(ResumeDisposition.EffectUnknown, OverviewRuns.Disposition(Job("j", effect: null), true));
        Assert.AreEqual(ResumeDisposition.RequiresAuthorization, OverviewRuns.Disposition(Job("j", effect: "deviceMutation"), true));
        Assert.AreEqual(ResumeDisposition.RequiresAuthorization, OverviewRuns.Disposition(Job("j", effect: "somethingNewUpstream"), true), "fails closed");
        Assert.AreEqual(ResumeDisposition.ParametersNotReported, OverviewRuns.Disposition(Job("j"), false));
        Assert.AreEqual(ResumeDisposition.DetailNotLoaded, OverviewRuns.Disposition(Job("j"), null), "never optimistic");
        Assert.AreEqual(ResumeDisposition.Resumable, OverviewRuns.Disposition(Job("j", effect: "hostOnly"), true));
        foreach (var effect in new[] { "readOnly", "hostOnly", "deviceMutation", "destructive", null })
        {
            Assert.AreEqual(ResumeDisposition.NeverReplayed, OverviewRuns.Disposition(Job("j", state: "interrupted", effect: effect, unknown: true), true));
        }
    }

    [TestMethod]
    public async Task TheRecordReadsTheEvidenceOfTheRunsItShows()
    {
        var overview = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Continue)).OverviewAsync();
        var threads = overview.Threads;
        CollectionAssert.AreEqual(new[] { "run:" + ScriptedDaemon.ContinueUnknownJobId, "thread:" + ScriptedDaemon.ContinueThreadId, "run:" + ScriptedDaemon.ContinueFlashJobId, "run:" + ScriptedDaemon.ContinueUnreportedJobId },
            threads.Select(t => t.Id).ToArray());
        Assert.AreEqual(ScriptedDaemon.ContinueObserveJobId, OverviewRuns.Featured(threads[1])!.JobId);
        var dispositions = new[] { ScriptedDaemon.ContinueUnknownJobId, ScriptedDaemon.ContinueObserveJobId, ScriptedDaemon.ContinueObserveOlderJobId, ScriptedDaemon.ContinueFlashJobId, ScriptedDaemon.ContinueUnreportedJobId }
            .Select(id => overview.DispositionOf(overview.Recent.Value!.Single(j => j.JobId == id))).ToArray();
        CollectionAssert.AreEqual(new[] { ResumeDisposition.NeverReplayed, ResumeDisposition.Resumable, ResumeDisposition.Resumable, ResumeDisposition.RequiresAuthorization, ResumeDisposition.ParametersNotReported }, dispositions);
    }

    [TestMethod]
    public async Task ADraftCarriesTheRecordedInputsForTheSameTargetAndBindingOnly()
    {
        var overview = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Continue)).OverviewAsync();
        JobSummary Run(string id) => overview.Recent.Value!.Single(j => j.JobId == id);
        var source = Run(ScriptedDaemon.ContinueObserveJobId);
        var evidence = overview.EvidenceOf(source.JobId);
        var (draft, failure) = WorkspaceContinuation.Prepare(source, evidence, ScriptedDaemon.FixtureTargetId, 3);
        Assert.IsNull(failure);
        Assert.AreEqual("""{"refreshServerFacts":true}""", draft!.Inputs.ToString());
        Assert.AreEqual(WorkspaceKind.Device, draft.Kind, "the record's own workspace");

        var first = (JsonObject)StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(draft.Request().Json));
        var second = (JsonObject)StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(draft.Request().Json));
        Assert.AreNotEqual(first["requestId"].ToString(), second["requestId"].ToString(), "a new request identity every time");
        var provenance = (JsonObject)((JsonObject)first["clientContext"])["provenance"];
        Assert.AreEqual(source.JobId, ((JsonString)provenance["arkdeck.continuedFromJob"]).Value);
        Assert.AreEqual(ScriptedDaemon.ContinueThreadId, ((JsonString)provenance["arkdeck.threadId"]).Value);
        Assert.AreEqual("""{"expectedBindingRevision":3,"targetId":"TGT-FIXTURE-1"}""", first["target"].ToString());
        Assert.IsFalse(first.ContainsKey("authorization") || first.ContainsKey("sessionId"));

        Assert.AreEqual("continuation_target_or_binding_changed", WorkspaceContinuation.Prepare(source, evidence, ScriptedDaemon.FixtureTargetId, 4).Failure);
        Assert.AreEqual("continuation_target_or_binding_changed", WorkspaceContinuation.Prepare(source, evidence, "TGT-OTHER", 3).Failure);
        Assert.AreEqual("continuation_source_not_repeatable", WorkspaceContinuation.Prepare(Run(ScriptedDaemon.ContinueFlashJobId), overview.EvidenceOf(ScriptedDaemon.ContinueFlashJobId), ScriptedDaemon.FixtureTargetId, 3).Failure);
        Assert.AreEqual("continuation_source_not_repeatable", WorkspaceContinuation.Prepare(Run(ScriptedDaemon.ContinueUnreportedJobId), overview.EvidenceOf(ScriptedDaemon.ContinueUnreportedJobId), ScriptedDaemon.FixtureTargetId, 3).Failure);
        var marked = evidence! with { Parameters = (JsonObject)StrictJson.Parse("""{"markers":["t1"]}"""u8.ToArray()) };
        Assert.AreEqual("continuation_typed_source_unavailable", WorkspaceContinuation.Prepare(source with { Operation = "trace.capture@1" }, marked, ScriptedDaemon.FixtureTargetId, 3).Failure, "outside the closed scope");
        Assert.AreEqual("continuation_markers_require_new_capture_times", WorkspaceContinuation.Prepare(source, marked, ScriptedDaemon.FixtureTargetId, 3).Failure);
    }

    [TestMethod]
    public async Task AStartedDraftIsOneNewJobAfterFreshChecks()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Continue));
        var overview = await loader.OverviewAsync();
        var source = overview.Recent.Value!.Single(j => j.JobId == ScriptedDaemon.ContinueObserveJobId);
        var draft = WorkspaceContinuation.Prepare(source, overview.EvidenceOf(source.JobId), ScriptedDaemon.FixtureTargetId, 3).Draft!;
        var accepted = (await loader.SubmitContinuationAsync(draft)).Answer;
        Assert.IsNull(accepted.Unavailable, accepted.Unavailable?.Detail);
        Assert.AreNotEqual(source.JobId, accepted.Value!.JobId);
        var ran = (await loader.RunContinuationAsync(draft, accepted.Value.JobId)).Answer;
        Assert.AreEqual("succeeded", ((JsonString)ran.Value!.Status["state"]).Value);

        // A draft whose binding moved since it was prepared is refused before anything is submitted.
        var stale = draft with { BindingRevision = 2 };
        Assert.AreEqual("continuation_source_or_target_drifted", (await loader.SubmitContinuationAsync(stale)).Answer.Unavailable!.ReasonCode);
        var after = await loader.OverviewAsync();
        Assert.AreEqual(6, after.Recent.Value!.Count, "exactly one new Job");
    }
}
