using System.Buffers.Binary;
using System.Text;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>The exact adopted identity a Device action is prepared for. A name is presentation only.</summary>
public sealed record DeviceScreenTarget(string TargetId, long BindingRevision, string StableIdentitySha256, string Title)
{
    public bool SameBinding(DeviceScreenTarget other) => TargetId == other.TargetId && BindingRevision == other.BindingRevision
                                                       && StableIdentitySha256 == other.StableIdentitySha256;

    public static DeviceScreenTarget? Of(TargetDetail detail) => detail.BindingRevision > 0 && ArtifactSummary.IsSha256(detail.StablePhysicalIdentitySha256)
        ? new(detail.TargetId, detail.BindingRevision, detail.StablePhysicalIdentitySha256, detail.DisplayName ?? detail.TargetId) : null;
}

/// <summary>Whole immutable Runtime screenshot bytes and their actual Job/binding. Historical stills never enable input.</summary>
public sealed record DeviceScreenFrame(byte[] Bytes, int Width, int Height, string JobId, string ArtifactId, string Digest,
    DeviceScreenTarget Target, string CapturedAtUtc, bool Historical);

public enum DeviceInputVerdict { Confirmed, Failed, Unknown }

public sealed record DeviceInputOutcome(DeviceInputVerdict Verdict, string? JobId, string Detail, ArkDeck.ClientKit.ControlFailure? DaemonFailure = null)
    : SurfaceState(DaemonFailure, JobId is not null || DaemonFailure is null);

/// <summary>Local screen liveness, never Runtime freshness or authority. Only a new explicit capture enables input.</summary>
public sealed class DeviceScreenSession
{
    public DeviceScreenTarget? Target { get; private set; }
    public DeviceScreenFrame? Frame { get; private set; }
    public bool Current { get; private set; }
    public bool Busy { get; private set; }
    public bool HistoryPending { get; private set; }
    public long Generation { get; private set; }
    public bool CanInput => !Busy && Current && Frame is { Historical: false } && Target is not null && Frame.Target.SameBinding(Target);

    public void Select(DeviceScreenTarget? target)
    {
        if (target is null || Target is null || !Target.SameBinding(target))
        {
            Generation++;
            Frame = null;
            Current = false;
        }
        Target = target;
    }

    public void Invalidate() { Generation++; Frame = null; Current = false; }
    public void RequestHistory() { Invalidate(); HistoryPending = true; }
    public void ClearHistory() => HistoryPending = false;
    public long? Begin(bool input = false)
    {
        if (Busy || Target is null || (input && !CanInput)) return null;
        if (!input) Current = false;
        Busy = true;
        return Generation;
    }
    public long? BeginHistory()
    {
        if (Busy) return null;
        HistoryPending = false;
        Current = false;
        Busy = true;
        return Generation;
    }
    public bool Captured(long generation, DeviceScreenFrame? frame)
    {
        Busy = false;
        if (generation != Generation || frame is null) return false;
        if (!frame.Historical && (Target is null || !Target.SameBinding(frame.Target))) return false;
        Frame = frame;
        Current = !frame.Historical;
        return true;
    }
    public bool Settled(long generation, DeviceInputVerdict verdict, bool failedMayHaveEffect = false)
    {
        Busy = false;
        if (generation != Generation) return false;
        if (verdict != DeviceInputVerdict.Failed || failedMayHaveEffect) Current = false;
        return true;
    }
    public void End() => Busy = false;
}

public enum DeviceGesture { Tap, LongPress, Swipe }
public sealed record DevicePoint(double X, double Y);

/// <summary>Uniform-fit image rectangle; letterboxing is never a device coordinate.</summary>
public sealed record DeviceViewport(double X, double Y, double Width, double Height, int PixelsWide, int PixelsHigh)
{
    public static DeviceViewport? Fit(double width, double height, int pixelsWide, int pixelsHigh)
    {
        if (!double.IsFinite(width) || !double.IsFinite(height) || width <= 0 || height <= 0 || pixelsWide is < 1 or > 32767 || pixelsHigh is < 1 or > 32767) return null;
        var scale = Math.Min(width / pixelsWide, height / pixelsHigh);
        return new((width - pixelsWide * scale) / 2, (height - pixelsHigh * scale) / 2, pixelsWide * scale, pixelsHigh * scale, pixelsWide, pixelsHigh);
    }
    public bool Contains(DevicePoint point) => double.IsFinite(point.X) && double.IsFinite(point.Y)
        && point.X >= X && point.Y >= Y && point.X <= X + Width && point.Y <= Y + Height;
    public (int X, int Y) Map(DevicePoint point) =>
        (Math.Min((int)(Math.Clamp((point.X - X) / Width, 0, 1) * PixelsWide), PixelsWide - 1),
            Math.Min((int)(Math.Clamp((point.Y - Y) / Height, 0, 1) * PixelsHigh), PixelsHigh - 1));
}

