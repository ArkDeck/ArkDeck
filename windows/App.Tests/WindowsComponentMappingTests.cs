using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ArkDeck.App.Core.Testing;

namespace ArkDeck.App.Tests;

/// <summary>
/// Closed source/fixture mapping for TASK-XPA-020's native semantic projection. This does
/// not run WinUI, prove native pixels/Narrator, or promote the synthetic JS gallery to hardware.
/// The named UIA flows and snapshots remain independently executable native software checks.
/// </summary>
[TestClass]
public sealed class WindowsComponentMappingTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    public void EveryControlledExportAndAll32PreviewsHaveExactNativeProjectionReferences()
    {
        var map = Load();
        Validate(map);
        TestContext.WriteLine("Closed source mapping:59controlledJSexports,32independentJSpreviews;native semantic projection only,pixelGalleryParity=false,narratorHumanValidation=false,hardwareEvidence=false.");
    }

    [TestMethod]
    [DataRow("missing")]
    [DataRow("duplicate")]
    [DataRow("unknown")]
    public void AComponentCannotBeMissingDuplicatedOrInvented(string mutation)
    {
        var map = Load();
        var components = map["componentGroups"]![0]!["components"]!.AsArray();
        if (mutation == "missing") components.RemoveAt(0);
        else if (mutation == "duplicate") components.Add(components[0]!.DeepClone());
        else components[0] = "InventedNativeGallery";
        Refuses(map, "componentCensus");
    }

    [TestMethod]
    [DataRow("missing")]
    [DataRow("duplicate")]
    [DataRow("unknown")]
    public void ThePreviewCensusCannotLoseDuplicateOrInventAnEntry(string mutation)
    {
        var map = Load();
        var previews = map["previews"]!.AsArray();
        if (mutation == "missing") previews.RemoveAt(0);
        else if (mutation == "duplicate") previews.Add(previews[0]!.DeepClone());
        else previews[0] = ".design-sync/previews/Invented.tsx";
        Refuses(map, "previewCensus");
    }

    [TestMethod]
    [DataRow("missingSource", "sourceMissing")]
    [DataRow("outsideRoot", "sourcePath")]
    [DataRow("missingAnchor", "sourceAnchor")]
    [DataRow("unknownCase", "testCase")]
    [DataRow("unknownSnapshot", "snapshot")]
    [DataRow("unknownIdentifier", "snapshotIdentifier")]
    [DataRow("wrongScenario", "snapshotScenario")]
    [DataRow("unknownField", "closedFields")]
    public void ProjectionReferencesAreMechanicalAndFailClosed(string mutation, string refusal)
    {
        var map = Load();
        var group = map["componentGroups"]![0]!;
        var source = group["sources"]![0]!;
        var proof = group["proofs"]![0]!;
        switch (mutation)
        {
            case "missingSource": source["path"] = "windows/App/Controls/Missing.cs"; break;
            case "outsideRoot": source["path"] = "windows/App/../../outside.cs"; break;
            case "missingAnchor": source["contains"] = "InventedGalleryAction("; break;
            case "unknownCase": proof["method"] = "InventedGalleryTest"; break;
            case "unknownSnapshot": proof["snapshotId"] = "gallery.invented"; break;
            case "unknownIdentifier": proof["automationIds"]![0] = "gallery.invented"; break;
            case "wrongScenario": proof["scenario"] = "invented"; break;
            case "unknownField": source["trustMe"] = true; break;
        }
        Refuses(map, refusal);
    }

    [TestMethod]
    public void AFlowMustNameTheActualTestAssertionAndScriptedScenario()
    {
        var map = Load();
        var proof = map["componentGroups"]!.AsArray().SelectMany(g => g!["proofs"]!.AsArray())
            .First(p => p!["kind"]!.GetValue<string>() == "scriptedFlow")!;
        proof["automationIds"]![0] = "gallery.invented";
        Refuses(map, "flowIdentifier");

        map = Load();
        proof = map["componentGroups"]!.AsArray().SelectMany(g => g!["proofs"]!.AsArray())
            .First(p => p!["method"]!.GetValue<string>() == "ALogCaptureAndATemplateRunAsTypedJobs")!;
        // This value occurs in both the fixture and test source as a result status, but it
        // is not a registered transport scenario and must never satisfy a source-only map.
        proof["scenario"] = "succeeded";
        Refuses(map, "snapshotScenario");

        map = Load();
        proof = map["componentGroups"]!.AsArray().SelectMany(g => g!["proofs"]!.AsArray())
            .First(p => p!["method"]!.GetValue<string>() == "ALogCaptureAndATemplateRunAsTypedJobs")!;
        proof["scenario"] = "inspector"; // registered, but not the Launch helper this method uses
        Refuses(map, "flowScenario");
    }

    [TestMethod]
    public void RetiredPlatformAndUpstreamReferencesCannotBePromotedToNativeGalleryClaims()
    {
        var map = Load();
        map["boundary"]!["pixelGalleryParity"] = true;
        Refuses(map, "boundary");
        map = Load();
        var retired = map["componentGroups"]!.AsArray().Single(g => g!["classification"]!.GetValue<string>() == "retiredAutomation")!;
        retired["classification"] = "nativeSemanticProjection";
        Refuses(map, "nativeSource");
        map = Load();
        map["upstream"]![0]!["classification"] = "nativeSemanticProjection";
        Refuses(map, "upstream");
    }

    private static JsonObject Load()
    {
        var bytes = File.ReadAllBytes(RepoPaths.At("windows", "spec", "windows-component-map.json"));
        using var parsed = JsonDocument.Parse(bytes);
        UniqueMembers(parsed.RootElement);
        return JsonNode.Parse(bytes)!.AsObject();
    }

    private static void UniqueMembers(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var member in value.EnumerateObject())
            {
                Require(names.Add(member.Name), "closedFields");
                UniqueMembers(member.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var member in value.EnumerateArray()) UniqueMembers(member);
    }

    private static void Validate(JsonObject map)
    {
        Fields(map, "schemaVersion", "feature", "scope", "boundary", "componentGroups", "previews", "upstream");
        Require(Text(map["schemaVersion"]) == "arkdeck.windows-component-map/1"
            && Text(map["feature"]) == "app.design.components"
            && Text(map["scope"]) == "TASK-XPA-020 native semantic projection", "scope");
        var boundary = map["boundary"]!.AsObject();
        Fields(boundary, "designPreviewCount", "controlledExportCount", "pixelGalleryParity", "narratorHumanValidation", "hardwareEvidence", "productionGalleryRoute");
        Require(boundary["designPreviewCount"]!.GetValue<int>() == 32 && boundary["controlledExportCount"]!.GetValue<int>() == 59
            && new[] { "pixelGalleryParity", "narratorHumanValidation", "hardwareEvidence", "productionGalleryRoute" }
                .All(k => boundary[k]!.GetValue<bool>() == false), "boundary");

        var exported = ValueNames(Read("docs/design/arkdeck-ds/src/index.ts"), "export", "./components/");
        Require(exported.Count == 59, "componentCensus");
        var groups = map["componentGroups"]!.AsArray();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var mapped = new HashSet<string>(StringComparer.Ordinal);
        var retired = new HashSet<string>(StringComparer.Ordinal);
        var chrome = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in groups)
        {
            var group = node!.AsObject();
            Fields(group, "id", "components", "classification", "projection", "sources", "proofs");
            Require(ids.Add(Text(group["id"])), "groupDuplicate");
            var classification = Text(group["classification"]);
            Require(classification is "nativeSemanticProjection" or "platformChrome" or "retiredAutomation", "classification");
            Require(Text(group["projection"]).Length >= 40, "projection");
            var components = Strings(group["components"]);
            Require(components.Length > 0, "componentCensus");
            foreach (var name in components)
            {
                Require(exported.Contains(name) && mapped.Add(name), "componentCensus");
                if (classification == "retiredAutomation") retired.Add(name);
                if (classification == "platformChrome") chrome.Add(name);
            }
            var sources = group["sources"]!.AsArray();
            Require(sources.Count > 0, "sourceMissing");
            foreach (var source in sources)
            {
                var path = Text(source!["path"]);
                if (classification != "retiredAutomation") Require(path.StartsWith("windows/App/", StringComparison.Ordinal), "nativeSource");
                CheckSource(source!.AsObject());
            }
            var proofs = group["proofs"]!.AsArray();
            Require(classification == "retiredAutomation" ? proofs.Count == 0 : proofs.Count > 0, "testCase");
            foreach (var proof in proofs) CheckProof(proof!.AsObject());
        }
        Require(mapped.SetEquals(exported), "componentCensus");
        Require(retired.SetEquals(new[] { "BudgetMeters", "OperationList", "StageTrack", "StatusStrip" }), "retiredScope");
        Require(chrome.SetEquals(new[] { "WindowFrame", "Symbol" }), "chromeScope");

        var previews = Strings(map["previews"]);
        var actual = Directory.EnumerateFiles(RepoPaths.At(".design-sync", "previews"), "*.tsx")
            .Select(p => ".design-sync/previews/" + Path.GetFileName(p)).Order(StringComparer.Ordinal).ToArray();
        Require(previews.Length == 32 && previews.Distinct(StringComparer.Ordinal).Count() == 32
            && previews.Order(StringComparer.Ordinal).SequenceEqual(actual, StringComparer.Ordinal), "previewCensus");
        foreach (var path in previews)
        {
            var imports = ValueNames(Read(path), "import", "@arkdeck/ds");
            Require(imports.Count > 0 && imports.IsSubsetOf(mapped), "previewImports");
        }

        var upstream = map["upstream"]!.AsArray();
        Require(upstream.Count == 1, "upstream");
        var canvas = upstream[0]!.AsObject();
        Fields(canvas, "id", "classification", "projection", "sources");
        Require(Text(canvas["id"]) == "ArkTraceCanvas" && Text(canvas["classification"]) == "upstreamExternal"
            && !mapped.Contains("ArkTraceCanvas") && Text(canvas["projection"]).Length >= 40, "upstream");
        Require(canvas["sources"]!.AsArray().Count >= 2, "upstream");
        foreach (var source in canvas["sources"]!.AsArray()) CheckSource(source!.AsObject());
    }

    private static void CheckProof(JsonObject proof)
    {
        Fields(proof, "kind", "path", "method", "scenario", "snapshotId", "automationIds");
        var kind = Text(proof["kind"]);
        Require(kind is "semanticSnapshot" or "scriptedFlow", "testCase");
        var path = Text(proof["path"]);
        Require(path.StartsWith("windows/App.UITests/", StringComparison.Ordinal) && path.EndsWith(".cs", StringComparison.Ordinal), "testCase");
        var source = Read(path);
        var method = Text(proof["method"]);
        Require(Regex.IsMatch(method, "^[A-Za-z][A-Za-z0-9]+$"), "testCase");
        var declaration = Regex.Match(source, @"\[TestMethod\]\s*(?:\[[^\r\n]*\]\s*)*public\s+(?:async\s+)?(?:void|Task)\s+" + Regex.Escape(method) + @"\(");
        Require(declaration.Success, "testCase");
        var next = source.IndexOf("[TestMethod]", declaration.Index + declaration.Length, StringComparison.Ordinal);
        var body = source[declaration.Index..(next < 0 ? source.Length : next)];
        var automationIds = Strings(proof["automationIds"]);
        Require(automationIds.Length > 0 && automationIds.Distinct(StringComparer.Ordinal).Count() == automationIds.Length, "testCase");
        var scenario = Text(proof["scenario"]);
        Require(ScriptedDaemon.Scenarios.Contains(scenario, StringComparer.Ordinal), "snapshotScenario");
        if (kind == "semanticSnapshot")
        {
            Require(path == "windows/App.UITests/SemanticSnapshotTests.cs" && method == "PagesMatchTheirSemanticSnapshots"
                && body.Contains("SurfaceSpec.Load(strings)", StringComparison.Ordinal), "testCase");
            using var snapshots = JsonDocument.Parse(Read("spec/ui-semantics/surfaces.json"));
            var matches = snapshots.RootElement.GetProperty("snapshots").EnumerateArray()
                .Where(s => s.GetProperty("id").GetString() == Text(proof["snapshotId"])).ToArray();
            Require(matches.Length == 1, "snapshot");
            var snapshot = matches[0];
            Require(snapshot.GetProperty("scenario").GetString() == scenario, "snapshotScenario");
            var actualIds = snapshot.GetProperty("elements").EnumerateArray().Select(e => e.GetProperty("automationId").GetString()!).ToHashSet(StringComparer.Ordinal);
            Require(automationIds.All(actualIds.Contains), "snapshotIdentifier");
        }
        else
        {
            Require(proof["snapshotId"] is null, "closedFields");
            Require(automationIds.All(id => body.Contains("\"" + id + "\"", StringComparison.Ordinal)), "flowIdentifier");
            var argumentPair = @"""--test-transport""\s*,\s*""" + Regex.Escape(scenario) + @"""";
            var direct = Regex.IsMatch(body, @"AppSession\.Launch\([^;]+?\[\s*" + argumentPair, RegexOptions.Singleline);
            // The Debug flow directly uses its one expression-bodied Launch helper. A random
            // matching status literal or another method's launch is never accepted as proof.
            var helpers = Regex.Matches(source, @"private\s+static\s+AppSession\s+Launch\(string\s+exe\)\s*=>\s*AppSession\.Launch\(exe,\s*\[([^;]+)\]\);");
            var helper = Regex.IsMatch(body, @"\bLaunch\(exe\)") && helpers.Count == 1
                && Regex.IsMatch(helpers[0].Groups[1].Value, @"^\s*" + argumentPair);
            Require(direct || helper, "flowScenario");
        }
    }

    private static HashSet<string> ValueNames(string source, string keyword, string module)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (Match match in Regex.Matches(source, @"\b" + keyword + @"\s*\{([^}]+)\}\s*from\s*[""']([^""']+)[""']", RegexOptions.Singleline))
        {
            if (!match.Groups[2].Value.StartsWith(module, StringComparison.Ordinal)) continue;
            foreach (var name in match.Groups[1].Value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                Require(Regex.IsMatch(name, "^[A-Za-z][A-Za-z0-9]+$") && names.Add(name), "componentCensus");
            }
        }
        return names;
    }

    private static void CheckSource(JsonObject source)
    {
        Fields(source, "path", "contains");
        var anchor = Text(source["contains"]);
        Require(anchor.Length >= 8 && Read(Text(source["path"])).Contains(anchor, StringComparison.Ordinal), "sourceAnchor");
    }

    private static string Read(string path)
    {
        Require(!Path.IsPathRooted(path) && !path.Contains('\\') && !path.Split('/').Any(p => p is "" or "." or "..")
            && (path.StartsWith("windows/", StringComparison.Ordinal) || path.StartsWith("docs/design/", StringComparison.Ordinal)
                || path.StartsWith(".design-sync/", StringComparison.Ordinal) || path == "spec/ui-semantics/surfaces.json"), "sourcePath");
        var absolute = RepoPaths.At(path.Replace('/', Path.DirectorySeparatorChar));
        Require(File.Exists(absolute), "sourceMissing");
        return File.ReadAllText(absolute);
    }

    private static string Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text)
        ? text : throw new InvalidDataException("closedFields");
    private static string[] Strings(JsonNode? node) => node is JsonArray array ? array.Select(Text).ToArray() : throw new InvalidDataException("closedFields");
    private static void Fields(JsonObject node, params string[] expected) => Require(node.Select(x => x.Key).ToHashSet(StringComparer.Ordinal).SetEquals(expected), "closedFields");
    private static void Require(bool condition, string reason) { if (!condition) throw new InvalidDataException(reason); }
    private static void Refuses(JsonObject map, string reason)
    {
        var failure = Assert.ThrowsExactly<InvalidDataException>(() => Validate(map));
        Assert.AreEqual(reason, failure.Message);
    }
}
