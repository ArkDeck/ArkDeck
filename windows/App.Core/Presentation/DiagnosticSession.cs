using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

// The Diagnostics workspace's offline half, as macOS reads it (ArkDeckClientKit:
// DiagnosticSessionOfflineInspector, DiagnosticSessionReading, DiagnosticReaderSelection,
// DiagnosticArtifactTextPreview, DiagnosticSessionApplicationReader and
// DiagnosticHilogSummaryReader; ArkDeckCore: HilogSummaryArtifactContract). Everything here is
// pure and transport-free: the Runtime owns the metadata and the bytes, the page hands them in,
// and nothing here reaches a device, writes anything or grants authority. The Swift oracle
// rust/tests/fixtures/diagnostics-inspect is replayed against it by DiagnosticSessionTests.

/// <summary>Which of the offline inspector's checks refused (Swift
/// <c>DiagnosticSessionOfflineInspectorError</c>).</summary>
public enum DiagnosticSessionFailure
{
    Invalid,
    ByteCountMismatch,
    DigestMismatch,
    ContentTooLarge,
    SensitiveContentRequiresExplicitAccess,
}

/// <summary>A refusal of the offline inspector, carrying the Swift reason code
/// (<c>DiagnosticSessionOfflineInspectorError.reason</c>).</summary>
public sealed class DiagnosticSessionException : Exception
{
    public DiagnosticSessionException(DiagnosticSessionFailure failure, string reason, string? artifactName = null, long? maximumBytes = null)
        : base(reason)
    {
        Failure = failure;
        Reason = reason;
        ArtifactName = artifactName;
        MaximumBytes = maximumBytes;
    }

    public DiagnosticSessionFailure Failure { get; }

    /// <summary>The machine reason (<c>diagnostics_*</c>).</summary>
    public string Reason { get; }

    /// <summary>The Artifact a byte-count or digest mismatch names.</summary>
    public string? ArtifactName { get; }

    /// <summary>The bound a too-large preview exceeded.</summary>
    public long? MaximumBytes { get; }

    internal static DiagnosticSessionException Invalid(string reason) => new(DiagnosticSessionFailure.Invalid, reason);
}

/// <summary>Immutable Runtime metadata accepted by the offline parser (Swift
/// <c>DiagnosticOfflineArtifactMetadata</c>). Missing products carry no digest; published products
/// always do.</summary>
public sealed record DiagnosticArtifactMetadata
{
    private DiagnosticArtifactMetadata(string artifactId, string name, string mediaType, string privacy, string status,
        string? statusDetail, string sourceOperation, long byteCount, string? sha256)
    {
        ArtifactId = artifactId;
        Name = name;
        MediaType = mediaType;
        Privacy = privacy;
        Status = status;
        StatusDetail = statusDetail;
        SourceOperation = sourceOperation;
        ByteCount = byteCount;
        Sha256 = sha256;
    }

    public string ArtifactId { get; }
    public string Name { get; }
    public string MediaType { get; }
    public string Privacy { get; }
    public string Status { get; }
    public string? StatusDetail { get; }
    public string SourceOperation { get; }
    public long ByteCount { get; }
    public string? Sha256 { get; }

    /// <exception cref="DiagnosticSessionException"><c>diagnostics_invalid_artifact_metadata</c>.</exception>
    public static DiagnosticArtifactMetadata Create(string artifactId, string name, string mediaType, string privacy, string status,
        string? statusDetail, string sourceOperation, long byteCount, string? sha256)
    {
        var valid = artifactId.Length > 0 && Utf8Length(artifactId) <= 512 && !HasControlCharacter(artifactId)
            && name.Length > 0 && Utf8Length(name) <= 1_024
            && mediaType.Length > 0 && Utf8Length(mediaType) <= 256
            && privacy is "standard" or "sensitive"
            && status is "published" or "missing" or "truncated"
            && sourceOperation.Length > 0 && Utf8Length(sourceOperation) <= 256
            && byteCount >= 0 && byteCount <= DiagnosticSessionOfflineInspector.MaximumSafeInteger
            && (statusDetail is null || Utf8Length(statusDetail) <= 4_096)
            && (status == "published" ? sha256 is not null && DiagnosticDigest.IsLowercaseSha256(sha256) : sha256 is null);
        if (!valid) throw DiagnosticSessionException.Invalid("diagnostics_invalid_artifact_metadata");
        return new(artifactId, name, mediaType, privacy, status, statusDetail, sourceOperation, byteCount, sha256);
    }

    internal static int Utf8Length(string value) => Encoding.UTF8.GetByteCount(value);

    // Foundation's CharacterSet.controlCharacters: general categories Cc and Cf.
    private static bool HasControlCharacter(string value)
    {
        foreach (var rune in value.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.Control or UnicodeCategory.Format) return true;
        }
        return false;
    }
}

/// <summary>Metadata-bound bytes (Swift <c>DiagnosticOfflineArtifact</c>): binding fails before
/// any parser sees the content.</summary>
public sealed class DiagnosticOfflineArtifact
{
    private readonly byte[] _bytes;

    private DiagnosticOfflineArtifact(DiagnosticArtifactMetadata metadata, byte[] bytes)
    {
        Metadata = metadata;
        _bytes = bytes;
    }

    public DiagnosticArtifactMetadata Metadata { get; }

    public ReadOnlyMemory<byte> Bytes => _bytes;

    /// <exception cref="DiagnosticSessionException">A byte count or digest that is not the
    /// metadata's.</exception>
    public static DiagnosticOfflineArtifact Bind(DiagnosticArtifactMetadata metadata, ReadOnlySpan<byte> bytes)
    {
        if (metadata.Status != "published" || metadata.ByteCount != bytes.Length)
        {
            throw new DiagnosticSessionException(DiagnosticSessionFailure.ByteCountMismatch, "diagnostics_artifact_byte_count_mismatch", metadata.Name);
        }
        if (metadata.Sha256 != DiagnosticDigest.Sha256(bytes))
        {
            throw new DiagnosticSessionException(DiagnosticSessionFailure.DigestMismatch, "diagnostics_artifact_integrity_mismatch", metadata.Name);
        }
        return new(metadata, bytes.ToArray());
    }
}

/// <summary>What the inspector reads: one Job's identity and typed capture inputs, its whole
/// Artifact inventory, and the bound bytes of the documents it parses, by name.</summary>
public sealed record DiagnosticSessionOfflineInput(
    string JobId,
    string OperationReference,
    JsonObject? TypedParameters,
    IReadOnlyList<DiagnosticArtifactMetadata> Inventory,
    IReadOnlyDictionary<string, DiagnosticOfflineArtifact> Documents);

/// <summary>Every derived answer says it is <c>offlineDerived</c> and names the parser and the
/// Artifacts it read, so it is never taken for new device evidence.</summary>
public sealed record DiagnosticSessionProvenance(string Kind, string Parser, string ParserVersion, IReadOnlyList<DiagnosticArtifactMetadata> Sources);

/// <summary>Swift <c>DiagnosticSessionOfflineInspection</c>.</summary>
public sealed record DiagnosticSessionInspection(
    string SchemaVersion,
    string JobId,
    string OperationReference,
    DiagnosticSessionProvenance Provenance,
    DiagnosticSessionReading Reading,
    bool? RingHeldAnchor,
    IReadOnlyList<DiagnosticArtifactMetadata> Inventory)
{
    public const string CurrentSchemaVersion = "arkdeck.diagnostics-inspection/1";
}

/// <summary>Swift <c>DiagnosticArtifactOfflinePreview</c>.</summary>
public sealed record DiagnosticArtifactOfflinePreview(
    string SchemaVersion,
    DiagnosticSessionProvenance Provenance,
    string Text,
    bool ReplacedInvalidUtf8,
    bool WasClipped)
{
    public const string CurrentSchemaVersion = "arkdeck.diagnostics-preview/1";
}

