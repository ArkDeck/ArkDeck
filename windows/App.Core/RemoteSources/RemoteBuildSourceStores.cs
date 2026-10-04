using System.Globalization;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ArkDeck.App.Core.RemoteSources;

/// <summary>A saved source (macOS <c>RemoteBuildSourceRecord</c>).</summary>
internal sealed record RemoteBuildSourceRecord(
    Guid Id,
    string Name,
    string Host,
    int Port,
    string Username,
    string RootPath,
    string CanonicalRootPath,
    RemoteBuildSourceAuthentication Authentication,
    string HostPublicKey,
    string HostKeyFingerprint,
    DateTimeOffset LastVerifiedAt);

internal sealed record RemoteBuildSourceBindingRecord(string TargetId, Guid SourceId, DateTimeOffset BoundAt);

internal enum RemoteBuildCredentialOrigin
{
    Provided,
    SystemDefault,
}

/// <summary>What Credential Manager keeps for one source (macOS
/// <c>RemoteBuildCredentialEnvelope</c>, the same JSON members: <c>authentication</c>,
/// <c>secret</c> and <c>passphrase</c> as base64, <c>origin</c>; a missing origin is a provided
/// secret).</summary>
internal sealed record RemoteBuildCredentialEnvelope(RemoteBuildSourceAuthentication Authentication, byte[] Secret, byte[]? Passphrase, RemoteBuildCredentialOrigin? Origin)
{
    public bool UsesSystemDefault => Origin == RemoteBuildCredentialOrigin.SystemDefault;

    public byte[] Encode()
    {
        var o = new JsonObject
        {
            ["authentication"] = Name(Authentication),
            ["origin"] = Origin is { } origin ? (origin == RemoteBuildCredentialOrigin.SystemDefault ? "systemDefault" : "provided") : null,
            ["passphrase"] = Passphrase is { } p ? Convert.ToBase64String(p) : null,
            ["secret"] = Convert.ToBase64String(Secret),
        };
        foreach (var key in o.Where(m => m.Value is null).Select(m => m.Key).ToArray()) o.Remove(key);
        return Encoding.UTF8.GetBytes(o.ToJsonString());
    }

    public static RemoteBuildCredentialEnvelope? Decode(byte[] data)
    {
        try
        {
            if (JsonNode.Parse(data) is not JsonObject o) return null;
            var authentication = Parse((string?)o["authentication"]);
            var origin = (string?)o["origin"] switch
            {
                null => (RemoteBuildCredentialOrigin?)null,
                "provided" => RemoteBuildCredentialOrigin.Provided,
                "systemDefault" => RemoteBuildCredentialOrigin.SystemDefault,
                _ => throw new FormatException("origin"),
            };
            var secret = Convert.FromBase64String((string?)o["secret"] ?? throw new FormatException("secret"));
            var passphrase = (string?)o["passphrase"] is { } p ? Convert.FromBase64String(p) : null;
            return authentication is { } a ? new(a, secret, passphrase, origin) : null;
        }
        catch (Exception error) when (error is JsonException or FormatException or InvalidOperationException)
        {
            return null;
        }
    }

    internal static string Name(RemoteBuildSourceAuthentication authentication) =>
        authentication == RemoteBuildSourceAuthentication.Password ? "password" : "privateKey";

    internal static RemoteBuildSourceAuthentication? Parse(string? name) => name switch
    {
        "password" => RemoteBuildSourceAuthentication.Password,
        "privateKey" => RemoteBuildSourceAuthentication.PrivateKey,
        _ => null,
    };
}

/// <summary>One line of the append-only audit (macOS <c>RemoteBuildAuditEvent</c>): the relative
/// path only as its SHA-256, never the path.</summary>
internal sealed record RemoteBuildAuditEvent(Guid EventId, Guid CorrelationId, string Phase, string Action, Guid? SourceId, string? RelativePathSha256, string? Outcome, DateTimeOffset ObservedAt);

internal interface IRemoteBuildSourceRecordStore
{
    IReadOnlyList<RemoteBuildSourceRecord> Load();

    void Replace(IReadOnlyList<RemoteBuildSourceRecord> records);
}

internal interface IRemoteBuildSourceBindingStore
{
    IReadOnlyList<RemoteBuildSourceBindingRecord> Load();

