using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ArkDeck.App.Core.Presentation;

namespace ArkDeck.App.Tests;

/// <summary>
/// The UI dump Viewer's offline half read as macOS reads it (UIDumpCapture). The Swift oracle
/// <c>rust/tests/fixtures/ui-dump-inspect/cases.json</c> (recorded by
/// <c>CLIUIDumpInspectOracleContractTests</c> over <c>RuntimeCLI.emitUIDumpDerivation</c>,
/// <c>UIDumpOfflineInspector</c>, <c>ViewerCaptureParser</c> and <c>ViewerHitTesting</c>) is
/// replayed case by case: the Artifact bytes come from the scripted <c>artifact.read</c>
/// frames, and the parsed nodes, hit results and refusals must be the golden stdout's.
/// </summary>
[TestClass]
public sealed class UIDumpCaptureTests
{
    private static string Fixtures => RepoPaths.At("rust", "tests", "fixtures", "ui-dump-inspect");

    [TestMethod]
    public void EveryOracleCaseDerivesAsTheSwiftCliDerivedIt()
    {
        using var oracle = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Fixtures, "cases.json")));
        var cases = oracle.RootElement.EnumerateArray().ToList();
        Assert.AreEqual(19, cases.Count);
        using var provenance = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Fixtures, "provenance.json")));
        Assert.AreEqual("CLIUIDumpInspectOracleContractTests", provenance.RootElement.GetProperty("producer").GetString());

        var mismatches = new List<string>();
        var replayed = 0;
        foreach (var @case in cases)
        {
            var name = @case.GetProperty("name").GetString()!;
            var argv = @case.GetProperty("argv").EnumerateArray().Select(a => a.GetString()!).ToList();
            var verb = argv[1];
            string? Option(string flag) => argv.IndexOf(flag) is var at and >= 0 ? argv[at + 1] : null;
            var job = Option("--job")!;

            var entries = new List<UIDumpArtifactEntry>();
            var reads = new Dictionary<string, SortedDictionary<long, byte[]>>(StringComparer.Ordinal);
            foreach (var frame in @case.GetProperty("script").EnumerateArray())
            {
                var result = frame.GetProperty("result");
                switch (frame.GetProperty("method").GetString())
                {
                    case "artifact.list":
                        foreach (var row in result.GetProperty("items").EnumerateArray())
                        {
                            entries.Add(UIDumpArtifactEntry.FromJson(ArkDeck.ClientKit.Json.StrictJson.Parse(Encoding.UTF8.GetBytes(row.GetRawText()))));
                        }
                        break;
                    case "artifact.read":
                        var id = result.GetProperty("artifactId").GetString()!;
                        if (!reads.TryGetValue(id, out var ranges)) reads[id] = ranges = [];
                        ranges[result.GetProperty("offset").GetInt64()] = Convert.FromBase64String(result.GetProperty("base64").GetString()!);
                        break;
                }
            }
            byte[]? Bytes(UIDumpSource? source) =>
                source is not null && reads.TryGetValue(source.ArtifactId, out var parts) ? [.. parts.Values.SelectMany(p => p)] : null;

            JsonNode answer;
            IReadOnlyList<string>? identities = null;
            try
            {
                var selection = UIDumpCapture.SelectArtifacts(job, entries);
                var inspection = UIDumpCapture.Derive(selection, Bytes(selection.Screenshot) ?? [], Bytes(selection.Tree) ?? [], Bytes(selection.RawDump));
                var derivation = DerivationJson(inspection.Provenance);
                if (verb == "inspect")
                {
                    answer = new JsonObject
                    {
                        ["schemaVersion"] = inspection.SchemaVersion,
                        ["derivation"] = derivation,
                        ["capture"] = CaptureJson(inspection.Capture),
                    };
                    identities = inspection.Capture.Nodes.Select(n => n.Identity).ToList();
                }
                else
                {
                    var x = double.Parse(Option("--x")!, CultureInfo.InvariantCulture);
                    var y = double.Parse(Option("--y")!, CultureInfo.InvariantCulture);
                    var hit = UIDumpCapture.DeriveHitTest(inspection, x, y, Option("--root"));
                    Assert.AreEqual(hit.Node?.Identity, UIDumpCapture.HitTest(inspection.Capture, Option("--root"), x, y));
                    answer = new JsonObject
                    {
                        ["schemaVersion"] = hit.SchemaVersion,
                        ["derivation"] = derivation,
                        ["point"] = new JsonObject { ["x"] = hit.X, ["y"] = hit.Y },
                        ["node"] = hit.Node is null ? null : NodeJson(hit.Node),
                    };
                    identities = hit.Node is null ? [] : [hit.Node.Identity];
                }
            }
            catch (UIDumpDerivationException failure)
            {
                var error = new JsonObject { ["code"] = failure.Code, ["message"] = failure.Message };
                if (failure.JobId is not null) error["details"] = new JsonObject { ["jobId"] = failure.JobId };
                answer = new JsonObject { ["error"] = error };
            }

            replayed++;
            var stdout = @case.GetProperty("stdout").GetString()!;
            if (stdout.StartsWith('{'))
            {
                using var golden = JsonDocument.Parse(stdout);
                var root = golden.RootElement;
                JsonNode expected;
                if (root.GetProperty("ok").GetBoolean())
                {
                    expected = JsonNode.Parse(root.GetProperty("result").GetRawText())!;
                }
                else
                {
                    var error = root.GetProperty("error");
                    var e = new JsonObject { ["code"] = error.GetProperty("code").GetString(), ["message"] = error.GetProperty("message").GetString() };
                    if (error.TryGetProperty("details", out var details)) e["details"] = JsonNode.Parse(details.GetRawText());
                    expected = new JsonObject { ["error"] = e };
                }
                if (!Same(expected, answer)) mismatches.Add($"{name}: expected {expected.ToJsonString()}, got {answer.ToJsonString()}");
            }
            else
            {
                // The human rendering lists every node it derived; its identities are the machine answer's.
                var golden = stdout.Split('\n').Select(l => l.Trim()).Where(l => l.StartsWith("identity: ", StringComparison.Ordinal))
                    .Select(l => l["identity: ".Length..]).ToList();
                if (identities is null || !golden.SequenceEqual(identities))
                {
                    mismatches.Add($"{name}: expected identities {string.Join(",", golden)}, got {(identities is null ? answer.ToJsonString() : string.Join(",", identities))}");
                }
            }
        }
        Assert.AreEqual(19, replayed);
        Assert.AreEqual(0, mismatches.Count, string.Join("\n", mismatches));
    }

    [TestMethod]
    public void ParserKeepsRawFieldsAndDeviceIdentityAndFindsTheWindow()
    {
        var capture = UIDumpCapture.Parse(Png(720, 1280), Encoding.UTF8.GetBytes("""
            {"attributes":{"id":"1","type":"Page","bounds":"[0,0][720,1280]","hostWindowId":"60","hitTestBehavior":"HitTestMode.Transparent","unknown":"kept"},"children":[{"attributes":{"id":"42","type":"Toggle","text":"Wi-Fi","bounds":"[40,80][220,136]","clickable":true,"childOnly":"not-root"},"children":[]}]}
            """), Encoding.UTF8.GetBytes("""{"windows":[{"id":"w1"}]}"""),
            new ViewerCaptureIdentity("job-1", "target-a", 7, "2026-08-22T00:00:00Z"));

        Assert.IsTrue(capture.CoordinatesAreVerified);
        Assert.AreEqual("2026-08-22T00:00:00Z", capture.CapturedAtUtc);
        var toggle = capture.Nodes.Single(n => n.DeviceId == "42");
        Assert.AreEqual("device:42", toggle.Identity);
        Assert.AreEqual("device:1", toggle.ParentIdentity);
        Assert.AreEqual(1, toggle.Depth);
        Assert.AreEqual(true, toggle.Clickable);
        Assert.AreEqual("HitTestMode.Transparent", capture.NodeById("device:1")?.HitTestBehavior);
        var root = UIDumpCapture.RawDump(capture.NodeById("device:1")!);
        StringAssert.Contains(root, "unknown");
        Assert.IsFalse(root.Contains("children", StringComparison.Ordinal));
        Assert.IsFalse(root.Contains("childOnly", StringComparison.Ordinal));
        StringAssert.StartsWith(root, "{\n  \"attributes\" : {\n    \"bounds\" : \"[0,0][720,1280]\",\n");
        StringAssert.Contains(UIDumpCapture.RawDump(toggle), "childOnly");
        Assert.AreEqual(new ViewerAdvancedDumpSelection("60", "42"), UIDumpCapture.AdvancedDumpSelectionFor(capture, "device:42"));
        Assert.AreEqual(60L, UIDumpCapture.WindowIdFor(capture, "device:42"));
        Assert.AreEqual("60", capture.NodeById("device:1")!.HostWindowId);
        Assert.IsNull(toggle.HostWindowId);
        Assert.AreEqual("device:42", UIDumpCapture.HitTest(capture, null, 60, 100));
        Assert.AreEqual(ViewerBounds.Create(40, 80, 180, 56), toggle.VisibleBounds);
    }

    [TestMethod]
    public void DuplicateDeviceIdsFallBackToPathsAndUnprovenCoordinatesHitNothing()
    {
        var capture = UIDumpCapture.Parse(Png(720, 1280), Encoding.UTF8.GetBytes("""
            {"attributes":{"id":"same","type":"Page","bounds":"[0,0][700,1280]"},"children":[{"attributes":{"id":"same","type":"Text"},"children":[]}]}
            """), null);
        Assert.IsFalse(capture.CoordinatesAreVerified);
        CollectionAssert.AreEqual(new[] { "path:0", "path:0.0" }, capture.Nodes.Select(n => n.Identity).ToArray());
        Assert.IsNull(UIDumpCapture.HitTest(capture, null, 1, 1));
        Assert.IsNull(capture.Nodes[0].VisibleBounds);
    }

    [TestMethod]
    public void ClippingAncestorsBoundVisibilityAndHits()
    {
        var capture = UIDumpCapture.Parse(Png(200, 200), Encoding.UTF8.GetBytes("""
            {"type":"Window","id":"window","bounds":[0,0,200,200],"children":[
              {"type":"List","id":"parent","clip":true,"bounds":[0,0,100,100],"hitTestBehavior":"none","children":[
                {"type":"ListItem","id":"child","bounds":[80,80,100,100]}]}]}
            """), null);
        Assert.AreEqual(ViewerBounds.Create(80, 80, 20, 20), capture.NodeById("device:child")!.VisibleBounds);
        Assert.AreEqual("device:child", UIDumpCapture.HitTest(capture, null, 90, 90));
        Assert.AreEqual("device:window", UIDumpCapture.HitTest(capture, null, 120, 120));
        Assert.AreEqual("device:window", UIDumpCapture.HitTest(capture, null, 50, 50));
        Assert.AreEqual(ViewerBounds.Create(0, 1200, 720, 80),
            ViewerBounds.Create(-40, 1200, 800, 160)!.Intersection(ViewerBounds.Create(0, 0, 720, 1280)!));
    }

    [TestMethod]
    public void HitTestingPrefersTheFloatingBranchOverDeeperContent()
    {
        var capture = UIDumpCapture.Parse(Png(200, 200), Encoding.UTF8.GetBytes("""
            {"type":"Root","id":"root","bounds":[0,0,200,200],"children":[
              {"type":"List","id":"content","bounds":[0,0,200,200],"zIndex":0,"children":[
                {"type":"Image","id":"poster","bounds":[0,0,200,200]}]},
              {"type":"TabBar","id":"tabbar","bounds":[10,150,180,40],"hitTestBehavior":"HitTestMode.Transparent","zIndex":3,"children":[
                {"type":"Column","id":"item","bounds":[10,150,180,40],"children":[
                  {"type":"SymbolGlyph","id":"icon","bounds":[140,155,40,30]}]}]},
              {"type":"Column","id":"overlay","bounds":[0,0,200,200],"hitTestBehavior":"HitTestMode.Transparent","zIndex":88}]}
            """), null);
        Assert.AreEqual("device:icon", UIDumpCapture.HitTest(capture, "device:root", 160, 170));
        Assert.AreEqual("device:poster", UIDumpCapture.HitTest(capture, "device:root", 5, 5));
        Assert.IsNull(UIDumpCapture.HitTest(capture, "device:missing", 5, 5));
    }

    [TestMethod]
    public void SearchAndOutlineRowsFollowTheViewer()
    {
        var capture = UIDumpCapture.Parse(Png(100, 100), Encoding.UTF8.GetBytes("""
            {"type":"Root","id":"r","bounds":[0,0,100,100],"children":[
              {"type":"Column","id":"c","children":[{"type":"Text","id":"t","text":"Hello World"}]},
              {"type":"Button","id":"b","inspectorId":"okButton"}]}
            """), null);
        CollectionAssert.AreEqual(new[] { "device:t" }, UIDumpCapture.Search(capture, "device:r", "  hello ").ToArray());
        CollectionAssert.AreEqual(new[] { "device:b" }, UIDumpCapture.Search(capture, null, "OKBUTTON").ToArray());
        Assert.AreEqual(0, UIDumpCapture.Search(capture, "device:c", "button").Count);
        Assert.AreEqual(0, UIDumpCapture.Search(capture, null, "   ").Count);
        var empty = new HashSet<string>();
        CollectionAssert.AreEqual(new[] { "device:r" }, UIDumpCapture.VisibleRows(capture, null, empty, "").Select(n => n.Identity).ToArray());
        CollectionAssert.AreEqual(new[] { "device:r", "device:c", "device:b" },
            UIDumpCapture.VisibleRows(capture, null, new HashSet<string> { "device:r" }, "").Select(n => n.Identity).ToArray());
        CollectionAssert.AreEqual(new[] { "device:r", "device:c", "device:t" },
            UIDumpCapture.VisibleRows(capture, null, empty, "world").Select(n => n.Identity).ToArray());
        Assert.AreEqual(0, UIDumpCapture.VisibleRows(capture, null, empty, "absent").Count);
        Assert.AreEqual("device:r", capture.PrimaryRootIdentity);
    }

    [TestMethod]
    public void AdvancedDumpReadsJsonOrKeyValueLinesAndRefusesTheSidecar()
    {
        var fields = UIDumpCapture.ParseAdvancedDump("""
            WaterFlow dump:
              accessibilityId : 841
              layoutConstraint: { minWidth: 0, maxWidth: 1280 }
              scrollable : true
            """);
        CollectionAssert.AreEqual(new[]
        {
            new ViewerDumpField("WaterFlow dump", ""),
            new ViewerDumpField("accessibilityId", "841"),
            new ViewerDumpField("layoutConstraint", "{ minWidth: 0, maxWidth: 1280 }"),
            new ViewerDumpField("scrollable", "true"),
        }, fields.ToArray());

        var json = UIDumpCapture.ParseAdvancedDump(Encoding.UTF8.GetBytes("""{"b":{"z":"a/b","a":[1,2.5]},"a":null,"c":true,"d":3.0}"""));
        CollectionAssert.AreEqual(new[]
        {
            new ViewerDumpField("a", "null"),
            new ViewerDumpField("b", "{\"a\":[1,2.5],\"z\":\"a/b\"}"),
            new ViewerDumpField("c", "1"),
            new ViewerDumpField("d", "3"),
        }, json.ToArray());

        var sidecar = Assert.ThrowsExactly<UIDumpCaptureException>(() =>
            UIDumpCapture.ParseAdvancedDump("Dump saved to /data/app/example/files/arkui-comp.dump\n"));
        Assert.AreEqual("advancedDumpRequiresSidecar", sidecar.Code);
        var invalid = Assert.ThrowsExactly<UIDumpCaptureException>(() => UIDumpCapture.ParseAdvancedDump("{}"));
        Assert.AreEqual(UIDumpCaptureErrorKind.InvalidAdvancedDump, invalid.Kind);
        Assert.AreEqual("ArkUI returned no readable key : value fields for this component", invalid.Message);
        Assert.ThrowsExactly<UIDumpCaptureException>(() => UIDumpCapture.ParseAdvancedDump([0xFF, 0x3A]));
    }

    [TestMethod]
    public void MalformedInputsAreNamedAsSwiftNamesThem()
    {
        Assert.AreEqual("invalidPNG", Assert.ThrowsExactly<UIDumpCaptureException>(() => UIDumpCapture.Parse("nope"u8.ToArray(), "{}"u8.ToArray(), null)).Code);
        Assert.AreEqual("invalidPNG", Assert.ThrowsExactly<UIDumpCaptureException>(() => UIDumpCapture.Parse(Png(0, 1), "{}"u8.ToArray(), null)).Code);
        Assert.AreEqual("unreadableTree", Assert.ThrowsExactly<UIDumpCaptureException>(() => UIDumpCapture.Parse(Png(1, 1), "[]"u8.ToArray(), null)).Code);
        Assert.AreEqual("unreadableTree", Assert.ThrowsExactly<UIDumpCaptureException>(() => UIDumpCapture.Parse(Png(1, 1), "{"u8.ToArray(), null)).Code);
        var invalid = Assert.ThrowsExactly<UIDumpCaptureException>(() => UIDumpCapture.Parse(Png(1, 1), """{"type":"A","children":[1]}"""u8.ToArray(), null));
        Assert.AreEqual("invalidTree", invalid.Code);
        Assert.AreEqual("The UI tree Artifact does not contain a valid node tree", invalid.Message);
    }

    [TestMethod]
    public void ScalarsBridgeAsFoundationBridgesThem()
    {
        var capture = UIDumpCapture.Parse(Png(10, 10), """
            {"type":"Root","id":12,"bounds":"[-1.5,.5][3.,x4]","children":[
              {"type":true,"id":"a","text":0.1,"clickable":1,"enabled":2,"focused":"TRUE","zIndex":"1e2","visible":"false"},
              {"id":"b","class":"K","zOrder":"inf","text":"","bounds":[1,2,3]}]}
            """u8.ToArray(), null);
        var root = capture.Nodes[0];
        Assert.AreEqual("12", root.DeviceId);
        Assert.AreEqual(ViewerBounds.Create(-1.5, 0.5, 4.5, 3.5), root.Bounds);
        var a = capture.NodeById("device:a")!;
        Assert.AreEqual("1", a.Type);
        Assert.AreEqual("0.1", a.Text);
        Assert.AreEqual(true, a.Clickable);
        Assert.IsNull(a.Enabled);
        Assert.IsNull(a.Focused);
        Assert.AreEqual(100.0, a.ZIndex);
        Assert.IsFalse(a.Visible);
        var b = capture.NodeById("device:b")!;
        Assert.AreEqual("K", b.Type);
        Assert.IsNull(b.ZIndex);
        Assert.IsNull(b.Text);
        Assert.IsNull(b.Bounds);
        Assert.AreEqual("{\"bounds\":[1,2,3],\"class\":\"K\",\"id\":\"b\",\"text\":\"\",\"zOrder\":\"inf\"}", b.RawFields);
    }

    [TestMethod]
    public void DerivationRefusesDuplicateArtifactIdsAndPointsOnUnverifiedCaptures()
    {
        var png = Png(4, 4);
        var tree = """{"type":"W","id":"w","bounds":[0,0,2,2]}"""u8.ToArray();
        var digest = (byte[] b) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(b));
        var entries = new List<UIDumpArtifactEntry>
        {
            new("ART-1", "screenshot.png", "image/png", digest(png), png.Length, "published", "sensitive", "2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z"),
            new("ART-1", "ui-tree.json", "application/json", digest(tree), tree.Length, "published", "sensitive"),
        };
        var selection = UIDumpCapture.SelectArtifacts("job-a", entries);
        var duplicate = Assert.ThrowsExactly<UIDumpDerivationException>(() => UIDumpCapture.Derive(selection, png, tree, null));
        Assert.AreEqual("recordUnreadable", duplicate.Code);
        Assert.AreEqual("the capture artifacts did not parse: invalidSource(\"duplicateArtifactId\")", duplicate.Message);

        entries[1] = entries[1] with { ArtifactId = "ART-2" };
        var inspection = UIDumpCapture.Derive(UIDumpCapture.SelectArtifacts("job-a", entries), png, tree, null);
        Assert.IsFalse(inspection.Capture.CoordinatesAreVerified);
        Assert.AreEqual("2026-01-01T00:00:00Z", inspection.Provenance.ObservedFromUtc);
        var drifted = Assert.ThrowsExactly<UIDumpDerivationException>(() => UIDumpCapture.DeriveHitTest(inspection, 1, 1));
        Assert.AreEqual("factsDrifted", drifted.Code);
        Assert.AreEqual("job-a", drifted.JobId);

        var mismatch = Assert.ThrowsExactly<UIDumpDerivationException>(() =>
            UIDumpCapture.Derive(UIDumpCapture.SelectArtifacts("job-a", entries), png, [.. tree, 0x20], null));
        Assert.AreEqual("artifactIntegrityFailed", mismatch.Code);
        Assert.AreEqual("artifact `ui-tree.json` byte count does not match its Runtime metadata", mismatch.Message);
    }

    private static byte[] Png(uint width, uint height)
    {
        var bytes = new List<byte> { 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13 };
        bytes.AddRange("IHDR"u8.ToArray());
        bytes.AddRange(BitConverter.GetBytes(width).Reverse());
        bytes.AddRange(BitConverter.GetBytes(height).Reverse());
        return [.. bytes];
    }

    /// <summary><c>CLIOfflineDerivation</c>'s derivation object.</summary>
    private static JsonObject DerivationJson(UIDumpProvenance provenance) => new()
    {
        ["kind"] = provenance.Kind,
        ["parser"] = provenance.Parser,
        ["parserVersion"] = provenance.ParserVersion,
        ["observedFromUtc"] = provenance.ObservedFromUtc,
        ["observedToUtc"] = provenance.ObservedToUtc,
        ["sources"] = new JsonArray([.. provenance.Sources.Select(s => (JsonNode?)new JsonObject
        {
            ["artifactId"] = s.ArtifactId,
            ["name"] = s.Name,
            ["mediaType"] = s.MediaType,
            ["sha256"] = s.Sha256,
            ["byteCount"] = s.ByteCount,
        })]),
    };

    private static JsonObject CaptureJson(ViewerCapture capture) => new()
    {
        ["screenshot"] = new JsonObject { ["width"] = capture.ScreenshotWidth, ["height"] = capture.ScreenshotHeight },
        ["coordinatesAreVerified"] = capture.CoordinatesAreVerified,
        ["roots"] = new JsonArray([.. capture.Roots.Select(r => (JsonNode?)r)]),
        ["nodeCount"] = capture.Nodes.Count,
        ["nodes"] = new JsonArray([.. capture.Nodes.Select(n => (JsonNode?)NodeJson(n))]),
    };

    /// <summary><c>CLIOfflineDerivation.encode(node:)</c>.</summary>
    private static JsonObject NodeJson(ViewerNode node) => new()
    {
        ["identity"] = node.Identity,
        ["deviceId"] = node.DeviceId,
        ["parentIdentity"] = node.ParentIdentity,
        ["children"] = new JsonArray([.. node.Children.Select(c => (JsonNode?)c)]),
        ["type"] = node.Type,
        ["text"] = node.Text,
        ["inspectorId"] = node.InspectorId,
        ["bounds"] = node.Bounds is { } b
            ? new JsonObject { ["x"] = b.X, ["y"] = b.Y, ["width"] = b.Width, ["height"] = b.Height }
            : null,
        ["visible"] = node.Visible,
        ["enabled"] = node.Enabled,
        ["clickable"] = node.Clickable,
        ["focusable"] = node.Focusable,
        ["focused"] = node.Focused,
        ["clipsChildren"] = node.ClipsChildren,
        ["hitTestBehavior"] = node.HitTestBehavior,
        ["zIndex"] = node.ZIndex,
        ["depth"] = node.Depth,
    };

    /// <summary>Structural equality with numbers compared by value (the golden spells a whole
    /// binary64 without a fraction).</summary>
    private static bool Same(JsonNode? expected, JsonNode? actual)
    {
        switch (expected)
        {
            case null:
                return actual is null;
            case JsonObject eo:
                return actual is JsonObject ao && eo.Count == ao.Count
                       && eo.All(p => ao.TryGetPropertyValue(p.Key, out var v) && Same(p.Value, v));
            case JsonArray ea:
                return actual is JsonArray aa && ea.Count == aa.Count && ea.Zip(aa).All(p => Same(p.First, p.Second));
            default:
                if (actual is null or JsonObject or JsonArray) return false;
                var ek = expected.GetValueKind();
                var ak = actual.GetValueKind();
                if (ek != ak) return false;
                return ek switch
                {
                    JsonValueKind.Number => double.Parse(expected.ToJsonString(), CultureInfo.InvariantCulture) == double.Parse(actual.ToJsonString(), CultureInfo.InvariantCulture),
                    _ => expected.ToJsonString() == actual.ToJsonString(),
                };
        }
    }
}
