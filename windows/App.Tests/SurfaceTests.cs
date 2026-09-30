using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.App.Tests;

/// <summary>
/// What each surface shows for each daemon answer, read through ClientKit (the scripted
/// transport feeds ClientKit's real codec, health preflight and method schemas, so a scripted
/// reply the contract refuses would fail here).
/// </summary>
[TestClass]
public sealed class SurfaceTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static SurfaceLoader Loader(string scenario) => new(ScriptedDaemon.Channel(scenario));

    [TestMethod]
    public async Task NothingAnsweringShowsTheRecoveryBannerAndNoData()
    {
        var loader = Loader(ScriptedDaemon.Unavailable);
        var overview = await loader.OverviewAsync();
        Assert.IsNotNull(overview.DaemonFailure);
        Assert.IsFalse(overview.Reached);
        foreach (var why in new[] { overview.Health.Unavailable, overview.Doctor.Unavailable, overview.Recent.Unavailable })
        {
            Assert.AreEqual(Unavailable.DaemonUnavailableCode, why!.ReasonCode);
        }
        Assert.IsNull(overview.Doctor.Value);
        var banner = RecoveryBannerState.For(overview.DaemonFailure!, English);
        Assert.AreEqual(RecoveryKind.NotRunning, banner.Kind);
        Assert.AreEqual("ArkDeck Runtime unavailable", banner.Title);
        Assert.AreEqual("arkdeck doctor", banner.CliCommand);
        StringAssert.StartsWith(banner.Reason, "Reason: HealthExchangeFailed: ");

        var history = await loader.HistoryAsync();
        Assert.AreEqual(Unavailable.DaemonUnavailableCode, history.Jobs.Unavailable!.ReasonCode);
        Assert.AreEqual("arkdeck job list", history.Jobs.Unavailable.CliCommand);
    }

    [TestMethod]
    public async Task AnotherContractShowsTheContractBanner()
    {
        var overview = await Loader(ScriptedDaemon.ContractMismatch).OverviewAsync();
        Assert.AreEqual(DaemonUnavailableReason.ContractMismatch, overview.DaemonFailure!.Reason);
        Assert.AreEqual(RecoveryKind.Contract, RecoveryBannerState.For(overview.DaemonFailure, English).Kind);
    }

    [TestMethod]
    public async Task TodaysWindowsDaemonShowsDoctorAndItsRefusalsAsTheyCame()
    {
        var loader = Loader(ScriptedDaemon.Foundation);
        var overview = await loader.OverviewAsync();
        Assert.IsNull(overview.DaemonFailure);
        Assert.IsTrue(overview.Reached);
        Assert.AreEqual(ControlContract.ContractIdentity, overview.Health.Value!.ContractIdentity);
        Assert.AreEqual("blocked", overview.Doctor.Value!.Overall);
        Assert.AreEqual(2, overview.Doctor.Value.Blockers);
        Assert.AreEqual("rejected", overview.Recent.Unavailable!.ReasonCode);
        Assert.AreEqual("unavailable(rejected): The Job owner is not configured", overview.Recent.Unavailable.ReasonText(English));

        var device = await loader.DeviceAsync();
        Assert.AreEqual("unavailable(rejected): hdc.notConfigured", device.Candidates.Unavailable!.ReasonText(English));
        Assert.AreEqual("CLI: arkdeck device candidates", device.Candidates.Unavailable.CliText(English));
        Assert.IsFalse(device.Candidates.Unavailable.IsDaemonUnavailable, "a refusal is data from the daemon, not a missing daemon");
    }

    [TestMethod]
    public async Task CandidatesAndJobsAreShownAsTheDaemonProjectsThem()
    {
        var loader = Loader(ScriptedDaemon.Jobs);
        var device = await loader.DeviceAsync();
        var candidates = device.Candidates.Value!;
        CollectionAssert.AreEqual(
            new[] { UiStrings.DeviceStateReady, UiStrings.DeviceStateNeedsTrust, UiStrings.DeviceStateOffline },
            candidates.Select(c => c.StateKey).ToArray());
        Assert.AreEqual("Bench board", candidates[0].Title);
        Assert.AreEqual("fixture-serial-2", candidates[1].Title);

        var history = await loader.HistoryAsync();
        Assert.AreEqual(3, history.Jobs.Value!.Count);
        Assert.AreEqual(1, history.Jobs.Value.Count(j => j.IsActive));

        var seen = new List<string>();
        for (var i = 0; i < ScriptedDaemon.RunningJobStates.Count + 1; i++)
        {
            var job = await loader.JobAsync(ScriptedDaemon.RunningJobId);
            seen.Add(job.Status.Value!.State);
            Assert.AreEqual(job.Status.Value.State, job.Events.Value!.Last().ToState, "the timeline ends at the current state");
        }
        CollectionAssert.AreEqual(new[] { "running", "waitingForDevice", "running", "succeeded", "succeeded" }, seen);

        var missing = await loader.JobAsync("job-unknown");
        Assert.AreEqual("notFound", missing.Status.Unavailable!.ReasonCode);
        Assert.AreEqual("arkdeck job status --job job-unknown", missing.Status.Unavailable.CliCommand);
    }

    [TestMethod]
    public async Task WithoutADaemonIdentityNothingIsConnected()
    {
        var channel = DaemonConfiguration.Create(new LaunchOptions(null, null, null), _ => null, Path.GetTempPath());
        Assert.IsInstanceOfType<UnconfiguredChannel>(channel);
        var result = await channel.HealthAsync();
        Assert.AreEqual(ControlFailureKind.DaemonUnavailable, result.Failure!.Kind);
        Assert.AreEqual(RecoveryKind.NotConfigured, RecoveryBannerState.For(result.Failure, English).Kind);

        var invalid = DaemonConfiguration.Create(new LaunchOptions(null, null, null),
            name => name switch
            {
                "ARKDECK_DAEMON_SIGNER_SHA256" => new string('0', 64),
                "ARKDECK_ENDPOINT" => @"\\.\pipe\not-arkdeck",
                _ => null,
            }, Path.GetTempPath());
        Assert.IsInstanceOfType<UnconfiguredChannel>(invalid, "an endpoint ClientKit refuses connects to nothing");

        var configured = DaemonConfiguration.Create(new LaunchOptions(null, null, null),
            name => name == "ARKDECK_DAEMON_SIGNER_SHA256" ? new string('0', 64) : null, Path.GetTempPath());
        Assert.IsInstanceOfType<SessionChannel>(configured);
    }

    [TestMethod]
    public void LaunchOptionsAndTheScenarioListAgree()
    {
        var options = LaunchOptions.Parse(["--language", "zh-Hans", "--page", "history", "--test-transport", "jobs"]);
        Assert.AreEqual(new LaunchOptions("zh-Hans", "history", "jobs"), options);
        Assert.ThrowsExactly<ArgumentException>(() => ScriptedDaemon.Channel("no-such-scenario"));
    }
}
