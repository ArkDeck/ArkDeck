using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Pages;
using ArkDeck.ClientKit;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App;

/// <summary>
/// The shell: title bar, navigation (Overview, Device, History, as the macOS sidebar groups
/// them), the daemon-unavailable recovery banner and the global Job Inspector. Pages report
/// each refresh here; the banner follows the latest report.
/// </summary>
public sealed partial class MainWindow : Window
{
    private static Localizer S => App.Strings;

    private string? _bannerReason;

    public MainWindow()
    {
        InitializeComponent();
        Instance = this;

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon("Assets/AppIcon.ico");
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 900));

        Title = S.Text(UiStrings.AppShellTitle);
        AppTitleBar.Title = Title;
        AutomationProperties.SetName(NavView, Title);
        SectionDevice.Content = S.Text(UiStrings.AppNavigationSectionDevice);
        SectionRecords.Content = S.Text(UiStrings.AppNavigationSectionRecords);
        foreach (var (item, key) in new[]
                 {
                     (NavOverview, UiStrings.AppNavigationOverview),
                     (NavDevice, UiStrings.AppNavigationDevice),
                     (NavHistory, UiStrings.AppNavigationHistory),
                     (NavSessions, UiStrings.WindowsNavigationSessions),
                     (NavAgents, UiStrings.WindowsNavigationAgents),
                     (NavImports, UiStrings.WindowsNavigationImports),
                     (NavDebug, UiStrings.WindowsNavigationDebug),
                     (NavSettings, UiStrings.WindowsNavigationSettings),
                 })
        {
            item.Content = S.Text(key);
            AutomationProperties.SetName(item, S.Text(key));
        }

        if (App.Options.TestTransport is { } scenario)
        {
            TestTransportBar.Title = S.Text(UiStrings.WindowsTestTransportTitle);
            TestTransportBar.Message = S.Format(UiStrings.WindowsTestTransportMessage, scenario);
            AutomationProperties.SetName(TestTransportBar, TestTransportBar.Title);
            TestTransportBar.IsOpen = true;
        }

        var retry = Ui.Button("app.recovery.retry", S.Text(UiStrings.WindowsActionRetry), async (_, _) => await RefreshAllAsync(), accent: true);
        RecoveryBar.ActionButton = retry;

        if (App.Options.FocusWalkFile is { } walk) FocusWalk.Install(this, walk);

        Inspector = new JobInspector();
        InspectorHost.Child = Inspector;
        Root.Loaded += (_, _) => Select(App.Options.StartPage ?? "overview");
    }

    public static MainWindow Instance { get; private set; } = null!;

    public JobInspector Inspector { get; }

    /// <summary>A page's or the inspector's refresh result: the recovery banner shows the
    /// first daemon-unavailable failure and goes away once the daemon answered again.</summary>
    public void Report(SurfaceState state)
    {
        if (state.DaemonFailure is { } failure) ShowBanner(failure);
        else if (state.Reached) HideBanner();
    }

    /// <summary>Re-reads the page and the inspector (the banner's Retry).</summary>
    public async Task RefreshAllAsync()
    {
        if (PageHost.Content is IRefreshable page) await page.RefreshAsync();
        await Inspector.RefreshAsync();
    }

    /// <summary>History, with one Job's record open.</summary>
    public async Task OpenJobAsync(string jobId)
    {
        Select("history");
        if (_pages.TryGetValue("history", out var page) && page is HistoryPage history) await history.OpenAsync(jobId);
    }

    public void Select(string tag)
    {
        foreach (var item in NavView.MenuItems.Concat(NavView.FooterMenuItems).OfType<NavigationViewItem>())
        {
            if ((string)item.Tag == tag)
            {
                NavView.SelectedItem = item;
                return;
            }
        }
        NavView.SelectedItem = NavOverview;
    }

    private void ShowBanner(ControlFailure failure)
    {
        var banner = RecoveryBannerState.For(failure, S);
        var content = Ui.Stack(4,
            Ui.Text("app.recovery.remedy", banner.Remedy),
            Ui.Text("app.recovery.reason", banner.Reason, "ArkDeckCaptionStyle"),
            Ui.Row(Ui.Text("app.recovery.cli", banner.CliText, "ArkDeckMonoStyle"), Ui.CopyCli("app.recovery.copyCli", banner.CliCommand)));
        RecoveryBar.Title = banner.Title;
        RecoveryBar.Message = banner.Message;
        RecoveryBar.Content = content;
        AutomationProperties.SetName(RecoveryBar, banner.Title);
        AutomationProperties.SetFullDescription(RecoveryBar, banner.Message);
        var changed = !RecoveryBar.IsOpen || _bannerReason != banner.Reason;
        RecoveryBar.IsOpen = true;
        _bannerReason = banner.Reason;
        if (changed) Ui.Announce(RecoveryBar);
    }

    private void HideBanner()
    {
        if (!RecoveryBar.IsOpen) return;
        // Closing is not announced from the banner (a collapsed element has no UIA peer to
        // speak for it); the pages' own live regions announce the data coming back.
        RecoveryBar.IsOpen = false;
        _bannerReason = null;
    }

    private void TitleBar_PaneToggleRequested(TitleBar sender, object args) => NavView.IsPaneOpen = !NavView.IsPaneOpen;

    private readonly Dictionary<string, UserControl> _pages = [];

    /// <summary>Shows the page of the selected item and re-reads it. Pages are code-only
    /// controls hosted directly (Frame navigation needs XAML type metadata they do not have).</summary>
    private async void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) return;
        var tag = (string)item.Tag;
        if (!_pages.TryGetValue(tag, out var page))
        {
            page = tag switch
            {
                "device" => new DevicePage(),
                "history" => new HistoryPage(),
                "settings" => new SettingsPage(),
                "sessions" => new SessionsPage(),
                "agents" => new AgentsPage(),
                "imports" => new ImportsPage(),
                "debug" => new DebugPage(),
                _ => new OverviewPage(),
            };
            _pages[tag] = page;
        }
        PageHost.Content = page;
        await ((IRefreshable)page).RefreshAsync();
    }
}

/// <summary>A surface that re-reads the daemon.</summary>
public interface IRefreshable
{
    Task RefreshAsync();
}