/// <summary>
/// Display-only decoding after Artifact integrity has been checked (Swift
/// <c>DiagnosticArtifactTextPreview</c>). Real HiLog buffers can contain invalid UTF-8; replacing
/// those sequences is disclosed, and never repairs structured evidence or stored bytes. JSON must
/// be strict UTF-8. Clipping counts characters as Swift does (extended grapheme clusters).
/// </summary>
public sealed record DiagnosticArtifactTextPreview(string Text, bool ReplacedInvalidUtf8, bool WasClipped)
{
    public const int MaximumBytes = 2 * 1_024 * 1_024;
    public const int MaximumCharacters = 120_000;

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly UTF8Encoding LossyUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false);

    /// <summary>The preview, or null when the bytes are too many, the bound is out of range, the
    /// media type is not text, or JSON is not valid UTF-8.</summary>
    public static DiagnosticArtifactTextPreview? Create(ReadOnlySpan<byte> bytes, string mediaType, int maximumCharacters = MaximumCharacters)
    {
        if (bytes.Length > MaximumBytes || maximumCharacters is < 1 or > MaximumCharacters
            || mediaType is not ("text/plain" or "application/json"))
        {
            return null;
        }
        string? strict;
        try
        {
            strict = StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            strict = null;
        }
        if (strict is null && mediaType != "text/plain") return null;
        var decoded = strict ?? LossyUtf8.GetString(bytes);

        var position = 0;
        var characters = 0;
        while (position < decoded.Length && characters < maximumCharacters)
        {
            position += StringInfo.GetNextTextElementLength(decoded.AsSpan(position));
            characters++;
        }
        return new(decoded[..position], strict is null, position < decoded.Length);
    }
}

/// <summary>
/// The App and CLI share this deterministic, device-free parser (Swift
/// <c>DiagnosticSessionOfflineInspector</c>). It owns the accepted document roles, bounds,
/// integrity checks and output versions.
/// </summary>
public static class DiagnosticSessionOfflineInspector
{
    public const string ParserId = "arkdeck.diagnostics-session-parser";
    public const string ParserVersion = "1.0.0";
    public const string OperationReference = "capture.diagnostics@1";
    public const string IndexArtifactName = "artifact-index.json";
    public const string SummaryArtifactName = "capture-summary.json";
    public const string MarkersArtifactName = "markers.json";
    public const int InventoryMaximumCount = 64_000;
    public const long MaximumSafeInteger = 9_007_199_254_740_991;
    public const int DocumentMaximumBytes = 1 * 1_024 * 1_024;
    public const int PreviewMaximumBytes = 2 * 1_024 * 1_024;
    public const int PreviewMaximumCharacters = 120_000;

    private static readonly string[] Statuses = ["published", "missing", "truncated"];

    /// <summary>Reads one capture's published documents into the reading the session can be
    /// shown to say.</summary>
    /// <exception cref="DiagnosticSessionException">The Swift reason the inspector refused
    /// with.</exception>
    public static DiagnosticSessionInspection Inspect(DiagnosticSessionOfflineInput input)
    {
        if (input.OperationReference != OperationReference || input.JobId.Length == 0 || DiagnosticArtifactMetadata.Utf8Length(input.JobId) > 512)
        {
            throw DiagnosticSessionException.Invalid("diagnostics_unsupported_operation");
        }
        var inventory = input.Inventory;
        if (inventory.Select(m => m.ArtifactId).Distinct(StringComparer.Ordinal).Count() != inventory.Count
            || inventory.Select(m => m.Name).Distinct(StringComparer.Ordinal).Count() != inventory.Count
            || inventory.Count > InventoryMaximumCount
            || !inventory.All(m => m.SourceOperation == input.OperationReference))
        {
            throw DiagnosticSessionException.Invalid("diagnostics_ambiguous_artifact_inventory");
        }
        string[] accepted = [IndexArtifactName, SummaryArtifactName, MarkersArtifactName];
        if (!input.Documents.Keys.All(accepted.Contains)
            || !input.Documents.All(d => d.Key == d.Value.Metadata.Name && inventory.Contains(d.Value.Metadata)))
        {
            throw DiagnosticSessionException.Invalid("diagnostics_unexpected_session_document");
        }

        var index = DecodeIndex(Document(IndexArtifactName, input).Bytes.Span);
        var summary = DecodeIndex(Document(SummaryArtifactName, input).Bytes.Span);
        var missingRequired = summary.MissingRequired;
        var requiredNotPublished = summary.Artifacts.Where(a => a.Value.Required && a.Value.Status != "published").Select(a => a.Key).ToHashSet(StringComparer.Ordinal);
        if (index.JobId != input.JobId || summary.JobId != input.JobId
            || index.Operation != input.OperationReference || summary.Operation != input.OperationReference
            || !SameProducts(index.Artifacts, summary.Artifacts)
            || missingRequired is null
            || missingRequired.Distinct(StringComparer.Ordinal).Count() != missingRequired.Count
            || !requiredNotPublished.SetEquals(missingRequired)
            || summary.Completeness != (missingRequired.Count == 0 ? "complete" : "incomplete"))
        {
            throw DiagnosticSessionException.Invalid("diagnostics_index_summary_mismatch");
        }

        bool IsPublished(string name) => inventory.Any(m => m.Name == name && m.Status == "published");

        foreach (var (name, item) in index.Artifacts)
        {
            if (!Statuses.Contains(item.Status)) throw DiagnosticSessionException.Invalid("diagnostics_unknown_artifact_status");
            if (item.Status == "published")
            {
                var metadata = inventory.FirstOrDefault(m => m.Name == name);
                if (metadata is null || metadata.Status != "published" || item.ArtifactId != metadata.ArtifactId
                    || item.ByteCount != metadata.ByteCount || item.Sha256 != metadata.Sha256)
                {
                    throw DiagnosticSessionException.Invalid("diagnostics_index_metadata_mismatch");
                }
            }
            else if (IsPublished(name))
            {
                throw DiagnosticSessionException.Invalid("diagnostics_index_metadata_mismatch");
            }
        }

        var missing = new List<DiagnosticMissingProduct>();
        if (input.TypedParameters is { } inputs)
        {
            var requested = RequestedProducts(inputs);
            if (requested.Contains("screenshot.png") && IsPublished("screenshot.jpeg"))
            {
                requested.Remove("screenshot.png");
                requested.Add("screenshot.jpeg");
            }
            requested.UnionWith(missingRequired);
            foreach (var name in requested.Order(CodePointComparer.Instance))
            {
                if (IsPublished(name)) continue;
                missing.Add(new(name, index.Artifacts.TryGetValue(name, out var product) ? product.Detail ?? product.Status : "not published"));
            }
        }
        else
        {
            missing.Add(new("parameters", "typed capture inputs were not reported"));
        }

        IReadOnlyList<DiagnosticMark> marks = [];
        IReadOnlyList<string> notDerived = [];
        bool? ringHeldAnchor = null;
        if (IsPublished(MarkersArtifactName))
        {
            var document = DecodeMarkers(Document(MarkersArtifactName, input).Bytes.Span, input.JobId);
            var reading = DiagnosticSessionReading.Make(document);
            marks = reading.Marks;
            notDerived = reading.NotDerived;
            if (document.TryGetValue("coverage", out var coverage) && coverage is JsonObject c && c.TryGetValue("ringHeldAnchor", out var anchor))
            {
                ringHeldAnchor = FoundationBool(anchor);
            }
        }
        else
        {
            missing.Add(new(MarkersArtifactName, "marker document was not published"));
        }

        var provenance = new DiagnosticSessionProvenance("offlineDerived", ParserId, ParserVersion, Sorted(input.Documents.Values.Select(d => d.Metadata)));
        var result = new DiagnosticSessionReading(
            input.JobId,
            new DiagnosticAlignment.CannotAlign("capture artifacts contain no host-to-device calibration"),
            marks,
            missing,
            notDerived);
        return new(DiagnosticSessionInspection.CurrentSchemaVersion, input.JobId, input.OperationReference, provenance, result, ringHeldAnchor, Sorted(inventory));
    }

