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
                     (NavFlash, UiStrings.WindowsNavigationFlash),
                     (NavTrace, UiStrings.AppNavigationTrace),
                     (NavTraceViewer, UiStrings.WindowsTraceViewerTitle),
                     (NavViewer, UiStrings.AppNavigationUiDump),
                     (NavDiagnostics, UiStrings.AppNavigationDiagnostics),
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

    /// <summary>The Trace viewer, showing a captured Trace (or what it had open).</summary>
    public async void OpenTraceViewer(TraceDocument? document)
    {
        if (!_pages.TryGetValue("traceViewer", out var page)) _pages["traceViewer"] = page = new TraceViewerPage();
        if (ReferenceEquals(NavView.SelectedItem, NavTraceViewer))
        {
            await ((TraceViewerPage)page).ShowAsync(document);
            return;
        }
        _pendingTrace = document;
        Select("traceViewer");
    }

    private TraceDocument? _pendingTrace;

    /// <summary>Reopens a History record in its workspace (macOS <c>openHistoryWorkspace</c>), or
    /// in Diagnostics (<c>openHistoryDiagnostics</c>): the page takes the record's read-only
    /// context, then shows it.</summary>
    public async void OpenHistoryWorkspace(HistoryWorkspaceContext context, bool inDiagnostics = false)
    {
        var tag = inDiagnostics ? "diagnostics" : context.Kind switch
        {
            WorkspaceKind.Flash => "flash",
            WorkspaceKind.Viewer => "viewer",
            WorkspaceKind.Trace => "trace",
            WorkspaceKind.Debug => "debug",
            WorkspaceKind.Device => "device",
            _ => "diagnostics",
        };
        if (!_pages.TryGetValue(tag, out var page)) _pages[tag] = page = CreatePage(tag);
        ((IHistoryContextPage)page).OpenHistoryContext(context);
        if (ReferenceEquals(PageHost.Content, page))
        {
            await ((IRefreshable)page).RefreshAsync();
            return;
        }
        Select(tag);
    }

    /// <summary>Settings, on one of its tabs (the remote browser's Open Server Settings).</summary>
    public void OpenSettings(string tab)
    {
        if (!_pages.TryGetValue("settings", out var page)) _pages["settings"] = page = new SettingsPage();
        ((SettingsPage)page).ShowTab(tab);
        if (ReferenceEquals(NavView.SelectedItem, NavSettings)) _ = ((SettingsPage)page).RefreshAsync();
        else Select("settings");
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

    private string _recoveryShown = "";

    /// <summary>The macOS global Job recovery banner (<c>GlobalRecoveryBannerView</c>), from the
    /// Jobs the Job Inspector read: one card per record that needs a person now (its kind in words,
    /// its guidance, Job and Target, and Open in History), the count when there are several; gone
    /// when none does. A change is announced.</summary>
    public void ShowJobRecovery(IReadOnlyList<JobSummary>? jobs)
    {
        var recovery = JobRecovery.Ordered(jobs ?? []);
        var key = string.Join(",", recovery.Select(j => j.JobId + ":" + JobRecovery.TitleKey(j)));
        if (key == _recoveryShown) return;
        _recoveryShown = key;
        if (recovery.Count == 0)
        {
            JobRecoveryHost.Content = null;
            JobRecoveryHost.Visibility = Visibility.Collapsed;
            return;
        }
        var list = Ui.Stack(6);
        list.Padding = new Thickness(16, 8, 16, 8);
        AutomationProperties.SetName(JobRecoveryHost, S.Text(UiStrings.JobRecoveryList));
        if (recovery.Count > 1) list.Children.Add(Ui.Text("jobRecovery.count", S.Format(UiStrings.JobRecoveryCount, recovery.Count), "ArkDeckCaptionStyle"));
        TextBlock? first = null;
        foreach (var job in recovery)
        {
            var title = Ui.Text("jobRecovery.title." + job.JobId, S.Text(JobRecovery.TitleKey(job)), "ArkDeckSectionTitleStyle");
            first ??= title;
            var id = Ui.Text("jobRecovery.job." + job.JobId, $"{job.JobId} · {job.TargetId}", "ArkDeckMonoStyle");
            id.IsTextSelectionEnabled = true;
            var open = Ui.Button("jobRecovery.openHistory." + job.JobId, S.Text(UiStrings.JobRecoveryActionOpenHistory), async (_, _) => await OpenJobAsync(job.JobId));
            AutomationProperties.SetName(open, $"{S.Text(UiStrings.JobRecoveryActionOpenHistory)}: {job.JobId}");
            list.Children.Add(Ui.Card(Ui.Stack(4, title,
                Ui.Text("jobRecovery.guidance." + job.JobId, S.Text(JobRecovery.GuidanceKey(job))),
                id, Ui.Row(open)), "jobRecovery.banner"));
        }
        JobRecoveryHost.Content = list;
        JobRecoveryHost.Visibility = Visibility.Visible;
        AutomationProperties.SetLiveSetting(first!, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        first!.DispatcherQueue.TryEnqueue(() => Ui.Announce(first));
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

    private static UserControl CreatePage(string tag) => tag switch
    {
        "device" => new DevicePage(),
        "history" => new HistoryPage(),
        "settings" => new SettingsPage(),
        "sessions" => new SessionsPage(),
        "agents" => new AgentsPage(),
        "imports" => new ImportsPage(),
        "debug" => new DebugPage(),
        "flash" => new FlashPage(),
        "trace" => new TracePage(),
        "traceViewer" => new TraceViewerPage(),
        "viewer" => new ViewerPage(),
        "diagnostics" => new DiagnosticsPage(),
        _ => new OverviewPage(),
    };

    /// <summary>Shows the page of the selected item and re-reads it. Pages are code-only
    /// controls hosted directly (Frame navigation needs XAML type metadata they do not have).</summary>
    private async void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) return;
        var tag = (string)item.Tag;
        if (!_pages.TryGetValue(tag, out var page))
        {
            page = CreatePage(tag);
            _pages[tag] = page;
        }
        PageHost.Content = page;
        if (page is TraceViewerPage viewer && _pendingTrace is { } pending)
        {
            _pendingTrace = null;
            await viewer.ShowAsync(pending);
            return;
        }
        await ((IRefreshable)page).RefreshAsync();
    }
}

/// <summary>A surface that re-reads the daemon.</summary>
public interface IRefreshable
{
    Task RefreshAsync();
}
