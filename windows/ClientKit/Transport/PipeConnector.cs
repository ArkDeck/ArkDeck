using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.ClientKit.Transport;

/// <summary>Why the local Runtime is unavailable to this client. Every reason means that
/// no business frame was sent on the connection; the UI shows the recovery banner.</summary>
public enum DaemonUnavailableReason
{
    /// <summary>The endpoint is not a local ArkDeck named pipe.</summary>
    EndpointInvalid,

    /// <summary>No such pipe, every instance busy, or it could not be opened.</summary>
    EndpointUnavailable,

    /// <summary>Layer 1: the pipe object's owner SID is not this client's token owner SID.</summary>
    OwnerMismatch,

    /// <summary>Layer 2: the server process of this connection is not the installed daemon
    /// (image path, file identity, signer pin or package family).</summary>
    InstanceMismatch,

    /// <summary>The same-connection <c>health</c> preflight failed in transport.</summary>
    HealthExchangeFailed,

    /// <summary>The daemon's <c>health</c> does not describe this client's contract.</summary>
    ContractMismatch,

    /// <summary>The connection's time budget ran out before a business frame was sent.</summary>
    DeadlineExceeded,
}

/// <summary>The pipe server was not authenticated; nothing was written to it.</summary>
public sealed class ServerAuthenticationException(DaemonUnavailableReason reason, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public DaemonUnavailableReason Reason { get; } = reason;
}

/// <summary>
/// Opens the daemon's named pipe and authenticates its server before any byte is written
/// (design §F.2, the Rust <c>LocalConnection::connect</c>):
/// <list type="number">
/// <item>Open with <c>SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION</c>, so the server can
/// identify but not impersonate this client.</item>
/// <item>Layer 1, account: the pipe object's owner SID must equal this process token's owner
/// SID (the client half of .NET's <c>PipeOptions.CurrentUserOnly</c>; an elevated token's
/// owner is Administrators, so elevation is covered too).</item>
/// <item>Layer 2, instance: the connection's server PID (<c>GetNamedPipeServerProcessId</c>,
/// confirmed on a client handle by SPK-3), its process opened and held, its image the
/// installed daemon's path and file, signed by the pinned signer or publisher (maintainer
/// ruling 17) or in the installed package, and the PID unchanged afterwards.</item>
/// </list>
/// Any failure closes the handle having sent zero frames.
/// </summary>
public static class PipeConnector
{
    public static AuthenticatedPipe Connect(PipeEndpoint endpoint, DaemonIdentity expected) =>
        Connect(endpoint, expected, ProcessToken.Owner(), TimeSpan.Zero);

    /// <summary>As <see cref="Connect(PipeEndpoint, DaemonIdentity)"/>; while every instance of
    /// the pipe is busy (the server has not offered the next one yet: <c>ERROR_PIPE_BUSY</c>),
    /// the kernel's wait for a free instance is taken within <paramref name="wait"/>, as the
    /// Rust client's <c>connect_verified</c> does. Nothing is written while waiting.</summary>
    public static AuthenticatedPipe Connect(PipeEndpoint endpoint, DaemonIdentity expected, TimeSpan wait) =>
        Connect(endpoint, expected, ProcessToken.Owner(), wait);

    /// <summary>Tests substitute the expected owner to exercise the layer-1 refusal: a
    /// non-elevated account cannot create a pipe owned by another SID.</summary>
    internal static AuthenticatedPipe Connect(PipeEndpoint endpoint, DaemonIdentity expected, SecurityIdentifier expectedOwner) =>
        Connect(endpoint, expected, expectedOwner, TimeSpan.Zero);

    internal static AuthenticatedPipe Connect(PipeEndpoint endpoint, DaemonIdentity expected, SecurityIdentifier expectedOwner, TimeSpan wait)
    {
        // Read before anything is opened: a partial or malformed publisher identity refuses
        // whatever else is configured (maintainer ruling 17; the Rust verify_installed_image).
        try
        {
            SignerPins.Configured(expected);
        }
        catch (UnauthorizedAccessException error)
        {
            throw new ServerAuthenticationException(DaemonUnavailableReason.InstanceMismatch, error.Message, error);
        }
        var deadline = Environment.TickCount64 + (long)Math.Max(0, wait.TotalMilliseconds);
        SafeFileHandle file;
        while (true)
        {
            file = Native.CreateFile(endpoint.Name,
                Native.GENERIC_READ | Native.GENERIC_WRITE | Native.READ_CONTROL, 0, IntPtr.Zero, Native.OPEN_EXISTING,
                Native.FILE_FLAG_OVERLAPPED | Native.SECURITY_SQOS_PRESENT | Native.SECURITY_IDENTIFICATION, IntPtr.Zero);
            if (!file.IsInvalid) break;
            var code = Marshal.GetLastPInvokeError();
            file.Dispose();
            var left = deadline - Environment.TickCount64;
            if (code == Native.ERROR_PIPE_BUSY && left > 0 && Native.WaitNamedPipe(endpoint.Name, (uint)Math.Min(left, uint.MaxValue - 1)))
            {
                continue;
            }
            var error = new Win32Exception(code);
            throw new ServerAuthenticationException(DaemonUnavailableReason.EndpointUnavailable,
                $"the local Runtime endpoint is unavailable: {error.Message} (Win32 error {error.NativeErrorCode})", error);
        }
        ProcessIdentity? peer = null;
        try
        {
            RequirePipeOwner(file, expectedOwner);
            var pid = ServerPid(file);
            try
            {
                peer = ProcessIdentity.Open(pid);
                peer.RequireServer(expected);
            }
            catch (Exception error) when (error is UnauthorizedAccessException or Win32Exception or IOException)
            {
                throw new ServerAuthenticationException(DaemonUnavailableReason.InstanceMismatch, error.Message, error);
            }
            if (ServerPid(file) != pid)
            {
                throw new ServerAuthenticationException(DaemonUnavailableReason.InstanceMismatch,
                    "pipe server PID changed during authentication");
            }
            var pipe = new SafePipeHandle(file.DangerousGetHandle(), ownsHandle: true);
            file.SetHandleAsInvalid();
            var result = new AuthenticatedPipe(pipe, peer);
            peer = null;
            return result;
        }
        finally
        {
            peer?.Dispose();
            file.Dispose();
        }
    }

