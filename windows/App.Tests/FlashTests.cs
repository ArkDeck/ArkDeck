using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>
/// The Flash workspace through ClientKit (TASK-XPA-020): its facts, the exact plan prepared from
/// a real DAYU200 archive of the flash-archive corpus, and the one submission, over the scripted
/// <see cref="ScriptedDaemon.Flash"/> daemon (the recorded flash-host-facts and flash-run
/// canonical oracles) and <see cref="ScriptedDaemon.Jobs"/> (the Windows daemon's measured
/// flash-bundle refusal).
/// </summary>
[TestClass]
public sealed class FlashTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static TargetSummary Fixture => new(ScriptedDaemon.FixtureTargetId, "Bench board", "1", 3, "2026-09-29T10:00:00Z", "3.2.0f");

    private static string Archive => RepoPaths.At("rust", "tests", "fixtures", "flash-archive", "archives", "complete.tar.gz");

    [TestMethod]
    public async Task TheWorkspaceReadsItsFacts()
    {
        var state = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Flash)).FlashAsync();
        Assert.IsTrue(state.Operation.IsAvailable, string.Join(", ", state.Operation.Availability.Reasons));
        var access = state.DeviceAccess.Value!;
        Assert.AreEqual(("accessible", "user", "chooseSupportedLoaderObservation"), (access.Verdict, access.Responsibility, access.Remediation));
        Assert.AreEqual(("exactBoundTarget", ScriptedDaemon.FixtureTargetId, 3L), (state.Bootloader!.Disposition, state.Bootloader.TargetId, state.Bootloader.BindingRevision!.Value));
        Assert.AreEqual(ScriptedDaemon.FixtureTargetId, state.Targets.Value!.Single().TargetId);

        var real = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs)).FlashAsync();
        Assert.IsFalse(real.Operation.IsAvailable);
    }

    [TestMethod]
    public async Task TheExactPlanIsReviewedOnTheHostAndPlannedByTheRuntime()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Flash));
        var prepared = await loader.PrepareFlashAsync(Archive, Fixture, CancellationToken.None);
        Assert.IsNull(prepared.FailureCode, prepared.FailureDetail);
        var plan = prepared.Plan!;
        Assert.AreEqual("OpenHarmony-7.0.0.36", plan.Archive.RuntimeBuildVersion);
        Assert.AreEqual("1e3ab5867689c4059b6c11a080f6496ad5217e1ca3b529ea7388cb3b1657911d", plan.Archive.ArchiveSha256);
        Assert.AreEqual(9, plan.Archive.MappedPartitionCount);
        Assert.IsTrue(plan.Archive.UserDataDestroyed);
        Assert.AreEqual("9ddf625692a74679bab6af60ef9a12a662149ec98609b9bfad147a7c50c34f04", plan.PlanDigest);
        Assert.AreEqual("unknown", plan.Prerequisites.Single(p => p.Identifier == "stablePower").Status);
        Assert.AreEqual(0, plan.Blocking.Count, "the Runtime's plan-only preview passed");
        using (var reviewed = JsonDocument.Parse(plan.Request!.Json))
        {
            Assert.AreEqual(plan.PlanDigest, reviewed.RootElement.GetProperty("reviewedPlanDigest").GetString());
            Assert.AreEqual("fullRestore", reviewed.RootElement.GetProperty("inputs").GetProperty("intent").GetString());
            Assert.AreEqual(FlashOperations.Client, reviewed.RootElement.GetProperty("clientContext").GetProperty("clientName").GetString());
        }
        var imports = (await loader.ImportsAsync()).Imports.Value!;
        Assert.IsTrue(imports.Any(i => i.Kind == "flash-bundle" && i.Name == "images.tar.gz" && i.DeviceProfile == "dayu200" && i.State == "committed"));
    }

    [TestMethod]
    public async Task TheWindowsDaemonsRefusalEndsThePreparation()
    {
        var prepared = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs)).PrepareFlashAsync(Archive, Fixture, CancellationToken.None);
        Assert.AreEqual(FlashReviewFailureCode.PlanMaterializationFailed, prepared.FailureCode);
        Assert.AreEqual("invalidInput: " + ScriptedDaemon.FlashLaneAbsence, prepared.FailureDetail);
        Assert.AreEqual("OpenHarmony-7.0.0.36", prepared.Plan!.Archive.RuntimeBuildVersion, "the host review still shows");

        var unsupported = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Flash)).PrepareFlashAsync(
            RepoPaths.At("rust", "tests", "fixtures", "flash-archive", "archives", "bad-checksum.tar.gz"), Fixture, CancellationToken.None);
        Assert.AreEqual(FlashReviewFailureCode.InvalidArchive, unsupported.FailureCode);
    }

    [TestMethod]
    public async Task TheReviewedPlanRunsAndItsPostflightMatches()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Flash));
        var plan = (await loader.PrepareFlashAsync(Archive, Fixture, CancellationToken.None)).Plan!;
        var submitted = await loader.SubmitFlashAsync(plan);
        Assert.IsNull(submitted.Failure, submitted.Failure?.ReasonText(English));
        var status = (await loader.RunFlashAsync(submitted.JobId!)).Answer.Value!;
        Assert.AreEqual("succeeded", status.State);
        Assert.IsTrue(status.IsLiveTerminal);
        var evidence = (await loader.FlashEvidenceAsync(submitted.JobId!)).Answer.Value!;
        Assert.AreEqual(("succeeded", "OpenHarmony-7.0.0.36", 3L), (evidence.TerminalState, evidence.ObservedFirmware, evidence.ObservedBindingRevision!.Value));
        Assert.AreEqual(0, evidence.Blockers.Count);
        var state = await loader.FlashAsync();
        Assert.AreEqual(submitted.JobId, state.Focused!.JobId);
        Assert.AreEqual(1, state.FlashJobCount);

        var unreviewed = await loader.SubmitFlashAsync(plan with { PlanDigest = null });
        Assert.AreEqual("unavailable(invalidInput): Only a bound execute plan can be submitted", unreviewed.Failure!.ReasonText(English));
    }

    [TestMethod]
    public void TheProgressProjectsAsTheMacOsProjector()
    {
        var partitions = new[]
        {
            new FlashPartitionRow(1, "uboot", "uboot.img", 100, "a"),
            new FlashPartitionRow(2, "system", "system.img", 300, "b"),
        };
        Assert.AreEqual(FlashPhase.ImportingImage, FlashLiveProgress.Project(null, partitions).Phase);
        var writing = FlashLiveProgress.Project(new FlashRunStatus("j", "running", false, [], new FlashProcessProgress("flash-partitions", "writing", "system", 1, 2, 50)), partitions);
        Assert.AreEqual((FlashPhase.WritingPartition, 62, 1), (writing.Phase, writing.WritePercent!.Value, writing.Stage), "byte-weighted: (100 + 150) / 400");
        var staging = FlashLiveProgress.Project(new FlashRunStatus("j", "running", false, [], new FlashProcessProgress("flash-partitions", "staging", null, 0, 2, null)), partitions);
        Assert.AreEqual(FlashPhase.ExtractingImage, staging.Phase);
        Assert.AreEqual(FlashPhase.EnteringBootloader, FlashLiveProgress.Project(new FlashRunStatus("j", "running", false, ["intent enter-loader-mode"], null), partitions).Phase);
        Assert.AreEqual(FlashPhase.ReconnectingDevice, FlashLiveProgress.Project(new FlashRunStatus("j", "running", false, ["intent wait-for-hdc"], null), partitions).Phase);
        Assert.AreEqual(FlashPhase.VerifyingSystem, FlashLiveProgress.Project(new FlashRunStatus("j", "running", false, ["verified rebind-and-verify-build"], null), partitions).Phase);
        Assert.AreEqual(FlashPhase.RebootingDevice, FlashLiveProgress.Project(new FlashRunStatus("j", "running", false, ["intent reboot-device"], null), partitions).Phase);
        Assert.AreEqual(2, FlashLiveProgress.Project(new FlashRunStatus("j", "running", false, ["intent verify-flash-readback"], null), partitions).Stage);
    }

    [TestMethod]
    public void TheCatalogReviewIsTheOneTheMacOsAppCompilesIn()
    {
        var swift = File.ReadAllText(RepoPaths.At("Packages", "ArkDeckKit", "Sources", "ArkDeckCore", "FlashReviewCatalogGenerated.swift"));
        var literal = swift[(swift.IndexOf("#\"\"\"", StringComparison.Ordinal) + 4)..swift.IndexOf("\"\"\"#", StringComparison.Ordinal)];
        using var expected = JsonDocument.Parse(literal);
        using var embedded = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("windows", "App.Core", "Catalog", "flash-catalog-review.json")));
        Assert.IsTrue(JsonElement.DeepEquals(expected.RootElement, embedded.RootElement), "regenerate App.Core/Catalog/flash-catalog-review.json from FlashReviewCatalogGenerated.swift");
        var review = FlashOperations.CatalogReview.Value;
        Assert.AreEqual(("c1ab01f8c7c24649080d109c481f9c034ffb73edcc62033684ac8a59875e0b12", 14, "destructive"), (review.StepSetDigest, review.Steps.Count, review.HighestEffect));
        var stages = review.Stages();
        CollectionAssert.AreEqual(new[] { "verify-image-bundle", "hash-images", "confirm-flash-intent" }, stages[0].Select(s => s.Id).ToArray());
        Assert.AreEqual("enter-loader-mode", stages[1][0].Id);
        CollectionAssert.AreEqual(new[] { "flash-partitions" }, stages[2].Select(s => s.Id).ToArray());
        Assert.AreEqual("finalize-session", stages[3][^1].Id);
    }
}
