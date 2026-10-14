using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.ClientKit.Transport;

/// <summary>The Rust PeerImageAccess scope: synchronous access to a packaged peer's
/// executable namespace, with the same user and elevation. Never spans an await or runs
/// caller code, signature verification or protocol work.</summary>
internal ref struct PeerImageAccess
{
    private SafeAccessTokenHandle? _token;
    private readonly uint _threadId;

    private PeerImageAccess(SafeAccessTokenHandle token)
    {
        _token = token;
        _threadId = Native.GetCurrentThreadId();
    }

    internal static PeerImageAccess Enter(SafeProcessHandle process)
    {
        var hasToken = Native.OpenThreadToken(Native.GetCurrentThread(), Native.TOKEN_QUERY, true, out var existing);
        var error = Marshal.GetLastPInvokeError();
        existing.Dispose();
        if (hasToken) throw new UnauthorizedAccessException("peer image access cannot replace a thread identity");
        if (error != Native.ERROR_NO_TOKEN) throw new Win32Exception(error);

        if (!Native.OpenProcessToken(process, Native.TOKEN_QUERY | Native.TOKEN_DUPLICATE, out var token))
        {
            error = Marshal.GetLastPInvokeError();
            token.Dispose();
            throw new Win32Exception(error);
        }
        try
        {
            using var current = ProcessToken.Open();
            if (!ProcessToken.User(token).Equals(ProcessToken.User(current))
                || ProcessToken.Elevated(token) != ProcessToken.Elevated(current))
            {
                throw new UnauthorizedAccessException("peer image access requires the same user and elevation");
            }
            if (!Native.ImpersonateLoggedOnUser(token)) throw new Win32Exception(Marshal.GetLastPInvokeError());
            return new PeerImageAccess(token);
        }
        catch
        {
            token.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (_token is null) return;
        // Continuing on a different thread or after a failed revert would leak the
        // peer's authority. There is no safe recovery inside this process.
        if (Native.GetCurrentThreadId() != _threadId || !Native.RevertToSelf())
        {
            Environment.FailFast("could not revert peer image access on its originating thread");
        }
        _token.Dispose();
        _token = null;
    }
}
