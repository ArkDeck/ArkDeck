using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace ArkDeck.App.Controls;

/// <summary>
/// Test runs only (<c>--focus-walk &lt;file&gt;</c> with <c>--test-transport</c>): on the window
/// message <c>ArkDeck.FocusWalk</c>, walks keyboard focus through the window with WinUI's own Tab
/// navigation (<see cref="FocusManager.TryMoveFocus(FocusNavigationDirection, FindNextElementOptions)"/>,
/// what the Tab key runs), starting at the first focusable element, and writes each stop —
/// its AutomationId, type, keyboard focus state and bounds — to the file. The keyboard tests
/// use it on a host whose desktop is locked, where key strokes cannot be sent; with an
/// unlocked desktop they send real Tab keys as well.
/// </summary>
internal static class FocusWalk
{
    private const uint Backward = 1;
    private static readonly uint Message = RegisterWindowMessage("ArkDeck.FocusWalk");
    private static SubclassProc? _proc;

    public static void Install(Window window, string file)
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        _proc = (hwnd, message, wParam, lParam, id, data) =>
        {
            if (message == Message)
            {
                var direction = (uint)wParam == Backward ? FocusNavigationDirection.Previous : FocusNavigationDirection.Next;
                window.DispatcherQueue.TryEnqueue(() => Walk(window, direction, file));
                return IntPtr.Zero;
            }
            return DefSubclassProc(hwnd, message, wParam, lParam);
        };
        SetWindowSubclass(handle, _proc, (UIntPtr)0x51, IntPtr.Zero);
    }

    private static void Walk(Window window, FocusNavigationDirection direction, string file)
    {
        var root = window.Content;
        var options = new FindNextElementOptions { SearchRoot = root.XamlRoot.Content };
        var stops = new JsonArray();
        var first = direction == FocusNavigationDirection.Next
            ? FocusManager.FindFirstFocusableElement(root.XamlRoot.Content)
            : FocusManager.FindLastFocusableElement(root.XamlRoot.Content);
        if (first is Control control) control.Focus(FocusState.Keyboard);
        var seen = new HashSet<DependencyObject>();
        for (var i = 0; i < 400; i++)
        {
            if (FocusManager.GetFocusedElement(root.XamlRoot) is not DependencyObject focused) break;
            if (!seen.Add(focused)) break;
            stops.Add((JsonNode)Describe(focused, root));
            if (!FocusManager.TryMoveFocus(direction, options)) break;
        }
        // JsonNode, not reflection-based serialization: the published App is trimmed (IL2026).
        File.WriteAllText(file, stops.ToJsonString());
    }

    private static JsonObject Describe(DependencyObject element, UIElement root)
    {
        var id = AutomationProperties.GetAutomationId(element);
        double x = 0, y = 0, width = 0, height = 0;
        var state = "";
        if (element is FrameworkElement fe)
        {
            var origin = fe.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0, 0));
            (x, y, width, height) = (origin.X, origin.Y, fe.ActualWidth, fe.ActualHeight);
            // Reading order uses document coordinates. Focusing a control can scroll its
            // viewport while the page title stays pinned, which must not reorder the stops.
            for (var ancestor = VisualTreeHelper.GetParent(fe); ancestor is not null; ancestor = VisualTreeHelper.GetParent(ancestor))
            {
                if (ancestor is not ScrollViewer scroll) continue;
                x += scroll.HorizontalOffset;
                y += scroll.VerticalOffset;
            }
        }
        if (element is Control c) state = c.FocusState.ToString();
        return new JsonObject
        {
            ["id"] = id,
            ["type"] = element.GetType().Name,
            ["state"] = state,
            ["x"] = x,
            ["y"] = y,
            ["width"] = width,
            ["height"] = height,
        };
    }

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, IntPtr data);

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, IntPtr data);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);
}
