using System.Globalization;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace ArkDeck.App.Pages;

/// <summary>
/// History: the Jobs <c>job.list</c> returns (read only), or the macOS "Runtime History
/// Unavailable" state with the daemon's reason (<c>unavailable(rejected): The Job owner is
/// not configured</c> while the Windows daemon composes no Job owner) and <c>arkdeck job
/// list</c>. Choosing a Job shows the macOS History detail: the Job's Runtime facts
/// (<c>job.status</c>) and its Artifacts (<c>artifact.list</c>), each published one with
/// Export… (bounded, digest-verified <c>artifact.read</c> chunks into a file the person picks,
/// the macOS export) and a Job's raw Trace with Inspect Trace (<c>trace.inspect</c>, whose
/// "no inspector" refusal is shown as it came).
/// </summary>
public sealed partial class HistoryPage() : SurfacePage<HistoryState>(
    "history", "history.title", UiStrings.AppNavigationHistory,
    "history.refresh", UiStrings.HistoryActionRefresh, "history.loading", UiStrings.HistoryLoading)
{
    // Rebuilt by each render; an element is never moved between renders, so a kept Artifact
    // result is kept as the function that builds it.
    private StackPanel _detail = new() { Spacing = 8 };
    private readonly Dictionary<string, Func<(FrameworkElement Content, TextBlock? Announce)>> _artifactResults = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ContentControl> _resultHosts = new(StringComparer.Ordinal);
    private string? _selected;

    // The Jobs read so far (the first page and every older page) and the next page's cursor.
    private List<JobSummary> _jobs = [];
    private string? _cursor;
    private string? _olderFailure;
    private bool _loadingOlder;
    private HistoryFilterQuery _filter = HistoryFilterQuery.None;
    private SessionActionState<SavedHistoryFilter>? _saved;
    private bool _savedBusy;
    private StackPanel _tableHost = new() { Spacing = 8 };
    private ContentControl _filtersHost = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private TextBlock _filterStatus = Ui.Status("history.filter.status.line");

    protected override async Task<HistoryState> LoadAsync()
    {
        var state = await App.Loader.HistoryAsync();
        _jobs = state.Jobs.Value?.ToList() ?? [];
        _cursor = state.NextCursor;
        _olderFailure = null;
        if (_saved is null && state.Reached) _saved = await App.Loader.SavedHistoryFilterAsync();
        return state;
    }

    protected override void Render(HistoryState state, StackPanel body)
    {
        if (state.Jobs.Unavailable is { } why)
        {
            body.Children.Add(Ui.Card(Ui.UnavailableNotice("history.unavailable", UiStrings.HistoryUnavailableTitle, why,
                UiStrings.HistoryUnavailableGuidance, titleId: "history.unavailable.title")));
        }
        else if (_jobs.Count == 0)
        {
            body.Children.Add(Ui.Card(Ui.Stack(4,
                Ui.Text("history.empty.title", S.Text(UiStrings.HistoryEmptyTitle), "ArkDeckSectionTitleStyle"),
                Ui.Text("history.empty.description", S.Text(UiStrings.HistoryEmptyDescription)))));
        }
        else
        {
            // New hosts each render: an element is never moved between renders.
            _filtersHost = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            _tableHost = new StackPanel { Spacing = 8 };
            _filtersHost.Content = Filters();
            body.Children.Add(Ui.Card(_filtersHost, "history.filters"));
            body.Children.Add(Ui.Card(_tableHost, "history.list"));
            RenderTable();
            _detail = new StackPanel { Spacing = 8 };
            body.Children.Add(Ui.Card(_detail, "history.detail"));
            if (_selected is { } selected && _jobs.Any(j => j.JobId == selected))
            {
                DispatcherQueue.TryEnqueue(async () => await ShowDetailAsync(selected));
            }
            else
            {
                _selected = null;
                _detail.Children.Add(Ui.Heading("history.detail.title", S.Text(UiStrings.HistoryDetailTitle)));
                _detail.Children.Add(Ui.Text("history.detail.select", S.Text(UiStrings.HistoryDetailSelect), "ArkDeckCaptionStyle"));
            }
        }
        body.Children.Add(Ui.Text("history.readOnlyNote", S.Text(UiStrings.HistoryReadOnlyNote), "ArkDeckCaptionStyle"));
    }

    // ---- filters (macOS filterSidebar, filterPickers, savedFilterMenu) ----

    private static ComboBox Picker<T>(string id, string headerKey, T current, IEnumerable<(T Value, string Label, string Tag)> options, Action<T> chosen)
    {
        var combo = new ComboBox { Header = S.Text(headerKey), MinWidth = 200 };
        AutomationProperties.SetAutomationId(combo, id);
        AutomationProperties.SetName(combo, S.Text(headerKey));
        foreach (var (value, label, tag) in options)
        {
            var item = new ComboBoxItem { Content = label, Tag = value };
            AutomationProperties.SetAutomationId(item, $"{id}.{tag}");
            combo.Items.Add(item);
            if (EqualityComparer<T>.Default.Equals(value, current)) combo.SelectedItem = item;
        }
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is ComboBoxItem { Tag: T value }) chosen(value);
        };
        return combo;
    }

    private static IEnumerable<(T, string, string)> Enum<T>(string prefix) where T : struct, System.Enum =>
        System.Enum.GetValues<T>().Select(v => (v, S.Text(prefix + HistoryFilterQuery.Name(v)), HistoryFilterQuery.Name(v)));

    private StackPanel Filters()
    {
        _filterStatus = Ui.Status("history.filter.status.line");
        var activity = Picker("history.filter.activity", UiStrings.HistoryActivityTitle, _filter.Activity,
            System.Enum.GetValues<HistoryActivity>().Select(a => (a,
                $"{S.Text("history.activity." + HistoryFilterQuery.Name(a))} ({_jobs.Count(j => a == HistoryActivity.All || HistoryFilterQuery.ActivityOf(j) == a)})",
                HistoryFilterQuery.Name(a))),
            a => SetFilter(_filter with { Activity = a }));
        var search = new TextBox { Header = S.Text(UiStrings.HistoryFilterSearch), PlaceholderText = S.Text(UiStrings.HistoryFilterSearch), Text = _filter.Search, MinWidth = 260 };
        AutomationProperties.SetAutomationId(search, "history.filter.search");
        AutomationProperties.SetName(search, S.Text(UiStrings.HistoryFilterSearch));
        search.TextChanging += (_, _) => { if (search.Text != _filter.Search) SetFilter(_filter with { Search = search.Text }, rebuildFilters: false); };
        var sessions = _jobs.Select(j => j.SessionId).OfType<string>().Distinct().Order(StringComparer.Ordinal);
        var targets = _jobs.Select(j => j.TargetId).Distinct().Order(StringComparer.Ordinal);
        var row = Ui.Row(activity, search,
            Picker("history.filter.status", UiStrings.HistoryFilterStatus, _filter.Status, Enum<HistoryStatus>("history.filter.status."), v => SetFilter(_filter with { Status = v })),
            Picker("history.filter.mode", UiStrings.HistoryFilterMode, _filter.Mode, Enum<HistoryMode>("history.filter.mode."), v => SetFilter(_filter with { Mode = v })),
            Picker("history.filter.session", UiStrings.HistoryFilterSession, _filter.SessionId ?? "",
                new[] { ("", S.Text(UiStrings.HistoryFilterSessionAll), "all") }.Concat(sessions.Select(x => (x, x, x))),
                v => SetFilter(_filter with { SessionId = v.Length == 0 ? null : v })),
            Picker("history.filter.device", UiStrings.HistoryFilterDevice, _filter.TargetId ?? "",
                new[] { ("", S.Text(UiStrings.HistoryFilterDeviceAll), "all") }.Concat(targets.Select(x => (x, x, x))),
                v => SetFilter(_filter with { TargetId = v.Length == 0 ? null : v })),
            Picker("history.filter.time", UiStrings.HistoryFilterTime, _filter.Time, Enum<HistoryTime>("history.filter.time."), v => SetFilter(_filter with { Time = v })));
        var quick = Ui.Row(
            Ui.Button("history.filter.reset", S.Text(UiStrings.HistoryFilterReset), (_, _) => SetFilter(HistoryFilterQuery.None)),
            Ui.Button("history.activity.needsAttention", S.Text(UiStrings.HistoryFilterPresetNeedsAttention), (_, _) => SetFilter(HistoryFilterQuery.None with { Status = HistoryStatus.NeedsAttention })),
            Ui.Button("history.filter.preset.recentFailures", S.Text(UiStrings.HistoryFilterPresetRecentFailures),
                (_, _) => SetFilter(HistoryFilterQuery.None with { Status = HistoryStatus.Failed, Time = HistoryTime.LastWeek })));
        if (_selected is { } selected && _jobs.FirstOrDefault(j => j.JobId == selected) is { } job)
        {
            quick.Children.Add(Ui.Button("history.activity.selectedDevice", job.TargetId, (_, _) => SetFilter(HistoryFilterQuery.None with { TargetId = job.TargetId })));
        }
        return Ui.Stack(8, Ui.Heading("history.filter.title", S.Text(UiStrings.HistoryFilterTitle), AutomationHeadingLevel.Level2),
            row, Ui.Text("history.activity.quickFilters", S.Text(UiStrings.HistoryActivityQuickFilters), "ArkDeckCaptionStyle"), quick, Saved(), _filterStatus);
    }

    /// <summary>The Runtime's one saved filter (<c>history.filter.*</c>, generation-guarded).</summary>
    private StackPanel Saved()
    {
        var panel = Ui.Stack(4, Ui.Text("history.filter.saved", S.Text(UiStrings.HistoryFilterSaved), "ArkDeckSectionTitleStyle"));
        var actions = Ui.Row();
        if (_saved?.Answer.Value is { } saved)
        {
            panel.Children.Add(Ui.Text("history.filter.saved.summary",
                saved.Query is { } q ? S.Format(UiStrings.WindowsHistoryFilterSavedSummary, Describe(q)) : S.Text(UiStrings.WindowsHistoryFilterSavedNone), "ArkDeckCaptionStyle"));
            actions.Children.Add(Ui.Button("history.filter.save", S.Text(UiStrings.HistoryFilterSave), async (_, _) => await MutateSavedAsync(save: true)));
            if (saved.Query is not null)
            {
                actions.Children.Add(Ui.Button("history.filter.applySaved", S.Text(UiStrings.HistoryFilterApplySaved), (_, _) => ApplySaved(saved.Query)));
                actions.Children.Add(Ui.Button("history.filter.deleteSaved", S.Text(UiStrings.HistoryFilterDeleteSaved), async (_, _) => await MutateSavedAsync(save: false)));
            }
        }
        else if (_saved?.Answer.Unavailable is { } why)
        {
            panel.Children.Add(Ui.Text("history.filter.saved.failure", S.Format(UiStrings.WindowsHistoryFilterSavedUnavailable, why.ReasonText(S)), "ArkDeckCaptionStyle"));
            actions.Children.Add(Ui.Button("history.filter.reloadSaved", S.Text(UiStrings.HistoryFilterReloadSaved), async (_, _) => await ReloadSavedAsync()));
        }
        panel.Children.Add(actions);
        return panel;
    }

    private string Describe(HistoryFilterQuery q)
    {
        var parts = new List<string>();
        if (q.Activity != HistoryActivity.All) parts.Add(S.Text("history.activity." + HistoryFilterQuery.Name(q.Activity)));
        if (q.Search.Length > 0) parts.Add($"\u201c{q.Search}\u201d");
        if (q.Status != HistoryStatus.All) parts.Add(S.Text("history.filter.status." + HistoryFilterQuery.Name(q.Status)));
        if (q.Mode != HistoryMode.All) parts.Add(S.Text("history.filter.mode." + HistoryFilterQuery.Name(q.Mode)));
        if (q.SessionId is { } session) parts.Add(session);
        if (q.TargetId is { } target) parts.Add(target);
        if (q.Time != HistoryTime.AnyTime) parts.Add(S.Text("history.filter.time." + HistoryFilterQuery.Name(q.Time)));
        return parts.Count == 0 ? S.Text(UiStrings.HistoryActivityAll) : string.Join(" · ", parts);
    }

    /// <summary>macOS <c>applySavedFilter</c>: a Session or Target not among the Jobs read is dropped.</summary>
    private void ApplySaved(HistoryFilterQuery query) => SetFilter(query with
    {
        SessionId = query.SessionId is { } s && _jobs.Any(j => j.SessionId == s) ? s : null,
        TargetId = query.TargetId is { } t && _jobs.Any(j => j.TargetId == t) ? t : null,
    });

    private async Task ReloadSavedAsync()
    {
        if (_savedBusy) return;
        _savedBusy = true;
        try
        {
            _saved = await Task.Run(() => App.Loader.SavedHistoryFilterAsync());
            MainWindow.Instance.Report(_saved);
        }
        finally
        {
            _savedBusy = false;
            _filtersHost.Content = Filters();
        }
    }

    private async Task MutateSavedAsync(bool save)
    {
        if (_savedBusy || _saved?.Answer.Value is not { } current) return;
        _savedBusy = true;
        var query = _filter;
        try
        {
            var result = await Task.Run(() => save ? App.Loader.SaveHistoryFilterAsync(query, current.Generation) : App.Loader.DeleteHistoryFilterAsync(current.Generation));
            MainWindow.Instance.Report(result);
            if (result.Answer.Value is not null)
            {
                _saved = result;
                Ui.Say(_filterStatus, S.Text(save ? UiStrings.WindowsHistoryFilterSavedDone : UiStrings.WindowsHistoryFilterDeletedDone));
            }
            else
            {
                // A changed generation (or anything else) re-reads the Runtime's filter, as macOS does.
                var reason = result.Answer.Unavailable!.ReasonText(S);
                _saved = await Task.Run(() => App.Loader.SavedHistoryFilterAsync());
                Ui.Say(_filterStatus, reason);
            }
        }
        finally
        {
            _savedBusy = false;
        }
        var said = _filterStatus.Text;
        _filtersHost.Content = Filters();
        Ui.Say(_filterStatus, said);
    }

    private void SetFilter(HistoryFilterQuery filter, bool rebuildFilters = true)
    {
        _filter = filter;
        // Only the filters and the list are rebuilt, from the Jobs already read (no new read).
        if (rebuildFilters) DispatcherQueue.TryEnqueue(() => _filtersHost.Content = Filters());
        RenderTable();
    }

    /// <summary>The filtered list (macOS jobTable): the count, the rows, the empty match, Load Older.</summary>
    private void RenderTable()
    {
        _tableHost.Children.Clear();
        var shown = _filter.Apply(_jobs, DateTimeOffset.UtcNow);
        _tableHost.Children.Add(Ui.Heading("history.activity.recent", S.Text(UiStrings.HistoryActivityRecent), AutomationHeadingLevel.Level2));
        _tableHost.Children.Add(Ui.Text("history.activity.recentDescription", S.Text(UiStrings.HistoryActivityRecentDescription), "ArkDeckCaptionStyle"));
        _tableHost.Children.Add(Ui.Text("history.filter.resultCount", S.Format(UiStrings.HistoryFilterResultCount, (long)shown.Count, (long)_jobs.Count), "ArkDeckCaptionStyle"));
        if (shown.Count == 0)
        {
            _tableHost.Children.Add(Ui.Stack(4,
                Ui.Text("history.filter.empty", S.Text(UiStrings.HistoryFilterEmptyTitle), "ArkDeckSectionTitleStyle"),
                Ui.Text("history.filter.empty.description", S.Text(UiStrings.HistoryFilterEmptyDescription), "ArkDeckCaptionStyle"),
                Ui.Row(Ui.Button("history.filter.empty.reset", S.Text(UiStrings.HistoryFilterReset), (_, _) => SetFilter(HistoryFilterQuery.None)))));
        }
        else
        {
            var table = Ui.Choice("history.table", S.Text(UiStrings.AppNavigationHistory));
            foreach (var job in shown)
            {
                var stateText = Ui.JobState("history.state.", job.State) + (job.OutcomeUnknown ? S.Text(UiStrings.HistoryStateOutcomeUnknownSuffix) : string.Empty);
                var row = Ui.Row(
                    Ui.Text($"history.row.state.{job.JobId}", stateText),
                    Ui.Text($"history.row.{job.JobId}.operation", job.Operation, "ArkDeckMonoStyle"),
                    Ui.Text($"history.row.{job.JobId}.job", job.JobId, "ArkDeckMonoStyle"),
                    Ui.Text($"history.row.{job.JobId}.created", S.Text(UiStrings.WindowsHistoryColumnCreated) + " " + job.CreatedAtUtc, "ArkDeckCaptionStyle"));
                var item = Ui.Item("history.row." + job.JobId, $"{job.JobId}, {job.Operation}, {stateText}", row);
                item.Tag = job.JobId;
                table.Items.Add(item);
                if (job.JobId == _selected) table.SelectedItem = item;
            }
            table.SelectionChanged += async (_, e) =>
            {
                if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string jobId }) await ShowDetailAsync(jobId);
            };
            _tableHost.Children.Add(table);
        }
        if (_olderFailure is { } failure) _tableHost.Children.Add(Ui.Text("history.loadOlder.failure", failure, "ArkDeckCaptionStyle"));
        if (_cursor is not null)
        {
            _tableHost.Children.Add(_loadingOlder
                ? Ui.Progress("history.loadOlder.loading", S.Text(UiStrings.HistoryActionLoadOlder))
                : Ui.Row(Ui.Button("history.loadOlder", S.Text(UiStrings.HistoryActionLoadOlder), async (_, _) => await LoadOlderAsync())));
        }
    }

    /// <summary>macOS Load Older: the next <c>job.list</c> page, each Job once.</summary>
    private async Task LoadOlderAsync()
    {
        if (_loadingOlder || _cursor is not { } cursor) return;
        _loadingOlder = true;
        _olderFailure = null;
        RenderTable();
        var state = await Task.Run(() => App.Loader.OlderHistoryAsync(cursor));
        MainWindow.Instance.Report(state);
        _loadingOlder = false;
        if (state.Jobs.Value is { } older)
        {
            var known = _jobs.Select(j => j.JobId).ToHashSet(StringComparer.Ordinal);
            _jobs.AddRange(older.Where(j => known.Add(j.JobId)));
            _cursor = state.NextCursor;
            Ui.Say(_filterStatus, S.Format(UiStrings.HistoryFilterResultCount, (long)_filter.Apply(_jobs, DateTimeOffset.UtcNow).Count, (long)_jobs.Count));
        }
        else
        {
            _olderFailure = state.Jobs.Unavailable!.ReasonText(S);
        }
        RenderTable();
    }

    private async Task ShowDetailAsync(string jobId)
    {
        if (_selected != jobId) _artifactResults.Clear();
        _resultHosts.Clear();
        _selected = jobId;
        _detail.Children.Clear();
        _detail.Children.Add(Ui.Heading("history.detail.title", S.Text(UiStrings.HistoryDetailTitle)));
        _detail.Children.Add(Ui.Progress("history.detail.loading", S.Text(UiStrings.HistoryDetailLoading)));
        var state = await Task.Run(() => App.Loader.HistoryDetailAsync(jobId));
        if (_selected != jobId) return;
        RenderDetail(state);
        MainWindow.Instance.Report(state);
    }

    private void RenderDetail(HistoryDetailState state)
    {
        _detail.Children.Clear();
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Ui.Heading("history.detail.title", S.Text(UiStrings.HistoryDetailTitle)));
        var reload = Ui.Button("history.detail.reload", S.Text(UiStrings.HistoryDetailReload), async (_, _) => await ShowDetailAsync(state.JobId));
        Grid.SetColumn(reload, 1);
        header.Children.Add(reload);
        _detail.Children.Add(header);

        if (state.Status.Unavailable is { } why)
        {
            _detail.Children.Add(Ui.UnavailableNotice("history.detail.unavailable", UiStrings.HistoryUnavailableTitle, why));
            return;
        }
        var job = state.Status.Value!;
        if (job.OutcomeUnknown) _detail.Children.Add(Ui.Text("history.detail.attention", S.Text(UiStrings.HistoryDetailOutcomeUnknown), "ArkDeckSectionTitleStyle"));
        else if (job.WaitingForHuman) _detail.Children.Add(Ui.Text("history.detail.attention", S.Text(UiStrings.HistoryDetailWaitingForHuman), "ArkDeckSectionTitleStyle"));
        OpenWorkspace(state, job);

        // macOS summarySection: the Job and manifest summary.
        var status = state.Shown?.Value?.Status;
        string? StatusText(string key) => status is not null && status.TryGetValue(key, out var v) && v is ArkDeck.ClientKit.Json.JsonString s ? s.Value : null;
        _detail.Children.Add(Ui.Heading("history.detail.summary", S.Text(UiStrings.HistoryDetailSummary), AutomationHeadingLevel.Level3));
        foreach (var (id, key, value) in new (string, string, string?)[]
                 {
                     ("history.detail.job", UiStrings.HistoryDetailJob, job.JobId),
                     ("history.detail.session", UiStrings.HistoryDetailSession, job.SessionId ?? S.Text(UiStrings.HistoryValueNotReported)),
                     ("history.detail.operation", UiStrings.HistoryDetailOperation, job.Operation),
                     ("history.detail.target", UiStrings.HistoryDetailTarget, job.TargetId),
                     ("history.detail.state", UiStrings.HistoryDetailState, Ui.JobState("history.state.", job.State)),
                     ("history.detail.outcomeCertainty", UiStrings.HistoryDetailOutcomeCertainty, S.Text(job.OutcomeUnknown ? UiStrings.HistoryOutcomeUnknown : UiStrings.HistoryOutcomeConfirmed)),
                     ("history.detail.mode", UiStrings.HistoryDetailMode, job.ExecutionMode),
                     ("history.detail.effect", UiStrings.HistoryDetailEffect, StatusText("actualEffect") ?? "—"),
                     ("history.detail.created", UiStrings.HistoryDetailCreated, job.CreatedAtUtc),
                     ("history.detail.started", UiStrings.HistoryDetailStarted, StatusText("startedAtUtc") ?? "—"),
                     ("history.detail.finished", UiStrings.HistoryDetailFinished, job.FinishedAtUtc ?? "—"),
                 })
        {
            _detail.Children.Add(Ui.Fact(id, S.Text(key), value!));
        }
        _detail.Children.Add(Ui.Text("history.detail.projectionNote", S.Text(UiStrings.HistoryDetailProjectionNote), "ArkDeckCaptionStyle"));
        if (job.OutstandingResidueCount > 0)
        {
            _detail.Children.Add(Ui.Text("history.detail.residue", S.Format(UiStrings.HistoryDetailResidue, job.OutstandingResidueCount)));
        }

        Timeline(state.Shown);
        Correlation(state, job);
        Evidence(state.Evidence);
        Parameters(state.Evidence);

        _detail.Children.Add(Ui.Heading("history.detail.artifacts", S.Text(UiStrings.HistoryDetailArtifacts), AutomationHeadingLevel.Level3));
        if (state.Artifacts.Unavailable is { } artifactsWhy)
        {
            _detail.Children.Add(Ui.UnavailableNotice("history.artifacts.unavailable", UiStrings.WindowsHistoryArtifactsUnavailable, artifactsWhy));
            Recovery(job);
            return;
        }
        var artifacts = state.Artifacts.Value!;
        if (artifacts.Count == 0)
        {
            // A planned Job carries no captured Artifacts by design (macOS emptyPlanned).
            _detail.Children.Add(Ui.Text("history.artifacts.empty",
                S.Text(job.ExecutionMode == "planOnly" ? UiStrings.HistoryArtifactsEmptyPlanned : UiStrings.HistoryArtifactsEmpty), "ArkDeckCaptionStyle"));
            Recovery(job);
            return;
        }
        var list = Ui.ActionList("history.artifacts", S.Text(UiStrings.HistoryDetailArtifacts));
        foreach (var artifact in artifacts)
        {
            list.Rows.Add(Ui.ActionItem("history.artifact." + artifact.ArtifactId, $"{artifact.Name}, {artifact.Status}", ArtifactRow(state.JobId, artifact)));
        }
        _detail.Children.Add(list);
        _detail.Children.Add(Ui.Text("history.artifacts.exportBoundary", S.Text(UiStrings.HistoryArtifactsExportBoundary), "ArkDeckCaptionStyle"));
        if (artifacts.Any(a => a.IsTrace))
        {
            _detail.Children.Add(Ui.Text("history.artifacts.traceViewerDeferred", S.Text(UiStrings.WindowsTraceViewerDeferred), "ArkDeckCaptionStyle"));
        }
        Recovery(job);
    }

    /// <summary>macOS's detail header actions: Open the workspace that produced the Job with the
    /// record's read-only context (and, for a <c>capture.diagnostics@1</c> Job of another
    /// workspace, Open Diagnostics too); "no workspace" for other records.</summary>
    private void OpenWorkspace(HistoryDetailState state, JobSummary job)
    {
        var context = HistoryWorkspaceContext.Of(job, state.Evidence.Value, state.Artifacts.Value);
        if (context is null)
        {
            _detail.Children.Add(Ui.Text("history.openWorkspace.unsupported", S.Text(UiStrings.HistoryActivityOpenUnsupported), "ArkDeckCaptionStyle"));
            return;
        }
        var open = Ui.Button("history.openWorkspace", S.Text("history.activity.open." + HistoryWorkspaceContext.Name(context.Kind)),
            (_, _) => MainWindow.Instance.OpenHistoryWorkspace(context), accent: true);
        ToolTipService.SetToolTip(open, S.Text(UiStrings.HistoryContextReadOnly));
        AutomationProperties.SetHelpText(open, S.Text(UiStrings.HistoryContextReadOnly));
        var row = Ui.Row(open);
        if (context.OperationReference == HistoryWorkspaceContext.CaptureDiagnostics && context.Kind != WorkspaceKind.Diagnostics)
        {
            var diagnostics = Ui.Button("history.openDiagnostics", S.Text(UiStrings.HistoryActivityOpenDiagnostics),
                (_, _) => MainWindow.Instance.OpenHistoryWorkspace(context, inDiagnostics: true));
            ToolTipService.SetToolTip(diagnostics, S.Text(UiStrings.HistoryContextReadOnly));
            AutomationProperties.SetHelpText(diagnostics, S.Text(UiStrings.HistoryContextReadOnly));
            row.Children.Add(diagnostics);
        }
        _detail.Children.Add(row);
    }

    /// <summary>The macOS History evidence section (<c>job.evidence</c>): the Runtime's record
    /// of what ran and under which authority, the steps it reports and its blockers.</summary>
    private void Evidence(Loaded<JobEvidenceFacts> loaded)
    {
        _detail.Children.Add(Ui.Heading("history.detail.evidence", S.Text(UiStrings.HistoryDetailEvidence), AutomationHeadingLevel.Level3));
        if (loaded.Unavailable is { } why)
        {
            _detail.Children.Add(Ui.UnavailableNotice("history.evidence.unavailable", UiStrings.WindowsHistoryEvidenceUnavailable, why));
            return;
        }
        var e = loaded.Value!;
        var none = "—";
        foreach (var (id, key, value) in new (string, string, string)[]
                 {
                     ("history.evidence.status", UiStrings.WindowsHistoryEvidenceStatus, e.Status),
                     ("history.evidence.provider", UiStrings.HistoryEvidenceProvider, e.ProviderId),
                     ("history.evidence.catalog", UiStrings.HistoryEvidenceCatalog, e.CatalogDigest),
                     ("history.evidence.binding", UiStrings.HistoryEvidenceBinding, e.BindingRevision?.ToString(CultureInfo.InvariantCulture) ?? none),
                     ("history.evidence.authority", UiStrings.HistoryEvidenceAuthority, e.AuthorityKind ?? none),
                     ("history.evidence.authorityReference", UiStrings.HistoryEvidenceAuthorityReference, e.AuthorityReference ?? none),
                     ("history.evidence.model", UiStrings.HistoryEvidenceModel, e.ObservedModel ?? none),
                     ("history.evidence.firmware", UiStrings.HistoryEvidenceFirmware, e.ObservedFirmware ?? none),
                     ("history.evidence.transport", UiStrings.HistoryEvidenceTransport, e.ObservedTransport ?? none),
                     ("history.evidence.terminalState", UiStrings.HistoryEvidenceTerminalState, e.TerminalState is { } t ? Ui.JobState("history.state.", t) : none),
                     ("history.evidence.mode", UiStrings.HistoryEvidenceMode, e.ExecutionMode),
                     ("history.evidence.effect", UiStrings.HistoryEvidenceEffect, e.ActualEffect ?? none),
                     ("history.evidence.firstEvidence", UiStrings.HistoryEvidenceFirstEvidence, e.FirstEvidenceStepAtUtc ?? none),
                 })
        {
            _detail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        if (e.ActualStepKinds is null)
        {
            _detail.Children.Add(Ui.Text("history.evidence.steps.unreported", S.Text(UiStrings.HistoryValueNotReported), "ArkDeckCaptionStyle"));
        }
        else if (e.ActualStepKinds.Count > 0)
        {
            _detail.Children.Add(Ui.Text("history.evidence.steps", string.Join(" · ", e.ActualStepKinds), "ArkDeckMonoStyle"));
        }
        foreach (var blocker in e.Blockers.Concat(e.MissingRequiredArtifacts))
        {
            _detail.Children.Add(Ui.Text("history.evidence.blocker." + blocker, blocker, "ArkDeckMonoStyle"));
        }
    }

    /// <summary>macOS timelineSection: the Job's journal summary (<c>job.show</c>, paged).</summary>
    private void Timeline(Loaded<JobShown>? shown)
    {
        if (shown is null) return;
        if (shown.Unavailable is { } why)
        {
            _detail.Children.Add(Ui.Heading("history.detail.timeline", S.Text(UiStrings.HistoryDetailTimeline), AutomationHeadingLevel.Level3));
            _detail.Children.Add(Ui.Text("history.detail.timeline.unavailable", why.ReasonText(S), "ArkDeckMonoStyle"));
            return;
        }
        var entries = shown.Value!.Terminal.Timeline;
        if (entries.Count == 0) return;
        _detail.Children.Add(Ui.Heading("history.detail.timeline", S.Text(UiStrings.HistoryDetailTimeline), AutomationHeadingLevel.Level3));
        var text = Ui.Text("history.detail.timeline.entries", string.Join("\n", entries), "ArkDeckMonoStyle");
        text.IsTextSelectionEnabled = true;
        AutomationProperties.SetName(text, S.Text(UiStrings.HistoryDetailTimeline));
        _detail.Children.Add(text);
    }

    /// <summary>macOS correlationSection: the Job's Session, operation and Target as its status
    /// states them, and its Artifacts with their digests; a link to its Session's Jobs.</summary>
    private void Correlation(HistoryDetailState state, JobSummary job)
    {
        if (state.Shown?.Value is not { } shown || state.Artifacts.Value is not { } artifacts) return;
        string? Text(string key) => shown.Status.TryGetValue(key, out var v) && v is ArkDeck.ClientKit.Json.JsonString s ? s.Value : null;
        if (Text("sessionId") is not { } session || Text("targetId") != job.TargetId || Text("operation") != job.Operation) return;
        _detail.Children.Add(Ui.Heading("history.detail.correlation", S.Text(UiStrings.HistoryDetailCorrelation), AutomationHeadingLevel.Level3));
        _detail.Children.Add(Ui.Fact("history.correlation.job", S.Text(UiStrings.HistoryDetailJob), job.JobId));
        _detail.Children.Add(Ui.Fact("history.correlation.session", S.Text(UiStrings.HistoryDetailSession), session));
        _detail.Children.Add(Ui.Fact("history.correlation.operation", S.Text(UiStrings.HistoryDetailOperation), job.Operation));
        _detail.Children.Add(Ui.Fact("history.correlation.target", S.Text(UiStrings.HistoryDetailTarget), job.TargetId));
        _detail.Children.Add(Ui.Row(Ui.Button("history.correlation.showSession", S.Text(UiStrings.HistoryCorrelationShowSession),
            (_, _) => SetFilter(HistoryFilterQuery.None with { SessionId = session }))));
        var published = artifacts.Where(a => a.Digest is not null).ToArray();
        if (published.Length == 0)
        {
            _detail.Children.Add(Ui.Text("history.correlation.noArtifacts", S.Text(UiStrings.HistoryCorrelationNoArtifacts), "ArkDeckCaptionStyle"));
        }
        else
        {
            _detail.Children.Add(Ui.Text("history.correlation.artifactCount", S.Format(UiStrings.HistoryCorrelationArtifactCount, (long)published.Length)));
            foreach (var artifact in published)
            {
                _detail.Children.Add(Ui.Stack(2,
                    Ui.Text($"history.correlation.artifact.{artifact.ArtifactId}", $"{artifact.Name} · {artifact.ArtifactId}", "ArkDeckCaptionStyle"),
                    Ui.Text($"history.correlation.artifact.{artifact.ArtifactId}.sha256", artifact.Digest!, "ArkDeckMonoStyle")));
            }
        }
        _detail.Children.Add(Ui.Text("history.correlation.readOnly", S.Text(UiStrings.HistoryCorrelationReadOnly), "ArkDeckCaptionStyle"));
    }

    /// <summary>macOS parameterSection: the Trace parameters before and after a capture, and the
    /// typed inputs the Job recorded.</summary>
    private void Parameters(Loaded<JobEvidenceFacts> loaded)
    {
        if (loaded.Value is not { } e) return;
        _detail.Children.Add(Ui.Heading("history.detail.parameters", S.Text(UiStrings.HistoryDetailParameters), AutomationHeadingLevel.Level3));
        if (e.TraceParameters is { Count: > 0 } trace)
        {
            var list = Ui.List("history.parameters.traceDiff", S.Text(UiStrings.HistoryDetailParameters));
            foreach (var p in trace)
            {
                string Value(string state, string? value) => state switch
                {
                    "value" => value ?? S.Text(UiStrings.HistoryValueNotReported),
                    "missing" => S.Text(UiStrings.HistoryParametersStateMissing),
                    "unreadable" => S.Text(UiStrings.HistoryParametersStateUnreadable),
                    _ => S.Text(UiStrings.HistoryParametersStateUnknown),
                };
                var line = $"{p.Name} · {S.Text(UiStrings.HistoryParametersColumnBefore)} {Value(p.BeforeState, p.BeforeValue)} · " +
                           $"{S.Text(UiStrings.HistoryParametersColumnAfter)} {Value(p.AfterState, p.AfterValue)} · {S.Text("history.parameters.comparison." + p.Comparison)}";
                list.Items.Add(Ui.Item("history.parameters.trace." + p.Name, line, Ui.Text($"history.parameters.trace.{p.Name}.text", line, "ArkDeckMonoStyle")));
            }
            _detail.Children.Add(list);
            if (e.Parameters is { Count: > 0 }) _detail.Children.Add(Ui.Text("history.parameters.typedInputs", S.Text(UiStrings.HistoryParametersTypedInputs), "ArkDeckCaptionStyle"));
        }
        if (e.Parameters is null)
        {
            if (e.TraceParameters is not { Count: > 0 }) _detail.Children.Add(Ui.Text("history.parameters.unavailable", S.Text(UiStrings.HistoryParametersUnavailable), "ArkDeckCaptionStyle"));
        }
        else if (e.Parameters.Count == 0)
        {
            if (e.TraceParameters is not { Count: > 0 }) _detail.Children.Add(Ui.Text("history.parameters.empty", S.Text(UiStrings.HistoryParametersEmpty), "ArkDeckCaptionStyle"));
        }
        else
        {
            foreach (var (name, value) in e.DisplayParameters) _detail.Children.Add(Ui.Fact("history.parameter." + name, name, value));
        }
    }

    /// <summary>macOS recoverySection: the record's unresolved condition, if any, read only.</summary>
    private void Recovery(JobSummary job)
    {
        _detail.Children.Add(Ui.Heading("history.detail.recovery", S.Text(UiStrings.HistoryDetailRecovery), AutomationHeadingLevel.Level3));
        var key = job.OutcomeUnknown ? UiStrings.HistoryRecoveryOutcomeUnknown
            : job.WaitingForHuman ? UiStrings.HistoryRecoveryWaitingForHuman
            : job.OutstandingResidueCount > 0 ? UiStrings.HistoryRecoveryResidue
            : UiStrings.HistoryRecoveryNone;
        _detail.Children.Add(Ui.Text("history.recovery.state", S.Text(key)));
        _detail.Children.Add(Ui.Text("history.recovery.readOnly", S.Text(UiStrings.HistoryRecoveryReadOnly), "ArkDeckCaptionStyle"));
    }

    /// <summary>Opens one Job's record (the Job Inspector's "Open this record").</summary>
    public async Task OpenAsync(string jobId)
    {
        _selected = jobId;
        await RefreshAsync();
    }

    /// <summary>One Artifact as the macOS History row shows it: name and status, role-free
    /// provenance and size, SHA-256, privacy and media type; then its actions and their
    /// results (kept while the same Job stays selected).</summary>
    private StackPanel ArtifactRow(string jobId, ArtifactSummary artifact)
    {
        var id = artifact.ArtifactId;
        var row = Ui.Stack(2,
            Ui.Row(Ui.Text($"history.artifact.{id}.name", artifact.Name, "ArkDeckSectionTitleStyle"),
                Ui.Text($"history.artifact.{id}.status", artifact.Status, "ArkDeckCaptionStyle")),
            Ui.Text($"history.artifact.{id}.source", $"{artifact.SourceOperation} · {S.Format(UiStrings.WindowsBytes, artifact.ByteCountText)}", "ArkDeckCaptionStyle"));
        if (artifact.Digest is { } digest) row.Children.Add(Ui.Text($"history.artifact.{id}.sha256", digest, "ArkDeckMonoStyle"));
        row.Children.Add(Ui.Text($"history.artifact.{id}.privacy", $"{artifact.Privacy} · {artifact.MediaType}", "ArkDeckCaptionStyle"));
        var actions = Ui.Row();
        // Only a published Artifact has bytes to export (macOS disables the button otherwise;
        // here it is absent and the status above says why).
        if (artifact.IsPublished)
        {
            actions.Children.Add(Ui.Button("history.artifact.export." + id, S.Text(UiStrings.HistoryArtifactsExport), async (_, _) => await ExportAsync(jobId, artifact)));
        }
        if (artifact.IsTrace)
        {
            actions.Children.Add(Ui.Button("history.artifact.inspectTrace." + id, S.Text(UiStrings.WindowsTraceInspectAction), async (_, _) => await InspectAsync(jobId, artifact)));
        }
        if (actions.Children.Count > 0) row.Children.Add(actions);
        var result = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
        AutomationProperties.SetAutomationId(result, $"history.artifact.{id}.result");
        if (_artifactResults.TryGetValue(id, out var kept)) result.Content = kept().Content;
        _resultHosts[id] = result;
        row.Children.Add(result);
        return row;
    }

    private void ShowResult(string artifactId, Func<(FrameworkElement Content, TextBlock? Announce)> build)
    {
        _artifactResults[artifactId] = build;
        if (!_resultHosts.TryGetValue(artifactId, out var host)) return;
        var (content, announce) = build();
        host.Content = content;
        if (announce is not null) Ui.Say(announce, announce.Text);
    }

    /// <summary>The macOS export: a preview of what will be written (name, size, privacy,
    /// SHA-256; a sensitive Artifact needs its own confirmation), a save location the person
    /// picks, then the bounded, digest-verified read. Nothing is sent to the Runtime but the
    /// reads; the destination stays in the App.</summary>
    private async Task ExportAsync(string jobId, ArtifactSummary artifact)
    {
        var message = S.Format(UiStrings.HistoryArtifactsExportPreviewMessage,
            artifact.Name, S.Format(UiStrings.WindowsBytes, artifact.ByteCountText), artifact.Privacy, artifact.Digest ?? string.Empty);
        var preview = Ui.Dialog(XamlRoot, "history.artifacts.exportPreview", S.Text(UiStrings.HistoryArtifactsExportPreviewTitle),
            Ui.Text("history.artifacts.exportPreview.message", message),
            S.Text(artifact.IsSensitive ? UiStrings.HistoryArtifactsExportSensitive : UiStrings.HistoryArtifactsExportConfirm),
            S.Text(UiStrings.HistoryArtifactsExportCancel));
        if (await preview.ShowAsync() != ContentDialogResult.Primary) return;

        var picker = new FileSavePicker(MainWindow.Instance.AppWindow.Id)
        {
            SuggestedFileName = SafeExportName(artifact.Name),
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        var extension = Path.GetExtension(SafeExportName(artifact.Name));
        picker.FileTypeChoices.Add(extension.Length > 1 ? extension : ".bin", [extension.Length > 1 ? extension : ".bin"]);
        var picked = await picker.PickSaveFileAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;

        var id = artifact.ArtifactId;
        ShowResult(id, () => (Ui.Progress($"history.artifact.exporting.{id}", S.Text(UiStrings.HistoryArtifactsExporting)), null));
        var exporter = new ArtifactExporter(App.Loader.Channel);
        var outcome = await Task.Run(() => exporter.ExportAsync(jobId, artifact, picked.Path, allowSensitive: artifact.IsSensitive));
        if (outcome.Completed)
        {
            MainWindow.Instance.Report(outcome);
            var path = outcome.ExportedPath!;
            ShowResult(id, () =>
            {
                var done = Ui.Live(Ui.Text($"history.artifact.exported.{id}", S.Format(UiStrings.WindowsHistoryArtifactsExported, path), "ArkDeckCaptionStyle"),
                    AutomationLiveSetting.Polite);
                var show = Ui.Button($"history.artifact.explorer.{id}", S.Text(UiStrings.WindowsHistoryArtifactsShowInExplorer), async (_, _) => await ShowInExplorerAsync(path));
                return (Ui.Stack(4, done, show), done);
            });
            return;
        }
        var why = outcome.Failure!;
        MainWindow.Instance.Report(outcome);
        ShowResult(id, () =>
        {
            var failed = Ui.Live(Ui.Text($"history.artifact.exportFailure.{id}", $"{S.Text(UiStrings.WindowsHistoryArtifactsExportFailed)} · {why.ReasonText(S)}"),
                AutomationLiveSetting.Assertive);
            return (Ui.Stack(4, failed, Ui.Row(Ui.Text($"history.artifact.exportFailure.{id}.cli", why.CliText(S), "ArkDeckMonoStyle"),
                Ui.CopyCli($"history.artifact.exportFailure.{id}.copyCli", why.CliCommand))), failed);
        });
    }

    /// <summary>Asks the Runtime to inspect the Job's raw Trace and shows its answer: the
    /// inspection facts, or <c>unavailable(operationUnavailable): Trace inspection is
    /// unavailable</c> and the CLI command while no Trace inspector is composed.</summary>
    private async Task InspectAsync(string jobId, ArtifactSummary trace)
    {
        var id = trace.ArtifactId;
        ShowResult(id, () => (Ui.Progress($"history.artifact.trace.{id}.inspecting", S.Text(UiStrings.WindowsTraceInspectInspecting)), null));
        var state = await Task.Run(() => App.Loader.InspectTraceAsync(jobId, trace));
        MainWindow.Instance.Report(state);
        if (state.Inspection.Unavailable is { } why)
        {
            ShowResult(id, () =>
            {
                var notice = Ui.UnavailableNotice($"history.artifact.trace.{id}.unavailable", UiStrings.WindowsTraceInspectUnavailable, why);
                var reason = Ui.Live((TextBlock)notice.Children[1], AutomationLiveSetting.Polite);
                return (notice, reason);
            });
            return;
        }
        var inspection = state.Inspection.Value!;
        ShowResult(id, () =>
        {
            var title = Ui.Live(Ui.Text($"history.artifact.trace.{id}.title", S.Text(UiStrings.WindowsTraceInspectTitle), "ArkDeckSectionTitleStyle"), AutomationLiveSetting.Polite);
            return (Ui.Stack(2, title,
            Ui.Text($"history.artifact.trace.{id}.engine", S.Format(UiStrings.WindowsTraceInspectEngine, inspection.EngineName, inspection.EngineVersion), "ArkDeckMonoStyle"),
            Ui.Text($"history.artifact.trace.{id}.parser", S.Format(UiStrings.WindowsTraceInspectParser, inspection.ParserName, inspection.ParserVersion), "ArkDeckMonoStyle"),
            Ui.Text($"history.artifact.trace.{id}.duration", S.Format(UiStrings.WindowsTraceInspectDuration, inspection.DurationNs), "ArkDeckMonoStyle"),
            Ui.Text($"history.artifact.trace.{id}.capabilities", S.Format(UiStrings.WindowsTraceInspectCapabilities, string.Join(", ", inspection.Capabilities)), "ArkDeckMonoStyle"),
            Ui.Text($"history.artifact.trace.{id}.quality", S.Format(UiStrings.WindowsTraceInspectQuality, inspection.DataQuality, inspection.IssueCount), "ArkDeckMonoStyle")), title);
        });
    }

    private static async Task ShowInExplorerAsync(string path)
    {
        var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
        var folder = await file.GetParentAsync();
        var options = new Windows.System.FolderLauncherOptions();
        options.ItemsToSelect.Add(file);
        await Windows.System.Launcher.LaunchFolderAsync(folder, options);
    }

    /// <summary>The macOS safe export name, with the characters Windows file names refuse
    /// replaced as well.</summary>
    internal static string SafeExportName(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sanitized = new string(value.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim().TrimEnd('.');
        return sanitized.Length == 0 ? "ArkDeck-Artifact" : sanitized;
    }
}