    /// <summary>A bounded text preview of one published capture Artifact. A sensitive Artifact
    /// is previewed only on explicit access.</summary>
    /// <exception cref="DiagnosticSessionException">The Swift reason the preview refused
    /// with.</exception>
    public static DiagnosticArtifactOfflinePreview Preview(DiagnosticOfflineArtifact artifact, bool contentAccessExplicit, int maximumCharacters = PreviewMaximumCharacters)
    {
        var metadata = artifact.Metadata;
        if (metadata.SourceOperation != OperationReference || metadata.MediaType is not ("text/plain" or "application/json"))
        {
            throw DiagnosticSessionException.Invalid("diagnostics_artifact_is_not_previewable_text");
        }
        if (artifact.Bytes.Length > PreviewMaximumBytes)
        {
            throw new DiagnosticSessionException(DiagnosticSessionFailure.ContentTooLarge, "diagnostics_artifact_exceeds_preview_limit", maximumBytes: PreviewMaximumBytes);
        }
        if (metadata.Privacy == "sensitive" && !contentAccessExplicit)
        {
            throw new DiagnosticSessionException(DiagnosticSessionFailure.SensitiveContentRequiresExplicitAccess, "diagnostics_sensitive_preview_requires_explicit_access");
        }
        var text = DiagnosticArtifactTextPreview.Create(artifact.Bytes.Span, metadata.MediaType, maximumCharacters)
            ?? throw DiagnosticSessionException.Invalid("diagnostics_invalid_structured_text");
        return new(DiagnosticArtifactOfflinePreview.CurrentSchemaVersion,
            new DiagnosticSessionProvenance("offlineDerived", ParserId, ParserVersion, [metadata]),
            text.Text, text.ReplacedInvalidUtf8, text.WasClipped);
    }

    private static List<DiagnosticArtifactMetadata> Sorted(IEnumerable<DiagnosticArtifactMetadata> metadata) =>
        metadata.OrderBy(m => m.Name, CodePointComparer.Instance).ThenBy(m => m.ArtifactId, CodePointComparer.Instance).ToList();

    private static DiagnosticOfflineArtifact Document(string name, DiagnosticSessionOfflineInput input)
    {
        if (!input.Documents.TryGetValue(name, out var artifact)
            || artifact.Metadata.Name != name
            || artifact.Metadata.MediaType != "application/json"
            || artifact.Metadata.Privacy != "standard"
            || artifact.Metadata.Status != "published"
            || artifact.Bytes.Length == 0
            || artifact.Bytes.Length > DocumentMaximumBytes
            || !input.Inventory.Contains(artifact.Metadata))
        {
            throw DiagnosticSessionException.Invalid($"diagnostics_missing_or_unreadable_{name}");
        }
        return artifact;
    }

    // Foundation bridges a JSON boolean, and a number that is exactly 0 or 1, to Bool.
    private static bool? FoundationBool(JsonValue value) => value switch
    {
        JsonBool b => b.Value,
        JsonNumber n when n.AsDouble() == 1 => true,
        JsonNumber n when n.AsDouble() == 0 => false,
        _ => null,
    };

    private sealed record Product(string Status, bool Required, string? ArtifactId, long? ByteCount, string? Sha256, string? Detail);

    private sealed record Index(string JobId, string Operation, IReadOnlyDictionary<string, Product> Artifacts, string? Completeness, IReadOnlyList<string>? MissingRequired);

    private static bool SameProducts(IReadOnlyDictionary<string, Product> left, IReadOnlyDictionary<string, Product> right) =>
        left.Count == right.Count && left.All(p => right.TryGetValue(p.Key, out var other) && other == p.Value);

    /// <summary>Swift <c>JSONDecoder().decode(Index.self, from:)</c>: the members it names, of
    /// their exact types (an optional member may be absent or null); others are ignored.</summary>
    private static Index DecodeIndex(ReadOnlySpan<byte> bytes)
    {
        static DiagnosticSessionException Unreadable() => DiagnosticSessionException.Invalid("diagnostics_unreadable_session_document");
        JsonValue parsed;
        try
        {
            parsed = StrictJson.Parse(bytes);
        }
        catch (MalformedJsonException)
        {
            throw Unreadable();
        }
        if (parsed is not JsonObject root) throw Unreadable();
        static string RequiredText(JsonObject o, string key) =>
            o.TryGetValue(key, out var v) && v is JsonString s ? s.Value : throw Unreadable();
        static string? OptionalText(JsonObject o, string key) =>
            !o.TryGetValue(key, out var v) || v is JsonNull ? null : v is JsonString s ? s.Value : throw Unreadable();

        if (!root.TryGetValue("artifacts", out var a) || a is not JsonObject artifacts) throw Unreadable();
        var products = new Dictionary<string, Product>(StringComparer.Ordinal);
        foreach (var (name, value) in artifacts.Members)
        {
            if (value is not JsonObject product) throw Unreadable();
            long? byteCount = !product.TryGetValue("byteCount", out var count) || count is JsonNull
                ? null
                : count is JsonNumber n && n.TryGetInt64(out var integer) ? integer : throw Unreadable();
            products[name] = new Product(
                RequiredText(product, "status"),
                product.TryGetValue("required", out var required) && required is JsonBool flag ? flag.Value : throw Unreadable(),
                OptionalText(product, "artifactId"),
                byteCount,
                OptionalText(product, "sha256"),
                OptionalText(product, "detail"));
        }
        IReadOnlyList<string>? missing = !root.TryGetValue("missingRequired", out var m) || m is JsonNull
            ? null
            : m is JsonArray names ? names.Items.Select(i => i is JsonString s ? s.Value : throw Unreadable()).ToList() : throw Unreadable();
        return new Index(RequiredText(root, "jobId"), RequiredText(root, "operation"), products, OptionalText(root, "completeness"), missing);
    }

    /// <summary>Swift <c>MarkerDocument.decode</c>: the published markers document, checked.</summary>
    private static JsonObject DecodeMarkers(ReadOnlySpan<byte> bytes, string jobId)
    {
        static DiagnosticSessionException Malformed() => DiagnosticSessionException.Invalid("diagnostics_invalid_markers_document");
        JsonValue parsed;
        try
        {
            parsed = StrictJson.Parse(bytes);
        }
        catch (MalformedJsonException)
        {
            throw Malformed();
        }
        if (parsed is not JsonObject document
            || Text(document, "documentType") != "arkdeck-diagnostic-markers"
            || Text(document, "schemaVersion") != "1.0.0"
            || Text(document, "jobId") != jobId
            || !document.TryGetValue("markers", out var m) || m is not JsonArray markers || !markers.Items.All(i => i is JsonObject)
            || markers.Items.Count > 1_024
            || !document.TryGetValue("notDerived", out var n) || n is not JsonArray notDerived
            || !notDerived.Items.All(i => i is JsonObject o && Text(o, "kind") is not null && Text(o, "reason") is not null))
        {
            throw Malformed();
        }
        foreach (var marker in markers.Items.Cast<JsonObject>())
        {
            switch (Text(marker, "kind"))
            {
                case "manual":
                    if (Text(marker, "atHostUTC") is not { } instant || !DiagnosticInstant.IsValid(instant))
                    {
                        throw DiagnosticSessionException.Invalid("diagnostics_invalid_marker_timestamp");
                    }
                    break;
                case "auto":
                    if (Text(marker, "trigger") is not { Length: > 0 }) throw DiagnosticSessionException.Invalid("diagnostics_invalid_automatic_marker");
                    if (marker.ContainsKey("atHostUTC") && (Text(marker, "atHostUTC") is not { } at || !DiagnosticInstant.IsValid(at)))
                    {
                        throw DiagnosticSessionException.Invalid("diagnostics_invalid_marker_timestamp");
                    }
                    break;
                default:
                    throw DiagnosticSessionException.Invalid("diagnostics_unknown_marker_kind");
            }
        }
        return document;
    }

    internal static string? Text(JsonObject o, string key) => o.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;

