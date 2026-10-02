using System.Security.Cryptography;
using ArkDeck.App.Core.Daemon;
using System.Text.RegularExpressions;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>The receipt of a committed Import: the Artifact the Runtime published.</summary>
public sealed record ImportReceipt(string ArtifactId, string ArtifactDigest, string MediaType, string Privacy, string ValidationKind,
    string? Lease = null, JsonObject? Validation = null)
{
    /// <summary>A validation fact of the published bytes (a native library's <c>abi</c>,
    /// <c>elfClassBits</c>, <c>machine</c>, <c>buildId</c>), as the Runtime read them.</summary>
    public JsonValue? Fact(string key) => Validation is { } v && v.TryGetValue(key, out var value) ? value : null;
}

/// <summary>One Import (<c>artifact.import.begin|append|commit|abort|list|inspect</c>): its
/// intent, generation, state, the bytes received so far and, once committed, its receipt.</summary>
public sealed record ImportRecord(
    string ImportId,
    string ImportRequestId,
    string Kind,
    string Name,
    long ByteCount,
    string Sha256,
    string TargetId,
    string BindingRevision,
    string? DeviceProfile,
    long Generation,
    string State,
    long NextOffset,
    long MaximumChunkBytes,
    string CreatedAtUtc,
    ImportReceipt? Receipt)
{
    public static ImportRecord Parse(JsonValue value)
    {
        var o = Json.Object(value, "an Import");
        if (TypedJson.Required(o, "schemaVersion", TypedJson.String) != "arkdeck.import/1")
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "an Import of another schema");
        }
        var m = TypedJson.Required(o, "metadata", v => Json.Object(v, "Import metadata"));
        ImportReceipt? receipt = null;
        if (o.TryGetValue("receipt", out var r) && r is JsonObject ro)
        {
            receipt = new ImportReceipt(
                TypedJson.Required(ro, "artifactId", TypedJson.String),
                TypedJson.Required(ro, "artifactDigest", TypedJson.String),
                TypedJson.Required(ro, "mediaType", TypedJson.String),
                TypedJson.Required(ro, "privacy", TypedJson.String),
                TypedJson.Required(TypedJson.Required(ro, "validation", v => Json.Object(v, "validation")), "kind", TypedJson.String),
                Json.OptionalString(ro, "lease"),
                TypedJson.Required(ro, "validation", v => Json.Object(v, "validation")));
        }
        long Number(JsonObject from, string key) => long.Parse(TypedJson.Required(from, key, TypedJson.String), System.Globalization.CultureInfo.InvariantCulture);
        return new(
            TypedJson.Required(o, "importId", TypedJson.String),
            TypedJson.Required(o, "importRequestId", TypedJson.String),
            TypedJson.Required(m, "kind", TypedJson.String),
            TypedJson.Required(m, "name", TypedJson.String),
            Number(m, "byteCount"),
            TypedJson.Required(m, "sha256", TypedJson.String),
            TypedJson.Required(m, "targetId", TypedJson.String),
            TypedJson.Required(m, "bindingRevision", TypedJson.String),
            Json.NullableString(m, "deviceProfile"),
            Number(o, "generation"),
            TypedJson.Required(o, "state", TypedJson.String),
            Number(o, "nextOffset"),
            Number(o, "maximumChunkBytes"),
            TypedJson.Required(o, "createdAtUtc", TypedJson.String),
            receipt);
    }

    public static (IReadOnlyList<ImportRecord> Items, string? NextCursor) ParsePage(JsonValue value)
    {
        var page = Json.Object(value, "an Import page");
        var more = TypedJson.Required(page, "hasMore", TypedJson.Bool);
        var cursor = Json.NullableString(page, "nextCursor");
        if (more != cursor is not null) throw new ContractException(ContractErrorKind.SchemaMismatch, "a cursor without more rows, or more rows without a cursor");
        return (TypedJson.Required(page, "items", v => TypedJson.List(v, Parse)), cursor);
    }
}

/// <summary>The Import kinds and the macOS App's intent rules for them
/// (<c>ArtifactImportIntent</c>): the file name each accepts, its size bound and device profile.
/// A file outside them is not uploaded; the Runtime still checks its own rules.</summary>
public static partial class ImportKind
{
    public const string Hap = "hap";
    public const string NativeLibrary = "native-library";
    public const string WorkspacePatch = "workspace-patch";
    public const string FlashBundle = "flash-bundle";

