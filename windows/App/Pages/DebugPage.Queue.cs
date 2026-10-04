using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.RemoteSources;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace ArkDeck.App.Pages;

/// <summary>
/// Debug › Artifacts' folder sources and reviewed deployment queue (macOS #2466:
/// <c>NativeLibraryDirectorySource</c>, <c>NativeLibraryDeploymentBatch</c> and their sections):
/// choose up to four folders (a mapped or UNC share works as any folder), tick up to 16 of the
/// lib*.so files found, or add the library chosen alone or on a server; Validate and review
/// prepares one plan per library for the current Target and bundle, the review lists them all,
/// and Deploy runs them one at a time, stopping at the first failure or uncertainty.
/// </summary>
public sealed partial class DebugPage : INativeLibraryDeployment
{
    private readonly List<string> _directories = [];
    private IReadOnlyList<NativeLibrarySource> _directoryCandidates = [];
    private readonly List<NativeLibrarySource> _queue = [];
    private string? _queueSelectionError;
    private bool _readingDirectories;
    private NativeLibraryDeploymentBatch? _batch;

    private NativeLibraryDeploymentBatch Batch
    {
        get
        {
            if (_batch is null)
            {
                _batch = new NativeLibraryDeploymentBatch(this);
                _batch.Changed += () => DispatcherQueue.TryEnqueue(() => { if (_selectedTab == "artifacts") RenderTab(); });
            }
            return _batch;
        }
    }

    /// <summary>The folder sources' controls under the build source.</summary>
    private void AddFolderSources(StackPanel sourcePanel)
    {
        var choose = Ui.Button("debug.artifacts.chooseDirectory", S.Text(UiStrings.DebugArtifactsChooseDirectory), async (_, _) => await ChooseDirectoryAsync());
        sourcePanel.Children.Add(Ui.Row(choose));
        if (_readingDirectories) sourcePanel.Children.Add(Ui.Progress("debug.artifacts.directory.reading", S.Text(UiStrings.DebugArtifactsDirectoryTitle)));
        foreach (var (directory, index) in _directories.Select((d, i) => (d, i)))
        {
            sourcePanel.Children.Add(Ui.Text($"debug.artifacts.directory.chosen.{index}", directory, "ArkDeckMonoStyle"));
        }
    }

    /// <summary>The library chosen alone (local or on a server) as a queue item.</summary>
    private NativeLibrarySource? CurrentLibrary => _remoteSource
        ? _remoteLibrary is { } remote ? new NativeLibrarySource.Ssh(remote.SourceId, remote.SourceName, remote.RelativePath) : null
        : _libraryPath is { } path ? new NativeLibrarySource.File(path) : null;

    private void AddQueueControls(StackPanel sourcePanel)
    {
        if (_queueSelectionError is { } error) sourcePanel.Children.Add(Ui.Text("debug.artifacts.queue.selectionError", error, "ArkDeckCaptionStyle"));
        if (CurrentLibrary is { } current)
        {
            sourcePanel.Children.Add(Ui.Row(Ui.Button("debug.artifacts.batch.add", S.Text(UiStrings.DebugArtifactsBatchAdd), (_, _) => AddToQueue(current))));
        }
        if (_remoteSource) sourcePanel.Children.Add(Ui.Text("debug.artifacts.wslSource", S.Text(UiStrings.DebugArtifactsWslSource), "ArkDeckCaptionStyle"));
    }

