using System.ComponentModel;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using ArkDeck.ClientKit.Json;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.App.Core.Presentation;

/// <summary>What the person approves before a diagnostic bundle is written (macOS
/// <c>RuntimeSupportBundlePreview</c>).</summary>
public sealed record SupportBundlePreview(string Destination, string ScopeSha256, IReadOnlyList<string> IncludedEntries, long EstimatedBytes,
    bool DeviceRawExcluded, string SensitiveDataWarning);

/// <summary>A refusal, with the code the Rust CLI's <c>runtime support-bundle</c> names.</summary>
public sealed class SupportBundleException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

/// <summary>
/// The local diagnostic bundle of Settings › Diagnostics (macOS
/// <c>RuntimeSupportBundleApplicationFacade</c> over <c>LocalDiagnosticBundleExporter</c>, and
/// the Rust CLI's <c>support_bundle.rs</c>): a new folder of three documents —
/// <c>metadata.json</c> (the App's name, version, build, Windows version and architecture),
/// <c>hdc/tool-placeholder.json</c> (redacted and unverified states only; HDC is never probed)
/// and <c>bundle.json</c> (the manifest). It reads no Runtime storage, log or file: no device
/// data, Session, journal, Artifact or secret can reach it. The preview writes nothing and names
/// the scope's digest, which binds the destination, its parent folder's identity and every
/// entry's bytes; the export recomputes it and writes only for that exact digest, never over an
/// existing folder.
/// </summary>
public static class SupportBundle
{
    /// <summary>Swift's fixed warning, as it ships (kept as the Rust CLI keeps it).</summary>
    public const string SensitiveDataWarning = "诊断包包含 App 日志和结构化 Job 摘要；设备 raw 默认排除，分享前仍应检查预览。";

    /// <summary>Swift <c>LocalDiagnosticBundleExporter.defaultMaximumBundleBytes</c>.</summary>
    public const long MaximumBytes = 32 * 1024 * 1024;

    public static SupportBundlePreview Preview(string destination) => Prepare(destination).Preview;

