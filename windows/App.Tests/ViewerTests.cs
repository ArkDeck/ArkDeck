using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>
/// The UI dump Viewer through ClientKit (TASK-XPA-020): a view capture over the scripted
/// <see cref="ScriptedDaemon.Viewer"/> daemon (the recorded ui-dump-inspect oracle's Artifacts),
/// read, verified and parsed on the host; a component's Advanced Dump; the macOS route rule for a
/// Connected Target; and the refusals of a daemon without an HDC.
/// </summary>
[TestClass]
public sealed class ViewerTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static TargetSummary Fixture => new(ScriptedDaemon.FixtureTargetId, "Bench board", "1", 3, "2026-09-29T10:00:00Z", "3.2.0f");

    [TestMethod]
    public async Task AViewIsCapturedVerifiedAndParsed()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Viewer));
        var state = await loader.ViewerAsync();
        Assert.IsTrue(state.Operation.IsAvailable);
        var target = state.JoinedTargets.Single();
        Assert.AreEqual(("Bench board", true), (target.Title, target.Connected));

        var captured = await loader.CaptureViewAsync(target.Target);
        Assert.IsNull(captured.Failure, captured.Failure);
        var capture = captured.Capture!;
        Assert.IsTrue(capture.CoordinatesAreVerified);
        Assert.AreEqual((400, 800), (capture.ScreenshotWidth, capture.ScreenshotHeight));
        Assert.IsTrue(capture.Nodes.Count > 3, $"{capture.Nodes.Count} nodes");
        Assert.IsTrue(captured.Metrics!.ReadBytes > 1000);
        var root = capture.PrimaryRootIdentity;
        var hit = UIDumpCapture.HitTest(capture, root, 200, 400);
        Assert.IsNotNull(hit);

        var node = capture.Nodes.FirstOrDefault(n => UIDumpCapture.AdvancedDumpSelectionFor(capture, n.Identity) is not null);
        if (node is not null)
        {
            var dump = await loader.AdvancedDumpAsync(target.Target, UIDumpCapture.AdvancedDumpSelectionFor(capture, node.Identity)!);
            Assert.IsNull(dump.Failure, dump.Failure);
            CollectionAssert.Contains(dump.Fields!.Select(f => $"{f.Key}={f.Value}").ToArray(), "text=Sign in");
        }
        var direct = await loader.AdvancedDumpAsync(target.Target, new ViewerAdvancedDumpSelection("7", "42"));
        Assert.IsNull(direct.Failure, direct.Failure);
        Assert.AreEqual("Button", direct.Fields!.Single(f => f.Key == "type").Value);
        Assert.AreEqual("windowId and componentId must be 1...20 ASCII decimal digits",
            (await loader.AdvancedDumpAsync(target.Target, new ViewerAdvancedDumpSelection("7", "4x"))).Failure);
    }

    [TestMethod]
    public void AConnectedTargetIsTheMacOsRoute()
    {
        DeviceCandidate Candidate(string key, string state, bool stale, string? target) => new(key, state, stale, null, target, target is null ? null : 3, "DAYU200", null, null);
        var targets = new[] { Fixture };
        Assert.IsTrue(ViewerTarget.Join(targets, Loaded<IReadOnlyList<DeviceCandidate>>.Of([Candidate("a", "Connected", false, Fixture.TargetId)])).Single().Connected);
        Assert.AreEqual("HDC reported Unauthorized",
            ViewerTarget.Join(targets, Loaded<IReadOnlyList<DeviceCandidate>>.Of([Candidate("a", "Unauthorized", false, Fixture.TargetId)])).Single().BlockedReason);
        Assert.AreEqual("HDC reported Connected, but that observation is stale",
            ViewerTarget.Join(targets, Loaded<IReadOnlyList<DeviceCandidate>>.Of([Candidate("a", "Connected", true, Fixture.TargetId)])).Single().BlockedReason);
        Assert.AreEqual($"Runtime reported more than one current route for target {Fixture.TargetId}",
            ViewerTarget.Join(targets, Loaded<IReadOnlyList<DeviceCandidate>>.Of([Candidate("a", "Connected", false, Fixture.TargetId), Candidate("b", "Offline", false, Fixture.TargetId)])).Single().BlockedReason);
        Assert.AreEqual("No current HDC route was reported for this target",
            ViewerTarget.Join(targets, Loaded<IReadOnlyList<DeviceCandidate>>.Of([])).Single().BlockedReason);
        Assert.AreEqual("Could not read current device state: hdc.notConfigured",
            ViewerTarget.Join(targets, Loaded<IReadOnlyList<DeviceCandidate>>.Not(new Unavailable("rejected", "hdc.notConfigured", CliCommands.DeviceCandidates, null))).Single().BlockedReason);
    }

    [TestMethod]
    public async Task ADaemonWithoutAnHdcRefusesTheCapture()
    {
        var state = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.DevelopmentRoot)).ViewerAsync();
        Assert.AreEqual("Could not read current device state: hdc.notConfigured", state.JoinedTargets.Single().BlockedReason);
        var jobs = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var captured = await jobs.CaptureViewAsync(Fixture);
        Assert.IsNull(captured.Capture);
        StringAssert.StartsWith(captured.Failure, "Viewer capture is missing exactly one of its Artifacts");
    }
}
