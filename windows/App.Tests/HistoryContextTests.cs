using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Which workspace a History record reopens in, and what it carries (macOS
/// <c>RuntimeHistoryWorkspaceContext</c> and <c>RuntimeWorkspaceKindProjection</c>).</summary>
[TestClass]
public sealed class HistoryContextTests
{
    private static JobSummary Job(string operation, string? kind) =>
        new("job-1", operation, "TGT-1", "succeeded", false, false, "execute", "2026-09-30T00:00:00Z", null, "session-job-1", kind);

    private static JobEvidenceFacts Evidence(string parameters, long? binding = 3) =>
        new("verified", "hdc", "digest", binding, null, null, "succeeded", "execute", null, null, null, [], [], null, 7,
            (JsonObject)StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(parameters)));

    [TestMethod]
    public void TheRuntimesWorkspaceKindWins()
    {
        Assert.AreEqual(WorkspaceKind.Trace, HistoryWorkspaceContext.Of(Job("capture.diagnostics@1", "trace"), null, null)!.Kind);
        Assert.AreEqual(WorkspaceKind.Device, HistoryWorkspaceContext.Of(Job("debug.hap@1", "device"), null, null)!.Kind);
    }

    [TestMethod]
    public void OperationsWhoseReferenceNamesAWorkspaceAreProjected()
    {
        foreach (var (operation, kind) in new (string, WorkspaceKind)[]
                 {
                     ("flash.full-restore@1", WorkspaceKind.Flash), ("flash.dayu200@1", WorkspaceKind.Flash),
                     ("debug.hap@1", WorkspaceKind.Debug), ("deploy.native-library.app-owned@1", WorkspaceKind.Debug), ("port-forward.remove@1", WorkspaceKind.Debug),
                     ("input.swipe@1", WorkspaceKind.Device), ("capture.screen-sequence@1", WorkspaceKind.Device),
                     ("observe.device@1", WorkspaceKind.Viewer), ("analyzer.summarize-trace@1", WorkspaceKind.Trace),
                     ("analyzer.summarize-hilog@1", WorkspaceKind.Diagnostics),
                 })
        {
            Assert.AreEqual(kind, HistoryWorkspaceContext.Of(Job(operation, null), null, null)!.Kind, operation);
        }
        Assert.IsNull(HistoryWorkspaceContext.Of(Job("capture.diagnostics@1", null), null, null), "a capture without typed inputs is ambiguous");
        Assert.IsNull(HistoryWorkspaceContext.Of(Job("runtime.selftest@1", null), null, null));
    }

    [TestMethod]
    public void ACapturesTypedInputsNameItsWorkspace()
    {
        WorkspaceKind? Kind(string parameters) => HistoryWorkspaceContext.Of(Job("capture.diagnostics@1", null), Evidence(parameters), null)?.Kind;
        Assert.AreEqual(WorkspaceKind.Viewer, Kind("""{"uiDump":true}"""));
        Assert.AreEqual(WorkspaceKind.Trace, Kind("""{"traceCategories":["ace"]}"""));
        Assert.AreEqual(WorkspaceKind.Device, Kind("""{"uiScreenshot":true}"""));
        Assert.AreEqual(WorkspaceKind.Diagnostics, Kind("""{"uiScreenshot":true,"captureHilog":true}"""));
        Assert.AreEqual(WorkspaceKind.Diagnostics, Kind("""{"traceCategories":[]}"""));
        Assert.IsNull(Kind("""{"durationSeconds":5}"""));
    }

    [TestMethod]
    public void TheContextCarriesTheRecordsFacts()
    {
        var artifact = new ArtifactSummary("ART-1", "job", "job-1", "trace.htrace", "application/octet-stream", "sensitive", "published", 10, new string('a', 64),
            "capture.diagnostics@1", "hdc", "2026-09-30T00:00:00Z");
        var context = HistoryWorkspaceContext.Of(Job("capture.diagnostics@1", "trace"), Evidence("""{"traceCategories":["ace"]}""", binding: null), [artifact])!;
        Assert.AreEqual(("job-1", "TGT-1", "session-job-1", 7L), (context.JobId, context.TargetId, context.SessionId, context.BindingRevision!.Value),
            "the observed binding when none was materialized");
        Assert.AreEqual("trace.htrace", context.Artifacts.Single().Name);
        Assert.AreEqual(new DiagnosticJobContext("job-1", "capture.diagnostics@1", "TGT-1", "session-job-1", "succeeded", "execute"), context.Diagnostics);
    }

    [TestMethod]
    public void DebugReopensOnTheTabThatRanTheOperation()
    {
        string Tab(string operation) => HistoryWorkspaceContext.Of(Job(operation, "debug"), null, null)!.DebugTab;
        Assert.AreEqual("apps", Tab("debug.hap@1"));
        Assert.AreEqual("network", Tab("port-forward.create@1"));
        Assert.AreEqual("logs", Tab("capture.diagnostics@1"));
        Assert.AreEqual("commands", Tab("debug.template@1"));
        Assert.AreEqual("artifacts", Tab("deploy.native-library.app-owned@1"));
    }
}
