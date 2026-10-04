using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;

namespace ArkDeck.App.Core.RemoteSources;

/// <summary>Where a source's credential envelope is kept (macOS
/// <c>RemoteBuildCredentialStoring</c>).</summary>
internal interface IRemoteCredentialStore
{
    void Set(byte[] data, Guid account);

    /// <exception cref="RemoteBuildSourceException"><c>credentialUnavailable</c> when absent or
    /// empty, <c>credentialStoreFailed</c> on any other failure.</exception>
    byte[] Read(Guid account);

    bool Contains(Guid account);

    bool Remove(Guid account);
}

/// <summary>
/// The macOS Keychain item of a remote build source (generic password, service
/// <c>com.arkdeck.remote-build-source.v1</c>, account the source's lower-case UUID) kept in this
/// user's Windows Credential Manager, as the Runtime's credential owner keeps its Keychain items
/// (<c>arkdeck-platform</c> <c>windows/credential.rs</c>): generic credentials named
/// <c>ArkDeck/app/com.arkdeck.remote-build-source.v1/&lt;account&gt;</c>, the account also the
/// credential's user name, <c>CRED_PERSIST_LOCAL_MACHINE</c> (this user, this computer), every call
/// taking ArkDeck's per-user Credential Manager turn (<c>Local\ArkDeck.CredentialManager.&lt;SID&gt;</c>,
/// which the Runtime takes too), and a write read back before it counts.
/// <para>
/// A generic credential holds at most 2,560 bytes, and macOS keeps up to a 256 KiB key (or a 4 KiB
/// password) in one item. The envelope is therefore stored in parts: <c>…/&lt;account&gt;#&lt;n&gt;</c>
/// hold its bytes, and the credential named by the account holds a manifest
/// (<c>{"byteCount","parts","sha256","version":1}</c>) written last, so a reader sees the previous
/// value or the new one, never a mix; a read whose parts do not match the manifest's digest is
/// unavailable.
/// </para>
/// </summary>
internal sealed class WindowsRemoteCredentialStore(string service = WindowsRemoteCredentialStore.Service, string scope = "ArkDeck/app") : IRemoteCredentialStore
{
    public const string Service = "com.arkdeck.remote-build-source.v1";
    private const int PartBytes = 2_560;
    private const int MaximumParts = 256;

    private string Target(Guid account) => $"{scope}/{service}/{Account(account)}";

    private static string Account(Guid account) => account.ToString("D").ToLowerInvariant();

