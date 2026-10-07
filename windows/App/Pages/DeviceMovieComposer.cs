using System.Security.Cryptography;
using ArkDeck.App.Core.Presentation;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace ArkDeck.App.Pages;

internal sealed record DeviceMovie(string Path, long ByteCount, string Sha256, double DurationSeconds, uint Width, uint Height);
internal sealed record DeviceMovieOutcome(DeviceMovie? Movie, string? Failure);
internal enum DeviceMovieStage { Composing, Validating }

/// <summary>Native local composition of the verified stills. The MP4 is a local derivative, never a Runtime Artifact or hardware verdict.</summary>
internal static class DeviceMovieComposer
{
    internal static async Task<DeviceMovieOutcome> ComposeAsync(DeviceRecording recording, string cacheRoot, Action<DeviceMovieStage> stage)
    {
        var parent = System.IO.Path.GetFullPath(System.IO.Path.Combine(cacheRoot, "device-recordings"));
        var directory = System.IO.Path.Combine(parent, Guid.NewGuid().ToString("N"));
        var keep = false;
        try
        {
            if (Directory.Exists(directory)) throw new IOException("Recording output already exists");
            Directory.CreateDirectory(directory);
            stage(DeviceMovieStage.Composing);
            var composition = new MediaComposition();
            foreach (var frame in recording.Frames)
            {
                var path = System.IO.Path.Combine(directory, frame.Name);
                await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) await output.WriteAsync(frame.Bytes);
                var image = await StorageFile.GetFileFromPathAsync(path);
                composition.Clips.Add(await MediaClip.CreateFromImageFileAsync(image, TimeSpan.FromSeconds(frame.DurationSeconds)));
            }
            var folder = await StorageFolder.GetFolderFromPathAsync(directory);
            var movie = await folder.CreateFileAsync("recording.mp4", CreationCollisionOption.FailIfExists);
            var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD720p);
            profile.Video.Width = (uint)recording.Width;
            profile.Video.Height = (uint)recording.Height;
            var result = await composition.RenderToFileAsync(movie, MediaTrimmingPreference.Precise, profile);
            if (result != TranscodeFailureReason.None) throw new InvalidDataException("The installed native encoder did not complete the movie");
            stage(DeviceMovieStage.Validating);
            var clip = await MediaClip.CreateFromFileAsync(movie);
            var properties = clip.GetVideoEncodingProperties();
            var length = new FileInfo(movie.Path).Length;
            if (length is < 1 or > 512L * 1024 * 1024 || properties.Width != recording.Width || properties.Height != recording.Height
                || Math.Abs(clip.OriginalDuration.TotalSeconds - recording.DurationSeconds) > .25)
                throw new InvalidDataException("The native movie dimensions or duration do not match its source frames");
            string digest;
            await using (var input = new FileStream(movie.Path, FileMode.Open, FileAccess.Read, FileShare.Read))
                digest = Convert.ToHexStringLower(await SHA256.HashDataAsync(input));
            foreach (var frame in recording.Frames) File.Delete(System.IO.Path.Combine(directory, frame.Name));
            keep = true;
            return new(new(movie.Path, length, digest, clip.OriginalDuration.TotalSeconds, properties.Width, properties.Height), null);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or ArgumentException
            or System.Runtime.InteropServices.COMException)
        {
            return new(null, "Native local movie composition is unavailable; the verified frames and observed timings remain available");
        }
        finally
        {
            // Only the fresh random child owned by this invocation may be removed.
            if (!keep && Directory.Exists(directory) && System.IO.Path.GetFullPath(directory).StartsWith(parent + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                try { Directory.Delete(directory, recursive: true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}