    /// <summary>Swift <c>requestedProducts</c>: what the capture's typed inputs asked for.</summary>
    private static HashSet<string> RequestedProducts(JsonObject inputs)
    {
        static DiagnosticSessionException Parameters() => DiagnosticSessionException.Invalid("diagnostics_invalid_capture_parameters");
        bool Enabled(string name, bool defaultValue = false) =>
            !inputs.TryGetValue(name, out var reported) ? defaultValue : reported is JsonBool flag ? flag.Value : throw Parameters();

        var names = new HashSet<string>(StringComparer.Ordinal);
        if (Enabled("captureHilog", true)) names.Add("hilog.txt");
        if (Enabled("uiDump", true)) names.Add("ui-dump.json");
        if (Enabled("advancedDump")) names.Add("advanced-dump.txt");
        if (Enabled("uiComponentTree")) names.Add("ui-tree.json");
        if (Enabled("uiScreenshot"))
        {
            var imageType = "png";
            if (inputs.TryGetValue("screenshotImageType", out var value))
            {
                imageType = value is JsonString { Value: "png" or "jpeg" } type ? type.Value : throw Parameters();
            }
            names.Add($"screenshot.{imageType}");
        }
        if (Enabled("crashLogs")) names.Add("crash-index.txt");
        foreach (var (field, product) in new[] { ("crashLogName", "crash-log.txt"), ("bundleName", "application-liveness.json") })
        {
            if (!inputs.TryGetValue(field, out var value)) continue;
            if (value is not JsonString { Value.Length: > 0 }) throw Parameters();
            names.Add(product);
        }
        if (inputs.TryGetValue("traceCategories", out var categories))
        {
            if (categories is not JsonArray tags || !tags.Items.All(t => t is JsonString { Value.Length: > 0 })) throw Parameters();
            if (tags.Items.Count > 0) names.Add("trace.htrace");
        }
        return names;
    }
}

/// <summary>How host time and device time relate for a session. There is no fourth state for
/// "probably fine".</summary>
public abstract record DiagnosticAlignment
{
    private DiagnosticAlignment() { }

    /// <summary>One clock produced both sides.</summary>
    public sealed record SameClock : DiagnosticAlignment;

    /// <summary>Two clocks with a measured offset, good to this tolerance.</summary>
    public sealed record Calibrated(int ToleranceMs) : DiagnosticAlignment;

    /// <summary>No calibration was established: nothing may be lined up against device time.</summary>
    public sealed record CannotAlign(string Reason) : DiagnosticAlignment;
}

/// <summary>Why a mark has no picture beside it. None of them is "here is an older
/// picture".</summary>
public abstract record DiagnosticScreenshotAbsence
{
    private DiagnosticScreenshotAbsence() { }

    /// <summary>A screenshot exists but was taken too far from the mark to stand for it.</summary>
    public sealed record TakenTooFarFromTheMark(int OffsetMs) : DiagnosticScreenshotAbsence;

    /// <summary>The window the host could observe the shutter in is wider than the rule.</summary>
    public sealed record ShutterWindowWiderThanTheRule(int WindowMs) : DiagnosticScreenshotAbsence;

    /// <summary>The capture tried and failed, and said why.</summary>
    public sealed record CaptureFailed(string Reason) : DiagnosticScreenshotAbsence;

    /// <summary>Nothing was captured for this mark.</summary>
    public sealed record NotCaptured : DiagnosticScreenshotAbsence;
}

/// <summary>A screenshot beside a mark; <c>TakenAfterMarkMs</c> is always shown.</summary>
public sealed record DiagnosticScreenshot(string ArtifactName, string CapturedAtUtc, int TakenAfterMarkMs);

/// <summary>A screenshot and the interval the host could observe its shutter in.</summary>
public sealed record DiagnosticObservedScreenshot(string ArtifactName, string WindowStartUtc, string WindowEndUtc);

/// <summary>A screenshot attempt that failed at a host instant.</summary>
public sealed record DiagnosticFailedScreenshot(string AtHostUtc, string Reason);

/// <summary>One mark of the session, its picture or why it has none.</summary>
public sealed record DiagnosticMark(
    int Ordinal,
    bool IsAutomatic,
    string AtHostUtc,
    string? Label,
    DiagnosticScreenshot? Screenshot,
    DiagnosticScreenshotAbsence? ScreenshotAbsence,
    string? Trigger);

/// <summary>A product the session declared and did not publish, named rather than omitted.</summary>
public sealed record DiagnosticMissingProduct(string Name, string Reason);

/// <summary>What a diagnostic session can be shown to say, derived only from the time facts its
/// Artifacts carry (Swift <c>DiagnosticSessionReading</c>).</summary>
public sealed record DiagnosticSessionReading(
    string JobId,
    DiagnosticAlignment Alignment,
    IReadOnlyList<DiagnosticMark> Marks,
    IReadOnlyList<DiagnosticMissingProduct> MissingProducts,
    IReadOnlyList<string> NotDerived)
{
    /// <summary>How far from a mark a screenshot may have been taken and still stand beside it.</summary>
    public const int ScreenshotAppliesWithinMs = 150;

    /// <summary>True when a declared product is missing: the reader says Partial.</summary>
    public bool IsPartial => MissingProducts.Count > 0;

    /// <summary>Builds the reading from a session's own <c>markers.json</c> and its screenshot
    /// facts (Swift <c>DiagnosticSessionReading.make</c>).</summary>
    public static DiagnosticSessionReading Make(
        JsonObject markersDocument,
        IReadOnlyList<(string ArtifactName, string CapturedAtUtc)>? screenshots = null,
        IReadOnlyList<DiagnosticObservedScreenshot>? observedScreenshots = null,
        IReadOnlyList<DiagnosticFailedScreenshot>? failedScreenshots = null,
        IReadOnlyList<DiagnosticMissingProduct>? declaredButMissing = null,
        DiagnosticAlignment? calibration = null)
    {
        screenshots ??= [];
        observedScreenshots ??= [];
        failedScreenshots ??= [];
        var jobId = DiagnosticSessionOfflineInspector.Text(markersDocument, "jobId") ?? "";
        var raw = markersDocument.TryGetValue("markers", out var m) && m is JsonArray a && a.Items.All(i => i is JsonObject)
            ? a.Items.Cast<JsonObject>().ToList()
            : [];
        var notDerived = markersDocument.TryGetValue("notDerived", out var n) && n is JsonArray nd && nd.Items.All(i => i is JsonObject)
            ? nd.Items.Cast<JsonObject>().Select(o => DiagnosticSessionOfflineInspector.Text(o, "kind")).OfType<string>().ToList()
            : [];
        var tolerance = ScreenshotAppliesWithinMs / 1000.0;

        var marks = new List<DiagnosticMark>();
        for (var i = 0; i < raw.Count; i++)
        {
            var entry = raw[i];
            var at = DiagnosticSessionOfflineInspector.Text(entry, "atHostUTC");
            var isAutomatic = DiagnosticSessionOfflineInspector.Text(entry, "kind") == "auto";
            var instant = at is null ? null : DiagnosticInstant.Parse(at);

            DiagnosticScreenshot? screenshot = null;
            DiagnosticScreenshotAbsence? absence = null;
            if (instant is { } mark)
            {
                (DiagnosticScreenshot Shot, int Distance)? nearest = null;
                foreach (var (artifactName, capturedAtUtc) in screenshots)
                {
                    if (DiagnosticInstant.Parse(capturedAtUtc) is not { } taken) continue;
                    var delta = DiagnosticInstant.Milliseconds(DiagnosticInstant.Seconds(mark, taken));
                    var distance = Math.Abs(delta);
                    if (nearest is null || distance < nearest.Value.Distance) nearest = (new DiagnosticScreenshot(artifactName, capturedAtUtc, delta), distance);
                }
                if (nearest is { } found)
                {
                    if (found.Distance <= ScreenshotAppliesWithinMs) screenshot = found.Shot;
                    else absence = new DiagnosticScreenshotAbsence.TakenTooFarFromTheMark(found.Shot.TakenAfterMarkMs);
                }

                // A capture whose observed window overlaps the mark's tolerance might be this
                // moment; when the window is wider than the rule, the rule cannot decide.
                if (screenshot is null)
                {
                    foreach (var observed in observedScreenshots)
                    {
                        if (DiagnosticInstant.Parse(observed.WindowStartUtc) is not { } start
                            || DiagnosticInstant.Parse(observed.WindowEndUtc) is not { } end
                            || DiagnosticInstant.Seconds(mark, end) < -tolerance
                            || DiagnosticInstant.Seconds(mark, start) > tolerance)
                        {
                            continue;
                        }
                        var width = DiagnosticInstant.Milliseconds(DiagnosticInstant.Seconds(start, end));
                        if (width <= ScreenshotAppliesWithinMs)
                        {
                            screenshot = new DiagnosticScreenshot(observed.ArtifactName, observed.WindowStartUtc,
                                DiagnosticInstant.Milliseconds(DiagnosticInstant.Seconds(mark, start)));
                        }
                        else
                        {
                            absence = new DiagnosticScreenshotAbsence.ShutterWindowWiderThanTheRule(width);
                        }
                        break;
                    }
                }
                if (screenshot is null && absence is null)
                {
                    // A failure at this mark is a better answer than "nothing was taken".
                    var failure = failedScreenshots.FirstOrDefault(f =>
                        DiagnosticInstant.Parse(f.AtHostUtc) is { } failed
                        && Math.Abs(DiagnosticInstant.Seconds(mark, failed)) * 1000 <= ScreenshotAppliesWithinMs);
                    absence = failure is null
                        ? new DiagnosticScreenshotAbsence.NotCaptured()
                        : new DiagnosticScreenshotAbsence.CaptureFailed(failure.Reason);
                }
            }
            else
            {
                absence = new DiagnosticScreenshotAbsence.NotCaptured();
            }

            marks.Add(new DiagnosticMark(i + 1, isAutomatic, at ?? "", DiagnosticSessionOfflineInspector.Text(entry, "label"),
                screenshot, absence, DiagnosticSessionOfflineInspector.Text(entry, "trigger")));
        }

        return new DiagnosticSessionReading(
            jobId,
            calibration ?? new DiagnosticAlignment.CannotAlign("no host-to-device calibration was established for this session"),
            marks,
            declaredButMissing ?? [],
            notDerived);
    }
}

