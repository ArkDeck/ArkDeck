using System.Security.Cryptography;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>How one Artifact export ended: the file written, or why nothing was. A daemon
/// that could not be reached is reported to the shell like any read.</summary>
public sealed record ExportOutcome(string? ExportedPath, Unavailable? Failure)
    : SurfaceState(
        Failure is { IsDaemonUnavailable: true } ? Failure.Failure : null,
        ExportedPath is not null || Failure?.Failure is { Kind: not ControlFailureKind.DaemonUnavailable })
{
    public bool Completed => ExportedPath is not null;

    public static ExportOutcome Done(string path) => new(path, null);

    public static ExportOutcome Failed(Unavailable why) => new(null, why);
}

/// <summary>
/// Exports one published Artifact of a Job to a file the person chose, as the macOS App does
/// (<c>RuntimeJobDetailXPCProvider.exportArtifact</c>): the bytes are read through
/// <c>artifact.read</c> in bounded chunks, each chunk checked against the Artifact's metadata
/// (the CLI's <c>validate_artifact_read</c>: same Artifact and digest, the offset asked for,
/// the byte count it claims, end of file exactly at the total), written to a staging file
/// beside the destination, and the SHA-256 of all of them must equal the Artifact's digest
/// before the staging file replaces the destination. The destination path stays in the App;
/// it is never sent to the Runtime. A sensitive Artifact is read only with the person's
/// explicit consent (<c>allowSensitive</c>).
/// </summary>
public sealed class ArtifactExporter(IControlChannel channel)
{
    /// <summary>The largest chunk asked for (the macOS App's bound).</summary>
    public const int ChunkBytes = 256 * 1024;

    public const string IntegrityCode = "artifactIntegrityFailed";
    public const string DestinationCode = "exportDestination";
    public const string NotPublishedCode = "artifactNotPublished";
    public const string SensitiveCode = "sensitiveAccessDenied";

