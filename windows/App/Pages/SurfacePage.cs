using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// A page that shows one daemon read: a title, its refresh action, a progress ring while
/// reading, then what came back. The body is rebuilt from each <see cref="SurfaceState"/>;
/// the shell gets every state for the recovery banner.
/// </summary>
public abstract partial class SurfacePage<TState> : UserControl, IRefreshable where TState : SurfaceState
{
    protected static Localizer S => App.Strings;

    private readonly StackPanel _body = new() { Spacing = 14 };
    // Hosts only; a host is never a Tab stop of its own (the keyboard test found empty stops).
    private readonly ContentControl _progress = new() { IsTabStop = false };
    private bool _refreshing;

    protected SurfacePage(string rootId, string titleId, string titleKey, string refreshId, string refreshKey, string progressId, string progressKey)
    {
        ProgressId = progressId;
        ProgressKey = progressKey;
        AutomationProperties.SetAutomationId(this, rootId);
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Ui.Heading(titleId, S.Text(titleKey), AutomationHeadingLevel.Level1));
        var refresh = Ui.Button(refreshId, S.Text(refreshKey), async (_, _) => await RefreshAsync());
        Grid.SetColumn(refresh, 1);
        header.Children.Add(refresh);
        var page = new StackPanel { Spacing = 14, Padding = new Thickness(24, 16, 24, 24), MaxWidth = 960, HorizontalAlignment = HorizontalAlignment.Left };
        page.Children.Add(header);
        page.Children.Add(_progress);
        page.Children.Add(_body);
        var scroll = new ScrollViewer { Content = page };
        // The page viewport, by which the layout tests measure what is visible.
        AutomationProperties.SetAutomationId(scroll, rootId + ".page");
        Content = scroll;
    }

    private string ProgressId { get; }

    private string ProgressKey { get; }

    public async Task RefreshAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            _progress.Content = Ui.Progress(ProgressId, S.Text(ProgressKey));
            // ClientKit connects and authenticates synchronously; keep that off the UI thread.
            var state = await Task.Run(LoadAsync);
            _progress.Content = null;
            _body.Children.Clear();
            Render(state, _body);
            MainWindow.Instance.Report(state);
        }
        finally
        {
            _refreshing = false;
        }
    }

    protected abstract Task<TState> LoadAsync();

    protected abstract void Render(TState state, StackPanel body);
}