    public void Set(byte[] data, Guid account)
    {
        var parts = data.Chunk(PartBytes).ToArray();
        if (data.Length == 0 || parts.Length > MaximumParts) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential);
        var manifest = Encoding.UTF8.GetBytes(new JsonObject
        {
            ["byteCount"] = data.Length,
            ["parts"] = parts.Length,
            ["sha256"] = Convert.ToHexStringLower(SHA256.HashData(data)),
            ["version"] = 1,
        }.ToJsonString());
        using var turn = Turn.Take();
        var previous = ManifestParts(account);
        for (var i = 0; i < parts.Length; i++) Write($"{Target(account)}#{i + 1}", Account(account), parts[i]);
        Write(Target(account), Account(account), manifest);
        for (var i = parts.Length; i < previous; i++) Delete($"{Target(account)}#{i + 1}");
        if (!ReadUnlocked(account).AsSpan().SequenceEqual(data))
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialStoreFailed, "Credential Manager did not keep the written credential");
        }
    }

    public byte[] Read(Guid account)
    {
        using var turn = Turn.Take();
        return ReadUnlocked(account);
    }

    public bool Contains(Guid account)
    {
        using var turn = Turn.Take();
        try
        {
            return ReadUnlocked(account).Length > 0;
        }
        catch (RemoteBuildSourceException)
        {
            return false;
        }
    }

    public bool Remove(Guid account)
    {
        using var turn = Turn.Take();
        var parts = ManifestParts(account);
        var removed = Delete(Target(account));
        for (var i = 0; i < Math.Max(parts, 0); i++) Delete($"{Target(account)}#{i + 1}");
        return removed;
    }

    private byte[] ReadUnlocked(Guid account)
    {
        var manifestBytes = ReadOne(Target(account), Account(account)) ?? throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialUnavailable);
        var manifest = JsonNode.Parse(manifestBytes) as JsonObject;
        if (manifest is null || (int?)manifest["version"] != 1 || (int?)manifest["parts"] is not { } count || count is < 1 or > MaximumParts
            || (int?)manifest["byteCount"] is not { } byteCount || (string?)manifest["sha256"] is not { } digest)
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialUnavailable);
        }
        using var buffer = new MemoryStream();
        for (var i = 0; i < count; i++)
        {
            buffer.Write(ReadOne($"{Target(account)}#{i + 1}", Account(account)) ?? throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialUnavailable));
        }
        var data = buffer.ToArray();
        if (data.Length != byteCount || data.Length == 0 || Convert.ToHexStringLower(SHA256.HashData(data)) != digest)
        {
            throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialUnavailable);
        }
        return data;
    }

    private int ManifestParts(Guid account)
    {
        try
        {
            return ReadOne(Target(account), Account(account)) is { } bytes && JsonNode.Parse(bytes) is JsonObject o && (int?)o["parts"] is { } n and > 0 and <= MaximumParts ? n : 0;
        }
        catch (Exception error) when (error is System.Text.Json.JsonException or RemoteBuildSourceException or InvalidOperationException)
        {
            return 0;
        }
    }

    // ---- Credential Manager ----

    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    [StructLayout(LayoutKind.Sequential)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    private static void Write(string target, string user, byte[] blob)
    {
        var targetName = Marshal.StringToHGlobalUni(target);
        var userName = Marshal.StringToHGlobalUni(user);
        var bytes = Marshal.AllocHGlobal(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, bytes, blob.Length);
            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = targetName,
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = bytes,
                Persist = CredPersistLocalMachine,
                UserName = userName,
            };
            if (!CredWrite(ref credential, 0))
            {
                throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialStoreFailed, $"Credential Manager status {Marshal.GetLastPInvokeError()}");
            }
        }
        finally
        {
            Marshal.Copy(new byte[blob.Length], 0, bytes, blob.Length);
            Marshal.FreeHGlobal(bytes);
            Marshal.FreeHGlobal(targetName);
            Marshal.FreeHGlobal(userName);
        }
    }

    /// <summary>The blob of one credential, or null when it is absent or empty; a credential this
    /// store did not write (another user name, another persistence) is refused.</summary>
    private static byte[]? ReadOne(string target, string user)
    {
        if (!CredRead(target, CredTypeGeneric, 0, out var pointer))
        {
            var status = Marshal.GetLastPInvokeError();
            return status == ErrorNotFound ? null
                : throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialStoreFailed, $"Credential Manager status {status}");
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            if (Marshal.PtrToStringUni(credential.UserName) != user || credential.Persist != CredPersistLocalMachine)
            {
                throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialStoreFailed, "Credential Manager holds a credential ArkDeck did not write");
            }
            if (credential.CredentialBlobSize == 0) return null;
            var blob = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, blob, 0, blob.Length);
            Marshal.Copy(new byte[blob.Length], 0, credential.CredentialBlob, blob.Length);
            return blob;
        }
        finally
        {
            CredFree(pointer);
        }
    }

    private static bool Delete(string target)
    {
        if (CredDelete(target, CredTypeGeneric, 0)) return true;
        var status = Marshal.GetLastPInvokeError();
        return status == ErrorNotFound ? false
            : throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialStoreFailed, $"Credential Manager status {status}");
    }

    /// <summary>ArkDeck's per-user Credential Manager turn: Credential Manager loses updates
    /// when one user's credentials change concurrently (measured, TASK-XPA-005).</summary>
    private sealed class Turn : IDisposable
    {
        private readonly Mutex _mutex;

        private Turn(Mutex mutex) => _mutex = mutex;

        public static Turn Take()
        {
            var sid = WindowsIdentity.GetCurrent().User?.Value ?? throw new InvalidOperationException("no user SID");
            var mutex = new Mutex(false, $@"Local\ArkDeck.CredentialManager.{sid}");
            try
            {
                if (!mutex.WaitOne(TimeSpan.FromSeconds(30)))
                {
                    throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialStoreFailed, "Credential Manager turn timed out");
                }
            }
            catch (AbandonedMutexException)
            {
                // The previous holder ended without releasing; the turn is ours.
            }
            catch
            {
                mutex.Dispose();
                throw;
            }
            return new Turn(mutex);
        }

        public void Dispose()
        {
            _mutex.ReleaseMutex();
            _mutex.Dispose();
        }
    }
}
