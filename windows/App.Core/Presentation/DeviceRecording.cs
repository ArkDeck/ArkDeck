using System.Text;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

public sealed record DeviceRecordingFrame(string Name, byte[] Bytes, double DurationSeconds);
public sealed record DeviceRecordingSource(string ArchiveArtifactId, string ArchiveSha256, long ArchiveBytes, string SequenceArtifactId, string SequenceSha256, long SequenceBytes);
public sealed record DeviceRecording(string JobId, DeviceScreenTarget Target, IReadOnlyList<DeviceRecordingFrame> Frames,
    int Width, int Height, int RequestedFrames, int MissingFrames, double ObservedFramesPerSecond)
{
    public double DurationSeconds => Frames.Sum(f => f.DurationSeconds);
    public DeviceRecordingSource? Source { get; init; }
}
public sealed record DeviceRecordingOutcome(DeviceRecording? Recording, string? Failure, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);
public sealed record DeviceRecordingStorage(int FrameCount, long RequiredBytes, long? RemainingBytes, int? FramesThatFit, string? Refusal)
{
    public bool Checked => RemainingBytes is not null;
}

/// <summary>The same measured estimate as the macOS workspace, sent unchanged to Runtime's storage preflight.</summary>
public static class DeviceRecordingBudget
{
    public static long Bytes(int frameCount) => frameCount is >= 2 and <= 300
        ? Math.Max(1L << 20, frameCount * 42573L * 3 / 2 + (64L << 10)) : throw new ArgumentOutOfRangeException(nameof(frameCount));
    public static int FramesThatFit(long remaining) => Enumerable.Range(2, 299).Where(n => Bytes(n) <= remaining).DefaultIfEmpty(0).Max();
    public static RuntimeRequest Request(DeviceScreenTarget target, int frameCount) => RuntimeRequest.Build("toolkit-recording", "capture.screen-sequence", 1,
        target.TargetId, target.BindingRevision, [("frameCount", JsonNumber.FromInt64(frameCount)), ("imageType", new JsonString("jpeg")),
            ("totalArtifactByteBudget", JsonNumber.FromInt64(Bytes(frameCount)))], ["hardwareEvidence"], DeviceOperations.Client);
}

/// <summary>Parses bounded, whole verified products locally; no external tar process or assumed frame cadence.</summary>
public static class DeviceRecordingProducts
{
    public const int MaximumArchiveBytes = 64 * 1024 * 1024;
    public static DeviceRecording Parse(string jobId, DeviceScreenTarget target, int requested, byte[] archive, byte[] sequence)
    {
        _ = DeviceRecordingBudget.Bytes(requested);
        var frames = Archive(archive);
        if (sequence.Length is < 2 or > 65536) throw new InvalidDataException("Recording timings exceed the bounded document size");
        var index = Json.Object(StrictJson.Parse(sequence), "screen sequence timings");
        if (Json.OptionalString(index, "schemaVersion") != "1.0.0" || TypedJson.Required(index, "requestedFrameCount", TypedJson.Int64) != requested
            || TypedJson.Required(index, "capturedFrameCount", TypedJson.Int64) != frames.Count || frames.Count < 1 || frames.Count > requested
            || TypedJson.Required(index, "framesMissing", TypedJson.Int64) != requested - frames.Count)
            throw new InvalidDataException("Recording counts do not match the actual frames");
        var durations = TypedJson.Required(index, "frameDurationsSeconds", v => TypedJson.List(v, Number));
        if (durations.Count != frames.Count || durations.Any(n => !double.IsFinite(n) || n <= 0)
            || !double.IsFinite(durations.Sum()) || durations.Sum() > TimeSpan.MaxValue.TotalSeconds)
            throw new InvalidDataException("Recording has no matching positive observed frame timings");
        var rate = TypedJson.Required(index, "observedFramesPerSecond", Number);
        var measured = frames.Count / durations.Sum();
        if (!double.IsFinite(rate) || Math.Abs(rate - measured) > Math.Max(1e-9, measured * 1e-9))
            throw new InvalidDataException("Recording rate does not match its observed frame durations");
        var size = DeviceScreenImages.Dimensions(frames[0].Bytes);
        if (frames.Any(f => DeviceScreenImages.Dimensions(f.Bytes) != size)) throw new InvalidDataException("Recording frame dimensions changed");
        return new(jobId, target, frames.Select((f, i) => new DeviceRecordingFrame(f.Name, f.Bytes, durations[i])).ToArray(), size.Width, size.Height,
            requested, requested - frames.Count, rate);
    }
    private static double Number(JsonValue value) => value is JsonNumber n ? n.AsDouble() : throw new InvalidDataException("Recording timing is not numeric");

