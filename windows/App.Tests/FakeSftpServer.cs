using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using ArkDeck.App.Core.RemoteSources;

namespace ArkDeck.App.Tests;

/// <summary>
/// An in-process SFTP version 3 server over a virtual file system, enough for the remote build
/// source reader: realpath (with symbolic links resolved), opendir/readdir/close, open for
/// reading, fstat and read. Every request is recorded; any other request type is answered
/// "operation unsupported" and recorded, so a test can assert that nothing wrote.
/// </summary>
internal sealed class FakeSftpServer
{
    public sealed record Node(bool Directory, byte[] Content, uint ModifiedTime, uint? Permissions = null, string? LinkTo = null);

    public Dictionary<string, Node> Files { get; } = new(StringComparer.Ordinal);

    public List<byte> RequestTypes { get; } = [];

    /// <summary>Called after each read; a test may change the file under the reader.</summary>
    public Action<string>? AfterRead { get; set; }

    public void Directory(string path, uint time = 1_700_000_000) => Files[path] = new Node(true, [], time);

    public void File(string path, byte[] content, uint time = 1_700_000_000) => Files[path] = new Node(false, content, time);

    public void Link(string path, string target) => Files[path] = new Node(false, [], 0, 0xA1FF, target);

    /// <summary>Starts a session; the returned client is connected to it.</summary>
    public async Task<SftpClient> ConnectAsync()
    {
        var toServer = new AnonymousPipeServerStream(PipeDirection.Out);
        var serverIn = new AnonymousPipeClientStream(PipeDirection.In, toServer.ClientSafePipeHandle);
        var toClient = new AnonymousPipeServerStream(PipeDirection.Out);
        var clientIn = new AnonymousPipeClientStream(PipeDirection.In, toClient.ClientSafePipeHandle);
        _ = Task.Run(() => Serve(serverIn, toClient));
        return await SftpClient.StartAsync(clientIn, toServer, CancellationToken.None);
    }

    private readonly Dictionary<string, (string Path, int Next)> _handles = [];

    private string Resolve(string path)
    {
        for (var hops = 0; hops < 8; hops++)
        {
            var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
            var built = "";
            var changed = false;
            for (var i = 0; i < parts.Length; i++)
            {
                if (parts[i] == ".") continue;
                if (parts[i] == "..")
                {
                    built = built.Contains('/') ? built[..built.LastIndexOf('/')] : "";
                    continue;
                }
                built += "/" + parts[i];
                if (Files.TryGetValue(built, out var node) && node.LinkTo is { } target)
                {
                    path = target + string.Concat(parts.Skip(i + 1).Select(p => "/" + p));
                    changed = true;
                    break;
                }
            }
            if (!changed) return built.Length == 0 ? "/" : built;
        }
        return path;
    }

    private void Serve(Stream input, Stream output)
    {
        try
        {
            while (true)
            {
                var header = new byte[5];
                input.ReadExactly(header);
                var body = new byte[BinaryPrimitives.ReadUInt32BigEndian(header) - 1];
                input.ReadExactly(body);
                var type = header[4];
                RequestTypes.Add(type);
                var r = new Reader(body);
                if (type == 1)
                {
                    Send(output, 2, w => w.UInt32(3));
                    continue;
                }
                var id = r.UInt32();
                switch (type)
                {
                    case 16: // realpath
                    {
                        var resolved = Resolve(r.Text());
                        if (!Files.ContainsKey(resolved) && resolved != "/") Status(output, id, 2, "No such file");
                        else Send(output, 104, w => { w.UInt32(id); w.UInt32(1); w.String(resolved); w.String(resolved); w.UInt32(0); });
                        break;
                    }
                    case 11: // opendir
                    {
                        var path = Resolve(r.Text());
                        if (!Files.TryGetValue(path, out var node) || !node.Directory) Status(output, id, 2, "No such directory");
                        else Handle(output, id, path);
                        break;
                    }
                    case 12: // readdir
                    {
                        var handle = Encoding.UTF8.GetString(r.Bytes());
                        var (path, next) = _handles[handle];
                        if (next > 0)
                        {
                            Status(output, id, 1, "EOF");
                            break;
                        }
                        _handles[handle] = (path, 1);
                        var children = Files.Where(f => f.Key != path && f.Key.StartsWith(path + "/", StringComparison.Ordinal) && !f.Key[(path.Length + 1)..].Contains('/')).ToArray();
                        Send(output, 104, w =>
                        {
                            w.UInt32(id);
                            w.UInt32((uint)children.Length + 2);
                            foreach (var dot in new[] { ".", ".." })
                            {
                                w.String(dot);
                                w.String(dot);
                                w.UInt32(0x4);
                                w.UInt32(0x41ED);
                            }
                            foreach (var (key, node) in children)
                            {
                                var name = key[(path.Length + 1)..];
                                w.String(name);
                                w.String(name);
                                Attributes(w, node);
                            }
                        });
                        break;
                    }
                    case 3: // open
                    {
                        var path = Resolve(r.Text());
                        var flags = r.UInt32();
                        if (flags != 1) Status(output, id, 3, "write refused by the fake");
                        else if (!Files.TryGetValue(path, out var node) || node.Directory) Status(output, id, 2, "No such file");
                        else Handle(output, id, path);
                        break;
                    }
                    case 8: // fstat
                    {
                        var (path, _) = _handles[Encoding.UTF8.GetString(r.Bytes())];
                        var node = Files[path];
                        Send(output, 105, w => { w.UInt32(id); Attributes(w, node); });
                        break;
                    }
                    case 5: // read
                    {
                        var (path, _) = _handles[Encoding.UTF8.GetString(r.Bytes())];
                        var offset = r.UInt64();
                        var length = r.UInt32();
                        var content = Files[path].Content;
                        if (offset >= (ulong)content.Length)
                        {
                            Status(output, id, 1, "EOF");
                            break;
                        }
                        var count = (int)Math.Min(Math.Min(length, 64 * 1024), (ulong)content.Length - offset);
                        var chunk = content.AsSpan((int)offset, count).ToArray();
                        Send(output, 103, w => { w.UInt32(id); w.Bytes(chunk); });
                        AfterRead?.Invoke(path);
                        break;
                    }
                    case 4: // close
                        _handles.Remove(Encoding.UTF8.GetString(r.Bytes()));
                        Status(output, id, 0, "OK");
                        break;
                    default:
                        Status(output, id, 8, "unsupported");
                        break;
                }
            }
        }
        catch (Exception error) when (error is IOException or EndOfStreamException or ObjectDisposedException)
        {
        }
    }

