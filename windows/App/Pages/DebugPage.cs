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
/// Debug, as the macOS Debug workspace (<c>DebugWorkspaceView</c>): the scope line, the Target
/// the page submits against, and five tabs — Artifacts (an app-owned native library planned,
/// reviewed, then deployed), Logs (a bounded HiLog capture and its shards), Apps (one HAP
/// lifecycle), Network (typed port rules) and Commands (four read-only templates) — each with
/// its operation's Runtime availability and its recent Jobs. Every action is one closed typed
/// Runtime Job (<see cref="SurfaceLoader.SubmitLogsAsync"/> and siblings); nothing is a raw
/// command. Where macOS disables an action, the action stays and says why it cannot run.
/// </summary>
public sealed partial class DebugPage() : SurfacePage<DebugState>(
    "debug", "debug.title", UiStrings.WindowsNavigationDebug,
    "debug.refresh", UiStrings.DebugActionRefresh, "debug.loading", UiStrings.SettingsCommonLoading)
{
    private static readonly string[] TabOrder = ["artifacts", "logs", "apps", "network", "commands"];

    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _tab = new() { Spacing = 14 };
    private SelectorBar? _tabBar;
    private DebugState? _state;
    private string _selectedTab = "artifacts";
    private string? _targetId;
    private bool _targetChosen;

    protected override Task<DebugState> LoadAsync() => App.Loader.DebugAsync(_targetId);

    private TargetSummary? Target => _state?.Targets.Value?.FirstOrDefault(t => t.TargetId == _targetId);

    protected override void Render(DebugState state, StackPanel body)
    {
        _state = state;
        // macOS DebugWorkspaceRefreshState: the first Target once the list loads, until the
        // person picks another (or none); a Target that disappears is dropped.
        var targets = state.Targets.Value ?? [];
        if (!_targetChosen || (_targetId is not null && targets.All(t => t.TargetId != _targetId)))
        {
            _targetId = targets.FirstOrDefault()?.TargetId;
        }
        _tab = new StackPanel { Spacing = 14 };
        body.Children.Add(Ui.Text("debug.scope", S.Text(UiStrings.DebugScope), "ArkDeckCaptionStyle"));
        body.Children.Add(TargetRow(state));
        if (state.Targets.Unavailable is { } why) body.Children.Add(Ui.Card(Ui.UnavailableNotice("debug.target.failure", UiStrings.DebugTargetLabel, why)));
        var active = (state.Jobs.Value ?? []).Count(j => j.IsActive);
        if (active > 0)
        {
            body.Children.Add(Ui.Row(Ui.Button("debug.activeJobs", S.Format(UiStrings.DebugJobsActive, active), (_, _) => MainWindow.Instance.Select("history"))));
        }
        body.Children.Add(TabBar());
        body.Children.Add(_tab);
        RenderTab();
    }

    private FlowPanel TargetRow(DebugState state)
    {
        var label = S.Text(UiStrings.DebugTargetLabel);
        var picker = new ComboBox { MinWidth = 230 };
        AutomationProperties.SetAutomationId(picker, "debug.target");
        AutomationProperties.SetName(picker, label);
        var none = new ComboBoxItem { Content = S.Text(UiStrings.DebugTargetNone), Tag = "" };
        picker.Items.Add(none);
        picker.SelectedItem = none;
        foreach (var target in state.Targets.Value ?? [])
        {
            var item = new ComboBoxItem { Content = target.TargetId, Tag = target.TargetId };
            AutomationProperties.SetAutomationId(item, "debug.target." + target.TargetId);
            picker.Items.Add(item);
            if (target.TargetId == _targetId) picker.SelectedItem = item;
        }
        picker.SelectionChanged += async (_, _) =>
        {
            if (picker.SelectedItem is not ComboBoxItem { Tag: string id }) return;
            var chosen = id.Length == 0 ? null : id;
            if (chosen == _targetId) return;
            _targetId = chosen;
            _targetChosen = true;
            await RefreshAsync();
        };
        var row = Ui.Row(Ui.Text("debug.target.label", label, "ArkDeckCaptionStyle"), picker);
        if (Target is { } selected)
        {
            row.Children.Add(Ui.Text("debug.target.binding", S.Format(UiStrings.DebugTargetBinding, selected.BindingRevision, selected.ToolVersion), "ArkDeckMonoStyle"));
        }
        return row;
    }

    /// <summary>The five tabs as a Fluent SelectorBar (arrow keys between tabs), on the tab
    /// last chosen.</summary>
    private SelectorBar TabBar()
    {
        var bar = new SelectorBar();
        _tabBar = bar;
        AutomationProperties.SetAutomationId(bar, "debug.tabs");
        AutomationProperties.SetName(bar, S.Text(UiStrings.DebugTabsLabel));
        foreach (var tag in TabOrder)
        {
            var title = S.Text("debug.tab." + tag);
            var item = new SelectorBarItem { Text = title, Tag = tag };
            AutomationProperties.SetAutomationId(item, "debug.tab." + tag);
            AutomationProperties.SetName(item, title);
            bar.Items.Add(item);
            if (tag == _selectedTab) bar.SelectedItem = item;
        }
        bar.SelectionChanged += (_, _) =>
        {
            if (bar.SelectedItem is { Tag: string tag } && tag != _selectedTab)
            {
                _selectedTab = tag;
                RenderTab();
            }
        };
        return bar;
    }

    private void RenderTab()
    {
        _tab.Children.Clear();
        if (_state is not { } state) return;
        switch (_selectedTab)
        {
            case "logs": LogsTab(state); break;
            case "apps": AppsTab(state); break;
            case "network": NetworkTab(state); break;
            case "commands": CommandsTab(state); break;
            default: ArtifactsTab(state); break;
        }
    }

    // ---- shared parts ----

    /// <summary>A titled section (macOS <c>WorkspaceSection</c>): heading, optional availability
    /// line beside it, then its content.</summary>
    private static Border Section(string id, string titleKey, OperationFacts? availabilityOf, bool includeAvailability, params UIElement[] children)
    {
        var header = Ui.Row(Ui.Heading(id + ".title", S.Text(titleKey), AutomationHeadingLevel.Level2));
        if (includeAvailability) header.Children.Add(AvailabilityStatus(availabilityOf));
        var stack = Ui.Stack(8, header);
        foreach (var child in children) stack.Children.Add(child);
        return Ui.Card(stack, id);
    }

    /// <summary>Availability as one line beside the section title it gates.</summary>
    private static TextBlock AvailabilityStatus(OperationFacts? operation)
    {
        var key = operation?.Availability.Kind switch
        {
            AvailabilityKind.Checking => UiStrings.DebugAvailabilityChecking,
            AvailabilityKind.Available => UiStrings.DebugAvailabilityAvailable,
            _ => UiStrings.DebugAvailabilityUnavailable,
        };
        return Ui.Text("debug.availability.status", S.Text(key), "ArkDeckCaptionStyle");
    }

    /// <summary>The blocker, and only the blocker: the Runtime's reasons while it reports the
    /// operation unavailable, nothing while it is available.</summary>
    private static UIElement? AvailabilityNotice(OperationFacts? operation)
    {
        if (operation is null) return Ui.Text("debug.availability.missing", S.Text(UiStrings.DebugAvailabilityMissing));
        if (operation.Availability.Kind != AvailabilityKind.Unavailable) return null;
        var stack = Ui.Stack(4, Ui.Text("debug.availability.blocked", S.Text(UiStrings.DebugAvailabilityUnavailable)));
        var index = 0;
        foreach (var reason in operation.Availability.Reasons)
        {
            stack.Children.Add(Ui.Text($"debug.availability.reason.{index++}", reason, "ArkDeckMonoStyle"));
        }
        return stack;
    }

    private static void AddIf(Panel panel, UIElement? element)
    {
        if (element is not null) panel.Children.Add(element);
    }

    /// <summary>Why an action cannot run now, in the order macOS disables it: no Target, the
    /// operation unavailable, invalid inputs, a Job of the tab running.</summary>
    private string? Blocker(OperationFacts? operation, bool inputsValid, bool busy)
    {
        if (Target is null) return S.Text(UiStrings.WindowsDebugNeedsTarget);
        if (operation is not { IsAvailable: true }) return S.Text(UiStrings.WindowsDebugOperationUnavailable);
        if (!inputsValid) return S.Text(UiStrings.WindowsDebugNeedsInputs);
        return busy ? S.Text(UiStrings.WindowsDebugBusy) : null;
    }

    private static string FailureText(string code)
    {
        var key = "debug.failure." + code;
        return UiStrings.All.Contains(key) ? S.Text(key) : code;
    }

    private static string EffectLine(OperationStep step) => $"{step.Kind} · {step.Effect}";

    /// <summary>The operation's recent Jobs on the selected Target (macOS
    /// <c>DebugRecentJobsSection</c>): five rows, each with its state, its typed failure or its
    /// latest timeline line, and a stop request while it is active.</summary>
    private Border RecentJobs(DebugState state, string tab, params string[] operations)
    {
        var jobs = (state.Jobs.Value ?? []).Where(j => operations.Contains(j.Operation) && (_targetId is null || j.TargetId == _targetId)).Take(5).ToArray();
        var stack = Ui.Stack(8, Ui.Heading($"debug.{tab}.jobs.title", S.Text(UiStrings.DebugJobsTitle), AutomationHeadingLevel.Level2));
        if (state.Jobs.Unavailable is { } why)
        {
            stack.Children.Add(Ui.UnavailableNotice($"debug.{tab}.jobs.unavailable", UiStrings.DebugJobsTitle, why));
        }
        else if (jobs.Length == 0)
        {
            stack.Children.Add(Ui.Text($"debug.{tab}.jobs.empty", S.Text(UiStrings.DebugJobsEmpty), "ArkDeckCaptionStyle"));
        }
        var status = Ui.Status($"debug.{tab}.jobs.status");
        foreach (var job in jobs)
        {
            var row = Ui.Stack(2,
                Ui.Text($"debug.jobs.row.{job.JobId}", job.JobId, "ArkDeckMonoStyle"),
                Ui.Text($"debug.jobs.row.{job.JobId}.summary", $"{job.TargetId} · {job.Operation} · {job.State}", "ArkDeckCaptionStyle"));
            if (job.FailureCode is { } code) row.Children.Add(Ui.Text($"debug.jobs.typedFailure.{job.JobId}", FailureText(code), "ArkDeckCaptionStyle"));
            if (job.IsActive)
            {
                row.Children.Add(Ui.Row(Ui.Button($"debug.jobs.cancel.{job.JobId}", S.Text(UiStrings.DebugActionCancel), async (_, _) =>
                {
                    var answer = await Task.Run(() => App.Loader.CancelJobAsync(job.JobId));
                    MainWindow.Instance.Report(answer);
                    if (answer.Answer.Value is not { Requested: true }) Ui.Say(status, S.Text(UiStrings.WindowsDebugJobsCancelFailed));
                    await RefreshAsync();
                })));
            }
            stack.Children.Add(row);
        }
        stack.Children.Add(status);
        return Ui.Card(stack, $"debug.{tab}.jobs");
    }

    /// <summary>A published Artifact row with its export (macOS shard rows): name, status and
    /// privacy, size, the digest's first 12 hex, and Export with its preview.</summary>
    private FrameworkElement ArtifactRow(string prefix, string jobId, ArtifactSummary artifact, StackPanel resultHost)
    {
        var digest = artifact.Digest is { Length: >= 12 } d ? d[..12] : artifact.Digest ?? "";
        var row = Ui.Stack(2,
            Ui.Text($"{prefix}.artifact.{artifact.ArtifactId}", artifact.Name, "ArkDeckMonoStyle"),
            Ui.Text($"{prefix}.artifact.{artifact.ArtifactId}.facts",
                $"{artifact.Status} · {artifact.Privacy} · {S.Format(UiStrings.WindowsBytes, artifact.ByteCountText)} · {digest}", "ArkDeckCaptionStyle"));
        if (artifact.IsPublished)
        {
            row.Children.Add(Ui.Row(Ui.Button($"{prefix}.export.{artifact.ArtifactId}", S.Text(UiStrings.DebugLogsExport),
                async (_, _) => await ExportAsync(prefix, jobId, artifact, resultHost))));
        }
        row.Children.Add(resultHost);
        return row;
    }

    /// <summary>The macOS export: the preview (a sensitive Artifact needs its own
    /// confirmation), a save location the person picks, then the bounded, digest-verified read.</summary>
    private async Task ExportAsync(string prefix, string jobId, ArtifactSummary artifact, StackPanel resultHost)
    {
        var message = S.Format(UiStrings.DebugLogsExportPreviewMessage,
            artifact.Name, S.Format(UiStrings.WindowsBytes, artifact.ByteCountText), artifact.Privacy, artifact.Digest ?? string.Empty);
        var preview = Ui.Dialog(XamlRoot, $"{prefix}.exportPreview", S.Text(UiStrings.DebugLogsExportPreviewTitle),
            Ui.Text($"{prefix}.exportPreview.message", message),
            S.Text(artifact.IsSensitive ? UiStrings.DebugLogsExportSensitive : UiStrings.DebugLogsExportConfirm), S.Text(UiStrings.DebugLogsExportCancel));
        if (await preview.ShowAsync() != ContentDialogResult.Primary) return;
        var name = artifact.Name.Replace('/', '_').Replace(':', '_');
        if (name.Length == 0) name = "ArkDeck-Artifact";
        var extension = Path.GetExtension(name);
        var picker = new FileSavePicker(MainWindow.Instance.AppWindow.Id) { SuggestedFileName = name, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add(extension.Length > 1 ? extension : ".bin", [extension.Length > 1 ? extension : ".bin"]);
        var picked = await picker.PickSaveFileAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
        resultHost.Children.Clear();
        resultHost.Children.Add(Ui.Progress($"{prefix}.exporting.{artifact.ArtifactId}", S.Text(UiStrings.DebugLogsExporting)));
        var outcome = await Task.Run(() => new ArtifactExporter(App.Loader.Channel).ExportAsync(jobId, artifact, picked.Path, allowSensitive: artifact.IsSensitive));
        MainWindow.Instance.Report(outcome);
        resultHost.Children.Clear();
        var result = Ui.Live(Ui.Text($"{prefix}.exportResult.{artifact.ArtifactId}", outcome.Completed
            ? S.Format(UiStrings.WindowsHistoryArtifactsExported, outcome.ExportedPath!)
            : $"{S.Text(UiStrings.WindowsHistoryArtifactsExportFailed)} · {outcome.Failure!.ReasonText(S)}", "ArkDeckCaptionStyle"),
            outcome.Completed ? AutomationLiveSetting.Polite : AutomationLiveSetting.Assertive);
        resultHost.Children.Add(result);
        Ui.Announce(result);
    }

    /// <summary>The Job a tab runs, as the macOS view models run it: submitted, then run to its
    /// end (<c>job.run</c>) while the page re-reads the workspace, then the terminal facts.</summary>
    private async Task<(JobTerminal? Terminal, Unavailable? Failure)> RunToEndAsync(SubmitOutcome submitted, Action<string> onAdmitted)
    {
        MainWindow.Instance.Report(submitted);
        if (submitted.JobId is not { } jobId) return (null, submitted.Failure);
        onAdmitted(jobId);
        var run = await Task.Run(() => App.Loader.RunJobAsync(jobId, CliCommands.ForJob(CliCommands.JobRun, jobId)));
        MainWindow.Instance.Report(run);
        return (run.Answer.Value, run.Answer.Unavailable);
    }

    private static TextBlock TerminalLine(string id, JobTerminal terminal) =>
        Ui.Text(id, $"{terminal.State} · {terminal.JobId}", "ArkDeckCaptionStyle");
}
