using System.Globalization;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>One Artifact of a Job as <c>artifact.list</c> projects it (the members the History
/// detail shows; the method schema validates the rest).</summary>
public sealed record ArtifactSummary(
    string ArtifactId,
    string OwnerKind,
    string OwnerId,
    string Name,
    string MediaType,
    string Privacy,
    string Status,
    long ByteCount,
    string? Digest,
    string SourceOperation,
    string ProviderId,
    string CreatedAtUtc)
{
    public const string SchemaVersion = "arkdeck.artifact/1";

    /// <summary>The raw Trace of a <c>trace.capture@1</c> Job, the one Artifact
    /// <c>trace.inspect</c> opens (macOS <c>TracePublishedArtifactPolicy.selectRawTrace</c>:
    /// name, media type, privacy, published, non-empty, a SHA-256).</summary>
    public const string TraceName = "trace.htrace";

    public const string TraceOperation = "trace.capture@1";

    public bool IsPublished => Status == "published";

    public bool IsSensitive => Privacy == "sensitive";

    public bool IsTrace => Name == TraceName && SourceOperation == TraceOperation && MediaType == "application/octet-stream"
                           && IsSensitive && IsPublished && ByteCount > 0 && Digest is not null;

    /// <summary>The exact byte count with invariant digit grouping (the catalogue's
    /// <c>windows.bytes</c> names the unit in each language).</summary>
    public string ByteCountText => ByteCount.ToString("N0", CultureInfo.InvariantCulture);

    /// <summary>One <c>artifact.list</c> page of the Job's Artifacts: every row an Artifact of
    /// that Job; <c>nextCursor</c> exactly when more rows follow.</summary>
    public static (IReadOnlyList<ArtifactSummary> Items, string? NextCursor) ParsePage(JsonValue value, string jobId)
    {
        var page = Json.Object(value, "an Artifact page");
        if (TypedJson.Required(page, "schemaVersion", TypedJson.String) != "arkdeck.cli.page/1")
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "an Artifact page of another schema");
        }
        var items = TypedJson.Required(page, "items", v => TypedJson.List(v, Parse));
        foreach (var item in items)
        {
            if (item.OwnerKind != "job" || item.OwnerId != jobId)
            {
                throw new ContractException(ContractErrorKind.SchemaMismatch, $"Artifact {item.ArtifactId} is not an Artifact of {jobId}");
            }
        }
        var more = TypedJson.Required(page, "hasMore", TypedJson.Bool);
        var cursor = Json.NullableString(page, "nextCursor");
        if (more != cursor is not null) throw new ContractException(ContractErrorKind.SchemaMismatch, "a cursor without more rows, or more rows without a cursor");
        return (items, cursor);
    }

    public static ArtifactSummary Parse(JsonValue value)
    {
        var o = Json.Object(value, "an Artifact");
        if (TypedJson.Required(o, "schemaVersion", TypedJson.String) != SchemaVersion)
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "an Artifact of another schema");
        }
        var owner = TypedJson.Required(o, "owner", v => Json.Object(v, "an Artifact owner"));
        var status = TypedJson.Required(o, "status", TypedJson.String);
        var digest = Json.NullableString(o, "artifactDigest");
        if (digest is not null && !IsSha256(digest)) throw new ContractException(ContractErrorKind.SchemaMismatch, "an Artifact digest is not a SHA-256");
        if (status == "published" && digest is null) throw new ContractException(ContractErrorKind.SchemaMismatch, "a published Artifact without a digest");
        var byteCount = TypedJson.Required(o, "byteCount", TypedJson.Int64);
        if (byteCount < 0) throw new ContractException(ContractErrorKind.SchemaMismatch, "a negative Artifact byte count");
        return new ArtifactSummary(
            TypedJson.Required(o, "artifactId", TypedJson.String),
            TypedJson.Required(owner, "kind", TypedJson.String),
            TypedJson.Required(owner, "id", TypedJson.String),
            TypedJson.Required(o, "name", TypedJson.String),
            TypedJson.Required(o, "mediaType", TypedJson.String),
            TypedJson.Required(o, "privacy", TypedJson.String),
            status,
            byteCount,
            digest,
            TypedJson.Required(o, "sourceOperation", TypedJson.String),
            TypedJson.Required(o, "providerId", TypedJson.String),
            TypedJson.Required(o, "createdAtUtc", TypedJson.String));
    }

    internal static bool IsSha256(string value) =>
        value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}

/// <summary>What <c>trace.inspect</c> reports about a Job's raw Trace: the Artifact it read,
/// the engine and parser that read it, the Trace's duration and capabilities, and the data
/// quality verdict, as the Runtime states them.</summary>
public sealed record TraceInspection(
    string ArtifactId,
    string SourceName,
    string EngineName,
    string EngineVersion,
    string ParserName,
    string ParserVersion,
    string DurationNs,
    IReadOnlyList<string> Capabilities,
    string DataQuality,
    int IssueCount,
    string StorageMode)
{
    public static TraceInspection Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Trace inspection");
        var source = TypedJson.Required(o, "source", v => Json.Object(v, "source"));
        var engine = TypedJson.Required(o, "engine", v => Json.Object(v, "engine"));
        var parser = TypedJson.Required(o, "parser", v => Json.Object(v, "parser"));
        var trace = TypedJson.Required(o, "trace", v => Json.Object(v, "trace"));
        var capabilities = TypedJson.Required(trace, "capabilities", v => Json.Object(v, "capabilities"));
        var quality = TypedJson.Required(o, "dataQuality", v => Json.Object(v, "dataQuality"));
        return new TraceInspection(
            TypedJson.Required(source, "artifactId", TypedJson.String),
            TypedJson.Required(source, "name", TypedJson.String),
            TypedJson.Required(engine, "name", TypedJson.String),
            TypedJson.Required(engine, "version", TypedJson.String),
            TypedJson.Required(parser, "name", TypedJson.String),
            TypedJson.Required(parser, "version", TypedJson.String),
            TypedJson.Required(trace, "durationNs", TypedJson.String),
            capabilities.Members.Where(m => m.Value is JsonBool { Value: true }).Select(m => m.Key).ToArray(),
            TypedJson.Required(quality, "status", TypedJson.String),
            TypedJson.Required(quality, "issues", v => v is JsonArray a ? a.Items.Count : throw new ContractException(ContractErrorKind.SchemaMismatch, "issues")),
            TypedJson.Required(o, "storageMode", TypedJson.String));
    }
}