    private void Handle(Stream output, uint id, string path)
    {
        var handle = Guid.NewGuid().ToString("N");
        _handles[handle] = (path, 0);
        Send(output, 102, w => { w.UInt32(id); w.String(handle); });
    }

    private static void Attributes(Writer w, Node node)
    {
        w.UInt32(0x1 | 0x4 | 0x8);
        w.UInt64((ulong)node.Content.Length);
        w.UInt32(node.Permissions ?? (node.Directory ? 0x41EDu : 0x81A4u));
        w.UInt32(node.ModifiedTime);
        w.UInt32(node.ModifiedTime);
    }

    private static void Status(Stream output, uint id, uint code, string message) =>
        Send(output, 101, w => { w.UInt32(id); w.UInt32(code); w.String(message); w.String(""); });

    private static void Send(Stream output, byte type, Action<Writer> fill)
    {
        var w = new Writer();
        fill(w);
        var body = w.Stream.ToArray();
        var header = new byte[5];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)body.Length + 1);
        header[4] = type;
        lock (output)
        {
            output.Write(header);
            output.Write(body);
            output.Flush();
        }
    }

    private sealed class Writer
    {
        public MemoryStream Stream { get; } = new();

        public void UInt32(uint v)
        {
            Span<byte> b = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(b, v);
            Stream.Write(b);
        }

        public void UInt64(ulong v)
        {
            Span<byte> b = stackalloc byte[8];
            BinaryPrimitives.WriteUInt64BigEndian(b, v);
            Stream.Write(b);
        }

        public void Bytes(byte[] v)
        {
            UInt32((uint)v.Length);
            Stream.Write(v);
        }

        public void String(string v) => Bytes(Encoding.UTF8.GetBytes(v));
    }

    private sealed class Reader(byte[] body)
    {
        private int _at;

        public uint UInt32()
        {
            var v = BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(_at));
            _at += 4;
            return v;
        }

        public ulong UInt64()
        {
            var v = BinaryPrimitives.ReadUInt64BigEndian(body.AsSpan(_at));
            _at += 8;
            return v;
        }

        public byte[] Bytes()
        {
            var n = (int)UInt32();
            var v = body.AsSpan(_at, n).ToArray();
            _at += n;
            return v;
        }

        public string Text() => Encoding.UTF8.GetString(Bytes());
    }
}

/// <summary>A connector to a <see cref="FakeSftpServer"/> whose host key is <see cref="HostKey"/>;
/// like the OpenSSH client with <c>StrictHostKeyChecking=yes</c>, it refuses another pinned key.</summary>
internal sealed class FakeConnector(FakeSftpServer server) : ISftpConnector
{
    public string HostKey { get; set; } = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOq3vB6cU8nR6t0cJv4CQyVb0kq3cWb6jY0tqYQJ3l1N";

    public List<(SshEndpoint Endpoint, RemoteBuildCredentialEnvelope Credential, string? Expected)> Connections { get; } = [];

    public async Task<SftpConnection> ConnectAsync(SshEndpoint endpoint, RemoteBuildCredentialEnvelope credential, string? expectedHostKey, CancellationToken cancellation)
    {
        Connections.Add((endpoint, credential, expectedHostKey));
        if (expectedHostKey is not null && expectedHostKey != HostKey) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.HostKeyChanged);
        var sftp = await server.ConnectAsync();
        return new SftpConnection(sftp, HostKey, () => ValueTask.CompletedTask);
    }
}

/// <summary>Credential Manager's role, in memory.</summary>
internal sealed class MemoryCredentials : IRemoteCredentialStore
{
    public Dictionary<Guid, byte[]> Items { get; } = [];

    public bool FailWrites { get; set; }

    public void Set(byte[] data, Guid account)
    {
        if (FailWrites) throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialStoreFailed, "refused by the test");
        Items[account] = data;
    }

    public byte[] Read(Guid account) =>
        Items.TryGetValue(account, out var data) && data.Length > 0 ? data : throw new RemoteBuildSourceException(RemoteBuildSourceErrorCode.CredentialUnavailable);

    public bool Contains(Guid account) => Items.ContainsKey(account);

    public bool Remove(Guid account) => Items.Remove(account);
}
