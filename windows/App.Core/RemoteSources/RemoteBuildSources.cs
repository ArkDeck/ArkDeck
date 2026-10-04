using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using ArkDeck.App.Core.Presentation;

namespace ArkDeck.App.Core.RemoteSources;

// Remote build sources (macOS RemoteBuildSourceApplicationFacade.swift) are deliberately
// narrower than a terminal. The App can save one SSH endpoint, list directories below one
// canonical build root and read one bounded native library. No API here accepts a command,
// executable, argv, environment or write-capable SFTP flag.

public enum RemoteBuildSourceAuthentication
{
    Password,
    PrivateKey,
}

/// <summary>The secret a probe uses (macOS <c>RemoteBuildSourceCredentialInput</c>).</summary>
public abstract record RemoteBuildSourceCredentialInput
{
    private RemoteBuildSourceCredentialInput() { }

    public sealed record Password(string Value) : RemoteBuildSourceCredentialInput;

    public sealed record PrivateKey(byte[] Key, string? Passphrase) : RemoteBuildSourceCredentialInput;

    /// <summary>ArkDeck's bounded subset of OpenSSH's default identity files
    /// (<c>%USERPROFILE%\.ssh\id_rsa</c>, then <c>id_ed25519</c>). No SSH config, agent,
    /// known-hosts file or other path is read.</summary>
    public sealed record SystemDefault(string? Passphrase) : RemoteBuildSourceCredentialInput;
}

public sealed record RemoteBuildSourceDraft(
    Guid? Id,
    string Name,
    string Host,
    int Port,
    string Username,
    string RootPath,
    RemoteBuildSourceAuthentication Authentication);

public sealed record RemoteBuildSourcePresentation(
    Guid Id,
    string Name,
    string Host,
    int Port,
    string Username,
    string RootPath,
    RemoteBuildSourceAuthentication Authentication,
    string HostKeyFingerprint,
    bool CredentialStored,
    bool UsesSystemDefaultCredential,
    DateTimeOffset LastVerifiedAt)
{
    public string Endpoint => $"{Username}@{Host}:{Port.ToString(CultureInfo.InvariantCulture)}";
}

/// <summary>An explicit association created by a person's remote-artifact selection: identifiers
/// only; credentials and remote paths stay in their own stores.</summary>
public sealed record RemoteBuildSourceBindingPresentation(string TargetId, Guid SourceId, DateTimeOffset BoundAt);

/// <summary>A successful, short-lived connection probe. Its trust token is the provider's; the
/// App cannot make one, and saving consumes it exactly once.</summary>
public sealed record RemoteBuildSourceProbe(
    Guid Id,
    string SourceName,
    string Endpoint,
    string RootPath,
    string CanonicalRootPath,
    string HostKeyFingerprint,
    bool RequiresNewHostTrust,
    DateTimeOffset VerifiedAt)
{
    internal Guid TrustToken { get; init; }
}

public enum RemoteBuildEntryKind
{
    Directory,
    NativeLibrary,
}

public sealed record RemoteBuildDirectoryEntry(string Name, string RelativePath, RemoteBuildEntryKind Kind, ulong? ByteCount, DateTimeOffset? ModifiedAt);

public sealed record RemoteBuildDirectoryListing(Guid SourceId, string SourceName, string RelativePath, IReadOnlyList<RemoteBuildDirectoryEntry> Entries);

public sealed record RemoteBuildNativeLibraryArtifact(Guid SourceId, string SourceName, string RelativePath, string FileName, int ByteCount, string Sha256)
{
    internal byte[] Contents { get; init; } = [];
}

/// <summary>The macOS <c>RemoteBuildSourceError</c> cases (the App shows each through the
/// catalogue's <c>windows.remoteSources.error.&lt;code&gt;</c>).</summary>
public enum RemoteBuildSourceErrorCode
{
    InvalidName,
    InvalidHost,
    InvalidPort,
    InvalidUsername,
    InvalidRoot,
    InvalidCredential,
    SystemCredentialUnavailable,
    SourceNotFound,
    CredentialUnavailable,
    ProbeExpired,
    HostKeyChanged,
    RootChanged,
    PathOutsideRoot,
    TooManyEntries,
    InvalidLibraryName,
    InvalidLibrarySize,
    FileChanged,
    ConnectionFailed,
    CredentialStoreFailed,
    StorageFailed,
}

public sealed class RemoteBuildSourceException(RemoteBuildSourceErrorCode code, string? detail = null)
    : Exception(detail is null ? code.ToString() : $"{code}: {detail}")
{
    public RemoteBuildSourceErrorCode Code { get; } = code;

    /// <summary>The transport's own words (<c>connectionFailed</c>) or the Credential Manager
    /// status (<c>credentialStoreFailed</c>).</summary>
    public string? Detail { get; } = detail;

    /// <summary>The catalogue key of the code's message.</summary>
    public string MessageKey => "windows.remoteSources.error." + char.ToLowerInvariant(Code.ToString()[0]) + Code.ToString()[1..];
}

/// <summary>macOS <c>RemoteBuildSourceBounds</c>: what a source, a credential and a path may be.</summary>
public static partial class RemoteBuildSourceBounds
{
    public const int MaximumPasswordBytes = 4_096;
    public const int MaximumKeyBytes = 256 * 1_024;
    public const int MaximumPassphraseBytes = 4_096;

