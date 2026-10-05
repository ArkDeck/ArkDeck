using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>The Device section's names and the bounded trust wait (macOS
/// <c>DeviceListViewModel</c> and <c>boundedAuthorizationWait</c>).</summary>
[TestClass]
public sealed class DeviceTrustTests
{
    private static DeviceCandidate Candidate(string key, string state = "Unauthorized", string? target = null, string? runtimeName = null, string? deviceName = null) =>
        new(key, state, false, runtimeName, target, target is null ? null : 3, deviceName, null, null);

    [TestMethod]
    public void AnAliasNamesOnlyADeviceNotAdoptedYet()
    {
        Assert.AreEqual("Spare board", DeviceTrust.NormalizeAlias("  Spare \t  board "));
        Assert.IsNull(DeviceTrust.NormalizeAlias("   "));
        Assert.IsNull(DeviceTrust.NormalizeAlias(new string('x', 65)));
        var aliases = new Dictionary<string, string> { ["k1"] = "Spare", ["k2"] = "Ignored" };
        Assert.AreEqual("Spare", DeviceTrust.Title(Candidate("k1", deviceName: "DAYU200"), aliases));
        Assert.AreEqual("Bench", DeviceTrust.Title(Candidate("k2", "Connected", "TGT-1", "Bench"), aliases), "an adopted Target's name is the Runtime's");
        Assert.AreEqual("TGT-1", DeviceTrust.Title(Candidate("k3", "Connected", "TGT-1"), aliases));
        Assert.AreEqual("k4", DeviceTrust.Title(Candidate("k4"), aliases));
    }

    [TestMethod]
    public async Task TheWaitEndsWhenTheDeviceTrustsThisComputerOrTheWindowCloses()
    {
        var trusting = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Trust));
        var ready = await trusting.WaitForTrustAsync("fixture-serial-2", TimeSpan.FromSeconds(30), TimeSpan.FromMilliseconds(50), CancellationToken.None);
        Assert.AreEqual(TrustWaitOutcome.Ready, ready.Outcome);

        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var timedOut = await loader.WaitForTrustAsync("fixture-serial-2", TimeSpan.FromMilliseconds(300), TimeSpan.FromMilliseconds(50), CancellationToken.None);
        Assert.AreEqual(TrustWaitOutcome.TimedOut, timedOut.Outcome);
        var gone = await loader.WaitForTrustAsync("no-such-device", TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(50), CancellationToken.None);
        Assert.AreEqual((TrustWaitOutcome.Unavailable, "The selected device is no longer visible"), (gone.Outcome, gone.Reason));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.AreEqual(TrustWaitOutcome.Cancelled, (await loader.WaitForTrustAsync("fixture-serial-2", TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(50), cancelled.Token)).Outcome);

        var foundation = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Foundation));
        Assert.AreEqual(TrustWaitOutcome.Unavailable, (await foundation.WaitForTrustAsync("fixture-serial-2", TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(50), CancellationToken.None)).Outcome);

        // A verdict ends once a later read shows the device in another state; a failed read ends nothing.
        Assert.IsFalse(DeviceTrust.EndsVerdict(timedOut.Latest, "fixture-serial-2", timedOut.Latest));
        Assert.IsTrue(DeviceTrust.EndsVerdict(ready.Latest, "fixture-serial-2", timedOut.Latest));
        Assert.IsFalse(DeviceTrust.EndsVerdict(Loaded<IReadOnlyList<DeviceCandidate>>.Not(new("rejected", "x", "c", null)), "fixture-serial-2", timedOut.Latest));
    }

    [TestMethod]
    public void OnlyATestTransportRunShortensTheWaitOrObservesOnItsOwn()
    {
        Assert.AreEqual((false, (int?)null), (LaunchOptions.Parse(["--trust-wait-fast", "--live-observation-ms", "300"]).FastTrustWait, LaunchOptions.Parse(["--live-observation-ms", "300"]).LiveObservationMilliseconds));
        var test = LaunchOptions.Parse(["--test-transport", "jobs", "--trust-wait-fast", "--live-observation-ms", "300"]);
        Assert.AreEqual((true, (int?)300), (test.FastTrustWait, test.LiveObservationMilliseconds));

        var root = Directory.CreateTempSubdirectory("arkdeck-preferences-").FullName;
        try
        {
            var preferences = new AppPreferences(root);
            preferences.SetDeviceAlias("k1", "Spare");
            preferences.SetDeviceAlias("k2", "Other");
            preferences.SetDeviceAlias("k1", null);
            CollectionAssert.AreEquivalent(new[] { "k2" }, new AppPreferences(root).DeviceAliases.Keys.ToArray());
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