    void Replace(IReadOnlyList<RemoteBuildSourceBindingRecord> bindings);
}

internal interface IRemoteBuildSourceAudit
{
    void Append(RemoteBuildAuditEvent auditEvent);
}

/// <summary>
/// The App's own remote-source files (macOS <c>~/Library/Application Support/com.arkdeck.ArkDeck/
/// RemoteBuildSources</c>): <c>sources-v1.json</c>, <c>target-bindings-v1.json</c> and
/// <c>audit-v1.jsonl</c> under <c>%LOCALAPPDATA%\ArkDeck\App\RemoteBuildSources</c>, apart from the
/// Runtime's state. Each is owner-only (a protected DACL granting only this user, the counterpart
/// of mode 0600), written whole through a staging file and moved into place. JSON keys are sorted,
/// dates are ISO 8601 UTC to the second, identifiers are upper-case UUIDs, as Swift encodes them.
/// </summary>
internal sealed class RemoteBuildSourceFiles(string directory) : IRemoteBuildSourceRecordStore, IRemoteBuildSourceBindingStore, IRemoteBuildSourceAudit
{
    private readonly object _gate = new();

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ArkDeck", "App", "RemoteBuildSources");

    public string Directory => directory;

    private string Records => Path.Combine(directory, "sources-v1.json");

    private string Bindings => Path.Combine(directory, "target-bindings-v1.json");

    private string Audit => Path.Combine(directory, "audit-v1.jsonl");

    IReadOnlyList<RemoteBuildSourceRecord> IRemoteBuildSourceRecordStore.Load() => Read(Records, "records", row => new RemoteBuildSourceRecord(
        Uuid(row, "id"), Text(row, "name"), Text(row, "host"), Integer(row, "port"), Text(row, "username"), Text(row, "rootPath"),
        Text(row, "canonicalRootPath"),
        RemoteBuildCredentialEnvelope.Parse(Text(row, "authentication")) ?? throw new FormatException("authentication"),
        Text(row, "hostPublicKey"), Text(row, "hostKeyFingerprint"), Date(row, "lastVerifiedAt")));

    void IRemoteBuildSourceRecordStore.Replace(IReadOnlyList<RemoteBuildSourceRecord> records) => Write(Records, "records",
        records.OrderBy(r => r.Name, Comparer<string>.Create(RemoteBuildSourceBounds.NaturalCompare)).Select(r => new JsonObject
        {
            ["authentication"] = RemoteBuildCredentialEnvelope.Name(r.Authentication),
            ["canonicalRootPath"] = r.CanonicalRootPath,
            ["host"] = r.Host,
            ["hostKeyFingerprint"] = r.HostKeyFingerprint,
            ["hostPublicKey"] = r.HostPublicKey,
            ["id"] = UuidText(r.Id),
            ["lastVerifiedAt"] = DateText(r.LastVerifiedAt),
            ["name"] = r.Name,
            ["port"] = r.Port,
            ["rootPath"] = r.RootPath,
            ["username"] = r.Username,
        }));

    IReadOnlyList<RemoteBuildSourceBindingRecord> IRemoteBuildSourceBindingStore.Load() => Read(Bindings, "bindings", row =>
        new RemoteBuildSourceBindingRecord(Text(row, "targetID"), Uuid(row, "sourceID"), Date(row, "boundAt")));

    void IRemoteBuildSourceBindingStore.Replace(IReadOnlyList<RemoteBuildSourceBindingRecord> bindings) => Write(Bindings, "bindings",
        bindings.OrderBy(b => b.TargetId, StringComparer.Ordinal).Select(b => new JsonObject
        {
            ["boundAt"] = DateText(b.BoundAt),
            ["sourceID"] = UuidText(b.SourceId),
            ["targetID"] = b.TargetId,
        }));