/// <summary>A selectable event on the reader's track.</summary>
public sealed record DiagnosticReaderEvent(string Identity, string Name, string StartUtc);

/// <summary>
/// What the reader is currently pointed at (Swift <c>DiagnosticReaderSelection</c>). A selected
/// event survives the cursor moving away from it.
/// </summary>
public sealed class DiagnosticReaderSelection(string cursorUtc, DiagnosticReaderEvent? @event = null)
{
    public string CursorUtc { get; private set; } = cursorUtc;

    public DiagnosticReaderEvent? Event { get; private set; } = @event;

    /// <summary>Moving the cursor never changes which event is selected.</summary>
    public void MoveCursor(string instant) => CursorUtc = instant;

    /// <summary>Only choosing an event changes the event; the cursor goes to its start.</summary>
    public void Select(DiagnosticReaderEvent selected)
    {
        Event = selected;
        CursorUtc = selected.StartUtc;
    }

    /// <summary>How far the cursor has drifted from the selected event, in milliseconds.</summary>
    public int? CursorOffsetFromEventMs() =>
        Event is not null && DiagnosticInstant.Parse(Event.StartUtc) is { } start && DiagnosticInstant.Parse(CursorUtc) is { } cursor
            ? DiagnosticInstant.Milliseconds(DiagnosticInstant.Seconds(start, cursor))
            : null;
}

/// <summary>Swift <c>ISO8601Timestamps.parse</c>: an ISO 8601 instant, with or without
/// fractional seconds, <c>Z</c> or a numeric offset.</summary>
internal static class DiagnosticInstant
{
    /// <summary>The accepted spelling (the Rust port's <c>instant</c> grammar).</summary>
    public static bool IsValid(string value) => Fields(value) is not null;

    /// <summary>The instant, or null when it is not a valid spelling or not representable.
    /// Out-of-range days and a leap second roll over, as Foundation's calendar does.</summary>
    public static DateTimeOffset? Parse(string value)
    {
        if (Fields(value) is not { } f || f.Year < 1) return null;
        try
        {
            var start = new DateTimeOffset(f.Year, f.Month, 1, 0, 0, 0, TimeSpan.Zero);
            return start.AddDays(f.Day - 1).AddHours(f.Hour).AddMinutes(f.Minute).AddSeconds(f.Second).AddTicks(f.Ticks)
                .AddMinutes(-f.OffsetMinutes);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>Seconds from <paramref name="from"/> to <paramref name="to"/>.</summary>
    public static double Seconds(DateTimeOffset from, DateTimeOffset to) => (to.UtcTicks - from.UtcTicks) / (double)TimeSpan.TicksPerSecond;

    /// <summary>Swift <c>Int((seconds * 1000).rounded())</c>.</summary>
    public static int Milliseconds(double seconds) => (int)Math.Round(seconds * 1000, MidpointRounding.AwayFromZero);

    private readonly record struct Parts(int Year, int Month, int Day, int Hour, int Minute, int Second, long Ticks, int OffsetMinutes);

    private static Parts? Fields(string value)
    {
        if (value.Length < 20 || value[4] != '-' || value[7] != '-' || value[10] != 'T' || value[13] != ':' || value[16] != ':') return null;
        bool Digits(int from, int to)
        {
            for (var i = from; i < to; i++)
            {
                if (value[i] is < '0' or > '9') return false;
            }
            return true;
        }
        if (!(Digits(0, 4) && Digits(5, 7) && Digits(8, 10) && Digits(11, 13) && Digits(14, 16) && Digits(17, 19))) return null;
        int Number(int from, int to) => int.Parse(value.AsSpan(from, to - from), NumberStyles.None, CultureInfo.InvariantCulture);
        var rest = value.AsSpan(19);
        long ticks = 0;
        if (rest.Length > 0 && rest[0] == '.')
        {
            var count = 1;
            while (count < rest.Length && rest[count] is >= '0' and <= '9') count++;
            if (count == 1) return null;
            var fraction = rest[1..count];
            for (var i = 0; i < 7; i++) ticks = ticks * 10 + (i < fraction.Length ? fraction[i] - '0' : 0);
            rest = rest[count..];
        }
        int offset;
        if (rest is "Z")
        {
            offset = 0;
        }
        else if (rest.Length == 6 && rest[0] is '+' or '-' && rest[3] == ':'
                 && rest[1] is >= '0' and <= '9' && rest[2] is >= '0' and <= '9' && rest[4] is >= '0' and <= '9' && rest[5] is >= '0' and <= '9')
        {
            offset = ((rest[1] - '0') * 10 + (rest[2] - '0')) * 60 + (rest[4] - '0') * 10 + (rest[5] - '0');
            if (rest[0] == '-') offset = -offset;
        }
        else
        {
            return null;
        }
        var parts = new Parts(Number(0, 4), Number(5, 7), Number(8, 10), Number(11, 13), Number(14, 16), Number(17, 19), ticks, offset);
        return parts.Month is >= 1 and <= 12 && parts.Day is >= 1 and <= 31 && parts.Hour < 24 && parts.Minute < 60 && parts.Second < 61 ? parts : null;
    }
}

internal static class DiagnosticDigest
{
    public static string Sha256(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    public static bool IsLowercaseSha256(string value) => ArtifactSummary.IsSha256(value);
}

// ---------------------------------------------------------------------------------------------
// The App-side binding (Swift DiagnosticSessionApplicationReader, DiagnosticHilogSummaryReader):
// the History selection, the Job's detail as the App read it, and a reader of verified bytes.
// ---------------------------------------------------------------------------------------------

/// <summary>The History row a diagnostics page opens (Swift <c>RuntimeHistoryWorkspaceContext</c>,
/// the members these readers check).</summary>
public sealed record DiagnosticJobContext(string JobId, string OperationReference, string TargetId, string? SessionId, string State, string? ExecutionMode);

/// <summary>The Job's own identity as <c>job.show</c> states it (Swift
/// <c>RuntimeJobCorrelationPresentation</c>): unavailable when the status names no Session.</summary>
public sealed record DiagnosticJobCorrelation(string JobId, string OperationReference, string TargetId, string SessionId)
{
    /// <summary>The correlation of <c>job.show</c>'s status object (<see cref="JobShown.Status"/>):
    /// null when it is another Job's or another operation's, or names no Session.</summary>
    public static DiagnosticJobCorrelation? FromStatus(JsonObject status, string jobId, string operationReference)
    {
        var target = DiagnosticSessionOfflineInspector.Text(status, "targetId");
        var session = DiagnosticSessionOfflineInspector.Text(status, "sessionId");
        return DiagnosticSessionOfflineInspector.Text(status, "jobId") == jobId
               && DiagnosticSessionOfflineInspector.Text(status, "operation") == operationReference
               && target is not null && session is { Length: > 0 }
            ? new(jobId, operationReference, target, session)
            : null;
    }
}

/// <summary>The <c>job.evidence</c> facts the diagnostics readers check (Swift
/// <c>RuntimeJobEvidencePresentation</c>): the typed parameters are the Runtime's
/// <c>parameters</c> object, null when it reported none.</summary>
public sealed record DiagnosticJobEvidence(
    string TerminalState,
    string ExecutionMode,
    string? ActualEffect,
    string ProviderId,
    long? BindingRevision,
    JsonObject? TypedParameters)
{
    /// <summary>One <c>job.evidence</c> answer, or null when it is another Job's or lacks a fact
    /// the Runtime must publish (Swift <c>decodeEvidence</c>).</summary>
    public static DiagnosticJobEvidence? Parse(JsonValue value, string jobId, string operationReference)
    {
        if (value is not JsonObject o
            || DiagnosticSessionOfflineInspector.Text(o, "jobId") != jobId
            || DiagnosticSessionOfflineInspector.Text(o, "operationReference") != operationReference
            || DiagnosticSessionOfflineInspector.Text(o, "catalogDigest") is null
            || DiagnosticSessionOfflineInspector.Text(o, "providerId") is not { } provider
            || DiagnosticSessionOfflineInspector.Text(o, "executionMode") is not { } mode
            || DiagnosticSessionOfflineInspector.Text(o, "terminalState") is not { } terminal)
        {
            return null;
        }
        long? revision = o.TryGetValue("bindingRevision", out var r) && r is JsonNumber n && n.TryGetInt64(out var integer) ? integer : null;
        return new(terminal, mode, DiagnosticSessionOfflineInspector.Text(o, "actualEffect"), provider, revision,
            o.TryGetValue("parameters", out var p) && p is JsonObject parameters ? parameters : null);
    }
}

/// <summary>One Artifact of the Job as the App lists it (Swift
/// <c>RuntimeArtifactPresentation</c>): its Catalog role, and an empty digest when the Runtime
/// sent none.</summary>
public sealed record DiagnosticJobArtifact(
    string ArtifactId,
    string Name,
    string? Role,
    string MediaType,
    long ByteCount,
    string Sha256,
    string Privacy,
    string Status,
    string? StatusDetail,
    string SourceOperation,
    string CreatedAtUtc)
{
    /// <summary>An <c>artifact.list</c> row of a Job of <paramref name="operationReference"/>, its
    /// role the one that operation's Catalog entry declares for the name.</summary>
    public static DiagnosticJobArtifact From(ArtifactSummary row, string operationReference, string? statusDetail = null) =>
        new(row.ArtifactId, row.Name, DiagnosticArtifactRoles.Of(operationReference, row.Name), row.MediaType, row.ByteCount,
            row.Digest ?? "", row.Privacy, row.Status, statusDetail, row.SourceOperation, row.CreatedAtUtc);
}

/// <summary>The Artifact roles the Catalog declares for the two operations these readers open
/// (<c>Catalog/operations/capture.diagnostics.v1.json</c>,
/// <c>analyzer.summarize-hilog.v1.json</c>; checked against them by the tests).</summary>
public static class DiagnosticArtifactRoles
{
    public static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Declared =
        new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.Ordinal)
        {
            [DiagnosticSessionOfflineInspector.OperationReference] = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["hilog.txt"] = "raw",
                ["ui-dump.json"] = "raw",
                ["advanced-dump.txt"] = "raw",
                ["ui-tree.json"] = "raw",
                ["screenshot.png"] = "raw",
                ["screenshot.jpeg"] = "raw",
                ["crash-index.txt"] = "raw",
                ["crash-log.txt"] = "raw",
                ["application-liveness.json"] = "derived",
                ["trace.htrace"] = "raw",
                ["capture.log"] = "log",
                ["markers.json"] = "derived",
                ["artifact-index.json"] = "derived",
                ["capture-summary.json"] = "derived",
            },
            [DiagnosticHilogSummary.OperationReference] = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                [DiagnosticHilogSummary.ArtifactName] = "derived",
            },
        };

