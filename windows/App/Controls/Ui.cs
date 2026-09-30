using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Controls;

/// <summary>
/// Builders for the elements the pages render. Every element that carries meaning gets a
/// stable AutomationId (the macOS AX identifier where the macOS App has one) and a UIA name;
/// no control is ever disabled (XPA-AC-8): an action that cannot run is not shown, and a
/// capability without data shows <c>unavailable(reasonCode)</c> and its CLI command.
/// </summary>
internal static class Ui
{
    private static Localizer S => App.Strings;

    public static TextBlock Text(string automationId, string text, string style = "ArkDeckBodyStyle")
    {
        var block = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources[style],
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(block, automationId);
        AutomationProperties.SetName(block, text);
        return block;
    }

    public static TextBlock Heading(string automationId, string text, AutomationHeadingLevel level = AutomationHeadingLevel.Level2)
    {
        var block = Text(automationId, text, level == AutomationHeadingLevel.Level1 ? "ArkDeckPageTitleStyle" : "ArkDeckSectionTitleStyle");
        block.IsTextSelectionEnabled = false;
        AutomationProperties.SetHeadingLevel(block, level);
        return block;
    }

    public static Button Button(string automationId, string text, RoutedEventHandler click, bool accent = false)
    {
        var button = new Button { Content = text };
        if (accent) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        AutomationProperties.SetAutomationId(button, automationId);
        AutomationProperties.SetName(button, text);
        button.Click += click;
        return button;
    }

    /// <summary>A button that copies a CLI command (a working action, not a stand-in).</summary>
    public static Button CopyCli(string automationId, string command) =>
        Button(automationId, S.Text(UiStrings.WindowsActionCopyCli), (_, _) =>
        {
            var data = new Windows.ApplicationModel.DataTransfer.DataPackage();
            data.SetText(command);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
        });

    public static Border Card(UIElement content, string? automationId = null)
    {
        var card = new Border { Style = (Style)Application.Current.Resources["ArkDeckCardStyle"], Child = content };
        if (automationId is not null) AutomationProperties.SetAutomationId(card, automationId);
        return card;
    }

    public static StackPanel Stack(double spacing = 8, params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = spacing };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static StackPanel Row(params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    /// <summary>
    /// The macOS unavailable notice of a surface: its title (<paramref name="titleKey"/>), the
    /// reason as <c>unavailable(reasonCode): detail</c>, optional guidance, the equivalent CLI
    /// command and a working "Copy CLI command". Ids: <c>{id}</c> (the title),
    /// <c>{id}.reason</c>, <c>{id}.guidance</c>, <c>{id}.cli</c>, <c>{id}.copyCli</c>, where the
    /// title id is <paramref name="titleId"/> when the macOS App names the title separately.
    /// </summary>
    public static StackPanel UnavailableNotice(string id, string titleKey, Unavailable why, string? guidanceKey = null, string? titleId = null)
    {
        var panel = Stack(4,
            Text(titleId ?? id, S.Text(titleKey), "ArkDeckSectionTitleStyle"),
            Text(id + ".reason", why.ReasonText(S), "ArkDeckCaptionStyle"));
        if (guidanceKey is not null) panel.Children.Add(Text(id + ".guidance", S.Text(guidanceKey)));
        panel.Children.Add(Row(Text(id + ".cli", why.CliText(S), "ArkDeckMonoStyle"), CopyCli(id + ".copyCli", why.CliCommand)));
        return panel;
    }

    /// <summary>Marks an element as a UIA live region.</summary>
    public static T Live<T>(T element, AutomationLiveSetting setting) where T : FrameworkElement
    {
        AutomationProperties.SetLiveSetting(element, setting);
        return element;
    }

    /// <summary>Raises LiveRegionChanged so Narrator reads the element's new name.</summary>
    public static void Announce(FrameworkElement element)
    {
        var peer = FrameworkElementAutomationPeer.FromElement(element) ?? FrameworkElementAutomationPeer.CreatePeerForElement(element);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    public static ProgressRing Progress(string automationId, string name)
    {
        var ring = new ProgressRing { IsActive = true, Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(ring, automationId);
        AutomationProperties.SetName(ring, name);
        return ring;
    }

    public static ListView List(string automationId, string name)
    {
        var list = new ListView { SelectionMode = ListViewSelectionMode.None };
        AutomationProperties.SetAutomationId(list, automationId);
        AutomationProperties.SetName(list, name);
        return list;
    }

    public static ListViewItem Item(string automationId, string name, UIElement content)
    {
        var item = new ListViewItem { Content = content };
        AutomationProperties.SetAutomationId(item, automationId);
        AutomationProperties.SetName(item, name);
        return item;
    }

    /// <summary>A job state label for a surface: the surface's own catalogue key when there is
    /// one, else the raw state (as the macOS App shows an unnamed state).</summary>
    public static string JobState(string prefix, string state)
    {
        var key = prefix + state;
        return UiStrings.All.Contains(key) ? S.Text(key) : state;
    }
}