    public static readonly IReadOnlyList<string> All = [Hap, NativeLibrary, WorkspacePatch, FlashBundle];

    public static string? DeviceProfile(string kind) => kind == FlashBundle ? "dayu200" : null;

    /// <summary>Null when the name and size suit the kind, else the macOS rule it breaks.</summary>
    public static string? Refusal(string kind, string name, long byteCount)
    {
        if (name.Length > 128 || !NameCharacters().IsMatch(name)) return "the file name must be at most 128 letters, digits, '.', '-' or '_'";
        return kind switch
        {
            Hap when !HapName().IsMatch(name) => "a HAP is a .hap or .hsp file",
            Hap when byteCount > 64L * 1024 * 1024 => "a HAP is at most 64 MiB",
            WorkspacePatch when !PatchName().IsMatch(name) => "a workspace patch is a .patch or .diff file",
            WorkspacePatch when byteCount > 512 * 1024 => "a workspace patch is at most 512 KiB",
            NativeLibrary when !LibraryName().IsMatch(name) => "a native library is a lib….so file",
            NativeLibrary when byteCount is < 64 or > 64L * 1024 * 1024 => "a native library is between 64 bytes and 64 MiB",
            FlashBundle when name != "images.tar.gz" => "a flash bundle is images.tar.gz",
            FlashBundle when byteCount > 8L * 1024 * 1024 * 1024 => "a flash bundle is at most 8 GiB",
            Hap or NativeLibrary or WorkspacePatch or FlashBundle => null,
            _ => "unknown Import kind",
        };
    }

    [GeneratedRegex("^[A-Za-z0-9._-]+$")]
    private static partial Regex NameCharacters();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]*\.(hap|hsp)$")]
    private static partial Regex HapName();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]*\.(patch|diff)$")]
    private static partial Regex PatchName();

    [GeneratedRegex(@"^lib[A-Za-z0-9_.-]+\.so$")]
    private static partial Regex LibraryName();
}