public sealed record DeviceGestureRequest(DeviceGesture Gesture, int X, int Y, int Width, int Height, int? ToX = null, int? ToY = null, int? DurationMs = null)
{
    public string OperationId => Gesture switch { DeviceGesture.Tap => "input.tap", DeviceGesture.LongPress => "input.long-press", _ => "input.swipe" };
    public bool IsValid => Enum.IsDefined(Gesture) && Width is > 0 and <= 32767 && Height is > 0 and <= 32767 && X >= 0 && X < Width && Y >= 0 && Y < Height
        && (Gesture != DeviceGesture.Tap || (ToX is null && ToY is null && DurationMs is null))
        && (Gesture != DeviceGesture.LongPress || (ToX is null && ToY is null))
        && (Gesture != DeviceGesture.Swipe || (ToX >= 0 && ToX < Width && ToY >= 0 && ToY < Height && DurationMs is >= 80 and <= 2000))
        && (Gesture != DeviceGesture.LongPress || DurationMs is >= 500 and <= 2000);
    public IEnumerable<(string Key, JsonValue Value)> Inputs
    {
        get
        {
            yield return ("displayWidth", JsonNumber.FromInt64(Width));
            yield return ("displayHeight", JsonNumber.FromInt64(Height));
            yield return (Gesture == DeviceGesture.Swipe ? "fromX" : "x", JsonNumber.FromInt64(X));
            yield return (Gesture == DeviceGesture.Swipe ? "fromY" : "y", JsonNumber.FromInt64(Y));
            if (Gesture == DeviceGesture.Swipe)
            {
                yield return ("toX", JsonNumber.FromInt64(ToX!.Value));
                yield return ("toY", JsonNumber.FromInt64(ToY!.Value));
            }
            if (DurationMs is { } duration) yield return ("durationMs", JsonNumber.FromInt64(duration));
        }
    }
    public static DeviceGestureRequest? Classify(DevicePoint start, DevicePoint end, double travel, double seconds, DeviceViewport viewport)
    {
        if (!viewport.Contains(start) || !double.IsFinite(end.X) || !double.IsFinite(end.Y) || !double.IsFinite(travel) || !double.IsFinite(seconds) || travel < 0 || seconds < 0) return null;
        var from = viewport.Map(start);
        if (travel >= 6)
        {
            var to = viewport.Map(end);
            return new(DeviceGesture.Swipe, from.X, from.Y, viewport.PixelsWide, viewport.PixelsHigh, to.X, to.Y, (int)Math.Clamp(seconds * 1000, 80, 2000));
        }
        return seconds >= .5
            ? new(DeviceGesture.LongPress, from.X, from.Y, viewport.PixelsWide, viewport.PixelsHigh, DurationMs: (int)Math.Clamp(seconds * 1000, 500, 2000))
            : new(DeviceGesture.Tap, from.X, from.Y, viewport.PixelsWide, viewport.PixelsHigh);
    }
}

public sealed record DeviceKeyboardCommand(string? Key = null, string? Text = null, bool ClipboardConsent = false)
{
    public static readonly IReadOnlyList<string> Keys = ["enter", "backspace", "tab", "escape", "arrowUp", "arrowDown", "arrowLeft", "arrowRight", "home", "back"];
    public bool IsValid => Key is not null ? Text is null && Keys.Contains(Key) : ClipboardConsent && !string.IsNullOrEmpty(Text)
        && Encoding.UTF8.GetByteCount(Text) <= 512 && !Text.EnumerateRunes().Any(r => Rune.GetUnicodeCategory(r) == System.Globalization.UnicodeCategory.Control);
    // Payload is private upload data. Its text is never a Job parameter or a presentation failure.
    internal byte[] Payload() => Encoding.UTF8.GetBytes((Key is not null
        ? SurfaceLoader.Params(("kind", new JsonString("key")), ("key", new JsonString(Key)))
        : SurfaceLoader.Params(("kind", new JsonString("text")), ("text", new JsonString(Text!)), ("allowDeviceClipboard", JsonBool.True))).ToString());
}

public static class DeviceScreenImages
{
    public const int MaximumBytes = 32 * 1024 * 1024;
    public static (int Width, int Height) Dimensions(byte[] bytes)
    {
        if (bytes.Length is < 24 or > MaximumBytes) throw new InvalidDataException("Screenshot size is outside the bounded format");
        if (bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) && bytes.AsSpan(12, 4).SequenceEqual("IHDR"u8))
        {
            return Bounded(BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16, 4)), BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20, 4)));
        }
        if (bytes[0] == 255 && bytes[1] == 216)
        {
            for (var offset = 2; offset + 4 <= bytes.Length;)
            {
                if (bytes[offset] != 255) break;
                var marker = bytes[offset + 1];
                if (marker == 255) { offset++; continue; }
                if (marker is 216 or >= 208 and <= 217) { offset += 2; continue; }
                var count = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(offset + 2, 2));
                if (count < 2 || offset + 2 + count > bytes.Length || marker == 218) break;
                if (marker is >= 192 and <= 207 && marker is not (196 or 200 or 204) && count >= 8)
                    return Bounded(BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(offset + 7, 2)), BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(offset + 5, 2)));
                offset += 2 + count;
            }
        }
        throw new InvalidDataException("Screenshot is not a bounded PNG or JPEG");
    }
    private static (int, int) Bounded(uint width, uint height) => width is > 0 and <= 32767 && height is > 0 and <= 32767 && (long)width * height <= 64L * 1024 * 1024
        ? ((int)width, (int)height) : throw new InvalidDataException("Screenshot dimensions exceed the display bound");
}
