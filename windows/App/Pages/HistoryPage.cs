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

    protected override Task<HistoryState> LoadAsync() => App.Loader.HistoryAsync();

    protected override void Render(HistoryState state, StackPanel body)
    {
        if (state.Jobs.Unavailable is { } why)
        {
            body.Children.Add(Ui.Card(Ui.UnavailableNotice("history.unavailable", UiStrings.HistoryUnavailableTitle, why,
                UiStrings.HistoryUnavailableGuidance, titleId: "history.unavailable.title")));
        }
        else if (state.Jobs.Value!.Count == 0)
        {
            body.Children.Add(Ui.Card(Ui.Stack(4,
                Ui.Text("history.empty.title", S.Text(UiStrings.HistoryEmptyTitle), "ArkDeckSectionTitleStyle"),
                Ui.Text("history.empty.description", S.Text(UiStrings.HistoryEmptyDescription)))));
        }
        else
        {
            var table = Ui.Choice("history.table", S.Text(UiStrings.AppNavigationHistory));
            foreach (var job in state.Jobs.Value!)
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
            body.Children.Add(Ui.Card(table));
            _detail = new StackPanel { Spacing = 8 };
            body.Children.Add(Ui.Card(_detail, "history.detail"));
            if (_selected is { } selected && state.Jobs.Value!.Any(j => j.JobId == selected))
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
        foreach (var (id, key, value) in new (string, string, string?)[]
                 {
                     ("history.detail.job", UiStrings.HistoryDetailJob, job.JobId),
                     ("history.detail.operation", UiStrings.HistoryDetailOperation, job.Operation),
                     ("history.detail.target", UiStrings.HistoryDetailTarget, job.TargetId),
                     ("history.detail.state", UiStrings.HistoryDetailState, Ui.JobState("history.state.", job.State)),
                     ("history.detail.mode", UiStrings.HistoryDetailMode, job.ExecutionMode),
                     ("history.detail.created", UiStrings.HistoryDetailCreated, job.CreatedAtUtc),
                     ("history.detail.finished", UiStrings.HistoryDetailFinished, job.FinishedAtUtc),
                 })
        {
            if (value is not null) _detail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }

        // macOS "Open Diagnostics": the record's read-only context in Diagnostics (the other
        // workspaces' hand-off is not ported yet).
        if (DiagnosticsState.ContextOf(job) is { } context)
        {
            var open = Ui.Button("history.openDiagnostics", S.Text(UiStrings.HistoryActivityOpenDiagnostics), (_, _) => MainWindow.Instance.OpenDiagnostics(context));
            ToolTipService.SetToolTip(open, S.Text(UiStrings.HistoryContextReadOnly));
            AutomationProperties.SetHelpText(open, S.Text(UiStrings.HistoryContextReadOnly));
            _detail.Children.Add(Ui.Row(open));
        }

        Evidence(state.Evidence);

        _detail.Children.Add(Ui.Heading("history.detail.artifacts", S.Text(UiStrings.HistoryDetailArtifacts), AutomationHeadingLevel.Level3));
        if (state.Artifacts.Unavailable is { } artifactsWhy)
        {
            _detail.Children.Add(Ui.UnavailableNotice("history.artifacts.unavailable", UiStrings.WindowsHistoryArtifactsUnavailable, artifactsWhy));
            return;
        }
        var artifacts = state.Artifacts.Value!;
        if (artifacts.Count == 0)
        {
            // A planned Job carries no captured Artifacts by design (macOS emptyPlanned).
            _detail.Children.Add(Ui.Text("history.artifacts.empty",
                S.Text(job.ExecutionMode == "planOnly" ? UiStrings.HistoryArtifactsEmptyPlanned : UiStrings.HistoryArtifactsEmpty), "ArkDeckCaptionStyle"));
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
