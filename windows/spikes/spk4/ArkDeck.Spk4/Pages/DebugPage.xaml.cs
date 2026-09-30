using ArkDeck.Spk4.Controls;
using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.Spk4.Pages;

public sealed partial class DebugPage : Page
{
    public DebugPage()
    {
        InitializeComponent();
        foreach (var tab in UnavailableCatalog.DebugTabs)
        {
            var item = new SelectorBarItem { Text = tab.Title, Tag = tab };
            AutomationProperties.SetAutomationId(item, "Debug.Tab." + tab.Title);
            Tabs.Items.Add(item);
        }
        Tabs.SelectedItem = Tabs.Items[0];
    }

    private void Tabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (sender.SelectedItem?.Tag is UnavailableCapability tab)
        {
            TabContent.Content = UnavailablePanel.Create(tab, AutomationIds.DebugUnavailable);
        }
    }
}
