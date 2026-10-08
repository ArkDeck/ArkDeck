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

    private readonly StackPanel _body = new() { Spacing = 24 };
    // Hosts only; a host is never a Tab stop of its own (the keyboard test found empty stops).
    private readonly ContentControl _progress = new() { IsTabStop = false };
    private bool _refreshing;

    protected SurfacePage(string rootId, string titleId, string titleKey, string refreshId, string refreshKey, string progressId, string progressKey)
    {
        ProgressId = progressId;
        ProgressKey = progressKey;
        AutomationProperties.SetAutomationId(this, rootId);
        var header = new Grid { ColumnSpacing = 16, Margin = new Thickness(24, 24, 24, 20), MaxWidth = PageMaxWidth };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Ui.Heading(titleId, S.Text(titleKey), AutomationHeadingLevel.Level1));
        var refresh = Ui.Button(refreshId, S.Text(refreshKey), async (_, _) => await RefreshAsync());
        Grid.SetColumn(refresh, 1);
        header.Children.Add(refresh);
        refresh.VerticalAlignment = VerticalAlignment.Center;
        _body.MaxWidth = PageMaxWidth;
        var scroll = new ScrollViewer
        {
            Content = _body,
            Padding = new Thickness(24, 0, 24, 48),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        // The page viewport, by which the layout tests measure what is visible.
        AutomationProperties.SetAutomationId(scroll, rootId + ".page");
        var page = new Grid();
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.Children.Add(header);
        Grid.SetRow(_progress, 1);
        _progress.Margin = new Thickness(24, 0, 24, 8);
        page.Children.Add(_progress);
        Grid.SetRow(scroll, 2);
        page.Children.Add(scroll);
        Content = page;
    }

    /// <summary>Forms follow PowerToys' 1000 epx limit; readers opt into the workspace width.</summary>
    protected virtual double PageMaxWidth => 1000;

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
            _last = state;
            _body.Children.Clear();
            Render(state, _body);
            MainWindow.Instance.Report(state);
        }
        finally
        {
            _refreshing = false;
        }
    }

    private TState? _last;

    /// <summary>Renders the last state again (a page-local choice changed; nothing is re-read).</summary>
    protected void Rerender()
    {
        if (_last is not { } state) return;
        _body.Children.Clear();
        Render(state, _body);
    }

    protected abstract Task<TState> LoadAsync();

    protected abstract void Render(TState state, StackPanel body);
}