    public static string? Of(string operationReference, string name) =>
        Declared.TryGetValue(operationReference, out var roles) && roles.TryGetValue(name, out var role) ? role : null;
}

/// <summary>What the App read for one Job: its correlation (null when unavailable), its
/// Artifacts (null when the inventory could not be read), its timeline and its evidence (null
/// when unavailable).</summary>
public sealed record DiagnosticJobDetail(
    string JobId,
    DiagnosticJobCorrelation? Correlation,
    IReadOnlyList<DiagnosticJobArtifact>? Artifacts,
    IReadOnlyList<string> Timeline,
    DiagnosticJobEvidence? Evidence);

/// <summary>One verified Artifact read: its bytes, or why not.</summary>
public sealed record DiagnosticArtifactRead(byte[]? Bytes, string? FailureReason)
{
    public static DiagnosticArtifactRead Loaded(byte[] bytes) => new(bytes, null);

    public static DiagnosticArtifactRead Failed(string reason) => new(null, reason);
}

/// <summary>Reads one Artifact of the Job, at most <c>maximumBytes</c>, sensitive only when
/// allowed (Swift <c>RuntimeJobDetailApplicationProviding.readArtifact</c>).</summary>
public delegate Task<DiagnosticArtifactRead> DiagnosticArtifactReader(DiagnosticJobArtifact artifact, int maximumBytes, bool allowSensitive);

/// <summary>The published bounded capture, read without a connected device (Swift
/// <c>DiagnosticSessionPresentation</c>).</summary>
public sealed record DiagnosticSessionPresentation(
    DiagnosticSessionReading Reading,
    IReadOnlyList<DiagnosticJobArtifact> Artifacts,
    IReadOnlyList<string> Timeline,
    bool? RingHeldAnchor);

/// <summary>The session, or the Swift reason it is unavailable.</summary>
public sealed record DiagnosticSessionLoad(DiagnosticSessionPresentation? Presentation, string? UnavailableReason)
{
    public static DiagnosticSessionLoad Unavailable(string reason) => new(null, reason);
}

/// <summary>The App's binding of one <c>capture.diagnostics@1</c> Job to the shared offline
/// inspector (Swift <c>DiagnosticSessionApplicationReader</c>).</summary>
public static class DiagnosticSessionApplication
{
    public static async Task<DiagnosticSessionLoad> LoadAsync(DiagnosticJobContext context, DiagnosticJobDetail detail, DiagnosticArtifactReader read)
    {
        if (context.OperationReference != DiagnosticSessionOfflineInspector.OperationReference)
        {
            return DiagnosticSessionLoad.Unavailable("diagnostics_unsupported_operation");
        }
        if (detail.JobId != context.JobId || detail.Correlation is not { } correlation
            || correlation.JobId != context.JobId || correlation.OperationReference != context.OperationReference
            || correlation.TargetId != context.TargetId || correlation.SessionId != context.SessionId
            || detail.Artifacts is not { } artifacts)
        {
            return DiagnosticSessionLoad.Unavailable("diagnostics_job_correlation_unavailable");
        }

        try
        {
            var inventory = artifacts.Select(Metadata).ToList();
            if (inventory.Select(m => m.ArtifactId).Distinct(StringComparer.Ordinal).Count() != inventory.Count
                || inventory.Select(m => m.Name).Distinct(StringComparer.Ordinal).Count() != inventory.Count
                || !inventory.All(m => m.SourceOperation == context.OperationReference))
            {
                return DiagnosticSessionLoad.Unavailable("diagnostics_ambiguous_artifact_inventory");
            }

            var documents = new Dictionary<string, DiagnosticOfflineArtifact>(StringComparer.Ordinal);
            foreach (var name in new[] { DiagnosticSessionOfflineInspector.IndexArtifactName, DiagnosticSessionOfflineInspector.SummaryArtifactName })
            {
                documents[name] = await DocumentAsync(name, inventory, artifacts, read).ConfigureAwait(false);
            }
            if (inventory.Any(m => m.Name == DiagnosticSessionOfflineInspector.MarkersArtifactName && m.Status == "published"))
            {
                var name = DiagnosticSessionOfflineInspector.MarkersArtifactName;
                documents[name] = await DocumentAsync(name, inventory, artifacts, read).ConfigureAwait(false);
            }

            var inspection = DiagnosticSessionOfflineInspector.Inspect(new DiagnosticSessionOfflineInput(
                context.JobId, context.OperationReference, detail.Evidence?.TypedParameters, inventory, documents));
            return new(new DiagnosticSessionPresentation(inspection.Reading, artifacts, detail.Timeline, inspection.RingHeldAnchor), null);
        }
        catch (Refusal refusal)
        {
            return DiagnosticSessionLoad.Unavailable(refusal.Reason);
        }
        catch (DiagnosticSessionException refusal)
        {
            return DiagnosticSessionLoad.Unavailable(refusal.Reason);
        }
        catch (Exception)
        {
            // Swift's catch-all: anything else is an unreadable session document.
            return DiagnosticSessionLoad.Unavailable("diagnostics_unreadable_session_document");
        }
    }

