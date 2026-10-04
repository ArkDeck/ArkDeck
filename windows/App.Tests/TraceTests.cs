using System.Security.Cryptography;
using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>
/// The Trace workspace and viewer through ClientKit (TASK-XPA-021): the probe checks and capture
/// blockers the macOS App applies, the duration entry, one capture over the scripted
/// <see cref="ScriptedDaemon.Viewer"/> daemon (the recorded trace-probe and capture-diagnostics-trace
/// oracles) opened in the viewer from its verified Artifact, and the Runtime's refusals.
/// </summary>
[TestClass]
public sealed class TraceTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static TargetSummary Fixture => new(ScriptedDaemon.FixtureTargetId, "Bench board", "1", 3, "2026-09-29T10:00:00Z", "3.2.0f");

    private static TargetSummary Oracle => new(ScriptedDaemon.OracleTargetId, null, "1", 1, "2026-09-14T00:00:00Z", "3.2.0d");

    [TestMethod]
    public async Task TheWorkspaceReadsTheProbeOfTheSelectedTarget()
    {
        var state = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Viewer)).TraceAsync(null);
        Assert.IsTrue(state.Operation.IsAvailable, string.Join(", ", state.Operation.Availability.Reasons));
        Assert.AreEqual((1L, 600L), state.DurationRange);
        Assert.AreEqual(8_192, state.CaptureBufferKB);
        var target = state.JoinedTargets.Single();
        Assert.AreEqual(("Bench board", "OpenHarmony 6.0 · fixt…ial-1 · USB", true), (target.Title, target.ConnectionSummary, target.Connected));
        var probe = state.ProbeOf(target)!;
        Assert.IsTrue(probe.IsCaptureEligible);
        Assert.AreEqual(("hitrace", "hitrace.dayu200-oh7.text", 9), (probe.Tool, probe.Family, probe.Parameters.Count));
        Assert.AreEqual(0, state.Blockers(target, TraceOperations.Preset("arkuiDeep"), durationValid: true).Count);
        Assert.AreEqual(ScriptedDaemon.FixtureTargetId, state.ResolveSelection(null, null));

        var refused = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.DevelopmentRoot)).TraceAsync(null);
        Assert.AreEqual($"unavailable(internalError): {ScriptedDaemon.TraceProbeRefusal}", refused.Probe!.Unavailable!.ReasonText(English));
        var blockers = refused.Blockers(refused.JoinedTargets.Single(), TraceOperations.Preset("arkuiDeep"), durationValid: true);
        Assert.IsTrue(blockers.Any(b => b.Key == "trace.blocker.capability"), "no probe, no capture");
    }

    [TestMethod]
    public void TheBlockersAreTheMacOsBlockersInOrder()
    {
        var target = new TraceTarget(Fixture, null, null, null, null, true);
        OperationFacts Operation(AvailabilityKind kind, params string[] reasons) =>
            new(TraceOperations.Reference, "Capture", "readOnly", 0, 0, new OperationReadiness(kind, reasons), [],
                [new OperationInput("durationSeconds", 1, 600), new OperationInput("traceBufferKB", 16_384, 65_536)]);
        TraceProbe Probe(string disposition, params string[] tags) => new(Fixture.TargetId, 3, disposition, "hitrace", "family", tags, [],
            TraceOperations.ParameterNames.Select(n => new TraceProbeParameter(n, "missing", null, null)).ToArray());
        TraceState State(OperationFacts operation, TraceProbe? probe) =>
            new(operation, Loaded<IReadOnlyList<TargetSummary>>.Of([Fixture]), null, probe is null ? null : Loaded<TraceProbe>.Of(probe), Loaded<IReadOnlyList<RecentJob>>.Of([]), null, true);
        string[] Keys(TraceState state, TraceTarget? t, bool duration = true) =>
            state.Blockers(t, TraceOperations.Preset("io"), duration).Select(b => b.Key ?? b.Text!).ToArray();

        CollectionAssert.AreEqual(new[] { "trace.blocker.operation", "provider hdc is not registered", "trace.blocker.target", "trace.blocker.duration", "trace.blocker.buffer", "trace.blocker.capability" },
            Keys(State(Operation(AvailabilityKind.Unavailable, "provider hdc is not registered"), null), null, duration: false));
        CollectionAssert.AreEqual(new[] { "trace.blocker.checking", "trace.blocker.buffer", "trace.blocker.adapterUnsupported" },
            Keys(State(Operation(AvailabilityKind.Checking), Probe("unsupported")), target));
        CollectionAssert.AreEqual(new[] { "trace.blocker.buffer", "trace.blocker.tags" },
            Keys(State(Operation(AvailabilityKind.Available), Probe("captureEligible", "disk", "sched")), target));
    }

    [TestMethod]
    public void TheDurationEntryIsTheMacOsEntry()
    {
        (long, long) range = (1, 600);
        Assert.AreEqual((1L, 10L), TraceDuration.InputRange(TraceDurationUnit.Minutes, range));
        Assert.IsNull(TraceDuration.InputRange(TraceDurationUnit.Minutes, (1, 59)));
        Assert.AreEqual((2L, 3L), TraceDuration.InputRange(TraceDurationUnit.Minutes, (61, 200)));
        Assert.AreEqual(1L, TraceDuration.InputValue(TraceDurationUnit.Minutes, 10, range), "minutes round up");
        Assert.AreEqual(90L, TraceDuration.InputValue(TraceDurationUnit.Seconds, 90, range));
        Assert.AreEqual(120, TraceDuration.Validate("2", TraceDurationUnit.Minutes, range).Seconds);
        Assert.AreEqual(TraceDurationFailure.Missing, TraceDuration.Validate("", TraceDurationUnit.Seconds, range).Failure);
        Assert.AreEqual(TraceDurationFailure.NotDecimal, TraceDuration.Validate("1.5", TraceDurationUnit.Seconds, range).Failure);
        Assert.AreEqual(TraceDurationFailure.NotDecimal, TraceDuration.Validate("１０", TraceDurationUnit.Seconds, range).Failure, "ASCII digits only");
        var outside = TraceDuration.Validate("11", TraceDurationUnit.Minutes, range);
        Assert.AreEqual((TraceDurationFailure.OutsideRange, (1L, 10L)), (outside.Failure!.Value, outside.InputRange));
        Assert.AreEqual("Enter a value from 1 through 10.", English.Format(UiStrings.TraceValidationRange, 1L, 10L));
        CollectionAssert.AreEqual(new[] { 5, 10, 15, 30 }, TraceDuration.QuickValues(TraceDurationUnit.Seconds).ToArray());
        Assert.AreEqual("traceCategories must contain 1...24 unique ASCII letter, digit, or underscore values of at most 64 bytes",
            TraceOperations.PresetFailure(10, ["ace", "ace"], 8_192));
        Assert.IsNull(TraceOperations.PresetFailure(600, TraceOperations.Preset("attachmentPanorama").Tags, 8_192));
    }

    [TestMethod]
    public void EveryRecordedProbeIsCheckedAsTheMacOsAppChecksIt()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("rust", "tests", "fixtures", "trace-probe", "cases.json")));
        var read = 0;
        foreach (var exchange in doc.RootElement.GetProperty("exchanges").EnumerateArray())
        {
            var answer = exchange.GetProperty("answer");
            if (!answer.GetProperty("ok").GetBoolean() || exchange.GetProperty("params").GetProperty("targetId").GetString() != Oracle.TargetId) continue;
            var probe = TraceProbe.Parse(StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(answer.GetProperty("result").GetRawText())), Oracle);
            Assert.AreEqual(exchange.GetProperty("answer").GetProperty("result").GetProperty("adapterDisposition").GetString(), probe.AdapterDisposition);
            read++;
        }
        Assert.IsTrue(read >= 12, $"{read} recorded probes");
        var eligible = doc.RootElement.GetProperty("exchanges").EnumerateArray().First(e => e.GetProperty("name").GetString() == "probe.captureEligible");
        var text = eligible.GetProperty("answer").GetProperty("result").GetRawText();
        foreach (var (from, to, message) in new[]
                 {
                     ("\"bindingRevision\":1", "\"bindingRevision\":2", "Runtime returned mismatched probe facts"),
                     ("\"tool\":\"bytrace\"", "\"tool\":\"atrace\"", "Runtime returned malformed tool facts"),
                     ("\"state\":\"value\",\"value\":\"false\"", "\"state\":\"value\"", "Runtime returned contradictory parameter facts"),
                 })
        {
            var compact = JsonSerializer.Serialize(JsonSerializer.Deserialize<JsonElement>(text));
            Assert.IsTrue(compact.Contains(from, StringComparison.Ordinal), from);
            var broken = compact.Replace(from, to, StringComparison.Ordinal);
            var error = Assert.ThrowsExactly<ArkDeck.ClientKit.Contract.ContractException>(() => TraceProbe.Parse(StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(broken)), Oracle));
            StringAssert.Contains(error.Message, message);
        }
    }

    [TestMethod]
    public async Task ACaptureRunsAndItsVerifiedTraceOpensInTheViewer()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Viewer));
        var submitted = await loader.SubmitTraceAsync(Fixture, 10, TraceOperations.Preset("arkuiDeep").Tags, TraceOperations.DefaultBufferKB);
        Assert.IsNull(submitted.Failure, submitted.Failure?.ReasonText(English));
        var terminal = (await loader.RunJobAsync(submitted.JobId!, CliCommands.TraceCapture)).Answer.Value!;
        Assert.IsTrue(terminal.Succeeded);

        var inbox = Directory.CreateTempSubdirectory("arkdeck-app-test-trace-");
        try
        {
            var opened = await loader.OpenCapturedTraceAsync(submitted.JobId!, TraceInbox.Root(inbox.FullName));
            var document = opened.Document!;
            var bytes = File.ReadAllBytes(document.Path);
            Assert.AreEqual(Convert.ToHexStringLower(SHA256.HashData(bytes)), document.Sha256);
            Assert.AreEqual(($"{document.Sha256}.htrace", 80L, submitted.JobId), (document.Name, document.ByteCount, document.JobId));

            var recents = new TraceRecents(Path.Combine(inbox.FullName, "recent-traces.json"));
            recents.Add(document.Path);
            var viewer = await loader.TraceViewerAsync(document, recents);
            Assert.AreEqual("unavailable(operationUnavailable): Trace inspection is unavailable", viewer.Inspection!.Unavailable!.ReasonText(English));
            CollectionAssert.AreEqual(new[] { document.Path }, viewer.Recents.ToArray());
            for (var i = 0; i < 10; i++) recents.Add(Path.Combine(inbox.FullName, $"t{i}.htrace"));
            Assert.AreEqual(TraceRecents.Limit, recents.Load().Count);

            var inspected = await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Inspector)).TraceViewerAsync(document with { JobId = ScriptedDaemon.TraceJobId,
                Artifact = (await new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Inspector)).HistoryDetailAsync(ScriptedDaemon.TraceJobId)).Artifacts.Value!.Single(a => a.Name == "trace.htrace") }, recents);
            Assert.AreEqual("5000000000", inspected.Inspection!.Value!.DurationNs);
            Assert.AreEqual("5.000 s", TraceViewerState.FormatDuration(5_000_000_000));
            Assert.AreEqual("1.500 ms", TraceViewerState.FormatDuration(1_500_000));
            Assert.AreEqual("12 ns", TraceViewerState.FormatDuration(12));
        }
        finally
        {
            inbox.Delete(recursive: true);
        }
    }

    [TestMethod]
    public async Task AJobWithoutExactlyOneRawTraceIsNotOpened()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Viewer));
        var inbox = Directory.CreateTempSubdirectory("arkdeck-app-test-trace-");
        try
        {
            var unknown = await loader.OpenCapturedTraceAsync("job-ffffffffffffffffffffffffffffffff", TraceInbox.Root(inbox.FullName));
            Assert.AreEqual("trace.viewer.artifactListUnavailable", unknown.FailureKey);
            var logs = await loader.SubmitLogsAsync(Fixture, 5, []);
            await loader.RunJobAsync(logs.JobId!, CliCommands.DebugLogs);
            Assert.AreEqual("trace.viewer.artifactInvalid", (await loader.OpenCapturedTraceAsync(logs.JobId!, TraceInbox.Root(inbox.FullName))).FailureKey);
            Assert.IsNull(TraceInbox.PathFor(inbox.FullName, "NOT-A-DIGEST"));
        }
        finally
        {
            inbox.Delete(recursive: true);
        }
    }
}