    /// <summary>The folder results and the queue sections.</summary>
    private void QueueSections(OperationFacts? operation)
    {
        if (_directoryCandidates.Count > 0)
        {
            var list = Ui.Stack(4, Ui.Text("debug.artifacts.directory.detail", S.Text(UiStrings.DebugArtifactsDirectoryDetail), "ArkDeckCaptionStyle"));
            foreach (var candidate in _directoryCandidates)
            {
                var box = new CheckBox { Content = $"{candidate.Name} · {candidate.Location}", IsChecked = _queue.Any(q => q.Id == candidate.Id) };
                AutomationProperties.SetAutomationId(box, "debug.artifacts.directory.library." + candidate.Name);
                AutomationProperties.SetName(box, $"{candidate.Name}, {candidate.Location}");
                box.Checked += (_, _) => AddToQueue(candidate);
                box.Unchecked += (_, _) => RemoveFromQueue(candidate.Id);
                list.Children.Add(box);
            }
            _tab.Children.Add(Section("debug.artifacts.directory", UiStrings.DebugArtifactsDirectoryTitle, null, false, list));
        }
        if (_queue.Count == 0) return;
        var batch = Batch;
        var panel = Ui.Stack(8, Ui.Text("debug.artifacts.batch.detail", S.Text(UiStrings.DebugArtifactsBatchDetail), "ArkDeckCaptionStyle"));
        foreach (var source in _queue)
        {
            var facts = Ui.Stack(2,
                Ui.Text($"debug.artifacts.batch.row.{source.Name}", source.Name, "ArkDeckMonoStyle"),
                Ui.Text($"debug.artifacts.batch.row.{source.Name}.location", source.Location, "ArkDeckCaptionStyle"));
            if (batch.Rows.FirstOrDefault(r => r.Source.Id == source.Id) is { } row)
            {
                facts.Children.Add(Ui.Text($"debug.artifacts.batch.row.{source.Name}.state", S.Text("debug.artifacts.batch.row." + Camel(row.State.ToString())), "ArkDeckCaptionStyle"));
                if (row.JobId is { } jobId) facts.Children.Add(Ui.Text($"debug.artifacts.batch.row.{source.Name}.job", jobId, "ArkDeckMonoStyle"));
            }
            var remove = Ui.Button($"debug.artifacts.batch.remove.{source.Name}", S.Text(UiStrings.DebugArtifactsBatchRemove), (_, _) => RemoveFromQueue(source.Id));
            AutomationProperties.SetName(remove, $"{S.Text(UiStrings.DebugArtifactsBatchRemove)}: {source.Name}");
            panel.Children.Add(Ui.Row(facts, remove));
        }
        if (batch.Phase != NativeLibraryBatchPhase.Idle)
        {
            panel.Children.Add(Ui.Text("debug.artifacts.batch.status", S.Text("debug.artifacts.batch.phase." + Camel(batch.Phase.ToString())), "ArkDeckSectionTitleStyle"));
            if (batch.Target is { } batchTarget)
            {
                panel.Children.Add(Ui.Text("debug.artifacts.batch.scope", $"{batchTarget.TargetId} · binding r{batchTarget.BindingRevision} · {batch.TargetBundle}", "ArkDeckMonoStyle"));
            }
        }
        if (batch.Failure is { } failure) panel.Children.Add(Ui.Text("debug.artifacts.batch.failure", failure));
        panel.Children.Add(batch.IsBusy
            ? Ui.Row(Ui.Button("debug.artifacts.batch.stop", S.Text(UiStrings.DebugArtifactsBatchStop), (_, _) => batch.Stop()))
            : Ui.Row(Ui.Button("debug.artifacts.batch.prepare", S.Text(UiStrings.DebugArtifactsBatchPrepare), async (_, _) => await PrepareQueueAsync(operation))));
        _tab.Children.Add(Section("debug.artifacts.batch", UiStrings.DebugArtifactsBatchTitle, null, false, panel));
    }

    private static string Camel(string name) => char.ToLowerInvariant(name[0]) + name[1..];

    private void AddToQueue(NativeLibrarySource source)
    {
        if (Batch.IsBusy || _queue.Any(q => q.Id == source.Id)) return;
        if (_queue.Count >= NativeLibraryDeploymentBatch.MaximumLibraries)
        {
            _queueSelectionError = S.Text(UiStrings.DebugArtifactsBatchLimit);
            RenderTab();
            Ui.Say(_artifactsStatus, _queueSelectionError);
            return;
        }
        _queueSelectionError = null;
        _queue.Add(source);
        Batch.Invalidate();
    }

    private void RemoveFromQueue(string id)
    {
        if (Batch.IsBusy) return;
        _queue.RemoveAll(q => q.Id == id);
        Batch.Invalidate();
    }

    /// <summary>Adds a folder (at most four) and searches them all again.</summary>
    private async Task ChooseDirectoryAsync()
    {
        if (_readingDirectories || Batch.IsBusy) return;
        var picker = new FolderPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        var picked = await picker.PickSingleFolderAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
        var directories = _directories.Contains(picked.Path, StringComparer.OrdinalIgnoreCase) ? _directories.ToList() : _directories.Append(picked.Path).ToList();
        _readingDirectories = true;
        _queueSelectionError = null;
        RenderTab();
        try
        {
            var found = await Task.Run(() => NativeLibraryDirectorySource.Libraries(directories));
            _directories.Clear();
            _directories.AddRange(directories);
            _directoryCandidates = found;
            if (found.Count == 0) _queueSelectionError = S.Text(UiStrings.DebugArtifactsDirectoryEmpty);
        }
        catch (NativeLibraryDirectoryException error)
        {
            _queueSelectionError = error.Message;
        }
        finally
        {
            _readingDirectories = false;
            RenderTab();
            if (_queueSelectionError is { } said) Ui.Say(_artifactsStatus, said);
            else Ui.Say(_artifactsStatus, S.Text(UiStrings.DebugArtifactsDirectoryTitle));
        }
    }

