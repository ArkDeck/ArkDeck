using System.Globalization;
using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace ArkDeck.Spk4.Pages;

public sealed partial class ViewerPage : Page, IMeasuredPage
{
    private readonly LoadClock _clock = new();

    public ViewerPage()
    {
        InitializeComponent();
    }

    public Task<LoadTiming> Ready => _clock.Ready;

    /// <summary>Split of the last load: fixture model vs. TreeViewNode hierarchy.</summary>
    public static double FixtureMs { get; private set; }

    public static double NodeBuildMs { get; private set; }

    public ScrollViewer? FindScroller() => LoadClock.FindDescendant<ScrollViewer>(Tree);

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var model = ViewerFixture.Generate();
        FixtureMs = sw.Elapsed.TotalMilliseconds;
        var root = Build(model);
        NodeBuildMs = sw.Elapsed.TotalMilliseconds - FixtureMs;
        _clock.Generated(ViewerFixture.Count(model));
        Tree.RootNodes.Add(root);
        _clock.CompleteWhen(() => LoadClock.HasRealisedRows(Tree));
        _ = ShowStatsAsync(ViewerFixture.MaxDepth(model));
    }

    private static TreeViewNode Build(ViewerNode model)
    {
        var node = new TreeViewNode { Content = model };
        foreach (var child in model.Children) node.Children.Add(Build(child));
        node.IsExpanded = true; // expand after the children exist (post-order)
        return node;
    }

    private async Task ShowStatsAsync(int depth)
    {
        var t = await _clock.Ready;
        Stats.Text = string.Create(CultureInfo.InvariantCulture,
            $"{t.Items:N0} fixture nodes, depth {depth}, all expanded · built in {t.GenerateMs:0} ms · rows on screen {t.BindToFirstFrameMs:0} ms after attach");
    }
}