    void IRemoteBuildSourceAudit.Append(RemoteBuildAuditEvent e)
    {
        var line = new JsonObject
        {
            ["action"] = e.Action,
            ["correlationID"] = UuidText(e.CorrelationId),
            ["eventID"] = UuidText(e.EventId),
            ["observedAt"] = DateText(e.ObservedAt),
            ["outcome"] = e.Outcome,
            ["phase"] = e.Phase,
            ["relativePathSHA256"] = e.RelativePathSha256,
            ["sourceID"] = e.SourceId is { } id ? UuidText(id) : null,
        };
        foreach (var key in line.Where(m => m.Value is null).Select(m => m.Key).ToArray()) line.Remove(key);
        var bytes = Encoding.UTF8.GetBytes(line.ToJsonString() + "\n");
        lock (_gate)
        {
            try
            {
                EnsureDirectory();
                if (!File.Exists(Audit))
                {
                    WriteWhole(Audit, bytes);
                    return;
                }
                using var stream = new FileStream(Audit, FileMode.Append, FileAccess.Write, FileShare.Read);
                stream.Write(bytes);
                stream.Flush(true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.StorageFailed);
            }
        }
    }

    private IReadOnlyList<T> Read<T>(string path, string member, Func<JsonObject, T> row)
    {
        lock (_gate)
        {
            if (!File.Exists(path)) return [];
            try
            {
                if (JsonNode.Parse(File.ReadAllBytes(path)) is not JsonObject envelope || Integer(envelope, "version") != 1)
                {
                    throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.StorageFailed);
                }
                return (envelope[member] as JsonArray ?? throw new FormatException(member))
                    .Select(item => row(item as JsonObject ?? throw new FormatException(member))).ToArray();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or FormatException
                                              or InvalidOperationException or KeyNotFoundException or OverflowException)
            {
                throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.StorageFailed);
            }
        }
    }

    private void Write(string path, string member, IEnumerable<JsonObject> rows)
    {
        var envelope = new JsonObject { [member] = new JsonArray(rows.ToArray<JsonNode?>()), ["version"] = 1 };
        lock (_gate)
        {
            try
            {
                EnsureDirectory();
                WriteWhole(path, Encoding.UTF8.GetBytes(envelope.ToJsonString()));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.StorageFailed);
            }
        }
    }

    private void EnsureDirectory()
    {
        if (System.IO.Directory.Exists(directory)) return;
        new DirectoryInfo(directory).Create(OwnerOnly.Directory());
    }

    /// <summary>Writes a whole owner-only file through a staging file beside it.</summary>
    private static void WriteWhole(string path, byte[] bytes)
    {
        var staging = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileInfo(staging).Create(FileMode.CreateNew, FileSystemRights.FullControl, FileShare.None, 4096, FileOptions.None, OwnerOnly.File()))
            {
                stream.Write(bytes);
                stream.Flush(true);
            }
            File.Move(staging, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(staging)) File.Delete(staging);
        }
    }

    private static string Text(JsonObject o, string key) => (string?)o[key] ?? throw new FormatException(key);

    private static int Integer(JsonObject o, string key) => (int?)o[key] ?? throw new FormatException(key);

    private static Guid Uuid(JsonObject o, string key) => Guid.Parse(Text(o, key));

    private static DateTimeOffset Date(JsonObject o, string key) =>
        DateTimeOffset.ParseExact(Text(o, key), "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);

    internal static string UuidText(Guid id) => id.ToString("D").ToUpperInvariant();

    internal static string DateText(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    internal static string PathDigest(string relativePath) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(relativePath)));
}

/// <summary>A protected DACL granting only the current user (the counterpart of mode 0600/0700).</summary>
internal static class OwnerOnly
{
    private static SecurityIdentifier User => WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("no user SID");

    public static FileSecurity File()
    {
        var security = new FileSecurity();
        security.SetOwner(User);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(User, FileSystemRights.FullControl, AccessControlType.Allow));
        return security;
    }

    public static DirectorySecurity Directory()
    {
        var security = new DirectorySecurity();
        security.SetOwner(User);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(User, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        return security;
    }

    /// <summary>True when the file grants nobody but its owner, the current user (macOS
    /// <c>st_uid == geteuid() &amp;&amp; mode &amp; 077 == 0</c>). SYSTEM and Administrators may
    /// keep access, as OpenSSH for Windows itself allows.</summary>
    public static bool IsPrivate(FileInfo file)
    {
        var acl = file.GetAccessControl();
        if (acl.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || owner != User) return false;
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow) continue;
            var sid = (SecurityIdentifier)rule.IdentityReference;
            if (sid == owner || sid.IsWellKnown(WellKnownSidType.LocalSystemSid) || sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid)) continue;
            return false;
        }
        return true;
    }
}
