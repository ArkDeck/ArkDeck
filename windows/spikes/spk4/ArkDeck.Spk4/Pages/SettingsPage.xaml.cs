using System.Globalization;
using Microsoft.UI.Xaml.Controls;
using Windows.UI.ViewManagement;

namespace ArkDeck.Spk4.Pages;

/// <summary>Read-only view of the system appearance inputs the spike honours.</summary>
public sealed partial class SettingsPage : Page
{
    public SettingsPage()
    {
        InitializeComponent();
        var ui = new UISettings();
        var accent = ui.GetColorValue(UIColorType.Accent);
        var hc = new AccessibilitySettings().HighContrast;
        Environment.Text = string.Create(CultureInfo.InvariantCulture,
            $"Theme: {ActualTheme}\nHigh contrast: {(hc ? "on" : "off")}\nText scale: {ui.TextScaleFactor:0.00}\nAccent: #{accent.R:X2}{accent.G:X2}{accent.B:X2}");
    }
}
