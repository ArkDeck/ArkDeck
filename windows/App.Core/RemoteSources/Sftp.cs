using System.Buffers.Binary;
using System.Text;

namespace ArkDeck.App.Core.RemoteSources;

/// <summary>The SFTP attributes this reader uses (SFTP v3, draft-ietf-secsh-filexfer-02 §5).</summary>
public sealed record SftpAttributes(ulong? Size, uint? Permissions, uint? ModifiedTime)
{
    public const uint TypeMask = 0xF000; // 0o170000
    public const uint Directory = 0x4000; // 0o040000
    public const uint Regular = 0x8000; // 0o100000

    public DateTimeOffset? Modified => ModifiedTime is { } t ? DateTimeOffset.FromUnixTimeSeconds(t) : null;
}

public sealed record SftpName(string FileName, SftpAttributes Attributes);

/// <summary>An SFTP request the server refused (<c>SSH_FXP_STATUS</c>).</summary>
public sealed class SftpStatusException(uint code, string message) : IOException($"SFTP status {code}: {message}")
{
    public uint Code { get; } = code;
}

/// <summary>
/// A read-only SFTP version 3 client over the subsystem's byte streams: <c>realpath</c>, directory
/// listing, opening a file for reading, its attributes and reads at offsets — the operations the
/// macOS remote build source uses (Citadel's <c>getRealPath</c>, <c>listDirectory</c>,
/// <c>withFile(.read)</c>, <c>readAttributes</c>, <c>read(from:length:)</c>). It has no request
/// that writes, renames, removes or executes anything. Requests are sent one at a time.
/// </summary>
public sealed class SftpClient
{
    private const byte Init = 1, Version = 2, Open = 3, Close = 4, Read = 5, Fstat = 8, OpenDir = 11, ReadDir = 12, RealPath = 16;
    private const byte Status = 101, Handle = 102, Data = 103, Name = 104, Attrs = 105;
    private const uint FlagSize = 0x1, FlagUidGid = 0x2, FlagPermissions = 0x4, FlagAcModTime = 0x8, FlagExtended = 0x80000000;
    private const uint OpenRead = 0x1;
    private const uint StatusEof = 1;
    private const int MaximumPacket = 1 << 20;

    private readonly Stream _input;
    private readonly Stream _output;
    private uint _next = 1;

    private SftpClient(Stream input, Stream output)
    {
        _input = input;
        _output = output;
    }

    /// <summary>Negotiates SFTP version 3 over the subsystem's stdout (<paramref name="input"/>)
    /// and stdin (<paramref name="output"/>).</summary>
    public static async Task<SftpClient> StartAsync(Stream input, Stream output, CancellationToken cancellation)
    {
        var client = new SftpClient(input, output);
        var init = new Packet(Init);
        init.UInt32(3);
        await client.SendAsync(init, cancellation).ConfigureAwait(false);
        var (type, body) = await client.ReceiveAsync(cancellation).ConfigureAwait(false);
        if (type != Version) throw new IOException("the SFTP server did not answer the version exchange");
        var reader = new Reader(body);
        if (reader.UInt32() < 3) throw new IOException("the SFTP server speaks a version below 3");
        return client;
    }

    public async Task<string> RealPathAsync(string path, CancellationToken cancellation)
    {
        var names = await NamesAsync(Request(RealPath, p => p.String(path)), cancellation).ConfigureAwait(false);
        return names is [var one] ? one.FileName : throw new IOException("SFTP realpath did not name exactly one path");
    }

    /// <summary>Every entry of a directory, at most <paramref name="limit"/> (more is an
    /// <see cref="InvalidDataException"/>), "." and ".." included as the server sends them.</summary>
    public async Task<IReadOnlyList<SftpName>> ListDirectoryAsync(string path, int limit, CancellationToken cancellation)
    {
        var handle = await HandleAsync(Request(OpenDir, p => p.String(path)), cancellation).ConfigureAwait(false);
        var entries = new List<SftpName>();
        try
        {
            while (true)
            {
                var (type, body) = await CallAsync(Request(ReadDir, p => p.Bytes(handle)), cancellation).ConfigureAwait(false);
                if (type == Status)
                {
                    var (code, message) = StatusOf(body);
                    if (code == StatusEof) break;
                    throw new SftpStatusException(code, message);
                }
                if (type != Name) throw new IOException("unexpected SFTP answer to readdir");
                entries.AddRange(ParseNames(body));
                if (entries.Count > limit + 2) throw new InvalidDataException("too many entries");
            }
        }
        finally
        {
            await CloseAsync(handle, cancellation).ConfigureAwait(false);
        }
        return entries;
    }

