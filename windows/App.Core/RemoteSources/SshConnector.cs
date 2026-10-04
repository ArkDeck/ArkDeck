using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace ArkDeck.App.Core.RemoteSources;

/// <summary>Where and as whom to connect.</summary>
internal sealed record SshEndpoint(string Host, int Port, string Username);

/// <summary>One SFTP session; the observed host key is the server's OpenSSH public key line
/// (<c>"&lt;type&gt; &lt;base64&gt;"</c>), known once the session is up.</summary>
internal sealed class SftpConnection(SftpClient sftp, string? observedHostKey, Func<ValueTask> close) : IAsyncDisposable
{
    public SftpClient Sftp { get; } = sftp;

    public string? ObservedHostKey { get; } = observedHostKey;

    public ValueTask DisposeAsync() => close();
}

/// <summary>Opens SFTP sessions (the production one runs Windows' OpenSSH client).</summary>
internal interface ISftpConnector
{
    /// <exception cref="RemoteBuildSourceException"><c>hostKeyChanged</c> when the server's key
    /// is not <paramref name="expectedHostKey"/>; <c>invalidCredential</c>,
    /// <c>systemCredentialUnavailable</c>, or <c>connectionFailed</c> with the client's words.</exception>
    Task<SftpConnection> ConnectAsync(SshEndpoint endpoint, RemoteBuildCredentialEnvelope credential, string? expectedHostKey, CancellationToken cancellation);
}

/// <summary>
/// SFTP over the Windows OpenSSH client (<c>%SystemRoot%\System32\OpenSSH\ssh.exe</c>, the built-in
/// one; never a client found on PATH). macOS runs SSH in the App process (Citadel) and reads no
/// SSH configuration, agent or known-hosts file; this connector keeps that boundary around the
/// external client:
/// <list type="bullet">
/// <item>argv only (no shell), <c>-F none</c> (no SSH config), <c>IdentityAgent=none</c>, no
/// forwarding, no control master, no local command, the <c>sftp</c> subsystem requested with
/// <c>-s</c> after <c>--</c>; the host was validated against <c>^[A-Za-z0-9._:-]+$</c>;</item>
/// <item>host keys: a per-connection known-hosts file in an owner-only temporary directory under
/// a fixed <c>HostKeyAlias</c>, the global file empty. A saved source's pinned key is the only line
/// and <c>StrictHostKeyChecking=yes</c> (any other key is refused: <c>hostKeyChanged</c>); a
/// first probe uses <c>accept-new</c> on an empty file and reads the key the client wrote there —
/// which the person then reviews and trusts by saving, as on macOS. The user's
/// <c>~/.ssh/known_hosts</c> is never read or written;</item>
/// <item>secrets: a password or key passphrase is answered through <c>SSH_ASKPASS</c>
/// (<c>SSH_ASKPASS_REQUIRE=force</c>): the App's own executable in its askpass mode reads it from
/// an owner-only, single-use named pipe, so no secret is on a command line, in the environment or
/// in a file. A key is written only into the owner-only temporary directory for the connection
/// (an explicit key from Credential Manager, or a verified copy of a system-default identity);
/// the directory is deleted when the session ends.</item>
/// </list>
/// </summary>
internal sealed class OpenSshConnector(string askPassExecutable, string? sshExecutable = null, string? homeDirectory = null) : ISftpConnector
{
    public const string HostKeyAlias = "arkdeck-remote-build-source";
    public const string AskPassPipeVariable = "ARKDECK_ASKPASS_PIPE";

    private static readonly string[] SystemIdentityFiles = ["id_rsa", "id_ed25519"];
    private const int MaximumKeyBytes = 256 * 1_024;

    public static string DefaultSsh => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");

    private string Ssh => sshExecutable ?? DefaultSsh;

