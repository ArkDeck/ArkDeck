using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.RemoteSources;
using Microsoft.UI.Xaml.Automation;
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

    protected override Task<OverviewState> LoadAsync() => App.Loader.OverviewAsync();

    protected override void Render(OverviewState state, StackPanel body)
    {
        body.Children.Add(Ui.Card(Scope(state), "overview.record.scope"));
        body.Children.Add(Ui.Card(Environment(state), "overview.environment.section"));
        body.Children.Add(Ui.Card(Recent(state), "overview.record.recent"));
    }

    // ---- what Overview describes: the device in scope and its remote build server ----

    /// <summary>macOS <c>deviceBar</c>: the adopted device online now that the page describes
    /// (a picker when there are several), and the remote build server bound to it.</summary>
    private FlowPanel Scope(OverviewState state)
    {
        var online = OverviewScope.Online(state.Devices?.Value);
        if (_preferredTarget is not null && online.All(t => t.TargetId != _preferredTarget)) _preferredTarget = null;
        var selected = OverviewScope.Selected(online, _preferredTarget);

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

    private static StackPanel Environment(OverviewState state)
    {
        var panel = Ui.Stack(8, Ui.Heading("overview.environment", S.Text(UiStrings.OverviewEnvironmentTitle)));
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

    private static StackPanel Recent(OverviewState state)
    {
        var panel = Ui.Stack(8, Ui.Heading("overview.record.recent.title", S.Text(UiStrings.OverviewRecordRecentTitle)));
        if (state.Recent.Unavailable is { } why)
        {
            panel.Children.Add(Ui.UnavailableNotice("overview.record.recent.unavailable", UiStrings.OverviewRecordRecentUnavailableTitle, why));
            return panel;
        }
        var jobs = state.Recent.Value!;
        if (jobs.Count == 0)
        {
            panel.Children.Add(Ui.Text("overview.record.empty", S.Text(UiStrings.OverviewRecordRecentEmpty)));
            return panel;
        }
        var list = Ui.List("overview.record.recent.list", S.Text(UiStrings.OverviewRecordRecentTitle));
        foreach (var job in jobs)
        {
            var chip = S.Text(RunStateKey(job.State));
            list.Items.Add(Ui.Item("overview.record.run." + job.JobId, $"{job.Operation}, {chip}",
                Ui.Row(Ui.Text("overview.record.run." + job.JobId + ".outcome", chip, "ArkDeckCaptionStyle"),
                    Ui.Text("overview.record.run." + job.JobId + ".operation", job.Operation, "ArkDeckMonoStyle"))));
        }
        panel.Children.Add(list);
        return panel;
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

    private static Grid Fact(string id, string labelKey, string value) => Ui.Fact(id, S.Text(labelKey), value);
}
