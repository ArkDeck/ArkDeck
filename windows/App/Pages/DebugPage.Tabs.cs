using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace ArkDeck.App.Pages;

public sealed partial class DebugPage
{
    // ---- Artifacts: one app-owned native library, planned, reviewed, then deployed ----

    private string? _libraryPath;
    private string _targetBundle = "";
    private string _libraryName = "";
    private bool _preparing;
    private NativeLibraryPreparation? _preparation;
    private string? _nativeJobId;
    private JobTerminal? _nativeTerminal;
    private string? _nativeFailure;
    private bool _remoteSource;
    private TextBlock _artifactsStatus = Ui.Status("debug.artifacts.status");

    private void ArtifactsTab(DebugState state)
    {
        var operation = state.Operation(DebugOperations.NativeLibrary);
        _artifactsStatus = Ui.Status("debug.artifacts.status");
        var target = Target;
        _tab.Children.Add(Ui.Card(Ui.Row(
            Ui.Text("debug.artifacts.target", S.Text(UiStrings.DebugArtifactsTarget), "ArkDeckCaptionStyle"),
            Ui.Text("debug.artifacts.targetScope", target is null ? S.Text(UiStrings.DebugTargetNone)
                : $"{target.TargetId} · binding r{target.BindingRevision} · {S.Text(UiStrings.DebugArtifactsTargetConfirmed)} · deviceMutation", "ArkDeckMonoStyle"))));

        // Build source.
        var source = new RadioButtons { MaxColumns = 2, Header = S.Text(UiStrings.DebugArtifactsSourceKind) };
        AutomationProperties.SetAutomationId(source, "debug.artifacts.source.kind");
        AutomationProperties.SetName(source, S.Text(UiStrings.DebugArtifactsSourceKind));
        foreach (var (tag, key) in new[] { ("local", UiStrings.DebugArtifactsSourceLocal), ("remote", UiStrings.DebugArtifactsSourceRemote) })
        {
            var option = new RadioButton { Content = S.Text(key), Tag = tag };
            AutomationProperties.SetAutomationId(option, "debug.artifacts.source." + tag);
            source.Items.Add(option);
            if ((tag == "remote") == _remoteSource) source.SelectedItem = option;
        }
        source.SelectionChanged += (_, _) =>
        {
            var remote = (source.SelectedItem as RadioButton)?.Tag as string == "remote";
            if (remote == _remoteSource) return;
            _remoteSource = remote;
            _libraryPath = null;
            _preparation = null;
            RenderTab();
        };
        var sourcePanel = Ui.Stack(8);
        AddIf(sourcePanel, AvailabilityNotice(operation));
        sourcePanel.Children.Add(Ui.Text("debug.artifacts.source.detail", S.Text(UiStrings.DebugArtifactsSourceDetail), "ArkDeckCaptionStyle"));
        sourcePanel.Children.Add(source);
        sourcePanel.Children.Add(_remoteSource
            ? Ui.Row(Ui.Button("debug.artifacts.browseRemote", S.Text(UiStrings.DebugArtifactsBrowseRemote), async (_, _) => await RemoteBrowserAsync()))
            : Ui.Row(Ui.Button("debug.artifacts.chooseLibrary", S.Text(UiStrings.DebugArtifactsChooseLibrary), async (_, _) => await ChooseLibraryAsync())));
        sourcePanel.Children.Add(Ui.Fact("debug.artifacts.selectedLibrary", S.Text(UiStrings.DebugArtifactsSelectedLibrary),
            _libraryPath is null ? S.Text(UiStrings.DebugArtifactsNoLibrary) : Path.GetFileName(_libraryPath)));
        sourcePanel.Children.Add(Ui.Text("debug.artifacts.sourceBoundary", S.Text(UiStrings.DebugArtifactsSourceBoundary), "ArkDeckCaptionStyle"));

        // Deployment inputs.
        var bundle = Field("debug.artifacts.bundle", S.Text(UiStrings.DebugArtifactsBundle), _targetBundle, "com.example.app", value =>
        {
            _targetBundle = value;
            _preparation = null;
        });
        var logical = Field("debug.artifacts.logicalName", S.Text(UiStrings.DebugArtifactsLogicalName), _libraryName, "libfeature_debug.so", value =>
        {
            _libraryName = value;
            _preparation = null;
        });
        var inputs = Ui.Stack(8, Ui.Text("debug.artifacts.destination.detail", S.Text(UiStrings.DebugArtifactsDestinationDetail), "ArkDeckCaptionStyle"),
            bundle, logical, Ui.Fact("debug.artifacts.abi", S.Text(UiStrings.DebugArtifactsAbi), S.Text(UiStrings.DebugArtifactsAbiObserved)));
        if (_targetBundle.Length > 0 && !DebugOperations.IsValidBundleName(_targetBundle))
        {
            inputs.Children.Add(Ui.Text("debug.artifacts.bundle.invalid", S.Text(UiStrings.DebugArtifactsBundleInvalid)));
        }
        if (_libraryName.Length > 0 && !DebugOperations.IsValidNativeLibraryName(_libraryName))
        {
            inputs.Children.Add(Ui.Text("debug.artifacts.logicalName.invalid", S.Text(UiStrings.DebugArtifactsLogicalNameInvalid)));
        }
        inputs.Children.Add(Ui.Disclosure("debug.artifacts.advanced", S.Text(UiStrings.DebugArtifactsAdvanced), Ui.Stack(6,
            Ui.Fact("debug.artifacts.verification", S.Text(UiStrings.DebugArtifactsVerification), S.Text(UiStrings.DebugArtifactsVerifyMaps)),
            Ui.Fact("debug.artifacts.rollback", S.Text(UiStrings.DebugArtifactsRollback), S.Text(UiStrings.DebugArtifactsRollbackAuto)),
            Ui.Text("debug.artifacts.policy.required", S.Text(UiStrings.DebugArtifactsPolicyRequired), "ArkDeckCaptionStyle"))));

        _tab.Children.Add(Section("debug.artifacts.source", UiStrings.DebugArtifactsSourceTitle, operation, true, sourcePanel));
        _tab.Children.Add(Section("debug.artifacts.destination", UiStrings.DebugArtifactsDestinationTitle, null, false, inputs));

        // Review and run.
        var review = Ui.Stack(8, Ui.Text("debug.artifacts.review.detail", S.Text(UiStrings.DebugArtifactsReviewDetail), "ArkDeckCaptionStyle"));
        if (_preparation is { } plan)
        {
            review.Children.Add(Ui.Stack(4,
                Ui.Text("debug.artifacts.planReady", S.Text(UiStrings.DebugArtifactsPlanReady)),
                Ui.Fact("debug.artifacts.plan.elf", "ELF", $"{plan.Abi} · ELF{plan.ElfClassBits} · machine {plan.Machine}"),
                Ui.Fact("debug.artifacts.plan.buildId", "Build ID", plan.BuildId),
                Ui.Fact("debug.artifacts.plan.sha256", "SHA-256", plan.Sha256)));
        }
        if (_preparing) review.Children.Add(Ui.Progress("debug.artifacts.preparing", S.Text(UiStrings.DebugArtifactsPreparing)));
        if (_nativeJobId is { } running)
        {
            review.Children.Add(Ui.Stack(2, Ui.Text("debug.artifacts.running", S.Text(UiStrings.DebugArtifactsRunning)),
                Ui.Text("debug.artifacts.running.detail", running, "ArkDeckMonoStyle")));
        }
        if (_nativeTerminal is { } terminal)
        {
            review.Children.Add(Ui.Stack(2,
                Ui.Text("debug.artifacts.terminal", S.Text(terminal.Succeeded ? UiStrings.DebugArtifactsVerified : UiStrings.DebugArtifactsNotVerified)),
                Ui.Text("debug.artifacts.terminal.latest", terminal.Timeline.LastOrDefault() ?? "", "ArkDeckMonoStyle")));
        }
        if (_nativeFailure is { } failure) review.Children.Add(Ui.Text("debug.artifacts.failure", failure));
        var actions = Ui.Row();
        if (_nativeJobId is { } active)
        {
            actions.Children.Add(Ui.Button("debug.artifacts.cancel", S.Text(UiStrings.DebugActionCancel), async (_, _) => await CancelAsync(active, _artifactsStatus)));
        }
        else
        {
            actions.Children.Add(Ui.Button("debug.artifacts.preview",
                S.Text(_preparation is null ? UiStrings.DebugArtifactsPreview : UiStrings.DebugArtifactsReopenPlan), async (_, _) => await PreviewNativeAsync(operation), accent: true));
        }
        if (_nativeTerminal?.State == "succeeded")
        {
            actions.Children.Add(Ui.Button("debug.artifacts.openLogs", S.Text(UiStrings.DebugArtifactsOpenLogs), (_, _) => SelectTab("logs")));
        }
        review.Children.Add(actions);
        review.Children.Add(_artifactsStatus);
        _tab.Children.Add(Section("debug.artifacts.review", UiStrings.DebugArtifactsReviewTitle, null, false, review));
        _tab.Children.Add(Ui.Card(Ui.Text("debug.artifacts.productionBoundary", S.Text(UiStrings.DebugArtifactsProductionBoundary))));
        var results = state.ArtifactsOf(DebugOperations.NativeLibrary, _targetId);
        if (results.Count > 0)
        {
            var list = Ui.Stack(6);
            foreach (var (jobId, artifact) in results) list.Children.Add(ArtifactRow("debug.artifacts", jobId, artifact, Ui.Stack(4)));
            _tab.Children.Add(Section("debug.artifacts.results", UiStrings.DebugArtifactsResultsTitle, null, false, list));
        }
        _tab.Children.Add(RecentJobs(state, "artifacts", DebugOperations.NativeLibrary));
    }