    private static async Task<DiagnosticOfflineArtifact> DocumentAsync(string name, IReadOnlyList<DiagnosticArtifactMetadata> inventory,
        IReadOnlyList<DiagnosticJobArtifact> artifacts, DiagnosticArtifactReader read)
    {
        var metadata = inventory.FirstOrDefault(m => m.Name == name);
        var artifact = metadata is null ? null : artifacts.FirstOrDefault(a => a.ArtifactId == metadata.ArtifactId && a.Name == name);
        if (metadata is null || artifact is null || artifact.Role != "derived" || metadata.Status != "published"
            || metadata.MediaType != "application/json" || metadata.Privacy != "standard"
            || metadata.ByteCount <= 0 || metadata.ByteCount > DiagnosticSessionOfflineInspector.DocumentMaximumBytes)
        {
            throw new Refusal($"diagnostics_missing_or_unreadable_{name}");
        }
        var answer = await read(artifact, DiagnosticSessionOfflineInspector.DocumentMaximumBytes, false).ConfigureAwait(false);
        if (answer.Bytes is not { } bytes) throw new Refusal(answer.FailureReason ?? "diagnostics_unreadable_session_document");
        return DiagnosticOfflineArtifact.Bind(metadata, bytes);
    }

    private static DiagnosticArtifactMetadata Metadata(DiagnosticJobArtifact artifact)
    {
        if (artifact.ByteCount < 0) throw new Refusal("diagnostics_invalid_artifact_metadata");
        try
        {
            return DiagnosticArtifactMetadata.Create(artifact.ArtifactId, artifact.Name, artifact.MediaType, artifact.Privacy, artifact.Status,
                artifact.StatusDetail, artifact.SourceOperation, artifact.ByteCount, artifact.Status == "published" ? artifact.Sha256 : null);
        }
        catch (DiagnosticSessionException)
        {
            throw new Refusal("diagnostics_invalid_artifact_metadata");
        }
    }

    private sealed class Refusal(string reason) : Exception(reason)
    {
        public string Reason { get; } = reason;
    }
}

/// <summary>A verified HiLog summary Artifact and its recorded provenance (Swift
/// <c>DiagnosticHilogSummaryPresentation</c>). No source log, transport or device-health verdict
/// is exposed.</summary>
public sealed record DiagnosticHilogSummaryPresentation(
    string JobId,
    string SourceJobId,
    string SourceArtifactId,
    string SourceSha256,
    long SourceByteCount,
    string AnalyzerExecutableSha256,
    string AnalyzerOutputSha256,
    string HeaderCoverage,
    long LineCount,
    long BlankLineCount,
    long UnrecognizedLineCount,
    IReadOnlyDictionary<string, long> LevelCounts,
    DiagnosticJobArtifact Artifact);

/// <summary>The summary, or the Swift reason it is unavailable.</summary>
public sealed record DiagnosticHilogSummaryLoad(DiagnosticHilogSummaryPresentation? Presentation, string? UnavailableReason)
{
    public static DiagnosticHilogSummaryLoad Unavailable(string reason) => new(null, reason);
}

/// <summary>
/// Reads one <c>analyzer.summarize-hilog@1</c> Job's summary Artifact and verifies it as macOS
/// does (Swift <c>DiagnosticHilogSummaryReader</c> over <c>HilogSummaryArtifactContract</c>): the
/// Job's facts, the source lease, the Artifact row, its size and digest, its canonical encoding,
/// and the analyzer report it records.
/// </summary>
public static class DiagnosticHilogSummary
{
    public const string OperationReference = "analyzer.summarize-hilog@1";
    public const string ArtifactName = "hilog-summary.json";
    public const int MaximumBytes = 16 * 1024;
    public const string AnalyzerRef = "hilog-summary@1";
    public const string AnalyzerVersion = "1.0.0";
    public const long MaximumInputBytes = 512L * 1024 * 1024;
    public const int MaximumOutputBytes = 8 * 1024;

    private static readonly string[] Levels = ["D", "I", "W", "E", "F"];
    private static readonly string[] Coverages = ["complete", "partial", "unrecognized", "empty"];

    public static async Task<DiagnosticHilogSummaryLoad> LoadAsync(DiagnosticJobContext context, DiagnosticJobDetail detail, DiagnosticArtifactReader read)
    {
        if (context.OperationReference != OperationReference || context.State != "succeeded" || context.ExecutionMode != "execute")
        {
            return DiagnosticHilogSummaryLoad.Unavailable("diagnostics_hilog_summary_not_completed");
        }
        if (detail.JobId != context.JobId || detail.Correlation is not { } correlation
            || correlation.JobId != context.JobId || correlation.OperationReference != context.OperationReference
            || correlation.TargetId != context.TargetId || correlation.SessionId != context.SessionId
            || detail.Evidence is not { } evidence
            || evidence.TerminalState != "succeeded" || evidence.ExecutionMode != "execute"
            || evidence.ActualEffect != "hostOnly" || evidence.ProviderId != "analyzer"
            || evidence.BindingRevision is not null
            || evidence.TypedParameters is null
            || !evidence.TypedParameters.TryGetValue("sourceArtifactRef", out var reference) || reference is not JsonString lease)
        {
            return DiagnosticHilogSummaryLoad.Unavailable("diagnostics_hilog_summary_correlation_mismatch");
        }
        var parts = lease.Value.Split(':');
        if (parts.Length != 3 || parts[0] != "lease-v1" || !IsIdentifier(parts[1]) || !IsIdentifier(parts[2]))
        {
            return DiagnosticHilogSummaryLoad.Unavailable("diagnostics_hilog_summary_source_unavailable");
        }

        var artifacts = detail.Artifacts;
        var artifact = artifacts?.FirstOrDefault(a => a.Name == ArtifactName);
        if (artifacts is null
            || artifacts.Select(a => a.ArtifactId).Distinct(StringComparer.Ordinal).Count() != artifacts.Count
            || artifacts.Select(a => a.Name).Distinct(StringComparer.Ordinal).Count() != artifacts.Count
            || artifact is null
            || artifact.SourceOperation != context.OperationReference
            || artifact.Status != "published" || artifact.Role != "derived"
            || artifact.Privacy != "standard" || artifact.MediaType != "application/json"
            || artifact.ByteCount <= 0 || artifact.ByteCount > MaximumBytes
            || !IsDigest(artifact.Sha256))
        {
            return DiagnosticHilogSummaryLoad.Unavailable("diagnostics_hilog_summary_artifact_unavailable");
        }

        var answer = await read(artifact, MaximumBytes, false).ConfigureAwait(false);
        if (answer.Bytes is not { } bytes) return DiagnosticHilogSummaryLoad.Unavailable("diagnostics_hilog_summary_read_failed");
        return Verify(context.JobId, parts[1], parts[2], artifact, bytes) is { } presentation
            ? new(presentation, null)
            : DiagnosticHilogSummaryLoad.Unavailable("diagnostics_hilog_summary_integrity_mismatch");
    }

