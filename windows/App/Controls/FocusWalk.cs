using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

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
        var stops = new List<Stop>();
        var first = direction == FocusNavigationDirection.Next
            ? FocusManager.FindFirstFocusableElement(root.XamlRoot.Content)
            : FocusManager.FindLastFocusableElement(root.XamlRoot.Content);
        if (first is Control control) control.Focus(FocusState.Keyboard);
        var seen = new HashSet<DependencyObject>();
        for (var i = 0; i < 400; i++)
        {
            if (FocusManager.GetFocusedElement(root.XamlRoot) is not DependencyObject focused) break;
            if (!seen.Add(focused)) break;
            stops.Add(Describe(focused, root));
            if (!FocusManager.TryMoveFocus(direction, options)) break;
        }
        // Written by hand: the published App is trimmed, and reflection-based serialization is not.
        using var stream = File.Create(file);
        using var json = new Utf8JsonWriter(stream);
        json.WriteStartArray();
        foreach (var stop in stops)
        {
            json.WriteStartObject();
            json.WriteString("id", stop.Id);
            json.WriteString("type", stop.Type);
            json.WriteString("state", stop.State);
            json.WriteNumber("x", stop.X);
            json.WriteNumber("y", stop.Y);
            json.WriteNumber("width", stop.Width);
            json.WriteNumber("height", stop.Height);
            json.WriteEndObject();
        }
        json.WriteEndArray();
    }

    private static Stop Describe(DependencyObject element, UIElement root)
    {
        var id = AutomationProperties.GetAutomationId(element);
        double x = 0, y = 0, width = 0, height = 0;
        var state = "";
        if (element is FrameworkElement fe)
        {
            var origin = fe.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0, 0));
            (x, y, width, height) = (origin.X, origin.Y, fe.ActualWidth, fe.ActualHeight);
        }
        if (element is Control c) state = c.FocusState.ToString();
        return new Stop(id, element.GetType().Name, state, x, y, width, height);
    }

    private readonly record struct Stop(string Id, string Type, string State, double X, double Y, double Width, double Height);

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, IntPtr data);

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, IntPtr data);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);
}
