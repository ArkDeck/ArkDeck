using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>
/// The Trace workspace and the Trace viewer through UIA patterns only (no synthetic input). Over
/// the scripted <c>viewer</c> daemon (the recorded trace-probe and capture-diagnostics-trace
/// oracles) a five-second App-responsiveness capture runs, its raw Trace is read and verified
/// into the App's cache and opened in the viewer, which says why no timeline is drawn on Windows
/// and shows the Runtime inspector's refusal; a local Trace file opens the same way and joins the
/// recent list. Over the <c>targets</c> daemon (the Windows daemon over a development root) Start
/// says why a capture cannot start and nothing is sent.
/// </summary>
[TestClass]
public sealed class TraceFlowTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void ACaptureOpensItsVerifiedTraceInTheViewer()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var cache = Directory.CreateTempSubdirectory("arkdeck-app-uitest-trace-");
        try
        {
            using var app = AppSession.Launch(exe, ["--test-transport", "viewer", "--language", "en-US", "--page", "trace", "--cache-root", cache.FullName]);
            Assert.AreEqual(strings["trace.availability.available"], app.WaitForName("trace.availability.status", n => n.Length > 0));
            Assert.AreEqual(strings["windows.trace.capture.localOnly"], AppSession.Name(app.Find("trace.capture.status")));
            Assert.AreEqual("OpenHarmony 6.0, fixture-serial-1, USB", AppSession.Name(app.Find("trace.target.deviceSummary")), "the full values for a screen reader");
            Assert.AreEqual(strings["trace.preset.arkuiDeep.detail"], AppSession.Name(app.Find("trace.profile.detail")));
            app.Find("trace.duration.quick.seconds.5").Patterns.Toggle.Pattern.Toggle();
            Assert.AreEqual("5", app.Find("trace.duration.input").Patterns.Value.Pattern.Value.Value);

            app.Invoke("trace.start");
            // The capture opens the viewer on its verified Trace.
            Assert.AreEqual(strings["error.title.bundledParserUnavailable"], app.WaitForName("trace.viewer.error.title", n => n.Length > 0));
            Assert.AreEqual(strings["error.reason.parser"], AppSession.Name(app.Find("trace.viewer.error.reason")));
            var reason = app.WaitForName("trace.viewer.inspection.reason", n => n.Length > 0);
            TestContext.WriteLine("inspection: " + reason);
            Assert.AreEqual(strings.Format("windows.unavailable.reason", ["operationUnavailable", "Trace inspection is unavailable"]), reason);
            var document = AppSession.Name(app.Find("trace.viewer.document"));
            StringAssert.EndsWith(document, ".htrace");
            Assert.IsTrue(File.Exists(Path.Combine(cache.FullName, "TraceInbox", document)), "staged in the App's cache");
            app.Find("trace.viewer.recent.0");
            app.Invoke("trace.viewer.error.diagnostics");
            Assert.AreEqual(strings["windows.traceViewer.noParser"], AppSession.Name(app.Find("trace.viewer.error.diagnostic")));

            app.Invoke("trace.viewer.capture");
            Assert.AreEqual(strings["trace.capture.finished"], app.WaitForName("trace.capture.status", n => n.Length > 0));
            Assert.AreEqual(strings["trace.viewer.latest"], AppSession.Name(app.Find("trace.viewer.latest")));
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            cache.Delete(recursive: true);
        }
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ALocalTraceOpensAndJoinsTheRecentList()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var cache = Directory.CreateTempSubdirectory("arkdeck-app-uitest-trace-");
        try
        {
            var trace = Path.Combine(cache.FullName, "sample.htrace");
            File.WriteAllBytes(trace, [0x68, 0x74, 0x72, 0x61, 0x63, 0x65]);
            using var app = AppSession.Launch(exe, ["--test-transport", "viewer", "--language", "en-US", "--page", "traceViewer", "--cache-root", cache.FullName]);
            Assert.AreEqual(strings["windows.traceViewer.idleTitle"], app.WaitForName("trace.viewer.idle.title", n => n.Length > 0));
            Assert.AreEqual(strings["windows.traceViewer.nothingSelected"], AppSession.Name(app.Find("trace.viewer.inspector.empty")));
            AgentImportFlowTests.ChooseFile(app, "trace.viewer.idle.open", trace);
            Assert.AreEqual("sample.htrace", app.WaitForName("trace.viewer.document", n => n.Length > 0));
            Assert.AreEqual(strings["error.title.bundledParserUnavailable"], AppSession.Name(app.Find("trace.viewer.error.title")));
            Assert.AreEqual("6", AppSession.Name(app.Find("trace.viewer.inspector.sourceBytes")));
            Assert.AreEqual("sample.htrace", AppSession.Name(app.Find("trace.viewer.recent.0")));
            Assert.IsNull(app.TryFind("trace.viewer.inspection.title", TimeSpan.FromMilliseconds(500)), "a local file has no Runtime record to ask about");

            File.Delete(trace);
            app.Invoke("traceViewer.refresh");
            Assert.AreEqual(strings.Format("windows.traceViewer.missingName", ["sample.htrace"]), app.WaitForName("trace.viewer.recent.0", n => n.Contains("missing", StringComparison.Ordinal)));
            app.Invoke("trace.viewer.recent.0.remove");
            SemanticSnapshotTests.WaitUntil(() => app.TryFind("trace.viewer.recent.0", TimeSpan.FromMilliseconds(200)) is null, "the missing Trace leaves the list");
        }
        finally
        {
            cache.Delete(recursive: true);
        }
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void StartSaysWhyACaptureCannotStart()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "targets", "--language", "en-US", "--page", "trace"]);
        var first = app.WaitForName("trace.capture.status", n => n.Length > 0);
        TestContext.WriteLine("blocked: " + first);
        Assert.AreNotEqual(strings["windows.trace.capture.localOnly"], first);
        Assert.AreEqual(strings["trace.availability.unavailable"], AppSession.Name(app.Find("trace.availability.status")));
        app.Invoke("trace.start");
        Assert.AreEqual(first, app.WaitForName("trace.submission.failure", n => n.Length > 0));
        Assert.IsNull(app.TryFind("trace.cancel", TimeSpan.FromMilliseconds(500)), "nothing was submitted");
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