    public static IReadOnlyList<(string Name, byte[] Bytes)> Archive(byte[] archive)
    {
        if (archive.Length is < 1024 or > MaximumArchiveBytes || archive.Length % 512 != 0) throw new InvalidDataException("Recording archive is truncated or too large");
        var frames = new SortedDictionary<string, byte[]>(StringComparer.Ordinal);
        var ended = false;
        for (var offset = 0; offset + 512 <= archive.Length;)
        {
            var header = archive.AsSpan(offset, 512);
            if (header.IndexOfAnyExcept((byte)0) < 0)
            {
                if (archive.AsSpan(offset).IndexOfAnyExcept((byte)0) >= 0) throw new InvalidDataException("Recording archive has data after its terminator");
                ended = true;
                break;
            }
            if (!header.Slice(257, 5).SequenceEqual("ustar"u8)) throw new InvalidDataException("Recording archive is not the provider's tar format");
            var checksum = Octal(header.Slice(148, 8));
            var actual = 0L;
            for (var i = 0; i < 512; i++) actual += i is >= 148 and < 156 ? 32 : header[i];
            if (checksum != actual) throw new InvalidDataException("Recording archive header checksum differs");
            var name = Field(header.Slice(0, 100));
            if (Field(header.Slice(345, 155)).Length != 0) throw new InvalidDataException("Recording archive has an unexpected path prefix");
            var count = Octal(header.Slice(124, 12));
            if (count is < 0 or > DeviceScreenImages.MaximumBytes || offset + 512L + count > archive.Length) throw new InvalidDataException("Recording archive member is truncated or too large");
            var type = header[156];
            if (type == (byte)'5' && name == "./" && count == 0) { offset += 512; continue; }
            if (type is not (0 or (byte)'0')) throw new InvalidDataException("Recording archive has an unexpected member type");
            var leaf = name.StartsWith("./", StringComparison.Ordinal) ? name[2..] : name;
            var parts = leaf.Split('.');
            if (parts.Length != 2 || parts[0].Length != 4 || !parts[0].All(c => c is >= '0' and <= '9') || parts[1] is not ("jpeg" or "png")
                || count == 0 || frames.Count >= 300 || !frames.TryAdd(leaf, archive.AsSpan(offset + 512, (int)count).ToArray()))
                throw new InvalidDataException("Recording archive has an unexpected or duplicate frame");
            offset = checked(offset + 512 + (int)((count + 511) / 512 * 512));
        }
        if (!ended || frames.Count == 0) throw new InvalidDataException("Recording archive has no complete frame sequence");
        return frames.Select(f => (f.Key, f.Value)).ToArray();
    }
    private static string Field(ReadOnlySpan<byte> value)
    {
        var end = value.IndexOf((byte)0);
        if (end >= 0) value = value[..end];
        if (value.IndexOfAnyInRange((byte)128, byte.MaxValue) >= 0) throw new InvalidDataException("Recording archive name is not ASCII");
        return Encoding.ASCII.GetString(value);
    }
    private static long Octal(ReadOnlySpan<byte> value)
    {
        var text = Field(value).Trim();
        if (text.Length == 0 || !text.All(c => c is >= '0' and <= '7')) throw new InvalidDataException("Recording archive has an invalid size or checksum");
        return Convert.ToInt64(text, 8);
    }
}