    /// <summary>Opens a file for reading only.</summary>
    public async Task<SftpFile> OpenReadAsync(string path, CancellationToken cancellation)
    {
        var handle = await HandleAsync(Request(Open, p =>
        {
            p.String(path);
            p.UInt32(OpenRead);
            p.UInt32(0);
        }), cancellation).ConfigureAwait(false);
        return new SftpFile(this, handle);
    }

    internal async Task<SftpAttributes> FstatAsync(byte[] handle, CancellationToken cancellation)
    {
        var (type, body) = await CallAsync(Request(Fstat, p => p.Bytes(handle)), cancellation).ConfigureAwait(false);
        if (type == Status) throw StatusError(body);
        if (type != Attrs) throw new IOException("unexpected SFTP answer to fstat");
        return new Reader(body).Attributes();
    }

    internal async Task<byte[]> ReadAsync(byte[] handle, ulong offset, uint length, CancellationToken cancellation)
    {
        var (type, body) = await CallAsync(Request(Read, p =>
        {
            p.Bytes(handle);
            p.UInt64(offset);
            p.UInt32(length);
        }), cancellation).ConfigureAwait(false);
        if (type == Status)
        {
            var (code, message) = StatusOf(body);
            return code == StatusEof ? [] : throw new SftpStatusException(code, message);
        }
        if (type != Data) throw new IOException("unexpected SFTP answer to read");
        var data = new Reader(body).Bytes();
        return data.Length <= length ? data : throw new IOException("the SFTP server returned more than was asked");
    }

    internal async Task CloseAsync(byte[] handle, CancellationToken cancellation)
    {
        var (type, body) = await CallAsync(Request(Close, p => p.Bytes(handle)), cancellation).ConfigureAwait(false);
        if (type != Status) throw new IOException("unexpected SFTP answer to close");
        var (code, message) = StatusOf(body);
        if (code != 0) throw new SftpStatusException(code, message);
    }

    // ---- framing ----

    private Packet Request(byte type, Action<Packet> fill)
    {
        var packet = new Packet(type);
        packet.UInt32(_next++);
        fill(packet);
        return packet;
    }

    private async Task<(byte Type, byte[] Body)> CallAsync(Packet request, CancellationToken cancellation)
    {
        var id = request.Id;
        await SendAsync(request, cancellation).ConfigureAwait(false);
        var (type, body) = await ReceiveAsync(cancellation).ConfigureAwait(false);
        var reader = new Reader(body);
        if (reader.UInt32() != id) throw new IOException("the SFTP server answered another request");
        return (type, body[4..]);
    }

    private async Task<byte[]> HandleAsync(Packet request, CancellationToken cancellation)
    {
        var (type, body) = await CallAsync(request, cancellation).ConfigureAwait(false);
        if (type == Status) throw StatusError(body);
        if (type != Handle) throw new IOException("unexpected SFTP answer to open");
        return new Reader(body).Bytes();
    }

    private async Task<IReadOnlyList<SftpName>> NamesAsync(Packet request, CancellationToken cancellation)
    {
        var (type, body) = await CallAsync(request, cancellation).ConfigureAwait(false);
        if (type == Status) throw StatusError(body);
        if (type != Name) throw new IOException("unexpected SFTP answer to realpath");
        return ParseNames(body);
    }

    private static List<SftpName> ParseNames(byte[] body)
    {
        var reader = new Reader(body);
        var count = reader.UInt32();
        if (count > 100_000) throw new IOException("an SFTP name list is too long");
        var names = new List<SftpName>((int)count);
        for (var i = 0; i < count; i++)
        {
            var name = reader.Text();
            reader.Bytes(); // longname: display only
            names.Add(new SftpName(name, reader.Attributes()));
        }
        return names;
    }

    private static (uint Code, string Message) StatusOf(byte[] body)
    {
        var reader = new Reader(body);
        var code = reader.UInt32();
        var message = reader.Remaining > 0 ? reader.Text() : "";
        return (code, message);
    }

