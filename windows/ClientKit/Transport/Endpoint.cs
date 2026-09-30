using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.ClientKit.Transport;

/// <summary>
/// The installed daemon this client may talk to: installation inputs, never values read
/// from the pipe (the Rust <c>ServerIdentity</c>). Windows requires the image path and at
/// least one of: the development signer certificate's SHA-256 (lowercase hex of its DER),
/// the production publisher identity (maintainer ruling 17: the leaf's subject
/// <c>O=</c> and its Artifact Signing certificate-profile EKU
/// <c>1.3.6.1.4.1.311.97.&lt;profile&gt;</c>, both or neither), or the exact MSIX package
/// family.
/// </summary>
public sealed record DaemonIdentity(string ExecutablePath, string? AuthenticodeSha256 = null, string? PackageFamily = null,
    string? PublisherOrganization = null, string? PublisherEku = null);

/// <summary>A local ArkDeck named pipe: <c>\\.\pipe\arkdeck-*</c>, at most 240 characters,
/// no further separators (the Rust <c>endpoint_name</c>).</summary>
public sealed record PipeEndpoint
{
    private const string PipePrefix = @"\\.\pipe\";

    public PipeEndpoint(string name)
    {
        if (!IsValid(name))
        {
            throw new ServerAuthenticationException(DaemonUnavailableReason.EndpointInvalid,
                "only a local ArkDeck named pipe endpoint is accepted");
        }
        Name = name;
    }

    public string Name { get; }

    public static bool IsValid(string? name) =>
        name is not null
        && name.StartsWith(PipePrefix + "arkdeck-", StringComparison.Ordinal)
        && System.Text.Encoding.UTF8.GetByteCount(name) <= 240
        && name.IndexOfAny(['\\', '/', ':'], PipePrefix.Length) < 0
        && !name.Contains('\0');

    /// <summary>The daemon's per-logon-session pipe, <c>\\.\pipe\arkdeck-agentd-&lt;logon SID&gt;</c>
    /// (the Rust <c>default_user_endpoint</c>).</summary>
    public static PipeEndpoint Default() => new(PipePrefix + "arkdeck-agentd-" + ProcessToken.LogonSid().Value);
}

/// <summary>This process's primary token (the Rust <c>Token::current</c>): not the thread's
/// impersonation token.</summary>
internal static class ProcessToken
{
    private const int TokenOwner = 4;

    public static SecurityIdentifier Owner()
    {
        using var token = Open();
        return WithInformation(token, TokenOwner, (buffer, length) =>
        {
            if (length < IntPtr.Size) throw Denied("truncated token information");
            return CopySid(Marshal.ReadIntPtr(buffer));
        });
    }

    public static SecurityIdentifier LogonSid()
    {
        using var token = Open();
        return WithInformation(token, Native.TokenGroups, (buffer, length) =>
        {
            if (length < sizeof(uint)) throw Denied("truncated token information");
            var count = (uint)Marshal.ReadInt32(buffer);
            var offset = IntPtr.Size; // TOKEN_GROUPS.Groups follows the DWORD at pointer alignment.
            var stride = 2 * IntPtr.Size; // SID_AND_ATTRIBUTES { PSID; DWORD } padded to pointer size.
            if (count > 0 && (length < offset || count > (length - offset) / stride)) throw Denied("invalid token group count");
            for (var i = 0; i < count; i++)
            {
                var entry = buffer + offset + i * stride;
                var attributes = (uint)Marshal.ReadInt32(entry + IntPtr.Size);
                if ((attributes & Native.SE_GROUP_LOGON_ID) == Native.SE_GROUP_LOGON_ID) return CopySid(Marshal.ReadIntPtr(entry));
            }
            throw Denied("token has no logon SID");
        });
    }

    internal static SecurityIdentifier CopySid(IntPtr sid)
    {
        if (sid == IntPtr.Zero || !Native.IsValidSid(sid)) throw Denied("invalid security identifier");
        return new SecurityIdentifier(sid);
    }

    private static SafeAccessTokenHandle Open()
    {
        if (!Native.OpenProcessToken(Native.GetCurrentProcess(), Native.TOKEN_QUERY, out var token))
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
        }
        return token;
    }

    private static T WithInformation<T>(SafeAccessTokenHandle token, int kind, Func<IntPtr, int, T> read)
    {
        Native.GetTokenInformation(token, kind, IntPtr.Zero, 0, out var length);
        if (length == 0 || length > 1024 * 1024) throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
        var buffer = Marshal.AllocHGlobal((int)length);
        try
        {
            if (!Native.GetTokenInformation(token, kind, buffer, length, out var returned))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
            }
            if (returned > length) throw Denied("token information exceeds allocated buffer");
            return read(buffer, (int)returned);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static UnauthorizedAccessException Denied(string message) => new(message);
}
