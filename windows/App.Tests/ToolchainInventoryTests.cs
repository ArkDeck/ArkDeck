using System.Text;
using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Complete read-only registry discovery over task-private scripted frames.</summary>
[TestClass]
public sealed class ToolchainInventoryTests
{
    [TestMethod]
    public async Task CompleteSnapshotKeepsBothBundleRecordsAndExactSelectedBooleans()
    {
        var channel = new Channel();
        var state = await new SurfaceLoader(channel).SettingsAsync();
        Assert.IsNull(state.Bundles.Unavailable);
        var bundles = state.Bundles.Value!;
        CollectionAssert.AreEqual(new[] { ScriptedDaemon.FirstBundleRef, ScriptedDaemon.SecondBundleRef }, bundles.Select(b => b.BundleRef).ToArray());
        CollectionAssert.AreEqual(new[] { "available", "removed" }, bundles.Select(b => b.State).ToArray());
        Assert.AreEqual(("4096", "3", "1", true), (bundles[0].ByteCount, bundles[0].EntryCount, bundles[0].Generation, bundles[0].ContentRetained));
        Assert.AreEqual(new RuntimeBundleReference("workspacePreset", "preset-fixture"), bundles[0].References.Single());
        Assert.AreEqual(("2", 0, true), (bundles[1].Generation, bundles[1].References.Count, bundles[1].ContentRetained));
        Assert.AreEqual("arkdeck.windows-daemon-package/1", bundles[0].Trust.Policy);
        Assert.AreEqual("notPerformed", bundles[0].Trust.ExecutionAssessment);
        CollectionAssert.AreEqual(new[] { "true", "false" }, state.Tools.Value!.Select(t => t.Selected).ToArray());
        Assert.AreEqual(2, channel.BundleReads);
        Assert.IsTrue(channel.Methods.All(ReadonlyMethods.Contains));
    }

    private static readonly HashSet<string> ReadonlyMethods = ["health", "doctor", "runtime.hdc.status", "runtime.tool.list",
        "runtime.bundle.list", "runtime.storage.status", "trace.cache.status", "workspace.project.list"];

    [TestMethod]
    public async Task EmptyAndRefusedInventoriesStayDistinctAndKeepTheirCliRoute()
    {
        var empty = await new SurfaceLoader(new Channel(ScriptedDaemon.ToolchainInventoryEmpty)).SettingsAsync();
        Assert.AreEqual(0, empty.Bundles.Value!.Count); Assert.AreEqual(0, empty.Tools.Value!.Count);
        var refused = await new SurfaceLoader(new Channel(ScriptedDaemon.ToolchainInventoryRefused)).SettingsAsync();
        Assert.IsNull(refused.Bundles.Value);
        Assert.AreEqual("recordUnreadable", refused.Bundles.Unavailable!.ReasonCode);
        Assert.AreEqual(SurfaceLoader.RuntimeBundleListCommand, refused.Bundles.Unavailable.CliCommand);
        Assert.IsNotNull(refused.Tools.Value);
    }

    [TestMethod]
    public async Task IncompleteChangedDuplicateOrMalformedSnapshotsNeverExposePartialInventory()
    {
        foreach (var drift in new[] { "revision", "duplicate", "order", "kind", "schema", "cursor", "empty-continuation", "extra-field", "digest", "count", "trust", "reference", "refusal" })
        {
            var channel = new Channel { Drift = drift };
            var state = await new SurfaceLoader(channel).SettingsAsync();
            Assert.IsNull(state.Bundles.Value, drift);
            Assert.AreEqual(drift == "refusal" ? "recordUnreadable" : Unavailable.ResultUnreadableCode, state.Bundles.Unavailable!.ReasonCode, drift);
            Assert.AreEqual(SurfaceLoader.RuntimeBundleListCommand, state.Bundles.Unavailable.CliCommand, drift);
            Assert.IsTrue(channel.Methods.All(ReadonlyMethods.Contains), drift);
        }
    }

    [TestMethod]
    public async Task RepeatedContinuationAndPageLimitRefuseWithoutAnUnboundedRead()
    {
        foreach (var drift in new[] { "cycle", "limit" })
        {
            var channel = new Channel { Drift = drift };
            var state = await new SurfaceLoader(channel).SettingsAsync();
            Assert.IsNull(state.Bundles.Value);
            Assert.AreEqual(Unavailable.ResultUnreadableCode, state.Bundles.Unavailable!.ReasonCode);
            Assert.AreEqual(drift == "cycle" ? 2 : SurfaceLoader.RuntimeBundlePageLimit, channel.BundleReads);
        }
    }

    [TestMethod]
    public void SelectedIsAnActualRuntimeBooleanRatherThanCoercedText()
    {
        var value = Parse("""{"items":[{"toolRef":"tool-fixture","kind":"hdc","state":"available","platform":"windows","selected":"true"}]}""");
        Assert.ThrowsExactly<ContractException>(() => ToolSummary.ParsePage(value));
    }

