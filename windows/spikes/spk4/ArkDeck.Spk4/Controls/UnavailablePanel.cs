using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.Spk4.Controls;

/// <summary>InfoBar that states `unavailable(reasonCode)` and offers the working CLI path
/// (a real "copy" action, not a disabled stand-in for the missing feature).</summary>
public static class UnavailablePanel
{
    public static InfoBar Create(UnavailableCapability capability, string automationId)
    {
        var copy = new Button { Content = "Copy CLI command" };
        AutomationProperties.SetAutomationId(copy, automationId + ".CopyCli");
        copy.Click += (_, _) =>
        {
            var data = new Windows.ApplicationModel.DataTransfer.DataPackage();
            data.SetText(capability.CliPath);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
        };
        var bar = new InfoBar
        {
            Title = capability.Heading,
            Message = capability.Body,
            Severity = InfoBarSeverity.Warning,
            IsClosable = false,
            IsOpen = true,
            ActionButton = copy,
            Margin = new Thickness(0, 8, 0, 0),
        };
        AutomationProperties.SetAutomationId(bar, automationId);
        // InfoBar exposes no UIA Name of its own; give the status bar the heading.
        AutomationProperties.SetName(bar, capability.Heading);
        return bar;
    }
}
