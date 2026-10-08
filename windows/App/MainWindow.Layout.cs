using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;

namespace ArkDeck.App;

public sealed partial class MainWindow
{
    /// <summary>XAML uses epx; AppWindow.Resize and DisplayArea.WorkArea use physical pixels.</summary>
    private void SizeForDisplay()
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = Math.Max(96, GetDpiForWindow(handle)) / 96.0;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)Math.Round(1280 * scale), (int)(area.Width * 0.94));
        var height = Math.Min((int)Math.Round(900 * scale), (int)(area.Height * 0.94));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);
}
