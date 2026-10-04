using System.Text;
using System.Text.Json;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>The Job Inspector's macOS facts beyond the status and events: the epoch relation,
/// the device residue, and the log Artifacts it previews.</summary>
[TestClass]
public sealed class JobInspectorTests
{
    [TestMethod]
    public void TheLogTableIsTheCatalogsLogRoles()
    {
        var declared = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var file in Directory.EnumerateFiles(RepoPaths.At("Catalog", "operations"), "*.json"))
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(file));
            var root = doc.RootElement;
            if (!root.TryGetProperty("artifacts", out var artifacts) || artifacts.ValueKind != JsonValueKind.Array) continue;
            foreach (var artifact in artifacts.EnumerateArray())
            {
                if (artifact.TryGetProperty("role", out var role) && role.GetString() == "log")
                {
                    declared[$"{root.GetProperty("id").GetString()}@{root.GetProperty("version").GetInt32()}"] = artifact.GetProperty("name").GetString()!;
                }
            }
        }
        CollectionAssert.AreEquivalent(declared.ToArray(), JobLogArtifacts.Declared.ToArray());
    }

    [TestMethod]
    public void ALogShowsItsLast200Lines()
    {
        var tail = JobLogArtifacts.Tail(Encoding.UTF8.GetBytes(string.Concat(Enumerable.Range(1, 250).Select(i => $"line {i}\n"))))!;
        var lines = tail.Split('\n');
        Assert.AreEqual(200, lines.Length);
        Assert.AreEqual("line 52", lines[0], "the last 200 of 251 split parts: lines 52–250 and the empty end");
        Assert.IsNull(JobLogArtifacts.Tail([0xff, 0xfe, 0xfd]));
    }

    [TestMethod]
    public async Task TheRecoveryScenarioCarriesTheRelationTheResidueAndALog()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Recovery));
        var superseded = await loader.JobAsync(ScriptedDaemon.SupersededJobId);
        Assert.AreEqual(ScriptedDaemon.SupersedingEpochId, superseded.Status.Value!.SupersededByRecoveryEpochId);
        Assert.IsTrue(superseded.Status.Value.OutcomeUnknown);
        Assert.IsTrue(JobRecovery.HasEstablishedCurrentEpoch(superseded.Status.Value));
        Assert.IsNull(superseded.Artifacts, "a Flash declares no log: its Artifacts are not read");

        var log = await loader.JobAsync(ScriptedDaemon.LogJobId);
        Assert.AreEqual(2L, log.Status.Value!.OutstandingResidueCount);
        var artifact = log.Artifacts!.Value!.Single(a => JobLogArtifacts.IsLog(log.Status.Value.Operation, a));
        var (bytes, failure) = await new ArtifactExporter(loader.Channel).ReadAsync(ScriptedDaemon.LogJobId, artifact, allowSensitive: false);
        Assert.IsNull(failure);
        StringAssert.StartsWith(JobLogArtifacts.Tail(bytes!), "capture line 52");
    }
}
