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
/// Flash, as the macOS Flash workspace (<c>FlashWorkspaceView</c>): the current device and its
/// readiness, then exactly one primary surface — a Flash Job's recovery blocker, the running
/// Flash's progress, the result with its postflight checks, or the image and the one fully named
/// primary button — and the details disclosure (availability, device access, target, profile and
/// prerequisites, the exact plan, the Runtime's Flash activity). The button acknowledges the
/// impact shown above it; the Runtime still admits the Job. It never shows disabled: while a
/// required check is unknown or not satisfied, the blocker replaces it.
/// </summary>
public sealed partial class FlashPage() : SurfacePage<FlashState>(
    "flash", "flash.title", UiStrings.WindowsNavigationFlash,
    "flash.refresh", UiStrings.FlashActionRefresh, "flash.loading", UiStrings.SettingsCommonLoading), IHistoryContextPage
{
    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _primary = new() { Spacing = 12 };
    private TextBlock _status = Ui.Status("flash.status");
    private FlashState? _state;
    private string? _targetId;
    private string? _archive;
    private bool _preparing;
    private FlashPreparation? _preparation;
    private FlashLanePreview _lane = FlashLanePreview.Pending;
    private string? _jobId;
    private FlashRunStatus? _live;
    private FlashRunStatus? _submission;
    private string? _submissionFailure;
    private JobEvidenceFacts? _evidence;
    private bool _submitting;
    private bool _cancelling;
    private bool _detailsOpen;
    private FlashPhase? _announcedPhase;

    protected override Task<FlashState> LoadAsync() => App.Loader.FlashAsync();

    private TargetSummary? Target => _state?.Targets.Value?.FirstOrDefault(t => t.TargetId == _targetId);

    private FlashPlan? Plan => _preparation?.Plan is { } plan && plan.Target.TargetId == _targetId ? plan : null;

    private HistoryWorkspaceContext? _history;

    /// <summary>macOS <c>focusHistoryContext</c>: the record's exact Target is selected and any
    /// plan invalidated, without preparing or submitting one; a Target no longer adopted stays
    /// selected and missing, so no other device is chosen for the record.</summary>
    public void OpenHistoryContext(HistoryWorkspaceContext context)
    {
        _history = context;
        if (_targetId == context.TargetId) return;
        _targetId = context.TargetId;
        _preparation = null;
    }

    protected override void Render(FlashState state, StackPanel body)
    {
        _state = state;
        var targets = state.Targets.Value ?? [];
        if (_targetId is null || (_history?.TargetId != _targetId && targets.All(t => t.TargetId != _targetId))) _targetId = targets.FirstOrDefault()?.TargetId;
        if (_history is { } history)
        {
            body.Children.Add(HistoryContextBanner.Create(history, async () =>
            {
                _history = null;
                await RefreshAsync();
            }));
        }
        var said = _status.Text;
        _status = Ui.Status("flash.status");
        Ui.SetText(_status, said);
        body.Children.Add(Ui.Text("flash.workspace.title", S.Text(UiStrings.FlashWorkspaceSubtitle), "ArkDeckCaptionStyle"));
        if (_targetId is not null && targets.All(t => t.TargetId != _targetId))
        {
            body.Children.Add(Ui.Text("flash.target.historyMissing", S.Text(UiStrings.FlashTargetHistoryMissing), "ArkDeckCaptionStyle"));
        }
        _primary = new StackPanel { Spacing = 12 };
        body.Children.Add(new AdaptiveColumns([
            Ui.Card(CurrentDevice(state), "flash.workspace.currentDevice.card"),
            Ui.Card(_primary, "flash.workspace.primary")], [1, 2], minimumColumnWidth: 260, spacing: 24));
        body.Children.Add(_status);
        RenderPrimary();
        // The macOS plain disclosure toggle: its title says what it will do.
        var details = Details(state);
        details.Visibility = _detailsOpen ? Visibility.Visible : Visibility.Collapsed;
        Button? toggle = null;
        toggle = Ui.Button("flash.workspace.details", S.Text(_detailsOpen ? UiStrings.FlashWorkspaceDetailsHide : UiStrings.FlashWorkspaceDetails), (_, _) =>
        {
            _detailsOpen = !_detailsOpen;
            details.Visibility = _detailsOpen ? Visibility.Visible : Visibility.Collapsed;
            var title = S.Text(_detailsOpen ? UiStrings.FlashWorkspaceDetailsHide : UiStrings.FlashWorkspaceDetails);
            toggle!.Content = title;
            AutomationProperties.SetName(toggle, title);
        });
        body.Children.Add(Ui.Row(toggle));
        body.Children.Add(details);
    }

    // ---- current device and readiness ----

    private StackPanel CurrentDevice(FlashState state)
    {
        var target = Target;
        var identity = Ui.Stack(2,
            Ui.Heading("flash.workspace.currentDevice", target is null ? S.Text(UiStrings.FlashWorkspaceDeviceNone) : "DAYU200", AutomationHeadingLevel.Level2),
            Ui.Text("flash.workspace.currentDevice.detail",
                target is null ? S.Text(UiStrings.FlashTargetGuidance) : S.Format(UiStrings.FlashWorkspaceDeviceDetail, target.TargetId, target.BindingRevision),
                target is null ? "ArkDeckCaptionStyle" : "ArkDeckMonoStyle"));
        var (readiness, detail) = Readiness(state);
        return Ui.Stack(8, identity, Ui.Text("flash.workspace.readiness", S.Text(readiness)), Ui.Text("flash.workspace.readiness.detail", detail, "ArkDeckCaptionStyle"));
    }

    private (string Key, string Detail) Readiness(FlashState state)
    {
        var availability = state.Operation.Availability;
        var plan = Plan;
        var key = availability.Kind switch
        {
            AvailabilityKind.Checking => UiStrings.FlashWorkspaceReadinessChecking,
            AvailabilityKind.Unavailable => UiStrings.FlashWorkspaceReadinessBlocked,
            _ when Target is null => UiStrings.FlashWorkspaceReadinessNoDevice,
            _ when _preparing => UiStrings.FlashWorkspaceReadinessChecking,
            _ when _preparation?.FailureCode is not null => UiStrings.FlashWorkspaceReadinessBlocked,
            _ when plan is { Blocking.Count: > 0 } && !WillActivateLoader => UiStrings.FlashWorkspaceReadinessBlocked,
            _ when plan is null => UiStrings.FlashWorkspaceReadinessSelected,
            _ => UiStrings.FlashWorkspaceReadinessReady,
        };
        var detail = availability.Kind == AvailabilityKind.Unavailable ? availability.Reasons.FirstOrDefault() ?? S.Text(UiStrings.FlashAvailabilityUnavailable)
            : Target is null ? S.Text(UiStrings.FlashWorkspaceReadinessNoDeviceDetail)
            : _preparing ? S.Text(UiStrings.FlashWorkspaceReadinessCheckingDetail)
            : _preparation?.FailureCode is not null ? S.Text(UiStrings.FlashWorkspaceReadinessPlanFailedDetail)
            : plan is { Blocking.Count: > 0 } && !WillActivateLoader ? S.Format(UiStrings.FlashWorkspaceReadinessBlockerCount, plan.Blocking.Count)
            : plan is not null ? S.Format(UiStrings.FlashWorkspaceReadinessCheckCount, plan.Prerequisites.Count(p => p.Requirement == "required" && p.Status == "satisfied"))
            : S.Text(UiStrings.FlashWorkspaceReadinessChooseImage);
        return (key, detail);
    }

    /// <summary>Whether a submission first binds the board in Loader mode to the selected Target
    /// (macOS <c>willActivateCurrentTargetOnSubmit</c>).</summary>
    private bool WillActivateLoader =>
        Target is { } target && _state?.Bootloader is { ObservationCount: 1, Mode: "loader" or "hdcNormal" } status
        && ((status.Disposition == "unbound" && status.Mode == "loader")
            || (status.Disposition == "targetBindingUnprepared" && status.TargetId == target.TargetId && status.BindingRevision == target.BindingRevision));

    // ---- the one primary surface ----

    private void RenderPrimary()
    {
        _primary.Children.Clear();
        if (_state is not { } state) return;
        if (_jobId is null && _submission is null && state.Focused is { } focused && NeedsRecovery(focused)) Recovery(focused);
        else if (_submitting || _jobId is not null) Progress();
        else if (_submission is not null || _submissionFailure is not null) Result();
        else ImageAndAction(state);
    }

    private static bool NeedsRecovery(RecentJob job) =>
        job.OutcomeUnknown || job.WaitingForHuman || job.State is "waitingForRecovery" or "awaitingRebindConfirmation" or "userAbandonRequested";

    private void Recovery(RecentJob job)
    {
        _primary.Children.Add(Ui.Heading("flash.runtime.attention", S.Text(UiStrings.FlashRuntimeRecoveryTitle), AutomationHeadingLevel.Level2));
        _primary.Children.Add(Ui.Text("flash.runtime.recovery.guidance",
            S.Text(job.OutcomeUnknown ? UiStrings.FlashRuntimeOutcomeUnknownGuidance : UiStrings.FlashRuntimeWaitingForHumanGuidance)));
        _primary.Children.Add(Ui.Fact("flash.runtime.job", S.Text(UiStrings.FlashRuntimeJob), job.JobId));
        _primary.Children.Add(Ui.Row(Ui.Button("flash.runtime.openHistory", S.Text(UiStrings.FlashRuntimeOpenRecord), async (_, _) => await MainWindow.Instance.OpenJobAsync(job.JobId))));
    }

    private void ImageAndAction(FlashState state)
    {
        var plan = Plan;
        var row = Ui.Stack(4,
            Ui.Text("flash.image.value", _archive is null ? S.Text(UiStrings.FlashWorkspaceImageChooseTitle) : Path.GetFileName(_archive)),
            Ui.Text("flash.image.detail", plan is null ? S.Text(UiStrings.FlashWorkspaceImageChooseHelp)
                : $"{Size(plan.Archive.ArchiveSizeBytes)} · {plan.Archive.RuntimeBuildVersion}", "ArkDeckCaptionStyle"),
            Ui.Row(Ui.Button("flash.image.choose", S.Text(_archive is null ? UiStrings.FlashWorkspaceImageChoose : UiStrings.FlashWorkspaceImageChange),
                async (_, _) => await ChooseImageAsync(), accent: _archive is null)));
        AutomationProperties.SetAutomationId(row, "flash.workspace.imageAction");
        _primary.Children.Add(row);
        if (_preparing)
        {
            _primary.Children.Add(Ui.Progress("flash.plan.preparing", S.Text(UiStrings.FlashWorkspaceImageValidating)));
            return;
        }
        if (_preparation?.FailureCode is { } code)
        {
            _primary.Children.Add(Ui.Text("flash.plan.error", S.Text(code switch
            {
                FlashReviewFailureCode.FileAccessDenied => UiStrings.FlashErrorFileAccess,
                FlashReviewFailureCode.UnsupportedArchiveFormat => UiStrings.FlashErrorFormat,
                FlashReviewFailureCode.UnreadableArchive => UiStrings.FlashErrorUnreadable,
                FlashReviewFailureCode.InvalidArchive => UiStrings.FlashErrorInvalid,
                FlashReviewFailureCode.UnsupportedBundle => UiStrings.FlashErrorUnsupported,
                _ => UiStrings.FlashErrorPlan,
            })));
            if (_preparation.FailureDetail is { } detail) _primary.Children.Add(Ui.Text("flash.plan.error.detail", detail, "ArkDeckMonoStyle"));
            _primary.Children.Add(Ui.Row(Ui.Button("flash.plan.retry", S.Text(UiStrings.FlashWorkspaceImageRetry), async (_, _) => await PrepareAsync())));
            return;
        }
        if (plan is null) return;
        var impactTarget = Target?.TargetId ?? "DAYU200";
        _primary.Children.Add(plan.Archive.UserDataDestroyed
            ? Ui.Text("flash.impact.userdata", S.Format(UiStrings.FlashWorkspaceActionImpact, impactTarget))
            : Ui.Text("flash.impact.partitions", S.Format(UiStrings.FlashImpactPartitions, plan.Archive.MappedPartitionCount)));
        _primary.Children.Add(Ui.Text("flash.workspace.action.power", S.Text(UiStrings.WindowsFlashActionPower)));
        _primary.Children.Add(Ui.Text("flash.workspace.action.authority", S.Text(UiStrings.FlashWorkspaceActionAuthority), "ArkDeckCaptionStyle"));
        if (CanSubmit(state, plan))
        {
            _primary.Children.Add(Ui.Row(Ui.Button("flash.execute.submit", S.Text(UiStrings.FlashWorkspaceActionSubmit), async (_, _) => await SubmitAsync(), accent: true)));
        }
        else
        {
            var availability = state.Operation.Availability;
            _primary.Children.Add(Ui.Text("flash.execute.prerequisiteBlocker", availability.Kind switch
            {
                AvailabilityKind.Checking => S.Text(UiStrings.FlashAvailabilityChecking),
                AvailabilityKind.Unavailable => availability.Reasons.FirstOrDefault() ?? S.Text(UiStrings.FlashAvailabilityUnavailable),
                _ when plan.Blocking.Count > 0 => S.Format(UiStrings.FlashWorkspaceActionBlocked, plan.Blocking.Count),
                _ => S.Text(UiStrings.FlashExecutePlanRequired),
            }));
        }
    }

    /// <summary>macOS <c>canSubmit</c>: available, not submitting, an archive, the plan for the
    /// selected Target, and no blocking required prerequisite unless the Loader is bound on submit.</summary>
    private bool CanSubmit(FlashState state, FlashPlan plan) =>
        state.Operation.IsAvailable && !_submitting && _archive is not null && Target is { } target
        && plan.Target.TargetId == target.TargetId && plan.Target.BindingRevision == target.BindingRevision
        && plan.Target.ToolVersion == target.ToolVersion && plan.Target.AdoptedAtUtc == target.AdoptedAtUtc
        && plan.RuntimeAdmissionPreviewPassed && (plan.Blocking.Count == 0 || WillActivateLoader);

    private void Progress()
    {
        var progress = FlashLiveProgress.Project(_live, Plan?.Archive.Partitions ?? []);
        var title = progress.Phase switch
        {
            FlashPhase.ImportingImage => S.Text(UiStrings.FlashWorkspaceProgressImporting),
            FlashPhase.ValidatingImage => S.Text(UiStrings.FlashWorkspaceProgressValidating),
            FlashPhase.EnteringBootloader => S.Text(UiStrings.FlashWorkspaceProgressBootloader),
            FlashPhase.ExtractingImage => S.Text(UiStrings.FlashWorkspaceProgressExtracting),
            FlashPhase.WritingPartition => S.Format(UiStrings.FlashWorkspaceProgressPartition, progress.PartitionName ?? S.Text(UiStrings.FlashWorkspaceProgressPartitionUnknown)),
            FlashPhase.VerifyingPartitions => S.Text(UiStrings.FlashWorkspaceProgressVerifyingPartitions),
            FlashPhase.RebootingDevice => S.Text(UiStrings.FlashWorkspaceProgressRebooting),
            FlashPhase.ReconnectingDevice => S.Text(UiStrings.FlashWorkspaceProgressReconnecting),
            _ => S.Text(UiStrings.FlashWorkspaceProgressVerifyingSystem),
        };
        _primary.Children.Add(Ui.Heading("flash.workspace.progress", title, AutomationHeadingLevel.Level2));
        _primary.Children.Add(Ui.Text("flash.workspace.progress.keepConnected", S.Text(UiStrings.WindowsFlashProgressKeepConnected), "ArkDeckCaptionStyle"));
        var bar = new ProgressBar { Minimum = 0, Maximum = 100, MinWidth = 320, IsIndeterminate = progress.WritePercent is null, Value = progress.WritePercent ?? 0 };
        AutomationProperties.SetAutomationId(bar, "flash.runtime.progress");
        AutomationProperties.SetName(bar, title);
        _primary.Children.Add(bar);
        _primary.Children.Add(progress.WritePercent is { } percent
            ? Ui.Text("flash.runtime.progress.percent", $"{percent}%")
            : Ui.Text("flash.runtime.progress.running", S.Text(UiStrings.FlashWorkspaceProgressRunning), "ArkDeckCaptionStyle"));
        _primary.Children.Add(Ui.Text("flash.runtime.progress.detail", progress.Phase == FlashPhase.WritingPartition && progress.Completed is { } done && progress.Total is { } total
            ? S.Format(UiStrings.FlashWorkspaceProgressPartitionDetail, done, total, progress.CurrentPercent ?? 0, progress.WritePercent ?? 0)
            : S.Text(UiStrings.FlashWorkspaceProgressIndeterminate), "ArkDeckCaptionStyle"));
        var stages = new[] { UiStrings.FlashWorkspaceStagePrepare, UiStrings.FlashWorkspaceStageWrite, UiStrings.FlashWorkspaceStageVerify };
        var track = Ui.Row();
        AutomationProperties.SetAutomationId(track, "flash.workspace.progress.stages");
        for (var i = 0; i < stages.Length; i++)
        {
            var mark = i < progress.Stage ? "✓" : i == progress.Stage ? "●" : "○";
            track.Children.Add(Ui.Text($"flash.workspace.progress.stage.{i}", $"{mark} {S.Text(stages[i])}", "ArkDeckCaptionStyle"));
        }
        _primary.Children.Add(track);
        if (progress.Phase == FlashPhase.WritingPartition)
        {
            _primary.Children.Add(Ui.Text("flash.runtime.criticalWrite", S.Text(UiStrings.WindowsFlashRuntimeCriticalWrite)));
        }
        if (_jobId is { } active)
        {
            _primary.Children.Add(Ui.Row(Ui.Button("flash.execute.cancel", S.Text(UiStrings.FlashActionCancel), async (_, _) => await CancelAsync(active))));
            _primary.Children.Add(Ui.Text("flash.action.cancel.help", S.Text(UiStrings.FlashActionCancelHelp), "ArkDeckCaptionStyle"));
        }
        if (_announcedPhase != progress.Phase)
        {
            _announcedPhase = progress.Phase;
            Ui.Say(_status, title);
        }
    }

    private bool VerifiedPostflight =>
        _submission is { State: "succeeded" or "recovered" } && _evidence is { TerminalState: "succeeded" or "recovered", Blockers.Count: 0 } evidence
        && Plan is { } plan && evidence.ObservedFirmware == plan.Archive.RuntimeBuildVersion && evidence.ObservedBindingRevision == plan.Target.BindingRevision;

    private void Result()
    {
        var success = VerifiedPostflight;
        _primary.Children.Add(Ui.Heading("flash.execute.terminal", S.Text(success ? UiStrings.FlashWorkspaceResultSuccess : UiStrings.FlashWorkspaceResultStopped),
            AutomationHeadingLevel.Level2));
        _primary.Children.Add(Ui.Text("flash.execute.description", success ? S.Text(UiStrings.FlashWorkspaceResultSuccessDetail)
            : _submissionFailure ?? (_submission is { } s ? S.Format(UiStrings.FlashWorkspaceResultState, s.State) : S.Text(UiStrings.FlashWorkspaceResultUnverified))));
        if (_submission?.JobId is { } jobId) _primary.Children.Add(Ui.Text("flash.execute.jobId", jobId, "ArkDeckMonoStyle"));
        if (Plan is { } plan && _evidence is { } evidence)
        {
            var postflight = Ui.Stack(4, Ui.Heading("flash.postflight.title", S.Text(UiStrings.FlashPostflightTitle), AutomationHeadingLevel.Level3));
            if (evidence.ObservedFirmware is { } firmware)
            {
                postflight.Children.Add(Postflight("build", S.Text(UiStrings.FlashPostflightBuild), plan.Archive.RuntimeBuildVersion, firmware, firmware == plan.Archive.RuntimeBuildVersion));
            }
            var planned = plan.Target.BindingRevision;
            var observed = evidence.ObservedBindingRevision ?? -1;
            postflight.Children.Add(Postflight("binding", S.Text(UiStrings.FlashPostflightBinding), $"r{planned} → r{planned}",
                $"r{planned} → r{(observed < 0 ? "?" : observed.ToString(CultureInfo.InvariantCulture))}", observed == planned));
            AutomationProperties.SetAutomationId(postflight, "flash.postflight");
            _primary.Children.Add(postflight);
        }
        _primary.Children.Add(Ui.Row(
            Ui.Button("flash.workspace.result.again", S.Text(UiStrings.FlashWorkspaceResultAgain), (_, _) => ResetForAnotherFlash(), accent: true),
            Ui.Button("flash.runtime.openHistory", S.Text(UiStrings.FlashWorkspaceResultHistory), async (_, _) =>
            {
                if (_submission?.JobId is { } id) await MainWindow.Instance.OpenJobAsync(id);
                else MainWindow.Instance.Select("history");
            })));
    }

    private TextBlock Postflight(string what, string label, string expected, string observed, bool matches)
    {
        var text = Ui.Text($"flash.postflight.{what}.{(matches ? "match" : "mismatch")}", $"{label}: {S.Format(UiStrings.FlashPostflightComparison, expected, observed)}");
        AutomationProperties.SetName(text, S.Format(matches ? UiStrings.FlashPostflightMatch : UiStrings.FlashPostflightMismatch, label, expected, observed));
        return text;
    }

    // ---- the details disclosure ----

    private StackPanel Details(FlashState state)
    {
        var details = Ui.Stack(12);
        // Availability.
        var availability = Ui.Stack(4, Ui.Heading("flash.availability.title", S.Text(UiStrings.FlashAvailabilityTitle), AutomationHeadingLevel.Level3),
            Ui.Text("flash.availability.status", S.Text(state.Operation.Availability.Kind switch
            {
                AvailabilityKind.Checking => UiStrings.FlashAvailabilityChecking,
                AvailabilityKind.Available => UiStrings.FlashAvailabilityAvailable,
                _ => UiStrings.FlashAvailabilityUnavailable,
            })));
        var reason = 0;
        foreach (var why in state.Operation.Availability.Kind == AvailabilityKind.Unavailable ? state.Operation.Availability.Reasons : [])
        {
            availability.Children.Add(Ui.Text($"flash.availability.reason.{reason++}", why, "ArkDeckMonoStyle"));
        }
        availability.Children.Add(Ui.Text("flash.availability.scope", S.Text(UiStrings.FlashAvailabilityScope), "ArkDeckCaptionStyle"));
        details.Children.Add(availability);

        // Device access and the bootloader.
        var access = Ui.Stack(4, Ui.Heading("flash.deviceAccess.title", S.Text(UiStrings.FlashDeviceAccessTitle), AutomationHeadingLevel.Level3));
        AutomationProperties.SetAutomationId(access, "flash.deviceAccess");
        if (state.DeviceAccess.Unavailable is { } unavailable)
        {
            access.Children.Add(Ui.Text("flash.deviceAccess.unavailable", S.Text(UiStrings.FlashDeviceAccessToolUnavailable)));
            access.Children.Add(Ui.Text("flash.deviceAccess.reason", unavailable.ReasonText(S), "ArkDeckMonoStyle"));
        }
        else if (state.DeviceAccess.Value is { } device)
        {
            access.Children.Add(Ui.Text("flash.deviceAccess.verdict", S.Text("flash.deviceAccess.verdict." + (device.Verdict == "offlineOrUnauthorized" ? "offline" : device.Verdict))));
            access.Children.Add(Ui.Fact("flash.deviceAccess.responsibility", S.Text(UiStrings.FlashDeviceAccessResponsibility), S.Text("flash.deviceAccess.responsibility." + device.Responsibility)));
            access.Children.Add(Ui.Fact("flash.deviceAccess.nextStep", S.Text(UiStrings.FlashDeviceAccessNextStep), S.Text("flash.deviceAccess.remediation." + device.Remediation)));
            if (device.ObservationCount > 0)
            {
                access.Children.Add(Ui.Fact("flash.deviceAccess.observations", S.Text(UiStrings.FlashDeviceAccessObservations),
                    S.Format(UiStrings.FlashDeviceAccessObservationValue, device.ObservationCount, string.Join(", ", device.ObservedModes))));
            }
        }
        access.Children.Add(Ui.Row(Ui.Button("flash.deviceAccess.reprobe", S.Text(UiStrings.FlashDeviceAccessReprobe), async (_, _) => await RefreshAsync())));
        if (state.Bootloader is { } boot)
        {
            if (boot is { Disposition: "unbound" or "targetBindingUnprepared", Mode: "loader" })
            {
                access.Children.Add(Ui.Text("flash.bootloader.unbound.title", S.Text(UiStrings.FlashBootloaderUnboundTitle)));
                access.Children.Add(Ui.Text("flash.bootloader.detail", S.Text(boot.Disposition == "targetBindingUnprepared" ? UiStrings.FlashBootloaderUnpreparedDetail : UiStrings.FlashBootloaderUnboundDetail),
                    "ArkDeckCaptionStyle"));
            }
            else if (boot is { Disposition: "exactBoundTarget", Mode: "loader" })
            {
                access.Children.Add(Ui.Text("flash.bootloader.bound", S.Text(UiStrings.FlashBootloaderBound)));
            }
            else if (boot is { Disposition: "targetBindingUnprepared", Mode: "hdcNormal" })
            {
                access.Children.Add(Ui.Text("flash.binding.unprepared.hdc.title", S.Text(UiStrings.FlashBindingUnpreparedHdcTitle)));
                access.Children.Add(Ui.Text("flash.binding.unprepared.hdc.detail", S.Text(UiStrings.FlashBindingUnpreparedHdcDetail), "ArkDeckCaptionStyle"));
            }
        }
        details.Children.Add(access);

        details.Children.Add(Configuration(state));
        if (Plan is { } plan) details.Children.Add(ExactPlan(plan));
        details.Children.Add(Activity(state));
        return details;
    }

    private StackPanel Configuration(FlashState state)
    {
        var configuration = Ui.Stack(6, Ui.Heading("flash.workspace.details.configuration", S.Text(UiStrings.FlashWorkspaceDetailsConfiguration), AutomationHeadingLevel.Level3));
        var profile = new ComboBox { Header = S.Text(UiStrings.FlashProfileLabel), MinWidth = 220 };
        AutomationProperties.SetAutomationId(profile, "flash.profile");
        AutomationProperties.SetName(profile, S.Text(UiStrings.FlashProfileLabel));
        profile.Items.Add(new ComboBoxItem { Content = FlashOperations.ProfileReference, Tag = FlashOperations.ProfileReference });
        profile.SelectedIndex = 0;
        configuration.Children.Add(profile);
        var targets = state.Targets.Value ?? [];
        if (targets.Count == 0)
        {
            configuration.Children.Add(Ui.Text("flash.target.empty", S.Text(UiStrings.FlashTargetNone)));
            if (state.Targets.Unavailable is { } why) configuration.Children.Add(Ui.Text("flash.target.failure", why.ReasonText(S), "ArkDeckMonoStyle"));
            configuration.Children.Add(Ui.Text("flash.target.guidance", S.Text(UiStrings.FlashTargetGuidance), "ArkDeckCaptionStyle"));
        }
        else
        {
            var picker = new ComboBox { Header = S.Text(UiStrings.FlashTargetLabel), MinWidth = 260 };
            AutomationProperties.SetAutomationId(picker, "flash.target");
            AutomationProperties.SetName(picker, S.Text(UiStrings.FlashTargetLabel));
            foreach (var target in targets)
            {
                var item = new ComboBoxItem { Content = target.TargetId, Tag = target.TargetId };
                AutomationProperties.SetAutomationId(item, "flash.target." + target.TargetId);
                picker.Items.Add(item);
                if (target.TargetId == _targetId) picker.SelectedItem = item;
            }
            picker.SelectionChanged += async (_, _) =>
            {
                if (picker.SelectedItem is not ComboBoxItem { Tag: string id } || id == _targetId || _preparing || _submitting) return;
                _targetId = id;
                _preparation = null;
                Ui.Say(_status, S.Text(UiStrings.WindowsFlashTargetChanged));
                if (_archive is not null) await PrepareAsync();
                else await RefreshAsync();
            };
            configuration.Children.Add(picker);
            if (Target is { } selected)
            {
                configuration.Children.Add(Ui.Fact("flash.target.binding", S.Text(UiStrings.FlashTargetBinding), selected.BindingRevision.ToString(CultureInfo.InvariantCulture)));
                configuration.Children.Add(Ui.Fact("flash.target.toolVersion", S.Text(UiStrings.FlashTargetToolVersion), selected.ToolVersion));
            }
        }
        var prerequisites = Ui.Stack(4, Ui.Heading("flash.plan.prerequisites", S.Text(UiStrings.FlashPlanPrerequisites), AutomationHeadingLevel.Level4));
        AutomationProperties.SetAutomationId(prerequisites, "flash.plan.prerequisitesSection");
        if (Plan is { } plan)
        {
            prerequisites.Children.Add(Ui.Text("flash.plan.prerequisitesNote", S.Text(UiStrings.FlashPlanPrerequisitesNote), "ArkDeckCaptionStyle"));
            foreach (var prerequisite in plan.Prerequisites)
            {
                prerequisites.Children.Add(Ui.Text($"flash.plan.prerequisite.{prerequisite.Identifier}",
                    $"{S.Text("flash.prerequisite." + prerequisite.Identifier)} · {S.Text("flash.prerequisite." + prerequisite.Requirement)} · {S.Text("flash.prerequisite.status." + prerequisite.Status)}"));
            }
        }
        else
        {
            prerequisites.Children.Add(Ui.Text("flash.plan.prerequisitesAwaitPlan", S.Text(UiStrings.FlashPlanPrerequisitesAwaitPlan), "ArkDeckCaptionStyle"));
        }
        configuration.Children.Add(prerequisites);
        return configuration;
    }

    private StackPanel ExactPlan(FlashPlan plan)
    {
        var review = FlashOperations.CatalogReview.Value;
        var exact = Ui.Stack(6, Ui.Heading("flash.plan.title", S.Text(UiStrings.FlashPlanTitle), AutomationHeadingLevel.Level3),
            Ui.Text("flash.workspace.plan.summary", S.Format(UiStrings.FlashWorkspacePlanSummary, review.Steps.Count, S.Text("flash.effect." + review.HighestEffect))));
        AutomationProperties.SetAutomationId(exact, "flash.plan.steps");
        var stages = review.Stages();
        var names = new[] { UiStrings.FlashWorkspacePlanPrepare, UiStrings.FlashWorkspacePlanLoader, UiStrings.FlashWorkspacePlanWrite, UiStrings.FlashWorkspacePlanVerify };
        for (var i = 0; i < stages.Count; i++)
        {
            var effect = stages[i].Count == 0 ? "—" : S.Text("flash.effect." + stages[i].Select(s => s.Effect).MaxBy(FlashCatalogReview.EffectRank));
            exact.Children.Add(Ui.Text($"flash.workspace.plan.stage.{i}", $"{S.Text(names[i])} · {S.Text(UiStrings.FlashWorkspacePlanSteps)} {stages[i].Count} · {effect}"));
        }
        exact.Children.Add(Ui.Fact("flash.plan.build", S.Text(UiStrings.FlashPlanBuild), plan.Archive.RuntimeBuildVersion));
        exact.Children.Add(Ui.Fact("flash.plan.size", S.Text(UiStrings.FlashPlanSize), Size(plan.Archive.ArchiveSizeBytes)));
        exact.Children.Add(Ui.Fact("flash.plan.archiveHash", S.Text(UiStrings.FlashPlanArchiveHash), plan.Archive.ArchiveSha256));
        exact.Children.Add(Ui.Fact("flash.plan.digest", S.Text(UiStrings.FlashPlanDigest), plan.PlanDigest ?? S.Text(UiStrings.FlashPlanDigestMaterializedAtSubmission)));
        exact.Children.Add(Ui.Fact("flash.plan.stepSetDigest", S.Text(UiStrings.FlashPlanStepSetDigest), review.StepSetDigest));
        exact.Children.Add(Ui.Fact("flash.plan.lanePlan", S.Text(UiStrings.FlashPlanLanePlan), _lane.State switch
        {
            "available" => _lane.Detail ?? "",
            "bundleNotInLaneStore" => S.Text(UiStrings.FlashPlanLanePlanBundleNotInLaneStore),
            "laneNotComposed" => S.Text(UiStrings.FlashPlanLanePlanLaneNotComposed),
            "deviceNotObserved" => $"{S.Text(UiStrings.FlashPlanLanePlanDeviceNotObserved)} — {_lane.Detail}",
            "planNotExecutable" => $"{S.Text(UiStrings.FlashPlanLanePlanPlanNotExecutable)} — {_lane.Detail}",
            "unavailable" => $"{S.Text(UiStrings.FlashPlanLanePlanUnavailable)} — {_lane.Detail}",
            _ => S.Text(UiStrings.FlashPlanLanePlanPending),
        }));
        var partitions = Ui.Stack(4);
        foreach (var partition in plan.Archive.Partitions)
        {
            var hash = partition.ImageSha256.Length >= 12 ? partition.ImageSha256[..12] : partition.ImageSha256;
            partitions.Children.Add(Ui.Text($"flash.plan.partition.{partition.PartitionName}",
                $"{partition.WriteOrder}. {partition.PartitionName} · {partition.ImageMemberName} · {S.Text(UiStrings.FlashPlanImageSize)} {Size(partition.ImageSizeBytes)} · {S.Text(UiStrings.FlashPlanImageHash)} {hash}",
                "ArkDeckMonoStyle"));
        }
        partitions.Children.Add(Ui.Text("flash.plan.writeForbidden", $"{S.Text(UiStrings.FlashPlanWriteForbidden)}: {string.Join(", ", plan.Archive.WriteForbiddenMemberNames)}", "ArkDeckCaptionStyle"));
        exact.Children.Add(Ui.Disclosure("flash.plan.partitions.disclosure", S.Format(UiStrings.FlashPlanPartitionCount, plan.Archive.MappedPartitionCount), partitions));
        return exact;
    }

    private StackPanel Activity(FlashState state)
    {
        var activity = Ui.Stack(6, Ui.Heading("flash.runtime.title", S.Text(UiStrings.FlashRuntimeTitle), AutomationHeadingLevel.Level3));
        if (state.Jobs.Unavailable is { } why)
        {
            activity.Children.Add(Ui.Text("flash.runtime.unavailable", S.Text(UiStrings.FlashRuntimeUnavailable)));
            activity.Children.Add(Ui.Text("flash.runtime.unavailable.reason", why.ReasonText(S), "ArkDeckMonoStyle"));
            activity.Children.Add(Ui.Text("flash.runtime.unavailableNote", S.Text(UiStrings.FlashRuntimeUnavailableNote), "ArkDeckCaptionStyle"));
            return activity;
        }
        if (state.Focused is not { } job)
        {
            activity.Children.Add(Ui.Text("flash.runtime.empty", S.Text(UiStrings.FlashRuntimeEmpty)));
            activity.Children.Add(Ui.Text("flash.runtime.emptyDescription", S.Text(UiStrings.FlashRuntimeEmptyDescription), "ArkDeckCaptionStyle"));
            return activity;
        }
        var stateKey = "flash.state." + job.State;
        activity.Children.Add(Ui.Text("flash.runtime.state", UiStrings.All.Contains(stateKey) ? S.Text(stateKey) : job.State));
        activity.Children.Add(Ui.Text("flash.runtime.jobCount", S.Format(UiStrings.FlashRuntimeJobCount, state.FlashJobCount), "ArkDeckCaptionStyle"));
        activity.Children.Add(Ui.Fact("flash.runtime.jobID", S.Text(UiStrings.FlashRuntimeJob), job.JobId));
        activity.Children.Add(Ui.Fact("flash.runtime.targetID", S.Text(UiStrings.FlashRuntimeTarget), job.TargetId));
        if (job.ResidueCount > 0) activity.Children.Add(Ui.Text("flash.runtime.residue", S.Format(UiStrings.FlashRuntimeResidue, job.ResidueCount)));
        if (state.FocusedStatus is { Timeline.Count: > 0 } status && status.JobId == job.JobId)
        {
            activity.Children.Add(Ui.Heading("flash.runtime.timeline", S.Text(UiStrings.FlashRuntimeTimeline), AutomationHeadingLevel.Level4));
            var entries = Ui.Stack(2);
            AutomationProperties.SetAutomationId(entries, "flash.runtime.timeline.entries");
            var index = 0;
            foreach (var entry in status.Timeline.TakeLast(20)) entries.Children.Add(Ui.Text($"flash.runtime.timeline.{index++}", entry, "ArkDeckMonoStyle"));
            activity.Children.Add(entries);
        }
        var result = job.OutcomeUnknown ? UiStrings.FlashRuntimeResultOutcomeUnknown : job.State switch
        {
            "succeeded" or "recovered" => UiStrings.FlashRuntimeResultSucceeded,
            "planned" => UiStrings.FlashRuntimeResultPlanned,
            "failed" => UiStrings.FlashRuntimeResultFailed,
            "cancelled" => UiStrings.FlashRuntimeResultCancelled,
            "interrupted" => UiStrings.FlashRuntimeResultInterrupted,
            "waitingForRecovery" or "awaitingRebindConfirmation" or "userAbandonRequested" => UiStrings.FlashRuntimeResultNeedsAction,
            _ => UiStrings.FlashRuntimeResultInProgress,
        };
        activity.Children.Add(Ui.Text("flash.runtime.result", S.Text(result)));
        if (!NeedsRecovery(job))
        {
            activity.Children.Add(Ui.Row(Ui.Button("flash.runtime.openRecord", S.Text(UiStrings.FlashRuntimeOpenRecord), async (_, _) => await MainWindow.Instance.OpenJobAsync(job.JobId))));
            activity.Children.Add(Ui.Text("flash.runtime.readOnly", S.Text(UiStrings.FlashRuntimeReadOnly), "ArkDeckCaptionStyle"));
        }
        return activity;
    }

    // ---- actions ----

    private async Task ChooseImageAsync()
    {
        if (_preparing) return;
        var picker = new FileOpenPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        foreach (var extension in new[] { ".gz", ".zip", ".7z" }) picker.FileTypeFilter.Add(extension);
        var picked = await picker.PickSingleFileAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
        _archive = picked.Path;
        _preparation = null;
        await PrepareAsync();
    }

    private async Task PrepareAsync()
    {
        if (_archive is not { } archive || _preparing) return;
        if (Target is not { } target)
        {
            Ui.Say(_status, S.Text(UiStrings.FlashTargetGuidance));
            return;
        }
        _preparing = true;
        _lane = FlashLanePreview.Pending;
        RenderPrimary();
        Ui.Say(_status, S.Text(UiStrings.FlashWorkspaceImageValidating));
        var prepared = await Task.Run(() => App.Loader.PrepareFlashAsync(archive, target, CancellationToken.None));
        MainWindow.Instance.Report(prepared);
        _preparing = false;
        _preparation = prepared;
        if (prepared.Plan is { RuntimeAdmissionPreviewPassed: true } plan)
        {
            _lane = await Task.Run(() => App.Loader.FlashLanePreviewAsync(target, plan.Archive.ArchiveSha256));
        }
        await RefreshAsync();
        Ui.Say(_status, prepared.FailureCode is null ? S.Text(UiStrings.FlashWorkspaceReadinessReady) : S.Text(UiStrings.FlashErrorPlan));
    }

    /// <summary>The one submission (macOS <c>submit</c>): the Loader bound first when it will be,
    /// and the plan prepared again for the rebound Target; then the reviewed request submitted and
    /// run to its end while the live status is polled; then its postflight evidence.</summary>
    private async Task SubmitAsync()
    {
        if (_submitting || Plan is not { } plan || _state is not { } state || !CanSubmit(state, plan)) return;
        _submitting = true;
        _submissionFailure = null;
        _submission = null;
        _evidence = null;
        _announcedPhase = null;
        RenderPrimary();
        if (WillActivateLoader && Target is { } target)
        {
            var (rebound, failure) = await Task.Run(() => App.Loader.BindLoaderAsync(target));
            if (rebound is null)
            {
                Finish(null, failure);
                return;
            }
            var prepared = await Task.Run(() => App.Loader.PrepareFlashAsync(plan.ArchivePath, rebound, CancellationToken.None));
            _preparation = prepared;
            if (prepared.Plan is not { Blocking.Count: 0, RuntimeAdmissionPreviewPassed: true } fresh)
            {
                Finish(null, "Loader was bound, but Runtime prerequisites still block Flash");
                return;
            }
            plan = fresh;
        }
        var submitted = await Task.Run(() => App.Loader.SubmitFlashAsync(plan));
        MainWindow.Instance.Report(submitted);
        if (submitted.JobId is not { } jobId)
        {
            Finish(null, submitted.Failure?.ReasonText(S));
            return;
        }
        _jobId = jobId;
        RenderPrimary();
        using var polling = new CancellationTokenSource();
        var poll = PollAsync(jobId, polling.Token);
        var ran = await Task.Run(() => App.Loader.RunFlashAsync(jobId));
        polling.Cancel();
        await poll;
        MainWindow.Instance.Report(ran);
        if (ran.Answer.Value is { State: "succeeded" or "recovered" })
        {
            _evidence = (await Task.Run(() => App.Loader.FlashEvidenceAsync(jobId))).Answer.Value;
        }
        Finish(ran.Answer.Value, ran.Answer.Unavailable?.ReasonText(S));
    }

    private async Task PollAsync(string jobId, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(500, cancellation);
            }
            catch (TaskCanceledException)
            {
                return;
            }
            var status = await Task.Run(() => App.Loader.FlashStatusAsync(jobId));
            if (status.Answer.Value is { } live && _jobId == jobId)
            {
                _live = live;
                RenderPrimary();
                if (live.IsLiveTerminal) return;
            }
        }
    }

    private void Finish(FlashRunStatus? terminal, string? failure)
    {
        _submitting = false;
        _jobId = null;
        _submission = terminal;
        _submissionFailure = failure;
        _ = RefreshAsync();
        Ui.Say(_status, S.Text(VerifiedPostflight ? UiStrings.FlashWorkspaceResultSuccess : UiStrings.FlashWorkspaceResultStopped));
    }

    private async Task CancelAsync(string jobId)
    {
        if (_cancelling) return;
        _cancelling = true;
        var answer = await Task.Run(() => App.Loader.CancelJobAsync(jobId));
        _cancelling = false;
        MainWindow.Instance.Report(answer);
        if (answer.Answer.Value is not { Requested: true }) Ui.Say(_status, S.Text(UiStrings.WindowsDebugJobsCancelFailed));
    }

    private void ResetForAnotherFlash()
    {
        _archive = null;
        _preparation = null;
        _submission = null;
        _submissionFailure = null;
        _evidence = null;
        _live = null;
        _lane = FlashLanePreview.Pending;
        RenderPrimary();
    }

    /// <summary>A byte count as macOS's file-style formatter writes it (decimal units).</summary>
    private static string Size(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        if (bytes < 1000) return $"{bytes} {units[0]}";
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return $"{value.ToString(value < 10 ? "0.#" : "0", CultureInfo.InvariantCulture)} {units[unit]}";
    }
}
