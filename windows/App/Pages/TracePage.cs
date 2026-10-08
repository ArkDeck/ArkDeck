using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace ArkDeck.App.Pages;

/// <summary>
/// Trace, as the macOS Trace workspace (<c>TraceWorkspaceView</c>): capture a bounded Trace from
/// an adopted device — the device, a capture profile and a duration, checked against the
/// Runtime's probe of that device — as one typed <c>capture.diagnostics@1</c> Job, then open the
/// captured Trace in the Trace viewer. Start never shows disabled: while a capture cannot start,
/// the first reason is the status line, and choosing Start says it again.
/// </summary>
public sealed partial class TracePage() : SurfacePage<TraceState>(
    "trace", "trace.title", UiStrings.AppNavigationTrace,
    "trace.refresh", UiStrings.TraceActionRefresh, "trace.loading", UiStrings.SettingsCommonLoading), IHistoryContextPage
{
    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _footer = new() { Spacing = 8 };
    private StackPanel _viewer = new() { Spacing = 8 };
    private TextBlock _validation = new();
    private TextBlock _status = Ui.Status("trace.status");
    private TraceState? _state;
    private string? _targetId;
    private string? _pinnedTargetId;
    private string _presetId = TraceOperations.DefaultPreset;
    private string _durationText = "10";
    private TraceDurationUnit _unit = TraceDurationUnit.Seconds;
    private bool _submitting;
    private bool _cancelling;
    private string? _activeJobId;
    private JobTerminal? _terminal;
    private string? _submissionFailure;
    private bool _preparingViewer;
    private string? _viewerFailureKey;
    private Unavailable? _viewerFailure;
    private TraceDocument? _latest;
    private HistoryWorkspaceContext? _history;
    private string? _historyTraceJob;

    /// <summary>macOS <c>openHistoryContext</c>: the record's Target is pinned and, for a capture,
    /// its raw Trace is read (verified) into the inbox and opened in the Trace viewer.</summary>
    public void OpenHistoryContext(HistoryWorkspaceContext context)
    {
        _history = context;
        _pinnedTargetId = context.TargetId;
        _targetId = context.TargetId;
        _historyTraceJob = context.OperationReference == HistoryWorkspaceContext.CaptureDiagnostics ? context.JobId : null;
    }

    protected override async Task<TraceState> LoadAsync()
    {
        var requested = _targetId;
        var state = await App.Loader.TraceAsync(requested);
        var resolved = state.ResolveSelection(_pinnedTargetId, requested);
        // A probe of another Target is never applied to the selection: read the selection's.
        return resolved is not null && resolved != requested && state.Probe?.Value?.TargetId != resolved
            ? await App.Loader.TraceAsync(resolved)
            : state;
    }

    private TraceTarget? Target => _state?.JoinedTargets.FirstOrDefault(t => t.TargetId == _targetId);

    private TracePreset Preset => TraceOperations.Preset(_presetId);

    private TraceDurationValidation Duration => TraceDuration.Validate(_durationText, _unit, _state?.DurationRange ?? TraceOperations.DefaultDurationRange);

    private IReadOnlyList<TraceBlocker> Blockers => _state?.Blockers(Target, Preset, Duration.IsValid) ?? [new("trace.blocker.checking", null)];

    protected override void Render(TraceState state, StackPanel body)
    {
        _state = state;
        _targetId = state.ResolveSelection(_pinnedTargetId, _targetId);
        var said = _status.Text;
        _status = Ui.Status("trace.status");
        Ui.SetText(_status, said);
        if (_history is { } history)
        {
            body.Children.Add(HistoryContextBanner.Create(history, async () =>
            {
                _history = null;
                _historyTraceJob = null;
                _pinnedTargetId = null;
                await RefreshAsync();
            }));
        }
        body.Children.Add(Ui.Text("trace.workspace.summary", S.Text(UiStrings.TraceWorkspaceSummary), "ArkDeckCaptionStyle"));
        body.Children.Add(Ui.Card(Capture(state), "trace.capture.section"));
        _viewer = new StackPanel { Spacing = 8 };
        body.Children.Add(Ui.Card(_viewer, "trace.viewer.section"));
        body.Children.Add(_status);
        RenderViewer();
        if (_historyTraceJob is { } job)
        {
            _historyTraceJob = null;
            DispatcherQueue.TryEnqueue(async () => await OpenCapturedAsync(job, open: true));
        }
    }

    // ---- capture ----

    private StackPanel Capture(TraceState state)
    {
        var (availabilityKey, _) = AvailabilityOf(state);
        var header = Ui.Row(
            Ui.Heading("trace.capture.title", S.Text(UiStrings.TraceCaptureTitle), AutomationHeadingLevel.Level2),
            Ui.Text("trace.availability.status", S.Text(availabilityKey)));
        var capture = Ui.Stack(16, header, Ui.Columns(Device(state), Profile()), DurationSection(state));
        _footer = new StackPanel { Spacing = 8 };
        capture.Children.Add(new Border { Height = 1, Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"] });
        capture.Children.Add(_footer);
        RenderFooter();
        return capture;
    }

    private (string Key, bool Ready) AvailabilityOf(TraceState state) =>
        state.Operation.Availability.Kind == AvailabilityKind.Checking
            ? (UiStrings.TraceAvailabilityChecking, false)
            : Blockers.Count == 0 ? (UiStrings.TraceAvailabilityAvailable, true) : (UiStrings.TraceAvailabilityUnavailable, false);

    private UIElement Device(TraceState state)
    {
        var targets = state.JoinedTargets;
        if (targets.Count == 0)
        {
            var text = state.Targets.Unavailable is { } why ? why.ReasonText(S) : S.Text(UiStrings.TraceTargetEmpty);
            return Ui.Stack(4,
                Ui.Text("trace.capture.device", S.Text(UiStrings.TraceCaptureDevice), "ArkDeckCaptionStyle"),
                Ui.Text("trace.target.empty", text));
        }
        var picker = new ComboBox { Header = S.Text(UiStrings.TraceCaptureDevice), MinWidth = 260, MaxWidth = 440 };
        AutomationProperties.SetAutomationId(picker, "trace.target.picker");
        AutomationProperties.SetName(picker, S.Text(UiStrings.TraceCaptureDevice));
        foreach (var target in targets)
        {
            var item = new ComboBoxItem { Content = target.Title, Tag = target.TargetId };
            AutomationProperties.SetAutomationId(item, "trace.target." + target.TargetId);
            picker.Items.Add(item);
            if (target.TargetId == _targetId) picker.SelectedItem = item;
        }
        picker.SelectionChanged += async (_, _) =>
        {
            if (picker.SelectedItem is not ComboBoxItem { Tag: string id } || id == _targetId) return;
            _pinnedTargetId = null;
            _targetId = id;
            _submissionFailure = null;
            await RefreshAsync();
        };
        var device = Ui.Stack(4, picker);
        if (Target is { ConnectionSummary: { } summary } target2)
        {
            var caption = Ui.Text("trace.target.deviceSummary", summary, "ArkDeckCaptionStyle");
            AutomationProperties.SetName(caption, target2.AccessibleConnectionSummary ?? summary);
            ToolTipService.SetToolTip(caption, target2.AccessibleConnectionSummary);
            device.Children.Add(caption);
        }
        return device;
    }

    private UIElement Profile()
    {
        var detail = Ui.Text("trace.profile.detail", S.Text($"trace.preset.{_presetId}.detail"), "ArkDeckCaptionStyle");
        var picker = new ComboBox { Header = S.Text(UiStrings.TraceCaptureProfile), MinWidth = 220, MaxWidth = 320 };
        AutomationProperties.SetAutomationId(picker, "trace.profile.picker");
        AutomationProperties.SetName(picker, S.Text(UiStrings.TraceCaptureProfile));
        foreach (var preset in TraceOperations.Presets)
        {
            var item = new ComboBoxItem { Content = S.Text($"trace.preset.{preset.Id}"), Tag = preset.Id };
            AutomationProperties.SetAutomationId(item, "trace.profile." + preset.Id);
            picker.Items.Add(item);
            if (preset.Id == _presetId) picker.SelectedItem = item;
        }
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedItem is not ComboBoxItem { Tag: string id } || id == _presetId) return;
            _presetId = id;
            _submissionFailure = null;
            Ui.SetText(detail, S.Text($"trace.preset.{id}.detail"));
            RenderFooter();
        };
        return Ui.Stack(4, picker, detail);
    }

    private UIElement DurationSection(TraceState state)
    {
        var range = state.DurationRange;
        var input = new TextBox { Header = S.Text(UiStrings.TraceBoundsDuration), Text = _durationText, Width = 120, TextAlignment = TextAlignment.Right, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(input, "trace.duration.input");
        AutomationProperties.SetName(input, S.Text(UiStrings.TraceBoundsDuration));
        _validation = Ui.Text("trace.duration.validation", "", "ArkDeckCaptionStyle");
        _validation.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
        var quick = new StackPanel { Spacing = 4 };
        input.TextChanged += (_, _) =>
        {
            _durationText = input.Text;
            _submissionFailure = null;
            UpdateDuration(quick);
        };

        var units = new[] { TraceDurationUnit.Seconds, TraceDurationUnit.Minutes }.Where(u => TraceDuration.InputRange(u, range) is not null).ToArray();
        var unit = new ComboBox { Header = S.Text(UiStrings.TraceDurationUnit), MinWidth = 140 };
        AutomationProperties.SetAutomationId(unit, "trace.duration.unit");
        AutomationProperties.SetName(unit, S.Text(UiStrings.TraceDurationUnit));
        foreach (var u in units)
        {
            var item = new ComboBoxItem { Content = S.Text(u == TraceDurationUnit.Seconds ? UiStrings.TraceDurationSeconds : UiStrings.TraceDurationMinutes), Tag = u };
            AutomationProperties.SetAutomationId(item, "trace.duration.unit." + (u == TraceDurationUnit.Seconds ? "seconds" : "minutes"));
            unit.Items.Add(item);
            if (u == _unit) unit.SelectedItem = item;
        }
        unit.SelectionChanged += (_, _) =>
        {
            if (unit.SelectedItem is not ComboBoxItem { Tag: TraceDurationUnit next } || next == _unit) return;
            var seconds = Duration.Seconds ?? (int)Math.Min(range.Maximum, Math.Max(range.Minimum, 10));
            if (TraceDuration.InputValue(next, seconds, range) is not { } value) return;
            _unit = next;
            _durationText = value.ToString(System.Globalization.CultureInfo.InvariantCulture);
            input.Text = _durationText;
            UpdateDuration(quick);
        };
        UpdateDuration(quick);
        return Ui.Stack(6, Ui.Row(input, unit), _validation, quick);

        void UpdateDuration(StackPanel host)
        {
            host.Children.Clear();
            host.Children.Add(Ui.Text("trace.duration.quick.caption", S.Text(UiStrings.TraceDurationQuick), "ArkDeckCaptionStyle"));
            // Only the durations the Catalog allows are offered (an unavailable one is not shown disabled).
            var buttons = new List<UIElement>();
            foreach (var value in TraceDuration.QuickValues(_unit).Where(v => TraceDuration.DurationSeconds(_unit, v, range) is not null))
            {
                var text = value.ToString(System.Globalization.CultureInfo.InvariantCulture);
                var toggle = new ToggleButton
                {
                    Content = _unit == TraceDurationUnit.Seconds ? $"{value}s" : $"{value} min",
                    IsChecked = _durationText == text,
                };
                var name = S.Text(QuickName(_unit, value));
                AutomationProperties.SetAutomationId(toggle, $"trace.duration.quick.{(_unit == TraceDurationUnit.Seconds ? "seconds" : "minutes")}.{value}");
                AutomationProperties.SetName(toggle, name);
                ToolTipService.SetToolTip(toggle, name);
                toggle.Click += (_, _) =>
                {
                    input.Text = text;
                    toggle.IsChecked = true;
                };
                buttons.Add(toggle);
            }
            var row = Ui.Row([.. buttons]);
            AutomationProperties.SetAutomationId(row, "trace.duration.quick");
            host.Children.Add(row);
            var validation = Duration;
            Ui.SetText(_validation, validation.Failure switch
            {
                TraceDurationFailure.Missing => S.Text(UiStrings.TraceValidationMissing),
                TraceDurationFailure.NotDecimal => S.Text(UiStrings.TraceValidationDecimal),
                TraceDurationFailure.OutsideRange => S.Format(UiStrings.TraceValidationRange, validation.InputRange.Minimum, validation.InputRange.Maximum),
                _ => "",
            });
            _validation.Visibility = validation.IsValid ? Visibility.Collapsed : Visibility.Visible;
            RenderFooter();
        }
    }

    private static string QuickName(TraceDurationUnit unit, int value) => (unit, value) switch
    {
        (TraceDurationUnit.Seconds, 5) => UiStrings.TraceDurationSet5Seconds,
        (TraceDurationUnit.Seconds, 10) => UiStrings.TraceDurationSet10Seconds,
        (TraceDurationUnit.Seconds, 15) => UiStrings.TraceDurationSet15Seconds,
        (TraceDurationUnit.Seconds, 30) => UiStrings.TraceDurationSet30Seconds,
        (TraceDurationUnit.Minutes, 1) => UiStrings.TraceDurationSet1Minute,
        (TraceDurationUnit.Minutes, 2) => UiStrings.TraceDurationSet2Minutes,
        (TraceDurationUnit.Minutes, 3) => UiStrings.TraceDurationSet3Minutes,
        _ => UiStrings.TraceDurationSetCustom,
    };

    private string BlockerText(TraceBlocker blocker) => blocker.Key is { } key ? S.Text(key) : blocker.Text ?? "";

    private void RenderFooter()
    {
        if (_state is null) return;
        _footer.Children.Clear();
        var blockers = Blockers;
        var details = blockers.Select(BlockerText).ToList();
        if (_state.Probe?.Unavailable is { } probeFailure) details.Add(probeFailure.ReasonText(S));
        TextBlock status;
        if (_submitting && _activeJobId is null)
        {
            status = Ui.Text("trace.capture.status", S.Text(UiStrings.TraceActionRunning));
        }
        else if (_activeJobId is not null)
        {
            status = Ui.Text("trace.capture.status", S.Text(UiStrings.TraceActionRunning));
        }
        else if (_submissionFailure is { } failure)
        {
            status = Ui.Text("trace.submission.failure", failure);
            status.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
        }
        else if (_terminal is { OutcomeUnknown: true })
        {
            status = Ui.Text("trace.capture.status", S.Text(UiStrings.TraceCaptureOutcomeUnknown));
        }
        else if (_terminal is { State: "succeeded" })
        {
            status = Ui.Text("trace.capture.status", S.Text(UiStrings.TraceCaptureFinished));
        }
        else if (_terminal is not null)
        {
            status = Ui.Text("trace.capture.status", S.Text(UiStrings.TraceCaptureNotCompleted));
        }
        else if (blockers.Count > 0)
        {
            status = Ui.Text("trace.capture.status", BlockerText(blockers[0]));
            ToolTipService.SetToolTip(status, string.Join(Environment.NewLine, details));
            AutomationProperties.SetFullDescription(status, string.Join(Environment.NewLine, details.Skip(1)));
        }
        else
        {
            status = Ui.Text("trace.capture.status", S.Text(UiStrings.WindowsTraceCaptureLocalOnly));
        }
        _footer.Children.Add(status);
        if (_activeJobId is { } jobId)
        {
            _footer.Children.Add(Ui.Row(
                Ui.Text("trace.capture.jobId", jobId, "ArkDeckMonoStyle"),
                Ui.Button("trace.cancel", S.Text(UiStrings.TraceActionCancel), async (_, _) => await CancelAsync())));
        }
        else if (!_submitting)
        {
            var start = Ui.Button("trace.start", S.Text(UiStrings.TraceActionStart), async (_, _) => await StartAsync(), accent: true);
            if (details.Count > 0)
            {
                ToolTipService.SetToolTip(start, string.Join(Environment.NewLine, details));
                AutomationProperties.SetHelpText(start, details[0]);
            }
            _footer.Children.Add(Ui.Row(start));
        }
    }

    private async Task StartAsync()
    {
        if (_submitting || _state is null) return;
        var blockers = Blockers;
        if (blockers.Count > 0 || Target is not { } target || Duration.Seconds is not { } seconds || _state.CaptureBufferKB is not { } buffer)
        {
            _submissionFailure = blockers.Count > 0 ? BlockerText(blockers[0]) : S.Text(UiStrings.TraceBlockerCapability);
            RenderFooter();
            Ui.Say(_status, _submissionFailure);
            return;
        }
        _submitting = true;
        _activeJobId = null;
        _terminal = null;
        _submissionFailure = null;
        _viewerFailureKey = null;
        _viewerFailure = null;
        RenderFooter();
        Ui.Say(_status, S.Text(UiStrings.TraceActionRunning));
        try
        {
            var tags = Preset.Tags;
            var submitted = await Task.Run(() => App.Loader.SubmitTraceAsync(target.Target, seconds, tags, buffer));
            MainWindow.Instance.Report(submitted);
            if (submitted.JobId is not { } jobId)
            {
                _submissionFailure = submitted.Failure?.ReasonText(S) ?? S.Text(UiStrings.TraceBlockerOperation);
                return;
            }
            _activeJobId = jobId;
            RenderFooter();
            var ran = await Task.Run(() => App.Loader.RunJobAsync(jobId, CliCommands.TraceCapture));
            MainWindow.Instance.Report(ran);
            _activeJobId = null;
            if (ran.Answer.Value is not { } terminal)
            {
                _submissionFailure = ran.Answer.Unavailable?.ReasonText(S);
                return;
            }
            _terminal = terminal;
            if (terminal is { State: "succeeded", OutcomeUnknown: false }) await OpenCapturedAsync(terminal.JobId, open: true);
        }
        finally
        {
            _submitting = false;
            _activeJobId = null;
            RenderFooter();
            Ui.Say(_status, _submissionFailure ?? (_terminal is { } t ? S.Text(t.OutcomeUnknown ? UiStrings.TraceCaptureOutcomeUnknown
                : t.State == "succeeded" ? UiStrings.TraceCaptureFinished : UiStrings.TraceCaptureNotCompleted) : ""));
        }
    }

    private async Task CancelAsync()
    {
        if (_activeJobId is not { } jobId || _cancelling) return;
        _cancelling = true;
        try
        {
            var answer = await Task.Run(() => App.Loader.CancelJobAsync(jobId));
            MainWindow.Instance.Report(answer);
            if (answer.Answer.Value is not { Requested: true })
            {
                _submissionFailure = S.Text(UiStrings.TraceCancelFailed);
                Ui.Say(_status, _submissionFailure);
            }
        }
        finally
        {
            _cancelling = false;
        }
    }

    // ---- viewing the captured Trace ----

    private void RenderViewer()
    {
        _viewer.Children.Clear();
        _viewer.Children.Add(Ui.Heading("trace.viewer.title", S.Text(UiStrings.TraceViewerTitle), AutomationHeadingLevel.Level2));
        if (_preparingViewer)
        {
            _viewer.Children.Add(Ui.Row(Ui.Progress("trace.viewer.preparing.ring", S.Text(UiStrings.TraceViewerPreparing)),
                Ui.Text("trace.viewer.preparing", S.Text(UiStrings.TraceViewerPreparing))));
        }
        else if (_viewerFailureKey is { } key)
        {
            var failure = Ui.Text("trace.viewer.failure", S.Text(key));
            failure.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
            _viewer.Children.Add(failure);
            if (_viewerFailure is { } why) _viewer.Children.Add(Ui.Text("trace.viewer.failure.reason", why.ReasonText(S), "ArkDeckMonoStyle"));
            if (_terminal is { State: "succeeded", OutcomeUnknown: false } done)
            {
                _viewer.Children.Add(Ui.Row(Ui.Button("trace.viewer.tryAgain", S.Text(UiStrings.TraceViewerTryAgain), async (_, _) => await OpenCapturedAsync(done.JobId, open: true))));
            }
        }
        else if (_latest is { } latest)
        {
            _viewer.Children.Add(Ui.Text("trace.viewer.latest", S.Text(UiStrings.TraceViewerLatest)));
            var name = Ui.Text("trace.viewer.latest.name", latest.Name, "ArkDeckMonoStyle");
            name.IsTextSelectionEnabled = true;
            _viewer.Children.Add(name);
        }
        else
        {
            _viewer.Children.Add(Ui.Text("trace.viewer.empty", S.Text(UiStrings.TraceViewerDescription), "ArkDeckCaptionStyle"));
        }
        _viewer.Children.Add(Ui.Row(Ui.Button("trace.openViewer", S.Text(UiStrings.TraceActionOpenViewer), (_, _) => MainWindow.Instance.OpenTraceViewer(_latest))));
    }

    private async Task OpenCapturedAsync(string jobId, bool open)
    {
        _preparingViewer = true;
        _viewerFailureKey = null;
        _viewerFailure = null;
        RenderViewer();
        Ui.Say(_status, S.Text(UiStrings.TraceViewerPreparing));
        try
        {
            var root = TraceInbox.Root(App.Options.CacheRoot);
            var outcome = await Task.Run(() => App.Loader.OpenCapturedTraceAsync(jobId, root));
            MainWindow.Instance.Report(outcome);
            if (outcome.Document is { } document)
            {
                _latest = document;
                if (open) MainWindow.Instance.OpenTraceViewer(document);
            }
            else
            {
                _viewerFailureKey = outcome.FailureKey;
                _viewerFailure = outcome.Reason;
                Ui.Say(_status, S.Text(outcome.FailureKey ?? UiStrings.TraceViewerReadFailed));
            }
        }
        finally
        {
            _preparingViewer = false;
            RenderViewer();
        }
    }
}
