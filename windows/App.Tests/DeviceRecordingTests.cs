using System.Formats.Tar;
using System.Security.Cryptography;
using System.Text;
using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

[TestClass]
public sealed class DeviceRecordingTests
{
    private static readonly DeviceScreenTarget Target = new("target-fixture", 3, new string('a', 64), "Bench");
    private static byte[] Image()
    {
        var document = (JsonObject)StrictJson.Parse(File.ReadAllBytes(RepoPaths.At("windows", "App.Core", "Testing", "Recorded", "viewer-workspace.json")));
        var row = ((JsonArray)document["uiDump"]["artifacts"]).Items.Single(r => ((JsonString)r["name"]).Value == "screenshot.png");
        return Convert.FromBase64String(((JsonString)document["uiDump"]["bytes"][((JsonString)row["artifactId"]).Value]).Value);
    }
    private static byte[] Archive(params string[] names)
    {
        using var stream = new MemoryStream();
        using (var writer = new TarWriter(stream, TarEntryFormat.Ustar, leaveOpen: true))
            foreach (var name in names) writer.WriteEntry(new UstarTarEntry(TarEntryType.RegularFile, name) { DataStream = new MemoryStream(Image()) });
        return stream.ToArray();
    }
    private static byte[] Sequence(string durations = "[1,0.5]", int requested = 3, int captured = 2, double rate = 4.0 / 3) =>
        Encoding.UTF8.GetBytes($$"""{"schemaVersion":"1.0.0","requestedFrameCount":{{requested}},"capturedFrameCount":{{captured}},"frameDurationsSeconds":{{durations}},"framesMissing":{{requested-captured}},"observedFramesPerSecond":{{rate.ToString("R",System.Globalization.CultureInfo.InvariantCulture)}}}""");

    [TestMethod]
    public void MeasuredDurationsAndMissingFramesArePreserved()
    {
        var parsed = DeviceRecordingProducts.Parse("job-recording", Target, 3, Archive("0002.png", "0001.png"), Sequence());
        Assert.AreEqual((400, 800, 3, 1, 1.5), (parsed.Width, parsed.Height, parsed.RequestedFrames, parsed.MissingFrames, parsed.DurationSeconds));
        CollectionAssert.AreEqual(new[] { "0001.png", "0002.png" }, parsed.Frames.Select(f => f.Name).ToArray());
        CollectionAssert.AreEqual(new[] { 1d, .5d }, parsed.Frames.Select(f => f.DurationSeconds).ToArray());
        Assert.AreEqual(4.0 / 3, parsed.ObservedFramesPerSecond);
    }