public sealed record ImportsState(Loaded<IReadOnlyList<ImportRecord>> Imports, Loaded<IReadOnlyList<TargetSummary>> Targets,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>How an upload ended: the committed Import, or why not (and whether the partial
/// Import was aborted).</summary>
public sealed record ImportOutcome(ImportRecord? Committed, Unavailable? Failure, bool Cancelled)
    : SurfaceState(
        Failure is { IsDaemonUnavailable: true } ? Failure.Failure : null,
        Committed is not null || Failure?.Failure is { Kind: not ControlFailureKind.DaemonUnavailable });

/// <summary>
/// Uploads one local file as an Import, as the macOS App does
/// (<c>RuntimeAppArtifactUpload.upload</c>): the file is read once to measure and digest it,
/// then kept open without write sharing while <c>artifact.import.begin</c>, bounded
/// <c>append</c> chunks (each with its SHA-256; the Runtime's offset checked after each) and
/// <c>commit</c> run. A failure or a cancellation before the commit aborts the Import (its own
/// generation, never replayed); a lost commit reply is left as it is, since the publication may
/// have happened. The file's bytes are the only thing sent; its path stays in the App.
/// </summary>
public sealed class ImportUploader(IControlChannel channel)
{
    public const int ChunkBytes = 512 * 1024;

    /// <summary>Uploads <paramref name="path"/>; <paramref name="name"/> names the Import when it is
    /// not the file's (a flash bundle is always <c>images.tar.gz</c>, as the macOS App uploads it).</summary>
    public async Task<ImportOutcome> UploadAsync(string path, string kind, TargetSummary target, IProgress<(long Sent, long Total)>? progress,
        CancellationToken cancellation, string? name = null)
    {
        name ??= Path.GetFileName(path);
        var requestId = "app-import-" + Guid.NewGuid().ToString("D");
        var cli = CliCommands.ForImport(kind);
        FileStream file;
        try
        {
            // Held without write sharing until the upload ends: the bytes cannot change under it.
            file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new(null, new Unavailable("invalidInput", error.Message, cli, null), false);
        }
        using (file)
        {
            if (ImportKind.Refusal(kind, name, file.Length) is { } rule) return new(null, new Unavailable("invalidInput", rule, cli, null), false);
            var total = file.Length;
            string digest;
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                var buffer = new byte[ChunkBytes];
                int read;
                try
                {
                    while ((read = await file.ReadAsync(buffer, cancellation).ConfigureAwait(false)) > 0) hash.AppendData(buffer, 0, read);
                }
                catch (OperationCanceledException)
                {
                    // Cancelled while measuring: nothing was sent, so there is nothing to abort.
                    return new(null, null, true);
                }
                digest = Convert.ToHexStringLower(hash.GetHashAndReset());
            }
            var intent = SurfaceLoader.Params(
                ("bindingRevision", new JsonString(target.BindingRevision.ToString(System.Globalization.CultureInfo.InvariantCulture))),
                ("byteCount", new JsonString(total.ToString(System.Globalization.CultureInfo.InvariantCulture))),
                ("deviceProfile", ImportKind.DeviceProfile(kind) is { } profile ? new JsonString(profile) : JsonNull.Instance),
                ("importRequestId", new JsonString(requestId)),
                ("kind", new JsonString(kind)),
                ("name", new JsonString(name)),
                ("schemaVersion", new JsonString("arkdeck.import-intent/1")),
                ("sha256", new JsonString(digest)),
                ("targetId", new JsonString(target.TargetId)));

            var begun = await Call("artifact.import.begin", intent, cli).ConfigureAwait(false);
            if (begun.Failure is not null)
            {
                // Begin may have persisted before its reply was lost: abort this request's own
                // first generation, as the macOS App does.
                await Abort(requestId, 1).ConfigureAwait(false);
                return new(null, begun.Failure, false);
            }
            var import = begun.Record!;
            if (import.State != "inProgress" || import.Generation != 1 || import.NextOffset != 0 || !SameIntent(import, kind, name, total, digest, target))
            {
                await Abort(requestId, import.Generation).ConfigureAwait(false);
                return new(null, new Unavailable(Unavailable.ResultUnreadableCode, "Runtime did not start the requested Import", cli, null), false);
            }
            try
            {
                file.Position = 0;
                var chunk = new byte[Math.Min(ChunkBytes, import.MaximumChunkBytes)];
                long offset = 0;
                progress?.Report((0, total));
                while (offset < total)
                {
                    cancellation.ThrowIfCancellationRequested();
                    var count = await file.ReadAsync(chunk.AsMemory(0, (int)Math.Min(chunk.Length, total - offset)), cancellation).ConfigureAwait(false);
                    if (count == 0) throw new IOException("the selected file changed during the Import");
                    var bytes = chunk.AsSpan(0, count);
                    var appended = await Call("artifact.import.append", SurfaceLoader.Params(
                        ("base64", new JsonString(Convert.ToBase64String(bytes))),
                        ("byteCount", new JsonString(count.ToString(System.Globalization.CultureInfo.InvariantCulture))),
                        ("generation", new JsonString(import.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture))),
                        ("importId", new JsonString(import.ImportId)),
                        ("offset", new JsonString(offset.ToString(System.Globalization.CultureInfo.InvariantCulture))),
                        ("sha256", new JsonString(Convert.ToHexStringLower(SHA256.HashData(bytes))))), cli).ConfigureAwait(false);
                    if (appended.Failure is { } failed)
                    {
                        await Abort(requestId, import.Generation).ConfigureAwait(false);
                        return new(null, failed, false);
                    }
                    var advanced = appended.Record!;
                    if (advanced.ImportId != import.ImportId || advanced.Generation != import.Generation || advanced.State != "inProgress"
                        || advanced.NextOffset != offset + count)
                    {
                        await Abort(requestId, import.Generation).ConfigureAwait(false);
                        return new(null, new Unavailable(Unavailable.ResultUnreadableCode, "Runtime Import offset or generation changed", cli, null), false);
                    }
                    offset = advanced.NextOffset;
                    progress?.Report((offset, total));
                }
                if (await file.ReadAsync(chunk.AsMemory(0, 1), cancellation).ConfigureAwait(false) != 0) throw new IOException("the selected file changed during the Import");
                cancellation.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException)
            {
                await Abort(requestId, import.Generation).ConfigureAwait(false);
                return new(null, null, true);
            }
            catch (IOException error)
            {
                await Abort(requestId, import.Generation).ConfigureAwait(false);
                return new(null, new Unavailable("invalidInput", error.Message, cli, null), false);
            }
            // A lost commit reply is an unknown publication: nothing is aborted or retried.
            var committed = await Call("artifact.import.commit", SurfaceLoader.Params(
                ("generation", new JsonString(import.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture))),
                ("importId", new JsonString(import.ImportId))), cli).ConfigureAwait(false);
            if (committed.Failure is { } refused) return new(null, refused, false);
            if (committed.Record is not { State: "committed", Receipt: not null } done || done.ImportId != import.ImportId)
            {
                return new(null, new Unavailable(Unavailable.ResultUnreadableCode, "Runtime returned no committed Import receipt", cli, null), false);
            }
            return new(done, null, false);
        }
    }

    private static bool SameIntent(ImportRecord import, string kind, string name, long total, string digest, TargetSummary target) =>
        import.Kind == kind && import.Name == name && import.ByteCount == total && import.Sha256 == digest && import.TargetId == target.TargetId
        && import.BindingRevision == target.BindingRevision.ToString(System.Globalization.CultureInfo.InvariantCulture);

    private async Task<(ImportRecord? Record, Unavailable? Failure)> Call(string method, JsonObject parameters, string cli)
    {
        var result = await channel.RequestAsync(method, parameters).ConfigureAwait(false);
        if (result.Failure is { } failure) return (null, Unavailable.From(failure, cli));
        try
        {
            return (ImportRecord.Parse(result.Value!), null);
        }
        catch (Exception error) when (error is ContractException or FormatException or InvalidCastException)
        {
            return (null, Unavailable.Unreadable(error, cli));
        }
    }

    private async Task Abort(string requestId, long generation) =>
        await channel.RequestAsync("artifact.import.abort", SurfaceLoader.Params(
            ("generation", new JsonString(generation.ToString(System.Globalization.CultureInfo.InvariantCulture))),
            ("importRequestId", new JsonString(requestId)))).ConfigureAwait(false);
}

