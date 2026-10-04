using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>The device Overview describes (macOS <c>OverviewCapabilityApplicationFacade.targets(from:)</c>
/// and <c>presentation(from:devices:preferredTargetID:)</c>).</summary>
[TestClass]
public sealed class OverviewScopeTests
{
    private static DeviceCandidate Candidate(string key, string state, string? target, long? binding, bool stale = false, string? name = null) =>
        new(key, state, stale, null, target, binding, name, "OpenHarmony 6.0", "usb");

    [TestMethod]
    public void OnlyAuthorizedCurrentAdoptedDevicesAreOnline()
    {
        var online = OverviewScope.Online([
            Candidate("a", "Connected", "TGT-A", 1, name: "DAYU200"),
            Candidate("b", "Connected", null, null),
            Candidate("c", "Unauthorized", "TGT-C", 1),
            Candidate("d", "Connected", "TGT-D", 2, stale: true),
            Candidate("e", "Connected", "TGT-A", 1),
            Candidate("f", "Connected", "TGT-F", null),
        ]);
        CollectionAssert.AreEqual(new[] { "TGT-A" }, online.Select(t => t.TargetId).ToArray());
        Assert.AreEqual("DAYU200 · TGT-A", online[0].Title);
        CollectionAssert.AreEqual(new[] { "OpenHarmony 6.0", "usb" }, OverviewScope.Facts(online[0]).ToArray());
    }

    [TestMethod]
    public void TheChoiceWinsWhileOnlineElseTheOnlyOneElseNone()
    {
        var two = OverviewScope.Online([Candidate("a", "Connected", "TGT-A", 1), Candidate("b", "Connected", "TGT-B", 2)]);
        Assert.IsNull(OverviewScope.Selected(two, null), "several online and no choice: no scope");
        Assert.AreEqual("TGT-B", OverviewScope.Selected(two, "TGT-B")!.TargetId);
        Assert.IsNull(OverviewScope.Selected(two, "TGT-GONE"));
        Assert.AreEqual("TGT-A", OverviewScope.Selected(two.Take(1).ToArray(), "TGT-GONE")!.TargetId);
    }

    [TestMethod]
    public async Task OverviewReadsTheDeviceObservations()
    {
        var overview = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs)).OverviewAsync();
        var online = OverviewScope.Online(overview.Devices!.Value);
        Assert.AreEqual(("TGT-FIXTURE-1", 3L, "DAYU200"), (online.Single().TargetId, online.Single().BindingRevision, online.Single().Candidate.DeviceName));

        var foundation = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Foundation)).OverviewAsync();
        Assert.AreEqual(0, OverviewScope.Online(foundation.Devices!.Value).Count, "no HDC: nothing online");
    }
}
