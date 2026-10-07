using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.App.Core.Presentation;

/// <summary>A safe, App-local folder held against replacement while Explorer is opened.</summary>
public sealed class TraceLicenseFolder : IDisposable
{
    private readonly IReadOnlyList<SafeFileHandle> _handles;
    internal TraceLicenseFolder(string path, IReadOnlyList<SafeFileHandle> handles) => (Path, _handles) = (path, handles);
    public string Path { get; }
    public void Dispose()
    {
        foreach (var handle in _handles.Reverse()) handle.Dispose();
    }
}

/// <summary>Windows counterpart of pinned ArkTraceCore/IO/BoundedRegularFile.swift:
/// bounded bytes and metadata come from the same read-only, no-follow handle. Parent directories
/// are also held and checked, so neither a reparse path nor a renamed group can redirect a read.</summary>
internal static class TraceLicenseFiles
{
    internal const int ProductLimit = 32 * 1024;
    internal const int NoticesLimit = 128 * 1024;
    internal enum Document { Product, Notices }
    private const uint DirectoryAttribute = 0x10, ReparseAttribute = 0x400, DeviceAttribute = 0x40;
    private const uint OpenReparsePoint = 0x00200000, BackupSemantics = 0x02000000;
    private static readonly UTF8Encoding Utf8 = new(false, true);

    internal static TraceLicenseSnapshot Load(string appDirectory, Action? betweenDocuments = null)
    {
        try
        {
            // One retained source group spans both documents; a package/group replacement
            // between the two reads cannot produce a mixed license snapshot.
            using var group = Group.Open(appDirectory);
            var product = Read(group, Document.Product);
            betweenDocuments?.Invoke();
            var notices = Read(group, Document.Notices);
            using var folder = OpenLicenseFolder(appDirectory);
            group.Validate();
            return new(product, notices, folder is not null);
        }
        catch (Exception error) when (IsFileRefusal(error))
        {
            var unavailable = Unavailable(error);
            return new(unavailable, unavailable, false);
        }
    }

    internal static TraceLicenseText Read(string appDirectory, Document document, Action? afterOpen = null)
    {
        try
        {
            using var group = Group.Open(appDirectory);
            return Read(group, document, afterOpen);
        }
        catch (Exception error) when (IsFileRefusal(error)) { return Unavailable(error); }
    }

    private static TraceLicenseText Read(Group group, Document document, Action? afterOpen = null)
    {
        try
        {
            var name = document == Document.Product ? "LICENSE" : "THIRD_PARTY_NOTICES.md";
            var limit = document == Document.Product ? ProductLimit : NoticesLimit;
            var path = System.IO.Path.Combine(group.Path, name);
            using var file = Open(path, directory: false);
            var before = Snapshot(file);
            if ((before.Attributes & (DirectoryAttribute | ReparseAttribute | DeviceAttribute)) != 0 || GetFileType(file) != 1)
                throw new Refusal("nonRegularFile");
            if (before.Size == 0 || before.Size > (ulong)limit) throw new Refusal("invalidSize");
            if (!SamePath(FinalPath(file), path)) throw new Refusal("sourceChanged");
            afterOpen?.Invoke();
            var bytes = new byte[(int)before.Size];
            using var stream = new FileStream(file, FileAccess.Read);
            stream.ReadExactly(bytes);
            if (stream.ReadByte() != -1 || Snapshot(file) != before || !SamePath(FinalPath(file), path))
                throw new Refusal("sourceChanged");
            group.Validate();
            return new(TraceLicenseStatus.Available, Utf8.GetString(bytes));
        }
        catch (Exception error) when (IsFileRefusal(error)) { return Unavailable(error); }
    }

    private static bool IsFileRefusal(Exception error) => error is Refusal or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException;
    private static TraceLicenseText Unavailable(Exception error) => new(TraceLicenseStatus.Unavailable, Reason: error switch
    {
        Refusal refusal => refusal.Code,
        DecoderFallbackException => "invalidUtf8",
        _ => "unreadable",
    });

