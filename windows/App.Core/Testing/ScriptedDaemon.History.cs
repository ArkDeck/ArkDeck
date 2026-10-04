using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    private sealed partial class Script
    {
        private ulong _filterGeneration = 1;
        private JsonObject? _filterQuery;
        private string? _filterUpdated;

        /// <summary>A route of the <c>history</c> scenario, or null when the method is not one.</summary>
        private byte[]? HistoryRoute(JsonObject request, string method)
        {
            var parameters = request.TryGetValue("params", out var p) && p is JsonObject o ? o : new JsonObject();
            switch (method)
            {
                case "job.list":
                {
                    var rows = DebugJobRows().Concat(JobsNow().Select(j => JobJson(j, list: true))).ToArray();
                    var older = new HashSet<string>([WaitingForRecoveryJobId, ResumeSafeJobId, LogJobId, SupersededJobId], StringComparer.Ordinal);
                    bool IsOlder(string row) => older.Any(id => row.Contains(id, StringComparison.Ordinal));
                    var cursor = parameters.TryGetValue("cursor", out var c) && c is JsonString s ? s.Value : null;
                    if (cursor is not null && cursor != OlderCursor) return Failure(request, "invalidInput", "unknown cursor");
                    var page = cursor is null ? rows.Where(r => !IsOlder(r)).ToArray() : rows.Where(IsOlder).ToArray();
                    var next = cursor is null ? $"\"{OlderCursor}\"" : "null";
                    return Success(request, Parse($$"""
                        {"hasMore":{{(cursor is null ? "true" : "false")}},"items":[{{string.Join(",", page)}}],"nextCursor":{{next}},"order":"createdAtDescJobIdAsc","pageKind":"snapshot","schemaVersion":"arkdeck.cli.page/1","snapshotRevision":"r1"}
                        """));
                }
                case "history.filter.list":
                {
                    var filters = _filterQuery is null ? "[]" : $"[{FilterResource()}]";
                    var updated = _filterUpdated is null ? "null" : $"\"{_filterUpdated}\"";
                    return Success(request, Parse($$"""
                        {"filters":{{filters}},"generation":"{{_filterGeneration}}","schemaVersion":"arkdeck.history-filter-list/1","updatedAtUtc":{{updated}}}
                        """));
                }
                case "history.filter.save":
                case "history.filter.delete":
                {
                    var expected = parameters.TryGetValue("expectedGeneration", out var g) && g is JsonString gs ? gs.Value : "";
                    if (expected != _filterGeneration.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    {
                        return Failure(request, "conflict", "The saved History filter changed. Reload it and try again.");
                    }
                    if (method == "history.filter.delete" && _filterQuery is null) return Failure(request, "notFound", "The saved History filter no longer exists.");
                    _filterQuery = method == "history.filter.save"
                        ? new JsonObject(parameters.Members.Where(m => m.Key != "expectedGeneration").OrderBy(m => m.Key, StringComparer.Ordinal))
                        : null;
                    _filterGeneration++;
                    _filterUpdated = "2026-10-04T00:00:0" + Math.Min(_filterGeneration, 9) + "Z";
                    return Success(request, Parse(FilterResource()));
                }
                default:
                    return null;
            }
        }

        private string FilterResource() =>
            $$"""{"generation":"{{_filterGeneration}}","query":{{(_filterQuery is null ? "null" : _filterQuery.ToString())}},"schemaVersion":"arkdeck.history-filter/1","updatedAtUtc":"{{_filterUpdated}}"}""";
    }
}
