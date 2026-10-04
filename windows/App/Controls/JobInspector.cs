using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Controls;

/// <summary>
/// The global Job Inspector (macOS <c>GlobalJobInspectorView</c>): a compact bar (show/hide,
/// refresh, open History, a status line that is a polite UIA live region) and, expanded, the
/// Jobs <c>job.list</c> returns or "Runtime status unavailable" with the reason; the selected
/// Job's <c>job.status</c> and <c>job.events</c>. The selected Job's state is an assertive live
/// region: while the Job is active it is re-read every two seconds and each change is
/// announced. Nothing here writes to the daemon.
/// </summary>
public sealed partial class JobInspector : UserControl
{
    private static Localizer S => App.Strings;

    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

    private readonly Button _toggle;
    private readonly TextBlock _compact;
    private readonly StackPanel _expanded = new() { Spacing = 8 };
    private readonly StackPanel _list = new() { Spacing = 8 };
    private readonly StackPanel _detail = new() { Spacing = 8 };
    private readonly DispatcherQueueTimer _poll;
    private bool _isExpanded = true;
    private string? _selectedJob;
    private string? _lastState;
    private TextBlock? _stateText;
    // What the last cancellation or result read said, per Job: the detail is rebuilt on every
    // poll, these lines are not re-read.
    private readonly Dictionary<string, string> _cancelMessages = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Loaded<JobResultFacts>> _results = new(StringComparer.Ordinal);

    public JobInspector()
    {
        AutomationProperties.SetAutomationId(this, "jobInspector");
        AutomationProperties.SetName(this, S.Text(UiStrings.JobInspectorRuntimeFacts));
        _toggle = Ui.Button("jobInspector.toggle", S.Text(UiStrings.JobInspectorActionHide), (_, _) => SetExpanded(!_isExpanded));
        _compact = Ui.Live(Ui.Text("jobInspector.compact.status", S.Text(UiStrings.JobInspectorRefreshing), "ArkDeckCaptionStyle"), AutomationLiveSetting.Polite);
        _compact.VerticalAlignment = VerticalAlignment.Center;
        var bar = Ui.Row(
            _toggle,
            Ui.Button("jobInspector.refresh", S.Text(UiStrings.JobInspectorActionRefresh), async (_, _) => await RefreshAsync()),
            Ui.Button("jobInspector.openHistory", S.Text(UiStrings.JobInspectorActionOpenHistory), (_, _) => MainWindow.Instance.Select("history")),
            _compact);
        var columns = new Grid { ColumnSpacing = 16 };
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
        columns.Children.Add(_list);
        Grid.SetColumn(_detail, 1);
        columns.Children.Add(_detail);
        _expanded.Children.Add(new ScrollViewer { Content = columns, MaxHeight = 280 });
        Content = Ui.Stack(8, bar, _expanded);
        Padding = new Thickness(16, 8, 16, 8);

        _poll = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _poll.Interval = PollInterval;
        _poll.Tick += async (_, _) => await PollSelectedAsync();
        Loaded += async (_, _) => await RefreshAsync();
    }

    public async Task RefreshAsync()
    {
        var state = await Task.Run(App.Loader.HistoryAsync);
        RenderList(state);
        MainWindow.Instance.Report(state);
        MainWindow.Instance.ShowJobRecovery(state.Jobs.Value);
        if (_selectedJob is { } job) await ShowJobAsync(job);
    }

    /// <summary>Shows one Job's status and events (from History or this list).</summary>
    public async Task ShowJobAsync(string jobId)
    {
        if (_selectedJob != jobId) _lastState = null;
        _selectedJob = jobId;
        SetExpanded(true);
        var state = await Task.Run(() => App.Loader.JobAsync(jobId));
        if (_selectedJob != jobId) return;
        RenderDetail(state);
        MainWindow.Instance.Report(state);
    }

    private async Task PollSelectedAsync()
    {
        if (_selectedJob is null) return;
        await ShowJobAsync(_selectedJob);
    }

    private void SetExpanded(bool expanded)
    {
        _isExpanded = expanded;
        _expanded.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        var label = S.Text(expanded ? UiStrings.JobInspectorActionHide : UiStrings.JobInspectorActionShow);
        _toggle.Content = label;
        AutomationProperties.SetName(_toggle, label);
    }

    private void SetCompact(string text)
    {
        if (_compact.Text == text) return;
        _compact.Text = text;
        AutomationProperties.SetName(_compact, text);
        Ui.Announce(_compact);
    }

