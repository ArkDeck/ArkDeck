using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.Spk4.Pages;

public sealed partial class OverviewPage : Page
{
    public OverviewPage()
    {
        InitializeComponent();
        Latest.ItemsSource = HistoryFixture.Generate(6);
    }
}
