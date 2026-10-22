using System.Globalization;
using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace ArkDeck.Spk4.Pages;

public sealed partial class HistoryPage : Page, IMeasuredPage
{
    private readonly LoadClock _clock = new();

    public HistoryPage()
    {
        InitializeComponent();
    }

    public Task<LoadTiming> Ready => _clock.Ready;

    public ScrollViewer? FindScroller() => LoadClock.FindDescendant<ScrollViewer>(List);

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var rows = HistoryFixture.Generate();
        _clock.Generated(rows.Count);
        List.ItemsSource = rows;
        _clock.CompleteWhen(() => List.ItemsPanelRoot is { } p && p.Children.Count > 0);
        _ = ShowStatsAsync();
    }

    private async Task ShowStatsAsync()
    {
        var t = await _clock.Ready;
        Stats.Text = string.Create(CultureInfo.InvariantCulture,
            $"{t.Items:N0} fixture rows · generated in {t.GenerateMs:0} ms · rows on screen {t.BindToFirstFrameMs:0} ms after bind");
    }

    private void List_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is HistoryRow row)
        {
            // Name the ListViewItem itself so UIA reads the row, not the record's ToString().
            AutomationProperties.SetName(args.ItemContainer, row.AutomationName);
        }
    }
}