    internal static TraceLicenseFolder? OpenLicenseFolder(string appDirectory)
    {
        Group? group = null;
        try
        {
            group = Group.Open(appDirectory);
            group.Add("Licenses");
            group.Validate();
            return new(group.Path, group.TakeHandles());
        }
        catch (Exception error) when (error is Refusal or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        { return null; }
        finally { group?.Dispose(); }
    }

    private sealed class Refusal(string code) : Exception { public string Code { get; } = code; }
    private readonly record struct FileSnapshot(uint Attributes, uint Volume, ulong Index, ulong Size, ulong LastWrite, ulong Created);
    private readonly record struct DirectoryPin(SafeFileHandle Handle, string Path, FileSnapshot Snapshot);

    private sealed class Group : IDisposable
    {
        private readonly List<DirectoryPin> _directories = [];
        internal string Path => _directories[^1].Path;

        internal static Group Open(string appDirectory)
        {
            if (!OperatingSystem.IsWindows()) throw new Refusal("unsupportedHost");
            var root = CanonicalRoot(appDirectory);
            var group = new Group();
            try
            {
                group.AddAbsolute(root[..3], requireName: false);
                foreach (var component in root[3..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
                    group.AddAbsolute(System.IO.Path.Combine(group.Path, component), requireName: false);
                group.Add("ArkTrace");
                return group;
            }
            catch { group.Dispose(); throw; }
        }

        internal void Add(string name) => AddAbsolute(System.IO.Path.Combine(Path, name), requireName: true);

        private void AddAbsolute(string path, bool requireName)
        {
            var handle = TraceLicenseFiles.Open(path, directory: true);
            try
            {
                var snapshot = Snapshot(handle);
                if ((snapshot.Attributes & DirectoryAttribute) == 0 || (snapshot.Attributes & (ReparseAttribute | DeviceAttribute)) != 0)
                    throw new Refusal("unsafeDirectory");
                var final = FinalPath(handle);
                if (_directories.Count > 0 && !SamePath(System.IO.Path.GetDirectoryName(final)!, Path))
                    throw new Refusal("sourceChanged");
                if (requireName && !SamePath(final, path)) throw new Refusal("sourceChanged");
                _directories.Add(new(handle, final, snapshot));
            }
            catch { handle.Dispose(); throw; }
        }

        internal void Validate()
        {
            foreach (var pin in _directories)
            {
                var now = Snapshot(pin.Handle);
                if ((now.Attributes & DirectoryAttribute) == 0 || (now.Attributes & (ReparseAttribute | DeviceAttribute)) != 0
                    || now.Volume != pin.Snapshot.Volume || now.Index != pin.Snapshot.Index || !SamePath(FinalPath(pin.Handle), pin.Path))
                    throw new Refusal("sourceChanged");
            }
        }

        internal IReadOnlyList<SafeFileHandle> TakeHandles()
        {
            var handles = _directories.Select(d => d.Handle).ToArray();
            _directories.Clear();
            return handles;
        }
        public void Dispose()
        {
            foreach (var pin in _directories.AsEnumerable().Reverse()) pin.Handle.Dispose();
            _directories.Clear();
        }
    }

    // Only an absolute local drive directory is a resource root. Neither relative paths,
    // namespace/UNC paths, alternate streams nor traversal are App resource locations.
    private static string CanonicalRoot(string root)
    {
        if (string.IsNullOrWhiteSpace(root) || root.Length < 3 || !char.IsAsciiLetter(root[0]) || root[1] != ':' || root[2] != '\\'
            || root.Contains('/') || root[2..].Contains(':') || root.Contains('\0')) throw new Refusal("invalidRoot");
        if (root[3..].Split('\\').Any(p => p is "." or ".." || p.EndsWith('.') || p.EndsWith(' '))) throw new Refusal("invalidRoot");
        var full = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(root));
        if (!SamePath(full, System.IO.Path.TrimEndingDirectorySeparator(root))) throw new Refusal("invalidRoot");
        return full;
    }

    private static SafeFileHandle Open(string path, bool directory)
    {
        // Attribute-only opens do not participate in Windows delete sharing. Include
        // FILE_LIST_DIRECTORY (without enumerating) so retained directory handles really
        // deny rename/replacement. They still permit independent child writes.
        var handle = CreateFile(path, directory ? 0x81u : 0x80000000u, directory ? 3u : 1u, IntPtr.Zero, 3,
            OpenReparsePoint | BackupSemantics, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        throw new Refusal(error is 2 or 3 ? "missing" : "unreadable");
    }

    private static FileSnapshot Snapshot(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info)) throw new Refusal("unreadable");
        return new(info.Attributes, info.Volume, Pair(info.IndexHigh, info.IndexLow), Pair(info.SizeHigh, info.SizeLow),
            Pair(info.WriteHigh, info.WriteLow), Pair(info.CreateHigh, info.CreateLow));
    }

    private static ulong Pair(uint high, uint low) => ((ulong)high << 32) | low;

    private static string FinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(32768);
        var count = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        if (count == 0 || count >= buffer.Capacity) throw new Refusal("unreadable");
        var path = buffer.ToString();
        if (!path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.Length < 7 || path[5] != ':')
            throw new Refusal("invalidRoot");
        return System.IO.Path.TrimEndingDirectorySeparator(path[4..]);
    }

    private static bool SamePath(string left, string right) => string.Equals(left, right, StringComparison.OrdinalIgnoreCase);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes, CreateLow, CreateHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume,
            SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder name, uint size, uint flags);
    [DllImport("kernel32.dll")]
    private static extern uint GetFileType(SafeFileHandle handle);
}