    /// <summary>The bytes' integrity checks: null is <c>diagnostics_hilog_summary_integrity_mismatch</c>.</summary>
    private static DiagnosticHilogSummaryPresentation? Verify(string jobId, string sourceJobId, string sourceArtifactId, DiagnosticJobArtifact artifact, byte[] bytes)
    {
        if (bytes.Length != artifact.ByteCount || DiagnosticDigest.Sha256(bytes) != artifact.Sha256) return null;
        if (Parse(bytes) is not JsonObject root || DecodeDerived(root) is not { } document) return null;
        if (!CanonicalJson.Encode(document.Encode()).AsSpan().SequenceEqual(bytes)) return null;
        var result = document.Result;
        if (document.SourceArtifactId != sourceArtifactId
            || !IsDigest(result.SourceSha256) || !IsDigest(document.AnalyzerExecutableSha256) || !IsDigest(document.AnalyzerOutputSha256))
        {
            return null;
        }
        var report = CanonicalJson.Encode(result.Encode());
        if (report.Length != document.AnalyzerOutputByteCount || DiagnosticDigest.Sha256(report) != document.AnalyzerOutputSha256
            || !ValidateReport(report, result.SourceSha256, result.SourceByteCount))
        {
            return null;
        }
        return new(jobId, sourceJobId, document.SourceArtifactId, result.SourceSha256, result.SourceByteCount,
            document.AnalyzerExecutableSha256, document.AnalyzerOutputSha256, result.HeaderCoverage,
            result.LineCount, result.BlankLineCount, result.UnrecognizedLineCount, result.LevelCounts, artifact);
    }

    /// <summary>Swift <c>HilogSummaryArtifactContract.validateReport</c>: the analyzer's canonical
    /// report for exactly this source, internally consistent.</summary>
    public static bool ValidateReport(ReadOnlySpan<byte> bytes, string sourceSha256, long sourceByteCount)
    {
        if (bytes.Length > MaximumOutputBytes || Parse(bytes) is not JsonObject root || DecodeAnalysis(root) is not { } result) return false;
        if (!CanonicalJson.Encode(result.Encode()).AsSpan().SequenceEqual(bytes)) return false;
        if (result.SchemaVersion != "1.0.0" || result.AnalyzerRef != AnalyzerRef || result.AnalyzerVersion != AnalyzerVersion
            || result.Scope != "default-hilog-header-lines" || result.Redaction != "content-and-identifiers-omitted"
            || result.SourceSha256 != sourceSha256 || result.SourceByteCount != sourceByteCount
            || result.SourceByteCount <= 0 || result.SourceByteCount > MaximumInputBytes
            || result.LineCount < 1 || result.LineCount > result.SourceByteCount
            || result.BlankLineCount < 0 || result.BlankLineCount > result.LineCount
            || result.UnrecognizedLineCount < 0 || result.UnrecognizedLineCount > result.LineCount
            || result.LevelCounts.Count != Levels.Length || !Levels.All(result.LevelCounts.ContainsKey)
            || !result.LevelCounts.Values.All(v => v >= 0 && v <= result.LineCount))
        {
            return false;
        }
        var recognized = result.LevelCounts.Values.Sum();
        return recognized + result.BlankLineCount + result.UnrecognizedLineCount == result.LineCount
               && result.HeaderCoverage == Coverage(result.LineCount, result.BlankLineCount, result.UnrecognizedLineCount);
    }

    /// <summary>Swift <c>HilogSummaryArtifactContract.coverage</c>.</summary>
    public static string Coverage(long lines, long blanks, long unknown)
    {
        if (lines == blanks) return "empty";
        if (unknown == lines - blanks) return "unrecognized";
        return unknown == 0 ? "complete" : "partial";
    }

    private static JsonValue? Parse(ReadOnlySpan<byte> bytes)
    {
        try
        {
            return StrictJson.Parse(bytes);
        }
        catch (MalformedJsonException)
        {
            return null;
        }
    }

    private sealed record Analysis(
        string SchemaVersion, string AnalyzerRef, string AnalyzerVersion, string Scope, string Redaction, string SourceSha256,
        long SourceByteCount, string HeaderCoverage, long LineCount, long BlankLineCount, long UnrecognizedLineCount,
        IReadOnlyDictionary<string, long> LevelCounts)
    {
        // Swift's synthesized Codable keys, encoded as CanonicalJSONEncoders.canonical() does
        // (sorted keys; JsonObject orders its members).
        public JsonObject Encode() => new(new Dictionary<string, JsonValue>(StringComparer.Ordinal)
        {
            ["schemaVersion"] = new JsonString(SchemaVersion),
            ["analyzerRef"] = new JsonString(AnalyzerRef),
            ["analyzerVersion"] = new JsonString(AnalyzerVersion),
            ["scope"] = new JsonString(Scope),
            ["redaction"] = new JsonString(Redaction),
            ["sourceSHA256"] = new JsonString(SourceSha256),
            ["sourceByteCount"] = JsonNumber.FromInt64(SourceByteCount),
            ["headerCoverage"] = new JsonString(HeaderCoverage),
            ["lineCount"] = JsonNumber.FromInt64(LineCount),
            ["blankLineCount"] = JsonNumber.FromInt64(BlankLineCount),
            ["unrecognizedLineCount"] = JsonNumber.FromInt64(UnrecognizedLineCount),
            ["levelCounts"] = new JsonObject(LevelCounts.Select(p => new KeyValuePair<string, JsonValue>(p.Key, JsonNumber.FromInt64(p.Value)))),
        });
    }

    private sealed record Derived(string SourceArtifactId, string AnalyzerExecutableSha256, string AnalyzerOutputSha256, long AnalyzerOutputByteCount, Analysis Result)
    {
        public JsonObject Encode() => new(new Dictionary<string, JsonValue>(StringComparer.Ordinal)
        {
            ["sourceArtifactID"] = new JsonString(SourceArtifactId),
            ["analyzerExecutableSHA256"] = new JsonString(AnalyzerExecutableSha256),
            ["analyzerOutputSHA256"] = new JsonString(AnalyzerOutputSha256),
            ["analyzerOutputByteCount"] = JsonNumber.FromInt64(AnalyzerOutputByteCount),
            ["result"] = Result.Encode(),
        });
    }

    // Swift JSONDecoder over the Codable types: every member present with its type (an Int is a
    // 64-bit integer), unknown members ignored (the canonical re-encoding then refuses them).
    private static string? Text(JsonObject o, string key) => DiagnosticSessionOfflineInspector.Text(o, key);

    private static long? Integer(JsonObject o, string key) =>
        o.TryGetValue(key, out var v) && v is JsonNumber n && n.TryGetInt64(out var value) ? value : null;

    private static Analysis? DecodeAnalysis(JsonObject o)
    {
        if (Text(o, "schemaVersion") is not { } schema || Text(o, "analyzerRef") is not { } analyzer
            || Text(o, "analyzerVersion") is not { } version || Text(o, "scope") is not { } scope
            || Text(o, "redaction") is not { } redaction || Text(o, "sourceSHA256") is not { } source
            || Integer(o, "sourceByteCount") is not { } sourceBytes
            || Text(o, "headerCoverage") is not { } coverage || !Coverages.Contains(coverage)
            || Integer(o, "lineCount") is not { } lines || Integer(o, "blankLineCount") is not { } blanks
            || Integer(o, "unrecognizedLineCount") is not { } unknown
            || !o.TryGetValue("levelCounts", out var l) || l is not JsonObject levels)
        {
            return null;
        }
        var counts = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var (key, value) in levels.Members)
        {
            if (value is not JsonNumber n || !n.TryGetInt64(out var count)) return null;
            counts[key] = count;
        }
        return new(schema, analyzer, version, scope, redaction, source, sourceBytes, coverage, lines, blanks, unknown, counts);
    }

    private static Derived? DecodeDerived(JsonObject o) =>
        Text(o, "sourceArtifactID") is { } source && Text(o, "analyzerExecutableSHA256") is { } executable
        && Text(o, "analyzerOutputSHA256") is { } output && Integer(o, "analyzerOutputByteCount") is { } count
        && o.TryGetValue("result", out var r) && r is JsonObject result && DecodeAnalysis(result) is { } analysis
            ? new(source, executable, output, count, analysis)
            : null;

    private static bool IsIdentifier(string value) =>
        value.Length is > 0 and <= 200 && value.All(c => c is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '-' or '.' or '_');

    private static bool IsDigest(string value) => DiagnosticDigest.IsLowercaseSha256(value);
}
