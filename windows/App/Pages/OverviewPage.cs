using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
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
    protected override Task<OverviewState> LoadAsync() => App.Loader.OverviewAsync();

    protected override void Render(OverviewState state, StackPanel body)
    {
        body.Children.Add(Ui.Card(Environment(state), "overview.environment.section"));
        body.Children.Add(Ui.Card(Recent(state), "overview.record.recent"));
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