    private static void RequirePipeOwner(SafeFileHandle pipe, SecurityIdentifier expectedOwner)
    {
        var status = Native.GetSecurityInfo(pipe, Native.SE_KERNEL_OBJECT, Native.OWNER_SECURITY_INFORMATION,
            out var owner, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out var descriptor);
        try
        {
            if (status != Native.ERROR_SUCCESS)
            {
                var error = new Win32Exception((int)status);
                throw new ServerAuthenticationException(DaemonUnavailableReason.OwnerMismatch,
                    $"the pipe owner could not be read: {error.Message}; zero frames sent", error);
            }
            SecurityIdentifier actual;
            try
            {
                actual = ProcessToken.CopySid(owner);
            }
            catch (UnauthorizedAccessException error)
            {
                throw new ServerAuthenticationException(DaemonUnavailableReason.OwnerMismatch, error.Message, error);
            }
            if (!actual.Equals(expectedOwner))
            {
                throw new ServerAuthenticationException(DaemonUnavailableReason.OwnerMismatch,
                    "pipe owner SID differs from the client token owner; zero frames sent");
            }
        }
        finally
        {
            if (descriptor != IntPtr.Zero) Native.LocalFree(descriptor);
        }
    }

    private static uint ServerPid(SafeFileHandle pipe)
    {
        if (!Native.GetNamedPipeServerProcessId(pipe, out var pid))
        {
            var error = new Win32Exception(Marshal.GetLastPInvokeError());
            throw new ServerAuthenticationException(DaemonUnavailableReason.InstanceMismatch,
                $"connection process identity unavailable: {error.Message}; zero frames sent", error);
        }
        if (pid == 0)
        {
            throw new ServerAuthenticationException(DaemonUnavailableReason.InstanceMismatch,
                "connection process identity unavailable; zero frames sent");
        }
        return pid;
    }
}

/// <summary>
/// An authenticated connection to the daemon: the byte stream plus the pinned server
/// process, image and namespace handles, all released together. Every write first checks
/// that the authenticated process is still the one that was verified (the Rust
/// <c>LocalConnection::write</c>).
/// </summary>
public sealed class AuthenticatedPipe : Stream
{
    private readonly NamedPipeClientStream _stream;
    private readonly ProcessIdentity _peer;

    internal AuthenticatedPipe(SafePipeHandle pipe, ProcessIdentity peer)
    {
        _stream = new NamedPipeClientStream(PipeDirection.InOut, isAsync: true, isConnected: true, pipe);
        _peer = peer;
    }

    /// <summary>The process ID authenticated for this connection.</summary>
    public uint ServerProcessId => _peer.Pid;

    /// <summary>The canonical image path of the authenticated server.</summary>
    public string ServerImagePath => _peer.ImagePath;

    public override bool CanRead => true;

    public override bool CanSeek => false;

    public override bool CanWrite => true;

    public override long Length => throw new NotSupportedException();

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
        _stream.ReadAsync(buffer, cancellationToken);

    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        try
        {
            _peer.RequireLive();
        }
        catch (Exception error) when (error is UnauthorizedAccessException or Win32Exception)
        {
            return ValueTask.FromException(new TransportException(TransportErrorKind.PeerChanged, error.Message, error));
        }
        return _stream.WriteAsync(buffer, cancellationToken);
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer, offset, count).GetAwaiter().GetResult();

    public override void Write(byte[] buffer, int offset, int count) => WriteAsync(buffer, offset, count).GetAwaiter().GetResult();

    public override void Flush() { }

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _stream.Dispose();
            _peer.Dispose();
        }
        base.Dispose(disposing);
    }
}
