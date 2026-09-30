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
/// Imports: a local file uploaded to the Runtime as an Import of one kind, bound to an adopted
/// Target (the CLI's <c>artifact import hap|native-library|workspace-patch|flash-bundle</c>),
/// and the Imports the Runtime keeps (<c>artifact.import.list|inspect</c>). The file comes from
/// the system file dialog; the upload shows its progress and can be cancelled, which aborts the
/// partial Import (<see cref="ImportUploader"/>). A committed Import can be released after a
/// confirmation, guarded by the generation the App read (<c>artifact.import.release</c>). The
/// Runtime's own refusal is shown as it came (a flash bundle is refused at publication while no
/// validator is configured).
/// </summary>
public sealed partial class ImportsPage() : SurfacePage<ImportsState>(
    "imports", "imports.title", UiStrings.WindowsNavigationImports,
    "imports.refresh", UiStrings.SettingsCommonRefresh, "imports.loading", UiStrings.SettingsCommonLoading)
{
    private static readonly (string Kind, string Key, string[] Extensions)[] Kinds =
    [
        (ImportKind.Hap, UiStrings.WindowsImportsKindHap, [".hap", ".hsp"]),
        (ImportKind.NativeLibrary, UiStrings.WindowsImportsKindNativeLibrary, [".so"]),
        (ImportKind.WorkspacePatch, UiStrings.WindowsImportsKindWorkspacePatch, [".patch", ".diff"]),
        (ImportKind.FlashBundle, UiStrings.WindowsImportsKindFlashBundle, [".gz"]),
    ];

    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _detail = new() { Spacing = 8 };
    private TextBlock _status = Ui.Status("imports.status");
    private TextBlock _fileText = new();
    private ProgressBar? _progressBar;
    private TextBlock? _progressText;
    private IReadOnlyList<ImportRecord> _imports = [];
    private IReadOnlyList<TargetSummary> _targets = [];
    private string _kind = ImportKind.Hap;
    private string? _targetId;
    private string? _file;
    private string? _selected;
    private CancellationTokenSource? _upload;
    private (long Sent, long Total) _sent;

    protected override Task<ImportsState> LoadAsync() => App.Loader.ImportsAsync();

    protected override void Render(ImportsState state, StackPanel body)
    {
        var said = _status.Text;
        _status = Ui.Status("imports.status");
        Ui.SetText(_status, said);
        _detail = new StackPanel { Spacing = 8 };
        body.Children.Add(Ui.Text("imports.subtitle", S.Text(UiStrings.WindowsImportsSubtitle), "ArkDeckCaptionStyle"));
        body.Children.Add(Ui.Card(Form(state), "imports.new"));
        body.Children.Add(_status);

        body.Children.Add(Ui.Heading("imports.list.title", S.Text(UiStrings.WindowsImportsList)));
        if (state.Imports.Unavailable is { } why)
        {
            _imports = [];
            body.Children.Add(Ui.Card(Ui.UnavailableNotice("imports.unavailable", UiStrings.WindowsImportsUnavailable, why)));
            return;
        }
        _imports = state.Imports.Value!;
        if (_imports.Count == 0)
        {
            body.Children.Add(Ui.Text("imports.empty", S.Text(UiStrings.WindowsImportsEmpty)));
            return;
        }
        var list = Ui.Choice("imports.list", S.Text(UiStrings.WindowsImportsList));
        foreach (var import in _imports)
        {
            var summary = S.Format(UiStrings.WindowsImportsRow, import.Kind, import.State, S.Format(UiStrings.WindowsBytes, import.ByteCount));
            var row = Ui.Stack(2,
                Ui.Text($"imports.row.{import.ImportId}.title", import.Name, "ArkDeckMonoStyle"),
                Ui.Text($"imports.row.{import.ImportId}.summary", summary, "ArkDeckCaptionStyle"));
            var item = Ui.Item("imports.row." + import.ImportId, $"{import.Name}, {summary}", row);
            item.Tag = import.ImportId;
            list.Items.Add(item);
            if (import.ImportId == _selected) list.SelectedItem = item;
        }
        list.SelectionChanged += async (_, e) =>
        {
            if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string id }) await ShowImportAsync(id);
        };
        body.Children.Add(Ui.Card(list));
        body.Children.Add(Ui.Card(_detail, "imports.detail"));
        if (_selected is { } selected && _imports.Any(i => i.ImportId == selected)) _ = ShowImportAsync(selected);
        else
        {
            _selected = null;
            _detail.Children.Add(Ui.Text("imports.select", S.Text(UiStrings.WindowsImportsSelect), "ArkDeckCaptionStyle"));
        }
    }

    /// <summary>The new-Import form: kind, Target, the chosen file, Import, and while an upload
    /// runs its progress and Cancel.</summary>
    private StackPanel Form(ImportsState state)
    {
        var form = Ui.Stack(10, Ui.Heading("imports.new.title", S.Text(UiStrings.WindowsImportsNew), AutomationHeadingLevel.Level2));
        if (state.Targets.Unavailable is { } why)
        {
            _targets = [];
            form.Children.Add(Ui.UnavailableNotice("imports.targets.unavailable", UiStrings.WindowsImportsTargetsUnavailable, why));
            return form;
        }
        _targets = state.Targets.Value!;
        if (_targets.Count == 0)
        {
            form.Children.Add(Ui.Text("imports.noTargets", S.Text(UiStrings.WindowsImportsNoTargets)));
            form.Children.Add(Ui.Row(Ui.Text("imports.noTargets.cli", S.Format(UiStrings.WindowsCliEquivalent, CliCommands.TargetList), "ArkDeckMonoStyle"),
                Ui.CopyCli("imports.noTargets.copyCli", CliCommands.TargetList)));
            return form;
        }

        var kind = Combo("imports.kind", S.Text(UiStrings.WindowsImportsKind));
        foreach (var (value, key, _) in Kinds)
        {
            var item = new ComboBoxItem { Content = S.Text(key), Tag = value };
            AutomationProperties.SetAutomationId(item, "imports.kind." + value);
            kind.Items.Add(item);
            if (value == _kind) kind.SelectedItem = item;
        }
        kind.SelectionChanged += (_, _) =>
        {
            if (kind.SelectedItem is not ComboBoxItem { Tag: string value } || value == _kind) return;
            // Another kind accepts other files: the choice starts over.
            _kind = value;
            _file = null;
            Ui.SetText(_fileText, S.Text(UiStrings.WindowsImportsNoFile));
        };

        var target = Combo("imports.target", S.Text(UiStrings.WindowsImportsTarget));
        if (_targets.All(t => t.TargetId != _targetId)) _targetId = _targets[0].TargetId;
        foreach (var t in _targets)
        {
            var item = new ComboBoxItem { Content = t.DisplayName is { } name ? $"{name} ({t.TargetId})" : t.TargetId, Tag = t.TargetId };
            AutomationProperties.SetAutomationId(item, "imports.target." + t.TargetId);
            target.Items.Add(item);
            if (t.TargetId == _targetId) target.SelectedItem = item;
        }
        target.SelectionChanged += (_, _) =>
        {
            if (target.SelectedItem is ComboBoxItem { Tag: string value }) _targetId = value;
        };

        var file = Ui.Fact("imports.file", S.Text(UiStrings.WindowsImportsFile), _file ?? S.Text(UiStrings.WindowsImportsNoFile));
        _fileText = (TextBlock)file.Children[1];
        form.Children.Add(Ui.Row(kind, target));
        form.Children.Add(file);
        form.Children.Add(Ui.Row(
            Ui.Button("imports.chooseFile", S.Text(UiStrings.WindowsImportsChooseFile), async (_, _) => await ChooseFileAsync()),
            Ui.Button("imports.start", S.Text(UiStrings.WindowsImportsStart), async (_, _) => await UploadAsync(), accent: true)));
        _progressBar = null;
        _progressText = null;
        if (_upload is not null) form.Children.Add(ProgressPanel());
        return form;
    }

    private static ComboBox Combo(string automationId, string header)
    {
        var combo = new ComboBox { Header = header, MinWidth = 240 };
        AutomationProperties.SetAutomationId(combo, automationId);
        AutomationProperties.SetName(combo, header);
        return combo;
    }

    private StackPanel ProgressPanel()
    {
        var name = S.Text(UiStrings.WindowsImportsProgress);
        _progressBar = new ProgressBar { Minimum = 0, Maximum = 100, MinWidth = 320 };
        AutomationProperties.SetAutomationId(_progressBar, "imports.progress");
        AutomationProperties.SetName(_progressBar, name);
        _progressText = Ui.Status("imports.progress.value");
        ShowProgress(announce: false);
        return Ui.Stack(6, _progressBar, _progressText,
            Ui.Row(Ui.Button("imports.cancel", S.Text(UiStrings.WindowsImportsCancel), (_, _) => _upload?.Cancel())));
    }

    private void ShowProgress(bool announce)
    {
        if (_progressBar is null || _progressText is null) return;
        var (sent, total) = _sent;
        _progressBar.Value = total == 0 ? 0 : sent * 100.0 / total;
        var text = S.Format(UiStrings.WindowsImportsProgressValue, S.Format(UiStrings.WindowsBytes, sent), S.Format(UiStrings.WindowsBytes, total));
        if (announce) Ui.Say(_progressText, text);
        else Ui.SetText(_progressText, text);
    }

    /// <summary>The system file dialog, filtered to the kind's file types.</summary>
    private async Task ChooseFileAsync()
    {
        var picker = new FileOpenPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        foreach (var extension in Kinds.First(k => k.Kind == _kind).Extensions) picker.FileTypeFilter.Add(extension);
        var picked = await picker.PickSingleFileAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
        _file = picked.Path;
        Ui.SetText(_fileText, _file);
    }

    private async Task UploadAsync()
    {
        if (_upload is not null)
        {
            Ui.Say(_status, S.Text(UiStrings.WindowsImportsBusy));
            return;
        }
        if (_file is not { } path)
        {
            Ui.Say(_status, S.Text(UiStrings.WindowsImportsChooseFileFirst));
            return;
        }
        if (_targets.FirstOrDefault(t => t.TargetId == _targetId) is not { } target) return;
        var kind = _kind;
        using var cancel = new CancellationTokenSource();
        _upload = cancel;
        _sent = (0, 0);
        // Created on the UI thread, so each report comes back to it.
        var progress = new Progress<(long Sent, long Total)>(p =>
        {
            // Announced at the start, then about every quarter, not on every chunk.
            var quarter = _sent.Total == 0 || p.Total == 0 || p.Sent * 4 / p.Total != _sent.Sent * 4 / _sent.Total || p.Sent == p.Total;
            _sent = p;
            ShowProgress(quarter);
        });
        await RefreshAsync();
        ImportOutcome outcome;
        try
        {
            outcome = await Task.Run(() => App.Loader.UploadImportAsync(path, kind, target, progress, cancel.Token));
        }
        finally
        {
            _upload = null;
        }
        MainWindow.Instance.Report(outcome);
        if (outcome.Committed is { } done)
        {
            _selected = done.ImportId;
            _file = null;
        }
        Ui.Say(_status, outcome switch
        {
            { Committed: { } committed } => S.Format(UiStrings.WindowsImportsDone, committed.Name, committed.Receipt!.ArtifactId),
            { Cancelled: true } => S.Text(UiStrings.WindowsImportsCancelled),
            { Failure: { } why } => $"{S.Text(UiStrings.WindowsImportsFailed)} · {why.ReasonText(S)}",
            _ => S.Text(UiStrings.WindowsImportsFailed),
        });
        await RefreshAsync();
    }

    private async Task ShowImportAsync(string importId)
    {
        _selected = importId;
        var detail = _detail;
        var state = await Task.Run(() => App.Loader.ImportAsync(importId));
        MainWindow.Instance.Report(state);
        if (_selected != importId || detail != _detail) return;
        detail.Children.Clear();
        if (state.Answer.Unavailable is { } why)
        {
            detail.Children.Add(Ui.UnavailableNotice("imports.detail.unavailable", UiStrings.WindowsImportsUnavailable, why));
            return;
        }
        var import = state.Answer.Value!;
        detail.Children.Add(Ui.Heading("imports.detail.title", import.Name, AutomationHeadingLevel.Level3));
        foreach (var (id, key, value) in new (string, string, string?)[]
                 {
                     ("imports.detail.id", UiStrings.WindowsImportsId, import.ImportId),
                     ("imports.detail.kind", UiStrings.WindowsImportsKind, import.Kind),
                     ("imports.detail.state", UiStrings.WindowsImportsState, import.State),
                     ("imports.detail.size", UiStrings.WindowsImportsSize, S.Format(UiStrings.WindowsBytes, import.ByteCount)),
                     ("imports.detail.sha256", UiStrings.WindowsImportsSha256, import.Sha256),
                     ("imports.detail.target", UiStrings.WindowsImportsTarget, import.TargetId),
                     ("imports.detail.generation", UiStrings.WindowsImportsGeneration, import.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                     ("imports.detail.created", UiStrings.WindowsImportsCreated, import.CreatedAtUtc),
                     ("imports.detail.artifact", UiStrings.WindowsImportsArtifact, import.Receipt?.ArtifactId),
                     ("imports.detail.digest", UiStrings.WindowsImportsDigest, import.Receipt?.ArtifactDigest),
                     ("imports.detail.mediaType", UiStrings.WindowsImportsMediaType, import.Receipt?.MediaType),
                     ("imports.detail.privacy", UiStrings.WindowsImportsPrivacy, import.Receipt?.Privacy),
                 })
        {
            if (value is not null) detail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        if (import.State == "committed")
        {
            detail.Children.Add(Ui.Row(Ui.Button("imports.release", S.Text(UiStrings.WindowsImportsRelease), async (_, _) => await ReleaseAsync(import))));
        }
    }

    private async Task ReleaseAsync(ImportRecord import)
    {
        var content = Ui.Text("imports.release.message", S.Format(UiStrings.WindowsImportsReleaseMessage, import.ImportId,
            import.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        var dialog = Ui.Dialog(XamlRoot, "imports.release.confirm", S.Text(UiStrings.WindowsImportsReleaseTitle), content,
            S.Text(UiStrings.WindowsImportsReleaseConfirm), S.Text(UiStrings.SettingsCommonCancel));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var state = await Task.Run(() => App.Loader.ReleaseImportAsync(import));
        MainWindow.Instance.Report(state);
        Ui.Say(_status, state.Answer.Unavailable is { } why
            ? $"{S.Text(UiStrings.WindowsImportsReleaseFailed)} · {why.ReasonText(S)}"
            : S.Text(UiStrings.WindowsImportsReleaseDone));
        await RefreshAsync();
    }
}