    private string Home => homeDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public async Task<SftpConnection> ConnectAsync(SshEndpoint endpoint, RemoteBuildCredentialEnvelope credential, string? expectedHostKey, CancellationToken cancellation)
    {
        if (!File.Exists(Ssh)) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ConnectionFailed, "the Windows OpenSSH client is not installed");
        var scratch = Directory.CreateTempSubdirectory("arkdeck-ssh-");
        scratch.SetAccessControl(OwnerOnly.Directory());
        Process? process = null;
        AskPassServer? askPass = null;
        try
        {
            var knownHosts = Path.Combine(scratch.FullName, "known_hosts");
            var globalHosts = Path.Combine(scratch.FullName, "global_known_hosts");
            File.WriteAllText(globalHosts, "");
            File.WriteAllText(knownHosts, expectedHostKey is null ? "" : $"{HostKeyAlias} {expectedHostKey}\n");

            var arguments = new List<string>
            {
                "-F", "none", "-T", "-x", "-a",
                "-o", "BatchMode=no",
                "-o", "ConnectTimeout=12",
                "-o", "ConnectionAttempts=1",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "IdentityAgent=none",
                "-o", "IdentitiesOnly=yes",
                "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no",
                "-o", "ClearAllForwardings=yes",
                "-o", "ControlMaster=no",
                "-o", "ControlPath=none",
                "-o", "PermitLocalCommand=no",
                "-o", "Tunnel=no",
                "-o", "GSSAPIAuthentication=no",
                "-o", "HostbasedAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "VerifyHostKeyDNS=no",
                "-o", "UpdateHostKeys=no",
                "-o", "CheckHostIP=no",
                "-o", "HashKnownHosts=no",
                "-o", $"HostKeyAlias={HostKeyAlias}",
                "-o", $"UserKnownHostsFile={knownHosts}",
                "-o", $"GlobalKnownHostsFile={globalHosts}",
                "-o", "StrictHostKeyChecking=" + (expectedHostKey is null ? "accept-new" : "yes"),
                "-o", "LogLevel=ERROR",
            };
            if (expectedHostKey is not null) arguments.AddRange(["-o", "HostKeyAlgorithms=" + HostKeyAlgorithms(expectedHostKey)]);

            string? secret;
            int prompts;
            if (credential.Authentication == RemoteBuildSourceAuthentication.Password)
            {
                secret = Utf8(credential.Secret) ?? throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential);
                prompts = 1;
                arguments.AddRange(["-o", "PreferredAuthentications=password", "-o", "PasswordAuthentication=yes", "-o", "PubkeyAuthentication=no"]);
            }
            else
            {
                var keys = credential.UsesSystemDefault ? SystemIdentities() : [credential.Secret];
                if (credential.UsesSystemDefault && keys.Count == 0) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.SystemCredentialUnavailable);
                if (!credential.UsesSystemDefault && KeyType(credential.Secret) is null) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential);
                secret = credential.Passphrase is { } passphrase ? Utf8(passphrase) ?? throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.InvalidCredential) : null;
                prompts = keys.Count;
                arguments.AddRange(["-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "PubkeyAuthentication=yes"]);
                for (var i = 0; i < keys.Count; i++)
                {
                    var file = Path.Combine(scratch.FullName, $"identity-{i}");
                    using (var stream = new FileInfo(file).Create(FileMode.CreateNew, FileSystemRights.FullControl, FileShare.None, 4096, FileOptions.None, OwnerOnly.File()))
                    {
                        stream.Write(keys[i]);
                    }
                    arguments.AddRange(["-i", file]);
                }
            }
            arguments.AddRange(["-p", endpoint.Port.ToString(System.Globalization.CultureInfo.InvariantCulture), "-l", endpoint.Username, "-s", "--", endpoint.Host, "sftp"]);

            askPass = AskPassServer.Start(secret, prompts);
            var start = new ProcessStartInfo(Ssh)
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = scratch.FullName,
            };
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
            foreach (var name in new[] { "SSH_AUTH_SOCK", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY", AskPassPipeVariable }) start.Environment.Remove(name);
            start.Environment["SSH_ASKPASS"] = askPassExecutable;
            start.Environment["SSH_ASKPASS_REQUIRE"] = "force";
            start.Environment["DISPLAY"] = "arkdeck";
            start.Environment[AskPassPipeVariable] = askPass.Name;

            process = Process.Start(start) ?? throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ConnectionFailed, "the OpenSSH client did not start");
            var errors = process.StandardError.ReadToEndAsync(CancellationToken.None);
            SftpClient sftp;
            try
            {
                sftp = await SftpClient.StartAsync(process.StandardOutput.BaseStream, process.StandardInput.BaseStream, cancellation).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException or EndOfStreamException)
            {
                await process.WaitForExitAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(15), CancellationToken.None).ConfigureAwait(false);
                throw Failure(await errors.ConfigureAwait(false), expectedHostKey is not null);
            }

            var observed = expectedHostKey ?? ObservedKey(knownHosts);
            var running = process;
            var server = askPass;
            process = null;
            askPass = null;
            return new SftpConnection(sftp, observed, async () =>
            {
                try
                {
                    running.StandardInput.Close();
                    using var exit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                    try
                    {
                        await running.WaitForExitAsync(exit.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        running.Kill(entireProcessTree: true);
                    }
                }
                finally
                {
                    running.Dispose();
                    server.Dispose();
                    Delete(scratch);
                }
            });
        }
        catch
        {
            if (process is { HasExited: false }) process.Kill(entireProcessTree: true);
            process?.Dispose();
            askPass?.Dispose();
            Delete(scratch);
            throw;
        }
    }

    /// <summary>The host key algorithms of a pinned key's type, so the client negotiates that
    /// key (an RSA key is signed with SHA-2).</summary>
    internal static string HostKeyAlgorithms(string openSshKey)
    {
        var type = openSshKey.Split(' ')[0];
        return type == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256,ssh-rsa" : type;
    }

    /// <summary>The key line the client wrote for the alias, or the macOS refusal when there is none.</summary>
    private static string ObservedKey(string knownHosts)
    {
        foreach (var line in File.ReadAllLines(knownHosts))
        {
            var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length >= 3 && fields[0] == HostKeyAlias) return $"{fields[1]} {fields[2]}";
        }
        throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ConnectionFailed, "the server offered no host key that can be pinned");
    }

    private static RemoteBuildSourceException Failure(string stderr, bool pinned)
    {
        if (pinned && (stderr.Contains("REMOTE HOST IDENTIFICATION HAS CHANGED", StringComparison.Ordinal)
                       || stderr.Contains("Host key verification failed", StringComparison.Ordinal)
                       || stderr.Contains("No matching host key type found", StringComparison.Ordinal)))
        {
            return new RemoteBuildSourceException(RemoteBuildSourceErrorCode.HostKeyChanged);
        }
        var last = stderr.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0) ?? "the OpenSSH client ended";
        return new RemoteBuildSourceException(RemoteBuildSourceErrorCode.ConnectionFailed, last);
    }

    /// <summary>The OpenSSH private key types the macOS App accepts: ed25519 and RSA (PEM or the
    /// OpenSSH format, whose public part names the type even when the key is encrypted).</summary>
    internal static string? KeyType(byte[] key)
    {
        var text = Utf8(key);
        if (text is null) return null;
        if (text.Contains("-----BEGIN RSA PRIVATE KEY-----", StringComparison.Ordinal)) return "ssh-rsa";
        const string begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----";
        var from = text.IndexOf(begin, StringComparison.Ordinal);
        var to = text.IndexOf(end, StringComparison.Ordinal);
        if (from < 0 || to < from) return null;
        try
        {
            var blob = Convert.FromBase64String(string.Concat(text[(from + begin.Length)..to].Where(c => !char.IsWhiteSpace(c))));
            var magic = "openssh-key-v1\0"u8;
            if (!blob.AsSpan().StartsWith(magic)) return null;
            var at = magic.Length;
            byte[] Next()
            {
                var length = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(blob.AsSpan(at));
                if (length < 0 || at + 4 + length > blob.Length) throw new FormatException("truncated");
                var value = blob.AsSpan(at + 4, length).ToArray();
                at += 4 + length;
                return value;
            }
            Next(); // cipher
            Next(); // kdf
            Next(); // kdf options
            if (System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(blob.AsSpan(at)) != 1) return null;
            at += 4;
            var publicKey = Next();
            var length = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(publicKey);
            var type = Encoding.ASCII.GetString(publicKey, 4, length);
            return type is "ssh-ed25519" or "ssh-rsa" ? type : null;
        }
        catch (Exception error) when (error is FormatException or ArgumentException or IndexOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>
    /// The system-default identities (macOS <c>SystemSSHIdentityResolver</c>): exactly
    /// <c>.ssh\id_rsa</c>, then <c>.ssh\id_ed25519</c> under the user's profile, each only when it is
    /// a regular file (not a reparse point), owned by this user and granting nobody else (the
    /// counterpart of <c>mode &amp; 077 == 0</c>), 1 byte to 256 KiB, unchanged while read, and an
    /// ed25519 or RSA key. The verified bytes are what the client is given.
    /// </summary>
    internal List<byte[]> SystemIdentities()
    {
        var keys = new List<byte[]>();
        foreach (var name in SystemIdentityFiles)
        {
            if (Secure(Path.Combine(Home, ".ssh", name)) is { } bytes && KeyType(bytes) is not null) keys.Add(bytes);
        }
        return keys;
    }

    private static byte[]? Secure(string path)
    {
        try
        {
            var before = new FileInfo(path);
            if (!before.Exists || (before.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory | FileAttributes.Device)) != 0) return null;
            if (before.Length is < 1 or > MaximumKeyBytes || !OwnerOnly.IsPrivate(before)) return null;
            byte[] bytes;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                bytes = new byte[stream.Length];
                stream.ReadExactly(bytes);
            }
            var after = new FileInfo(path);
            return after.Length == before.Length && after.LastWriteTimeUtc == before.LastWriteTimeUtc && after.CreationTimeUtc == before.CreationTimeUtc
                   && after.Attributes == before.Attributes && bytes.Length == before.Length
                ? bytes
                : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static string? Utf8(byte[] bytes)
    {
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    private static void Delete(DirectoryInfo directory)
    {
        try
        {
            directory.Delete(recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Left behind only when the file system refuses; it is owner-only and holds no secret
            // the person did not already keep in Credential Manager or their profile.
        }
    }

    /// <summary>
    /// Answers the client's password or passphrase prompts for one connection: an owner-only named
    /// pipe with an unguessable name, at most <c>prompts</c> answers, each the one secret. A
    /// prompt that is not a password or passphrase prompt (such as a host-key question) is
    /// refused.
    /// </summary>
    private sealed class AskPassServer : IDisposable
    {
        private readonly CancellationTokenSource _stop = new();

        private AskPassServer(string name) => Name = name;

        public string Name { get; }

        public static AskPassServer Start(string? secret, int prompts)
        {
            var server = new AskPassServer("arkdeck-askpass-" + Guid.NewGuid().ToString("N"));
            _ = server.ServeAsync(secret, Math.Max(prompts, 0));
            return server;
        }

        private async Task ServeAsync(string? secret, int prompts)
        {
            var security = new PipeSecurity();
            var user = WindowsIdentity.GetCurrent().User!;
            security.SetOwner(user);
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance, AccessControlType.Allow));
            for (var answered = 0; !_stop.IsCancellationRequested && answered <= prompts; answered++)
            {
                try
                {
                    await using var pipe = NamedPipeServerStreamAcl.Create(Name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security);
                    await pipe.WaitForConnectionAsync(_stop.Token).ConfigureAwait(false);
                    using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);
                    var prompt = (await reader.ReadLineAsync(_stop.Token).ConfigureAwait(false) ?? "").ToLowerInvariant();
                    var allowed = secret is not null && answered < prompts && (prompt.Contains("password", StringComparison.Ordinal) || prompt.Contains("passphrase", StringComparison.Ordinal));
                    var answer = allowed ? "1" + secret : "0";
                    var bytes = new UTF8Encoding(false).GetBytes(answer + "\n");
                    await pipe.WriteAsync(bytes, _stop.Token).ConfigureAwait(false);
                    await pipe.FlushAsync(_stop.Token).ConfigureAwait(false);
                    pipe.WaitForPipeDrain();
                }
                catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException)
                {
                    return;
                }
            }
        }

        public void Dispose()
        {
            _stop.Cancel();
            _stop.Dispose();
        }
    }
}