    private void RenderList(HistoryState state)
    {
        _list.Children.Clear();
        if (state.Jobs.Unavailable is { } why)
        {
            SetCompact(S.Text(UiStrings.JobInspectorCompactUnavailable));
            _list.Children.Add(Ui.UnavailableNotice("jobInspector.unavailable", UiStrings.JobInspectorUnavailableTitle, why, UiStrings.JobInspectorUnavailableGuidance));
            return;
        }
        var jobs = state.Jobs.Value!;
        if (jobs.Count == 0)
        {
            SetCompact(S.Text(UiStrings.JobInspectorCompactEmpty));
            _list.Children.Add(Ui.Stack(4,
                Ui.Text("jobInspector.empty", S.Text(UiStrings.JobInspectorEmptyTitle), "ArkDeckSectionTitleStyle"),
                Ui.Text("jobInspector.empty.description", S.Text(UiStrings.JobInspectorEmptyDescription))));
            return;
        }
        SetCompact(S.Format(UiStrings.JobInspectorCompactActiveCount, jobs.Count(j => j.IsActive)));
        var list = Ui.Choice("jobInspector.list", S.Text(UiStrings.JobInspectorRuntimeFacts));
        // As on macOS: Jobs that need attention first, then active ones, then the rest.
        foreach (var job in jobs.OrderBy(j => j.OutcomeUnknown || j.WaitingForHuman ? 0 : j.IsActive ? 1 : 2))
        {
            var stateText = Ui.JobState("job.state.", job.State);
            var item = Ui.Item("jobInspector.row." + job.JobId, $"{job.Operation}, {stateText}",
                Ui.Stack(0, Ui.Text($"jobInspector.row.{job.JobId}.operation", job.Operation, "ArkDeckMonoStyle"),
                    Ui.Text($"jobInspector.row.{job.JobId}.state", stateText, "ArkDeckCaptionStyle")));
            item.Tag = job.JobId;
            list.Items.Add(item);
            if (job.JobId == _selectedJob) list.SelectedItem = item;
        }
        list.SelectionChanged += async (_, e) =>
        {
            if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string jobId }) await ShowJobAsync(jobId);
        };
        _list.Children.Add(list);
        if (_selectedJob is null)
        {
            _detail.Children.Clear();
            _detail.Children.Add(Ui.Text("jobInspector.select", S.Text(UiStrings.JobInspectorSelect)));
        }
    }

    private void RenderDetail(JobDetailState state)
    {
        _detail.Children.Clear();
        if (state.Status.Unavailable is { } why)
        {
            _poll.Stop();
            _detail.Children.Add(Ui.UnavailableNotice("jobInspector.detail.unavailable", UiStrings.JobInspectorUnavailableTitle, why));
            return;
        }
        var job = state.Status.Value!;
        var label = Ui.JobState("job.state.", job.State);
        _stateText = Ui.Live(Ui.Text("jobInspector.state", label, "ArkDeckSectionTitleStyle"), AutomationLiveSetting.Assertive);
        _detail.Children.Add(Ui.Heading("jobInspector.runtimeFacts", S.Text(UiStrings.JobInspectorRuntimeFacts)));
        _detail.Children.Add(_stateText);
        if (job.OutcomeUnknown) _detail.Children.Add(Ui.Text("jobInspector.attention", S.Text(UiStrings.JobInspectorResultOutcomeUnknown)));
        else if (job.WaitingForHuman) _detail.Children.Add(Ui.Text("jobInspector.attention", S.Text(UiStrings.JobInspectorResultWaitingForHuman)));
        Actions(job);
        foreach (var (id, key, value) in new[]
                 {
                     ("jobInspector.fact.job", UiStrings.JobInspectorFactJob, job.JobId),
                     ("jobInspector.fact.operation", UiStrings.JobInspectorFactOperation, job.Operation),
                     ("jobInspector.fact.target", UiStrings.JobInspectorFactTarget, job.TargetId),
                     ("jobInspector.fact.recordedState", UiStrings.JobInspectorFactRecordedState, job.State),
                     ("jobInspector.fact.mode", UiStrings.JobInspectorFactMode, job.ExecutionMode),
                 })
        {
            _detail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        if (!job.IsActive) Result(job);
        _detail.Children.Add(Ui.Heading("jobInspector.timeline", S.Text(UiStrings.JobInspectorTimeline)));
        if (state.Events.Unavailable is { } eventsWhy)
        {
            _detail.Children.Add(Ui.Text("jobInspector.timeline.unavailable", eventsWhy.ReasonText(S), "ArkDeckCaptionStyle"));
        }
        else
        {
            var entries = Ui.List("jobInspector.timeline.entries", S.Text(UiStrings.JobInspectorTimeline));
            foreach (var e in state.Events.Value!)
            {
                var text = $"{e.Timestamp}  {e.Type}  {e.FromState} → {e.ToState}";
                entries.Items.Add(Ui.Item("jobInspector.timeline." + e.EventId, text, Ui.Text($"jobInspector.timeline.{e.EventId}.text", text, "ArkDeckMonoStyle")));
            }
            _detail.Children.Add(entries);
        }

        // Announce a change of the selected Job's state (not the first read of a Job).
        if (_lastState is not null && _lastState != job.State)
        {
            DispatcherQueue.TryEnqueue(() => { if (_stateText is not null) Ui.Announce(_stateText); });
        }
        _lastState = job.State;
        if (job.IsActive) _poll.Start();
        else _poll.Stop();
    }

    /// <summary>The macOS inspector actions: open the record in History, and — for a queued or
    /// active Job whose outcome is known (<c>RuntimeJobControlApplicationFacade.canCancel</c>) —
    /// request cancellation after a confirmation. A request is not an outcome: the line says
    /// the Runtime is reaching a safe boundary, and the state is read back.</summary>
    private void Actions(JobSummary job)
    {
        var actions = Ui.Row(Ui.Button("jobInspector.openRecord", S.Text(UiStrings.JobInspectorActionOpenRecord),
            async (_, _) => await MainWindow.Instance.OpenJobAsync(job.JobId)));
        if (job.IsActive && !job.OutcomeUnknown)
        {
            actions.Children.Add(Ui.Button("jobInspector.cancel", S.Text(UiStrings.JobInspectorActionCancel), async (_, _) => await CancelAsync(job)));
        }
        _detail.Children.Add(actions);
        if (_cancelMessages.TryGetValue(job.JobId, out var message))
        {
            _detail.Children.Add(Ui.Live(Ui.Text("jobInspector.cancel.result", message, "ArkDeckCaptionStyle"), AutomationLiveSetting.Polite));
        }
    }

    private async Task CancelAsync(JobSummary job)
    {
        var dialog = Ui.Dialog(XamlRoot, "jobInspector.cancel.confirm", S.Text(UiStrings.WindowsJobInspectorCancelTitle),
            Ui.Text("jobInspector.cancel.message", S.Format(UiStrings.WindowsJobInspectorCancelMessage, job.JobId)),
            S.Text(UiStrings.JobInspectorActionCancel), S.Text(UiStrings.SettingsCommonCancel));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var state = await Task.Run(() => App.Loader.CancelJobAsync(job.JobId));
        MainWindow.Instance.Report(state);
        _cancelMessages[job.JobId] = state.Answer switch
        {
            { Value.Requested: true } => S.Text(UiStrings.JobInspectorCancelRequested),
            { Unavailable: { } why } => $"{S.Text(UiStrings.JobInspectorCancelRefused)} · {why.ReasonText(S)}",
            _ => S.Text(UiStrings.JobInspectorCancelRefused),
        };
        await ShowJobAsync(job.JobId);
        foreach (var text in _detail.Children.OfType<TextBlock>().Where(t => AutomationProperties.GetAutomationId(t) == "jobInspector.cancel.result"))
        {
            Ui.Announce(text);
        }
        await RefreshAsync();
    }

    /// <summary>A terminal Job's <c>job.result</c>: the Artifacts the Runtime verified and the
    /// cleanup it still owes (read once per Job).</summary>
    private void Result(JobSummary job)
    {
        _detail.Children.Add(Ui.Heading("jobInspector.result", S.Text(UiStrings.WindowsJobInspectorResult)));
        if (!_results.TryGetValue(job.JobId, out var loaded))
        {
            var id = job.JobId;
            _detail.Children.Add(Ui.Progress("jobInspector.result.loading", S.Text(UiStrings.JobInspectorRefreshing)));
            DispatcherQueue.TryEnqueue(async () =>
            {
                var state = await Task.Run(() => App.Loader.JobResultAsync(id));
                MainWindow.Instance.Report(state);
                _results[id] = state.Answer;
                if (_selectedJob == id) await ShowJobAsync(id);
            });
            return;
        }
        if (loaded.Unavailable is { } why)
        {
            _detail.Children.Add(Ui.UnavailableNotice("jobInspector.result.unavailable", UiStrings.WindowsJobInspectorResultUnavailable, why));
            return;
        }
        var result = loaded.Value!;
        _detail.Children.Add(Ui.Text("jobInspector.result.artifacts",
            S.Format(UiStrings.WindowsJobInspectorResultArtifacts, result.Artifacts.Count, result.Artifacts.Count(a => a.BytesVerified), result.CleanupCount)));
    }
}
