using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Testing;

public static partial class ScriptedDaemon
{
    // Explicit software-only discovery fixtures; no helper is registered, selected or run.
    public const string ToolchainInventory = "toolchain-inventory";
    public const string ToolchainInventoryEmpty = "toolchain-inventory-empty";
    public const string ToolchainInventoryRefused = "toolchain-inventory-refused";
    public const string FirstBundleRef = "bundle:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    public const string SecondBundleRef = "bundle:sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    private sealed partial class Script
    {
        private byte[]? ToolchainInventoryRoute(JsonObject request, string method)
        {
            if (method == "runtime.tool.list")
            {
                var page = (JsonObject)Parse(ToolPageJson);
                if (scenario == ToolchainInventoryEmpty)
                    return Success(request, new JsonObject(page.Members.Select(m => m.Key == "items" ? new KeyValuePair<string, JsonValue>(m.Key, new JsonArray([])) : m)));
                var original = ((JsonArray)page["items"]).Items.Single() as JsonObject ?? throw new InvalidOperationException();
                var second = new JsonObject(original.Members.Select(m => m.Key switch
                {
                    "toolRef" => new KeyValuePair<string, JsonValue>(m.Key, new JsonString("tool-hdc-fixture-secondary")),
                    "selected" => new KeyValuePair<string, JsonValue>(m.Key, JsonBool.False),
                    _ => m,
                }));
                return Success(request, new JsonObject(page.Members.Select(m => m.Key == "items" ? new KeyValuePair<string, JsonValue>(m.Key, new JsonArray([original, second])) : m)));
            }
            if (method != "runtime.bundle.list") return null;
            if (scenario == ToolchainInventoryRefused)
                return Failure(request, "recordUnreadable", "Bundle registry is unreadable", Details("bootstrapRegistryOwner"));
            var parameters = request.TryGetValue("params", out var p) ? (JsonObject)p : new JsonObject();
            var next = parameters.TryGetValue("cursor", out var c) && c is JsonString { Value: "bundle-page-2" };
            if (parameters.ContainsKey("cursor") && !next) return Failure(request, "invalidCursor", "not this snapshot cursor", Details("bootstrapRegistryOwner"));
            var empty = scenario == ToolchainInventoryEmpty;
            var items = empty ? "[]" : "[" + Bundle(next ? 'b' : 'a', next ? "removed" : "available") + "]";
            var more = !empty && !next;
            return Success(request, Parse($$"""{"schemaVersion":"arkdeck.cli.page/1","pageKind":"snapshot","order":"bundleRef:asc","snapshotRevision":"bundle-inventory-fixture","hasMore":{{(more?"true":"false")}},"nextCursor":{{(more?"\"bundle-page-2\"":"null")}},"items":{{items}}}"""));
        }

        private static string Bundle(char digestCharacter, string state)
        {
            var digest = new string(digestCharacter, 64);
            var removed = state == "removed";
            var references = removed ? "[]" : "[{\"kind\":\"workspacePreset\",\"id\":\"preset-fixture\"}]";
            return $$$"""{"schemaVersion":"arkdeck.runtime-bundle/1","bundleRef":"bundle:sha256:{{{digest}}}","kind":"daemon-bundle","platform":"windows","version":"0.1.0","state":"{{{state}}}","contentDigest":"{{{digest}}}","digestAlgorithm":"sha256-jcs","contentSchemaVersion":"arkdeck.bundle-content/1","byteCount":"4096","entryCount":"3","generation":"{{{(removed?"2":"1")}}}","registeredAtUTC":"2026-10-07T00:00:00Z","contentRetained":true,"references":{{{references}}},"trust":{"policy":"arkdeck.windows-daemon-package/1","signature":"verified","teamIdentifier":"fixture-signer","executionAssessment":"notPerformed"}}""";
        }
    }
}
