using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace ArkDeck.App.Controls;

/// <summary>
/// Scripted-transport tests only: render the actual XAML tree when a locked desktop cannot
/// provide screen pixels. Uses Mica's opaque theme fallback; native caption buttons and the
/// compositor's Mica effect are outside the XAML tree.
/// </summary>
internal static class RenderSnapshot
{
    private static readonly uint Message = RegisterWindowMessage("ArkDeck.RenderSnapshot");
    private static SubclassProc? _proc;

    public static void Install(Window window, string file)
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        _proc = (hwnd, message, wParam, lParam, id, data) =>
        {
            if (message != Message) return DefSubclassProc(hwnd, message, wParam, lParam);
            window.DispatcherQueue.TryEnqueue(async () =>
            {
                try { await SaveAsync((Grid)window.Content, file); }
                catch (Exception error) when (error is COMException or IOException or UnauthorizedAccessException)
                {
                    File.WriteAllText(file + ".error", error.GetType().Name + ": " + error.Message);
                }
            });
            return nint.Zero;
        };
        SetWindowSubclass(handle, _proc, (nuint)0x52, nint.Zero);
    }

    private static async Task SaveAsync(Grid root, string file)
    {
        var style = root.Style;
        var bitmap = new RenderTargetBitmap();
        try
        {
            root.Style = (Style)Application.Current.Resources["ArkDeckSnapshotStyle"];
            root.UpdateLayout();
            await bitmap.RenderAsync(root);
        }
        finally { root.Style = style; }
        var buffer = await bitmap.GetPixelsAsync();
        var bytes = new byte[buffer.Length];
        using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(bytes);
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes);
        await encoder.FlushAsync();
        stream.Seek(0);
        var encoded = new byte[checked((int)stream.Size)];
        using (var reader = new DataReader(stream))
        {
            await reader.LoadAsync((uint)encoded.Length);
            reader.ReadBytes(encoded);
        }
        await File.WriteAllBytesAsync(file + ".writing", encoded);
        File.Move(file + ".writing", file, overwrite: true);
    }

    private delegate nint SubclassProc(nint hwnd, uint message, nint wParam, nint lParam, nuint id, nint data);

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(nint hwnd, SubclassProc proc, nuint id, nint data);

    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint hwnd, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);
}