    [TestMethod]
    public void PublishedBundleCorpusKeepsTheOriginalHelperTrustProjection()
    {
        var rows = File.ReadLines(RepoPaths.At("Packages", "ArkDeckKit", "Tests", "ArkDeckContractTests", "Fixtures", "ControlFrames", "runtime.bundle.list.jsonl"))
            .Select(Parse).Where(frame => frame["ok"] is JsonBool { Value: true })
            .SelectMany(frame => ((JsonArray)((JsonObject)frame["result"])["items"]).Items).Select(RuntimeBundle.Parse).ToArray();
        Assert.AreEqual(2, rows.Length);
        Assert.IsTrue(rows.All(row => row.Platform == "macos" && row.ContentRetained && row.EntryCount == "12"));
        Assert.IsTrue(rows.All(row => row.Trust == new RuntimeBundleTrust("arkdeck.daemon-helper/1", "verified", "8AQTYW5FKR", "notPerformed")));
        Assert.IsTrue(rows.All(row => row.References.Count == 0));
        CollectionAssert.AreEquivalent(new[] { "79623613", "77931261" }, rows.Select(row => row.ByteCount).ToArray());
    }

    private static JsonObject Parse(string text) => (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(text));
    private static JsonObject With(JsonObject o, string key, JsonValue value) => new(o.Members.Where(m => m.Key != key).Append(new(key, value)));

    private sealed class Channel(string scenario = ScriptedDaemon.ToolchainInventory) : IControlChannel
    {
        private readonly IControlChannel _inner = ScriptedDaemon.Channel(scenario);
        public readonly List<string> Methods = [];
        public int BundleReads;
        public string? Drift;
        public Task<ControlResult> HealthAsync() { Methods.Add("health"); return _inner.HealthAsync(); }
        public async Task<ControlResult> RequestAsync(string method, JsonObject? parameters = null)
        {
            Methods.Add(method);
            if (method != "runtime.bundle.list") return await _inner.RequestAsync(method, parameters);
            BundleReads++;
            Assert.AreEqual((long)SurfaceLoader.RuntimeBundlePageSize, TypedJson.Int64(parameters!["pageSize"]));
            if (Drift == "refusal" && BundleReads == 2)
                return ControlResult.Failed(new(ControlFailureKind.Remote, "Unreadable continuation", Remote: new("recordUnreadable", "Unreadable continuation", null)));
            var innerParameters = Drift == "limit" && BundleReads > 1 ? SurfaceLoader.Params() : parameters;
            var reply = await _inner.RequestAsync(method, innerParameters);
            if (reply.Value is not JsonObject page) return reply;
            if (Drift is "cycle" or "limit")
            {
                var item = (JsonObject)((JsonArray)page["items"]).Items[0];
                var digest = BundleReads.ToString("x64");
                item = With(With(item, "bundleRef", new JsonString("bundle:sha256:" + digest)), "contentDigest", new JsonString(digest));
                page = With(With(With(page, "items", new JsonArray([item])), "hasMore", JsonBool.True), "nextCursor", new JsonString(Drift == "cycle" ? "bundle-page-2" : "cursor-" + BundleReads));
                return ControlResult.Success(page);
            }
            if (BundleReads != 2) return reply;
            var rows = (JsonArray)page["items"];
            var row = (JsonObject)rows.Items[0];
            page = Drift switch
            {
                "revision" => With(page, "snapshotRevision", new JsonString("changed")),
                "duplicate" => With(page, "items", new JsonArray([With(With(row, "bundleRef", new JsonString(ScriptedDaemon.FirstBundleRef)), "contentDigest", new JsonString(new string('a',64)))])),
                "order" => With(page, "order", new JsonString("registeredAtDesc")),
                "kind" => With(page, "pageKind", new JsonString("eventStream")),
                "schema" => With(page, "schemaVersion", new JsonString("future")),
                "cursor" => With(page, "nextCursor", new JsonString("unexpected")),
                "empty-continuation" => With(With(page, "hasMore", JsonBool.True), "nextCursor", new JsonString("next")) is { } more ? With(more, "items", new JsonArray([])) : page,
                "extra-field" => With(page, "unknown", JsonBool.True),
                "digest" => With(page, "items", new JsonArray([With(row, "contentDigest", new JsonString(new string('a',64)))])),
                "count" => With(page, "items", new JsonArray([With(row, "byteCount", new JsonString("-1"))])),
                "trust" => With(page, "items", new JsonArray([With(row, "trust", With((JsonObject)row["trust"], "authority", JsonBool.True))])),
                "reference" => With(page, "items", new JsonArray([With(row, "references", new JsonArray([Parse("""{"kind":"workspacePreset","id":"preset-fixture","authority":true}""")]))])),
                _ => page,
            };
            return ControlResult.Success(page);
        }
    }
}