    private async Task PrepareQueueAsync(OperationFacts? operation)
    {
        if (Target is not { } target || operation is not { IsAvailable: true } || !DebugOperations.IsValidBundleName(_targetBundle) || _preparing || _nativeJobId is not null)
        {
            Ui.Say(_artifactsStatus, Blocker(operation, DebugOperations.IsValidBundleName(_targetBundle), _preparing || _nativeJobId is not null)
                                     ?? S.Text(UiStrings.WindowsDebugNeedsInputs));
            return;
        }
        _queueSteps = operation.Steps;
        await Batch.PrepareAsync(_queue.ToArray(), target, _targetBundle);
        if (Batch.Phase == NativeLibraryBatchPhase.Review) await ReviewQueueAsync();
    }

    private IReadOnlyList<OperationStep> _queueSteps = [];

    /// <summary>The queue's review sheet: every plan, then Deploy reviewed queue.</summary>
    private async Task ReviewQueueAsync()
    {
        var batch = Batch;
        var rows = Ui.Stack(6);
        foreach (var row in batch.Rows)
        {
            var plan = row.Preparation!;
            rows.Children.Add(Ui.Stack(2,
                Ui.Text($"debug.artifacts.batch.review.{row.Source.Name}", row.Source.Name, "ArkDeckMonoStyle"),
                Ui.Text($"debug.artifacts.batch.review.{row.Source.Name}.digest", plan.PlanDigest, "ArkDeckCaptionStyle"),
                Ui.Text($"debug.artifacts.batch.review.{row.Source.Name}.elf", $"{plan.Abi} · ELF{plan.ElfClassBits} · {plan.Sha256}", "ArkDeckCaptionStyle")));
        }
        var content = Ui.Stack(8,
            Ui.Text("debug.artifacts.batch.warning", S.Text(UiStrings.DebugArtifactsBatchWarning)),
            Ui.Text("debug.artifacts.batch.review.scope", $"{batch.Target!.TargetId} · binding r{batch.Target.BindingRevision} · {batch.TargetBundle}", "ArkDeckMonoStyle"),
            rows);
        var dialog = Ui.Dialog(XamlRoot, "debug.artifacts.batch.review", S.Text(UiStrings.DebugArtifactsBatchReview), new ScrollViewer { Content = content, MaxHeight = 520 },
            S.Text(UiStrings.DebugArtifactsBatchRun), S.Text(UiStrings.DebugArtifactsSheetBack));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await batch.SubmitReviewedAsync();
        await RefreshAsync();
        Ui.Say(_artifactsStatus, S.Text("debug.artifacts.batch.phase." + Camel(batch.Phase.ToString())));
    }

    // ---- INativeLibraryDeployment: each item through the single-library path ----

    async Task<(NativeLibraryPreparation? Plan, string? Failure)> INativeLibraryDeployment.PrepareAsync(NativeLibrarySource source, TargetSummary target, string targetBundle)
    {
        string path;
        string? staged = null;
        switch (source)
        {
            case NativeLibrarySource.File file:
                path = file.Path;
                break;
            case NativeLibrarySource.Ssh ssh:
                try
                {
                    var fetched = await Task.Run(() => App.RemoteSources.FetchNativeLibraryAsync(ssh.SourceId, ssh.RelativePath));
                    path = staged = RemoteNativeLibraryStaging.Write(fetched);
                }
                catch (RemoteBuildSourceException error)
                {
                    return (null, SettingsPage.RemoteError(error));
                }
                break;
            default:
                return (null, "unknown library source");
        }
        try
        {
            var steps = _queueSteps;
            var outcome = await Task.Run(() => App.Loader.PrepareNativeLibraryAsync(target, path, targetBundle, source.Name, "hashProcessAndMaps", "autoRollback", steps,
                CancellationToken.None));
            MainWindow.Instance.Report(outcome);
            return (outcome.Prepared, outcome.Failure?.ReasonText(S));
        }
        finally
        {
            if (staged is not null) RemoteNativeLibraryStaging.Remove(staged);
        }
    }

    async Task<SubmitOutcome> INativeLibraryDeployment.SubmitAsync(NativeLibraryPreparation plan)
    {
        var submitted = await Task.Run(() => App.Loader.SubmitNativeLibraryAsync(plan));
        MainWindow.Instance.Report(submitted);
        return submitted;
    }

    async Task<(JobTerminal? Terminal, string? Failure)> INativeLibraryDeployment.RunAsync(string jobId)
    {
        var run = await Task.Run(() => App.Loader.RunJobAsync(jobId, CliCommands.ForJob(CliCommands.JobRun, jobId)));
        MainWindow.Instance.Report(run);
        return (run.Answer.Value, run.Answer.Unavailable?.ReasonText(S));
    }
}
