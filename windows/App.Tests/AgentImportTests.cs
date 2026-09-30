using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>
/// Agent executions, human actions and Imports through ClientKit (TASK-XPA-020). The scripted
/// <see cref="ScriptedDaemon.Jobs"/> answers from the recorded Swift corpora
/// (agent-human-action, import-upload-current); the recorded answers themselves are read by the
/// App's parsers here.
/// </summary>
[TestClass]
public sealed class AgentImportTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static SurfaceLoader Loader(string scenario) => new(ScriptedDaemon.Channel(scenario));

    private static TargetSummary Fixture => new(ScriptedDaemon.FixtureTargetId, "Bench board", "1", 3, "2026-09-29T10:00:00Z", "3.2.0f");

    [TestMethod]
    public async Task WaitingExecutionsNameTheirHumanActions()
    {
        var loader = Loader(ScriptedDaemon.Jobs);
        var state = await loader.AgentsAsync();
        CollectionAssert.AreEquivalent(new[] { ScriptedDaemon.ConnectExecutionId, ScriptedDaemon.AmbiguousExecutionId, ScriptedDaemon.CompletedExecutionId },
            state.Executions.Value!.Select(e => e.ExecutionId).ToArray());
        Assert.AreEqual(2, state.HumanActions.Value!.Count);

        var ambiguous = (await loader.AgentAsync(ScriptedDaemon.AmbiguousExecutionId)).Answer.Value!;
        Assert.AreEqual("waitingForHuman", ambiguous.State);
        var action = ambiguous.HumanAction!;
        Assert.AreEqual("ambiguousIdentity", action.Category);
        Assert.IsTrue(action.NeedsSelection);
        CollectionAssert.AreEqual(new[] { "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }, action.Choices.Select(c => c.Label).ToArray());
        Assert.IsFalse(action.Accepts(null));
        Assert.IsFalse(action.Accepts("<candidate-9>"));
        Assert.ThrowsExactly<ArgumentException>(() => loader.ResumeAsync(action, "anything"), "a value outside the schema is never sent");

        var resumed = await loader.ResumeAsync(action, "<candidate-2>");
        Assert.IsNull(resumed.Answer.Unavailable);
        Assert.AreEqual("jobOwned", (await loader.AgentAsync(ScriptedDaemon.AmbiguousExecutionId)).Answer.Value!.State);

        var connect = (await loader.HumanActionAsync("<har-1>")).Answer.Value!;
        Assert.IsFalse(connect.NeedsSelection);
        Assert.IsTrue(connect.Accepts(null));
        Assert.IsNull((await loader.ResumeAsync(connect, null)).Answer.Unavailable);
    }

    [TestMethod]
    public async Task AnAbandonIsGuardedByTheGeneration()
    {
        var loader = Loader(ScriptedDaemon.Jobs);
        var execution = (await loader.AgentAsync(ScriptedDaemon.ConnectExecutionId)).Answer.Value!;
        var abandoned = (await loader.AbandonAsync(execution)).Answer.Value!;
        Assert.AreEqual("abandoned", abandoned.State);
        Assert.IsTrue(abandoned.IsTerminal);
        var stale = await loader.AbandonAsync(execution);
        Assert.AreEqual("unavailable(resourceConflict): execution generation changed", stale.Answer.Unavailable!.ReasonText(English));
        Assert.AreEqual($"arkdeck agent abandon --expected-generation <n> --execution-id {ScriptedDaemon.ConnectExecutionId}", stale.Answer.Unavailable.CliCommand);
    }

    [TestMethod]
    public async Task TheFoundationAndTheDevelopmentRootAnswerAsMeasured()
    {
        var foundation = await Loader(ScriptedDaemon.Foundation).AgentsAsync();
        Assert.AreEqual("unavailable(operationUnavailable): AgentExecution owner is unavailable", foundation.Executions.Unavailable!.ReasonText(English));
        Assert.AreEqual("arkdeck agent list", foundation.Executions.Unavailable.CliCommand);
        var imports = await Loader(ScriptedDaemon.Foundation).ImportsAsync();
        Assert.AreEqual("unavailable(operationUnavailable): Import owner services are unavailable", imports.Imports.Unavailable!.ReasonText(English));

        var root = await Loader(ScriptedDaemon.DevelopmentRoot).AgentsAsync();
        Assert.AreEqual(0, root.Executions.Value!.Count);
        Assert.AreEqual(0, root.HumanActions.Value!.Count);
    }

    [TestMethod]
    public async Task AFileIsUploadedInVerifiedChunksAndCommitted()
    {
        var channel = ScriptedDaemon.Channel(ScriptedDaemon.Jobs);
        using var directory = new TemporaryFolder();
        var path = Path.Combine(directory.Path, "entry.hap");
        var bytes = Enumerable.Range(0, 1_200_000).Select(i => (byte)(i * 7 % 253)).ToArray();
        "PK\u0003\u0004"u8.CopyTo(bytes);
        File.WriteAllBytes(path, bytes);
        var reports = new List<(long Sent, long Total)>();
        var outcome = await new ImportUploader(channel).UploadAsync(path, ImportKind.Hap, Fixture, new Progress(reports), CancellationToken.None);
        Assert.IsNull(outcome.Failure, outcome.Failure?.ReasonText(English));
        var done = outcome.Committed!;
        Assert.AreEqual("committed", done.State);
        Assert.AreEqual(Convert.ToHexStringLower(SHA256.HashData(bytes)), done.Sha256);
        Assert.AreEqual("hap", done.Receipt!.ValidationKind);
        CollectionAssert.AreEqual(new long[] { 0, 524_288, 1_048_576, 1_200_000 }, reports.Select(r => r.Sent).ToArray(), "three bounded chunks");

        var listed = (await new SurfaceLoader(channel).ImportsAsync()).Imports.Value!;
        Assert.IsTrue(listed.Any(i => i.ImportId == done.ImportId && i.State == "committed"));
        var released = await new SurfaceLoader(channel).ReleaseImportAsync(done);
        Assert.IsNull(released.Answer.Unavailable);
        Assert.AreEqual("released", (await new SurfaceLoader(channel).ImportAsync(done.ImportId)).Answer.Value!.State);
        Assert.IsNull((await new SurfaceLoader(channel).ReleaseImportAsync(done)).Answer.Unavailable, "a repeated release answers the same release");
        var notZip = Path.Combine(directory.Path, "plain.hap");
        File.WriteAllBytes(notZip, new byte[4096]);
        var refused = await new ImportUploader(channel).UploadAsync(notZip, ImportKind.Hap, Fixture, null, CancellationToken.None);
        Assert.AreEqual("unavailable(invalidInput): Import is not a ZIP-based HAP/HSP container", refused.Failure!.ReasonText(English));
    }

    [TestMethod]
    public async Task AFlashBundleIsRefusedAtPublicationAndACancelledUploadIsAborted()
    {
        var channel = ScriptedDaemon.Channel(ScriptedDaemon.Jobs);
        using var directory = new TemporaryFolder();
        var flash = Path.Combine(directory.Path, "images.tar.gz");
        File.WriteAllBytes(flash, new byte[4096]);
        var refused = await new ImportUploader(channel).UploadAsync(flash, ImportKind.FlashBundle, Fixture, null, CancellationToken.None);
        Assert.AreEqual($"unavailable(operationUnavailable): {ScriptedDaemon.FlashRefusal}", refused.Failure!.ReasonText(English));
        Assert.AreEqual(CliCommands.ImportFlashBundle, refused.Failure.CliCommand);

        var hap = Path.Combine(directory.Path, "big.hap");
        File.WriteAllBytes(hap, new byte[2_000_000]);
        using var cancel = new CancellationTokenSource();
        var outcome = await new ImportUploader(channel).UploadAsync(hap, ImportKind.Hap, Fixture,
            new Progress([], sent => { if (sent > 0) cancel.Cancel(); }), cancel.Token);
        Assert.IsTrue(outcome.Cancelled);
        var imports = (await new SurfaceLoader(channel).ImportsAsync()).Imports.Value!;
        Assert.IsTrue(imports.Any(i => i.Name == "big.hap" && i.State == "aborted"), "the partial Import was aborted");
    }

    [TestMethod]
    public void FilesOutsideTheKindsRulesAreNotUploaded()
    {
        Assert.IsNull(ImportKind.Refusal(ImportKind.Hap, "entry.hap", 10));
        Assert.IsNotNull(ImportKind.Refusal(ImportKind.Hap, "entry.zip", 10));
        Assert.IsNotNull(ImportKind.Refusal(ImportKind.Hap, "my entry.hap", 10));
        Assert.IsNotNull(ImportKind.Refusal(ImportKind.Hap, "entry.hap", 65L * 1024 * 1024));
        Assert.IsNull(ImportKind.Refusal(ImportKind.NativeLibrary, "libdemo.so", 4096));
        Assert.IsNotNull(ImportKind.Refusal(ImportKind.NativeLibrary, "libdemo.so", 10));
        Assert.IsNull(ImportKind.Refusal(ImportKind.FlashBundle, "images.tar.gz", 4096));
        Assert.IsNotNull(ImportKind.Refusal(ImportKind.FlashBundle, "images.tgz", 4096));
        Assert.IsNull(ImportKind.Refusal(ImportKind.WorkspacePatch, "fix.patch", 100));
        Assert.AreEqual("dayu200", ImportKind.DeviceProfile(ImportKind.FlashBundle));
        Assert.IsNull(ImportKind.DeviceProfile(ImportKind.Hap));
    }

    [TestMethod]
    public void EveryRecordedAgentAndImportAnswerIsReadable()
    {
        using var agents = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("rust", "tests", "fixtures", "agent-human-action", "cases.json")));
        var read = 0;
        foreach (var exchange in agents.RootElement.GetProperty("exchanges").EnumerateArray())
        {
            var answer = exchange.GetProperty("answer");
            if (!answer.GetProperty("ok").GetBoolean()) continue;
            var value = StrictJson.Parse(Encoding.UTF8.GetBytes(answer.GetProperty("result").GetRawText()));
            switch (exchange.GetProperty("method").GetString())
            {
                case "agent.run" or "agent.status" or "agent.abandon":
                    var execution = AgentExecution.Parse(value);
                    if (execution.HumanAction is { NeedsSelection: true } action) Assert.AreEqual(action.SelectionValues!.Count, action.Choices.Count);
                    read++;
                    break;
                case "human-action.show":
                    HumanAction.Parse(value);
                    read++;
                    break;
                case "human-action.list":
                    HumanAction.ParsePage(value);
                    read++;
                    break;
            }
        }
        Assert.IsTrue(read >= 10, read.ToString());
        using var imports = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("rust", "tests", "fixtures", "import-upload-current", "swift-results.json")));
        foreach (var entry in imports.RootElement.EnumerateArray())
        {
            var record = ImportRecord.Parse(StrictJson.Parse(Encoding.UTF8.GetBytes(entry.GetProperty("result").GetRawText())));
            StringAssert.StartsWith(record.ImportId, "imp-");
        }
    }

    private sealed class Progress(List<(long Sent, long Total)> reports, Action<long>? onReport = null) : IProgress<(long Sent, long Total)>
    {
        public void Report((long Sent, long Total) value)
        {
            reports.Add(value);
            onReport?.Invoke(value.Sent);
        }
    }

    private sealed class TemporaryFolder : IDisposable
    {
        public string Path { get; } = Directory.CreateTempSubdirectory("arkdeck-app-import-").FullName;

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
