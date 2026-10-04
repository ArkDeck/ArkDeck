using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>Why a UI dump capture or an Advanced Dump did not parse (macOS
/// <c>ViewerCaptureFailure</c>).</summary>
public enum UIDumpCaptureErrorKind
{
    UnreadableTree,
    InvalidTree,
    InvalidRawDump,
    InvalidPng,
    InvalidAdvancedDump,
    AdvancedDumpRequiresSidecar,
}

/// <summary>A capture refused by <c>ViewerCaptureParser</c> or <c>ViewerAdvancedDumpParser</c>.
/// <see cref="Code"/> is the Swift case name (<c>invalidPNG</c>, as <c>\(error)</c> spells it)
/// and <see cref="Exception.Message"/> is the case's <c>message</c>.</summary>
public sealed class UIDumpCaptureException(UIDumpCaptureErrorKind kind) : Exception(MessageOf(kind))
{
    public UIDumpCaptureErrorKind Kind { get; } = kind;

    public string Code => Kind switch
    {
        UIDumpCaptureErrorKind.UnreadableTree => "unreadableTree",
        UIDumpCaptureErrorKind.InvalidTree => "invalidTree",
        UIDumpCaptureErrorKind.InvalidRawDump => "invalidRawDump",
        UIDumpCaptureErrorKind.InvalidPng => "invalidPNG",
        UIDumpCaptureErrorKind.InvalidAdvancedDump => "invalidAdvancedDump",
        _ => "advancedDumpRequiresSidecar",
    };

    private static string MessageOf(UIDumpCaptureErrorKind kind) => kind switch
    {
        UIDumpCaptureErrorKind.UnreadableTree => "The UI tree Artifact is not readable JSON",
        UIDumpCaptureErrorKind.InvalidTree => "The UI tree Artifact does not contain a valid node tree",
        UIDumpCaptureErrorKind.InvalidRawDump => "The UI dump Artifact is not readable JSON",
        UIDumpCaptureErrorKind.InvalidPng => "The screenshot Artifact is not a valid PNG",
        UIDumpCaptureErrorKind.InvalidAdvancedDump => "ArkUI returned no readable key : value fields for this component",
        _ => "ArkUI moved this Advanced Dump to a remote sidecar; retrieval is not safely available for this device build",
    };
}

/// <summary>A refusal of the offline derivation as the CLI reports it
/// (<c>RuntimeCLI.emitUIDumpDerivation</c>): the control error <see cref="Code"/>
/// (<c>resourceNotFound</c>, <c>recordUnreadable</c>, <c>artifactIntegrityFailed</c>,
/// <c>factsDrifted</c>), its message, and the Job it names in <c>details.jobId</c> when the CLI
/// names one.</summary>
public sealed class UIDumpDerivationException(string code, string message, string? jobId = null) : Exception(message)
{
    public string Code { get; } = code;

    public string? JobId { get; } = jobId;
}

/// <summary>A provider rectangle (macOS <c>ViewerBounds</c>): finite, never negative in size.</summary>
public sealed record ViewerBounds
{
    private ViewerBounds(double x, double y, double width, double height)
    {
        X = x;
        Y = y;
        Width = width;
        Height = height;
    }

    public double X { get; }

    public double Y { get; }

    public double Width { get; }

    public double Height { get; }

    /// <summary>Swift's failable <c>init</c>: null unless every value is finite and the size is
    /// not negative.</summary>
    public static ViewerBounds? Create(double x, double y, double width, double height) =>
        double.IsFinite(x) && double.IsFinite(y) && double.IsFinite(width) && double.IsFinite(height) && width >= 0 && height >= 0
            ? new ViewerBounds(x, y, width, height)
            : null;

    /// <summary>Edges inclusive, as Swift's <c>contains(x:y:)</c>.</summary>
    public bool Contains(double x, double y) => x >= X && y >= Y && x <= X + Width && y <= Y + Height;

    /// <summary>The overlap, or null when it has no area.</summary>
    public ViewerBounds? Intersection(ViewerBounds other)
    {
        var left = Math.Max(X, other.X);
        var top = Math.Max(Y, other.Y);
        var right = Math.Min(X + Width, other.X + other.Width);
        var bottom = Math.Min(Y + Height, other.Y + other.Height);
        return right > left && bottom > top ? Create(left, top, right - left, bottom - top) : null;
    }
}

/// <summary>The Job a capture came from (macOS <c>ViewerCaptureIdentity</c>).</summary>
public sealed record ViewerCaptureIdentity(string JobId, string TargetId, long BindingRevision, string CapturedAtUtc);

/// <summary>One component of a capture (macOS <c>ViewerNode</c>). <see cref="Identity"/> is
/// private to the capture: <c>device:&lt;id&gt;</c> when the provider id is unique, else
/// <c>path:a.b.c</c>. <see cref="DeviceId"/> is only ever the provider's own value.</summary>
public sealed record ViewerNode
{
    public required string Identity { get; init; }

    public required string? DeviceId { get; init; }

    public required string? ParentIdentity { get; init; }

    public required IReadOnlyList<string> Children { get; init; }

    public required string Type { get; init; }

    public required string? Text { get; init; }

    public required string? InspectorId { get; init; }

    public required ViewerBounds? Bounds { get; init; }

    /// <summary>The pixels left visible on the screenshot by every clipping ancestor
    /// (<c>ViewerScreenshotMapping.visibleBounds(of:in:)</c>); null when the capture's
    /// coordinates are unverified or nothing is visible.</summary>
    public required ViewerBounds? VisibleBounds { get; init; }

    public required bool Visible { get; init; }

    public required bool? Enabled { get; init; }

    public required bool? Clickable { get; init; }

    public required bool? Focusable { get; init; }

    public required bool? Focused { get; init; }

    /// <summary>The provider's <c>clip</c> flag.</summary>
    public required bool ClipsChildren { get; init; }

    public required string? HitTestBehavior { get; init; }

    /// <summary><c>zIndex</c>, else <c>zOrder</c>.</summary>
    public required double? ZIndex { get; init; }

    /// <summary>This node's own decimal <c>hostWindowId</c>, if it publishes one (see
    /// <see cref="UIDumpCapture.WindowIdFor"/> for the inherited one).</summary>
    public required string? HostWindowId { get; init; }

    public required int Depth { get; init; }

    /// <summary>The component's own JSON object without <c>children</c>, compact and key-sorted
    /// as <c>JSONSerialization</c> writes it.</summary>
    public required string RawFields { get; init; }

    internal IReadOnlyDictionary<string, object> Fields { get; init; } = new Dictionary<string, object>();

    /// <summary>Swift <c>acceptsPointerHit</c>: <c>None</c> and <c>Transparent</c> pass a click
    /// through.</summary>
    public bool AcceptsPointerHit => HitTestBehavior?.ToLowerInvariant() is not ("none" or "transparent" or "hittestmode.none" or "hittestmode.transparent");
}

/// <summary>One immutable parsed capture (macOS <c>ViewerCapture</c>).</summary>
public sealed class ViewerCapture
{
    private readonly Dictionary<string, ViewerNode> _index;

    internal ViewerCapture(
        byte[] screenshotPng,
        int screenshotWidth,
        int screenshotHeight,
        IReadOnlyList<string> roots,
        IReadOnlyList<ViewerNode> nodes,
        byte[]? rawDumpDocument,
        ViewerCaptureIdentity? identity,
        bool coordinatesAreVerified)
    {
        ScreenshotPng = screenshotPng;
        ScreenshotWidth = screenshotWidth;
        ScreenshotHeight = screenshotHeight;
        Roots = roots;
        Nodes = nodes;
        RawDumpDocument = rawDumpDocument;
        Identity = identity;
        CoordinatesAreVerified = coordinatesAreVerified;
        _index = new Dictionary<string, ViewerNode>(StringComparer.Ordinal);
        foreach (var node in nodes) _index.TryAdd(node.Identity, node);
    }

    public byte[] ScreenshotPng { get; }

    public int ScreenshotWidth { get; }

    public int ScreenshotHeight { get; }

    public IReadOnlyList<string> Roots { get; }

    /// <summary>Every component, depth first in provider order.</summary>
    public IReadOnlyList<ViewerNode> Nodes { get; }

    public byte[]? RawDumpDocument { get; }

    public ViewerCaptureIdentity? Identity { get; }

    public string? CapturedAtUtc => Identity?.CapturedAtUtc;

    public bool CoordinatesAreVerified { get; }

    public ViewerNode? NodeById(string identity) => _index.GetValueOrDefault(identity);

    /// <summary>The unique focused root, else the first root.</summary>
    public string? PrimaryRootIdentity
    {
        get
        {
            var focused = Roots.Where(r => NodeById(r)?.Focused == true).ToList();
            return focused.Count == 1 ? focused[0] : Roots.Count > 0 ? Roots[0] : null;
        }
    }

    /// <summary>Swift <c>ancestors(of:)</c>: root first, bounded against cycles.</summary>
    public IReadOnlyList<string> Ancestors(string identity)
    {
        var result = new List<string>();
        var visited = new HashSet<string>(StringComparer.Ordinal);
        var cursor = NodeById(identity)?.ParentIdentity;
        while (cursor is not null && visited.Add(cursor) && NodeById(cursor) is { } node)
        {
            result.Add(cursor);
            cursor = node.ParentIdentity;
        }
        result.Reverse();
        return result;
    }

    /// <summary>Swift <c>subtreeNodes(rootIdentity:)</c>: every node without a root; nothing
    /// for an unknown root; else the root's subtree in provider order.</summary>
    public IReadOnlyList<ViewerNode> SubtreeNodes(string? rootIdentity)
    {
        if (string.IsNullOrEmpty(rootIdentity)) return Nodes;
        if (NodeById(rootIdentity) is null) return [];
        var included = new HashSet<string>(StringComparer.Ordinal);
        var pending = new List<string> { rootIdentity };
        while (pending.Count > 0)
        {
            var identity = pending[^1];
            pending.RemoveAt(pending.Count - 1);
            if (!included.Add(identity)) break;
            if (NodeById(identity) is { } node) pending.AddRange(node.Children);
        }
        return Nodes.Where(n => included.Contains(n.Identity)).ToList();
    }
}

/// <summary>One key/value of an Advanced Dump (macOS <c>ViewerDumpField</c>).</summary>
public sealed record ViewerDumpField(string Key, string Value);

/// <summary>The ids the <c>componentDetail</c> recipe takes (macOS
/// <c>ViewerAdvancedDumpSelection</c>).</summary>
public sealed record ViewerAdvancedDumpSelection(string WindowId, string ComponentId);

/// <summary>One Artifact of the capture Job as <c>artifact.list</c> reports it; every member
/// the derivation checks may be absent, as the CLI checks it.</summary>
public sealed record UIDumpArtifactEntry(
    string? ArtifactId,
    string? Name,
    string? MediaType,
    string? Sha256,
    long? ByteCount,
    string? Status,
    string? Privacy,
    string? ObservedFromUtc = null,
    string? ObservedToUtc = null)
{
    /// <summary>An <c>artifact.list</c> row: <c>artifactDigest</c> is the SHA-256 and
    /// <c>observationWindow.startUtc/endUtc</c> the observation window.</summary>
    public static UIDumpArtifactEntry FromJson(JsonValue row)
    {
        static string? S(JsonValue value) => value is JsonString s ? s.Value : null;
        long? count = row["byteCount"] is JsonNumber n && n.TryGetInt64(out var c) && c >= 0 ? c : null;
        var window = row["observationWindow"];
        return new UIDumpArtifactEntry(
            S(row["artifactId"]), S(row["name"]), S(row["mediaType"]), S(row["artifactDigest"]), count,
            S(row["status"]), S(row["privacy"]), S(window["startUtc"]), S(window["endUtc"]));
    }

    /// <summary>A row the App already projected; the observation window comes from elsewhere.</summary>
    public static UIDumpArtifactEntry FromSummary(ArtifactSummary summary, string? observedFromUtc = null, string? observedToUtc = null) =>
        new(summary.ArtifactId, summary.Name, summary.MediaType, summary.Digest, summary.ByteCount,
            summary.Status, summary.Privacy, observedFromUtc, observedToUtc);
}

/// <summary>One immutable Artifact a derivation reads (macOS <c>UIDumpOfflineSource</c>).</summary>
public sealed record UIDumpSource(string ArtifactId, string Name, string MediaType, string Sha256, long ByteCount);

/// <summary>The Artifacts of one capture Job the derivation will read, and the screenshot's
/// observation window.</summary>
public sealed record UIDumpSelection(
    string JobId,
    UIDumpSource Tree,
    UIDumpSource Screenshot,
    UIDumpSource? RawDump,
    string? ObservedFromUtc,
    string? ObservedToUtc);

/// <summary>macOS <c>UIDumpOfflineProvenance</c>: sources sorted by name, then Artifact id.</summary>
public sealed record UIDumpProvenance(
    string Kind,
    string Parser,
    string ParserVersion,
    string? ObservedFromUtc,
    string? ObservedToUtc,
    IReadOnlyList<UIDumpSource> Sources);

/// <summary>macOS <c>UIDumpOfflineInspection</c>.</summary>
public sealed record UIDumpInspection(string SchemaVersion, string JobId, UIDumpProvenance Provenance, ViewerCapture Capture);

/// <summary>macOS <c>UIDumpOfflineHitTest</c>.</summary>
public sealed record UIDumpHitTest(string SchemaVersion, UIDumpProvenance Provenance, double X, double Y, ViewerNode? Node);

/// <summary>
/// The macOS UI dump Viewer's offline half: <c>ViewerCaptureParser</c> (PNG size, the
/// <c>dumpLayout</c> tree, identities, the coordinate proof), <c>ViewerScreenshotMapping</c>
/// (clipped visible bounds), <c>ViewerHitTesting</c>, <c>ViewerCapture</c>'s search, outline rows,
/// Raw dump and Advanced Dump selection, <c>ViewerAdvancedDumpParser</c>, and the derivation the
/// CLI runs over a Job's Artifacts (<c>UIDumpOfflineInspector</c> behind
/// <c>RuntimeCLI.emitUIDumpDerivation</c>). Nothing here reads a path or contacts a device.
/// </summary>
public static class UIDumpCapture
{
    public const string ParserId = "arkdeck.viewer.ui-dump-parser";
    public const string ParserVersion = "1.0.0";
    public const string InspectionSchemaVersion = "arkdeck.ui-dump-inspection/1";
    public const string HitTestSchemaVersion = "arkdeck.ui-dump-hit-test/1";
    public const long MaximumCaptureBytes = 64L * 1024 * 1024;
    public const string ScreenshotName = "screenshot.png";
    public const string ScreenshotMediaType = "image/png";
    public const string TreeName = "ui-tree.json";
    public const string TreeMediaType = "application/json";
    public const string RawDumpName = "ui-dump.json";
    public const string RawDumpMediaType = "application/json";

    // ---- ViewerCaptureParser ----

    /// <summary>macOS <c>ViewerCaptureParser.parse</c>. <paramref name="uiDumpJson"/> is kept
    /// as opaque bytes and never parsed.</summary>
    /// <exception cref="UIDumpCaptureException">invalidPNG, unreadableTree or invalidTree.</exception>
    public static ViewerCapture Parse(byte[] screenshotPng, byte[] uiTreeJson, byte[]? uiDumpJson, ViewerCaptureIdentity? identity = null)
    {
        ArgumentNullException.ThrowIfNull(screenshotPng);
        ArgumentNullException.ThrowIfNull(uiTreeJson);
        var (width, height) = PngDimensions(screenshotPng);
        if (FoundationJson.Parse(uiTreeJson) is not Dictionary<string, object> document)
        {
            throw new UIDumpCaptureException(UIDumpCaptureErrorKind.UnreadableTree);
        }
        var (componentRoots, documentBounds) = ComponentRoots(document);
        var provisional = new List<Provisional>();
        for (var index = 0; index < componentRoots.Count; index++)
        {
            AppendNode(componentRoots[index], [index], null, provisional);
        }

        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var item in provisional)
        {
            if (item.SourceId is { } id) counts[id] = counts.GetValueOrDefault(id) + 1;
        }
        var identities = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var item in provisional)
        {
            var pathText = PathKey(item.Path);
            identities[pathText] = item.SourceId is { } id && counts[id] == 1 ? "device:" + id : "path:" + pathText;
        }
        var nodes = provisional.Select(item => item.Node with
        {
            Identity = identities[PathKey(item.Path)],
            ParentIdentity = item.ParentPath is null ? null : identities.GetValueOrDefault(PathKey(item.ParentPath)),
            Children = item.ChildPaths.Select(p => identities.GetValueOrDefault(PathKey(p))).OfType<string>().ToList(),
        }).ToList();
        var roots = nodes.Where(n => n.ParentIdentity is null).Select(n => n.Identity).ToList();
        if (nodes.Count == 0 || roots.Count == 0) throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidTree);

        // Swift's `Int(_: Double)` truncates toward zero.
        bool Covers(ViewerBounds b) => b.X == 0 && b.Y == 0 && Math.Truncate(b.Width) == width && Math.Truncate(b.Height) == height;
        var verified = documentBounds is not null
            ? Covers(documentBounds)
            : nodes.Any(n => n.ParentIdentity is null && n.Bounds is { } b && Covers(b));

        var draft = new ViewerCapture(screenshotPng, width, height, roots, nodes, uiDumpJson, identity, verified);
        var final = nodes.Select(n => n with { VisibleBounds = VisibleBounds(n, draft) }).ToList();
        return new ViewerCapture(screenshotPng, width, height, roots, final, uiDumpJson, identity, verified);
    }

    private sealed record Provisional(int[] Path, int[]? ParentPath, IReadOnlyList<int[]> ChildPaths, string? SourceId, ViewerNode Node);

    private static string PathKey(int[] path) => string.Join('.', path.Select(i => i.ToString(CultureInfo.InvariantCulture)));

    private static Dictionary<string, object> AttributesOf(Dictionary<string, object> obj) =>
        obj.TryGetValue("attributes", out var a) && a is Dictionary<string, object> attributes ? attributes : obj;

    private static object? Get(Dictionary<string, object> obj, string key) => obj.GetValueOrDefault(key);

    /// <summary>Swift <c>as? [[String: Any]]</c>.</summary>
    private static List<Dictionary<string, object>>? Objects(object? value)
    {
        if (value is not List<object> items) return null;
        var result = new List<Dictionary<string, object>>(items.Count);
        foreach (var item in items)
        {
            if (item is not Dictionary<string, object> o) return null;
            result.Add(o);
        }
        return result;
    }

    /// <summary>Swift <c>componentRoots(of:)</c>: past the attribute-less document envelope to the
    /// real roots, keeping the envelope's bounds as the coordinate proof.</summary>
    private static (List<Dictionary<string, object>> Roots, ViewerBounds? Bounds) ComponentRoots(Dictionary<string, object> document)
    {
        var current = document;
        ViewerBounds? documentBounds = null;
        for (var step = 0; step < 8; step++)
        {
            var attributes = AttributesOf(current);
            if (StringOf(Get(attributes, "type")) is not null
                || StringOf(Get(attributes, "accessibilityId")) is not null
                || StringOf(Get(attributes, "id")) is not null
                || StringOf(Get(attributes, "nodeId")) is not null
                || StringOf(Get(attributes, "componentId")) is not null
                || Objects(Get(current, "children")) is not { Count: > 0 } children)
            {
                return ([current], documentBounds);
            }
            documentBounds ??= BoundsOf(Get(attributes, "bounds") ?? Get(current, "bounds"));
            if (children.Count > 1) return (children, documentBounds);
            current = children[0];
        }
        return ([current], documentBounds);
    }

    private static void AppendNode(Dictionary<string, object> obj, int[] path, int[]? parentPath, List<Provisional> items)
    {
        var attributes = AttributesOf(obj);
        var fields = new Dictionary<string, object>(obj, StringComparer.Ordinal);
        fields.Remove("children");
        List<Dictionary<string, object>> children;
        if (obj.TryGetValue("children", out var childValue))
        {
            children = Objects(childValue) ?? throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidTree);
        }
        else
        {
            children = [];
        }
        var childPaths = Enumerable.Range(0, children.Count).Select(i => (int[])[.. path, i]).ToList();
        var sourceId = StringOf(Get(attributes, "accessibilityId"))
                       ?? StringOf(Get(attributes, "id"))
                       ?? StringOf(Get(attributes, "nodeId"))
                       ?? StringOf(Get(attributes, "componentId"));
        var type = StringOf(Get(attributes, "type"))
                   ?? StringOf(Get(attributes, "componentType"))
                   ?? StringOf(Get(attributes, "class"))
                   ?? "Unknown";
        items.Add(new Provisional(path, parentPath, childPaths, sourceId, new ViewerNode
        {
            Identity = "",
            DeviceId = sourceId,
            ParentIdentity = null,
            Children = [],
            Type = type,
            Text = StringOf(Get(attributes, "text")),
            InspectorId = StringOf(Get(attributes, "inspectorId")),
            Bounds = BoundsOf(Get(attributes, "bounds") ?? Get(obj, "bounds")),
            VisibleBounds = null,
            Visible = BoolOf(Get(attributes, "visible")) ?? true,
            Enabled = BoolOf(Get(attributes, "enabled")),
            Clickable = BoolOf(Get(attributes, "clickable")),
            Focusable = BoolOf(Get(attributes, "focusable")),
            Focused = BoolOf(Get(attributes, "focused")),
            ClipsChildren = BoolOf(Get(attributes, "clip")) ?? false,
            HitTestBehavior = StringOf(Get(attributes, "hitTestBehavior")),
            ZIndex = NumberOf(Get(attributes, "zIndex") ?? Get(attributes, "zOrder")),
            HostWindowId = HostWindowId(fields),
            Depth = Math.Max(0, path.Length - 1),
            RawFields = FoundationJson.Write(fields, pretty: false, escapeSlashes: true),
            Fields = fields,
        }));
        for (var index = 0; index < children.Count; index++)
        {
            AppendNode(children[index], [.. path, index], path, items);
        }
    }

    private static (int Width, int Height) PngDimensions(byte[] bytes)
    {
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        ReadOnlySpan<byte> ihdr = [73, 72, 68, 82];
        if (bytes.Length < 24 || !bytes.AsSpan(0, 8).SequenceEqual(signature) || !bytes.AsSpan(12, 4).SequenceEqual(ihdr))
        {
            throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidPng);
        }
        long Read(int at) => ((long)bytes[at] << 24) | ((long)bytes[at + 1] << 16) | ((long)bytes[at + 2] << 8) | bytes[at + 3];
        var width = Read(16);
        var height = Read(20);
        if (width <= 0 || height <= 0 || width > int.MaxValue || height > int.MaxValue)
        {
            throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidPng);
        }
        return ((int)width, (int)height);
    }

    /// <summary>Swift <c>string(_:)</c>: a non-empty string, or an <c>NSNumber</c>'s
    /// <c>stringValue</c> (a boolean is <c>1</c>/<c>0</c>).</summary>
    private static string? StringOf(object? value) => value switch
    {
        string { Length: > 0 } s => s,
        bool b => b ? "1" : "0",
        FoundationJson.Number n => n.Text,
        _ => null,
    };

    /// <summary>Swift <c>bool(_:)</c>: a boolean (a number bridges when exactly 0 or 1), or the
    /// strings <c>true</c>/<c>false</c>.</summary>
    private static bool? BoolOf(object? value) => value switch
    {
        bool b => b,
        FoundationJson.Number { Value: 1 } => true,
        FoundationJson.Number { Value: 0 } => false,
        "true" => true,
        "false" => false,
        _ => null,
    };

    /// <summary>Swift <c>number(_:)</c>: a finite number, from a number, a boolean or a numeric
    /// string.</summary>
    private static double? NumberOf(object? value)
    {
        double? parsed = value switch
        {
            bool b => b ? 1 : 0,
            FoundationJson.Number n => n.Value,
            string s => SwiftDouble(s),
            _ => null,
        };
        return parsed is { } v && double.IsFinite(v) ? v : null;
    }

    /// <summary>Swift <c>Double(_: String)</c> over a decimal or exponent spelling.</summary>
    private static double? SwiftDouble(string text)
    {
        var body = text.StartsWith('+') || text.StartsWith('-') ? text[1..] : text;
        if (body.Length == 0 || !body.All(c => c is >= '0' and <= '9' or '.' or 'e' or 'E' or '+' or '-')) return null;
        return double.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent,
            CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    private static readonly Regex BoundsNumber = new(@"[-+]?(?:\d+(?:\.\d*)?|\.\d+)", RegexOptions.CultureInvariant);

    /// <summary>Swift <c>bounds(_:)</c>: an object of <c>x</c>/<c>left</c>, <c>y</c>/<c>top</c>
    /// and a size or a far corner, four numbers, or a <c>[l,t][r,b]</c> string.</summary>
    private static ViewerBounds? BoundsOf(object? value)
    {
        if (value is Dictionary<string, object> o)
        {
            var x = NumberOf(Get(o, "x") ?? Get(o, "left"));
            var y = NumberOf(Get(o, "y") ?? Get(o, "top"));
            if (x is { } bx && y is { } by)
            {
                if (NumberOf(Get(o, "width")) is { } w && NumberOf(Get(o, "height")) is { } h) return ViewerBounds.Create(bx, by, w, h);
                if (NumberOf(Get(o, "right")) is { } r && NumberOf(Get(o, "bottom")) is { } b) return ViewerBounds.Create(bx, by, r - bx, b - by);
            }
        }
        if (value is List<object> { Count: 4 } items
            && NumberOf(items[0]) is { } ax && NumberOf(items[1]) is { } ay && NumberOf(items[2]) is { } aw && NumberOf(items[3]) is { } ah)
        {
            return ViewerBounds.Create(ax, ay, aw, ah);
        }
        if (value is string text)
        {
            var values = BoundsNumber.Matches(text).Select(m => SwiftDouble(m.Value)).OfType<double>().ToList();
            if (values.Count == 4) return ViewerBounds.Create(values[0], values[1], values[2] - values[0], values[3] - values[1]);
        }
        return null;
    }

    // ---- ViewerScreenshotMapping ----

    /// <summary>Swift <c>visibleBounds(_:screenshotWidth:screenshotHeight:)</c>.</summary>
    private static ViewerBounds? OnScreen(ViewerBounds? bounds, int width, int height) =>
        width > 0 && height > 0 && bounds is not null && ViewerBounds.Create(0, 0, width, height) is { } viewport
            ? bounds.Intersection(viewport)
            : null;

    /// <summary>macOS <c>ViewerScreenshotMapping.visibleBounds(of:in:)</c>: the node's
    /// on-screen pixels left by every <c>clip=true</c> ancestor.</summary>
    public static ViewerBounds? VisibleBounds(ViewerNode node, ViewerCapture capture)
    {
        if (!capture.CoordinatesAreVerified) return null;
        var visible = OnScreen(node.Bounds, capture.ScreenshotWidth, capture.ScreenshotHeight);
        if (visible is null) return null;
        var visited = new HashSet<string>(StringComparer.Ordinal);
        var cursor = node.ParentIdentity;
        while (cursor is not null && visited.Add(cursor) && capture.NodeById(cursor) is { } ancestor)
        {
            if (ancestor.ClipsChildren)
            {
                var clip = OnScreen(ancestor.Bounds, capture.ScreenshotWidth, capture.ScreenshotHeight);
                visible = clip is null ? null : visible.Intersection(clip);
                if (visible is null) return null;
            }
            cursor = ancestor.ParentIdentity;
        }
        return visible;
    }

    // ---- ViewerHitTesting ----

    /// <summary>macOS <c>ViewerHitTesting.node(in:rootIdentity:x:y:)</c>: the front-most painted
    /// branch's deepest visible, hit-accepting node whose clipped bounds hold the point; null when
    /// the coordinates are unverified or nothing is there.</summary>
    public static string? HitTest(ViewerCapture capture, string? rootIdentity, double x, double y) =>
        HitTestNode(capture, rootIdentity, x, y)?.Identity;

    /// <summary>As <see cref="HitTest"/>, returning the node.</summary>
    public static ViewerNode? HitTestNode(ViewerCapture capture, string? rootIdentity, double x, double y)
    {
        ArgumentNullException.ThrowIfNull(capture);
        if (!capture.CoordinatesAreVerified) return null;
        var candidates = capture.SubtreeNodes(rootIdentity);
        var order = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var offset = 0; offset < candidates.Count; offset++) order.TryAdd(candidates[offset].Identity, offset);
        ViewerNode? best = null;
        foreach (var node in candidates)
        {
            if (!node.Visible || !node.AcceptsPointerHit || node.VisibleBounds is not { } bounds || !bounds.Contains(x, y)) continue;
            // `Sequence.max(by:)`: a later element replaces the best only when the best is behind it.
            if (best is null || IsPaintedBehind(best, node, capture, order)) best = node;
        }
        return best;
    }

    private static bool IsPaintedBehind(ViewerNode left, ViewerNode right, ViewerCapture capture, Dictionary<string, int> order)
    {
        int Stable(string identity) => order.GetValueOrDefault(identity);
        var leftPath = capture.Ancestors(left.Identity).Append(left.Identity).ToList();
        var rightPath = capture.Ancestors(right.Identity).Append(right.Identity).ToList();
        var shared = Math.Min(leftPath.Count, rightPath.Count);
        var divergence = 0;
        while (divergence < shared && leftPath[divergence] == rightPath[divergence]) divergence++;

        if (divergence < shared && capture.NodeById(leftPath[divergence]) is { } leftBranch && capture.NodeById(rightPath[divergence]) is { } rightBranch)
        {
            static double Z(double? value) => value is { } v && double.IsFinite(v) ? v : 0;
            var leftZ = Z(leftBranch.ZIndex);
            var rightZ = Z(rightBranch.ZIndex);
            if (leftZ != rightZ) return leftZ < rightZ;
            if (divergence > 0 && capture.NodeById(leftPath[divergence - 1]) is { } parent)
            {
                var leftIndex = IndexOf(parent.Children, leftBranch.Identity);
                var rightIndex = IndexOf(parent.Children, rightBranch.Identity);
                if (leftIndex >= 0 && rightIndex >= 0 && leftIndex != rightIndex) return leftIndex < rightIndex;
            }
            return Stable(leftBranch.Identity) < Stable(rightBranch.Identity);
        }
        // One is an ancestor of the other: the descendant is the more specific component.
        if (leftPath.Count != rightPath.Count) return leftPath.Count < rightPath.Count;
        return Stable(left.Identity) < Stable(right.Identity);
    }

    private static int IndexOf(IReadOnlyList<string> list, string value)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (list[i] == value) return i;
        }
        return -1;
    }

    // ---- search, outline rows, raw dump, window id ----

    private static string NormalizedQuery(string query) => query.Trim().ToLowerInvariant();

    /// <summary>macOS <c>searchMatches(rootIdentity:query:)</c>: nodes of the root's subtree whose
    /// "type text deviceID inspectorID" contains the trimmed, lower-cased query; ancestors are not
    /// matches.</summary>
    public static IReadOnlyList<string> Search(ViewerCapture capture, string? rootIdentity, string query) =>
        SearchNodes(capture, rootIdentity, query).Select(n => n.Identity).ToList();

    private static List<ViewerNode> SearchNodes(ViewerCapture capture, string? rootIdentity, string query)
    {
        var normalized = NormalizedQuery(query);
        if (normalized.Length == 0) return [];
        return capture.SubtreeNodes(rootIdentity).Where(node =>
            string.Join(' ', new[] { node.Type, node.Text, node.DeviceId, node.InspectorId }.OfType<string>())
                .ToLowerInvariant().Contains(normalized, StringComparison.Ordinal)).ToList();
    }

    /// <summary>macOS <c>visibleTreeNodes(rootIdentity:query:expandedNodeIdentities:)</c>: the
    /// outline rows. Without a query, each root and the children of expanded nodes; with one,
    /// every match and its ancestors, fully expanded.</summary>
    public static IReadOnlyList<ViewerNode> VisibleRows(ViewerCapture capture, string? rootIdentity, IReadOnlySet<string> expanded, string query)
    {
        ArgumentNullException.ThrowIfNull(capture);
        ArgumentNullException.ThrowIfNull(expanded);
        var normalized = NormalizedQuery(query);
        IReadOnlyList<string> roots = !string.IsNullOrEmpty(rootIdentity)
            ? capture.NodeById(rootIdentity) is null ? [] : [rootIdentity]
            : capture.Roots;
        var included = new HashSet<string>(StringComparer.Ordinal);
        if (normalized.Length > 0)
        {
            var matches = SearchNodes(capture, rootIdentity, normalized);
            if (matches.Count == 0) return [];
            foreach (var match in matches)
            {
                included.Add(match.Identity);
                var visitedUp = new HashSet<string>(StringComparer.Ordinal);
                var cursor = match.ParentIdentity;
                while (cursor is not null && visitedUp.Add(cursor) && capture.NodeById(cursor) is { } node)
                {
                    included.Add(cursor);
                    cursor = node.ParentIdentity;
                }
            }
        }
        var rows = new List<ViewerNode>();
        var visited = new HashSet<string>(StringComparer.Ordinal);
        var stack = new Stack<string>(roots.Reverse());
        // An explicit stack in visit order, so a deep provider tree cannot exhaust the thread's stack.
        while (stack.Count > 0)
        {
            var identity = stack.Pop();
            if (!visited.Add(identity) || capture.NodeById(identity) is not { } node || (normalized.Length > 0 && !included.Contains(identity))) continue;
            rows.Add(node);
            if (normalized.Length > 0 || expanded.Contains(identity))
            {
                for (var i = node.Children.Count - 1; i >= 0; i--) stack.Push(node.Children[i]);
            }
        }
        return rows;
    }

    /// <summary>macOS <c>formattedRawFields(for:)</c>: the node's own fields without
    /// <c>children</c>, pretty-printed and key-sorted as <c>JSONSerialization</c> writes them.</summary>
    public static string RawDump(ViewerNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        return FoundationJson.Write(node.Fields, pretty: true, escapeSlashes: true);
    }

    /// <summary>The nearest decimal <c>hostWindowId</c> walking up from the node (its
    /// <c>attributes</c>, else the object itself), as a number; null when none is found or it
    /// does not fit.</summary>
    public static long? WindowIdFor(ViewerCapture capture, string identity) =>
        HostWindowFor(capture, identity) is { } text && long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var id) ? id : null;

    /// <summary>macOS <c>advancedDumpSelection(for:)</c>: the node's decimal device id and its
    /// nearest enclosing host window, or null.</summary>
    public static ViewerAdvancedDumpSelection? AdvancedDumpSelectionFor(ViewerCapture capture, string identity)
    {
        ArgumentNullException.ThrowIfNull(capture);
        if (capture.NodeById(identity) is not { } node || DecimalIdentifier(node.DeviceId) is not { } component) return null;
        return HostWindowFor(capture, identity) is { } window ? new ViewerAdvancedDumpSelection(window, component) : null;
    }

    private static string? HostWindowFor(ViewerCapture capture, string identity)
    {
        var visited = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = identity;
        while (cursor is not null && visited.Add(cursor) && capture.NodeById(cursor) is { } candidate)
        {
            if (candidate.HostWindowId is { } window) return window;
            cursor = candidate.ParentIdentity;
        }
        return null;
    }

    private static string? HostWindowId(Dictionary<string, object> document)
    {
        var fields = AttributesOf(document);
        return Get(fields, "hostWindowId") switch
        {
            string s => DecimalIdentifier(s),
            bool b => DecimalIdentifier(b ? "1" : "0"),
            FoundationJson.Number n => DecimalIdentifier(n.Text),
            _ => null,
        };
    }

    private static string? DecimalIdentifier(string? value) =>
        value is { Length: > 0 and <= 20 } && value.All(c => c is >= '0' and <= '9') ? value : null;

    // ---- ViewerAdvancedDumpParser ----

    /// <summary>macOS <c>ViewerAdvancedDumpParser.parse</c> over UTF-8 bytes.</summary>
    /// <exception cref="UIDumpCaptureException">invalidAdvancedDump or advancedDumpRequiresSidecar.</exception>
    public static IReadOnlyList<ViewerDumpField> ParseAdvancedDump(byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        if (data.Length == 0) throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidAdvancedDump);
        string text;
        try
        {
            text = new UTF8Encoding(false, true).GetString(data);
        }
        catch (DecoderFallbackException)
        {
            throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidAdvancedDump);
        }
        return ParseAdvancedDumpText(text, data);
    }

    /// <summary>macOS <c>ViewerAdvancedDumpParser.parse</c>: a JSON object gives its fields in
    /// key order; otherwise every <c>key: value</c> line; a mention of <c>arkui-comp.dump</c> or
    /// <c>arkui.dump</c> with no fields is a remote-sidecar refusal.</summary>
    /// <exception cref="UIDumpCaptureException">invalidAdvancedDump or advancedDumpRequiresSidecar.</exception>
    public static IReadOnlyList<ViewerDumpField> ParseAdvancedDump(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (text.Length == 0) throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidAdvancedDump);
        return ParseAdvancedDumpText(text, Encoding.UTF8.GetBytes(text));
    }

    private static List<ViewerDumpField> ParseAdvancedDumpText(string text, byte[] data)
    {
        if (FoundationJson.Parse(data) is Dictionary<string, object> obj)
        {
            var jsonFields = obj.Keys.Order(SwiftText.Order)
                .Select(key => new ViewerDumpField(key, FieldValue(obj[key]))).ToList();
            if (jsonFields.Count > 0) return jsonFields;
        }

        var fields = new List<ViewerDumpField>();
        char[] newlines = ['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];
        foreach (var rawLine in text.Split(newlines, StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            var separator = line.IndexOf(':');
            if (separator < 0) continue;
            var key = line[..separator].Trim().Trim("|`+-=>[]{} ".ToCharArray());
            var value = line[(separator + 1)..].Trim();
            if (key.Length == 0) continue;
            fields.Add(new ViewerDumpField(key, value));
        }
        if (fields.Count == 0)
        {
            var normalized = text.ToLowerInvariant();
            if (normalized.Contains("arkui-comp.dump", StringComparison.Ordinal) || normalized.Contains("arkui.dump", StringComparison.Ordinal))
            {
                throw new UIDumpCaptureException(UIDumpCaptureErrorKind.AdvancedDumpRequiresSidecar);
            }
            throw new UIDumpCaptureException(UIDumpCaptureErrorKind.InvalidAdvancedDump);
        }
        return fields;
    }

    private static string FieldValue(object value) => value switch
    {
        FoundationJson.Null => "null",
        string s => s,
        bool b => b ? "1" : "0",
        FoundationJson.Number n => n.Text,
        _ => FoundationJson.Write(value, pretty: false, escapeSlashes: false),
    };

    // ---- the CLI's derivation (RuntimeCLI.emitUIDumpDerivation over UIDumpOfflineInspector) ----

    /// <summary>Chooses the capture's Artifacts from the Job's inventory as the CLI does: the
    /// one published, sensitive <c>ui-tree.json</c> and <c>screenshot.png</c>, and an optional
    /// <c>ui-dump.json</c>, each with valid metadata, within the bounded size.</summary>
    /// <exception cref="UIDumpDerivationException">resourceNotFound or recordUnreadable.</exception>
    public static UIDumpSelection SelectArtifacts(string jobId, IReadOnlyList<UIDumpArtifactEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        if (entries.Count == 0)
        {
            throw new UIDumpDerivationException("resourceNotFound",
                $"job {jobId} has published no artifacts; check the job identity and that it reached a terminal state", jobId);
        }
        var treeRow = Entry(entries, TreeName, TreeMediaType, jobId)
                      ?? throw new UIDumpDerivationException("resourceNotFound", $"job {jobId} published no `{TreeName}`, so it is not a UI dump capture", jobId);
        var screenshotRow = Entry(entries, ScreenshotName, ScreenshotMediaType, jobId)
                            ?? throw new UIDumpDerivationException("resourceNotFound", $"job {jobId} published no screenshot to derive against", jobId);
        var rawRow = Entry(entries, RawDumpName, RawDumpMediaType, jobId);
        var tree = SourceOf(treeRow, jobId);
        var screenshot = SourceOf(screenshotRow, jobId);
        var raw = rawRow is null ? null : SourceOf(rawRow, jobId);
        long total = 0;
        foreach (var item in new[] { tree, screenshot, raw }.OfType<UIDumpSource>())
        {
            total += item.ByteCount;
            if (total > MaximumCaptureBytes)
            {
                throw new UIDumpDerivationException("recordUnreadable", $"job {jobId} UI dump exceeds the bounded offline inspection size");
            }
        }
        return new UIDumpSelection(jobId, tree, screenshot, raw, screenshotRow.ObservedFromUtc, screenshotRow.ObservedToUtc);
    }

    private static UIDumpArtifactEntry? Entry(IReadOnlyList<UIDumpArtifactEntry> entries, string name, string mediaType, string jobId)
    {
        var matches = entries.Where(e => e.Name == name).ToList();
        if (matches.Count > 1) throw new UIDumpDerivationException("recordUnreadable", $"job {jobId} published duplicate `{name}` Artifacts");
        if (matches.Count == 0) return null;
        var row = matches[0];
        if (row.Status != "published" || row.MediaType != mediaType || row.Privacy != "sensitive")
        {
            throw new UIDumpDerivationException("recordUnreadable", $"job {jobId} published `{name}` with invalid status, media type, or privacy");
        }
        return row;
    }

    /// <summary>macOS <c>UIDumpOfflineSource.init</c>.</summary>
    private static UIDumpSource SourceOf(UIDumpArtifactEntry row, string jobId)
    {
        if (row is not { ArtifactId: { } id, Name: { } name, MediaType: { } mediaType, Sha256: { } sha256, ByteCount: { } byteCount })
        {
            throw new UIDumpDerivationException("recordUnreadable", $"job {jobId} published an artifact this build cannot read");
        }
        var valid = id.Length > 0 && Encoding.UTF8.GetByteCount(id) <= 512
                    && !id.Any(c => char.GetUnicodeCategory(c) is UnicodeCategory.Control or UnicodeCategory.Format)
                    && name.Length > 0 && Encoding.UTF8.GetByteCount(name) <= 256
                    && mediaType.Length > 0 && Encoding.UTF8.GetByteCount(mediaType) <= 256
                    && sha256.Length == 64 && sha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')
                    && byteCount >= 0;
        if (!valid) throw new UIDumpDerivationException("recordUnreadable", $"job {jobId} published invalid metadata for `{name}`");
        return new UIDumpSource(id, name, mediaType, sha256, byteCount);
    }

    /// <summary>macOS <c>UIDumpOfflineInspector.inspect</c> as the CLI runs it: binds each
    /// Artifact's bytes to its metadata (screenshot, tree, then raw dump), refuses a repeated
    /// Artifact id, then parses.</summary>
    /// <exception cref="UIDumpDerivationException">artifactIntegrityFailed or recordUnreadable
    /// (<c>the capture artifacts did not parse: invalidPNG</c> and the like).</exception>
    public static UIDumpInspection Derive(UIDumpSelection selection, byte[] screenshotPng, byte[] uiTreeJson, byte[]? uiDumpJson, ViewerCaptureIdentity? identity = null)
    {
        ArgumentNullException.ThrowIfNull(selection);
        ArgumentNullException.ThrowIfNull(screenshotPng);
        ArgumentNullException.ThrowIfNull(uiTreeJson);
        var job = selection.JobId;
        foreach (var (source, bytes) in new (UIDumpSource? Source, byte[]? Bytes)[]
                 {
                     (selection.Screenshot, screenshotPng), (selection.Tree, uiTreeJson), (selection.RawDump, uiDumpJson),
                 })
        {
            if (source is null) continue;
            var data = bytes ?? [];
            if (source.ByteCount != data.Length)
            {
                throw new UIDumpDerivationException("artifactIntegrityFailed", $"artifact `{source.Name}` byte count does not match its Runtime metadata", job);
            }
            if (Convert.ToHexStringLower(SHA256.HashData(data)) != source.Sha256)
            {
                throw new UIDumpDerivationException("artifactIntegrityFailed", $"artifact `{source.Name}` SHA-256 does not match its Runtime metadata", job);
            }
        }
        var sources = new List<UIDumpSource> { selection.Screenshot, selection.Tree };
        if (selection.RawDump is { } rawDump) sources.Add(rawDump);
        if (sources.Select(s => s.ArtifactId).Distinct(StringComparer.Ordinal).Count() != sources.Count)
        {
            throw new UIDumpDerivationException("recordUnreadable", "the capture artifacts did not parse: invalidSource(\"duplicateArtifactId\")", job);
        }
        ViewerCapture capture;
        try
        {
            capture = Parse(screenshotPng, uiTreeJson, selection.RawDump is null ? null : uiDumpJson, identity);
        }
        catch (UIDumpCaptureException failure)
        {
            throw new UIDumpDerivationException("recordUnreadable", "the capture artifacts did not parse: " + failure.Code, job);
        }
        var sorted = sources
            .OrderBy(s => s.Name, StringComparer.Ordinal)
            .ThenBy(s => s.ArtifactId, StringComparer.Ordinal)
            .ToList();
        var provenance = new UIDumpProvenance("offlineDerived", ParserId, ParserVersion, selection.ObservedFromUtc, selection.ObservedToUtc, sorted);
        return new UIDumpInspection(InspectionSchemaVersion, job, provenance, capture);
    }

    /// <summary>The CLI's <c>ui-dump hit-test</c> over a derivation.</summary>
    /// <exception cref="UIDumpDerivationException">factsDrifted when the capture's coordinates
    /// were never verified.</exception>
    public static UIDumpHitTest DeriveHitTest(UIDumpInspection inspection, double x, double y, string? rootIdentity = null)
    {
        ArgumentNullException.ThrowIfNull(inspection);
        if (!inspection.Capture.CoordinatesAreVerified)
        {
            throw new UIDumpDerivationException("factsDrifted",
                "this capture's coordinate mapping was never verified, so a point cannot be resolved to a node",
                inspection.JobId);
        }
        return new UIDumpHitTest(HitTestSchemaVersion, inspection.Provenance, x, y, HitTestNode(inspection.Capture, rootIdentity, x, y));
    }
}

/// <summary>Foundation <c>JSONSerialization</c> as the Viewer uses it: a parse that keeps
/// integers apart from doubles and bridges scalars as <c>NSNumber</c> does, and a writer with
/// <c>.sortedKeys</c>, optional <c>.prettyPrinted</c> and optional slash escaping.</summary>
internal static class FoundationJson
{
    /// <summary><c>NSNull</c>.</summary>
    public sealed class Null
    {
        public static readonly Null Instance = new();

        private Null() { }
    }

    /// <summary>A JSON number: its binary64 value and <c>NSNumber.stringValue</c>.</summary>
    public sealed record Number(double Value, bool IsInteger, string Text);

    /// <summary>Objects are <c>Dictionary&lt;string, object&gt;</c> (a repeated key: the last
    /// wins), arrays <c>List&lt;object&gt;</c>; null when the bytes are not JSON.</summary>
    public static object? Parse(byte[] utf8)
    {
        try
        {
            using var document = JsonDocument.Parse(utf8, new JsonDocumentOptions { MaxDepth = 512 });
            return Convert(document.RootElement);
        }
        catch (JsonException)
        {
            return null;
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static object Convert(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var obj = new Dictionary<string, object>(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject()) obj[property.Name] = Convert(property.Value);
                return obj;
            case JsonValueKind.Array:
                return element.EnumerateArray().Select(Convert).ToList();
            case JsonValueKind.String:
                return element.GetString() ?? "";
            case JsonValueKind.True:
                return true;
            case JsonValueKind.False:
                return false;
            case JsonValueKind.Number:
                var raw = element.GetRawText();
                if (raw.IndexOfAny(['.', 'e', 'E']) < 0 && long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var integer))
                {
                    return new Number(integer, true, integer.ToString(CultureInfo.InvariantCulture));
                }
                var value = element.GetDouble();
                return new Number(value, false, DoubleText(value));
            default:
                return Null.Instance;
        }
    }

    /// <summary>Foundation's spelling of a <c>Double</c>: shortest round-trip digits, integral
    /// values without a fraction, exponential below 1e-4 and above 2^53.</summary>
    public static string DoubleText(double value)
    {
        if (!double.IsFinite(value)) return value.ToString(CultureInfo.InvariantCulture);
        var negative = double.IsNegative(value);
        var shortest = Math.Abs(value).ToString("R", CultureInfo.InvariantCulture);
        // Digits and decimal exponent of the shortest round-trip spelling.
        var exponentAt = shortest.IndexOfAny(['E', 'e']);
        var mantissa = exponentAt < 0 ? shortest : shortest[..exponentAt];
        var exponent = exponentAt < 0 ? 0 : int.Parse(shortest[(exponentAt + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        var point = mantissa.IndexOf('.');
        var integerDigits = point < 0 ? mantissa.Length : point;
        var digits = mantissa.Replace(".", "", StringComparison.Ordinal);
        var leading = digits.Length - digits.TrimStart('0').Length;
        digits = digits[leading..].TrimEnd('0');
        if (digits.Length == 0) return negative ? "-0" : "0";
        var power = exponent + integerDigits - leading - 1;
        var sign = negative ? "-" : "";
        if (power < -4 || Math.Abs(value) > 9_007_199_254_740_992.0)
        {
            var tail = digits.Length > 1 ? "." + digits[1..] : "";
            return $"{sign}{digits[0]}{tail}e{(power < 0 ? "-" : "+")}{Math.Abs(power):00}";
        }
        var at = power + 1;
        string body;
        if (at <= 0) body = "0." + new string('0', -at) + digits;
        else if (at >= digits.Length) body = digits + new string('0', at - digits.Length);
        else body = digits[..at] + "." + digits[at..];
        return sign + body;
    }

    /// <summary><c>JSONSerialization.data(withJSONObject:options:)</c> with <c>.sortedKeys</c>.</summary>
    public static string Write(object value, bool pretty, bool escapeSlashes)
    {
        var output = new StringBuilder();
        WriteValue(output, value, pretty, escapeSlashes, 0);
        return output.ToString();
    }

    private static void WriteValue(StringBuilder output, object value, bool pretty, bool escapeSlashes, int level)
    {
        switch (value)
        {
            case IReadOnlyDictionary<string, object> obj:
                WriteContainer(output, '{', '}', obj.Keys.Order(StringComparer.Ordinal).ToList(), pretty, level, (key, next) =>
                {
                    WriteString(output, key, escapeSlashes);
                    output.Append(pretty ? " : " : ":");
                    WriteValue(output, obj[key], pretty, escapeSlashes, next);
                });
                break;
            case List<object> items:
                WriteContainer(output, '[', ']', items, pretty, level, (item, next) => WriteValue(output, item, pretty, escapeSlashes, next));
                break;
            case string s:
                WriteString(output, s, escapeSlashes);
                break;
            case bool b:
                output.Append(b ? "true" : "false");
                break;
            case Number n:
                output.Append(n.Text);
                break;
            default:
                output.Append("null");
                break;
        }
    }

    private static void WriteContainer<T>(StringBuilder output, char open, char close, IReadOnlyList<T> items, bool pretty, int level, Action<T, int> write)
    {
        output.Append(open);
        if (pretty)
        {
            output.Append('\n');
            for (var i = 0; i < items.Count; i++)
            {
                output.Append(' ', (level + 1) * 2);
                write(items[i], level + 1);
                if (i < items.Count - 1) output.Append(',');
                output.Append('\n');
            }
            if (items.Count == 0) output.Append('\n');
            output.Append(' ', level * 2);
        }
        else
        {
            for (var i = 0; i < items.Count; i++)
            {
                if (i > 0) output.Append(',');
                write(items[i], level + 1);
            }
        }
        output.Append(close);
    }

    private static void WriteString(StringBuilder output, string text, bool escapeSlashes)
    {
        output.Append('"');
        foreach (var c in text)
        {
            switch (c)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '/' when escapeSlashes: output.Append("\\/"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                case < ' ': output.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); break;
                default: output.Append(c); break;
            }
        }
        output.Append('"');
    }
}
