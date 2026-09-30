using ArkDeck.Spk4.Controls;
using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.Spk4.Pages;

public sealed partial class TracePage : Page
{
    public TracePage()
    {
        InitializeComponent();
        Body.Children.Add(UnavailablePanel.Create(UnavailableCatalog.TraceViewer, AutomationIds.TraceUnavailable));
    }
}
