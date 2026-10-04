using System.Security.Cryptography;

namespace ArkDeck.App.Core.RemoteSources;

/// <summary>
/// The App's remote build sources (macOS <c>ProductionRemoteBuildSourceProvider</c> and
/// <c>ProductionRemoteBuildSourceBindingProvider</c>): saved SSH endpoints, a probe that verifies
/// the connection, the credential, the build root and the host key, a single-use trust token that
/// saving consumes, directory listings and one bounded native-library read below the canonical
/// root, the per-Target bindings, and an append-only audit that never holds a path. Everything
/// stays in the App: no Runtime call is made here.
/// </summary>
public sealed class RemoteBuildSourceProvider
{
    private static readonly TimeSpan ProbeLifetime = TimeSpan.FromMinutes(5);
    private const int MaximumEntries = 500;
    private const uint ReadChunkBytes = 512 * 1_024;
    private const ulong MinimumLibraryBytes = 64;
    private const ulong MaximumLibraryBytes = 64 * 1_024 * 1_024;

    private readonly IRemoteBuildSourceRecordStore _records;
    private readonly IRemoteBuildSourceBindingStore _bindings;
    private readonly IRemoteCredentialStore _credentials;
    private readonly IRemoteBuildSourceAudit _audit;
    private readonly ISftpConnector _connector;
    private readonly Func<DateTimeOffset> _now;
    private readonly Dictionary<Guid, (RemoteBuildSourceRecord Record, byte[] Credential, DateTimeOffset ExpiresAt)> _pending = [];
    private readonly SemaphoreSlim _gate = new(1, 1);

