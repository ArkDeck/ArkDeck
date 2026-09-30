using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>
/// The TASK-XPA-020 surfaces through ClientKit: the adopted Targets and their Runtime display
/// names (Device), a Job's Artifacts, their verified export and the Trace inspection
/// (History detail). The scripted transport feeds ClientKit's real codec and method schemas;
/// the <see cref="ScriptedDaemon.DevelopmentRoot"/> and <see cref="ScriptedDaemon.Foundation"/>
/// answers are the real Windows daemon's (recorded in the run record).
/// </summary>
[TestClass]
public sealed class TargetArtifactTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static SurfaceLoader Loader(string scenario) => new(ScriptedDaemon.Channel(scenario));

    private static ScriptedDaemon.ScriptedArtifact Scripted(string name) => ScriptedDaemon.Artifacts.Single(a => a.Name == name);

    [TestMethod]
    public async Task TheDevelopmentRootShowsItsAdoptedTargetWithoutAnHdc()
    {
        var loader = Loader(ScriptedDaemon.DevelopmentRoot);
        var device = await loader.DeviceAsync();
        Assert.AreEqual("unavailable(rejected): hdc.notConfigured", device.Candidates.Unavailable!.ReasonText(English));
        var target = device.Targets.Value!.Single();
        Assert.AreEqual(ScriptedDaemon.OracleTargetId, target.TargetId);
        Assert.IsNull(target.DisplayName);
        Assert.AreEqual(ScriptedDaemon.OracleTargetId, target.Title, "no display name: the Target id");
        Assert.AreEqual("1", target.DisplayNameGeneration);

        var detail = await loader.TargetAsync(target.TargetId);
        var shown = detail.Detail.Value!;
        Assert.AreEqual(new string('a', 32), shown.ConnectKey);
        Assert.AreEqual(Convert.ToHexStringLower(SHA256.HashData(Encoding.ASCII.GetBytes(shown.ConnectKey))), shown.StablePhysicalIdentitySha256);
        Assert.IsNull(shown.ObservedFacts);
        var availability = detail.Availability.Value!;
        Assert.AreEqual("ready", availability.BindingState);
        Assert.AreEqual("unresolved (device_observation_unavailable)", availability.Presence.Text);
        Assert.AreEqual("absent (runtime_tool_unavailable)", availability.Tool.Text);
        Assert.AreEqual("host", availability.OperationsScope);
        CollectionAssert.AreEqual(new[] { "provider_not_registered" }, availability.Operations[0].ReasonCodes.ToArray());

        var missing = await loader.TargetAsync("TGT-unknown");
        Assert.AreEqual("notFound", missing.Detail.Unavailable!.ReasonCode);
        Assert.AreEqual("arkdeck target show --target TGT-unknown", missing.Detail.Unavailable.CliCommand);
    }

    [TestMethod]
    public async Task ARenameIsGuardedByTheGenerationTheAppRead()
    {
        var loader = Loader(ScriptedDaemon.DevelopmentRoot);
        var id = ScriptedDaemon.OracleTargetId;
        var renamed = await loader.RenameTargetAsync(id, "Bench board", "1");
        Assert.AreEqual(new DisplayNameChange(id, "Bench board", "2", "2026-09-30T08:05:00Z"), renamed.Change.Value);
        var listed = (await loader.DeviceAsync()).Targets.Value!.Single();
        Assert.AreEqual("Bench board", listed.Title);
        Assert.AreEqual("2", listed.DisplayNameGeneration);

        // Another writer (or an older read) named generation 1: refused, nothing overwritten.
        var stale = await loader.RenameTargetAsync(id, "Other", "1");
        Assert.AreEqual("resourceConflict", stale.Change.Unavailable!.ReasonCode);
        Assert.IsFalse(stale.Change.Unavailable.IsDaemonUnavailable);
        Assert.AreEqual("unavailable(resourceConflict): Target display-name generation changed or is exhausted", stale.Change.Unavailable.ReasonText(English));
        Assert.AreEqual("arkdeck target display-name set --target TGT-3ba3f5f43b92 --expected-generation <n> --name <text>", stale.Change.Unavailable.CliCommand);
        Assert.AreEqual("Bench board", (await loader.DeviceAsync()).Targets.Value!.Single().DisplayName);

        var cleared = await loader.ClearTargetNameAsync(id, "2");
        Assert.IsNull(cleared.Change.Value!.Name);
        Assert.AreEqual("3", cleared.Change.Value.Generation);
        Assert.IsNull((await loader.DeviceAsync()).Targets.Value!.Single().DisplayName);
    }

    [TestMethod]
    public void NamesFollowTheMacOSRenameRule()
    {
        Assert.AreEqual("Bench board", DisplayName.Normalize("  Bench \t\n board  "));
        Assert.IsNull(DisplayName.Normalize(""));
        Assert.IsNull(DisplayName.Normalize(" \t "));
        Assert.AreEqual(new string('a', 64), DisplayName.Normalize(new string('a', 64)));
        Assert.IsNull(DisplayName.Normalize(new string('a', 65)), "the Runtime would take 65; the macOS rule (and its message) says 1–64");
        var family = "\U0001F469‍\U0001F469‍\U0001F467";
        Assert.IsNotNull(DisplayName.Normalize(string.Concat(Enumerable.Repeat(family, 64))), "64 user-perceived characters, as Swift counts them");
        Assert.IsNull(DisplayName.Normalize(string.Concat(Enumerable.Repeat(family, 65))));
    }

    [TestMethod]
    public async Task TheFoundationHasNoTargetArtifactOrTraceOwner()
    {
        var loader = Loader(ScriptedDaemon.Foundation);
        var device = await loader.DeviceAsync();
        Assert.AreEqual("unavailable(internalError): Target owner is not configured", device.Targets.Unavailable!.ReasonText(English));
        Assert.AreEqual("CLI: arkdeck target list", device.Targets.Unavailable.CliText(English));
        Assert.IsTrue(device.Reached);

        var detail = await loader.HistoryDetailAsync(ScriptedDaemon.TraceJobId);
        Assert.AreEqual("unavailable(rejected): The Job owner is not configured", detail.Status.Unavailable!.ReasonText(English));
        Assert.AreEqual("unavailable(operationUnavailable): Artifact owner is not configured", detail.Artifacts.Unavailable!.ReasonText(English));
        Assert.AreEqual($"arkdeck artifact list --job {ScriptedDaemon.TraceJobId}", detail.Artifacts.Unavailable.CliCommand);
    }

    [TestMethod]
    public async Task AJobsArtifactsAreShownAsTheRuntimeListsThem()
    {
        var loader = Loader(ScriptedDaemon.Jobs);
        var failed = await loader.HistoryDetailAsync(ScriptedDaemon.FailedJobId);
        Assert.AreEqual("failed", failed.Status.Value!.State);
        var artifacts = failed.Artifacts.Value!;
        Assert.AreEqual(2, artifacts.Count);
        var log = artifacts.Single(a => a.Name == "flash-log.txt");
        Assert.IsTrue(log.IsPublished);
        Assert.IsFalse(log.IsTrace);
        Assert.AreEqual(Scripted("flash-log.txt").Sha256, log.Digest);
        var missing = artifacts.Single(a => a.Name == "partition-table.json");
        Assert.IsFalse(missing.IsPublished);
        Assert.IsNull(missing.Digest);

        var trace = (await loader.HistoryDetailAsync(ScriptedDaemon.TraceJobId)).Artifacts.Value!.Single(a => a.IsTrace);
        Assert.AreEqual("300,000", trace.ByteCountText);
        Assert.IsTrue(trace.IsSensitive);

        var running = await loader.HistoryDetailAsync(ScriptedDaemon.RunningJobId);
        Assert.AreEqual(0, running.Artifacts.Value!.Count);
    }

    [TestMethod]
    public async Task WithoutAnInspectorTheTraceShowsTheRuntimesRefusal()
    {
        var loader = Loader(ScriptedDaemon.Jobs);
        var trace = (await loader.HistoryDetailAsync(ScriptedDaemon.TraceJobId)).Artifacts.Value!.Single(a => a.IsTrace);
        var inspection = await loader.InspectTraceAsync(ScriptedDaemon.TraceJobId, trace);
        Assert.AreEqual("unavailable(operationUnavailable): Trace inspection is unavailable", inspection.Inspection.Unavailable!.ReasonText(English));
        Assert.AreEqual($"arkdeck trace inspect --job {ScriptedDaemon.TraceJobId} --artifact {trace.ArtifactId} --allow-sensitive",
            inspection.Inspection.Unavailable.CliCommand);

        var inspected = await Loader(ScriptedDaemon.Inspector).InspectTraceAsync(ScriptedDaemon.TraceJobId, trace);
        var facts = inspected.Inspection.Value!;
        Assert.AreEqual(trace.ArtifactId, facts.ArtifactId);
        Assert.AreEqual("ArkTrace", facts.EngineName);
        Assert.AreEqual("5000000000", facts.DurationNs);
        CollectionAssert.AreEqual(new[] { "cpuScheduling", "namedSlices", "threadStates" }, facts.Capabilities.ToArray());
        Assert.AreEqual("ok", facts.DataQuality);
    }

    [TestMethod]
    public void EveryRecordedInspectionTheRuntimeAcceptsIsReadable()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("rust", "tests", "fixtures", "trace-inspect", "projections.json")));
        var accepted = doc.RootElement.EnumerateArray().Where(c => c.GetProperty("accepted").GetBoolean()).ToArray();
        Assert.IsTrue(accepted.Length > 0);
        foreach (var projection in accepted)
        {
            var value = StrictJson.Parse(Encoding.UTF8.GetBytes(projection.GetProperty("value").GetRawText()));
            var parsed = TraceInspection.Parse(value);
            Assert.AreEqual(projection.GetProperty("artifactId").GetString(), parsed.ArtifactId, projection.GetProperty("name").GetString());
        }
    }

    [TestMethod]
    public async Task AnExportWritesTheVerifiedBytesAndNothingElse()
    {
        var channel = ScriptedDaemon.Channel(ScriptedDaemon.Jobs);
        var trace = (await new SurfaceLoader(channel).HistoryDetailAsync(ScriptedDaemon.TraceJobId)).Artifacts.Value!.Single(a => a.IsTrace);
        using var directory = new TemporaryDirectory();
        var destination = Path.Combine(directory.Path, "trace.htrace");

        var refused = await new ArtifactExporter(channel).ExportAsync(ScriptedDaemon.TraceJobId, trace, destination, allowSensitive: false);
        Assert.AreEqual(ArtifactExporter.SensitiveCode, refused.Failure!.ReasonCode, "a sensitive Artifact needs the person's consent");
        Assert.IsFalse(File.Exists(destination));

        var exported = await new ArtifactExporter(channel).ExportAsync(ScriptedDaemon.TraceJobId, trace, destination, allowSensitive: true);
        Assert.IsTrue(exported.Completed, exported.Failure?.ReasonText(English));
        Assert.IsTrue(exported.Reached);
        CollectionAssert.AreEqual(Scripted("trace.htrace").Bytes, File.ReadAllBytes(destination), "two 256 KiB-bounded chunks, in order");
        CollectionAssert.AreEqual(new[] { "trace.htrace" }, Directory.GetFiles(directory.Path).Select(Path.GetFileName).ToArray(), "no staging file left");

        // An existing regular file is replaced (the person chose it in the save dialog).
        var config = (await new SurfaceLoader(channel).HistoryDetailAsync(ScriptedDaemon.TraceJobId)).Artifacts.Value!.Single(a => a.Name == "trace-config.json");
        var existing = Path.Combine(directory.Path, "config.json");
        File.WriteAllText(existing, "old");
        Assert.IsTrue((await new ArtifactExporter(channel).ExportAsync(ScriptedDaemon.TraceJobId, config, existing, allowSensitive: false)).Completed);
        CollectionAssert.AreEqual(Scripted("trace-config.json").Bytes, File.ReadAllBytes(existing));

        var toDirectory = await new ArtifactExporter(channel).ExportAsync(ScriptedDaemon.TraceJobId, config, directory.Path, allowSensitive: false);
        Assert.AreEqual(ArtifactExporter.DestinationCode, toDirectory.Failure!.ReasonCode);

        var missing = (await new SurfaceLoader(channel).HistoryDetailAsync(ScriptedDaemon.FailedJobId)).Artifacts.Value!.Single(a => !a.IsPublished);
        Assert.AreEqual(ArtifactExporter.NotPublishedCode,
            (await new ArtifactExporter(channel).ExportAsync(ScriptedDaemon.FailedJobId, missing, Path.Combine(directory.Path, "x"), false)).Failure!.ReasonCode);
    }

    [TestMethod]
    [DataRow("digest")]
    [DataRow("byte")]
    [DataRow("offset")]
    [DataRow("eof")]
    [DataRow("total")]
    public async Task ADriftingChunkLeavesTheDestinationAsItWas(string drift)
    {
        var channel = new Tampering(ScriptedDaemon.Channel(ScriptedDaemon.Jobs), drift);
        var trace = (await new SurfaceLoader(channel).HistoryDetailAsync(ScriptedDaemon.TraceJobId)).Artifacts.Value!.Single(a => a.IsTrace);
        using var directory = new TemporaryDirectory();
        var destination = Path.Combine(directory.Path, "trace.htrace");
        File.WriteAllText(destination, "kept");
        var outcome = await new ArtifactExporter(channel).ExportAsync(ScriptedDaemon.TraceJobId, trace, destination, allowSensitive: true);
        Assert.AreEqual(ArtifactExporter.IntegrityCode, outcome.Failure!.ReasonCode, drift);
        Assert.AreEqual("kept", File.ReadAllText(destination));
        Assert.AreEqual(1, Directory.GetFiles(directory.Path).Length, "the staging file is removed");
        Assert.AreEqual($"arkdeck artifact read --artifact {trace.ArtifactId} --job {ScriptedDaemon.TraceJobId}", outcome.Failure.CliCommand);
    }

    [TestMethod]
    public async Task ArtifactPagesAreFollowedAndARepeatedCursorIsUnreadable()
    {
        var paged = await new SurfaceLoader(new Paging(ScriptedDaemon.Channel(ScriptedDaemon.Jobs), repeat: false)).HistoryDetailAsync(ScriptedDaemon.TraceJobId);
        CollectionAssert.AreEqual(new[] { "trace-config.json", "trace-config.json", "trace.htrace", "trace.htrace" },
            paged.Artifacts.Value!.Select(a => a.Name).Order(StringComparer.Ordinal).ToArray());

        var looping = await new SurfaceLoader(new Paging(ScriptedDaemon.Channel(ScriptedDaemon.Jobs), repeat: true)).HistoryDetailAsync(ScriptedDaemon.TraceJobId);
        Assert.AreEqual(Unavailable.ResultUnreadableCode, looping.Artifacts.Unavailable!.ReasonCode);
        Assert.IsTrue(looping.Reached);
        Assert.IsNull(looping.DaemonFailure);
    }

    [TestMethod]
    public async Task NothingAnsweringReachesTheBannerFromEverySurface()
    {
        var loader = Loader(ScriptedDaemon.Unavailable);
        var device = await loader.DeviceAsync();
        Assert.IsNotNull(device.DaemonFailure);
        Assert.AreEqual(Unavailable.DaemonUnavailableCode, device.Targets.Unavailable!.ReasonCode);
        Assert.IsNotNull((await loader.TargetAsync(ScriptedDaemon.OracleTargetId)).DaemonFailure);
        Assert.IsNotNull((await loader.RenameTargetAsync(ScriptedDaemon.OracleTargetId, "x", "1")).DaemonFailure);
        Assert.IsNotNull((await loader.HistoryDetailAsync(ScriptedDaemon.TraceJobId)).DaemonFailure);
        var artifact = new ArtifactSummary("ART-1", "job", ScriptedDaemon.TraceJobId, "a.txt", "text/plain", "standard", "published", 1, new string('0', 64), "x@1", "hdc", "2026-09-30T08:00:00Z");
        using var directory = new TemporaryDirectory();
        var export = await new ArtifactExporter(ScriptedDaemon.Channel(ScriptedDaemon.Unavailable)).ExportAsync(ScriptedDaemon.TraceJobId, artifact, Path.Combine(directory.Path, "a.txt"), false);
        Assert.IsTrue(export.Failure!.IsDaemonUnavailable);
        Assert.IsNotNull(export.DaemonFailure, "the shell shows the recovery banner");
        Assert.AreEqual(0, Directory.GetFiles(directory.Path).Length);
    }

    [TestMethod]
    public void TheCliCommandsAreTheCoverageTemplatesFilledIn()
    {
        Assert.AreEqual("arkdeck target show --target TGT-1", CliCommands.ForTarget(CliCommands.TargetShow, "TGT-1"));
        StringAssert.StartsWith(CliCommands.ArtifactList, "arkdeck artifact list (--job <id>");
        Assert.AreEqual("arkdeck artifact list --job job-1", CliCommands.ArtifactListForJob("job-1"));
        StringAssert.StartsWith(CliCommands.ArtifactRead, "arkdeck artifact read --artifact <artifact-id> (--job <id>");
        Assert.AreEqual("arkdeck artifact read --artifact ART-1 --job job-1", CliCommands.ArtifactReadForJob("job-1", "ART-1"));
    }

    /// <summary>The scripted daemon with one <c>artifact.read</c> fact changed in every reply.</summary>
    private sealed class Tampering(IControlChannel inner, string drift) : IControlChannel
    {
        public Task<ControlResult> HealthAsync() => inner.HealthAsync();

        public async Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null)
        {
            var result = await inner.RequestAsync(method, parameters);
            if (method != "artifact.read" || result.Value is not JsonObject chunk) return result;
            var members = chunk.Members.ToDictionary(m => m.Key, m => m.Value, StringComparer.Ordinal);
            switch (drift)
            {
                case "digest":
                    members["artifactDigest"] = new JsonString(new string('0', 64));
                    break;
                case "byte":
                    var bytes = Convert.FromBase64String(((JsonString)members["base64"]).Value);
                    bytes[^1] ^= 0xFF;
                    members["base64"] = new JsonString(Convert.ToBase64String(bytes));
                    break;
                case "offset":
                    members["offset"] = JsonNumber.FromInt64(TypedJsonInt(members["offset"]) + 1);
                    break;
                case "eof":
                    members["eof"] = JsonBool.Of(!((JsonBool)members["eof"]).Value);
                    break;
                case "total":
                    members["totalByteCount"] = JsonNumber.FromInt64(TypedJsonInt(members["totalByteCount"]) + 1);
                    break;
            }
            return ControlResult.Success(new JsonObject(members));
        }

        private static long TypedJsonInt(JsonValue value) => ArkDeck.ClientKit.Contract.TypedJson.Int64(value);
    }

    /// <summary>The scripted daemon's Artifact page served twice: page one names a cursor,
    /// page two is the same rows again and ends (or names the same cursor again).</summary>
    private sealed class Paging(IControlChannel inner, bool repeat) : IControlChannel
    {
        public Task<ControlResult> HealthAsync() => inner.HealthAsync();

        public async Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null)
        {
            if (method != "artifact.list") return await inner.RequestAsync(method, parameters);
            var hasCursor = parameters!.ContainsKey("cursor");
            var forwarded = new JsonObject(parameters.Members.Where(m => m.Key != "cursor"));
            var result = await inner.RequestAsync(method, forwarded);
            var page = ((JsonObject)result.Value!).Members.ToDictionary(m => m.Key, m => m.Value, StringComparer.Ordinal);
            var more = !hasCursor || repeat;
            page["hasMore"] = JsonBool.Of(more);
            page["nextCursor"] = more ? new JsonString("0f5e0c1a-0000-4000-8000-000000000001.1") : JsonNull.Instance;
            return ControlResult.Success(new JsonObject(page));
        }
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string Path { get; } = Directory.CreateTempSubdirectory("arkdeck-app-export-").FullName;

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
