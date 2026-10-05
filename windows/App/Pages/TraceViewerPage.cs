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
/// The Trace viewer (the macOS Trace Viewer window, <c>TraceViewerWorkspaceView</c>): capture or
/// open a Trace, the recent Traces, the timeline pane and the Inspector. Windows has no ArkTrace
/// parser (the macOS engine bundles a macOS-only <c>trace_streamer</c>), so the timeline pane shows
/// the macOS "bundled parser is unavailable" state with its diagnostics instead of a timeline, and
/// the Inspector shows what the file and the Runtime can tell: the file's size and SHA-256 and,
/// for a captured Trace, the Runtime's Trace inspector's answer (<c>trace.inspect</c>) — today a
/// refusal on Windows, shown as it is.
/// </summary>
public sealed partial class TraceViewerPage() : SurfacePage<TraceViewerState>(
    "traceViewer", "traceViewer.title", UiStrings.WindowsTraceViewerTitle,
    "traceViewer.refresh", UiStrings.WindowsTraceViewerReload, "traceViewer.loading", UiStrings.SettingsCommonLoading)
{
    private readonly TraceRecents _recents = TraceRecents.In(App.Options.CacheRoot);
    private TextBlock _status = Ui.Status("trace.viewer.status");
    private TraceDocument? _document;
    private string? _openFailure;
    private bool _diagnosticsOpen;

    protected override Task<TraceViewerState> LoadAsync() => App.Loader.TraceViewerAsync(_document, _recents);

    /// <summary>Shows a Trace (a captured one from the Trace page, or none) and re-reads.</summary>
    public async Task ShowAsync(TraceDocument? document)
    {
        if (document is not null)
        {
            _document = document;
            _openFailure = null;
            _recents.Add(document.Path);
        }
        await RefreshAsync();
    }

    protected override void Render(TraceViewerState state, StackPanel body)
    {
        var said = _status.Text;
        _status = Ui.Status("trace.viewer.status");
        Ui.SetText(_status, said);
        var capture = Ui.Button("trace.viewer.capture", S.Text(UiStrings.WindowsTraceViewerCapture), (_, _) => MainWindow.Instance.Select("trace"));
        ToolTipService.SetToolTip(capture, S.Text(UiStrings.WindowsTraceViewerCaptureHelp));
        AutomationProperties.SetHelpText(capture, S.Text(UiStrings.WindowsTraceViewerCaptureHelp));
        body.Children.Add(Ui.Row(capture, Ui.Button("trace.viewer.open", S.Text(UiStrings.WindowsTraceViewerOpen), async (_, _) => await ChooseAsync())));
        body.Children.Add(Ui.Card(Recent(state), "trace.viewer.recent"));
        body.Children.Add(Ui.Card(Timeline(state), "trace.viewer.timeline"));
        body.Children.Add(Ui.Card(Inspector(state), "trace.viewer.inspector"));
        body.Children.Add(_status);
    }

    // ---- the sidebar's recent Traces ----

    private StackPanel Recent(TraceViewerState state)
    {
        var panel = Ui.Stack(6, Ui.Heading("trace.viewer.recent.title", S.Text(UiStrings.WindowsTraceViewerRecent), AutomationHeadingLevel.Level2));
        for (var i = 0; i < state.Recents.Count; i++)
        {
            var path = state.Recents[i];
            var name = Path.GetFileName(path);
            var remove = Ui.Button($"trace.viewer.recent.{i}.remove", S.Text(UiStrings.WindowsTraceViewerRemoveRecent), async (_, _) =>
            {
                _recents.Remove(path);
                await RefreshAsync();
            });
            AutomationProperties.SetName(remove, $"{S.Text(UiStrings.WindowsTraceViewerRemoveRecent)}: {name}");
            if (File.Exists(path))
            {
                var open = Ui.Button($"trace.viewer.recent.{i}", name, async (_, _) => await OpenAsync(path));
                ToolTipService.SetToolTip(open, path);
                panel.Children.Add(Ui.Row(open, remove));
            }
            else
            {
                // A missing file is shown, inert, as on macOS.
                var missing = Ui.Text($"trace.viewer.recent.{i}", S.Format(UiStrings.WindowsTraceViewerMissingName, name), "ArkDeckCaptionStyle");
                ToolTipService.SetToolTip(missing, S.Format(UiStrings.WindowsTraceViewerMissingPath, path));
                panel.Children.Add(Ui.Row(missing, remove));
            }
        }
        return panel;
    }

    // ---- the timeline pane ----

    private StackPanel Timeline(TraceViewerState state)
    {
        if (_openFailure is { } failure)
        {
            return ErrorBanner(UiStrings.ErrorTitleTraceCouldNotBeOpened, UiStrings.ErrorReasonChooseFile, failure);
        }
        if (state.Document is not { } document)
        {
            return Ui.Stack(8,
                Ui.Heading("trace.viewer.idle.title", S.Text(UiStrings.WindowsTraceViewerIdleTitle), AutomationHeadingLevel.Level2),
                Ui.Text("trace.viewer.idle.detail", S.Text(UiStrings.WindowsTraceViewerIdleDetail), "ArkDeckCaptionStyle"),
                Ui.Row(
                    Ui.Button("trace.viewer.idle.capture", S.Text(UiStrings.WindowsTraceViewerCaptureTrace), (_, _) => MainWindow.Instance.Select("trace"), accent: true),
                    Ui.Button("trace.viewer.idle.open", S.Text(UiStrings.WindowsTraceViewerOpenTrace), async (_, _) => await ChooseAsync())));
        }
        var banner = ErrorBanner(UiStrings.ErrorTitleBundledParserUnavailable, UiStrings.ErrorReasonParser, S.Text(UiStrings.WindowsTraceViewerNoParser));
        banner.Children.Insert(0, Ui.Text("trace.viewer.document", document.Name, "ArkDeckMonoStyle"));
        return banner;
    }

    /// <summary>The macOS error banner: title, reason, a Diagnostics disclosure and the recovery.</summary>
    private StackPanel ErrorBanner(string titleKey, string reasonKey, string diagnostic)
    {
        var detail = Ui.Text("trace.viewer.error.diagnostic", diagnostic, "ArkDeckMonoStyle");
        detail.IsTextSelectionEnabled = true;
        detail.Visibility = _diagnosticsOpen ? Visibility.Visible : Visibility.Collapsed;
        var toggle = Ui.Button("trace.viewer.error.diagnostics", S.Text(UiStrings.WindowsTraceViewerDiagnostics), (_, _) =>
        {
            _diagnosticsOpen = !_diagnosticsOpen;
            detail.Visibility = _diagnosticsOpen ? Visibility.Visible : Visibility.Collapsed;
        });
        return Ui.Stack(8,
            Ui.Heading("trace.viewer.error.title", S.Text(titleKey), AutomationHeadingLevel.Level2),
            Ui.Text("trace.viewer.error.reason", S.Text(reasonKey)),
            Ui.Row(toggle, Ui.Button("trace.viewer.error.chooseAnother", S.Text(UiStrings.WindowsTraceViewerChooseAnother), async (_, _) => await ChooseAsync())),
            detail);
    }

    // ---- the Inspector ----

    private StackPanel Inspector(TraceViewerState state)
    {
        var panel = Ui.Stack(6, Ui.Heading("trace.viewer.inspector.title", S.Text(UiStrings.WindowsTraceViewerInspector), AutomationHeadingLevel.Level2));
        if (state.Document is not { } document)
        {
            panel.Children.Add(Ui.Text("trace.viewer.inspector.empty", S.Text(UiStrings.WindowsTraceViewerNothingSelected), "ArkDeckCaptionStyle"));
            return panel;
        }
        panel.Children.Add(Ui.Fact("trace.viewer.inspector.sourceBytes", S.Text(UiStrings.WindowsTraceViewerSourceBytes),
            document.ByteCount.ToString("N0", System.Globalization.CultureInfo.InvariantCulture)));
        panel.Children.Add(Ui.Fact("trace.viewer.inspector.sha256", S.Text(UiStrings.WindowsTraceViewerSha256), document.Sha256));
        if (state.Inspection is not { } inspection) return panel;
        panel.Children.Add(Ui.Heading("trace.viewer.inspection.title", S.Text(UiStrings.WindowsTraceViewerRuntimeInspection), AutomationHeadingLevel.Level3));
        if (inspection.Value is { } facts)
        {
            if (long.TryParse(facts.DurationNs, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var ns))
            {
                panel.Children.Add(Ui.Fact("trace.viewer.inspection.duration", S.Text(UiStrings.WindowsTraceViewerDuration), TraceViewerState.FormatDuration(ns)));
            }
            panel.Children.Add(Ui.Fact("trace.viewer.inspection.engine", S.Text(UiStrings.WindowsTraceViewerEngine),
                $"{facts.EngineName} {facts.EngineVersion} · {facts.ParserName} {facts.ParserVersion}"));
            panel.Children.Add(Ui.Fact("trace.viewer.inspection.dataQuality", S.Text(UiStrings.WindowsTraceViewerDataQuality), facts.DataQuality));
        }
        else if (inspection.Unavailable is { } why)
        {
            panel.Children.Add(Ui.Text("trace.viewer.inspection.reason", why.ReasonText(S), "ArkDeckCaptionStyle"));
            panel.Children.Add(Ui.Row(Ui.Text("trace.viewer.inspection.cli", why.CliText(S), "ArkDeckMonoStyle"), Ui.CopyCli("trace.viewer.inspection.copyCli", why.CliCommand)));
        }
        return panel;
    }

    // ---- opening ----

    /// <summary>The Trace menu's Open Trace… (Ctrl+Shift+O).</summary>
    public Task ChooseTraceAsync() => ChooseAsync();

    /// <summary>The Trace menu's Reload Trace (Ctrl+Shift+R): the open file read again.</summary>
    public async Task ReloadTraceAsync()
    {
        if (_document is { } document) await OpenAsync(document.Path);
        else Ui.Say(_status, S.Text(UiStrings.WindowsTraceViewerNothingToReload));
    }

    /// <summary>A Trace file Windows handed the App (Open with, or a file association).</summary>
    public Task OpenFileAsync(string path) => OpenAsync(path);

    private async Task ChooseAsync()
    {
        var picker = new FileOpenPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        foreach (var extension in TraceDocument.Extensions) picker.FileTypeFilter.Add(extension);
        var picked = await picker.PickSingleFileAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
        if (!TraceDocument.Extensions.Contains(Path.GetExtension(picked.Path).ToLowerInvariant()))
        {
            Ui.Say(_status, S.Text(UiStrings.WindowsTraceViewerChooseInvalid));
            return;
        }
        await OpenAsync(picked.Path);
    }

    private async Task OpenAsync(string path)
    {
        var document = await Task.Run(() => TraceDocument.OpenAsync(path));
        if (document is null)
        {
            _document = null;
            _openFailure = path;
            Ui.Say(_status, S.Text(UiStrings.ErrorTitleTraceCouldNotBeOpened));
            await RefreshAsync();
            return;
        }
        await ShowAsync(document);
        Ui.Say(_status, S.Text(UiStrings.ErrorTitleBundledParserUnavailable));
    }
}