    internal RemoteBuildSourceProvider(IRemoteBuildSourceRecordStore records, IRemoteBuildSourceBindingStore bindings, IRemoteCredentialStore credentials,
        IRemoteBuildSourceAudit audit, ISftpConnector connector, Func<DateTimeOffset>? now = null)
    {
        _records = records;
        _bindings = bindings;
        _credentials = credentials;
        _audit = audit;
        _connector = connector;
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>The production provider: the App's files, Credential Manager and Windows'
    /// OpenSSH client, with <paramref name="askPassExecutable"/> (the App itself) answering
    /// prompts.</summary>
    public static RemoteBuildSourceProvider Create(string askPassExecutable, string? directory = null)
    {
        var files = new RemoteBuildSourceFiles(directory ?? RemoteBuildSourceFiles.DefaultDirectory);
        var credentials = directory is null ? new WindowsRemoteCredentialStore() : new WindowsRemoteCredentialStore(scope: "ArkDeck-fixture/app");
        return new RemoteBuildSourceProvider(files, files, credentials, files, new OpenSshConnector(askPassExecutable));
    }

    public Task<IReadOnlyList<RemoteBuildSourcePresentation>> ListSourcesAsync() => Locked<IReadOnlyList<RemoteBuildSourcePresentation>>(() =>
        Task.FromResult<IReadOnlyList<RemoteBuildSourcePresentation>>(_records.Load().Select(Presentation)
            .OrderBy(p => p.Name, Comparer<string>.Create(RemoteBuildSourceBounds.NaturalCompare)).ToArray()));

    public Task<RemoteBuildSourceProbe> ProbeAsync(RemoteBuildSourceDraft draft, RemoteBuildSourceCredentialInput? credential, CancellationToken cancellation = default) => Locked(async () =>
    {
        var normalized = RemoteBuildSourceBounds.Validate(draft);
        var existing = _records.Load().FirstOrDefault(r => r.Id == normalized.Id);
        var sourceId = normalized.Id ?? Guid.NewGuid();
        var envelope = CredentialForProbe(credential, existing, sourceId, normalized.Authentication);
        var expected = existing is not null && existing.Host == normalized.Host && existing.Port == normalized.Port ? existing.HostPublicKey : null;
        var correlation = Guid.NewGuid();
        Audit(correlation, "intent", "probe", normalized.Id, null, null);
        try
        {
            var (canonical, hostKey) = await WithSftpAsync(new SshEndpoint(normalized.Host, normalized.Port, normalized.Username), envelope, expected,
                (sftp, ct) => sftp.RealPathAsync(normalized.RootPath, ct), cancellation).ConfigureAwait(false);
            var record = new RemoteBuildSourceRecord(sourceId, normalized.Name, normalized.Host, normalized.Port, normalized.Username, normalized.RootPath,
                canonical, normalized.Authentication, hostKey, Fingerprint(hostKey), Second(_now()));
            var token = Guid.NewGuid();
            _pending[token] = (record, envelope.Encode(), _now() + ProbeLifetime);
            Audit(correlation, "outcome", "probe", sourceId, null, "confirmed");
            return new RemoteBuildSourceProbe(sourceId, record.Name, $"{record.Username}@{record.Host}:{record.Port}", record.RootPath, record.CanonicalRootPath,
                record.HostKeyFingerprint, expected is null, record.LastVerifiedAt) { TrustToken = token };
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            TryAudit(correlation, "outcome", "probe", normalized.Id, null, "failed");
            throw Map(error);
        }
    }, cancellation);

    public Task<RemoteBuildSourcePresentation> SaveAsync(RemoteBuildSourceProbe probe) => Locked(() =>
    {
        if (!_pending.Remove(probe.TrustToken, out var staged) || staged.Record.Id != probe.Id || staged.ExpiresAt <= _now())
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ProbeExpired);
        }
        var correlation = Guid.NewGuid();
        Audit(correlation, "intent", "save", staged.Record.Id, null, null);
        byte[]? previous = null;
        try
        {
            previous = _credentials.Read(staged.Record.Id);
        }
        catch (RemoteBuildSourceException)
        {
        }
        try
        {
            _credentials.Set(staged.Credential, staged.Record.Id);
            var all = _records.Load().Where(r => r.Id != staged.Record.Id).Append(staged.Record).ToArray();
            _records.Replace(all);
            TryAudit(correlation, "outcome", "save", staged.Record.Id, null, "confirmed");
            return Task.FromResult(Presentation(staged.Record));
        }
        catch (RemoteBuildSourceException)
        {
            try
            {
                if (previous is not null) _credentials.Set(previous, staged.Record.Id);
                else _credentials.Remove(staged.Record.Id);
            }
            catch (RemoteBuildSourceException)
            {
            }
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.StorageFailed);
        }
    });

    public Task RemoveAsync(Guid sourceId) => Locked(() =>
    {
        var old = _records.Load();
        if (old.All(r => r.Id != sourceId)) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.SourceNotFound);
        var correlation = Guid.NewGuid();
        Audit(correlation, "intent", "remove", sourceId, null, null);
        _credentials.Remove(sourceId);
        _records.Replace(old.Where(r => r.Id != sourceId).ToArray());
        TryAudit(correlation, "outcome", "remove", sourceId, null, "confirmed");
        return Task.FromResult(true);
    });

    public Task<RemoteBuildDirectoryListing> ListDirectoryAsync(Guid sourceId, string relativePath, CancellationToken cancellation = default) => Locked(async () =>
    {
        relativePath = RemoteBuildSourceBounds.RelativePath(relativePath, allowEmpty: true);
        var record = Record(sourceId);
        var credential = DecodedCredential(sourceId, record.Authentication);
        var correlation = Guid.NewGuid();
        Audit(correlation, "intent", "listDirectory", sourceId, relativePath, null);
        try
        {
            var (entries, _) = await WithSftpAsync(Endpoint(record), credential, record.HostPublicKey, async (sftp, ct) =>
            {
                var canonical = await ContainedAsync(sftp, record, relativePath, ct).ConfigureAwait(false);
                IReadOnlyList<SftpName> names;
                try
                {
                    names = await sftp.ListDirectoryAsync(canonical, MaximumEntries, ct).ConfigureAwait(false);
                }
                catch (InvalidDataException)
                {
                    throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.TooManyEntries);
                }
                var visible = names.Where(n => n.FileName is not ("." or "..")).ToArray();
                if (visible.Length > MaximumEntries) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.TooManyEntries);
                return visible.Select(n => Entry(n, relativePath)).OfType<RemoteBuildDirectoryEntry>()
                    .OrderBy(e => e.Kind == RemoteBuildEntryKind.Directory ? 0 : 1)
                    .ThenBy(e => e.Name, Comparer<string>.Create(RemoteBuildSourceBounds.NaturalCompare))
                    .ToArray();
            }, cancellation).ConfigureAwait(false);
            Audit(correlation, "outcome", "listDirectory", sourceId, relativePath, "confirmed");
            return new RemoteBuildDirectoryListing(sourceId, record.Name, relativePath, entries);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            TryAudit(correlation, "outcome", "listDirectory", sourceId, relativePath, "failed");
            throw Map(error);
        }
    }, cancellation);

    public Task<RemoteBuildNativeLibraryArtifact> FetchNativeLibraryAsync(Guid sourceId, string relativePath, CancellationToken cancellation = default) => Locked(async () =>
    {
        relativePath = RemoteBuildSourceBounds.RelativePath(relativePath, allowEmpty: false);
        var fileName = RemoteBuildSourceBounds.Component(relativePath.Split('/')[^1]);
        if (!RemoteBuildSourceBounds.IsNativeLibraryName(fileName)) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidLibraryName);
        var record = Record(sourceId);
        var credential = DecodedCredential(sourceId, record.Authentication);
        var correlation = Guid.NewGuid();
        Audit(correlation, "intent", "readNativeLibrary", sourceId, relativePath, null);
        try
        {
            var (contents, _) = await WithSftpAsync(Endpoint(record), credential, record.HostPublicKey, async (sftp, ct) =>
            {
                var canonical = await ContainedAsync(sftp, record, relativePath, ct).ConfigureAwait(false);
                await using var file = await sftp.OpenReadAsync(canonical, ct).ConfigureAwait(false);
                var before = await file.AttributesAsync(ct).ConfigureAwait(false);
                if (before.Size is not { } size || size < MinimumLibraryBytes || size > MaximumLibraryBytes)
                {
                    throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidLibrarySize);
                }
                var buffer = new MemoryStream((int)size);
                ulong offset = 0;
                while (offset < size)
                {
                    ct.ThrowIfCancellationRequested();
                    var chunk = await file.ReadAsync(offset, (uint)Math.Min(ReadChunkBytes, size - offset), ct).ConfigureAwait(false);
                    if (chunk.Length == 0) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.FileChanged);
                    buffer.Write(chunk);
                    offset += (ulong)chunk.Length;
                    if (offset > size) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.FileChanged);
                }
                var after = await file.AttributesAsync(ct).ConfigureAwait(false);
                if (after.Size != before.Size || after.ModifiedTime != before.ModifiedTime || buffer.Length != (long)size)
                {
                    throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.FileChanged);
                }
                return buffer.ToArray();
            }, cancellation).ConfigureAwait(false);
            var artifact = new RemoteBuildNativeLibraryArtifact(sourceId, record.Name, relativePath, fileName, contents.Length,
                Convert.ToHexStringLower(SHA256.HashData(contents))) { Contents = contents };
            Audit(correlation, "outcome", "readNativeLibrary", sourceId, relativePath, "confirmed");
            return artifact;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            TryAudit(correlation, "outcome", "readNativeLibrary", sourceId, relativePath, "failed");
            throw Map(error);
        }
    }, cancellation);

    // ---- bindings ----

    public Task<RemoteBuildSourceBindingPresentation?> BindingAsync(string targetId) => Locked(() =>
    {
        targetId = ValidatedTargetId(targetId);
        var binding = _bindings.Load().FirstOrDefault(b => b.TargetId == targetId);
        return Task.FromResult(binding is null ? null : new RemoteBuildSourceBindingPresentation(binding.TargetId, binding.SourceId, binding.BoundAt));
    });

    public Task BindAsync(Guid sourceId, string targetId) => Locked(() =>
    {
        targetId = ValidatedTargetId(targetId);
        if (_records.Load().All(r => r.Id != sourceId)) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.SourceNotFound);
        _bindings.Replace(_bindings.Load().Where(b => b.TargetId != targetId).Append(new RemoteBuildSourceBindingRecord(targetId, sourceId, Second(_now()))).ToArray());
        return Task.FromResult(true);
    });

    public Task UnbindAsync(string targetId) => Locked(() =>
    {
        targetId = ValidatedTargetId(targetId);
        _bindings.Replace(_bindings.Load().Where(b => b.TargetId != targetId).ToArray());
        return Task.FromResult(true);
    });

    // ---- internals ----

    private async Task<T> Locked<T>(Func<Task<T>> body, CancellationToken cancellation = default)
    {
        await _gate.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            return await body().ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private RemoteBuildSourceRecord Record(Guid sourceId) =>
        _records.Load().FirstOrDefault(r => r.Id == sourceId) ?? throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.SourceNotFound);

    private static SshEndpoint Endpoint(RemoteBuildSourceRecord record) => new(record.Host, record.Port, record.Username);

    private RemoteBuildCredentialEnvelope CredentialForProbe(RemoteBuildSourceCredentialInput? input, RemoteBuildSourceRecord? existing, Guid sourceId,
        RemoteBuildSourceAuthentication authentication)
    {
        if (input is not null) return RemoteBuildSourceBounds.Credential(input, authentication);
        if (existing?.Authentication == authentication) return DecodedCredential(sourceId, authentication);
        if (authentication == RemoteBuildSourceAuthentication.PrivateKey)
        {
            return RemoteBuildSourceBounds.Credential(new RemoteBuildSourceCredentialInput.SystemDefault(null), authentication);
        }
        throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialUnavailable);
    }

    private RemoteBuildCredentialEnvelope DecodedCredential(Guid sourceId, RemoteBuildSourceAuthentication expected)
    {
        var envelope = RemoteBuildCredentialEnvelope.Decode(_credentials.Read(sourceId));
        return envelope is not null && envelope.Authentication == expected
            ? envelope
            : throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialUnavailable);
    }

    /// <summary>The root's canonical path must still be the saved one, and the requested path's
    /// canonical path must lie inside it (no symbolic link leads out).</summary>
    private static async Task<string> ContainedAsync(SftpClient sftp, RemoteBuildSourceRecord record, string relativePath, CancellationToken cancellation)
    {
        var root = await sftp.RealPathAsync(record.RootPath, cancellation).ConfigureAwait(false);
        if (root != record.CanonicalRootPath) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.RootChanged);
        var canonical = await sftp.RealPathAsync(RemoteBuildSourceBounds.Join(record.RootPath, relativePath), cancellation).ConfigureAwait(false);
        return RemoteBuildSourceBounds.IsContained(canonical, root) ? canonical : throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.PathOutsideRoot);
    }

    private static RemoteBuildDirectoryEntry? Entry(SftpName name, string relativePath)
    {
        string component;
        try
        {
            component = RemoteBuildSourceBounds.Component(name.FileName);
        }
        catch (RemoteBuildSourceException)
        {
            return null;
        }
        var mode = name.Attributes.Permissions is { } p ? p & SftpAttributes.TypeMask : (uint?)null;
        RemoteBuildEntryKind kind;
        if (mode == SftpAttributes.Directory) kind = RemoteBuildEntryKind.Directory;
        else if (mode is null || mode == SftpAttributes.Regular)
        {
            if (!RemoteBuildSourceBounds.IsNativeLibraryName(component)) return null;
            kind = RemoteBuildEntryKind.NativeLibrary;
        }
        else return null;
        return new RemoteBuildDirectoryEntry(component, RemoteBuildSourceBounds.Append(relativePath, component), kind, name.Attributes.Size, name.Attributes.Modified);
    }

    private async Task<(T Value, string HostKey)> WithSftpAsync<T>(SshEndpoint endpoint, RemoteBuildCredentialEnvelope credential, string? expectedHostKey,
        Func<SftpClient, CancellationToken, Task<T>> operation, CancellationToken cancellation)
    {
        await using var connection = await _connector.ConnectAsync(endpoint, credential, expectedHostKey, cancellation).ConfigureAwait(false);
        var value = await operation(connection.Sftp, cancellation).ConfigureAwait(false);
        var observed = connection.ObservedHostKey
                       ?? throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ConnectionFailed, "the server offered no host key that can be pinned");
        if (expectedHostKey is not null && observed != expectedHostKey) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.HostKeyChanged);
        return (value, observed);
    }

    private RemoteBuildSourcePresentation Presentation(RemoteBuildSourceRecord record)
    {
        RemoteBuildCredentialEnvelope? credential = null;
        try
        {
            credential = DecodedCredential(record.Id, record.Authentication);
        }
        catch (RemoteBuildSourceException)
        {
        }
        return new RemoteBuildSourcePresentation(record.Id, record.Name, record.Host, record.Port, record.Username, record.RootPath, record.Authentication,
            record.HostKeyFingerprint, _credentials.Contains(record.Id), credential?.UsesSystemDefault == true, record.LastVerifiedAt);
    }

    /// <summary>macOS's fingerprint: <c>SHA256:</c> and the lower-case hex SHA-256 of the key blob
    /// (hex, not OpenSSH's base64 form).</summary>
    internal static string Fingerprint(string openSsh)
    {
        var parts = openSsh.Split(' ', 3);
        byte[] blob;
        try
        {
            blob = parts.Length > 1 ? Convert.FromBase64String(parts[1]) : System.Text.Encoding.UTF8.GetBytes(openSsh);
        }
        catch (FormatException)
        {
            blob = System.Text.Encoding.UTF8.GetBytes(openSsh);
        }
        return "SHA256:" + Convert.ToHexStringLower(SHA256.HashData(blob));
    }

    private static string ValidatedTargetId(string targetId)
    {
        var trimmed = RemoteBuildSourceBounds.Trim(targetId);
        if (trimmed != targetId || trimmed.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(trimmed) > 512 || RemoteBuildSourceBounds.HasControl(trimmed))
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.StorageFailed);
        }
        return trimmed;
    }

    private void Audit(Guid correlation, string phase, string action, Guid? sourceId, string? relativePath, string? outcome) =>
        _audit.Append(new RemoteBuildAuditEvent(Guid.NewGuid(), correlation, phase, action, sourceId,
            relativePath is null ? null : RemoteBuildSourceFiles.PathDigest(relativePath), outcome, Second(_now())));

    private void TryAudit(Guid correlation, string phase, string action, Guid? sourceId, string? relativePath, string? outcome)
    {
        try
        {
            Audit(correlation, phase, action, sourceId, relativePath, outcome);
        }
        catch (RemoteBuildSourceException)
        {
            // Outcome lines are best effort, as on macOS; the intent line was mandatory.
        }
    }

    private static Exception Map(Exception error) => error switch
    {
        RemoteBuildSourceException => error,
        SftpStatusException status => new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ConnectionFailed, status.Message),
        _ => new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ConnectionFailed, error.Message),
    };

    private static DateTimeOffset Second(DateTimeOffset at) => DateTimeOffset.FromUnixTimeSeconds(at.ToUnixTimeSeconds());
}

