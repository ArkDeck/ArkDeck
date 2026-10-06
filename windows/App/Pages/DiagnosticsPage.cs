using System.Globalization;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace ArkDeck.App.Pages;

/// <summary>
/// Diagnostics (macOS <c>DiagnosticsWorkspaceView</c>), the session reader: what a saved
/// <c>capture.diagnostics@1</c> session can and cannot prove — the alignment state, every mark
/// with its picture or which of the reasons it has none, what nothing looked for, the products
/// that went missing, its Artifacts with a local text preview — or a verified HiLog summary.
/// A record is opened from History (Open Diagnostics); reading it starts no Job. Live controls
/// name only the one Job this App accepted; History remains an immutable read-only view.
/// </summary>
public sealed partial class DiagnosticsPage() : SurfacePage<DiagnosticsState>(
    "diagnostics", "diagnostics.title", UiStrings.AppNavigationDiagnostics,
    "diagnostics.session.reload", UiStrings.DiagnosticsSessionReload, "diagnostics.session.loading", UiStrings.DiagnosticsSessionLoading), IHistoryContextPage
{
    private DiagnosticJobContext? _context;
    private DiagnosticsState? _state;
    private TextBlock _status = Ui.Status("diagnostics.status");
    private readonly TextBlock _captureState = Ui.Status("diagnostics.capture.state");
    private Panel? _captureStateOwner;
    private string? _announcedCaptureState;
    private readonly StackPanel _preview = new() { Spacing = 6 };
    private DiagnosticReaderSelection? _selection;
    private bool _previewLoading;
    private static DiagnosticCaptureSession? _sharedCapture;
    private readonly DiagnosticCaptureSession _capture = _sharedCapture ??= new(new DiagnosticCaptureProvider(App.Loader));
    private DiagnosticCaptureTarget? _captureTarget;
    private int _captureDuration = 60;
    private bool _subscribed;
    private bool _eventsHooked;
    private string? _completedJobOpened;

    private HistoryWorkspaceContext? _history;

    /// <summary>Opens a History record (macOS <c>openHistoryContext</c>); the next refresh reads it.</summary>
    public void OpenHistoryContext(HistoryWorkspaceContext context)
    {
        _history = context;
        _context = context.Diagnostics;
        _selection = null;
        _preview.Children.Clear();
    }

    protected override async Task<DiagnosticsState> LoadAsync()
    {
        var state = await App.Loader.DiagnosticsAsync(_context);
        if (_history is null)
        {
            var observations = await App.Loader.DeviceCandidatesAsync();
            _captureTarget = observations.Value is { } candidates ? DiagnosticCaptureTarget.From(candidates) : null;
            _capture.SelectionChanged(_captureTarget);
        }
        return state;
    }

    protected override void Render(DiagnosticsState state, StackPanel body)
    {
        _state = state;
        var said = _status.Text;
        _status = Ui.Status("diagnostics.status");
        Ui.SetText(_status, said);
        var reading = state.Session?.Presentation?.Reading;
        if (reading is not null && _selection is null) _selection = new DiagnosticReaderSelection(reading.Marks.FirstOrDefault()?.AtHostUtc ?? "");
        if (reading is null) _selection = null;

        if (_history is { } history)
        {
            body.Children.Add(HistoryContextBanner.Create(history, async () =>
            {
                _history = null;
                _context = null;
                _selection = null;
                _preview.Children.Clear();
                await RefreshAsync();
            }));
        }
        body.Children.Add(Toolbar(state, reading));
        if (!state.IsHilogSummaryContext && _history is null) body.Children.Add(Ui.Card(CapturePane(), "diagnostics.capture"));

        if (state.LoadError is { } reason)
        {
            body.Children.Add(Ui.Card(Failed(state, reason), "diagnostics.session.failed"));
        }
        else if (state.Hilog?.Presentation is { } summary)
        {
            body.Children.Add(Ui.Card(HilogSummary(summary), "diagnostics.hilog.summary"));
        }
        else if (state.Session?.Presentation is not { } session)
        {
            body.Children.Add(Ui.Card(Ui.Stack(4,
                Ui.Heading("diagnostics.session.empty", S.Text(UiStrings.DiagnosticsSessionNone), AutomationHeadingLevel.Level2),
                Ui.Text("diagnostics.session.empty.detail", S.Text(UiStrings.DiagnosticsSessionNoneDetail), "ArkDeckCaptionStyle"))));
        }
        else
        {
            if (session.Reading.IsPartial)
            {
                body.Children.Add(Ui.Card(Ui.Stack(4,
                    Ui.Text("diagnostics.partial", S.Text(UiStrings.DiagnosticsPartial), "ArkDeckSectionTitleStyle"),
                    Ui.Text("diagnostics.partial.detail", S.Text(UiStrings.DiagnosticsPartialDetail), "ArkDeckCaptionStyle"))));
            }
            body.Children.Add(Ui.Card(SessionSection(session), "diagnostics.session"));
            body.Children.Add(Ui.Card(Marks(session.Reading), "diagnostics.marks"));
            if (session.Reading.NotDerived.Count > 0)
            {
                body.Children.Add(Ui.Card(Ui.Stack(4,
                    Ui.Text("diagnostics.notDerived.title", S.Text(UiStrings.DiagnosticsNotDerivedTitle), "ArkDeckSectionTitleStyle"),
                    Ui.Text("diagnostics.notDerived.detail", S.Text(UiStrings.DiagnosticsNotDerivedDetail), "ArkDeckCaptionStyle"),
                    Ui.Text("diagnostics.notDerived", string.Join(" · ", session.Reading.NotDerived), "ArkDeckMonoStyle"))));
            }
            if (session.Reading.MissingProducts.Count > 0)
            {
                var missing = Ui.Stack(4, Ui.Text("diagnostics.missing.title", S.Text(UiStrings.DiagnosticsMissingTitle), "ArkDeckSectionTitleStyle"));
                foreach (var product in session.Reading.MissingProducts)
                {
                    missing.Children.Add(Ui.Row(
                        Ui.Text("diagnostics.missing." + product.Name, product.Name, "ArkDeckMonoStyle"),
                        Ui.Text("diagnostics.missing." + product.Name + ".reason", product.Reason, "ArkDeckCaptionStyle")));
                }
                body.Children.Add(Ui.Card(missing, "diagnostics.missing"));
            }
            body.Children.Add(Ui.Card(Artifacts(session), "diagnostics.artifacts"));
            body.Children.Add(_preview);
        }
        if (!state.IsHilogSummaryContext) body.Children.Add(Footer(reading));
        body.Children.Add(_status);
    }

    // ---- the toolbar: the HiLog title or the alignment state ----

    private UIElement Toolbar(DiagnosticsState state, DiagnosticSessionReading? reading)
    {
        if (state.IsHilogSummaryContext)
        {
            return Ui.Heading("diagnostics.workspace.title", S.Text(UiStrings.DiagnosticsHilogTitle), AutomationHeadingLevel.Level2);
        }
        // The alignment state decides whether anything below can be lined up with what the
        // device recorded, so it leads the page.
        var (title, refusal) = reading?.Alignment switch
        {
            DiagnosticAlignment.SameClock => (S.Text(UiStrings.DiagnosticsAlignmentSameClock), false),
            DiagnosticAlignment.Calibrated c => ($"{S.Text(UiStrings.DiagnosticsAlignmentCalibrated)} ±{c.ToleranceMs.ToString(CultureInfo.InvariantCulture)} ms", false),
            _ => (S.Text(UiStrings.DiagnosticsAlignmentCannotAlign), true),
        };
        return Ui.Text("diagnostics.alignment", title, refusal ? "ArkDeckSectionTitleStyle" : "ArkDeckCaptionStyle");
    }

    // ---- live capture: one accepted Runtime owner, retained across navigation ----

    private StackPanel CapturePane()
    {
        SubscribeCapture();
        async Task Action(Func<Task> action)
        {
            await Task.Run(action);
            if (_capture.Failure is { } failure) Ui.Say(_status, failure);
            Rerender();
        }
        var arm = Ui.Button("diagnostics.capture.arm", S.Text(UiStrings.DiagnosticsCaptureArm), async (_, _) =>
        {
            if (!_capture.CanStart) { Ui.Say(_status, S.Text(UiStrings.DiagnosticsCaptureUncertain)); return; }
            if (_captureTarget is not { } target) { Ui.Say(_status, S.Text(UiStrings.DiagnosticsCaptureChooseTarget)); return; }
            _context = null;
            _selection = null;
            _preview.Children.Clear();
            await RefreshAsync();
            await Action(() => _capture.StartAsync(target, _captureDuration));
        });
        var duration = new ComboBox { Header = S.Text(UiStrings.DiagnosticsCaptureDuration), MinWidth = 180 };
        AutomationProperties.SetAutomationId(duration, "diagnostics.capture.duration");
        AutomationProperties.SetName(duration, S.Text(UiStrings.DiagnosticsCaptureDuration));
        foreach (var seconds in new[] { 30, 60, 120 })
        {
            var item = new ComboBoxItem { Content = $"{seconds} s", Tag = seconds };
            duration.Items.Add(item);
            if (seconds == _captureDuration) duration.SelectedItem = item;
        }
        duration.SelectionChanged += (_, _) =>
        {
            if (_capture.CanStart && duration.SelectedItem is ComboBoxItem { Tag: int seconds }) _captureDuration = seconds;
            else if (duration.SelectedItem is ComboBoxItem { Tag: int attempted } && attempted != _captureDuration) Rerender();
        };
        var mark = Ui.Button("diagnostics.capture.mark", S.Text(UiStrings.WindowsDiagnosticsCaptureMark), async (_, _) => await Action(_capture.MarkAsync));
        mark.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.M, Modifiers = VirtualKeyModifiers.Control });
        var stop = Ui.Button("diagnostics.capture.stop", S.Text(UiStrings.DiagnosticsCaptureStop), async (_, _) => await Action(_capture.StopAsync));
        var actions = Ui.Row(mark, stop);
        if (_capture.CanCancelPreparation) actions.Children.Add(Ui.Button("diagnostics.capture.cancelPreparation", S.Text(UiStrings.DiagnosticsCaptureCancelPreparation), async (_, _) => await Action(_capture.CancelPreparationAsync)));
        if (_capture.JobId is not null) actions.Children.Add(Ui.Button("diagnostics.capture.refresh", S.Text(UiStrings.DiagnosticsCaptureRefresh), async (_, _) => await Action(() => _capture.RefreshAsync())));
        var panel = Ui.Stack(8, Ui.Row(arm, duration), actions);
        var targetShown = _capture.CanStart ? _captureTarget : _capture.Target;
        panel.Children.Add(Ui.Text("diagnostics.capture.target", targetShown?.Title ?? S.Text(UiStrings.DiagnosticsCaptureChooseTarget), "ArkDeckCaptionStyle"));
        if (_capture.JobId is { } jobId) panel.Children.Add(Ui.Text("diagnostics.capture.job", jobId, "ArkDeckMonoStyle"));
        if (_capture.Snapshot is { } snapshot)
        {
            var row = new FlowPanel();
            AddCaptureState(row, _capture.Phase == DiagnosticCapturePhase.Uncertain
                ? S.Text("diagnostics.capture.phase.uncertain") : S.Text("diagnostics.capture.state." + snapshot.State));
            row.Children.Add(Ui.Text("diagnostics.capture.elapsed", $"{snapshot.ElapsedMs / 1000} / {snapshot.MaximumSeconds} s", "ArkDeckMonoStyle"));
            row.Children.Add(Ui.Text("diagnostics.capture.markCount", $"{S.Text(UiStrings.DiagnosticsCaptureMarks)}: {snapshot.Markers.Count} / {snapshot.MaximumMarkers}", "ArkDeckCaptionStyle"));
            panel.Children.Add(row);
        }
        else if (_capture.Phase != DiagnosticCapturePhase.Idle) AddCaptureState(panel, S.Text("diagnostics.capture.phase." + _capture.Phase.ToString().ToLowerInvariant()));
        if (_capture.Phase == DiagnosticCapturePhase.Uncertain) panel.Children.Add(Ui.Text("diagnostics.capture.uncertain", S.Text(UiStrings.DiagnosticsCaptureUncertain), "ArkDeckCaptionStyle"));
        if (_capture.Failure is { } reason) panel.Children.Add(Ui.Text("diagnostics.capture.reasonCode", reason, "ArkDeckMonoStyle"));
        panel.Children.Add(Ui.Text("diagnostics.capture.boundary", S.Text(UiStrings.DiagnosticsCaptureBoundary), "ArkDeckCaptionStyle"));
        return panel;
    }

    private void AddCaptureState(Panel destination, string text)
    {
        // Parent can be null after the whole body is detached; retain the actual collection.
        _captureStateOwner?.Children.Remove(_captureState);
        Ui.SetText(_captureState, text);
        destination.Children.Add(_captureState);
        _captureStateOwner = destination;
    }

    private void SubscribeCapture()
    {
        if (!_subscribed) { _capture.Changed += CaptureChanged; _subscribed = true; }
        if (_eventsHooked) return;
        _eventsHooked = true;
        Unloaded += (_, _) => { _capture.Changed -= CaptureChanged; _subscribed = false; };
        Loaded += (_, _) => { if (_history is null) { SubscribeCapture(); CaptureChanged(); } };
    }

    private void CaptureChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        // A live controller can finish in the background, but cannot replace a historical view.
        if (_history is not null) return;
        Rerender();
        var announcement = (_capture.JobId ?? "") + ":" + _captureState.Text;
        if (_capture.Phase != DiagnosticCapturePhase.Idle && _captureStateOwner is not null && _announcedCaptureState != announcement)
        {
            _announcedCaptureState = announcement;
            Ui.Say(_captureState, _captureState.Text);
        }
        if (_capture.CompletedContext is { } context && _completedJobOpened != context.JobId)
        {
            _completedJobOpened = context.JobId;
            _context = context.Diagnostics;
            _selection = null;
            _preview.Children.Clear();
            _ = RefreshAsync();
        }
    });

    // ---- a record that could not be read ----

    private StackPanel Failed(DiagnosticsState state, string reason)
    {
        var panel = Ui.Stack(6, Ui.Heading("diagnostics.session.failed.title",
            S.Text(state.IsHilogSummaryContext ? UiStrings.DiagnosticsHilogFailed : UiStrings.DiagnosticsSessionFailed), AutomationHeadingLevel.Level2));
        if (state.IsHilogSummaryContext) panel.Children.Add(Ui.Text("diagnostics.hilog.failed.detail", S.Text(UiStrings.DiagnosticsHilogFailedDetail), "ArkDeckCaptionStyle"));
        var why = Ui.Text("diagnostics.session.failed.reason", reason, "ArkDeckMonoStyle");
        why.IsTextSelectionEnabled = true;
        panel.Children.Add(why);
        panel.Children.Add(Ui.Row(Ui.Button("diagnostics.session.retry", S.Text(UiStrings.DiagnosticsSessionRetry), async (_, _) => await RefreshAsync())));
        return panel;
    }

    // ---- the HiLog summary ----

    private StackPanel HilogSummary(DiagnosticHilogSummaryPresentation summary)
    {
        var panel = Ui.Stack(8,
            Ui.Text("diagnostics.hilog.job", summary.JobId, "ArkDeckMonoStyle"),
            Ui.Text("diagnostics.hilog.readOnly", S.Text(UiStrings.DiagnosticsHilogReadOnly), "ArkDeckCaptionStyle"),
            Ui.Text("diagnostics.hilog.coverage", S.Text("diagnostics.hilog.coverage." + summary.HeaderCoverage), "ArkDeckSectionTitleStyle"),
            Ui.Text("diagnostics.hilog.boundary", S.Text(UiStrings.DiagnosticsHilogCoverageDetail), "ArkDeckCaptionStyle"));
        string Count(long value) => value.ToString(CultureInfo.InvariantCulture);
        panel.Children.Add(Ui.Fact("diagnostics.hilog.count.lines", S.Text(UiStrings.DiagnosticsHilogLines), Count(summary.LineCount)));
        foreach (var level in new[] { "D", "I", "W", "E", "F" })
        {
            panel.Children.Add(Ui.Fact("diagnostics.hilog.count." + level, S.Text("diagnostics.hilog.level." + level),
                Count(summary.LevelCounts.TryGetValue(level, out var n) ? n : 0)));
        }
        panel.Children.Add(Ui.Fact("diagnostics.hilog.count.unrecognized", S.Text(UiStrings.DiagnosticsHilogUnrecognized), Count(summary.UnrecognizedLineCount)));
        panel.Children.Add(Ui.Fact("diagnostics.hilog.count.blank", S.Text(UiStrings.DiagnosticsHilogBlank), Count(summary.BlankLineCount)));
        panel.Children.Add(Ui.Heading("diagnostics.hilog.source.title", S.Text(UiStrings.DiagnosticsHilogSource), AutomationHeadingLevel.Level3));
        panel.Children.Add(Ui.Text("diagnostics.hilog.source.detail", S.Text(UiStrings.DiagnosticsHilogSourceDetail), "ArkDeckCaptionStyle"));
        panel.Children.Add(Ui.Fact("diagnostics.hilog.sourceJob", S.Text(UiStrings.DiagnosticsHilogSourceJob), summary.SourceJobId));
        panel.Children.Add(Ui.Fact("diagnostics.hilog.sourceArtifact", S.Text(UiStrings.DiagnosticsHilogSourceArtifact), summary.SourceArtifactId));
        panel.Children.Add(Ui.Fact("diagnostics.hilog.sourceBytes", S.Text(UiStrings.DiagnosticsHilogSourceBytes), Count(summary.SourceByteCount)));
        panel.Children.Add(Disclosure("diagnostics.hilog.digests", S.Text(UiStrings.DiagnosticsHilogDigests), Ui.Stack(6,
            Ui.Fact("diagnostics.hilog.sourceDigest", S.Text(UiStrings.DiagnosticsHilogSourceDigest), summary.SourceSha256),
            Ui.Fact("diagnostics.hilog.toolDigest", S.Text(UiStrings.DiagnosticsHilogToolDigest), summary.AnalyzerExecutableSha256),
            Ui.Fact("diagnostics.hilog.outputDigest", S.Text(UiStrings.DiagnosticsHilogOutputDigest), summary.AnalyzerOutputSha256),
            Ui.Fact("diagnostics.hilog.artifactDigest", S.Text(UiStrings.DiagnosticsHilogArtifactDigest), summary.Artifact.Sha256))));
        return panel;
    }

    private readonly HashSet<string> _open = new(StringComparer.Ordinal);

    /// <summary>A macOS DisclosureGroup as a button that shows and hides its content (an Expander
    /// does not expose its content to UI Automation by identifier); it stays open across re-reads.</summary>
    private StackPanel Disclosure(string id, string header, FrameworkElement content)
    {
        content.Visibility = _open.Contains(id) ? Visibility.Visible : Visibility.Collapsed;
        var toggle = Ui.Button(id, header, (_, _) =>
        {
            if (!_open.Remove(id)) _open.Add(id);
            content.Visibility = _open.Contains(id) ? Visibility.Visible : Visibility.Collapsed;
        });
        return Ui.Stack(6, Ui.Row(toggle), content);
    }

    // ---- the session ----

    private StackPanel SessionSection(DiagnosticSessionPresentation session)
    {
        var job = Ui.Text("diagnostics.session.job", session.Reading.JobId, "ArkDeckMonoStyle");
        job.IsTextSelectionEnabled = true;
        var panel = Ui.Stack(6, job, Ui.Text("diagnostics.session.readOnly", S.Text(UiStrings.DiagnosticsSessionReadOnly), "ArkDeckCaptionStyle"));
        if (session.RingHeldAnchor is { } covered)
        {
            panel.Children.Add(Ui.Text("diagnostics.ring", S.Text(covered ? UiStrings.DiagnosticsRingCovered : UiStrings.DiagnosticsRingLost), "ArkDeckCaptionStyle"));
        }
        var timeline = Ui.Text("diagnostics.session.timeline.text", string.Join("\n", session.Timeline), "ArkDeckMonoStyle");
        timeline.IsTextSelectionEnabled = true;
        panel.Children.Add(Disclosure("diagnostics.session.timeline", S.Text(UiStrings.DiagnosticsSessionTimeline), timeline));
        return panel;
    }

    private StackPanel Marks(DiagnosticSessionReading reading)
    {
        var panel = Ui.Stack(8, Ui.Heading("diagnostics.marks.title", S.Text(UiStrings.DiagnosticsMarksTitle), AutomationHeadingLevel.Level2));
        if (reading.Marks.Count == 0)
        {
            panel.Children.Add(Ui.Text("diagnostics.marks.empty", S.Text(UiStrings.DiagnosticsMarksEmpty), "ArkDeckCaptionStyle"));
            return panel;
        }
        foreach (var mark in reading.Marks) panel.Children.Add(Mark(mark));
        return panel;
    }

    /// <summary>One mark. A mark a person made and one the Runtime derived differ by their word
    /// (Marked, Found), not by colour; a mark without a usable picture says which reason applies.</summary>
    private Border Mark(DiagnosticMark mark)
    {
        var ordinal = mark.Ordinal.ToString(CultureInfo.InvariantCulture);
        var kind = S.Text(mark.IsAutomatic ? UiStrings.DiagnosticsMarkAuto : UiStrings.DiagnosticsMarkManual);
        var title = mark.Label is { } label ? $"{kind} {ordinal} · {label}" : mark.Trigger is { } trigger ? $"{kind} {ordinal} · {trigger}" : $"{kind} {ordinal}";
        var panel = Ui.Stack(4, Ui.Row(
            Ui.Text($"diagnostics.mark.{ordinal}.title", title, "ArkDeckSectionTitleStyle"),
            Ui.Text($"diagnostics.mark.time.{ordinal}", mark.AtHostUtc.Length == 0 ? S.Text(UiStrings.DiagnosticsMarkTimeMissing) : mark.AtHostUtc, "ArkDeckMonoStyle")));
        if (mark.Screenshot is { } shot)
        {
            // The offset is part of the reading: a picture taken 120 ms after a mark is a picture
            // of 120 ms after the mark.
            panel.Children.Add(Ui.Text($"diagnostics.mark.{ordinal}.screenshot",
                $"+{shot.TakenAfterMarkMs.ToString(CultureInfo.InvariantCulture)} ms {S.Text(UiStrings.DiagnosticsShotTakenAfter)}", "ArkDeckCaptionStyle"));
            panel.Children.Add(Ui.Text($"diagnostics.mark.{ordinal}.standsFor", S.Text(UiStrings.DiagnosticsShotStandsFor), "ArkDeckCaptionStyle"));
        }
        else if (mark.ScreenshotAbsence is { } absence)
        {
            var (absenceTitle, detail) = absence switch
            {
                DiagnosticScreenshotAbsence.TakenTooFarFromTheMark far => (S.Text(UiStrings.DiagnosticsShotTooFar),
                    $"{S.Text(UiStrings.DiagnosticsShotTooFarDetail)} (+{far.OffsetMs.ToString(CultureInfo.InvariantCulture)} ms)"),
                DiagnosticScreenshotAbsence.ShutterWindowWiderThanTheRule wide => (S.Text(UiStrings.DiagnosticsShotUndecidable),
                    $"{S.Text(UiStrings.DiagnosticsShotUndecidableDetail)} ({wide.WindowMs.ToString(CultureInfo.InvariantCulture)} ms > {DiagnosticSessionReading.ScreenshotAppliesWithinMs.ToString(CultureInfo.InvariantCulture)} ms)"),
                DiagnosticScreenshotAbsence.CaptureFailed failed => (S.Text(UiStrings.DiagnosticsShotFailed), failed.Reason),
                _ => (S.Text(UiStrings.DiagnosticsShotNone), (string?)null),
            };
            panel.Children.Add(Ui.Text($"diagnostics.mark.{ordinal}.noScreenshot", absenceTitle, "ArkDeckCaptionStyle"));
            if (detail is not null) panel.Children.Add(Ui.Text($"diagnostics.mark.{ordinal}.noScreenshot.detail", detail, "ArkDeckCaptionStyle"));
        }
        return Ui.Card(panel, "diagnostics.mark." + ordinal);
    }

    // ---- Artifacts and the local preview ----

    private StackPanel Artifacts(DiagnosticSessionPresentation session)
    {
        var panel = Ui.Stack(8,
            Ui.Heading("diagnostics.artifacts.title", S.Text(UiStrings.DiagnosticsArtifactsTitle), AutomationHeadingLevel.Level2),
            Ui.Text("diagnostics.artifacts.privacy", S.Text(UiStrings.DiagnosticsArtifactsPrivacy), "ArkDeckCaptionStyle"));
        if (session.Artifacts.Count(IsRawTrace) == 1 && _context is { } context)
        {
            var open = Ui.Button("diagnostics.artifacts.openTrace", S.Text(UiStrings.DiagnosticsArtifactsOpenTrace), async (_, _) => await OpenTraceAsync(context.JobId));
            ToolTipService.SetToolTip(open, S.Text(UiStrings.DiagnosticsArtifactsOpenTracePrivacy));
            AutomationProperties.SetHelpText(open, S.Text(UiStrings.DiagnosticsArtifactsOpenTracePrivacy));
            panel.Children.Add(Ui.Row(open));
        }
        foreach (var artifact in session.Artifacts)
        {
            var facts = Ui.Stack(2,
                Ui.Text($"diagnostics.artifact.{artifact.Name}", artifact.Name, "ArkDeckMonoStyle"),
                Ui.Text($"diagnostics.artifact.{artifact.Name}.facts",
                    $"{artifact.Status} · {artifact.ByteCount.ToString(CultureInfo.InvariantCulture)} B · {artifact.Privacy}", "ArkDeckCaptionStyle"));
            if (artifact.Status == "published" && artifact.MediaType is "text/plain" or "application/json")
            {
                var read = Ui.Button($"diagnostics.artifact.read.{artifact.Name}",
                    S.Text(artifact.Privacy == "sensitive" ? UiStrings.DiagnosticsArtifactsReadSensitive : UiStrings.DiagnosticsArtifactsRead),
                    async (_, _) => await PreviewAsync(session, artifact));
                AutomationProperties.SetName(read, $"{S.Text(artifact.Privacy == "sensitive" ? UiStrings.DiagnosticsArtifactsReadSensitive : UiStrings.DiagnosticsArtifactsRead)}: {artifact.Name}");
                panel.Children.Add(Ui.Row(facts, read));
            }
            else
            {
                panel.Children.Add(facts);
            }
        }
        panel.Children.Add(Ui.Text("diagnostics.artifacts.openElsewhere", S.Text(UiStrings.DiagnosticsArtifactsOpenElsewhere), "ArkDeckCaptionStyle"));
        return panel;
    }

    /// <summary>macOS <c>TracePublishedArtifactPolicy.selectRawTrace</c> over the session's
    /// Artifacts (the Trace page's rule).</summary>
    private static bool IsRawTrace(DiagnosticJobArtifact a) =>
        a is { Name: ArtifactSummary.TraceName, MediaType: "application/octet-stream", Privacy: "sensitive", Status: "published", ByteCount: > 0, SourceOperation: TraceOperations.Reference }
        && a.Sha256.Length == 64 && a.Sha256.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    private async Task OpenTraceAsync(string jobId)
    {
        var outcome = await Task.Run(() => App.Loader.OpenCapturedTraceAsync(jobId, TraceInbox.Root(App.Options.CacheRoot)));
        MainWindow.Instance.Report(outcome);
        if (outcome.Document is { } document) MainWindow.Instance.OpenTraceViewer(document);
        else Ui.Say(_status, S.Text(outcome.FailureKey ?? UiStrings.TraceViewerReadFailed));
    }

    /// <summary>Reading device text is a separate, explicit local action: nothing is fetched on
    /// navigation, exported or sent anywhere.</summary>
    private async Task PreviewAsync(DiagnosticSessionPresentation session, DiagnosticJobArtifact artifact)
    {
        if (_previewLoading || _context is not { } context) return;
        _previewLoading = true;
        _preview.Children.Clear();
        _preview.Children.Add(Ui.Text("diagnostics.preview.name", artifact.Name, "ArkDeckSectionTitleStyle"));
        _preview.Children.Add(Ui.Progress("diagnostics.preview.loading", S.Text(UiStrings.DiagnosticsSessionLoading)));
        try
        {
            var (preview, failure) = await Task.Run(() => App.Loader.DiagnosticPreviewAsync(context, session, artifact));
            if (!ReferenceEquals(_context, context)) return;
            _preview.Children.RemoveAt(1);
            if (preview is null)
            {
                var text = failure is null ? null : failure == DiagnosticSessionText.InvalidStructuredText ? S.Text(failure) : failure;
                if (text is not null)
                {
                    _preview.Children.Add(Ui.Text("diagnostics.preview.failed", text, "ArkDeckCaptionStyle"));
                    Ui.Say(_status, text);
                }
                return;
            }
            if (preview.WasClipped) _preview.Children.Add(Ui.Text("diagnostics.preview.clipped", S.Text(UiStrings.DiagnosticsPreviewClipped), "ArkDeckCaptionStyle"));
            if (preview.ReplacedInvalidUtf8)
            {
                _preview.Children.Add(Ui.Text("diagnostics.preview.encodingWarning", S.Text(UiStrings.DiagnosticsPreviewReplacedInvalidUTF8), "ArkDeckCaptionStyle"));
            }
            var body = Ui.Text("diagnostics.preview.text", preview.Text, "ArkDeckMonoStyle");
            body.IsTextSelectionEnabled = true;
            // The text itself is not the element's name (it can be 120,000 characters).
            AutomationProperties.SetName(body, artifact.Name);
            _preview.Children.Add(body);
            Ui.Say(_status, artifact.Name);
        }
        finally
        {
            _previewLoading = false;
        }
    }

    // ---- the footer: what is selected, and why nothing can be aligned ----

    private UIElement Footer(DiagnosticSessionReading? reading)
    {
        var summary = _selection?.Event is { } selected
            ? _selection.CursorOffsetFromEventMs() is int drift and not 0
                ? $"{selected.Name} · {S.Text(UiStrings.DiagnosticsSelectionDriftedAway)} {(drift > 0 ? "+" : "")}{drift.ToString(CultureInfo.InvariantCulture)} ms"
                : selected.Name
            : S.Text(UiStrings.DiagnosticsSelectionTimeOnly);
        var row = Ui.Stack(4, Ui.Text("diagnostics.selection", summary, "ArkDeckCaptionStyle"));
        if (reading?.Alignment is DiagnosticAlignment.CannotAlign cannot)
        {
            var detail = reading.ClockObservation is { } observation
                ? observation.Status == "unvalidated"
                    ? S.Text(UiStrings.DiagnosticsAlignmentObservedWindow).Replace("{milliseconds}", observation.WindowMilliseconds.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
                    : S.Text(UiStrings.DiagnosticsAlignmentClockDiscontinuity)
                : cannot.Reason == "capture artifacts contain no host-to-device calibration"
                ? S.Text(UiStrings.DiagnosticsAlignmentExplain)
                : $"{S.Text(UiStrings.DiagnosticsAlignmentExplain)} ({cannot.Reason})";
            row.Children.Add(Ui.Text("diagnostics.alignment.detail", detail, "ArkDeckCaptionStyle"));
        }
        return row;
    }
}
