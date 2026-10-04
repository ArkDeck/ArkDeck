using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>History's filters, older pages and saved filter (macOS <c>RuntimeHistoryView</c>
/// filters and <c>RuntimeHistoryFilterApplicationFacade</c>).</summary>
[TestClass]
public sealed class HistoryFilterTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-04T12:00:00Z", System.Globalization.CultureInfo.InvariantCulture);

    private static JobSummary Job(string id, string operation, string state, string created, string? kind = null, string mode = "execute",
        bool unknown = false, string? session = null, string target = "TGT-1", long residue = 0) =>
        new(id, operation, target, state, unknown, false, mode, created, null, session, kind, null, null, residue);

    [TestMethod]
    public void EachFilterNarrowsAsMacOsDoes()
    {
        JobSummary[] jobs =
        [
            Job("job-1", "flash.full-restore@1", "failed", "2026-10-04T11:30:00Z"),
            Job("job-2", "debug.hap@1", "succeeded", "2026-10-03T12:30:00Z", session: "s-2"),
            Job("job-3", "capture.diagnostics@1", "running", "2026-09-20T00:00:00Z", kind: "trace", target: "TGT-2"),
            Job("job-4", "observe.device@1", "interrupted", "2026-10-04T11:59:00Z", unknown: true, mode: "planOnly"),
            Job("job-5", "runtime.selftest@1", "succeeded", "2026-10-04T10:00:00Z", residue: 1),
        ];
        string[] Ids(HistoryFilterQuery q) => q.Apply(jobs, Now).Select(j => j.JobId).ToArray();
        CollectionAssert.AreEqual(new[] { "job-4", "job-1", "job-5", "job-2", "job-3" }, Ids(HistoryFilterQuery.None), "newest first");
        CollectionAssert.AreEqual(new[] { "job-1" }, Ids(new() { Activity = HistoryActivity.Flash }));
        CollectionAssert.AreEqual(new[] { "job-3" }, Ids(new() { Activity = HistoryActivity.Trace }));
        CollectionAssert.AreEqual(new[] { "job-5" }, Ids(new() { Activity = HistoryActivity.Other }));
        CollectionAssert.AreEqual(new[] { "job-3" }, Ids(new() { Status = HistoryStatus.Active }));
        CollectionAssert.AreEqual(new[] { "job-4", "job-5" }, Ids(new() { Status = HistoryStatus.NeedsAttention }));
        CollectionAssert.AreEqual(new[] { "job-4" }, Ids(new() { Mode = HistoryMode.Planned }));
        CollectionAssert.AreEqual(new[] { "job-2" }, Ids(new() { SessionId = "s-2" }));
        CollectionAssert.AreEqual(new[] { "job-3" }, Ids(new() { TargetId = "TGT-2" }));
        CollectionAssert.AreEqual(new[] { "job-4", "job-1" }, Ids(new() { Time = HistoryTime.LastHour }));
        CollectionAssert.AreEqual(new[] { "job-4", "job-1", "job-5", "job-2" }, Ids(new() { Time = HistoryTime.LastWeek }).Take(4).ToArray());
        CollectionAssert.AreEqual(new[] { "job-2" }, Ids(new() { Search = "HAP" }), "case-insensitive over the operation");
        CollectionAssert.AreEqual(new[] { "job-3" }, Ids(new() { Search = "tgt-2" }));
    }

    [TestMethod]
    public void TheWireNamesAreTheRuntimes()
    {
        var query = new HistoryFilterQuery("hap", HistoryStatus.NeedsAttention, HistoryMode.Planned, null, "TGT-1", HistoryTime.LastWeek, HistoryActivity.Debug);
        var wire = query.ToWire("3");
        Assert.AreEqual("""{"activity":"debug","expectedGeneration":"3","mode":"planned","search":"hap","sessionId":null,"status":"needsAttention","targetId":"TGT-1","timeRange":"lastWeek"}""", wire.ToString());
        Assert.AreEqual(query, HistoryFilterQuery.FromWire(wire));
        Assert.AreEqual(HistoryStatus.All, HistoryFilterQuery.Parse("NeedsAttention", HistoryStatus.All), "names are exact");
    }

    [TestMethod]
    public void AnInconsistentListIsRefused()
    {
        static JsonValue J(string s) => StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(s));
        Assert.IsNull(SavedHistoryFilter.ParseList(J("""{"filters":[],"generation":"1","schemaVersion":"arkdeck.history-filter-list/1","updatedAtUtc":null}""")).Query);
        foreach (var bad in new[]
                 {
                     """{"filters":[],"generation":"2","schemaVersion":"arkdeck.history-filter-list/1","updatedAtUtc":null}""",
                     """{"filters":[],"generation":"01","schemaVersion":"arkdeck.history-filter-list/1","updatedAtUtc":null}""",
                     """{"filters":[],"generation":"1","schemaVersion":"arkdeck.history-filter-list/2","updatedAtUtc":null}""",
                 })
        {
            Assert.ThrowsExactly<ArkDeck.ClientKit.Contract.ContractException>(() => SavedHistoryFilter.ParseList(J(bad)), bad);
        }
    }

    [TestMethod]
    public async Task OlderPagesAndTheSavedFilterGoThroughTheRuntime()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.History));
        var first = await loader.HistoryAsync();
        Assert.AreEqual(ScriptedDaemon.OlderCursor, first.NextCursor);
        var older = await loader.OlderHistoryAsync(first.NextCursor!);
        Assert.IsNull(older.NextCursor);
        CollectionAssert.Contains(older.Jobs.Value!.Select(j => j.JobId).ToArray(), ScriptedDaemon.SupersededJobId);

        var saved = (await loader.SavedHistoryFilterAsync()).Answer.Value!;
        Assert.AreEqual((1UL, (HistoryFilterQuery?)null), (saved.Generation, saved.Query));
        var query = new HistoryFilterQuery(Status: HistoryStatus.Failed, Time: HistoryTime.LastWeek);
        var after = (await loader.SaveHistoryFilterAsync(query, 1)).Answer.Value!;
        Assert.AreEqual((2UL, query), (after.Generation, after.Query));
        Assert.AreEqual("conflict", (await loader.SaveHistoryFilterAsync(query, 1)).Answer.Unavailable!.ReasonCode, "a stale generation is refused");
        Assert.AreEqual(query, (await loader.SavedHistoryFilterAsync()).Answer.Value!.Query);
        var deleted = (await loader.DeleteHistoryFilterAsync(2)).Answer.Value!;
        Assert.AreEqual((3UL, (HistoryFilterQuery?)null), (deleted.Generation, deleted.Query));
    }
}
