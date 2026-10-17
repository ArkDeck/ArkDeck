using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

public sealed partial class FlashPage
{
    private bool _maintaining;
    private string? _maintenanceTarget;
    private string? _maintenanceSource;
    private FlashRunStatus? _maintenanceStatus;
    private string? _maintenanceFailure;

    private StackPanel Maintenance(FlashState state)
    {
        var panel = Ui.Stack(8, Ui.Heading("flash.maintenance.title", S.Text(UiStrings.FlashMaintenanceTitle)),
            Ui.Text("flash.maintenance.detail", S.Text(UiStrings.FlashMaintenanceDetail)));
        var sources = (state.Jobs.Value ?? []).Where(j => j.TargetId == _targetId && j.Operation is "flash.full-restore@1" or "flash.dayu200" or "flash.restore-boot-loop@1").ToArray();
        if (!sources.Any(j => j.JobId == _maintenanceSource)) _maintenanceSource = sources.FirstOrDefault()?.JobId;
        if (sources.Length == 0) panel.Children.Add(Ui.Text("flash.maintenance.noSource", S.Text(UiStrings.FlashMaintenanceNoSource)));
        else
        {
            var picker = new ComboBox { Header = S.Text(UiStrings.FlashMaintenanceSource), ItemsSource = sources.Select(j => j.JobId).ToArray(), SelectedItem = _maintenanceSource };
            picker.SelectionChanged += (_, _) => _maintenanceSource = picker.SelectedItem as string;
            panel.Children.Add(picker);
            var verify = Ui.Button("flash.maintenance.verify", S.Text(UiStrings.FlashMaintenanceVerify), async (_, _) => await MaintainAsync(false));
            var restore = Ui.Button("flash.maintenance.restore", S.Text(UiStrings.FlashMaintenanceRestore), async (_, _) => await MaintainAsync(true));
            verify.IsEnabled = !_maintaining && !_submitting;
            restore.IsEnabled = verify.IsEnabled && _archive is not null;
            panel.Children.Add(Ui.Row(verify, restore));
            if (_archive is null) panel.Children.Add(Ui.Text("flash.maintenance.archive", S.Text(UiStrings.FlashMaintenanceArchive)));
        }
        if (_maintaining) panel.Children.Add(Ui.Text("flash.maintenance.busy", S.Text(UiStrings.FlashMaintenanceBusy)));
        if (_maintenanceTarget == _targetId && _maintenanceFailure is { } failure) panel.Children.Add(Ui.Text("flash.maintenance.failure", failure));
        var status = _maintenanceTarget == _targetId ? _maintenanceStatus : null;
        if (status is null && state.FocusedStatus is { } focused && (state.Jobs.Value ?? []).Any(j => j.JobId == focused.JobId && j.TargetId == _targetId)) status = focused;
        if (status?.MaintenanceResult is { } result)
        {
            panel.Children.Add(Ui.Text("flash.maintenance.result", S.Format(UiStrings.FlashMaintenanceResult, result.Outcome, result.ExitCode)));
            panel.Children.Add(Ui.Text("flash.maintenance.job", status.JobId));
            panel.Children.Add(Ui.Text("flash.maintenance.sourceJob", result.SourceJobId));
            if (result.Reason is { } reason)
            {
                panel.Children.Add(Ui.Text("flash.maintenance.stopped", S.Text(UiStrings.FlashMaintenanceStopped)));
                panel.Children.Add(Ui.Text("flash.maintenance.reason", reason));
            }
            if (result.Verification is { } v)
            {
                panel.Children.Add(Ui.Text("flash.maintenance.counts", S.Format(UiStrings.FlashMaintenanceCounts, v.Verified, v.Skipped, v.Failed)));
                panel.Children.Add(Ui.Text("flash.maintenance.plan", v.SourcePlanId + "\n" + v.SourcePlanSha256));
                foreach (var t in v.Targets)
                {
                    var details = Ui.Stack(4,
                        Ui.Text("flash.maintenance.range", S.Format(UiStrings.FlashMaintenanceRange, t.RangeStart, t.RangeLength)),
                        Ui.Text("flash.maintenance.expected", S.Text(UiStrings.FlashMaintenanceExpected) + "\n" + t.ExpectedSha256),
                        Ui.Text("flash.maintenance.observed", S.Text(UiStrings.FlashMaintenanceObserved) + "\n" + (t.ObservedSha256 ?? "—")),
                        Ui.Text("flash.maintenance.strength", t.Strength ?? t.Reason ?? "—"));
                    panel.Children.Add(new Expander { Header = t.Target + ": " + t.Outcome, Content = details, HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Stretch });
                }
            }
        }
        return panel;
    }

    private async Task MaintainAsync(bool restoring)
    {
        if (_maintaining || _submitting || Target is not { } target || _maintenanceSource is not { } source || (restoring && _archive is null)) return;
        _maintaining = true;
        _maintenanceTarget = target.TargetId;
        _maintenanceStatus = null;
        _maintenanceFailure = null;
        try
        {
            var (status, failure) = await App.Loader.FlashMaintenanceAsync(source, target, restoring ? _archive : null, 600000);
            if (_targetId == target.TargetId) { _maintenanceStatus = status; _maintenanceFailure = failure; }
        }
        catch (Exception error) { if (_targetId == target.TargetId) _maintenanceFailure = error.Message; }
        finally { _maintaining = false; }
        await RefreshAsync();
    }
}
