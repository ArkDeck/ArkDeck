using System.Text;
using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>
/// The Debug workspace through ClientKit (TASK-XPA-020): the six operations' facts, the probe,
/// and each closed typed action as the macOS <c>DebugApplicationFacade</c> sends it. The scripted
/// <see cref="ScriptedDaemon.Jobs"/> replays the recorded Swift oracles (capture-diagnostics,
/// debug-hap, deploy-native-library, port-forward, debug-probe) and the Windows daemon's
/// measured operation descriptions.
/// </summary>
[TestClass]
public sealed class DebugTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static TargetSummary Fixture => new(ScriptedDaemon.FixtureTargetId, "Bench board", "1", 3, "2026-09-29T10:00:00Z", "3.2.0f");

    [TestMethod]
    public async Task TheWorkspaceReadsTheOperationsTargetsAndProbe()
    {
        var state = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs)).DebugAsync(null);
        CollectionAssert.AreEqual(DebugOperations.All.ToArray(), state.Operations.Select(o => o.Reference).ToArray());
        Assert.IsTrue(state.Operations.All(o => o.IsAvailable));
        var native = state.Operation(DebugOperations.NativeLibrary)!;
        Assert.AreEqual("deviceMutation", native.MinimumEffect);
        Assert.AreEqual(11, native.Steps.Count);
        Assert.AreEqual("verify-elf-locally", native.Steps[0].Id);
        Assert.AreEqual(536_870_912, state.Operation(DebugOperations.CaptureDiagnostics)!.OutputByteBudget);
        Assert.AreEqual(ScriptedDaemon.FixtureTargetId, state.Targets.Value!.Single().TargetId);
        var probe = state.Probe!.Value!;
        CollectionAssert.AreEqual(new[] { "com.example.alpha", "com.example.zeta" }, probe.Packages.ToArray());
        Assert.AreEqual(2, probe.PortRules.Count);
    }

    [TestMethod]
    public async Task TheFoundationAnswersAsMeasured()
    {
        var state = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Foundation)).DebugAsync(null);
        Assert.IsTrue(state.Operations.All(o => !o.IsAvailable && o.Availability.Reasons.Count == 1));
        Assert.AreEqual("unavailable(internalError): Target owner is not configured", state.Targets.Unavailable!.ReasonText(English));
        Assert.IsNull(state.Probe, "no Target, no probe");
    }

    [TestMethod]
    public async Task ALogCaptureIsSubmittedRunAndListed()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var submitted = await loader.SubmitLogsAsync(Fixture, 30, ["tag:ArkUI", "level:warn"]);
        Assert.IsNull(submitted.Failure, submitted.Failure?.ReasonText(English));
        var terminal = (await loader.RunJobAsync(submitted.JobId!, CliCommands.JobRun)).Answer.Value!;
        Assert.AreEqual("succeeded", terminal.State);
        Assert.IsTrue(terminal.Succeeded);
        Assert.AreEqual("running->succeeded", terminal.Timeline[^1]);
        var job = (await loader.DebugAsync(null)).Jobs.Value!.First();
        Assert.AreEqual((submitted.JobId, DebugOperations.CaptureDiagnostics, "succeeded"), (job.JobId, job.Operation, job.State));

        var refused = await loader.SubmitLogsAsync(Fixture, 30, ["tag:$(rm)"]);
        Assert.AreEqual("unavailable(invalidInput): HiLog request is outside the published bounds", refused.Failure!.ReasonText(English));
    }

    [TestMethod]
    public async Task ACancelledJobEndsCancelled()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var submitted = await loader.SubmitTemplateAsync(Fixture, "device.uptime");
        Assert.IsTrue((await loader.CancelJobAsync(submitted.JobId!)).Answer.Value!.Requested);
        var terminal = (await loader.RunJobAsync(submitted.JobId!, CliCommands.JobRun)).Answer.Value!;
        Assert.AreEqual(("cancelled", "cancelled"), (terminal.State, terminal.FailureCode));
        Assert.AreEqual("unavailable(invalidInput): Unknown Debug template", (await loader.SubmitTemplateAsync(Fixture, "device.shell")).Failure!.ReasonText(English));
    }

    [TestMethod]
    public async Task PortRulesAreCreatedAndRemovedThroughJobs()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var rule = new DebugPortRule("forward", 9200, 9201);
        var created = await loader.SubmitPortRuleAsync(Fixture, rule, removing: false);
        await loader.RunJobAsync(created.JobId!, CliCommands.JobRun);
        Assert.IsTrue((await loader.DebugAsync(null)).Probe!.Value!.PortRules.Contains(rule));
        var removed = await loader.SubmitPortRuleAsync(Fixture, rule, removing: true);
        await loader.RunJobAsync(removed.JobId!, CliCommands.JobRun);
        Assert.IsFalse((await loader.DebugAsync(null)).Probe!.Value!.PortRules.Contains(rule));
        Assert.AreEqual("localPortOutOfRange", DebugOperations.PortRuleFailure("80", "9001", out _, out _));
        Assert.AreEqual("remotePortNotNumeric", DebugOperations.PortRuleFailure("9000", "90a1", out _, out _));
        Assert.IsNull(DebugOperations.PortRuleFailure("9000", "9001", out var local, out var remote));
        Assert.AreEqual((9000, 9001), (local, remote));
    }

    [TestMethod]
    public async Task AHapIsImportedThenSubmittedWithItsLeases()
    {
        using var directory = new TemporaryFolder();
        var entry = directory.Hap("entry.hap", 1);
        var feature = directory.Hap("feature.hsp", 2);
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var submitted = await loader.SubmitHapAsync(Fixture, entry, [feature], "com.example.demo", "EntryAbility", "uninstall", "stopped", true, 30, CancellationToken.None);
        Assert.IsNull(submitted.Failure, submitted.Failure?.ReasonText(English));
        var terminal = (await loader.RunJobAsync(submitted.JobId!, CliCommands.JobRun)).Answer.Value!;
        Assert.AreEqual("succeeded", terminal.State);
        var imports = (await loader.ImportsAsync()).Imports.Value!;
        Assert.IsTrue(imports.Count(i => i.State == "committed" && i.Kind == "hap") >= 2, "both packages were imported");

        var duplicate = directory.Hap("again.hap", 1);
        var refused = await loader.SubmitHapAsync(Fixture, entry, [duplicate], "com.example.demo", "EntryAbility", "uninstall", "stopped", true, 30, CancellationToken.None);
        Assert.AreEqual("unavailable(invalidInput): Select each package only once; duplicate files or bytes were found", refused.Failure!.ReasonText(English));
        Assert.AreEqual("invalidEntry", DebugOperations.PackageSelectionFailure(feature, []));
        Assert.AreEqual("invalidAdditional", DebugOperations.PackageSelectionFailure(entry, [Path.Combine(directory.Path, "notes.txt")]));
        Assert.AreEqual("duplicatePackage", DebugOperations.PackageSelectionFailure(entry, [entry]));
        var bounds = await loader.SubmitHapAsync(Fixture, entry, [], "demo", "EntryAbility", "uninstall", "stopped", true, 30, CancellationToken.None);
        Assert.AreEqual("unavailable(invalidInput): HAP request is outside the published bounds", bounds.Failure!.ReasonText(English));
    }

    [TestMethod]
    public async Task ANativeLibraryIsPlannedReviewedAndSubmittedAsReviewed()
    {
        using var directory = new TemporaryFolder();
        var library = Path.Combine(directory.Path, "libexample.so");
        File.WriteAllBytes(library, Enumerable.Range(0, 588).Select(i => (byte)i).ToArray());
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var steps = (await loader.DebugAsync(null)).Operation(DebugOperations.NativeLibrary)!.Steps;
        var outcome = await loader.PrepareNativeLibraryAsync(Fixture, library, "com.example.demo", "libexample.so", "hashProcessAndMaps", "autoRollback", steps, CancellationToken.None);
        Assert.IsNull(outcome.Failure, outcome.Failure?.ReasonText(English));
        var plan = outcome.Prepared!;
        Assert.AreEqual(("arm64-v8a", 64L, 183L), (plan.Abi, plan.ElfClassBits, plan.Machine));
        Assert.AreEqual("600694d55fd146f2ddc3a8c7541f517f77a9a1f6b72f914be43dda94d0f3dc1a", plan.PlanDigest);
        Assert.AreEqual(11, plan.Steps.Count);
        using (var reviewed = JsonDocument.Parse(plan.Reviewed.Json))
        {
            Assert.AreEqual(plan.PlanDigest, reviewed.RootElement.GetProperty("reviewedPlanDigest").GetString());
            Assert.AreEqual("arm64-v8a", reviewed.RootElement.GetProperty("inputs").GetProperty("expectedABI").GetString());
            Assert.IsFalse(reviewed.RootElement.GetProperty("clientContext").TryGetProperty("provenance", out _), "the Artifacts client files no thread");
        }
        var submitted = await loader.SubmitNativeLibraryAsync(plan);
        Assert.IsNull(submitted.Failure, submitted.Failure?.ReasonText(English));
        var ran = await loader.RunJobAsync(submitted.JobId!, CliCommands.JobRun);
        Assert.IsNull(ran.Answer.Unavailable, ran.Answer.Unavailable?.ReasonText(English));
        Assert.AreEqual("succeeded", ran.Answer.Value!.State);

        var wrong = await loader.PrepareNativeLibraryAsync(Fixture, library, "com.example.demo", "example.so", "hashProcessAndMaps", "autoRollback", steps, CancellationToken.None);
        Assert.AreEqual("unavailable(invalidInput): Complete the bundle, library name and published verification settings", wrong.Failure!.ReasonText(English));
    }

    [TestMethod]
    public void TheRequestIsTheMacOsDocument()
    {
        var request = RuntimeRequest.Build("debug-logs-ui", "capture.diagnostics", 1, "TGT-1", 2, [("durationSeconds", JsonNumber.FromInt64(5))],
            ["derivedArtifacts"], DebugOperations.LogsClient);
        using var document = JsonDocument.Parse(request.Json);
        var root = document.RootElement;
        CollectionAssert.AreEqual(new[] { "clientContext", "documentType", "idempotencyKey", "inputs", "operation", "requestId", "requestedOutputs", "schemaVersion", "target" },
            root.EnumerateObject().Select(p => p.Name).ToArray(), "canonical: sorted keys, no authorization");
        Assert.AreEqual("runtime-operation-request", root.GetProperty("documentType").GetString());
        Assert.AreEqual(2, root.GetProperty("target").GetProperty("expectedBindingRevision").GetInt64());
        StringAssert.StartsWith(root.GetProperty("requestId").GetString(), "debug-logs-ui-");
        StringAssert.Matches(root.GetProperty("clientContext").GetProperty("provenance").GetProperty("arkdeck.threadId").GetString(), new("^t-[0-9a-f]{12}$"));
        // RuntimeWorkspaceThread.identifier: "t-" + SHA-256("salt|client|target")[..12].
        Assert.AreEqual("t-" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("s|c|t")))[..12], RuntimeRequest.ThreadId("c", "t", "s"));
    }

    [TestMethod]
    public void TheTypedValuesFollowTheMacOsValidators()
    {
        Assert.IsTrue(DebugOperations.IsValidBundleName("com.example.app"));
        Assert.IsFalse(DebugOperations.IsValidBundleName("example"));
        Assert.IsFalse(DebugOperations.IsValidBundleName("com.example.app;rm"));
        Assert.IsTrue(DebugOperations.IsValidAbilityName("EntryAbility"));
        Assert.IsFalse(DebugOperations.IsValidAbilityName("1Entry"));
        Assert.IsTrue(DebugOperations.IsValidNativeLibraryName("libfeature_debug.so"));
        Assert.IsFalse(DebugOperations.IsValidNativeLibraryName("feature.so"));
        Assert.IsTrue(DebugOperations.IsSafeHilogComponent("level:warn"));
        Assert.IsFalse(DebugOperations.IsSafeHilogComponent("a b"));
        Assert.IsFalse(DebugOperations.IsSafeHilogComponent(new string('a', 201)));
    }

    [TestMethod]
    public void EveryRecordedDebugAnswerIsReadable()
    {
        var plans = 0;
        foreach (var corpus in new[] { "capture-diagnostics", "debug-hap", "deploy-native-library", "port-forward" })
        {
            using var cases = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("rust", "tests", "fixtures", corpus, "cases.json")));
            foreach (var exchange in cases.RootElement.GetProperty("exchanges").EnumerateArray())
            {
                var answer = exchange.GetProperty("answer");
                if (!answer.GetProperty("ok").GetBoolean()) continue;
                var value = StrictJson.Parse(Encoding.UTF8.GetBytes(answer.GetProperty("result").GetRawText()));
                switch (exchange.GetProperty("method").GetString())
                {
                    case "job.plan":
                        JobPlan.Parse(value);
                        plans++;
                        break;
                    case "job.submit":
                        JobAcceptance.Parse(value);
                        break;
                }
            }
        }
        Assert.IsTrue(plans >= 12, plans.ToString());
        var target = new TargetSummary(ScriptedDaemon.OracleTargetId, null, "1", 1, "2026-09-14T00:00:00Z", "3.2.0d");
        using var probes = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("rust", "tests", "fixtures", "debug-probe", "cases.json")));
        var read = 0;
        foreach (var exchange in probes.RootElement.GetProperty("exchanges").EnumerateArray())
        {
            if (exchange.GetProperty("method").GetString() != "debug.probe" || !exchange.GetProperty("answer").GetProperty("ok").GetBoolean()) continue;
            DebugProbe.Parse(StrictJson.Parse(Encoding.UTF8.GetBytes(exchange.GetProperty("answer").GetProperty("result").GetRawText())), target);
            read++;
        }
        Assert.IsTrue(read >= 1);
    }

    private sealed class TemporaryFolder : IDisposable
    {
        public string Path { get; } = Directory.CreateTempSubdirectory("arkdeck-app-debug-").FullName;

        /// <summary>A package whose bytes open a ZIP container (a HAP's publication check).</summary>
        public string Hap(string name, byte seed)
        {
            var path = System.IO.Path.Combine(Path, name);
            var bytes = Enumerable.Range(0, 4096).Select(i => (byte)(i * seed % 251)).ToArray();
            "PK\u0003\u0004"u8.CopyTo(bytes);
            File.WriteAllBytes(path, bytes);
            return path;
        }

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
