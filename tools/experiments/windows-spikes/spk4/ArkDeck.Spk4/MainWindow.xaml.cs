using ArkDeck.Spk4.Bench;
using ArkDeck.Spk4.Pages;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ArkDeck.Spk4;

public sealed partial class MainWindow : Window
{
    private readonly LaunchOptions _options;

    /// <summary>Milliseconds from process start to the first rendered frame.</summary>
    public static double FirstFrameMs { get; private set; } = -1;

    public MainWindow(LaunchOptions options)
    {
        _options = options;
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon("Assets/AppIcon.ico");
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 860));

        CompositionTarget.Rendering += OnFirstRendering;
        Root.Loaded += OnRootLoaded;
    }

    public Frame ContentFrame => NavFrame;

    private void OnFirstRendering(object? sender, object e)
    {
        CompositionTarget.Rendering -= OnFirstRendering;
        FirstFrameMs = App.MsSinceProcessStart;
    }

    private async void OnRootLoaded(object sender, RoutedEventArgs e)
    {
        Select(_options.StartPage ?? "overview");
        if (_options.BenchDir is { } dir)
        {
            await new BenchRunner(this, dir).RunAsync();
            Close();
        }
    }

    /// <summary>Selects a navigation item by tag (drives the SelectionChanged path).</summary>
    public void Select(string tag)
    {
        foreach (var item in NavView.MenuItems.OfType<NavigationViewItem>())
        {
            if ((string)item.Tag == tag)
            {
                NavView.SelectedItem = item;
                return;
            }
        }
        throw new ArgumentException($"unknown page tag {tag}", nameof(tag));
    }

    private void TitleBar_PaneToggleRequested(TitleBar sender, object args) =>
        NavView.IsPaneOpen = !NavView.IsPaneOpen;

    private void TitleBar_BackRequested(TitleBar sender, object args)
    {
        if (NavFrame.CanGoBack) NavFrame.GoBack();
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            NavFrame.Navigate(typeof(SettingsPage));
            return;
        }
        if (args.SelectedItem is not NavigationViewItem item) return;
        var page = (string)item.Tag switch
        {
            "overview" => typeof(OverviewPage),
            "history" => typeof(HistoryPage),
            "viewer" => typeof(ViewerPage),
            "job" => typeof(JobInspectorPage),
            "debug" => typeof(DebugPage),
            "trace" => typeof(TracePage),
            var t => throw new InvalidOperationException($"Unknown navigation item tag: {t}"),
        };
        NavFrame.Navigate(page);
    }
}
