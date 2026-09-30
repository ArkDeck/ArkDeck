using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.ClientKit.Transport;

/// <summary>
/// The pipe server's process, pinned for the life of the connection (the Rust
/// <c>ProcessIdentity</c>): the process handle (so the PID cannot be recycled underneath
/// it), its image opened without write or delete sharing, and every ancestor directory of
/// the image opened without delete sharing, so neither the file nor a parent directory can
/// be exchanged while the connection lives.
/// </summary>
internal sealed class ProcessIdentity : IDisposable
{
    private readonly SafeProcessHandle _process;
    private readonly SafeFileHandle _image;
    private readonly List<SafeFileHandle> _namespace;

    private ProcessIdentity(SafeProcessHandle process, SafeFileHandle image, List<SafeFileHandle> held, uint pid, long started, string path)
    {
        _process = process;
        _image = image;
        _namespace = held;
        Pid = pid;
        Started = started;
        ImagePath = path;
    }

    public uint Pid { get; }

    public long Started { get; }

    /// <summary>The canonical (<c>\\?\X:\...</c>) image path.</summary>
    public string ImagePath { get; }

    public static ProcessIdentity Open(uint pid)
    {
        var process = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION | Native.SYNCHRONIZE, false, pid);
        if (process.IsInvalid) throw LastError();
        List<SafeFileHandle>? held = null;
        SafeFileHandle? image = null;
        try
        {
            var path = FileIdentity.Canonicalize(ProcessImage(process));
            held = FileIdentity.LockNamespace(path);
            image = FileIdentity.OpenLocked(path);
            var identity = new ProcessIdentity(process, image, held, pid, ProcessStarted(process), path);
            identity.RequireLive();
            return identity;
        }
        catch
        {
            image?.Dispose();
            held?.ForEach(h => h.Dispose());
            process.Dispose();
            throw;
        }
    }

    /// <summary>Still the same running process: not exited (an exit code of 259 is not
    /// taken for "still active") and the same creation time.</summary>
    public void RequireLive()
    {
        if (Native.WaitForSingleObject(_process, 0) != Native.WAIT_TIMEOUT || ProcessStarted(_process) != Started)
        {
            throw new UnauthorizedAccessException("authenticated peer process exited or changed");
        }
    }

    /// <summary>The Rust <c>require_server</c>: the image is the installed daemon (same
    /// canonical path and the same file), and it carries the installed package family or a
    /// trusted Authenticode signature whose signer certificate has the pinned SHA-256.</summary>
    public void RequireServer(DaemonIdentity expected)
    {
        if (!Path.IsPathFullyQualified(expected.ExecutablePath)
            || !string.Equals(FileIdentity.Canonicalize(ImagePath), FileIdentity.Canonicalize(expected.ExecutablePath), StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException("pipe server image differs from installed daemon; zero frames sent");
        }
        using (var installed = FileIdentity.OpenLocked(expected.ExecutablePath))
        {
            if (!FileIdentity.Of(installed).Equals(FileIdentity.Of(_image)))
            {
                throw new UnauthorizedAccessException("installed daemon file identity differs from server image");
            }
        }
        var packageMatches = expected.PackageFamily is { Length: > 0 } family && PackageFamily(_process) == family;
        var signatureMatches = expected.AuthenticodeSha256 is { } pin && Authenticode.SignerMatches(_image, ImagePath, pin);
        if (!packageMatches && !signatureMatches)
        {
            throw new UnauthorizedAccessException(
                "pipe server lacks the installed package or trusted signing identity; zero frames sent");
        }
        RequireLive();
    }

    public void Dispose()
    {
        _image.Dispose();
        foreach (var handle in _namespace) handle.Dispose();
        _process.Dispose();
    }

    private static unsafe string ProcessImage(SafeProcessHandle process)
    {
        var buffer = new char[32768];
        var length = (uint)buffer.Length;
        fixed (char* path = buffer)
        {
            if (!Native.QueryFullProcessImageName(process, 0, path, ref length)) throw LastError();
        }
        return new string(buffer, 0, (int)length);
    }

    private static long ProcessStarted(SafeProcessHandle process)
    {
        if (!Native.GetProcessTimes(process, out var creation, out _, out _, out _)) throw LastError();
        return creation;
    }

    private static unsafe string? PackageFamily(SafeProcessHandle process)
    {
        uint length = 0;
        var status = Native.GetPackageFamilyName(process, ref length, null);
        if (status != Native.ERROR_INSUFFICIENT_BUFFER || length == 0 || length > 4096) return null;
        var output = new char[length];
        fixed (char* name = output)
        {
            status = Native.GetPackageFamilyName(process, ref length, name);
        }
        return status == Native.ERROR_SUCCESS && length > 0 ? new string(output, 0, (int)length - 1) : null;
    }

    private static Win32Exception LastError() => new(Marshal.GetLastPInvokeError());
}