    [GeneratedRegex(@"^[A-Za-z0-9._:-]+$")]
    private static partial Regex HostPattern();

    [GeneratedRegex(@"^[A-Za-z0-9._-]{1,64}$")]
    private static partial Regex UsernamePattern();

    public static RemoteBuildSourceDraft Validate(RemoteBuildSourceDraft draft)
    {
        var name = Trim(draft.Name);
        if (name.Length == 0 || new StringInfo(name).LengthInTextElements > 80) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidName);
        var host = Trim(draft.Host).ToLowerInvariant();
        if (host.Length == 0 || host.Length > 255 || !HostPattern().IsMatch(host)) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidHost);
        if (draft.Port is < 1 or > 65_535) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidPort);
        var username = Trim(draft.Username);
        if (!UsernamePattern().IsMatch(username)) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidUsername);
        return draft with { Name = name, Host = host, Username = username, RootPath = AbsoluteRoot(draft.RootPath) };
    }

    internal static RemoteBuildCredentialEnvelope Credential(RemoteBuildSourceCredentialInput input, RemoteBuildSourceAuthentication authentication)
    {
        switch (input, authentication)
        {
            case (RemoteBuildSourceCredentialInput.Password password, RemoteBuildSourceAuthentication.Password):
            {
                var secret = Encoding.UTF8.GetBytes(password.Value);
                if (secret.Length is 0 or > MaximumPasswordBytes) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential);
                return new(RemoteBuildSourceAuthentication.Password, secret, null, RemoteBuildCredentialOrigin.Provided);
            }
            case (RemoteBuildSourceCredentialInput.PrivateKey key, RemoteBuildSourceAuthentication.PrivateKey):
            {
                if (key.Key.Length is 0 or > MaximumKeyBytes) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential);
                return new(RemoteBuildSourceAuthentication.PrivateKey, key.Key, Passphrase(key.Passphrase), RemoteBuildCredentialOrigin.Provided);
            }
            case (RemoteBuildSourceCredentialInput.SystemDefault system, RemoteBuildSourceAuthentication.PrivateKey):
                return new(RemoteBuildSourceAuthentication.PrivateKey, [], Passphrase(system.Passphrase), RemoteBuildCredentialOrigin.SystemDefault);
            default:
                throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential);
        }
    }

    private static byte[]? Passphrase(string? passphrase)
    {
        var bytes = passphrase is null ? null : Encoding.UTF8.GetBytes(passphrase);
        if (bytes is { Length: > MaximumPassphraseBytes }) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential);
        return bytes is { Length: 0 } ? null : bytes;
    }

    public static string AbsoluteRoot(string value)
    {
        var trimmed = Trim(value);
        if (!trimmed.StartsWith('/') || trimmed == "/" || Encoding.UTF8.GetByteCount(trimmed) > 1_024 || HasControl(trimmed))
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidRoot);
        }
        var parts = trimmed.Split('/');
        if (parts[0].Length != 0 || parts.Skip(1).Any(p => p.Length == 0 || p == "." || p == ".."))
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidRoot);
        }
        return "/" + string.Join('/', parts.Skip(1));
    }

    public static string Component(string value)
    {
        if (value.Length == 0 || value == "." || value == ".." || Encoding.UTF8.GetByteCount(value) > 255 || value.Contains('/') || HasControl(value))
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.PathOutsideRoot);
        }
        return value;
    }

    public static string RelativePath(string value, bool allowEmpty)
    {
        if (Encoding.UTF8.GetByteCount(value) > 2_048 || value.StartsWith('/')) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.PathOutsideRoot);
        if (value.Length == 0)
        {
            return allowEmpty ? "" : throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.PathOutsideRoot);
        }
        return string.Join('/', value.Split('/').Select(Component));
    }

    public static string Append(string @base, string component) => @base.Length == 0 ? component : $"{@base}/{component}";

    public static string Join(string root, string relative) => relative.Length == 0 ? root : $"{root}/{relative}";

    public static bool IsContained(string path, string root) => path == root || path.StartsWith(root + "/", StringComparison.Ordinal);

    /// <summary>The macOS lib*.so rule (<c>DebugTypedValueValidator.isValidNativeLibraryLogicalName</c>).</summary>
    public static bool IsNativeLibraryName(string name) => DebugOperations.IsValidNativeLibraryName(name);

    /// <summary>Swift's <c>trimmingCharacters(in: .whitespacesAndNewlines)</c>.</summary>
    internal static string Trim(string value) => value.Trim();

    /// <summary>NUL or a character of Swift's <c>CharacterSet.controlCharacters</c> (Cc and Cf).</summary>
    internal static bool HasControl(string value)
    {
        foreach (var rune in value.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (rune.Value == 0 || category is UnicodeCategory.Control or UnicodeCategory.Format) return true;
        }
        return false;
    }

    /// <summary>The macOS display order of names (<c>localizedStandardCompare</c>: case-insensitive,
    /// digits by value).</summary>
    public static int NaturalCompare(string a, string b) =>
        string.Compare(a, b, CultureInfo.InvariantCulture, CompareOptions.IgnoreCase | CompareOptions.NumericOrdering);
}