/// <summary>
/// The hand-off of a fetched remote library to the local native-library path (macOS
/// <c>prepareRemoteNativeLibrary</c>): its bytes, checked again against the size and SHA-256 the
/// read reported, are written to an owner-only temporary directory
/// (<c>arkdeck-remote-native-&lt;id&gt;\&lt;file name&gt;</c>), prepared from there like a local file,
/// and the directory is removed afterwards.
/// </summary>
public static class RemoteNativeLibraryStaging
{
    public static string Write(RemoteBuildNativeLibraryArtifact artifact)
    {
        var contents = artifact.Contents;
        if (contents.Length != artifact.ByteCount || Convert.ToHexStringLower(SHA256.HashData(contents)) != artifact.Sha256)
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.FileChanged);
        }
        var directory = new DirectoryInfo(Path.Combine(Path.GetTempPath(), "arkdeck-remote-native-" + Guid.NewGuid().ToString("N")));
        directory.Create(OwnerOnly.Directory());
        var file = Path.Combine(directory.FullName, RemoteBuildSourceBounds.Component(artifact.FileName));
        using (var stream = new FileInfo(file).Create(FileMode.CreateNew, System.Security.AccessControl.FileSystemRights.FullControl, FileShare.Read, 4096,
                   FileOptions.None, OwnerOnly.File()))
        {
            stream.Write(contents);
        }
        return file;
    }

    public static void Remove(string file)
    {
        try
        {
            if (Path.GetDirectoryName(file) is { } directory && Path.GetFileName(directory).StartsWith("arkdeck-remote-native-", StringComparison.Ordinal))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Left behind only when the file system refuses; it is owner-only.
        }
    }
}
