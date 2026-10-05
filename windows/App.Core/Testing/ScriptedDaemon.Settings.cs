using System.Globalization;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    /// <summary>A quota (GiB) that makes the <c>jobs</c> storage owner publish another writer's
    /// policy first, so the App's generation-bound write meets <c>resourceConflict</c>.</summary>
    public const ulong ConflictingQuotaGiB = 99;

    /// <summary>A storage root the <c>jobs</c> storage owner refuses.</summary>
    public const string RefusedStorageRoot = @"C:\Missing\ArkDeck Sessions";

    private sealed partial class Script
    {
        private ulong _storageGeneration = 1;
        private string _quota = "21474836480";
        private string _margin = "1073741824";
        private string _retention = "30";
        private string? _customRoot;
        private bool _tracePurged;

        /// <summary>The <c>jobs</c> storage and Trace cache owners: generation-bound writes the way
        /// the Runtime checks them, and a purge of the one inactive derived database.</summary>
        private byte[]? SettingsRoute(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) && p is JsonObject o ? o : new JsonObject();
            string? Param(string key) => parameters.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
            switch (method)
            {
                case "runtime.storage.status":
                    return Success(request, Parse(StorageNow()));
                case "runtime.storage.policy":
                case "runtime.storage.root":
                {
                    if (Param("expectedGeneration") != _storageGeneration.ToString(CultureInfo.InvariantCulture))
                    {
                        return Failure(request, "resourceConflict", "storage settings changed; read them again");
                    }
                    if (method == "runtime.storage.policy")
                    {
                        if (!ulong.TryParse(Param("totalQuotaBytes"), CultureInfo.InvariantCulture, out var quota)
                            || !ulong.TryParse(Param("safetyMarginBytes"), CultureInfo.InvariantCulture, out var margin)
                            || !ulong.TryParse(Param("retentionDays"), CultureInfo.InvariantCulture, out var days) || quota <= margin || margin == 0 || days == 0)
                        {
                            return Failure(request, "invalidInput", "the storage policy is not valid");
                        }
                        if (quota == ConflictingQuotaGiB << 30)
                        {
                            _storageGeneration++;
                            _retention = "45";
                            return Failure(request, "resourceConflict", "storage settings changed; read them again");
                        }
                        (_quota, _margin, _retention) = (Param("totalQuotaBytes")!, Param("safetyMarginBytes")!, Param("retentionDays")!);
                    }
                    else if (parameters.TryGetValue("resetToDefault", out var reset) && reset is JsonBool { Value: true })
                    {
                        _customRoot = null;
                    }
                    else
                    {
                        var root = Param("rootPath");
                        if (root is null || root == RefusedStorageRoot || !Path.IsPathFullyQualified(root))
                        {
                            return Failure(request, "invalidInput", "the storage root is not a writable directory");
                        }
                        _customRoot = root;
                    }
                    _storageGeneration++;
                    return Success(request, Parse(StorageNow()));
                }
                case "trace.cache.status":
                    return Success(request, Parse(TraceCacheNow()));
                case "trace.cache.purge":
                {
                    var removed = _tracePurged ? 0 : 1;
                    var before = TraceCacheCounts();
                    _tracePurged = true;
                    return Success(request, Parse($$"""
                        {"after":{{TraceCacheCounts()}},"before":{{before}},"originalTraceArtifactRemovalCount":0,"purgeScope":"inactiveDerivedDatabases","recoveredPrivateDirectoryCount":0,"removedEntryCount":{{removed}},"removedOrphanOwnerMarkerCount":0,"schemaVersion":"arkdeck.trace-cache-purge/1","skippedActiveEntryCount":1}
                        """));
                }
                default:
                    return null;
            }
        }

        private string TraceCacheCounts() => _tracePurged
            ? """{"activeEntryCount":1,"entryCount":1,"inactiveEntryCount":0,"totalByteCount":"32768"}"""
            : """{"activeEntryCount":1,"entryCount":2,"inactiveEntryCount":1,"totalByteCount":"65536"}""";

        private string TraceCacheNow()
        {
            var counts = (JsonObject)Parse(TraceCacheCounts());
            return new JsonObject(counts.Members
                .Append(new("purgeScope", new JsonString("inactiveDerivedDatabases")))
                .Append(new("schemaVersion", new JsonString("arkdeck.trace-cache-status/1")))
                .OrderBy(m => m.Key, StringComparer.Ordinal)).ToString();
        }

        private string StorageNow()
        {
            var root = _customRoot ?? @"C:\Users\Example\AppData\Local\ArkDeck\Sessions";
            return $$$$"""
                {"artifactDomain":{"policy":"runtimeManaged","remainingBytes":"9663676416","rootReference":"runtime-artifacts","schemaVersion":"arkdeck.runtime-artifact-storage/1","totalBytes":"10737418240","usedBytes":"1073741824"},"schemaVersion":"arkdeck.runtime-storage-status/1","sessionDomain":{"catalogGeneration":null,"generation":"{{{{_storageGeneration}}}}","policy":{"retentionDays":"{{{{_retention}}}}","safetyMarginBytes":"{{{{_margin}}}}","totalQuotaBytes":"{{{{_quota}}}}"},"rootKind":"{{{{(_customRoot is null ? "default" : "custom")}}}}","rootPath":{{{{new JsonString(root)}}}},"schemaVersion":"arkdeck.session-storage/1","usage":{"measurementIncomplete":false,"pinnedBytes":"4096","pinnedSessionCount":"1","sessionCount":"3","unaccountedSessionCount":"0","usedBytes":"123456"}}}
                """;
        }
    }
}