    /// <summary>Writes the bundle the person approved; the scope must still be
    /// <paramref name="approvedScope"/>.</summary>
    public static SupportBundlePreview Export(string destination, string approvedScope)
    {
        var prepared = Prepare(destination);
        if (prepared.Preview.ScopeSha256 != approvedScope)
        {
            throw new SupportBundleException("previewDrifted", "the support-bundle scope differs from the approved preview; preview it again");
        }
        var parent = Path.GetDirectoryName(prepared.Preview.Destination)!;
        var staging = Path.Combine(parent, $".arkdeck-bundle-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(Path.Combine(staging, "hdc"));
            foreach (var (path, bytes) in prepared.Entries.Append(("bundle.json", prepared.Manifest)))
            {
                using var file = new FileStream(Path.Combine(staging, path.Replace('/', Path.DirectorySeparatorChar)), FileMode.CreateNew, FileAccess.Write);
                file.Write(bytes);
                file.Flush(flushToDisk: true);
            }
            // The scope again just before publication: the folder appears whole or not at all.
            if (Prepare(destination).Preview.ScopeSha256 != approvedScope)
            {
                throw new SupportBundleException("previewDrifted", "the support-bundle scope differs from the approved preview; preview it again");
            }
            Directory.Move(staging, prepared.Preview.Destination);
            return prepared.Preview;
        }
        catch (IOException) when (Directory.Exists(prepared.Preview.Destination) || File.Exists(prepared.Preview.Destination))
        {
            throw new SupportBundleException("resourceConflict", "the support-bundle destination already exists");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new SupportBundleException("ioFailure", "the support bundle could not be read or written safely");
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    private sealed record Prepared(SupportBundlePreview Preview, IReadOnlyList<(string Path, byte[] Bytes)> Entries, byte[] Manifest);

    private static Prepared Prepare(string destination)
    {
        if (string.IsNullOrWhiteSpace(destination) || !Path.IsPathFullyQualified(destination) || destination.StartsWith(@"\\", StringComparison.Ordinal))
        {
            throw new SupportBundleException("invalidInput", "the support-bundle destination is unsafe or invalid");
        }
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(destination));
        if (Directory.Exists(full) || File.Exists(full)) throw new SupportBundleException("resourceConflict", "the support-bundle destination already exists");
        var parent = Path.GetDirectoryName(full);
        if (parent is null || !Directory.Exists(parent)) throw new SupportBundleException("invalidInput", "the support-bundle destination is unsafe or invalid");
        var (volume, index) = Identity(parent);

        (string Path, byte[] Bytes)[] entries = [("metadata.json", Canonical(Metadata())), ("hdc/tool-placeholder.json", Canonical(Tool()))];
        var scope = new List<byte>(Encoding.UTF8.GetBytes($"{full}\nparent-device:{volume}\nparent-inode:{index}\n"));
        foreach (var (path, bytes) in entries.OrderBy(e => e.Path, StringComparer.Ordinal))
        {
            scope.AddRange(Encoding.UTF8.GetBytes(path));
            scope.Add(0);
            scope.AddRange(Encoding.UTF8.GetBytes(Sha256(bytes)));
            scope.Add((byte)'\n');
        }
        var digest = Sha256([.. scope]);
        var generated = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        long entryBytes = entries.Sum(e => (long)e.Bytes.Length);
        string[] included = [.. entries.Select(e => e.Path).Append("bundle.json").Order(StringComparer.Ordinal)];
        var estimated = entryBytes;
        // The manifest states the bundle's size, itself included: solved to a fixed point.
        for (var i = 0; i < 8; i++)
        {
            var preview = new JsonObject(
            [
                new("deviceRawExcluded", JsonBool.True),
                new("estimatedBytes", JsonNumber.FromInt64(estimated)),
                new("includedEntries", new JsonArray(included.Select(p => (JsonValue)new JsonString(p)))),
                new("scopeSHA256", new JsonString(digest)),
                new("sensitiveDataWarning", new JsonString(SensitiveDataWarning)),
            ]);
            var manifest = Canonical(new JsonObject(
            [
                new("automaticUploadEnabled", JsonBool.False),
                new("generatedAt", new JsonString(generated)),
                new("preview", preview),
                new("schemaVersion", new JsonString("1.0.0")),
                new("tool", Tool()),
            ]));
            var total = entryBytes + manifest.Length;
            if (total == estimated)
            {
                if (estimated > MaximumBytes) throw new SupportBundleException("quotaExceeded", "the support bundle exceeds its bounded export quota");
                return new(new(full, digest, included, estimated, true, SensitiveDataWarning), entries, manifest);
            }
            estimated = total;
        }
        throw new SupportBundleException("invalidInput", "the support-bundle destination is unsafe or invalid");
    }

    private static JsonObject Metadata()
    {
        var assembly = Assembly.GetEntryAssembly() ?? typeof(SupportBundle).Assembly;
        string Bounded(string? value) => string.IsNullOrEmpty(value) ? "development" : value.Length > 256 ? value[..256] : value;
        var version = Environment.OSVersion.Version;
        return new JsonObject(
        [
            new("appName", new JsonString("ArkDeck")),
            new("appVersion", new JsonString(Bounded(assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion))),
            new("architecture", new JsonString(RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.Arm64 => "arm64",
                Architecture.X64 => "x86_64",
                _ => "unknown",
            })),
            new("buildVersion", new JsonString(Bounded(assembly.GetName().Version?.ToString()))),
            new("platform", new JsonString($"Windows {version.Major}.{version.Minor}.{version.Build}")),
        ]);
    }

    private static JsonObject Tool() => new(
    [
        new("path", new JsonString("redacted")),
        new("serverEndpoint", new JsonString("redacted")),
        new("serverOwnership", new JsonString("unverified")),
        new("version", new JsonString("unverified")),
    ]);

    private static byte[] Canonical(JsonObject value) => Encoding.UTF8.GetBytes(value.ToString());

    private static string Sha256(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    /// <summary>The parent folder's volume serial number and file index (the counterpart of the
    /// macOS device and inode): a replaced folder of the same name is another scope.</summary>
    private static (uint Volume, ulong Index) Identity(string directory)
    {
        using var handle = CreateFile(directory, 0x80 /* FILE_READ_ATTRIBUTES */, 7 /* share all */, IntPtr.Zero, 3 /* OPEN_EXISTING */,
            0x02000000 /* FILE_FLAG_BACKUP_SEMANTICS */, IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info))
        {
            throw new SupportBundleException("invalidInput", "the support-bundle destination is unsafe or invalid: " + new Win32Exception(Marshal.GetLastWin32Error()).Message);
        }
        return (info.VolumeSerialNumber, ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow;
        public uint CreationTimeHigh;
        public uint LastAccessTimeLow;
        public uint LastAccessTimeHigh;
        public uint LastWriteTimeLow;
        public uint LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);
}
