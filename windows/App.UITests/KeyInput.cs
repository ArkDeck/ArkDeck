using System.Runtime.InteropServices;
using System.Text;

namespace ArkDeck.App.UITests;

/// <summary>
/// A key stroke posted as <c>WM_KEYDOWN</c>/<c>WM_KEYUP</c> to the App window's input site,
/// which WinUI handles as the key itself. Unlike <c>SendInput</c> it also works while the
/// desktop is locked (the reference host runs its tests locked); Shift is held in the App
/// thread's shared input state for Shift+key.
/// </summary>
internal static class KeyInput
{
    private const int WmKeyDown = 0x0100, WmKeyUp = 0x0101;
    public const int Tab = 0x09, Shift = 0x10, Control = 0x11, Escape = 0x1B, F5 = 0x74;

    public static void Press(IntPtr window, int key, bool shift = false) => Press(window, key, shift, control: false);

    /// <summary>A stroke with Ctrl (and Shift) held in the App thread's shared input state.</summary>
    public static void PressControl(IntPtr window, int key, bool shift = false) => Press(window, key, shift, control: true);

    private static void Press(IntPtr window, int key, bool shift, bool control)
    {
        var site = InputSite(window);
        if (!shift && !control)
        {
            Post(site, WmKeyDown, key);
            Post(site, WmKeyUp, key);
            Thread.Sleep(80);
            return;
        }
        // A posted message carries no modifier state: share the App thread's input state for
        // the stroke and hold Shift down in it.
        var target = GetWindowThreadProcessId(site, out _);
        var self = GetCurrentThreadId();
        if (!AttachThreadInput(self, target, true)) throw new InvalidOperationException("AttachThreadInput failed");
        try
        {
            var state = new byte[256];
            GetKeyboardState(state);
            var held = (byte[])state.Clone();
            if (shift) held[Shift] = 0x80;
            if (control) held[Control] = 0x80;
            SetKeyboardState(held);
            Post(site, WmKeyDown, key);
            Post(site, WmKeyUp, key);
            Thread.Sleep(150);
            SetKeyboardState(state);
        }
        finally
        {
            AttachThreadInput(self, target, false);
        }
        Thread.Sleep(80);
    }

    private static void Post(IntPtr window, int message, int key)
    {
        var scan = MapVirtualKey((uint)key, 0);
        uint lParam = 1u | (scan << 16) | (message == WmKeyUp ? 3u << 30 : 0u);
        if (!PostMessage(window, (uint)message, (IntPtr)key, (IntPtr)unchecked((int)lParam))) throw new InvalidOperationException("PostMessage failed");
    }

    /// <summary>The WinUI input site child window of the App window (where keyboard input goes).</summary>
    private static IntPtr InputSite(IntPtr window)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(window, (child, _) =>
        {
            var name = new StringBuilder(256);
            GetClassName(child, name, name.Capacity);
            if (name.ToString() == "InputSiteWindowClass")
            {
                found = child;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found != IntPtr.Zero ? found : window;
    }

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint to, bool doAttach);

    [DllImport("user32.dll")]
    private static extern bool GetKeyboardState(byte[] state);

    [DllImport("user32.dll")]
    private static extern bool SetKeyboardState(byte[] state);

    private delegate bool EnumProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint code, uint mapType);
}