public sealed partial class SurfaceLoader
{
    public async Task<DeviceRecordingStorage> DeviceRecordingStorageAsync(int frameCount)
    {
        var needed = DeviceRecordingBudget.Bytes(frameCount);
        var result = await channel.RequestAsync("artifact.quota", Params()).ConfigureAwait(false);
        if (result.Failure is not null) return new(frameCount, needed, null, null, null);
        try
        {
            var quota = Json.Object(result.Value!, "Artifact quota");
            var remaining = TypedJson.Required(quota, "remainingBytes", TypedJson.Int64);
            if (remaining < 0) throw new InvalidDataException("Negative Artifact quota");
            return new(frameCount, needed, remaining, DeviceRecordingBudget.FramesThatFit(remaining), needed > remaining ? "Insufficient Artifact storage; choose a shorter recording" : null);
        }
        catch (Exception error) when (DeviceReadError(error)) { return new(frameCount, needed, null, null, null); }
    }

    public async Task<DeviceRecordingOutcome> RecordDeviceScreenAsync(DeviceScreenTarget target, int frameCount)
    {
        var gate = await DeviceScreenGateAsync(target.TargetId, target).ConfigureAwait(false);
        if (gate.RefusalFor(DeviceOperations.Recording) is { } refusal) return new(null, refusal, gate.DaemonFailure, gate.Reached);
        var storage = await DeviceRecordingStorageAsync(frameCount).ConfigureAwait(false);
        if (storage.Refusal is not null) return new(null, storage.Refusal, null, true);
        var execution = await ExecuteDeviceOnceAsync(DeviceRecordingBudget.Request(target, frameCount), target, DeviceOperations.Recording, gate).ConfigureAwait(false);
        if (execution.Shown is null || !execution.Shown.Terminal.Succeeded) return new(null, execution.Detail, execution.Failure, true);
        try
        {
            var rows = await DeviceProductsAsync(execution.Shown.Terminal.JobId).ConfigureAwait(false);
            async Task<byte[]> Product(string name, int maximum, string mediaType, string privacy)
            {
                var choices = rows.Where(r => r.Artifact.Name == name).ToArray();
                if (choices is not [var source] || !source.Matches(execution.Shown.Terminal.JobId, target, DeviceOperations.Recording, privacy)
                    || source.Artifact.MediaType != mediaType || source.Artifact.ByteCount > maximum)
                    throw new InvalidDataException("Recording has no unique verified same-Job " + name);
                var read = await new ArtifactExporter(channel).ReadAsync(execution.Shown.Terminal.JobId, source.Artifact, allowSensitive: true).ConfigureAwait(false);
                return read.Bytes ?? throw new InvalidDataException("The complete recording product could not be verified");
            }
            var archive = await Product("frames.tar", DeviceRecordingProducts.MaximumArchiveBytes, "application/x-tar", "sensitive").ConfigureAwait(false);
            var sequence = await Product("sequence.json", 65536, "application/json", "standard").ConfigureAwait(false);
            var archiveReceipt = rows.Single(r => r.Artifact.Name == "frames.tar").Artifact;
            var sequenceReceipt = rows.Single(r => r.Artifact.Name == "sequence.json").Artifact;
            return new(DeviceRecordingProducts.Parse(execution.Shown.Terminal.JobId, target, frameCount, archive, sequence) with
            { Source = new(archiveReceipt.ArtifactId, archiveReceipt.Digest!, archiveReceipt.ByteCount, sequenceReceipt.ArtifactId, sequenceReceipt.Digest!, sequenceReceipt.ByteCount) }, null, null, true);
        }
        catch (Exception error) when (DeviceReadError(error)) { return new(null, "The recording products are unreadable: " + error.Message, null, true); }
    }
}
