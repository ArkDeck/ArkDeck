namespace ArkDeck.ClientKit.Transport;

/// <summary>Why a frame could not be read or written (the Rust <c>io::ErrorKind</c> the
/// client reports as <c>ClientError::Transport</c>).</summary>
public enum TransportErrorKind
{
    /// <summary>End of stream before the frame's LF: a lost reply, never a complete frame.</summary>
    UnexpectedEof,

    /// <summary>The frame exceeds its limit, or reaches it without a delimiter.</summary>
    InvalidData,

    /// <summary>The connection's deadline passed.</summary>
    TimedOut,

    /// <summary>The authenticated peer exited or changed.</summary>
    PeerChanged,

    /// <summary>Any other I/O failure.</summary>
    Io,
}

public sealed class TransportException(TransportErrorKind kind, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public TransportErrorKind Kind { get; } = kind;
}

/// <summary>
/// The Rust <c>read_frame</c> over a <c>BufReader</c> (T0/T1): bytes up to and including
/// LF, the LF counting toward the limit; bytes after the LF stay buffered for the next
/// frame, as <c>BufReader</c> keeps them.
/// </summary>
public sealed class FrameReader(Func<Memory<byte>, CancellationToken, ValueTask<int>> read)
{
    private const int Capacity = 8 * 1024; // std::io::BufReader's default capacity.
    private readonly byte[] _buffer = new byte[Capacity];
    private int _start;
    private int _end;

    public async ValueTask<byte[]> ReadFrameAsync(int limit, CancellationToken cancellation)
    {
        var output = new List<byte>();
        while (true)
        {
            if (_start == _end)
            {
                _start = 0;
                _end = await read(_buffer, cancellation).ConfigureAwait(false);
                if (_end == 0)
                {
                    throw new TransportException(TransportErrorKind.UnexpectedEof, "incomplete control frame");
                }
            }
            var available = _buffer.AsSpan(_start, _end - _start);
            var end = available.IndexOf((byte)'\n');
            var consumed = end < 0 ? available.Length : end + 1;
            if ((long)output.Count + consumed > limit)
            {
                throw new TransportException(TransportErrorKind.InvalidData, "control frame exceeds its limit");
            }
            output.AddRange(available[..consumed]);
            _start += consumed;
            if (end >= 0)
            {
                output.RemoveAt(output.Count - 1);
                return output.ToArray();
            }
            if (output.Count == limit)
            {
                throw new TransportException(TransportErrorKind.InvalidData, "control frame lacks its bounded delimiter");
            }
        }
    }
}
