using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>
/// The Diagnostics page's reads through ClientKit (TASK-XPA-020): a History record opened over
/// the scripted <see cref="ScriptedDaemon.Diagnostics"/> daemon (the diagnostics-inspect oracle's
/// session and job-run-hilog's summary Job), read, verified and inspected on the host as macOS
/// does; the bounded local preview; which History records open Diagnostics.
/// </summary>
[TestClass]
public sealed class DiagnosticsTests
{
    private static async Task<DiagnosticJobContext> ContextAsync(SurfaceLoader loader, string jobId)
    {
        var history = await loader.HistoryAsync();
        var job = history.Jobs.Value!.Single(j => j.JobId == jobId);
        return DiagnosticsState.ContextOf(job) ?? throw new AssertFailedException(jobId + " opens no Diagnostics context");
    }

    [TestMethod]
    public async Task NoRecordOpenReadsNothing()
    {
        var state = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Diagnostics)).DiagnosticsAsync(null);
        Assert.IsNull(state.Session);
        Assert.IsNull(state.Hilog);
        Assert.IsNull(state.LoadError);
        Assert.IsFalse(state.Reached);
    }

    [TestMethod]
    public void OnlyThePublishedInteractiveReferenceAddsAnUnambiguousHistoryReader()
    {
        Assert.IsTrue(DiagnosticsState.IsDiagnosticsRecord(DiagnosticCaptureProvider.Operation, null));
        Assert.IsTrue(DiagnosticsState.IsDiagnosticsRecord("capture.diagnostics@1", null));
        Assert.IsFalse(DiagnosticsState.IsDiagnosticsRecord("capture.unknown@1", null));
        Assert.AreEqual(WorkspaceKind.Diagnostics, HistoryWorkspaceContext.UnambiguousKind(DiagnosticCaptureProvider.Operation));
        Assert.IsNull(HistoryWorkspaceContext.UnambiguousKind("capture.diagnostics@1"), "The old multi-workspace capture keeps its original input-based classification");
    }

    [TestMethod]
    public async Task ASavedSessionIsReadAsTheSwiftInspectorReadsIt()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Diagnostics));
        var context = await ContextAsync(loader, ScriptedDaemon.DiagnosticSessionJobId);
        Assert.AreEqual(("capture.diagnostics@1", "session-" + ScriptedDaemon.DiagnosticSessionJobId), (context.OperationReference, context.SessionId));

        var state = await loader.DiagnosticsAsync(context);
        Assert.IsNull(state.LoadError, state.LoadError);
        var session = state.Session!.Presentation!;
        Assert.AreEqual(ScriptedDaemon.DiagnosticSessionJobId, session.Reading.JobId);
        Assert.AreEqual(new DiagnosticAlignment.CannotAlign("capture artifacts contain no host-to-device calibration"), session.Reading.Alignment);
        // The golden inspection (diagnostics-inspect "inspectComplete"): the ring held its
        // anchor; three marks (a manual "stutter", an "anr" without a time, a "crash"); the
        // failed Trace is a missing product; frame drops were never looked for.
        Assert.IsTrue(session.RingHeldAnchor!.Value);
        Assert.AreEqual(8, session.Artifacts.Count);
        Assert.IsTrue(session.Timeline.Count > 10);
        CollectionAssert.AreEqual(new[] { "manual 1 stutter 2026-09-10T00:00:01Z", "automatic 2 anr ", "automatic 3 crash 2026-09-10T00:00:02.500Z" },
            session.Reading.Marks.Select(m => $"{(m.IsAutomatic ? "automatic" : "manual")} {m.Ordinal} {m.Label ?? m.Trigger} {m.AtHostUtc}").ToArray());
        Assert.IsTrue(session.Reading.Marks.All(m => m.ScreenshotAbsence is DiagnosticScreenshotAbsence.NotCaptured));
        Assert.AreEqual(new DiagnosticMissingProduct("trace.htrace", "trace capture failed"), session.Reading.MissingProducts.Single());
        CollectionAssert.AreEqual(new[] { "frameDrops" }, session.Reading.NotDerived.ToArray());
        Assert.IsFalse(state.IsHilogSummaryContext);
    }

    [TestMethod]
    public async Task TextIsPreviewedLocallyAndSensitiveTextOnlyByItsOwnAction()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Diagnostics));
        var context = await ContextAsync(loader, ScriptedDaemon.DiagnosticSessionJobId);
        var session = (await loader.DiagnosticsAsync(context)).Session!.Presentation!;

        var hilog = session.Artifacts.Single(a => a.Name == "hilog.txt");
        var (preview, failure) = await loader.DiagnosticPreviewAsync(context, session, hilog);
        Assert.IsNull(failure, failure);
        Assert.IsTrue(preview!.Text.Length > 0);
        Assert.IsFalse(preview.WasClipped);

        var sensitive = session.Artifacts.Single(a => a.Name == "private-hilog.txt");
        (preview, failure) = await loader.DiagnosticPreviewAsync(context, session, sensitive);
        Assert.IsNull(failure, failure);
        Assert.IsNotNull(preview);

        // An image is not text: nothing is read.
        var image = session.Artifacts.Single(a => a.Name == "screenshot.png");
        (preview, failure) = await loader.DiagnosticPreviewAsync(context, session, image);
        Assert.IsNull(preview);
        Assert.IsNull(failure);
    }

    [TestMethod]
    public async Task ASavedHilogSummaryIsVerified()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Diagnostics));
        var context = await ContextAsync(loader, ScriptedDaemon.HilogSummaryJobId);
        var state = await loader.DiagnosticsAsync(context);
        Assert.IsTrue(state.IsHilogSummaryContext);
        Assert.IsNull(state.LoadError, state.LoadError);
        var summary = state.Hilog!.Presentation!;
        Assert.AreEqual(ScriptedDaemon.HilogSummaryJobId, summary.JobId);
        Assert.AreEqual("hilog-summary.json", summary.Artifact.Name);
        Assert.IsTrue(summary.LineCount > 0);
    }

    [TestMethod]
    public async Task AnotherOperationsRecordIsRefusedByTheSessionReader()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Diagnostics));
        var context = new DiagnosticJobContext(ScriptedDaemon.DiagnosticSessionJobId, "analyzer.extract-crash-signature@1", "TGT-3ba3f5f43b92",
            "session-" + ScriptedDaemon.DiagnosticSessionJobId, "succeeded", "execute");
        var state = await loader.DiagnosticsAsync(context);
        Assert.AreEqual("diagnostics_unsupported_operation", state.LoadError);
    }

    [TestMethod]
    public void HistoryOpensDiagnosticsForItsRecordsOnly()
    {
        static JobSummary Job(string operation, string? kind) => new("job-1", operation, "TGT-1", "succeeded", false, false, "execute", "2026-09-30T00:00:00Z", null, "session-job-1", kind);
        Assert.IsNotNull(DiagnosticsState.ContextOf(Job("capture.diagnostics@1", "trace")));
        Assert.IsNotNull(DiagnosticsState.ContextOf(Job("analyzer.summarize-hilog@1", null)));
        Assert.IsNotNull(DiagnosticsState.ContextOf(Job("analyzer.extract-crash-signature@1", null)));
        Assert.IsNotNull(DiagnosticsState.ContextOf(Job("analyzer.summarize-hilog@1", "diagnostics")));
        Assert.IsNull(DiagnosticsState.ContextOf(Job("analyzer.summarize-hilog@1", "trace")));
        Assert.IsNull(DiagnosticsState.ContextOf(Job("observe.device@1", "device")));
        Assert.IsNull(DiagnosticsState.ContextOf(Job("debug.hap@1", null)));
    }
}