    public async Task<ExportOutcome> ExportAsync(string jobId, ArtifactSummary artifact, string destination, bool allowSensitive,
        CancellationToken cancellation = default)
    {
        var cli = CliCommands.ArtifactReadForJob(jobId, artifact.ArtifactId);
        if (!artifact.IsPublished || artifact.Digest is null)
        {
            return ExportOutcome.Failed(new Unavailable(NotPublishedCode, "Only a published Artifact can be exported", cli, null));
        }
        if (artifact.IsSensitive && !allowSensitive)
        {
            return ExportOutcome.Failed(new Unavailable(SensitiveCode, "Sensitive Artifact export requires explicit opt-in", cli, null));
        }
        string full;
        try
        {
            full = Path.GetFullPath(destination);
            if (Directory.Exists(full) || (File.Exists(full) && File.GetAttributes(full).HasFlag(FileAttributes.ReparsePoint)))
            {
                return ExportOutcome.Failed(new Unavailable(DestinationCode, "The selected export destination is not a regular file", cli, null));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return ExportOutcome.Failed(new Unavailable(DestinationCode, error.Message, cli, null));
        }

        var staging = Path.Combine(Path.GetDirectoryName(full)!, $".{Path.GetFileName(full)}.arkdeck-export-{Guid.NewGuid():N}.partial");
        try
        {
            using (var file = new FileStream(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024))
            using (var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                long offset = 0;
                do
                {
                    cancellation.ThrowIfCancellationRequested();
                    var result = await channel.RequestAsync("artifact.read", SurfaceLoader.Params(
                        ("owner", SurfaceLoader.JobOwner(jobId)),
                        ("artifactId", new JsonString(artifact.ArtifactId)),
                        ("offset", JsonNumber.FromInt64(offset)),
                        ("maxBytes", JsonNumber.FromInt64(ChunkBytes)),
                        ("allowSensitive", JsonBool.Of(allowSensitive)))).ConfigureAwait(false);
                    if (result.Failure is { } failure) return ExportOutcome.Failed(Unavailable.From(failure, cli));
                    var bytes = Chunk(result.Value!, artifact, offset, out var next);
                    file.Write(bytes);
                    digest.AppendData(bytes);
                    offset = next;
                }
                while (offset < artifact.ByteCount);
                file.Flush(flushToDisk: true);
                var actual = Convert.ToHexStringLower(digest.GetHashAndReset());
                if (actual != artifact.Digest)
                {
                    return ExportOutcome.Failed(new Unavailable(IntegrityCode, "Exported Artifact SHA-256 does not match Runtime metadata", cli, null));
                }
            }
            if (File.Exists(full) && File.GetAttributes(full).HasFlag(FileAttributes.ReparsePoint))
            {
                return ExportOutcome.Failed(new Unavailable(DestinationCode, "The selected export destination is not a regular file", cli, null));
            }
            File.Move(staging, full, overwrite: true);
            return ExportOutcome.Done(full);
        }
        catch (ChunkException error)
        {
            return ExportOutcome.Failed(new Unavailable(IntegrityCode, error.Message, cli, null));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return ExportOutcome.Failed(new Unavailable(DestinationCode, error.Message, cli, null));
        }
        finally
        {
            try
            {
                if (File.Exists(staging)) File.Delete(staging);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Left behind only if the file system refuses the delete; it is never the destination.
            }
        }
    }

    /// <summary>Reads one published Artifact of a Job into memory through the same checked
    /// chunks (the macOS Viewer's <c>readArtifact</c>): the bytes, whose SHA-256 is the
    /// Artifact's digest, or why not.</summary>
    public async Task<(byte[]? Bytes, Unavailable? Failure)> ReadAsync(string jobId, ArtifactSummary artifact, bool allowSensitive,
        CancellationToken cancellation = default)
    {
        var cli = CliCommands.ArtifactReadForJob(jobId, artifact.ArtifactId);
        if (!artifact.IsPublished || artifact.Digest is null) return (null, new Unavailable(NotPublishedCode, "Only a published Artifact can be read", cli, null));
        if (artifact.IsSensitive && !allowSensitive) return (null, new Unavailable(SensitiveCode, "Sensitive Artifact read requires explicit opt-in", cli, null));
        using var buffer = new MemoryStream();
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        try
        {
            long offset = 0;
            while (offset < artifact.ByteCount)
            {
                cancellation.ThrowIfCancellationRequested();
                var result = await channel.RequestAsync("artifact.read", SurfaceLoader.Params(
                    ("owner", SurfaceLoader.JobOwner(jobId)),
                    ("artifactId", new JsonString(artifact.ArtifactId)),
                    ("offset", JsonNumber.FromInt64(offset)),
                    ("maxBytes", JsonNumber.FromInt64(ChunkBytes)),
                    ("allowSensitive", JsonBool.Of(allowSensitive)))).ConfigureAwait(false);
                if (result.Failure is { } failure) return (null, Unavailable.From(failure, cli));
                var bytes = Chunk(result.Value!, artifact, offset, out var next);
                buffer.Write(bytes);
                digest.AppendData(bytes);
                offset = next;
            }
        }
        catch (ChunkException error)
        {
            return (null, new Unavailable(IntegrityCode, error.Message, cli, null));
        }
        return Convert.ToHexStringLower(digest.GetHashAndReset()) == artifact.Digest
            ? (buffer.ToArray(), null)
            : (null, new Unavailable(IntegrityCode, "Artifact SHA-256 does not match Runtime metadata", cli, null));
    }

    /// <summary>One <c>artifact.read</c> chunk, checked as the CLI checks it.</summary>
    internal static byte[] Chunk(JsonValue value, ArtifactSummary artifact, long expectedOffset, out long nextOffset)
    {
        try
        {
            var o = Json.Object(value, "an Artifact chunk");
            var offset = TypedJson.Required(o, "offset", TypedJson.Int64);
            nextOffset = TypedJson.Required(o, "nextOffset", TypedJson.Int64);
            var total = TypedJson.Required(o, "totalByteCount", TypedJson.Int64);
            var count = TypedJson.Required(o, "byteCount", TypedJson.Int64);
            var eof = TypedJson.Required(o, "eof", TypedJson.Bool);
            var bytes = Convert.FromBase64String(TypedJson.Required(o, "base64", TypedJson.String));
            if (TypedJson.Required(o, "artifactId", TypedJson.String) != artifact.ArtifactId
                || TypedJson.Required(o, "artifactDigest", TypedJson.String) != artifact.Digest
                || total != artifact.ByteCount
                || offset != expectedOffset
                || offset > nextOffset
                || nextOffset > total
                || count != bytes.Length
                || nextOffset - offset != bytes.Length
                || bytes.Length > ChunkBytes
                || eof != (nextOffset == total)
                || (bytes.Length == 0 && !eof))
            {
                throw new ChunkException("Runtime Artifact chunk facts drifted during export");
            }
            return bytes;
        }
        catch (Exception error) when (error is ContractException or FormatException)
        {
            throw new ChunkException("Runtime returned an unreadable Artifact chunk: " + error.Message);
        }
    }

    private sealed class ChunkException(string message) : Exception(message);
}