    private static SftpStatusException StatusError(byte[] body)
    {
        var (code, message) = StatusOf(body);
        return new SftpStatusException(code, message);
    }

    private async Task SendAsync(Packet packet, CancellationToken cancellation)
    {
        var bytes = packet.ToArray();
        await _output.WriteAsync(bytes, cancellation).ConfigureAwait(false);
        await _output.FlushAsync(cancellation).ConfigureAwait(false);
    }

    private async Task<(byte Type, byte[] Body)> ReceiveAsync(CancellationToken cancellation)
    {
        var header = new byte[5];
        await _input.ReadExactlyAsync(header, cancellation).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length < 1 || length > MaximumPacket) throw new IOException("an SFTP packet is out of bounds");
        var body = new byte[length - 1];
        await _input.ReadExactlyAsync(body, cancellation).ConfigureAwait(false);
        return (header[4], body);
    }

    private sealed class Packet(byte type)
    {
        private readonly MemoryStream _body = new();

        public uint Id { get; private set; }

        public void UInt32(uint value)
        {
            if (_body.Length == 0 && type != Init) Id = value;
            Span<byte> b = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32BigEndian(b, value);
            _body.Write(b);
        }

        public void UInt64(ulong value)
        {
            Span<byte> b = stackalloc byte[8];
            BinaryPrimitives.WriteUInt64BigEndian(b, value);
            _body.Write(b);
        }

        public void Bytes(byte[] value)
        {
            UInt32((uint)value.Length);
            _body.Write(value);
        }

        public void String(string value) => Bytes(Encoding.UTF8.GetBytes(value));

        public byte[] ToArray()
        {
            var body = _body.ToArray();
            var bytes = new byte[5 + body.Length];
            BinaryPrimitives.WriteUInt32BigEndian(bytes, (uint)(body.Length + 1));
            bytes[4] = type;
            body.CopyTo(bytes, 5);
            return bytes;
        }
    }

    private sealed class Reader(byte[] body)
    {
        private int _at;

        public int Remaining => body.Length - _at;

        public uint UInt32()
        {
            Need(4);
            var value = BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(_at));
            _at += 4;
            return value;
        }

        public ulong UInt64()
        {
            Need(8);
            var value = BinaryPrimitives.ReadUInt64BigEndian(body.AsSpan(_at));
            _at += 8;
            return value;
        }

        public byte[] Bytes()
        {
            var length = UInt32();
            if (length > Remaining) throw new IOException("an SFTP string runs past its packet");
            var value = body.AsSpan(_at, (int)length).ToArray();
            _at += (int)length;
            return value;
        }

        public string Text() => new UTF8Encoding(false, true).GetString(Bytes());

        public SftpAttributes Attributes()
        {
            var flags = UInt32();
            ulong? size = (flags & FlagSize) != 0 ? UInt64() : null;
            if ((flags & FlagUidGid) != 0)
            {
                UInt32();
                UInt32();
            }
            uint? permissions = (flags & FlagPermissions) != 0 ? UInt32() : null;
            uint? modified = null;
            if ((flags & FlagAcModTime) != 0)
            {
                UInt32();
                modified = UInt32();
            }
            if ((flags & FlagExtended) != 0)
            {
                var count = UInt32();
                for (var i = 0; i < count; i++)
                {
                    Bytes();
                    Bytes();
                }
            }
            return new SftpAttributes(size, permissions, modified);
        }

        private void Need(int count)
        {
            if (Remaining < count) throw new IOException("an SFTP packet is truncated");
        }
    }
}

/// <summary>A file opened for reading; closed when disposed.</summary>
public sealed class SftpFile(SftpClient client, byte[] handle) : IAsyncDisposable
{
    public Task<SftpAttributes> AttributesAsync(CancellationToken cancellation) => client.FstatAsync(handle, cancellation);

    public Task<byte[]> ReadAsync(ulong offset, uint length, CancellationToken cancellation) => client.ReadAsync(handle, offset, length, cancellation);

    public async ValueTask DisposeAsync()
    {
        try
        {
            await client.CloseAsync(handle, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException)
        {
            // The connection is going away with the operation; nothing was written.
        }
    }
}
