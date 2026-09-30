using System.Diagnostics;
using System.Text.Json;
using ArkDeck.Spk4.Fixtures;
using ArkDeck.Spk4.Pages;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ArkDeck.Spk4.Bench;

/// <summary>Scripted SPK-4 benchmark (design §H.4 (a), §I.2 UI rows): loads the 10k-row History
/// list and the 20k-node Viewer tree, scrolls each for a fixed number of frames and records the
/// UI-thread frame interval from <see cref="CompositionTarget.Rendering"/>, plus working set.
/// Writes one JSON file per run into the bench directory.</summary>
public sealed class BenchRunner(MainWindow window, string outDir)
{
    private const int FramesPerPass = 600;   // ~10 s at 60 Hz per pass
    private const double SteadyPxPerFrame = 48; // ~2,900 px/s: a fast wheel/drag scroll
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    public async Task RunAsync()
    {
        await Frames(2); // the first frame has been presented before any mark is written
        Directory.CreateDirectory(outDir);
        var path = Path.Combine(outDir, $"bench-{Environment.ProcessId}.json");
        using var stream = File.Create(path);
        using var json = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true });
        json.WriteStartObject();
        json.WriteString("schema", "arkdeck-spk4-bench/v1");
        json.WriteString("utc", DateTime.UtcNow.ToString("O"));
        json.WriteString("osVersion", Environment.OSVersion.VersionString);
        json.WriteString("processArchitecture", System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString());
        json.WriteNumber("processorCount", Environment.ProcessorCount);
        json.WriteBoolean("packaged", IsPackaged());
        json.WriteNumber("appCtorMs", Math.Round(App.AppCtorMs, 1));
        json.WriteNumber("firstFrameMs", Math.Round(MainWindow.FirstFrameMs, 1));
        WriteMemory(json, "memoryAtStart");

        foreach (var tag in new[] { "history", "viewer" })
        {
            json.WriteStartObject(tag);
            var nav = Stopwatch.StartNew();
            window.Select(tag);
            var page = (IMeasuredPage)window.ContentFrame.Content;
            var timing = await page.Ready;
            json.WriteNumber("items", timing.Items);
            json.WriteNumber("generateMs", Math.Round(timing.GenerateMs, 1));
            json.WriteNumber("bindToRowsOnScreenMs", Math.Round(timing.BindToFirstFrameMs, 1));
            json.WriteNumber("navigateToRowsOnScreenMs", Math.Round(nav.Elapsed.TotalMilliseconds, 1));
            if (page is ViewerPage)
            {
                json.WriteNumber("viewerFixtureMs", Math.Round(ViewerPage.FixtureMs, 1));
                json.WriteNumber("treeViewNodeBuildMs", Math.Round(ViewerPage.NodeBuildMs, 1));
            }
            WriteMemory(json, "memoryAfterLoad");
            await Frames(30);
            var scroller = page.FindScroller() ?? throw new InvalidOperationException($"{tag}: no ScrollViewer");
            json.WriteNumber("scrollableHeightPx", Math.Round(scroller.ScrollableHeight));
            WriteSummary(json, "steadyScroll", await ScrollAsync(scroller, _ => SteadyPxPerFrame));
            // Page-sized jumps every frame: every frame realises a fresh viewport of rows.
            WriteSummary(json, "pageJumpScroll", await ScrollAsync(scroller, s => s.ViewportHeight));
            WriteMemory(json, "memoryAfterScroll");
            json.WriteEndObject();
        }
        json.WriteEndObject();
        await json.FlushAsync();
    }

    private async Task<List<double>> ScrollAsync(ScrollViewer scroller, Func<ScrollViewer, double> step)
    {
        scroller.ChangeView(null, 0, null, true);
        await Frames(10);
        var frames = new List<double>(FramesPerPass);
        var tcs = new TaskCompletionSource();
        var offset = 0.0;
        var direction = 1;
        var last = -1.0;
        void OnRendering(object? sender, object e)
        {
            var now = _clock.Elapsed.TotalMilliseconds;
            if (last >= 0) frames.Add(now - last);
            last = now;
            if (frames.Count >= FramesPerPass)
            {
                CompositionTarget.Rendering -= OnRendering;
                tcs.TrySetResult();
                return;
            }
            offset += direction * step(scroller);
            if (offset >= scroller.ScrollableHeight) { offset = scroller.ScrollableHeight; direction = -1; }
            else if (offset <= 0) { offset = 0; direction = 1; }
            scroller.ChangeView(null, offset, null, true);
        }
        CompositionTarget.Rendering += OnRendering;
        await tcs.Task;
        return frames;
    }

    private static Task Frames(int count)
    {
        var tcs = new TaskCompletionSource();
        var seen = 0;
        void OnRendering(object? s, object e)
        {
            if (++seen < count) return;
            CompositionTarget.Rendering -= OnRendering;
            tcs.TrySetResult();
        }
        CompositionTarget.Rendering += OnRendering;
        return tcs.Task;
    }

    private static void WriteSummary(Utf8JsonWriter json, string name, List<double> frames)
    {
        var s = FrameStats.Summarize(frames);
        json.WriteStartObject(name);
        json.WriteNumber("frames", s.Frames);
        json.WriteNumber("p50Ms", Math.Round(s.P50, 2));
        json.WriteNumber("p95Ms", Math.Round(s.P95, 2));
        json.WriteNumber("p99Ms", Math.Round(s.P99, 2));
        json.WriteNumber("maxMs", Math.Round(s.Max, 2));
        json.WriteNumber("over33Ms", s.Over33);
        json.WriteNumber("over100Ms", s.Over100);
        json.WriteBoolean("passesH4a", s.PassesH4a);
        json.WriteEndObject();
    }

    private static void WriteMemory(Utf8JsonWriter json, string name)
    {
        using var p = Process.GetCurrentProcess();
        p.Refresh();
        json.WriteStartObject(name);
        json.WriteNumber("workingSetMiB", Math.Round(p.WorkingSet64 / 1048576.0, 1));
        json.WriteNumber("privateMiB", Math.Round(p.PrivateMemorySize64 / 1048576.0, 1));
        json.WriteNumber("managedHeapMiB", Math.Round(GC.GetTotalMemory(false) / 1048576.0, 1));
        json.WriteEndObject();
    }

    private static bool IsPackaged()
    {
        try
        {
            return Windows.ApplicationModel.Package.Current is not null;
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            return false;
        }
    }
}