public sealed partial class SurfaceLoader
{
    /// <summary>The Import page: every Import (<c>artifact.import.list</c>) and the adopted
    /// Targets a new Import is bound to (<c>target.list</c>).</summary>
    public async Task<ImportsState> ImportsAsync()
    {
        var run = new Run(channel);
        var imports = await run.LoadPages(async c =>
        {
            var items = new List<ImportRecord>();
            var cursors = new HashSet<string>(StringComparer.Ordinal);
            string? cursor = null;
            for (var page = 0; page < AgentPageLimit; page++)
            {
                var parameters = cursor is null
                    ? Params(("pageSize", JsonNumber.FromInt64(AgentPageSize)))
                    : Params(("pageSize", JsonNumber.FromInt64(AgentPageSize)), ("cursor", new JsonString(cursor)));
                var result = await c.RequestAsync("artifact.import.list", parameters).ConfigureAwait(false);
                if (result.Failure is { } failure) return ((IReadOnlyList<ImportRecord>?)null, failure);
                var (rows, next) = ImportRecord.ParsePage(result.Value!);
                items.AddRange(rows);
                if (next is null) return (items, null);
                if (!cursors.Add(next)) throw new ContractException(ContractErrorKind.SchemaMismatch, "artifact.import.list repeated a cursor");
                cursor = next;
            }
            throw new ContractException(ContractErrorKind.SchemaMismatch, $"artifact.import.list returned more than {AgentPageLimit} pages");
        }, CliCommands.ImportList);
        var targets = await run.Load(c => c.RequestAsync("target.list"), TargetSummary.ParseAll, CliCommands.TargetList);
        return new(imports, targets, run.DaemonFailure, run.Reached);
    }

    /// <summary>Uploads one file as an Import through this loader's channel (<see cref="ImportUploader"/>).</summary>
    public Task<ImportOutcome> UploadImportAsync(string path, string kind, TargetSummary target, IProgress<(long Sent, long Total)>? progress,
        CancellationToken cancellation) => new ImportUploader(channel).UploadAsync(path, kind, target, progress, cancellation);

    public Task<SessionActionState<ImportRecord>> ImportAsync(string importId) =>
        Action("artifact.import.inspect", Params(("importId", new JsonString(importId))), ImportRecord.Parse, CliCommands.ForImportId(CliCommands.ImportInspect, importId));

    /// <summary>Releases a committed Import's lease (<c>artifact.import.release</c>), guarded by
    /// the generation the App read.</summary>
    public Task<SessionActionState<ResumeAnswer>> ReleaseImportAsync(ImportRecord import) =>
        Action("artifact.import.release",
            Params(("generation", new JsonString(import.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture))), ("importId", new JsonString(import.ImportId))),
            ResumeAnswer.Parse, CliCommands.ForImportId(CliCommands.ImportRelease, import.ImportId));
}
