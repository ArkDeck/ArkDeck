using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.RemoteSources;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// Overview: the Runtime's own diagnosis (<c>health</c> + <c>doctor</c>, the macOS
/// "Environment" section; CLI <c>arkdeck doctor</c>) and "Recent Work" (<c>job.list</c>).
/// Everything shown is the daemon's projection as it came back.
/// </summary>
public sealed partial class OverviewPage() : SurfacePage<OverviewState>(
    "overview", "overview.title", UiStrings.AppNavigationOverview,
    "overview.refresh", UiStrings.WindowsActionRefresh, "overview.status.refreshing", UiStrings.OverviewStatusRefreshing)
{
    private string? _preferredTarget;
    private int _remoteGeneration;
    private OverviewTarget? _scoped;
    private string? _resumingJobId;
    private readonly HashSet<string> _expanded = new(StringComparer.Ordinal);

    protected override Task<OverviewState> LoadAsync() => App.Loader.OverviewAsync(_preferredTarget);

    protected override void Render(OverviewState state, StackPanel body)
    {
        // macOS order: what is in scope, what deserves attention next, what just happened; then
        // the Runtime's own diagnosis.
        if (state.Devices is { } devices) MainWindow.Instance.ShowDevices(devices);
        body.Children.Add(Ui.Card(Scope(state), "overview.record.scope"));
        Button? focus = null;
        if (_resumingJobId is { } resuming && state.Recent.Value?.FirstOrDefault(j => j.JobId == resuming) is { } run)
        {
            body.Children.Add(Ui.Card(Resume(state, run, out var cancel), "overview.resume.card"));
            focus = cancel;
        }
        else
        {
            _resumingJobId = null;
        }
        body.Children.Add(Ui.Card(NextStep(state), "overview.record.next"));
        body.Children.Add(Ui.Card(Recent(state), "overview.record.recent"));
        body.Children.Add(Ui.Card(Environment(state), "overview.environment.section"));
        // The sheet takes focus as the macOS sheet does.
        if (focus is not null) focus.Loaded += (_, _) => focus.Focus(Microsoft.UI.Xaml.FocusState.Programmatic);
    }

    // ---- what Overview describes: the device in scope and its remote build server ----

    /// <summary>macOS <c>deviceBar</c>: the adopted device online now that the page describes
    /// (a picker when there are several), and the remote build server bound to it.</summary>
    private FlowPanel Scope(OverviewState state)
    {
        var online = OverviewScope.Online(state.Devices?.Value);
        if (_preferredTarget is not null && online.All(t => t.TargetId != _preferredTarget)) _preferredTarget = null;
        var selected = OverviewScope.Selected(online, _preferredTarget);
        _scoped = selected;

        var device = Ui.Stack(4, Ui.Text("overview.record.device.label", S.Text(UiStrings.OverviewRecordDeviceLabel), "ArkDeckCaptionStyle"));
        if (online.Count > 1)
        {
            var picker = new ComboBox { MinWidth = 260, PlaceholderText = S.Text(UiStrings.OverviewRecordDeviceChoose) };
            AutomationProperties.SetAutomationId(picker, "overview.record.device.picker");
            AutomationProperties.SetName(picker, S.Text(UiStrings.OverviewRecordDeviceLabel));
            foreach (var target in online)
            {
                var item = new ComboBoxItem { Content = target.Title, Tag = target.TargetId };
                AutomationProperties.SetAutomationId(item, "overview.record.device.picker." + target.TargetId);
                picker.Items.Add(item);
                if (target.TargetId == selected?.TargetId) picker.SelectedItem = item;
            }
            picker.SelectionChanged += async (_, _) =>
            {
                if (picker.SelectedItem is not ComboBoxItem { Tag: string id } || id == _preferredTarget) return;
                _preferredTarget = id;
                await RefreshAsync();
            };
            device.Children.Add(picker);
        }
        else
        {
            var name = selected is null ? S.Text(UiStrings.OverviewRecordDeviceNone)
                : selected.Candidate.DeviceName is { Length: > 0 } n ? n : selected.TargetId;
            device.Children.Add(Ui.Text("overview.record.device.name", name, "ArkDeckSectionTitleStyle"));
        }
        var facts = selected is null
            ? S.Text(UiStrings.OverviewRecordDeviceNoneDetail)
            : string.Join(" · ", new[] { selected.TargetId, S.Format(UiStrings.OverviewRecordBinding, selected.BindingRevision) }.Concat(OverviewScope.Facts(selected)));
        device.Children.Add(Ui.Text("overview.record.device.facts", facts, "ArkDeckMonoStyle"));

        var remote = Ui.Stack(4);
        if (selected is { } scoped)
        {
            RenderRemote(remote, new RemoteServerBinding(RemoteServerBindingState.Loading));
            _ = LoadRemoteAsync(remote, scoped.TargetId);
        }
        else
        {
            _remoteGeneration++;
            RenderRemote(remote, new RemoteServerBinding(RemoteServerBindingState.Unbound));
        }
        return Ui.Row(device, remote);
    }

    /// <summary>macOS <c>OverviewRemoteServerViewModel</c>: only an explicit binding of this
    /// Target counts, and a binding to a removed server is stale. The App's own store; no Runtime
    /// call.</summary>
    private async Task LoadRemoteAsync(StackPanel host, string targetId)
    {
        var generation = ++_remoteGeneration;
        RemoteServerBinding result;
        try
        {
            var sources = await Task.Run(() => App.RemoteSources.ListSourcesAsync());
            var binding = await Task.Run(() => App.RemoteSources.BindingAsync(targetId));
            result = binding is null ? new(RemoteServerBindingState.Unbound)
                : sources.FirstOrDefault(s => s.Id == binding.SourceId) is { } source ? new(RemoteServerBindingState.Bound, source.Name, source.Endpoint)
                : new(RemoteServerBindingState.Stale);
        }
        catch (RemoteBuildSourceException error)
        {
            result = new(RemoteServerBindingState.Unavailable, Reason: SettingsPage.RemoteError(error));
        }
        if (generation == _remoteGeneration) RenderRemote(host, result);
    }

    private static void RenderRemote(StackPanel host, RemoteServerBinding binding)
    {
        host.Children.Clear();
        AutomationProperties.SetAutomationId(host, "overview.record.remoteServer");
        host.Children.Add(Ui.Text("overview.record.remoteServer.label", S.Text(UiStrings.OverviewRecordRemoteServerLabel), "ArkDeckCaptionStyle"));
        switch (binding.State)
        {
            case RemoteServerBindingState.Loading:
                host.Children.Add(Ui.Text("overview.record.remoteServer.state", S.Text(UiStrings.OverviewRecordRemoteServerLoading), "ArkDeckCaptionStyle"));
                break;
            case RemoteServerBindingState.Unbound:
                host.Children.Add(Ui.Text("overview.record.remoteServer.state", S.Text(UiStrings.OverviewRecordRemoteServerUnbound), "ArkDeckSectionTitleStyle"));
                host.Children.Add(Ui.Text("overview.record.remoteServer.detail", S.Text(UiStrings.OverviewRecordRemoteServerUnboundDetail), "ArkDeckCaptionStyle"));
                break;
            case RemoteServerBindingState.Bound:
                host.Children.Add(Ui.Row(Ui.Text("overview.record.remoteServer.name", binding.Name!, "ArkDeckSectionTitleStyle"),
                    Ui.Text("overview.record.remoteServer.state", S.Text(UiStrings.OverviewRecordRemoteServerBound), "ArkDeckCaptionStyle")));
                var endpoint = Ui.Text("overview.record.remoteServer.endpoint", binding.Endpoint!, "ArkDeckMonoStyle");
                endpoint.IsTextSelectionEnabled = true;
                host.Children.Add(endpoint);
                break;
            case RemoteServerBindingState.Stale:
                host.Children.Add(Ui.Text("overview.record.remoteServer.state", S.Text(UiStrings.OverviewRecordRemoteServerStale), "ArkDeckSectionTitleStyle"));
                host.Children.Add(Ui.Text("overview.record.remoteServer.detail", S.Text(UiStrings.OverviewRecordRemoteServerStaleDetail), "ArkDeckCaptionStyle"));
                break;
            default:
                host.Children.Add(Ui.Text("overview.record.remoteServer.state", S.Text(UiStrings.OverviewRecordRemoteServerUnavailable), "ArkDeckSectionTitleStyle"));
                host.Children.Add(Ui.Text("overview.record.remoteServer.detail", binding.Reason ?? "", "ArkDeckMonoStyle"));
                break;
        }
    }

    // ---- the HDC environment (macOS HDCStatusView) ----

    private bool _hdcExpanded;
    private CapabilityMatrix? _probed;

    /// <summary>macOS <c>environmentSection</c>: four summary facts, and behind the disclosure the
    /// server and toolchain, the capability matrix, the device and channel, what needs attention
    /// and the advanced facts. Read only: the Runtime owns HDC selection and recovery.</summary>
    private StackPanel HdcBlock(OverviewState state)
    {
        var hdc = state.Hdc!;
        var matrix = _probed is { } probed && probed.TargetId == state.Capabilities?.TargetId && probed.BindingRevision == state.Capabilities?.BindingRevision
            ? probed : state.Capabilities!;
        var attention = hdc.TrustReady ? 0 : 1;
        var panel = Ui.Stack(8);
        var toggle = Ui.Button("overview.advanced.toggle",
            $"{S.Text(UiStrings.OverviewEnvironmentTitle)} · {S.Text(_hdcExpanded ? UiStrings.OverviewEnvironmentExpanded : UiStrings.OverviewEnvironmentCollapsed)}", (_, _) =>
            {
                _hdcExpanded = !_hdcExpanded;
                Rerender();
            });
        toggle.KeyboardAccelerators.Add(new Microsoft.UI.Xaml.Input.KeyboardAccelerator
        {
            Key = Windows.System.VirtualKey.D,
            Modifiers = Windows.System.VirtualKeyModifiers.Control | Windows.System.VirtualKeyModifiers.Shift,
        });
        panel.Children.Add(toggle);
        panel.Children.Add(Ui.Row(
            Ui.Text("overview.status.server.value", S.Text("overview.serverHealth." + hdc.Health), "ArkDeckCaptionStyle"),
            Ui.Text("overview.status.trust.value", S.Text(hdc.Trust switch
            {
                "ready" => UiStrings.OverviewTrustReady,
                "waiting" => UiStrings.OverviewTrustWaiting,
                _ => UiStrings.OverviewTrustUnavailable,
            }), "ArkDeckCaptionStyle"),
            Ui.Text("overview.status.channel.value", S.Text(UiStrings.OverviewChannelUnverified), "ArkDeckCaptionStyle"),
            Ui.Text("overview.status.needsAttention.value", attention == 0 ? S.Text(UiStrings.OverviewStatusNeedsAttentionNone) : S.Text(UiStrings.OverviewStatusNeedsAttentionOne), "ArkDeckCaptionStyle")));
        if (!_hdcExpanded) return panel;

        panel.Children.Add(Ui.Heading("overview.section.serverToolchain", S.Text(UiStrings.OverviewSectionServerToolchain), AutomationHeadingLevel.Level3));
        foreach (var (id, key, value) in new[]
                 {
                     ("hdc.health", UiStrings.OverviewFieldServerHealth, hdc.Health),
                     ("hdc.endpoint", UiStrings.OverviewFieldEndpoint, hdc.Endpoint),
                     ("hdc.toolchain.clientVersion", UiStrings.OverviewFieldClientVersion, hdc.ClientVersion),
                     ("hdc.toolchain.serverVersion", UiStrings.OverviewFieldServerVersion, hdc.ServerVersion),
                     ("hdc.toolchain.daemonVersion", UiStrings.OverviewFieldDaemonVersion, hdc.DaemonVersion),
                     ("hdc.toolchain.source", UiStrings.OverviewFieldSource, HdcEnvironment.Source),
                     ("hdc.toolchain.trust", UiStrings.OverviewFieldPlatformTrust, HdcEnvironment.PlatformTrust),
                 })
        {
            panel.Children.Add(Ui.Fact(id, S.Text(key), value));
        }

        panel.Children.Add(Ui.Heading("overview.section.capabilities", S.Text(UiStrings.OverviewSectionCapabilities), AutomationHeadingLevel.Level3));
        panel.Children.Add(Ui.Fact("hdc.ownership", S.Text(UiStrings.OverviewFieldOwnership), hdc.Ownership));
        panel.Children.Add(Ui.Fact("hdc.subserver", S.Text(UiStrings.OverviewFieldSubserver), HdcEnvironment.Subserver));
        panel.Children.Add(Ui.Fact("hdc.lifecycle.availability", S.Text(UiStrings.OverviewFieldLifecycleAvailability), HdcEnvironment.LifecycleAvailability));
        panel.Children.Add(Ui.Text("overview.capabilities.matrixTitle", matrix.TargetId is { } target
            ? S.Format(UiStrings.OverviewCapabilitiesTitleTarget, target, matrix.BindingRevision ?? 0)
            : S.Text(UiStrings.OverviewCapabilitiesTitleNoTarget), "ArkDeckCaptionStyle"));
        if (matrix.Failure is { } failure && matrix.Items.Count == 0)
        {
            panel.Children.Add(Ui.Text("overview.capabilities.failure", failure, "ArkDeckCaptionStyle"));
        }
        else
        {
            if (matrix.Failure is { } why) panel.Children.Add(Ui.Text("overview.capabilities.failure", why, "ArkDeckCaptionStyle"));
            var rows = Ui.List("overview.capabilities.matrix", matrix.TargetId is { } t
                ? S.Format(UiStrings.OverviewCapabilitiesTitleTarget, t, matrix.BindingRevision ?? 0)
                : S.Text(UiStrings.OverviewCapabilitiesTitleNoTarget));
            foreach (var item in matrix.Items)
            {
                var stateText = S.Text("overview.capabilities.state." + item.State);
                rows.Items.Add(Ui.Item("overview.capabilities." + item.Id, $"{item.Name}: {stateText} · {item.Evidence}", Ui.Stack(2,
                    Ui.Row(Ui.Text($"overview.capabilities.{item.Id}.name", item.Name, "ArkDeckMonoStyle"),
                        Ui.Text($"overview.capabilities.{item.Id}.state", stateText)),
                    Ui.Text($"overview.capabilities.{item.Id}.evidence", item.Evidence, "ArkDeckMonoStyle"))));
            }
            panel.Children.Add(rows);
            if (matrix.TargetId is { } scopedTarget && matrix.BindingRevision is { } binding)
            {
                // The hidumper row is proved by a read-only Job, run when asked (each run is a
                // new Job in History), not on every refresh.
                var status = Ui.Status("overview.capabilities.hidumper.status");
                panel.Children.Add(Ui.Row(Ui.Button("overview.capabilities.hidumper.check", S.Text(UiStrings.WindowsOverviewHdcCheckHidumper),
                    async (_, _) => await CheckHidumperAsync(matrix, scopedTarget, binding, status)), status));
            }
        }

        panel.Children.Add(Ui.Heading("overview.section.deviceChannel", S.Text(UiStrings.OverviewSectionDeviceChannel), AutomationHeadingLevel.Level3));
        panel.Children.Add(Ui.Fact("hdc.authorization", S.Text(UiStrings.OverviewFieldAuthorization), hdc.AuthorizationText));
        panel.Children.Add(Ui.Fact("hdc.channelProtection", S.Text(UiStrings.OverviewFieldChannelProtection), HdcEnvironment.ChannelProtection));
        panel.Children.Add(Ui.Fact("hdc.devices.events", S.Text(UiStrings.OverviewFieldDeviceEvents), HdcEnvironment.DeviceEvents));

        panel.Children.Add(Ui.Heading("hdc.section.needsAttention", S.Text(UiStrings.OverviewSectionNeedsAttention), AutomationHeadingLevel.Level3));
        if (attention == 0)
        {
            panel.Children.Add(Ui.Text("hdc.attention.clear", S.Text(UiStrings.OverviewAttentionClear), "ArkDeckCaptionStyle"));
        }
        else
        {
            panel.Children.Add(Ui.Text("overview.attention.trust", S.Text(UiStrings.OverviewAttentionTrust), "ArkDeckSectionTitleStyle"));
            panel.Children.Add(Ui.Text("overview.attention.trust.reason", hdc.AuthorizationText));
            panel.Children.Add(Ui.Text("overview.attention.trust.nextStep", S.Text(UiStrings.OverviewAttentionNextStepRefresh), "ArkDeckCaptionStyle"));
        }
        panel.Children.Add(Ui.Text("hdc.lifecycle.recoveryUnavailable", HdcEnvironment.RecoveryUnavailable, "ArkDeckCaptionStyle"));
        panel.Children.Add(Ui.Text("hdc.lifecycle.previewRequirement", HdcEnvironment.RecoveryRequirement, "ArkDeckCaptionStyle"));

        panel.Children.Add(Ui.Heading("overview.section.advanced", S.Text(UiStrings.OverviewSectionAdvanced), AutomationHeadingLevel.Level3));
        foreach (var (id, key, value) in new[]
                 {
                     ("hdc.toolchain.path", UiStrings.OverviewFieldPath, HdcEnvironment.AbsolutePath),
                     ("hdc.toolchain.hash", UiStrings.OverviewFieldHash, hdc.Hash),
                     ("hdc.generation", UiStrings.OverviewFieldGeneration, hdc.Generation),
                     ("hdc.endpoint.source", UiStrings.OverviewFieldEndpointSource, hdc.EndpointSource ?? "unknown"),
                     ("hdc.ownership.basis", UiStrings.OverviewFieldOwnershipBasis, HdcEnvironment.OwnershipBasis),
                     ("hdc.counters.autoLifecycle", UiStrings.OverviewFieldAutoLifecycleDispatches, HdcEnvironment.Counter),
                     ("hdc.counters.autoSubserver", UiStrings.OverviewFieldAutoSubserverDispatches, HdcEnvironment.Counter),
                 })
        {
            panel.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        return panel;
    }

    /// <summary>macOS <c>DebugWindowInventoryJobRunner</c>: one read-only
    /// <c>debug.template@1</c> window inventory on the device in scope, run to its end.</summary>
    private async Task CheckHidumperAsync(CapabilityMatrix matrix, string targetId, long binding, TextBlock status)
    {
        Ui.Say(status, S.Text(UiStrings.OverviewCapabilitiesLoading));
        var target = new TargetSummary(targetId, null, "0", binding, "", "");
        var submitted = await Task.Run(() => App.Loader.SubmitTemplateAsync(target, "device.windowInventory"));
        MainWindow.Instance.Report(submitted);
        if (submitted.JobId is not { } jobId)
        {
            _probed = matrix.WithWindowInventoryFailure(submitted.Failure is { } f ? $"{f.ReasonCode}: {f.Detail}" : "debug.template@1 was not admitted");
            Rerender();
            return;
        }
        var ran = await Task.Run(() => App.Loader.RunJobAsync(jobId, CliCommands.ForJob(CliCommands.JobRun, jobId)));
        MainWindow.Instance.Report(ran);
        _probed = ran.Answer.Value is { } terminal
            ? matrix.WithWindowInventory(jobId, terminal.State, terminal.OutcomeUnknown)
            : matrix.WithWindowInventoryFailure($"{ran.Answer.Unavailable!.ReasonCode}: {ran.Answer.Unavailable.Detail}");
        Rerender();
    }

    private StackPanel Environment(OverviewState state)
    {
        var panel = Ui.Stack(8, Ui.Heading("overview.environment", S.Text(UiStrings.OverviewEnvironmentTitle)));
        if (state.Hdc is not null && state.Capabilities is not null) panel.Children.Add(HdcBlock(state));
        if (state.Doctor.Unavailable is { } why)
        {
            panel.Children.Add(Ui.UnavailableNotice("overview.doctor.unavailable", UiStrings.WindowsOverviewDoctorUnavailable, why));
            return panel;
        }
        var doctor = state.Doctor.Value!;
        var overallKey = "windows.overview.doctor.overall." + doctor.Overall;
        var overall = UiStrings.All.Contains(overallKey) ? S.Text(overallKey) : doctor.Overall;
        panel.Children.Add(Ui.Text("overview.doctor.overall", S.Format(UiStrings.WindowsOverviewDoctorOverall, overall), "ArkDeckSectionTitleStyle"));
        panel.Children.Add(Ui.Text("overview.doctor.counts", S.Format(UiStrings.WindowsOverviewDoctorCounts, doctor.Blockers, doctor.Warnings, doctor.Info), "ArkDeckCaptionStyle"));
        panel.Children.Add(Fact("overview.runtime.protocol", UiStrings.WindowsOverviewRuntimeProtocol, doctor.RuntimeProtocolVersion));
        if (state.Health.Value is { } health)
        {
            panel.Children.Add(Fact("overview.runtime.contract", UiStrings.WindowsOverviewRuntimeContract, health.ContractIdentity));
        }
        panel.Children.Add(Fact("overview.runtime.operations", UiStrings.WindowsOverviewRuntimeOperations,
            S.Format(UiStrings.WindowsOverviewRuntimeOperationsValue, doctor.AvailableOperationCount, doctor.OperationCount)));

        panel.Children.Add(Ui.Heading("overview.section.needsAttention", S.Text(UiStrings.OverviewSectionNeedsAttention)));
        var attention = doctor.Findings.Where(f => f.Severity is "blocker" or "warning").ToArray();
        if (attention.Length == 0)
        {
            panel.Children.Add(Ui.Text("overview.attention.clear", S.Text(UiStrings.OverviewAttentionClear)));
        }
        var findings = Ui.List("overview.doctor.findings", S.Text(UiStrings.WindowsOverviewDoctorTitle));
        foreach (var finding in doctor.Findings)
        {
            var severityKey = "windows.overview.doctor.severity." + finding.Severity;
            var severity = UiStrings.All.Contains(severityKey) ? S.Text(severityKey) : finding.Severity;
            var name = $"{severity}: {finding.Summary} ({finding.Code})";
            findings.Items.Add(Ui.Item("overview.doctor.finding." + finding.Code, name,
                Ui.Stack(2, Ui.Text("overview.doctor.finding." + finding.Code + ".severity", severity, "ArkDeckCaptionStyle"),
                    Ui.Text("overview.doctor.finding." + finding.Code + ".summary", $"{finding.Summary} ({finding.Code})"))));
        }
        panel.Children.Add(findings);
        return panel;
    }

    // ---- what deserves attention next, and what just happened (macOS nextStepSection, recordSection) ----

    /// <summary>macOS <c>nextStepSection</c>: the first line's featured run, what it means now and
    /// how to continue it; else where to start.</summary>
    private StackPanel NextStep(OverviewState state)
    {
        var panel = Ui.Stack(8, Ui.Heading("overview.record.next.title", S.Text(UiStrings.OverviewRecordNextTitle)));
        if (state.Threads.FirstOrDefault() is not { } thread || OverviewRuns.Featured(thread) is not { } run)
        {
            var empty = Ui.Stack(4,
                Ui.Text("overview.record.next.empty.title", S.Text(UiStrings.OverviewRecordNextEmptyTitle), "ArkDeckSectionTitleStyle"),
                Ui.Text("overview.record.next.empty.detail", S.Text(UiStrings.OverviewRecordNextEmptyDetail), "ArkDeckCaptionStyle"));
            AutomationProperties.SetAutomationId(empty, "overview.record.next.empty");
            panel.Children.Add(empty);
            return panel;
        }
        var attention = OverviewRuns.NeedsAttention(run);
        var summary = Ui.Stack(4);
        AutomationProperties.SetAutomationId(summary, "overview.record.next." + run.JobId);
        summary.Children.Add(attention
            ? Ui.Text("overview.record.next.attention", S.Text(UiStrings.OverviewRecordNextAttention), "ArkDeckSectionTitleStyle")
            : Ui.Row(Ui.Text("overview.record.next.workspace", WorkspaceTitle(state, run), "ArkDeckSectionTitleStyle"),
                Ui.Text("overview.record.next.state", S.Text(RunStateKey(run.State)), "ArkDeckCaptionStyle")));
        if (attention) summary.Children.Add(Ui.Text("overview.record.next.workspace", WorkspaceTitle(state, run)));
        summary.Children.Add(Ui.Text("overview.record.next.detail", NextDetail(run, thread), "ArkDeckCaptionStyle"));
        summary.Children.Add(Ui.Text("overview.record.next.operation", $"{run.TargetId} · {OverviewRuns.DisplayedOperation(run.Operation)}", "ArkDeckMonoStyle"));
        panel.Children.Add(summary);

        var actions = Ui.Row(Ui.Button("overview.record.next.open", S.Text(UiStrings.OverviewRecordRunOpen), async (_, _) => await MainWindow.Instance.OpenJobAsync(run.JobId)));
        switch (state.DispositionOf(run))
        {
            case ResumeDisposition.Resumable:
                actions.Children.Add(Ui.Button("overview.record.next.again", S.Text(UiStrings.OverviewRecordRunAgain), (_, _) => StartResume(run), accent: true));
                break;
            case ResumeDisposition.RequiresAuthorization:
                actions.Children.Add(Ui.Button("overview.record.next.again", S.Text(UiStrings.OverviewRecordRunAgainGated), (_, _) => StartResume(run), accent: true));
                break;
        }
        panel.Children.Add(actions);
        return panel;
    }

    private static string NextDetail(JobSummary run, OverviewRunThread thread)
    {
        if (run.OutcomeUnknown && !JobRecovery.HasEstablishedCurrentEpoch(run)) return S.Text(UiStrings.OverviewRecordNextUnknownDetail);
        if (run.WaitingForHuman) return S.Text(UiStrings.OverviewRecordNextWaitingDetail);
        if (run.OutstandingResidueCount > 0) return S.Format(UiStrings.OverviewRecordNextResidueDetail, run.OutstandingResidueCount);
        return S.Format(UiStrings.OverviewRecordNextRecentDetail, (long)thread.Runs.Count, RunOutcome(run));
    }

    /// <summary>macOS <c>recordSection</c>: the lines of work, each with its featured run and its
    /// other recent runs behind Show more; the archive stays in History.</summary>
    private StackPanel Recent(OverviewState state)
    {
        var panel = Ui.Stack(8, Ui.Row(Ui.Heading("overview.record.recent.title", S.Text(UiStrings.OverviewRecordRecentTitle)),
            Ui.Button("overview.record.recent.all", S.Text(UiStrings.OverviewRecordRecentAll), (_, _) => MainWindow.Instance.Select("history"))));
        if (state.Recent.Unavailable is { } why)
        {
            panel.Children.Add(Ui.UnavailableNotice("overview.record.recent.unavailable", UiStrings.OverviewRecordRecentUnavailableTitle, why));
            return panel;
        }
        var threads = state.Threads;
        if (threads.Count == 0)
        {
            panel.Children.Add(Ui.Text("overview.record.empty", S.Text(UiStrings.OverviewRecordRecentEmpty)));
            return panel;
        }
        foreach (var thread in threads) panel.Children.Add(ThreadCard(state, thread));
        return panel;
    }

    private Border ThreadCard(OverviewState state, OverviewRunThread thread)
    {
        var featured = OverviewRuns.Featured(thread)!;
        var others = OverviewRuns.Additional(thread, featured);
        var header = Ui.Stack(2,
            Ui.Text($"overview.record.thread.{thread.Id}.title", WorkspaceTitle(state, featured), "ArkDeckSectionTitleStyle"),
            Ui.Text($"overview.record.thread.{thread.Id}.subtitle", $"{thread.TargetId} · {S.Format(UiStrings.OverviewRecordRunCount, (long)thread.Runs.Count)}", "ArkDeckCaptionStyle"));
        AutomationProperties.SetAutomationId(header, "overview.record.thread." + thread.Id);
        var top = Ui.Row(header);
        if (thread.NeedsAttention)
        {
            top.Children.Add(Ui.Text($"overview.record.thread.{thread.Id}.needsAttention", S.Text(UiStrings.OverviewRecordThreadNeedsAttention), "ArkDeckCaptionStyle"));
        }
        var card = Ui.Stack(6, top, RunRow(state, featured));
        if (others.Count > 0)
        {
            var expanded = _expanded.Contains(thread.Id);
            // Show/hide buttons rather than an Expander, whose content UIA does not expose.
            card.Children.Add(Ui.Button($"overview.record.thread.{thread.Id}.more",
                expanded ? S.Text(UiStrings.WindowsOverviewThreadLess) : S.Format(UiStrings.OverviewRecordThreadMore, (long)others.Count), (_, _) =>
                {
                    if (!_expanded.Remove(thread.Id)) _expanded.Add(thread.Id);
                    Rerender();
                }));
            if (expanded)
            {
                foreach (var run in others) card.Children.Add(RunRow(state, run));
            }
        }
        return Ui.Card(card, $"overview.record.thread.{thread.Id}.card");
    }

    private FlowPanel RunRow(OverviewState state, JobSummary run)
    {
        var row = Ui.Row(Ui.Text("overview.record.run." + run.JobId, run.JobId, "ArkDeckMonoStyle"));
        if (run.ActualEffect is { } effect) row.Children.Add(Ui.Text($"overview.record.run.{run.JobId}.effect", effect, "ArkDeckCaptionStyle"));
        row.Children.Add(Ui.Text($"overview.record.run.{run.JobId}.outcome", RunOutcome(run), "ArkDeckCaptionStyle"));
        var disposition = state.DispositionOf(run);
        switch (disposition)
        {
            case ResumeDisposition.Resumable or ResumeDisposition.DetailNotLoaded:
                row.Children.Add(Ui.Button($"overview.record.run.{run.JobId}.again", S.Text(UiStrings.OverviewRecordRunAgain), (_, _) => StartResume(run)));
                break;
            case ResumeDisposition.RequiresAuthorization:
                row.Children.Add(Ui.Button($"overview.record.run.{run.JobId}.again", S.Text(UiStrings.OverviewRecordRunAgainGated), (_, _) => StartResume(run)));
                break;
            default:
                row.Children.Add(Ui.Text($"overview.record.run.{run.JobId}.refusal", S.Text(RefusalKey(disposition)), "ArkDeckCaptionStyle"));
                break;
        }
        row.Children.Add(Ui.Button($"overview.record.run.{run.JobId}.open", S.Text(UiStrings.OverviewRecordRunOpen), async (_, _) => await MainWindow.Instance.OpenJobAsync(run.JobId)));
        return row;
    }

    private static string RefusalKey(ResumeDisposition disposition) => disposition switch
    {
        ResumeDisposition.NeverReplayed => UiStrings.OverviewRecordRefusalNeverReplayed,
        ResumeDisposition.NotTerminal => UiStrings.OverviewRecordRefusalNotTerminal,
        ResumeDisposition.EffectUnknown => UiStrings.OverviewRecordRefusalEffectUnknown,
        _ => UiStrings.OverviewRecordRefusalParametersNotReported,
    };

    /// <summary>macOS <c>workspaceTitle(for:)</c>: the workspace that ran it, else the operation.</summary>
    private static string WorkspaceTitle(OverviewState state, JobSummary run) =>
        OverviewRuns.TitleKind(run.Operation, state.EvidenceOf(run.JobId)?.Parameters) switch
        {
            WorkspaceKind.Viewer => S.Text(UiStrings.OverviewRecordWorkspaceViewer),
            WorkspaceKind.Trace => S.Text(UiStrings.OverviewRecordWorkspaceTrace),
            WorkspaceKind.Debug => S.Text(UiStrings.OverviewRecordWorkspaceDebug),
            WorkspaceKind.Flash => S.Text(UiStrings.OverviewRecordWorkspaceFlash),
            WorkspaceKind.Device => S.Text(UiStrings.OverviewRecordWorkspaceDevice),
            _ => OverviewRuns.DisplayedOperation(run.Operation),
        };

    /// <summary>macOS <c>runOutcome</c>: the state, an unknown effect, residue, and when.</summary>
    private static string RunOutcome(JobSummary run)
    {
        var parts = new List<string> { run.State };
        if (run.OutcomeUnknown && !JobRecovery.HasEstablishedCurrentEpoch(run)) parts.Add(S.Text(UiStrings.OverviewRecordRunOutcomeUnknown));
        if (run.OutstandingResidueCount > 0) parts.Add(S.Format(UiStrings.OverviewRecordResidue, run.OutstandingResidueCount));
        parts.Add(run.FinishedAtUtc ?? run.StartedAtUtc ?? run.CreatedAtUtc);
        return string.Join(" · ", parts);
    }

    /// <summary>The macOS Overview run chip (<c>OverviewRecordView.swift</c>): four named
    /// outcomes, everything else "In progress".</summary>
    private static string RunStateKey(string state) => state switch
    {
        "succeeded" or "recovered" => UiStrings.OverviewRecordStateSucceeded,
        "failed" => UiStrings.OverviewRecordStateFailed,
        "interrupted" => UiStrings.OverviewRecordStateInterrupted,
        "cancelled" => UiStrings.OverviewRecordStateCancelled,
        _ => UiStrings.OverviewRecordStateInProgress,
    };

    // ---- Run It Again (macOS OverviewResumeSheet) ----

    private void StartResume(JobSummary run)
    {
        _resumingJobId = run.JobId;
        Rerender();
    }

    /// <summary>macOS <c>OverviewResumeSheet</c>, shown in place above the record: what the source
    /// run recorded, which facts still hold, and either the typed inputs or why there are none.
    /// It opens the source workspace or prepares a read-only draft; neither submits.</summary>
    private StackPanel Resume(OverviewState state, JobSummary run, out Button focus)
    {
        var evidence = state.EvidenceOf(run.JobId);
        var disposition = state.DispositionOf(run);
        var panel = Ui.Stack(8);
        AutomationProperties.SetAutomationId(panel, "overview.resume");
        panel.Children.Add(Ui.Row(Ui.Heading("overview.resume.title", S.Text(UiStrings.OverviewResumeTitle)),
            Ui.Text("overview.resume.operation", run.Operation, "ArkDeckMonoStyle")));
        panel.Children.Add(Ui.Text("overview.resume.explanation", S.Text(UiStrings.OverviewResumeExplanation), "ArkDeckCaptionStyle"));
        panel.Children.Add(Ui.Fact("overview.resume.source", S.Text(UiStrings.OverviewResumeSource), $"{run.JobId} · {run.State}"));
        panel.Children.Add(Ui.Fact("overview.resume.thread", S.Text(UiStrings.OverviewResumeThread), run.ThreadId ?? S.Text(UiStrings.OverviewRecordThreadUngrouped)));
        panel.Children.Add(Ui.Fact("overview.resume.target", S.Text(UiStrings.OverviewResumeTarget), run.TargetId));
        panel.Children.Add(Ui.Fact("overview.resume.effect", S.Text(UiStrings.OverviewResumeEffect), run.ActualEffect ?? S.Text(UiStrings.OverviewResumeEffectUnrecorded)));
        // Provenance, not a verdict: the App is not given the current Catalog digest.
        if (evidence is not null) panel.Children.Add(Ui.Fact("overview.resume.catalogDigest", S.Text(UiStrings.OverviewResumeCatalogDigest), evidence.CatalogDigest));

        var targetId = _scoped?.TargetId;
        var binding = _scoped?.BindingRevision;
        if (targetId != run.TargetId) panel.Children.Add(Ui.Text("overview.resume.drift.target", S.Text(UiStrings.OverviewResumeDriftTarget)));
        else if (evidence?.BindingRevision is not { } recorded || binding is null) panel.Children.Add(Ui.Text("overview.resume.drift.unknown", S.Text(UiStrings.OverviewResumeDriftUnknown), "ArkDeckCaptionStyle"));
        else if (recorded != binding) panel.Children.Add(Ui.Text("overview.resume.drift.binding", S.Text(UiStrings.OverviewResumeDriftBinding)));

        switch (disposition)
        {
            case ResumeDisposition.ParametersNotReported or ResumeDisposition.DetailNotLoaded:
                panel.Children.Add(Ui.Text("overview.resume.noParameters", S.Text(UiStrings.OverviewResumeNoParameters)));
                break;
            case ResumeDisposition.RequiresAuthorization:
                panel.Children.Add(Ui.Text("overview.resume.gated", S.Format(UiStrings.OverviewResumeGated, run.ActualEffect ?? "")));
                break;
            case ResumeDisposition.NeverReplayed:
                panel.Children.Add(Ui.Text("overview.resume.neverReplayed", S.Text(UiStrings.OverviewResumeNeverReplayed)));
                break;
            case ResumeDisposition.NotTerminal or ResumeDisposition.EffectUnknown:
                panel.Children.Add(Ui.Text("overview.resume.notRepeatable", S.Text(UiStrings.OverviewResumeNotRepeatable)));
                break;
            default:
                panel.Children.Add(Ui.Text("overview.resume.parameters", S.Text(UiStrings.OverviewResumeParameters), "ArkDeckCaptionStyle"));
                foreach (var (name, value) in evidence!.DisplayParameters) panel.Children.Add(Ui.Fact("overview.resume.parameter." + name, name, value));
                panel.Children.Add(Ui.Text("overview.resume.parameters.note", S.Text(UiStrings.OverviewResumeParametersNote), "ArkDeckCaptionStyle"));
                break;
        }
        var (draft, failure) = WorkspaceContinuation.Prepare(run, evidence, targetId, binding);
        if (failure is not null)
        {
            panel.Children.Add(Ui.Text("overview.resume.prepare.reason", $"{S.Text(UiStrings.OverviewResumePrepareUnavailable)} · {failure}", "ArkDeckCaptionStyle"));
        }
        var status = Ui.Status("overview.resume.status");
        var cancel = Ui.Button("overview.resume.cancel", S.Text(UiStrings.OverviewResumeCancel), (_, _) =>
        {
            _resumingJobId = null;
            Rerender();
        });
        var open = Ui.Button("overview.resume.open", S.Text(UiStrings.OverviewResumeOpen), (_, _) =>
        {
            // XPA-AC-8: enabled; where macOS disables it, the refusal is said instead.
            if (disposition != ResumeDisposition.Resumable)
            {
                Ui.Say(status, S.Text(UiStrings.WindowsOverviewResumeOpenRefused));
                return;
            }
            if (OverviewRuns.OpenKind(run, evidence?.Parameters) is not { } kind)
            {
                Ui.Say(status, S.Text(UiStrings.WindowsOverviewResumeOpenUnknown));
                return;
            }
            _resumingJobId = null;
            MainWindow.Instance.Select(MainWindow.Tag(kind));
        });
        var prepare = Ui.Button("overview.resume.prepare", S.Text(UiStrings.OverviewResumePrepare), (_, _) =>
        {
            if (draft is null)
            {
                Ui.Say(status, $"{S.Text(UiStrings.OverviewResumePrepareUnavailable)} · {failure}");
                return;
            }
            _resumingJobId = null;
            MainWindow.Instance.PrepareContinuation(draft, targetId, binding);
        }, accent: true);
        panel.Children.Add(Ui.Row(cancel, open, prepare, status));
        focus = cancel;
        return panel;
    }

    private static Grid Fact(string id, string labelKey, string value) => Ui.Fact(id, S.Text(labelKey), value);
}