/// <summary>A file's volume serial number and 128-bit file id (<c>FILE_ID_INFO</c>): a name
/// no path spelling or rename changes.</summary>
internal readonly record struct FileIdentity(ulong Volume, UInt128 Index)
{
    public static unsafe FileIdentity Of(SafeFileHandle file)
    {
        if (!Native.GetFileInformationByHandleEx(file, Native.FileIdInfo, out var info, (uint)sizeof(Native.FILE_ID_INFO)))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError());
        }
        var bytes = new ReadOnlySpan<byte>(info.FileId, 16);
        return new FileIdentity(info.VolumeSerialNumber, System.Buffers.Binary.BinaryPrimitives.ReadUInt128LittleEndian(bytes));
    }

    /// <summary>Rust <c>std::fs::canonicalize</c> on Windows: open with no access and full
    /// sharing, then <c>GetFinalPathNameByHandleW</c> (DOS volume name, normalized).</summary>
    public static unsafe string Canonicalize(string path)
    {
        using var handle = Native.CreateFile(path, 0, Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE | Native.FILE_SHARE_DELETE,
            IntPtr.Zero, Native.OPEN_EXISTING, Native.FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastPInvokeError());
        var buffer = new char[512];
        while (true)
        {
            uint length;
            fixed (char* output = buffer)
            {
                length = Native.GetFinalPathNameByHandle(handle, output, (uint)buffer.Length, 0);
            }
            if (length == 0) throw new Win32Exception(Marshal.GetLastPInvokeError());
            if (length < buffer.Length) return new string(buffer, 0, (int)length);
            buffer = new char[length];
        }
    }

    /// <summary>Rust <c>open_locked_file</c>: read access, read-only sharing (no writer, no
    /// deletion while held), reparse points opened as themselves and refused.</summary>
    public static SafeFileHandle OpenLocked(string path)
    {
        var file = Native.CreateFile(path, Native.GENERIC_READ, Native.FILE_SHARE_READ, IntPtr.Zero,
            Native.OPEN_EXISTING, Native.FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastPInvokeError());
        if (!Native.GetFileInformationByHandle(file, out var info))
        {
            var error = new Win32Exception(Marshal.GetLastPInvokeError());
            file.Dispose();
            throw error;
        }
        if ((info.FileAttributes & (Native.FILE_ATTRIBUTE_REPARSE_POINT | Native.FILE_ATTRIBUTE_DIRECTORY)) != 0)
        {
            file.Dispose();
            throw new UnauthorizedAccessException("reparse points and directories cannot be executable identities");
        }
        return file;
    }

    /// <summary>Rust <c>lock_namespace</c>: every physical ancestor directory of a local
    /// drive path, from the root down, held without delete sharing; a reparse point or a
    /// non-directory among them is refused.</summary>
    public static List<SafeFileHandle> LockNamespace(string path)
    {
        var (root, rest) = SplitDrivePath(path);
        var parts = rest.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        var held = new List<SafeFileHandle>();
        try
        {
            // The root, then each parent of the image down to its own directory.
            var directory = root;
            held.Add(OpenDirectory(directory));
            for (var i = 0; i < parts.Length - 1; i++)
            {
                directory = Path.Join(directory, parts[i]);
                held.Add(OpenDirectory(directory));
            }
            return held;
        }
        catch
        {
            held.ForEach(h => h.Dispose());
            throw;
        }
    }

    private static (string Root, string Tail) SplitDrivePath(string path)
    {
        // Prefix::Disk (`C:\`) or Prefix::VerbatimDisk (`\\?\C:\`) only.
        var verbatim = path.StartsWith(@"\\?\", StringComparison.Ordinal);
        var drive = verbatim ? path[4..] : path;
        if (drive.Length < 3 || !char.IsAsciiLetter(drive[0]) || drive[1] != ':' || drive[2] != '\\')
        {
            throw new UnauthorizedAccessException("verified executable must be on an absolute local drive path");
        }
        var root = (verbatim ? @"\\?\" : string.Empty) + drive[..3];
        return (root, drive[3..]);
    }

    private static SafeFileHandle OpenDirectory(string directory)
    {
        var handle = Native.CreateFile(directory, Native.FILE_READ_ATTRIBUTES, Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE,
            IntPtr.Zero, Native.OPEN_EXISTING, Native.FILE_FLAG_BACKUP_SEMANTICS | Native.FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastPInvokeError());
        if (!Native.GetFileInformationByHandle(handle, out var info)
            || (info.FileAttributes & Native.FILE_ATTRIBUTE_DIRECTORY) == 0
            || (info.FileAttributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            handle.Dispose();
            throw new UnauthorizedAccessException("executable namespace contains a reparse point or non-directory");
        }
        return handle;
    }
}

/// <summary>The Rust <c>verify_signature</c>: <c>WinVerifyTrust</c> (generic verify v2, no
/// UI, whole-chain revocation from the cache only, root excluded) over the held image
/// handle, then the first signer's certificate DER must hash to the pin.</summary>
internal static class Authenticode
{
    public static bool SignerMatches(SafeFileHandle image, string path, string pin)
    {
        if (pin.Length != 64 || !pin.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')) return false;
        var pathMemory = Marshal.StringToHGlobalUni(path);
        var fileInfo = Marshal.AllocHGlobal(Marshal.SizeOf<Native.WINTRUST_FILE_INFO>());
        var addedReference = false;
        try
        {
            image.DangerousAddRef(ref addedReference);
            Marshal.StructureToPtr(new Native.WINTRUST_FILE_INFO
            {
                cbStruct = (uint)Marshal.SizeOf<Native.WINTRUST_FILE_INFO>(),
                pcwszFilePath = pathMemory,
                hFile = image.DangerousGetHandle(),
            }, fileInfo, false);
            var data = new Native.WINTRUST_DATA
            {
                cbStruct = (uint)Marshal.SizeOf<Native.WINTRUST_DATA>(),
                dwUIChoice = Native.WTD_UI_NONE,
                fdwRevocationChecks = Native.WTD_REVOKE_WHOLECHAIN,
                dwUnionChoice = Native.WTD_CHOICE_FILE,
                pFile = fileInfo,
                dwStateAction = Native.WTD_STATEACTION_VERIFY,
                dwProvFlags = Native.WTD_CACHE_ONLY_URL_RETRIEVAL | Native.WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
            };
            var action = Native.WINTRUST_ACTION_GENERIC_VERIFY_V2;
            var status = Native.WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            var verified = false;
            try
            {
                if (status == 0)
                {
                    var provider = Native.WTHelperProvDataFromStateData(data.hWVTStateData);
                    var signer = provider == IntPtr.Zero ? IntPtr.Zero : Native.WTHelperGetProvSignerFromChain(provider, 0, false, 0);
                    var certificate = signer == IntPtr.Zero ? IntPtr.Zero : Native.WTHelperGetProvCertFromChain(signer, 0);
                    // CRYPT_PROVIDER_CERT { DWORD cbStruct; PCCERT_CONTEXT pCert; ... }
                    var context = certificate == IntPtr.Zero ? IntPtr.Zero : Marshal.ReadIntPtr(certificate, IntPtr.Size);
                    if (context != IntPtr.Zero)
                    {
                        // CERT_CONTEXT { DWORD dwCertEncodingType; BYTE* pbCertEncoded; DWORD cbCertEncoded; ... }
                        var encoded = Marshal.ReadIntPtr(context, IntPtr.Size);
                        var length = Marshal.ReadInt32(context, 2 * IntPtr.Size);
                        if (encoded != IntPtr.Zero && length > 0)
                        {
                            var der = new byte[length];
                            Marshal.Copy(encoded, der, 0, length);
                            verified = Convert.ToHexStringLower(SHA256.HashData(der)) == pin;
                        }
                    }
                }
            }
            finally
            {
                data.dwStateAction = Native.WTD_STATEACTION_CLOSE;
                Native.WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            }
            return verified;
        }
        finally
        {
            if (addedReference) image.DangerousRelease();
            Marshal.DestroyStructure<Native.WINTRUST_FILE_INFO>(fileInfo);
            Marshal.FreeHGlobal(fileInfo);
            Marshal.FreeHGlobal(pathMemory);
        }
    }
}
