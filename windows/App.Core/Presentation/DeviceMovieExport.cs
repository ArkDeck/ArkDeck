using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.App.Core.Presentation;

/// <summary>Exports only the retained local movie bytes already measured by native composition.</summary>
public static class DeviceMovieExport
{
    public static async Task ExportAsync(string sourcePath, string destinationPath, long byteCount, string sha256)
    {
        if (byteCount is < 1 or > 512L * 1024 * 1024 || !ArtifactSummary.IsSha256(sha256))
            throw new InvalidDataException("The local movie receipt is invalid");
        var source = Path.GetFullPath(sourcePath);
        var destination = Path.GetFullPath(destinationPath);
        if (string.Equals(source, destination, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The export destination is the retained movie");
        // Open the leaf itself, refuse reparse/device/directory files, and deny writes/deletion
        // throughout hashing, copying and publication. No later pathname read supplies bytes.
        using var handle = OpenRegular(source);
        await using var input = new FileStream(handle, FileAccess.Read);
        if (input.Length != byteCount || Convert.ToHexStringLower(await SHA256.HashDataAsync(input)) != sha256)
            throw new InvalidDataException("The retained local movie changed after composition");
        input.Position = 0;
        RequireDestination(destination);
        var staging = Path.Combine(Path.GetDirectoryName(destination)!, $".arkdeck-movie-{Guid.NewGuid():N}.partial");
        var created = false;
        try
        {
            await using (var output = new FileStream(staging, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            {
                created = true;
                await input.CopyToAsync(output);
                output.Flush(flushToDisk: true);
                output.Position = 0;
                if (output.Length != byteCount || Convert.ToHexStringLower(await SHA256.HashDataAsync(output)) != sha256)
                    throw new InvalidDataException("The staged local movie differs from its receipt");
            }
            RequireDestination(destination);
            File.Move(staging, destination, overwrite: true);
        }
        finally
        {
            if (created)
            {
                try { File.Delete(staging); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }

    private static void RequireDestination(string path)
    {
        if (Directory.Exists(path) || (File.Exists(path) && (File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Device)) != 0))
            throw new IOException("The local movie destination is not a regular file");
    }

    private static SafeFileHandle OpenRegular(string path)
    {
        var handle = CreateFile(path, 0x80000000 /* GENERIC_READ */, 1 /* FILE_SHARE_READ */, IntPtr.Zero, 3 /* OPEN_EXISTING */,
            0x00200000 /* FILE_FLAG_OPEN_REPARSE_POINT */, IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var information)
            || (information.FileAttributes & (uint)(FileAttributes.ReparsePoint | FileAttributes.Directory | FileAttributes.Device)) != 0)
        {
            handle.Dispose();
            throw new IOException("The retained local movie is not an ordinary readable file");
        }
        return handle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow, CreationTimeHigh;
        public uint LastAccessTimeLow, LastAccessTimeHigh;
        public uint LastWriteTimeLow, LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh, FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);
}
