using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Settings' Runtime writes (macOS <c>SettingsApplicationFacade</c> storage policy and
/// root, <c>RuntimeTraceCacheApplicationFacade</c> purge): generation-bound, the Runtime decides,
/// another writer's earlier publication is read back and never overwritten.</summary>
[TestClass]
public sealed class SettingsWriteTests
{
    [TestMethod]
    public void TheDraftsAreCheckedAsMacOsChecksThem()
    {
        Assert.AreEqual((20UL << 30, 2UL << 30, 30UL), StorageStatus.Draft("20", "2", "30"));
        foreach (var (q, m, r) in new[] { ("2", "2", "30"), ("20", "0", "30"), ("20", "2", "0"), ("20.5", "2", "30"), ("-1", "2", "30"), ("x", "2", "30"), ("18446744073709551615", "2", "30") })
        {
            Assert.IsNull(StorageStatus.Draft(q, m, r), $"{q}/{m}/{r}");
        }
        Assert.AreEqual("20", StorageStatus.GiB("21474836480"));
    }

    [TestMethod]
    public async Task APolicyIsSavedAgainstTheGenerationRead()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var saved = (await loader.SaveStoragePolicyAsync(40UL << 30, 4UL << 30, 14)).Answer.Value!;
        Assert.IsFalse(saved.Superseded);
        Assert.AreEqual(("42949672960", "4294967296", "14", "2"), (saved.Status.QuotaBytes, saved.Status.SafetyMarginBytes, saved.Status.RetentionDays, saved.Status.Generation));

        var raced = (await loader.SaveStoragePolicyAsync(ScriptedDaemon.ConflictingQuotaGiB << 30, 4UL << 30, 14)).Answer.Value!;
        Assert.IsTrue(raced.Superseded, "the other writer won");
        Assert.AreEqual(("42949672960", "45"), (raced.Status.QuotaBytes, raced.Status.RetentionDays), "its state is shown, this request is not re-sent");

        Assert.AreEqual("invalidInput", (await loader.SaveStoragePolicyAsync(4UL << 30, 4UL << 30, 14)).Answer.Unavailable!.ReasonCode, "the Runtime decides");
    }

    [TestMethod]
    public async Task TheRootIsTheRuntimesToAccept()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        Assert.AreEqual("invalidInput", (await loader.SetStorageRootAsync(ScriptedDaemon.RefusedStorageRoot)).Answer.Unavailable!.ReasonCode);
        var custom = (await loader.SetStorageRootAsync(@"D:\ArkDeck Sessions")).Answer.Value!.Status;
        Assert.AreEqual(("custom", @"D:\ArkDeck Sessions"), (custom.SessionRootKind, custom.SessionRootPath));
        Assert.AreEqual("default", (await loader.SetStorageRootAsync(null)).Answer.Value!.Status.SessionRootKind);
    }

    [TestMethod]
    public async Task APurgeRemovesInactiveDerivedDatabasesOnly()
    {
        var loader = new SurfaceLoader(ScriptedDaemon.Channel(ScriptedDaemon.Jobs));
        var first = (await loader.PurgeTraceCacheAsync()).Answer.Value!;
        Assert.AreEqual((1L, 1L, 2L, 1L), (first.RemovedEntryCount, first.SkippedActiveEntryCount, first.EntriesBefore, first.EntriesAfter));
        Assert.AreEqual(0, (await loader.PurgeTraceCacheAsync()).Answer.Value!.RemovedEntryCount);
        Assert.AreEqual(0, (await loader.SettingsAsync()).TraceCache.Value!.InactiveEntryCount);

        var counts = """{"activeEntryCount":0,"entryCount":0,"inactiveEntryCount":0,"totalByteCount":"0"}""";
        var report = $$"""{"after":{{counts}},"before":{{counts}},"originalTraceArtifactRemovalCount":1,"purgeScope":"inactiveDerivedDatabases","recoveredPrivateDirectoryCount":0,"removedEntryCount":0,"removedOrphanOwnerMarkerCount":0,"schemaVersion":"arkdeck.trace-cache-purge/1","skippedActiveEntryCount":0}""";
        Assert.ThrowsExactly<ArkDeck.ClientKit.Contract.ContractException>(() => TraceCachePurge.Parse(StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(report))), "an original Trace removed");
    }
}