    private async Task ChooseLibraryAsync()
    {
        var picker = new FileOpenPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".so");
        var picked = await picker.PickSingleFileAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
        _libraryPath = picked.Path;
        _libraryName = Path.GetFileName(picked.Path);
        _preparation = null;
        RenderTab();
    }

    /// <summary>The macOS remote build browser. Remote build servers are an App-side SSH
    /// setting the Windows App does not have, so the browser opens on its no-servers state.</summary>
    private async Task RemoteBrowserAsync()
    {
        var content = Ui.Stack(6,
            Ui.Text("debug.artifacts.remoteBrowser.detail", S.Text(UiStrings.DebugArtifactsRemoteBrowserDetail), "ArkDeckCaptionStyle"),
            Ui.Heading("debug.artifacts.remoteBrowser.empty.title", S.Text(UiStrings.DebugArtifactsRemoteBrowserEmptyTitle), AutomationHeadingLevel.Level3),
            Ui.Text("debug.artifacts.remoteBrowser.empty.detail", S.Text(UiStrings.DebugArtifactsRemoteBrowserEmptyDetail)),
            Ui.Text("debug.artifacts.remoteBrowser.windows", S.Text(UiStrings.WindowsDebugRemoteUnavailable), "ArkDeckCaptionStyle"));
        var dialog = Ui.Dialog(XamlRoot, "debug.artifacts.remoteBrowser", S.Text(UiStrings.DebugArtifactsRemoteBrowserTitle), content,
            S.Text(UiStrings.DebugArtifactsSourceLocal), S.Text(UiStrings.DebugArtifactsRemoteBrowserCancel));
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            _remoteSource = false;
            RenderTab();
        }
    }

    private async Task PreviewNativeAsync(OperationFacts? operation)
    {
        if (_preparation is { } ready)
        {
            await ReviewNativeAsync(ready);
            return;
        }
        var inputsValid = _libraryPath is not null && DebugOperations.IsValidBundleName(_targetBundle) && DebugOperations.IsValidNativeLibraryName(_libraryName);
        if (Blocker(operation, inputsValid, _preparing || _nativeJobId is not null) is { } blocked)
        {
            Ui.Say(_artifactsStatus, blocked);
            return;
        }
        var target = Target!;
        var path = _libraryPath!;
        _preparing = true;
        _nativeFailure = null;
        _nativeTerminal = null;
        RenderTab();
        Ui.Say(_artifactsStatus, S.Text(UiStrings.DebugArtifactsPreparing));
        var steps = operation!.Steps;
        var outcome = await Task.Run(() => App.Loader.PrepareNativeLibraryAsync(target, path, _targetBundle, _libraryName, "hashProcessAndMaps", "autoRollback", steps,
            CancellationToken.None));
        MainWindow.Instance.Report(outcome);
        _preparing = false;
        _preparation = outcome.Prepared;
        _nativeFailure = outcome.Failure?.ReasonText(S);
        RenderTab();
        Ui.Say(_artifactsStatus, _nativeFailure ?? S.Text(UiStrings.DebugArtifactsPlanReady));
        if (_preparation is { } prepared) await ReviewNativeAsync(prepared);
    }

    /// <summary>The plan sheet: what will change, the Runtime's plan digest and its steps; Run
    /// submits exactly the reviewed request.</summary>
    private async Task ReviewNativeAsync(NativeLibraryPreparation plan)
    {
        var steps = Ui.Stack(4);
        var index = 0;
        foreach (var step in plan.Steps)
        {
            index++;
            steps.Children.Add(Ui.Stack(2, Ui.Text($"debug.artifacts.sheet.step.{step.Id}", $"{index}. {step.Id}", "ArkDeckMonoStyle"),
                Ui.Text($"debug.artifacts.sheet.step.{step.Id}.effect", EffectLine(step), "ArkDeckCaptionStyle")));
        }
        var content = Ui.Stack(8,
            Ui.Text("debug.artifacts.sheet.warning", S.Text(UiStrings.DebugArtifactsSheetWarning)),
            Ui.Fact("debug.artifacts.sheet.target", S.Text(UiStrings.DebugArtifactsSheetTarget), $"{plan.TargetId} · binding r{plan.BindingRevision}"),
            Ui.Fact("debug.artifacts.sheet.library", S.Text(UiStrings.DebugArtifactsSheetLibrary), plan.LibraryName),
            Ui.Fact("debug.artifacts.sheet.bundle", S.Text(UiStrings.DebugArtifactsSheetBundle), plan.TargetBundle),
            Ui.Fact("debug.artifacts.sheet.effect", "effect", "deviceMutation"),
            Ui.Fact("debug.artifacts.sheet.verification", S.Text(UiStrings.DebugArtifactsSheetVerification), S.Text(UiStrings.DebugArtifactsVerifyMaps)),
            Ui.Fact("debug.artifacts.sheet.rollback", S.Text(UiStrings.DebugArtifactsSheetRollback), S.Text(UiStrings.DebugArtifactsRollbackAuto)),
            Ui.Fact("debug.artifacts.sheet.digest", S.Text(UiStrings.DebugArtifactsSheetDigest), plan.PlanDigest),
            Ui.Heading("debug.artifacts.sheet.steps", S.Text(UiStrings.DebugArtifactsSheetSteps), AutomationHeadingLevel.Level3),
            steps);
        var dialog = Ui.Dialog(XamlRoot, "debug.artifacts.sheet", S.Text(UiStrings.DebugArtifactsSheetTitle), new ScrollViewer { Content = content, MaxHeight = 520 },
            S.Text(UiStrings.DebugArtifactsSheetRun), S.Text(UiStrings.DebugArtifactsSheetBack));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (_nativeJobId is not null) return;
        _nativeFailure = null;
        var submitted = await Task.Run(() => App.Loader.SubmitNativeLibraryAsync(plan));
        var (terminal, failure) = await RunToEndAsync(submitted, jobId =>
        {
            _nativeJobId = jobId;
            RenderTab();
            Ui.Say(_artifactsStatus, S.Text(UiStrings.DebugArtifactsRunning));
        });
        _nativeJobId = null;
        _nativeTerminal = terminal;
        _nativeFailure = failure?.ReasonText(S);
        await RefreshAsync();
        Ui.Say(_artifactsStatus, _nativeFailure ?? S.Text(terminal!.Succeeded ? UiStrings.DebugArtifactsVerified : UiStrings.DebugArtifactsNotVerified));
    }

    // ---- Logs: a bounded HiLog capture ----

    private int _logSeconds = 30;
    private string _logLevel = "Warn";
    private readonly Dictionary<string, string> _logFilters = new(StringComparer.Ordinal)
    {
        ["domain"] = "", ["tag"] = "", ["pid"] = "", ["keyword"] = "", ["marker"] = "",
    };
    private string? _logJobId;
    private JobTerminal? _logTerminal;
    private string? _logFailure;
    private bool _viewportPaused;
    private TextBlock _logsStatus = Ui.Status("debug.logs.status");

    private IReadOnlyList<string> LogFilterTokens() =>
        _logFilters.Where(f => f.Value.Length > 0 && DebugOperations.IsSafeHilogComponent(f.Value)).Select(f => $"{f.Key}:{f.Value}")
            .Append("level:" + _logLevel.ToLowerInvariant()).ToArray();

    private string[] InvalidLogFilters() =>
        _logFilters.Where(f => f.Value.Length > 0 && !DebugOperations.IsSafeHilogComponent(f.Value)).Select(f => f.Key).ToArray();

    private void LogsTab(DebugState state)
    {
        var operation = state.Operation(DebugOperations.CaptureDiagnostics);
        _logsStatus = Ui.Status("debug.logs.status");
        var capture = Ui.Stack(8);
        AddIf(capture, AvailabilityNotice(operation));
        capture.Children.Add(Ui.Fact("debug.logs.target", S.Text(UiStrings.DebugLogsTarget), _targetId ?? S.Text(UiStrings.DebugTargetNone)));
        var duration = new NumberBox
        {
            Header = S.Format(UiStrings.DebugLogsDuration, _logSeconds), Minimum = 1, Maximum = 600, Value = _logSeconds,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, SmallChange = 1, LargeChange = 30,
        };
        AutomationProperties.SetAutomationId(duration, "debug.logs.duration");
        AutomationProperties.SetName(duration, S.Format(UiStrings.DebugLogsDuration, _logSeconds));
        duration.ValueChanged += (_, e) =>
        {
            if (double.IsNaN(e.NewValue)) return;
            _logSeconds = (int)Math.Clamp(e.NewValue, 1, 600);
            duration.Header = S.Format(UiStrings.DebugLogsDuration, _logSeconds);
            AutomationProperties.SetName(duration, S.Format(UiStrings.DebugLogsDuration, _logSeconds));
        };
        capture.Children.Add(duration);
        var level = new RadioButtons { MaxColumns = 3, Header = S.Text(UiStrings.DebugLogsLevel) };
        AutomationProperties.SetAutomationId(level, "debug.logs.level");
        AutomationProperties.SetName(level, S.Text(UiStrings.DebugLogsLevel));
        foreach (var (tag, glyph) in new[] { ("Info", "I"), ("Warn", "W"), ("Error", "E") })
        {
            var option = new RadioButton { Content = glyph, Tag = tag };
            AutomationProperties.SetAutomationId(option, "debug.logs.level." + tag.ToLowerInvariant());
            AutomationProperties.SetName(option, tag);
            level.Items.Add(option);
            if (tag == _logLevel) level.SelectedItem = option;
        }
        level.SelectionChanged += (_, _) =>
        {
            if (level.SelectedItem is RadioButton { Tag: string tag }) _logLevel = tag;
        };
        capture.Children.Add(level);
        foreach (var (name, key, prompt) in new[]
                 {
                     ("domain", UiStrings.DebugLogsDomain, "0xD003900"), ("tag", UiStrings.DebugLogsTag, "ArkUI"), ("pid", UiStrings.DebugLogsPid, "1234"),
                     ("keyword", UiStrings.DebugLogsKeyword, "render"), ("marker", UiStrings.DebugLogsMarker, "checkout-start"),
                 })
        {
            capture.Children.Add(Field("debug.logs." + name, S.Text(key), _logFilters[name], prompt, value => _logFilters[name] = value));
        }
        capture.Children.Add(Ui.Text("debug.logs.filters.note", S.Text(UiStrings.DebugLogsFiltersNote), "ArkDeckCaptionStyle"));
        if (InvalidLogFilters() is { Length: > 0 } invalid)
        {
            capture.Children.Add(Ui.Text("debug.logs.filters.invalid", S.Format(UiStrings.DebugLogsFiltersInvalid, string.Join(", ", invalid))));
        }
        capture.Children.Add(Ui.Text("debug.logs.rawSave", S.Text(UiStrings.DebugLogsRawSave), "ArkDeckCaptionStyle"));
        var request = Ui.Disclosure("debug.logs.request", S.Text(UiStrings.DebugLogsRequestTitle), Ui.Stack(4,
                Ui.Fact("debug.logs.request.operation", S.Text(UiStrings.DebugAvailabilityOperation), DebugOperations.CaptureDiagnostics),
                Ui.Fact("debug.logs.request.duration", "durationSeconds", _logSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                Ui.Fact("debug.logs.request.filters", "hilogFilters", "[" + string.Join(", ", LogFilterTokens()) + "]"),
                Ui.Fact("debug.logs.request.uiDump", "uiDump", "false"),
                Ui.Text("debug.logs.request.effect", S.Format(UiStrings.DebugAvailabilityEffect, operation?.MinimumEffect ?? ""), "ArkDeckCaptionStyle")));
        capture.Children.Add(request);
        var actions = _logJobId is { } active
            ? Ui.Row(Ui.Button("debug.logs.cancel", S.Text(UiStrings.DebugActionCancel), async (_, _) => await CancelAsync(active, _logsStatus)),
                Ui.Progress("debug.logs.activeJob", S.Format(UiStrings.WindowsDebugRunning, active)))
            : Ui.Row(Ui.Button("debug.logs.start", S.Text(UiStrings.DebugLogsStart), async (_, _) => await StartLogsAsync(operation), accent: true));
        capture.Children.Add(actions);
        if (_logFailure is { } failure) capture.Children.Add(Ui.Text("debug.logs.failure", failure));
        else if (_logTerminal is { } terminal)
        {
            capture.Children.Add(TerminalLine("debug.logs.terminal", terminal));
            if (terminal.FailureCode is { } code) capture.Children.Add(Ui.Text("debug.logs.typedFailure", FailureText(code)));
        }
        capture.Children.Add(_logsStatus);
        _tab.Children.Add(Section("debug.logs.capture", UiStrings.DebugLogsCaptureTitle, operation, true, capture));

        // One destructive buffer action exists in the design; no published operation runs it,
        // so the section states why instead of offering a disabled menu.
        _tab.Children.Add(Section("debug.logs.destructive", UiStrings.DebugLogsDestructiveTitle, null, false,
            Ui.Text("debug.logs.destructive.scope", S.Text(UiStrings.DebugLogsDestructiveScope), "ArkDeckCaptionStyle"),
            Ui.Text("debug.logs.destructive.blocked", S.Text(UiStrings.DebugBlockedBufferOperation))));

        var viewport = Ui.Stack(4);
        AutomationProperties.SetAutomationId(viewport, "debug.logs.viewport");
        if (_logTerminal is { Timeline.Count: > 0 } shown)
        {
            var index = 0;
            foreach (var entry in shown.Timeline.TakeLast(12)) viewport.Children.Add(Ui.Text($"debug.logs.viewport.{index++}", entry, "ArkDeckMonoStyle"));
        }
        else
        {
            viewport.Children.Add(Ui.Text("debug.logs.live.empty", S.Text(UiStrings.DebugLogsLiveEmpty)));
            viewport.Children.Add(Ui.Text("debug.logs.live.empty.detail", S.Text(UiStrings.DebugLogsLiveEmptyDetail), "ArkDeckCaptionStyle"));
        }
        var live = Ui.Stack(8);
        if (_logJobId is not null)
        {
            // A local viewport state only: it never cancels or suspends the Runtime Job.
            live.Children.Add(Ui.Row(Ui.Button("debug.logs.pauseViewport", S.Text(_viewportPaused ? UiStrings.DebugLogsResume : UiStrings.DebugLogsPause), (_, _) =>
            {
                _viewportPaused = !_viewportPaused;
                RenderTab();
            })));
        }
        live.Children.Add(viewport);
        live.Children.Add(Ui.Text("debug.logs.viewport.bounded", S.Text(UiStrings.DebugLogsViewportBounded), "ArkDeckCaptionStyle"));
        _tab.Children.Add(Section("debug.logs.live", UiStrings.DebugLogsLiveTitle, null, false, live));

        var shards = Ui.Stack(6);
        var rows = state.ArtifactsOf(DebugOperations.CaptureDiagnostics, _targetId);
        if (rows.Count == 0)
        {
            shards.Children.Add(Ui.Text("debug.logs.shards.empty", S.Text(UiStrings.DebugLogsShardsEmpty)));
            shards.Children.Add(Ui.Text("debug.logs.shards.empty.detail", S.Text(UiStrings.DebugLogsShardsEmptyDetail), "ArkDeckCaptionStyle"));
        }
        foreach (var (jobId, artifact) in rows) shards.Children.Add(ArtifactRow("debug.logs", jobId, artifact, Ui.Stack(4)));
        shards.Children.Add(Ui.Text("debug.logs.exportBoundary", S.Text(UiStrings.DebugLogsExportBoundary), "ArkDeckCaptionStyle"));
        if (operation is { OutputByteBudget: > 0 } budget)
        {
            shards.Children.Add(Ui.Text("debug.logs.storage.totalBudget",
                S.Format(UiStrings.DebugLogsStorageTotalBudget, S.Format(UiStrings.WindowsBytes, budget.OutputByteBudget.ToString("N0", System.Globalization.CultureInfo.InvariantCulture))),
                "ArkDeckCaptionStyle"));
        }
        _tab.Children.Add(Section("debug.logs.shards", UiStrings.DebugLogsShardsTitle, null, false, shards));
        _tab.Children.Add(RecentJobs(state, "logs", DebugOperations.CaptureDiagnostics));
    }

    private async Task StartLogsAsync(OperationFacts? operation)
    {
        if (Blocker(operation, InvalidLogFilters().Length == 0, _logJobId is not null) is { } blocked)
        {
            Ui.Say(_logsStatus, blocked);
            return;
        }
        var target = Target!;
        var filters = LogFilterTokens();
        _logFailure = null;
        _logTerminal = null;
        var submitted = await Task.Run(() => App.Loader.SubmitLogsAsync(target, _logSeconds, filters));
        var (terminal, failure) = await RunToEndAsync(submitted, jobId =>
        {
            _logJobId = jobId;
            RenderTab();
            Ui.Say(_logsStatus, S.Format(UiStrings.WindowsDebugRunning, jobId));
        });
        _logJobId = null;
        _logTerminal = terminal;
        _logFailure = failure?.ReasonText(S);
        await RefreshAsync();
        Ui.Say(_logsStatus, _logFailure ?? $"{terminal!.State} · {terminal.JobId}");
    }

    // ---- Apps: one HAP lifecycle ----

    private string? _hapPath;
    private readonly List<string> _additionalHaps = [];
    private string? _hapSelectionError;
    private string _bundleName = "";
    private string _abilityName = "";
    private string _cleanupPolicy = "uninstall";
    private string _postRunState = "stopped";
    private bool _captureDiagnostics = true;
    private int _diagnosticsSeconds = 30;
    private bool _importingHap;
    private string? _hapJobId;
    private JobTerminal? _hapTerminal;
    private string? _hapFailure;
    private TextBlock _appsStatus = Ui.Status("debug.apps.status");

    private string? InvalidIdentityFields()
    {
        var invalid = new List<string>();
        if (_bundleName.Length > 0 && !DebugOperations.IsValidBundleName(_bundleName)) invalid.Add(S.Text(UiStrings.DebugAppsBundle));
        if (_abilityName.Length > 0 && !DebugOperations.IsValidAbilityName(_abilityName)) invalid.Add(S.Text(UiStrings.DebugAppsAbility));
        return invalid.Count == 0 ? null : string.Join(", ", invalid);
    }

    private void AppsTab(DebugState state)
    {
        var operation = state.Operation(DebugOperations.DebugHap);
        _appsStatus = Ui.Status("debug.apps.status");
        var busy = _importingHap || _hapJobId is not null;

        var package = Ui.Stack(8);
        AddIf(package, AvailabilityNotice(operation));
        package.Children.Add(Ui.Fact("debug.apps.target", S.Text(UiStrings.DebugAppsTarget), _targetId ?? S.Text(UiStrings.DebugTargetNone)));
        package.Children.Add(Ui.Row(Ui.Button("debug.apps.entry.choose", S.Text(UiStrings.DebugAppsChooseHAP), async (_, _) =>
        {
            if (busy) Ui.Say(_appsStatus, S.Text(UiStrings.WindowsDebugBusy));
            else await ChoosePackagesAsync(additional: false);
        })));
        package.Children.Add(Ui.Text("debug.apps.entry.name", _hapPath is null ? S.Text(UiStrings.DebugAppsNoHAP) : Path.GetFileName(_hapPath), "ArkDeckMonoStyle"));
        package.Children.Add(Ui.Text("debug.apps.additional.title", S.Text(UiStrings.DebugAppsAdditionalTitle)));
        package.Children.Add(Ui.Text("debug.apps.additional.note", S.Text(UiStrings.DebugAppsAdditionalNote), "ArkDeckCaptionStyle"));
        for (var i = 0; i < _additionalHaps.Count; i++)
        {
            var index = i;
            var name = Path.GetFileName(_additionalHaps[i]);
            var remove = Ui.Button($"debug.apps.additional.remove.{i}", S.Text(UiStrings.DebugAppsAdditionalRemove), (_, _) =>
            {
                if (busy) return;
                _additionalHaps.RemoveAt(index);
                _hapSelectionError = null;
                RenderTab();
            });
            AutomationProperties.SetName(remove, S.Format(UiStrings.DebugAppsAdditionalRemoveNamed, name));
            package.Children.Add(Ui.Row(Ui.Text($"debug.apps.additional.file.{i}", name, "ArkDeckMonoStyle"), remove));
        }
        package.Children.Add(Ui.Row(Ui.Button("debug.apps.additional.add", S.Text(UiStrings.DebugAppsAdditionalAdd), async (_, _) =>
        {
            if (_hapPath is null) Ui.Say(_appsStatus, S.Text(UiStrings.DebugAppsNoHAP));
            else if (busy) Ui.Say(_appsStatus, S.Text(UiStrings.WindowsDebugBusy));
            else if (_additionalHaps.Count >= DebugOperations.MaximumAdditionalPackages) Ui.Say(_appsStatus, S.Text(UiStrings.DebugAppsSelectionTooManyPackages));
            else await ChoosePackagesAsync(additional: true);
        })));
        if (_hapPath is not null)
        {
            package.Children.Add(Ui.Row(Ui.Button("debug.apps.packages.clear", S.Text(UiStrings.DebugAppsClearSelection), (_, _) =>
            {
                if (busy) return;
                _hapPath = null;
                _additionalHaps.Clear();
                _hapSelectionError = null;
                RenderTab();
            })));
        }
        if (_hapSelectionError is { } selectionError) package.Children.Add(Ui.Text("debug.apps.selection.error", selectionError));
        package.Children.Add(Ui.Text("debug.apps.localOnly", S.Text(UiStrings.DebugAppsLocalOnly), "ArkDeckCaptionStyle"));
        _tab.Children.Add(Section("debug.apps.package", UiStrings.DebugAppsPackageTitle, operation, true, package));

        var identity = Ui.Stack(8,
            Field("debug.apps.bundle", S.Text(UiStrings.DebugAppsBundle), _bundleName, "com.example.app", value => _bundleName = value),
            Field("debug.apps.ability", S.Text(UiStrings.DebugAppsAbility), _abilityName, "EntryAbility", value => _abilityName = value));
        if (InvalidIdentityFields() is { } invalid) identity.Children.Add(Ui.Text("debug.apps.identity.invalid", S.Format(UiStrings.DebugTypedInvalidIdentifier, invalid)));
        identity.Children.Add(Ui.Text("debug.apps.identity.note", S.Text(UiStrings.DebugAppsIdentityNote), "ArkDeckCaptionStyle"));
        _tab.Children.Add(Section("debug.apps.identity", UiStrings.DebugAppsIdentityTitle, null, false, identity));

        var lifecycle = Ui.Stack(8, Ui.Fact("debug.apps.installPolicy", S.Text(UiStrings.DebugAppsInstallPolicy), S.Text(UiStrings.DebugAppsInstallReplace)),
            Choice("debug.apps.cleanupPolicy", S.Text(UiStrings.DebugAppsCleanupPolicy), _cleanupPolicy,
                [("uninstall", S.Text(UiStrings.DebugAppsCleanupUninstall)), ("retain", S.Text(UiStrings.DebugAppsCleanupRetain))], value =>
                {
                    _cleanupPolicy = value;
                    RenderTab();
                }),
            Choice("debug.apps.postRun", S.Text(UiStrings.DebugAppsPostRun), _postRunState,
                [("stopped", S.Text(UiStrings.DebugAppsPostRunStopped)), ("running", S.Text(UiStrings.DebugAppsPostRunRunning))], value =>
                {
                    _postRunState = value;
                    RenderTab();
                }));
        if (_cleanupPolicy == "uninstall" && _postRunState == "running")
        {
            lifecycle.Children.Add(Ui.Text("debug.apps.runningCleanupHint", S.Text(UiStrings.DebugAppsRunningCleanupHint)));
        }
        var capture = new ToggleSwitch { Header = S.Text(UiStrings.DebugAppsCaptureDiagnostics), IsOn = _captureDiagnostics };
        AutomationProperties.SetAutomationId(capture, "debug.apps.captureDiagnostics");
        AutomationProperties.SetName(capture, S.Text(UiStrings.DebugAppsCaptureDiagnostics));
        capture.Toggled += (_, _) =>
        {
            _captureDiagnostics = capture.IsOn;
            RenderTab();
        };
        lifecycle.Children.Add(capture);
        if (_captureDiagnostics)
        {
            var seconds = new NumberBox
            {
                Header = S.Format(UiStrings.DebugAppsDiagnosticsDuration, _diagnosticsSeconds), Minimum = 1, Maximum = 300, Value = _diagnosticsSeconds,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, SmallChange = 1, LargeChange = 30,
            };
            AutomationProperties.SetAutomationId(seconds, "debug.apps.diagnosticsDuration");
            AutomationProperties.SetName(seconds, S.Format(UiStrings.DebugAppsDiagnosticsDuration, _diagnosticsSeconds));
            seconds.ValueChanged += (_, e) =>
            {
                if (double.IsNaN(e.NewValue)) return;
                _diagnosticsSeconds = (int)Math.Clamp(e.NewValue, 1, 300);
                seconds.Header = S.Format(UiStrings.DebugAppsDiagnosticsDuration, _diagnosticsSeconds);
                AutomationProperties.SetName(seconds, S.Format(UiStrings.DebugAppsDiagnosticsDuration, _diagnosticsSeconds));
            };
            lifecycle.Children.Add(seconds);
        }
        lifecycle.Children.Add(Ui.Stack(2, Ui.Text("debug.apps.mutationScope", S.Text(UiStrings.DebugAppsMutationScope)),
            Ui.Text("debug.apps.mutationDetail", S.Text(UiStrings.DebugAppsMutationDetail), "ArkDeckCaptionStyle")));
        _tab.Children.Add(Section("debug.apps.lifecycle", UiStrings.DebugAppsLifecycleTitle, null, false, lifecycle));

        var plan = Ui.Stack(8);
        var request = Ui.Disclosure("debug.apps.request", S.Text(UiStrings.DebugLogsRequestTitle), Ui.Stack(4,
                Ui.Fact("debug.apps.request.operation", S.Text(UiStrings.DebugAvailabilityOperation), DebugOperations.DebugHap),
                Ui.Fact("debug.apps.request.package", S.Text(UiStrings.DebugAppsPackageTitle), _hapPath is null ? "—" : Path.GetFileName(_hapPath)),
                Ui.Fact("debug.apps.request.additional", S.Text(UiStrings.DebugAppsAdditionalTitle), _additionalHaps.Count == 0 ? "—" : string.Join("\n", _additionalHaps.Select(Path.GetFileName))),
                Ui.Fact("debug.apps.request.bundle", "bundleName", _bundleName.Length == 0 ? "—" : _bundleName),
                Ui.Fact("debug.apps.request.ability", "abilityName", _abilityName.Length == 0 ? "—" : _abilityName),
                Ui.Fact("debug.apps.request.install", "installPolicy", "installOrReplace"),
                Ui.Fact("debug.apps.request.cleanup", "cleanupPolicy", _cleanupPolicy),
                Ui.Fact("debug.apps.request.postRun", "postRunAbilityState", _postRunState),
                Ui.Fact("debug.apps.request.capture", "captureDiagnostics", _captureDiagnostics ? "true" : "false"),
                Ui.Fact("debug.apps.request.seconds", "diagnosticsDurationSeconds", _diagnosticsSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                Ui.Fact("debug.apps.request.portForward", "portForwardProfile", "none")));
        plan.Children.Add(request);
        foreach (var step in operation?.Steps ?? [])
        {
            var line = step.IsOptional ? $"{EffectLine(step)} · {S.Text(UiStrings.DebugOptional)}" : EffectLine(step);
            plan.Children.Add(Ui.Stack(2, Ui.Text($"debug.apps.step.{step.Id}", step.Id, "ArkDeckMonoStyle"),
                Ui.Text($"debug.apps.step.{step.Id}.effect", line, "ArkDeckCaptionStyle")));
        }
        if (_importingHap || _hapJobId is not null)
        {
            var row = Ui.Row(Ui.Progress("debug.apps.progress", S.Text(_hapJobId is null ? UiStrings.DebugAppsImporting : UiStrings.DebugAppsRunning)));
            if (_hapJobId is { } active)
            {
                row.Children.Add(Ui.Text("debug.apps.activeJob", active, "ArkDeckMonoStyle"));
                row.Children.Add(Ui.Button("debug.apps.cancel", S.Text(UiStrings.DebugActionCancel), async (_, _) => await CancelAsync(active, _appsStatus)));
            }
            plan.Children.Add(row);
        }
        else
        {
            plan.Children.Add(Ui.Row(Ui.Button("debug.apps.run", S.Text(UiStrings.DebugAppsRun), async (_, _) => await RunHapAsync(operation), accent: true)));
        }
        if (_hapFailure is { } failure) plan.Children.Add(Ui.Text("debug.apps.failure", failure));
        if (_hapTerminal is { } terminal)
        {
            plan.Children.Add(TerminalLine("debug.apps.terminal", terminal));
            if (terminal.FailureCode is { } code) plan.Children.Add(Ui.Text("debug.apps.typedFailure", FailureText(code)));
        }
        plan.Children.Add(_appsStatus);
        _tab.Children.Add(Section("debug.apps.plan", UiStrings.DebugAppsPlanTitle, null, false, plan));

        var inventory = Ui.Stack(6);
        if (state.Probe?.Value is { Packages.Count: > 0 } probe && probe.TargetId == _targetId)
        {
            foreach (var name in probe.Packages)
            {
                inventory.Children.Add(Ui.Text($"debug.apps.inventory.{name}",
                    $"{name} · {S.Text(UiStrings.DebugAppsInventoryPid)}: {S.Text(UiStrings.DebugAvailabilityUnavailable)} · {S.Text(UiStrings.DebugAppsInventoryDebuggable)}: {S.Text(UiStrings.DebugAvailabilityUnavailable)}",
                    "ArkDeckMonoStyle"));
            }
            if (probe.Warnings.Count > 0) inventory.Children.Add(Ui.Text("debug.apps.inventory.warnings", string.Join(" · ", probe.Warnings), "ArkDeckMonoStyle"));
        }
        else
        {
            inventory.Children.Add(Ui.Text("debug.apps.inventory.empty", S.Text(UiStrings.DebugAppsInventoryEmpty)));
            inventory.Children.Add(Ui.Text("debug.apps.inventory.empty.detail",
                state.Probe?.Unavailable?.ReasonText(S) ?? S.Text(UiStrings.DebugAppsInventoryEmptyDetail), "ArkDeckCaptionStyle"));
        }
        // Per-package start, stop and uninstall have no published operation: the reason, not
        // three disabled buttons.
        inventory.Children.Add(Ui.Text("debug.apps.inventory.blocked", S.Text(UiStrings.DebugBlockedPackageLifecycle), "ArkDeckCaptionStyle"));
        _tab.Children.Add(Section("debug.apps.inventory", UiStrings.DebugAppsInventoryTitle, null, false, inventory));
        var artifacts = state.ArtifactsOf(DebugOperations.DebugHap, _targetId);
        if (artifacts.Count > 0)
        {
            var list = Ui.Stack(6);
            foreach (var (jobId, artifact) in artifacts) list.Children.Add(ArtifactRow("debug.apps", jobId, artifact, Ui.Stack(4)));
            _tab.Children.Add(Section("debug.apps.artifacts", UiStrings.DebugAppsArtifactsTitle, null, false, list));
        }
        _tab.Children.Add(RecentJobs(state, "apps", DebugOperations.DebugHap));
    }

    private async Task ChoosePackagesAsync(bool additional)
    {
        var picker = new FileOpenPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".hap");
        if (additional) picker.FileTypeFilter.Add(".hsp");
        var paths = additional
            ? (await picker.PickMultipleFilesAsync()).Select(f => f.Path).Where(p => !string.IsNullOrEmpty(p)).ToArray()
            : (await picker.PickSingleFileAsync()) is { Path: { Length: > 0 } single } ? [single] : [];
        if (paths.Length == 0) return;
        var entry = additional ? _hapPath! : paths[0];
        var extra = additional ? _additionalHaps.Concat(paths).ToList() : _additionalHaps.ToList();
        if (DebugOperations.PackageSelectionFailure(entry, extra) is { } reason)
        {
            _hapSelectionError = S.Text("debug.apps.selection." + reason);
        }
        else
        {
            _hapPath = entry;
            _additionalHaps.Clear();
            _additionalHaps.AddRange(extra);
            _hapSelectionError = null;
        }
        RenderTab();
    }

    private async Task RunHapAsync(OperationFacts? operation)
    {
        var inputsValid = _hapPath is not null && _bundleName.Length > 0 && _abilityName.Length > 0 && InvalidIdentityFields() is null && _hapSelectionError is null;
        if (Blocker(operation, inputsValid, _importingHap || _hapJobId is not null) is { } blocked)
        {
            Ui.Say(_appsStatus, _hapPath is null && Target is not null && operation is { IsAvailable: true } ? S.Text(UiStrings.DebugAppsNoHAP) : blocked);
            return;
        }
        var target = Target!;
        var (entry, extra) = (_hapPath!, _additionalHaps.ToArray());
        _importingHap = true;
        _hapFailure = null;
        _hapTerminal = null;
        RenderTab();
        Ui.Say(_appsStatus, S.Text(UiStrings.DebugAppsImporting));
        var submitted = await Task.Run(() => App.Loader.SubmitHapAsync(target, entry, extra, _bundleName, _abilityName, _cleanupPolicy, _postRunState,
            _captureDiagnostics, _diagnosticsSeconds, CancellationToken.None));
        _importingHap = false;
        var (terminal, failure) = await RunToEndAsync(submitted, jobId =>
        {
            _hapJobId = jobId;
            RenderTab();
            Ui.Say(_appsStatus, S.Text(UiStrings.DebugAppsRunning));
        });
        _hapJobId = null;
        _hapTerminal = terminal;
        _hapFailure = failure?.ReasonText(S);
        await RefreshAsync();
        Ui.Say(_appsStatus, _hapFailure ?? $"{terminal!.State} · {terminal.JobId}");
    }

    // ---- Network: typed port rules ----

    private string _direction = "forward";
    private string _localPort = "";
    private string _remotePort = "";
    private string? _portJobId;
    private JobTerminal? _portTerminal;
    private string? _portFailure;
    private TextBlock _networkStatus = Ui.Status("debug.network.status");

    private void NetworkTab(DebugState state)
    {
        _networkStatus = Ui.Status("debug.network.status");
        var editor = Ui.Stack(8, Ui.Fact("debug.network.target", S.Text(UiStrings.DebugNetworkTarget), _targetId ?? S.Text(UiStrings.DebugTargetNone)));
        var direction = new RadioButtons { MaxColumns = 2, Header = S.Text(UiStrings.DebugNetworkDirection) };
        AutomationProperties.SetAutomationId(direction, "debug.network.direction");
        AutomationProperties.SetName(direction, S.Text(UiStrings.DebugNetworkDirection));
        foreach (var (tag, key) in new[] { ("forward", UiStrings.DebugNetworkForward), ("reverse", UiStrings.DebugNetworkReverse) })
        {
            var option = new RadioButton { Content = S.Text(key), Tag = tag };
            AutomationProperties.SetAutomationId(option, "debug.network.direction." + tag);
            direction.Items.Add(option);
            if (tag == _direction) direction.SelectedItem = option;
        }
        direction.SelectionChanged += (_, _) =>
        {
            if (direction.SelectedItem is RadioButton { Tag: string tag } && tag != _direction)
            {
                _direction = tag;
                RenderTab();
            }
        };
        editor.Children.Add(direction);
        // The validation and the typed rule follow each keystroke in place; the fields keep focus.
        var validation = Ui.Text("debug.network.validation", "", "ArkDeckCaptionStyle");
        var typedRule = Ui.Fact("debug.network.typedRule", S.Text(UiStrings.DebugNetworkTypedRule), "");
        void Validate()
        {
            var problem = DebugOperations.PortRuleFailure(_localPort, _remotePort, out var l, out var r);
            Ui.SetText(validation, problem is null ? S.Text(UiStrings.DebugNetworkValidationValid) : S.Text("debug.network.validation." + problem));
            typedRule.Visibility = problem is null ? Visibility.Visible : Visibility.Collapsed;
            Ui.SetText((TextBlock)typedRule.Children[1], problem is null ? $"{_direction} · tcp:{l} → tcp:{r}" : "");
        }
        editor.Children.Add(Field("debug.network.localPort", S.Text(UiStrings.DebugNetworkLocalPort), _localPort, "9000", value =>
        {
            _localPort = value;
            Validate();
        }));
        editor.Children.Add(Field("debug.network.remotePort", S.Text(UiStrings.DebugNetworkRemotePort), _remotePort, "9001", value =>
        {
            _remotePort = value;
            Validate();
        }));
        editor.Children.Add(validation);
        editor.Children.Add(typedRule);
        Validate();
        editor.Children.Add(Ui.Row(Ui.Button("debug.network.add", S.Text(UiStrings.DebugNetworkAdd), async (_, _) =>
        {
            var problem = DebugOperations.PortRuleFailure(_localPort, _remotePort, out var l, out var r);
            await PortRuleAsync(state, new DebugPortRule(_direction, l, r), removing: false, valid: problem is null);
        }, accent: true)));
        if (_portJobId is { } active)
        {
            editor.Children.Add(Ui.Row(Ui.Progress("debug.network.activeJob", S.Format(UiStrings.WindowsDebugRunning, active)),
                Ui.Button("debug.network.cancel", S.Text(UiStrings.DebugActionCancel), async (_, _) => await CancelAsync(active, _networkStatus))));
        }
        if (_portFailure is { } portFailure) editor.Children.Add(Ui.Text("debug.network.failure", portFailure));
        if (_portTerminal is { } terminal)
        {
            editor.Children.Add(TerminalLine("debug.network.terminal", terminal));
            if (terminal.FailureCode is { } code) editor.Children.Add(Ui.Text("debug.network.typedFailure", FailureText(code)));
        }
        editor.Children.Add(_networkStatus);
        editor.Children.Add(Ui.Stack(2,
            Ui.Text("debug.network.safety.title", S.Text(UiStrings.DebugNetworkSafetyTitle), "ArkDeckCaptionStyle"),
            Ui.Text("debug.network.safety.typed", S.Text(UiStrings.DebugNetworkSafetyTyped), "ArkDeckCaptionStyle"),
            Ui.Text("debug.network.safety.noShell", S.Text(UiStrings.DebugNetworkSafetyNoShell), "ArkDeckCaptionStyle"),
            Ui.Text("debug.network.safety.binding", S.Text(UiStrings.DebugNetworkSafetyBinding), "ArkDeckCaptionStyle")));
        _tab.Children.Add(Section("debug.network.editor", UiStrings.DebugNetworkEditorTitle, state.Operation(DebugOperations.CreatePortForward), true, editor));

        var rules = Ui.Stack(6);
        if (state.Probe?.Value is { PortRules.Count: > 0 } probe && probe.TargetId == _targetId)
        {
            foreach (var rule in probe.PortRules)
            {
                var id = $"debug.network.rule.{rule.Direction}.{rule.LocalPort}.{rule.RemotePort}";
                rules.Children.Add(Ui.Row(
                    Ui.Text(id, $"{rule.Direction} · tcp:{rule.LocalPort} → tcp:{rule.RemotePort} · active", "ArkDeckMonoStyle"),
                    Ui.Button(id + ".delete", S.Text(UiStrings.DebugNetworkDelete), async (_, _) => await PortRuleAsync(state, rule, removing: true, valid: true))));
            }
            if (probe.Warnings.Where(w => w.Contains("Rules", StringComparison.Ordinal)).ToArray() is { Length: > 0 } warnings)
            {
                rules.Children.Add(Ui.Text("debug.network.rules.warnings", string.Join(" · ", warnings), "ArkDeckMonoStyle"));
            }
        }
        else
        {
            rules.Children.Add(Ui.Text("debug.network.rules.empty", S.Text(UiStrings.DebugNetworkRulesEmpty)));
            rules.Children.Add(Ui.Text("debug.network.rules.empty.detail", state.Probe?.Unavailable?.ReasonText(S) ?? S.Text(UiStrings.DebugNetworkRulesEmptyDetail),
                "ArkDeckCaptionStyle"));
        }
        rules.Children.Add(Ui.Text("debug.network.delete.scope", S.Text(UiStrings.DebugNetworkDeleteScope), "ArkDeckCaptionStyle"));
        _tab.Children.Add(Section("debug.network.rules", UiStrings.DebugNetworkRulesTitle, null, false, rules));
        _tab.Children.Add(RecentJobs(state, "network", DebugOperations.CreatePortForward, DebugOperations.RemovePortForward));
    }

    private async Task PortRuleAsync(DebugState state, DebugPortRule rule, bool removing, bool valid)
    {
        var operation = state.Operation(removing ? DebugOperations.RemovePortForward : DebugOperations.CreatePortForward);
        if (Blocker(operation, valid, _portJobId is not null) is { } blocked)
        {
            Ui.Say(_networkStatus, blocked);
            return;
        }
        var target = Target!;
        _portFailure = null;
        _portTerminal = null;
        var submitted = await Task.Run(() => App.Loader.SubmitPortRuleAsync(target, rule, removing));
        var (terminal, failure) = await RunToEndAsync(submitted, jobId =>
        {
            _portJobId = jobId;
            RenderTab();
            Ui.Say(_networkStatus, S.Format(UiStrings.WindowsDebugRunning, jobId));
        });
        _portJobId = null;
        _portTerminal = terminal;
        _portFailure = failure?.ReasonText(S);
        await RefreshAsync();
        Ui.Say(_networkStatus, _portFailure ?? $"{terminal!.State} · {terminal.JobId}");
    }

    // ---- Commands: four read-only templates ----

    private string _templateId = DebugOperations.Templates[0];
    private string? _commandJobId;
    private JobTerminal? _commandTerminal;
    private string? _commandFailure;
    private string? _commandFeedbackTemplate;
    private TextBlock _commandsStatus = Ui.Status("debug.commands.status");

    private void CommandsTab(DebugState state)
    {
        var operation = state.Operation(DebugOperations.DebugTemplate);
        _commandsStatus = Ui.Status("debug.commands.status");
        _tab.Children.Add(Ui.Card(Ui.Text("debug.commands.typedOnly", S.Text(UiStrings.DebugCommandsCalloutTyped))));
        var templates = Ui.Choice("debug.commands.templates", S.Text(UiStrings.DebugCommandsSelect));
        foreach (var template in DebugOperations.Templates)
        {
            var item = Ui.Item("debug.commands.template." + template, $"{template}, readOnly",
                Ui.Stack(2, Ui.Text($"debug.commands.template.{template}.id", template, "ArkDeckMonoStyle"),
                    Ui.Text($"debug.commands.template.{template}.effect", "readOnly", "ArkDeckCaptionStyle")));
            item.Tag = template;
            templates.Items.Add(item);
            if (template == _templateId) templates.SelectedItem = item;
        }
        templates.SelectionChanged += (_, e) =>
        {
            if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string id } && id != _templateId && _commandJobId is null)
            {
                _templateId = id;
                RenderTab();
            }
        };
        _tab.Children.Add(Section("debug.commands.select", UiStrings.DebugCommandsSelect, null, false, templates));

        var invocation = Ui.Stack(8);
        AddIf(invocation, AvailabilityNotice(operation));
        invocation.Children.Add(Ui.Fact("debug.commands.catalog", "catalog", "arkdeck-remote-operations@1.0.0"));
        invocation.Children.Add(Ui.Fact("debug.commands.actionId", "actionId", _templateId));
        invocation.Children.Add(Ui.Fact("debug.commands.effect", S.Text(UiStrings.DebugCommandsEffect), "readOnly"));
        invocation.Children.Add(Ui.Fact("debug.commands.target", S.Text(UiStrings.DebugCommandsTarget), _targetId ?? S.Text(UiStrings.DebugTargetNone)));
        invocation.Children.Add(Ui.Text("debug.commands.noParameters", S.Text(UiStrings.DebugCommandsNoParameters), "ArkDeckCaptionStyle"));
        invocation.Children.Add(Ui.Fact("debug.commands.operation", S.Text(UiStrings.DebugAvailabilityOperation), DebugOperations.DebugTemplate));
        invocation.Children.Add(Ui.Fact("debug.commands.templateId", "templateId", _templateId));
        invocation.Children.Add(Ui.Text("debug.commands.argv.note", S.Text(UiStrings.DebugCommandsArgvNote), "ArkDeckCaptionStyle"));
        invocation.Children.Add(_commandJobId is { } active
            ? Ui.Row(Ui.Button("debug.commands.cancel", S.Text(UiStrings.DebugActionCancel), async (_, _) => await CancelAsync(active, _commandsStatus)),
                Ui.Progress("debug.commands.activeJob", S.Format(UiStrings.WindowsDebugRunning, active)))
            : Ui.Row(Ui.Button("debug.commands.run", S.Text(UiStrings.DebugCommandsRun), async (_, _) => await RunTemplateAsync(operation), accent: true)));
        var feedback = _commandFeedbackTemplate == _templateId;
        if (feedback && _commandFailure is { } failure) invocation.Children.Add(Ui.Text("debug.commands.failure", failure));
        invocation.Children.Add(_commandsStatus);
        _tab.Children.Add(Section("debug.commands.argv", UiStrings.DebugCommandsArgvTitle, operation, true, invocation));

        var result = Ui.Stack(6);
        if (feedback && _commandTerminal is { } terminal)
        {
            result.Children.Add(Ui.Fact("debug.commands.job.id", S.Text(UiStrings.DebugCommandsJobId), terminal.JobId));
            result.Children.Add(Ui.Fact("debug.commands.job.state", S.Text(UiStrings.DebugCommandsJobState), terminal.State));
            result.Children.Add(Ui.Fact("debug.commands.job.outcome", S.Text(UiStrings.DebugCommandsJobOutcome),
                S.Text(terminal.OutcomeUnknown ? UiStrings.DebugCommandsJobUnknown : UiStrings.DebugCommandsJobKnown)));
            if (terminal.FailureCode is { } code) result.Children.Add(Ui.Text("debug.commands.typedFailure", FailureText(code)));
            if (terminal.Timeline.LastOrDefault() is { } latest) result.Children.Add(Ui.Fact("debug.commands.job.latest", S.Text(UiStrings.DebugCommandsJobLatest), latest));
        }
        else
        {
            result.Children.Add(Ui.Text("debug.commands.result.none", S.Text(UiStrings.DebugCommandsResultNone), "ArkDeckCaptionStyle"));
        }
        _tab.Children.Add(Section("debug.commands.result", UiStrings.DebugCommandsResultTitle, null, false, result));
        _tab.Children.Add(Ui.Text("debug.commands.footer", S.Text(UiStrings.DebugCommandsFooterNoFreeText), "ArkDeckCaptionStyle"));
        var artifacts = Ui.Stack(6);
        var rows = state.ArtifactsOf(DebugOperations.DebugTemplate, _targetId);
        if (rows.Count == 0)
        {
            artifacts.Children.Add(Ui.Text("debug.commands.artifacts.empty", S.Text(UiStrings.DebugCommandsArtifactsEmpty)));
            artifacts.Children.Add(Ui.Text("debug.commands.artifacts.empty.detail", S.Text(UiStrings.DebugCommandsArtifactsEmptyDetail), "ArkDeckCaptionStyle"));
        }
        foreach (var (jobId, artifact) in rows) artifacts.Children.Add(ArtifactRow("debug.commands", jobId, artifact, Ui.Stack(4)));
        _tab.Children.Add(Section("debug.commands.artifacts", UiStrings.DebugCommandsArtifactsTitle, null, false, artifacts));
        _tab.Children.Add(RecentJobs(state, "commands", DebugOperations.DebugTemplate));
    }

    private async Task RunTemplateAsync(OperationFacts? operation)
    {
        if (Blocker(operation, true, _commandJobId is not null) is { } blocked)
        {
            Ui.Say(_commandsStatus, blocked);
            return;
        }
        var target = Target!;
        var template = _templateId;
        _commandFeedbackTemplate = template;
        _commandFailure = null;
        _commandTerminal = null;
        var submitted = await Task.Run(() => App.Loader.SubmitTemplateAsync(target, template));
        var (terminal, failure) = await RunToEndAsync(submitted, jobId =>
        {
            _commandJobId = jobId;
            RenderTab();
            Ui.Say(_commandsStatus, S.Text(UiStrings.DebugCommandsJobRunning) + " " + jobId);
        });
        _commandJobId = null;
        _commandTerminal = terminal;
        _commandFailure = failure?.ReasonText(S);
        await RefreshAsync();
        Ui.Say(_commandsStatus, _commandFailure ?? $"{terminal!.State} · {terminal.JobId}");
    }

    // ---- shared controls ----

    private async Task CancelAsync(string jobId, TextBlock status)
    {
        var answer = await Task.Run(() => App.Loader.CancelJobAsync(jobId));
        MainWindow.Instance.Report(answer);
        if (answer.Answer.Value is not { Requested: true }) Ui.Say(status, S.Text(UiStrings.WindowsDebugJobsCancelFailed));
    }

    /// <summary>Moves to another tab as the tab bar would (its selection renders the tab).</summary>
    private void SelectTab(string tag)
    {
        if (_tabBar?.Items.FirstOrDefault(i => (string)i.Tag == tag) is { } item) _tabBar.SelectedItem = item;
    }

    /// <summary>A labelled text field whose value survives re-renders.</summary>
    private static TextBox Field(string id, string header, string value, string prompt, Action<string> changed)
    {
        var box = new TextBox { Header = header, Text = value, PlaceholderText = prompt, MinWidth = 220 };
        AutomationProperties.SetAutomationId(box, id);
        AutomationProperties.SetName(box, header);
        // TextChanging, not TextChanged: TextChanged is raised asynchronously, so an action
        // invoked right after the text was set (UI Automation's SetValue, then Invoke) could
        // read the previous value.
        box.TextChanging += (_, _) => changed(box.Text);
        return box;
    }

    /// <summary>A closed choice (macOS Picker) as a ComboBox with a header.</summary>
    private static ComboBox Choice(string id, string header, string value, (string Tag, string Label)[] options, Action<string> changed)
    {
        var combo = new ComboBox { Header = header, MinWidth = 220 };
        AutomationProperties.SetAutomationId(combo, id);
        AutomationProperties.SetName(combo, header);
        foreach (var (tag, label) in options)
        {
            var item = new ComboBoxItem { Content = label, Tag = tag };
            AutomationProperties.SetAutomationId(item, $"{id}.{tag}");
            combo.Items.Add(item);
            if (tag == value) combo.SelectedItem = item;
        }
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is ComboBoxItem { Tag: string tag } && tag != value) changed(tag);
        };
        return combo;
    }
}