/// <summary>
/// The App's askpass mode: OpenSSH runs the App's executable as <c>SSH_ASKPASS</c> with the
/// prompt as its argument and <see cref="OpenSshConnector.AskPassPipeVariable"/> naming the pipe;
/// this asks the App for the answer and prints it for the client. Exit status 1 refuses the prompt.
/// </summary>
public static class AskPassClient
{
    public static bool IsRequested(string[] args) =>
        args.Length == 1 && Environment.GetEnvironmentVariable(OpenSshConnector.AskPassPipeVariable) is { Length: > 0 };

    public static int Run(string prompt)
    {
        try
        {
            var name = Environment.GetEnvironmentVariable(OpenSshConnector.AskPassPipeVariable)!;
            using var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut);
            pipe.Connect(10_000);
            var bytes = new UTF8Encoding(false).GetBytes(prompt.Replace('\n', ' ').Replace('\r', ' ') + "\n");
            pipe.Write(bytes);
            pipe.Flush();
            using var reader = new StreamReader(pipe, new UTF8Encoding(false));
            var answer = reader.ReadLine();
            if (answer is not { Length: > 0 } || answer[0] != '1') return 1;
            using var stdout = Console.OpenStandardOutput();
            stdout.Write(new UTF8Encoding(false).GetBytes(answer[1..] + "\n"));
            stdout.Flush();
            return 0;
        }
        catch (Exception error) when (error is IOException or TimeoutException or UnauthorizedAccessException)
        {
            return 1;
        }
    }
}