    [TestMethod]
    public void TruncatedCorruptAndEscapingArchivesAreRefusedWhole()
    {
        var archive = Archive("0001.png", "0002.png");
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Archive(archive[..^1024]));
        var broken = archive.ToArray(); broken[20] ^= 1;
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Archive(broken));
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Archive(Archive("../0001.png")));
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Archive(Archive("0001.png", "0001.png")));
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Archive(Archive("not-a-frame.txt")));
    }

    [TestMethod]
    public void TimingsMustDescribeTheActualRequestedAndCapturedSequence()
    {
        var archive = Archive("0001.png", "0002.png");
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Parse("job", Target, 3, archive, Sequence("[1]")));
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Parse("job", Target, 3, archive, Sequence("[1,0]")));
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Parse("job", Target, 3, archive, Sequence(requested: 4)));
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Parse("job", Target, 3, archive, Sequence(rate: 30)));
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Parse("job", Target, 3, archive, Sequence(captured: 1)));
        // The actual Provider measures every attempted frame, including failed attempts.
        // Do not discard a span or invent its image to make a local movie look complete.
        Assert.ThrowsExactly<InvalidDataException>(() => DeviceRecordingProducts.Parse("job", Target, 3, Archive("0001.png", "0003.png"), Sequence("[0.5,0.25,0.5]", rate: 1.6)));
    }

    [TestMethod]
    public async Task PublishedStandardTimingsAndSensitiveArchiveReadWholeOnTheSameJob()
    {
        var channel = ArkDeck.App.Core.Testing.ScriptedDaemon.Channel(ArkDeck.App.Core.Testing.ScriptedDaemon.DeviceScreen);
        var loader = new SurfaceLoader(channel);
        var target = (await loader.DeviceScreenGateAsync(ArkDeck.App.Core.Testing.ScriptedDaemon.FixtureTargetId)).Target!;
        var outcome = await loader.RecordDeviceScreenAsync(target, 2);
        Assert.IsNull(outcome.Failure, outcome.Failure);
        Assert.AreEqual((2, 0, 1d), (outcome.Recording!.Frames.Count, outcome.Recording.MissingFrames, outcome.Recording.DurationSeconds));
        Assert.IsNotNull(outcome.Recording.Source);
        Assert.AreEqual(64, outcome.Recording.Source.SequenceSha256.Length);
        Assert.IsTrue(outcome.Recording.Source.ArchiveBytes > 1024);
    }

    [TestMethod]
    public async Task ChangedRetainedMovieNeverOverwritesTheSelectedDestination()
    {
        var directory = Directory.CreateTempSubdirectory("arkdeck-device-movie-export-");
        try
        {
            var source = Path.Combine(directory.FullName, "retained.mp4");
            var destination = Path.Combine(directory.FullName, "saved.mp4");
            byte[] original = [1, 2, 3, 4];
            byte[] previousExport = [7, 8, 9];
            var digest = Convert.ToHexStringLower(SHA256.HashData(original));
            await File.WriteAllBytesAsync(source, original);
            await File.WriteAllBytesAsync(destination, previousExport);
            await DeviceMovieExport.ExportAsync(source, destination, original.Length, digest);
            CollectionAssert.AreEqual(original, await File.ReadAllBytesAsync(destination));
            // Same-length replacement catches the missing whole-hash revalidation, not just size drift.
            await File.WriteAllBytesAsync(source, [4, 3, 2, 1]);
            await File.WriteAllBytesAsync(destination, previousExport);
            await Assert.ThrowsExactlyAsync<InvalidDataException>(() => DeviceMovieExport.ExportAsync(source, destination, original.Length, digest));
            CollectionAssert.AreEqual(previousExport, await File.ReadAllBytesAsync(destination));
            await File.WriteAllBytesAsync(source, [1]);
            await Assert.ThrowsExactlyAsync<InvalidDataException>(() => DeviceMovieExport.ExportAsync(source, destination, original.Length, digest));
            CollectionAssert.AreEqual(previousExport, await File.ReadAllBytesAsync(destination));
            Assert.AreEqual(0, Directory.GetFiles(directory.FullName, "*.partial").Length);
        }
        finally { directory.Delete(recursive: true); }
    }

    [TestMethod]
    public async Task RetainedMovieCannotBeExportedOverItselfOrThroughASymbolicLink()
    {
        var directory = Directory.CreateTempSubdirectory("arkdeck-device-movie-source-");
        try
        {
            var source = Path.Combine(directory.FullName, "retained.mp4");
            var link = Path.Combine(directory.FullName, "linked.mp4");
            var destination = Path.Combine(directory.FullName, "saved.mp4");
            byte[] bytes = [1, 2, 3, 4];
            await File.WriteAllBytesAsync(source, bytes);
            var digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
            await Assert.ThrowsExactlyAsync<IOException>(() => DeviceMovieExport.ExportAsync(source, source, bytes.Length, digest));
            File.CreateSymbolicLink(link, source);
            await Assert.ThrowsExactlyAsync<IOException>(() => DeviceMovieExport.ExportAsync(link, destination, bytes.Length, digest));
            Assert.IsFalse(File.Exists(destination));
            CollectionAssert.AreEqual(bytes, await File.ReadAllBytesAsync(source));
        }
        finally { directory.Delete(recursive: true); }
    }

    [TestMethod]
    public void FixedFrameCountAndRuntimeBudgetMatchTheStorageEstimate()
    {
        var small = DeviceRecordingBudget.Bytes(2);
        Assert.AreEqual(1L << 20, small);
        var maximum = DeviceRecordingBudget.Bytes(300);
        Assert.AreEqual(300 * 42573L * 3 / 2 + 65536, maximum);
        Assert.AreEqual(299, DeviceRecordingBudget.FramesThatFit(maximum - 1));
        Assert.AreEqual(0, DeviceRecordingBudget.FramesThatFit(small - 1));
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => DeviceRecordingBudget.Bytes(1));
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => DeviceRecordingBudget.Bytes(301));
        var request = (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(DeviceRecordingBudget.Request(Target, 300).Json));
        Assert.AreEqual(300d, ((JsonNumber)request["inputs"]["frameCount"]).AsDouble());
        Assert.AreEqual((double)maximum, ((JsonNumber)request["inputs"]["totalArtifactByteBudget"]).AsDouble());
    }
}
