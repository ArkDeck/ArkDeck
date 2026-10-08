using System.Globalization;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// Device: the candidates <c>device.observations</c> reports, named as the macOS Device
/// sidebar names them, or the daemon's structured refusal as it came
/// (<c>unavailable(rejected): hdc.notConfigured</c> while no Windows HDC is registered) with
/// <c>arkdeck device candidates</c> and a working Re-check; then the Targets adopted before
/// (<c>target.list</c>, answered by the Target store without an HDC). Choosing a Target shows
/// <c>target.show</c> and <c>target.availability</c>, and its Runtime display name can be
/// renamed or cleared (<c>target.display-name.set|clear</c>, the name the CLI shows too).
/// Adoption stays in the CLI.
/// </summary>
public sealed partial class DevicePage() : SurfacePage<DeviceState>(
    "device", "device.title", UiStrings.AppNavigationDevice,
    "hdc.devices.refresh", UiStrings.HdcDevicesRefresh, "app.devices.checking", UiStrings.OverviewStatusRefreshing), IHistoryContextPage
{
    protected override double PageMaxWidth => double.PositiveInfinity;

    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _detail = new() { Spacing = 8 };
    private TextBlock _nameStatus = Ui.Status("device.target.nameStatus");
    private IReadOnlyList<TargetSummary> _targets = [];
    private string? _selected;

    protected override Task<DeviceState> LoadAsync() => App.Loader.DeviceAsync();

    private HistoryWorkspaceContext? _history;

    /// <summary>Selects the historical record's Target and reads only its same-Job screenshot.</summary>
    public void OpenHistoryContext(HistoryWorkspaceContext context)
    {
        _history = context;
        _selected = context.TargetId;
        _screen.RequestHistory();
        _screenBitmap = null;
    }

    protected override void Render(DeviceState state, StackPanel body)
    {
        if (_history is { } history)
        {
            body.Children.Add(HistoryContextBanner.Create(history, async () =>
            {
                _history = null;
                _screen.ClearHistory();
                await RefreshAsync();
            }));
        }
        body.Children.Add(ScreenWorkspace());
        EndVerdictIfTheDeviceMoved(state.Candidates);
        MainWindow.Instance.ShowDevices(state.Candidates);
        if (CandidateDetail(state) is { } detail) body.Children.Add(detail);
        if (state.Candidates.Unavailable is { } why)
        {
            var notice = Ui.UnavailableNotice("app.devices.unavailable", UiStrings.AppDevicesUnavailable, why);
            notice.Children.Add(Ui.Button("device.action.recheck", S.Text(UiStrings.DeviceActionRecheck), async (_, _) => await RefreshAsync()));
            body.Children.Add(Ui.Card(notice, "app.devices.unavailable.section"));
        }
        else if (state.Candidates.Value!.Count == 0)
        {
            body.Children.Add(Ui.Text("app.devices.empty", S.Text(UiStrings.WindowsDeviceEmpty)));
        }
        else
        {
            var list = Ui.List("app.devices.list", S.Text(UiStrings.AppNavigationDevice));
            var aliases = App.Preferences.DeviceAliases;
            foreach (var candidate in state.Candidates.Value!)
            {
                var title = DeviceTrust.Title(candidate, aliases);
                var stateText = candidate.StateKey is { } key ? S.Text(key) : candidate.AuthorizationState;
                var facts = Ui.Stack(2,
                    Ui.Text($"device.row.{candidate.CandidateKey}.title", title, "ArkDeckSectionTitleStyle"),
                    Ui.Text($"device.row.{candidate.CandidateKey}.state", stateText));
                foreach (var (fact, labelKey, value) in new (string, string, string?)[]
                         {
                             ("connectKey", UiStrings.DeviceFactConnectKey, candidate.CandidateKey),
                             ("target", UiStrings.DeviceFactTarget, candidate.AdoptedTargetId),
                             ("bindingRevision", UiStrings.DeviceFactBindingRevision, candidate.BindingRevision?.ToString(CultureInfo.InvariantCulture)),
                             ("model", UiStrings.DeviceFactModel, candidate.DeviceName),
                             ("firmware", UiStrings.DeviceFactFirmware, candidate.SystemVersion),
                             ("transport", UiStrings.DeviceFactTransport, candidate.Transport),
                         })
                {
                    if (value is null) continue;
                    facts.Children.Add(Ui.Fact($"device.row.{candidate.CandidateKey}.{fact}", S.Text(labelKey), value));
                }
                list.Items.Add(Ui.Item("device.row." + candidate.CandidateKey, $"{title}, {stateText}", facts));
            }
            body.Children.Add(Ui.Card(list));
        }
        body.Children.Add(Ui.Card(Targets(state), "device.targets"));
        body.Children.Add(Ui.Text("device.detail.adoptViaCLI", S.Text(UiStrings.DeviceDetailAdoptViaCLI), "ArkDeckCaptionStyle"));
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_screen.HistoryPending && _history is { } context)
            {
                await ReadHistoryScreenAsync(context);
            }
            else if (_history is null) await RefreshScreenGateAsync(_selected);
        });
    }

    /// <summary>The adopted Targets and the selected one's detail.</summary>
    private UIElement Targets(DeviceState state)
    {
        var panel = Ui.Stack(8, Ui.Heading("device.targets.title", S.Text(UiStrings.WindowsDeviceTargetsTitle)));
        _detail = new StackPanel { Spacing = 8 };
        var said = _nameStatus.Text;
        _nameStatus = Ui.Status("device.target.nameStatus");
        Ui.SetText(_nameStatus, said);
        if (state.Targets.Unavailable is { } why)
        {
            _targets = [];
            panel.Children.Add(Ui.UnavailableNotice("device.targets.unavailable", UiStrings.WindowsDeviceTargetsUnavailable, why));
            return panel;
        }
        _targets = state.Targets.Value!;
        if (_selected is null && _targets.Count == 1) _selected = _targets[0].TargetId;
        if (_targets.Count == 0)
        {
            panel.Children.Add(Ui.Text("device.targets.empty", S.Text(UiStrings.WindowsDeviceTargetsEmpty)));
            return panel;
        }
        var list = Ui.Choice("device.targets.list", S.Text(UiStrings.WindowsDeviceTargetsTitle));
        foreach (var target in _targets)
        {
            var row = Ui.Stack(2,
                Ui.Text($"device.target.{target.TargetId}.title", target.Title, "ArkDeckSectionTitleStyle"),
                Ui.Fact($"device.target.{target.TargetId}.id", S.Text(UiStrings.DeviceFactTarget), target.TargetId),
                Ui.Fact($"device.target.{target.TargetId}.bindingRevision", S.Text(UiStrings.DeviceFactBindingRevision),
                    target.BindingRevision.ToString(CultureInfo.InvariantCulture)));
            var item = Ui.Item("device.target." + target.TargetId, target.DisplayName is null ? target.TargetId : $"{target.DisplayName}, {target.TargetId}", row);
            item.Tag = target.TargetId;
            list.Items.Add(item);
            if (target.TargetId == _selected) list.SelectedItem = item;
        }
        list.SelectionChanged += async (_, e) =>
        {
            if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string id }) await ShowTargetAsync(id);
        };
        panel.Children.Add(list);
        panel.Children.Add(_nameStatus);
        if (_selected is { } selected && _targets.Any(t => t.TargetId == selected))
        {
            DispatcherQueue.TryEnqueue(async () => await ShowTargetAsync(selected));
        }
        else
        {
            _selected = null;
            _detail.Children.Add(Ui.Text("device.target.select", S.Text(UiStrings.WindowsDeviceTargetSelect), "ArkDeckCaptionStyle"));
        }
        return Ui.MasterDetail(panel, _detail);
    }

    private async Task ShowTargetAsync(string targetId)
    {
        var changed = _selected != targetId;
        _selected = targetId;
        if (changed)
        {
            _history = null;
            _screen.ClearHistory();
            _screen.Select(null);
            _screenBitmap = null;
            RenderScreen();
        }
        _detail.Children.Clear();
        _detail.Children.Add(Ui.Progress("device.target.loading", S.Text(UiStrings.OverviewStatusRefreshing)));
        var state = await Task.Run(() => App.Loader.TargetAsync(targetId));
        if (_selected != targetId) return;
        RenderTarget(state);
        MainWindow.Instance.Report(state);
        if (_history is null) await RefreshScreenGateAsync(targetId);
    }

    private void RenderTarget(TargetDetailState state)
    {
        _detail.Children.Clear();
        if (state.Detail.Unavailable is { } why)
        {
            _detail.Children.Add(Ui.UnavailableNotice("device.target.detail.unavailable", UiStrings.WindowsDeviceTargetDetailUnavailable, why));
            return;
        }
        var target = state.Detail.Value!;
        var summary = _targets.FirstOrDefault(t => t.TargetId == target.TargetId);
        _detail.Children.Add(Ui.Heading("device.target.detail.title", target.DisplayName ?? target.TargetId, AutomationHeadingLevel.Level3));
        var actions = Ui.Row(Ui.Button("device.target.rename", S.Text(UiStrings.DeviceActionRename), async (_, _) => await RenameAsync(target)));
        if (target.DisplayName is not null)
        {
            actions.Children.Add(Ui.Button("device.target.clearName", S.Text(UiStrings.WindowsDeviceRenameClear), async (_, _) => await ClearNameAsync(target)));
        }
        _detail.Children.Add(actions);
        foreach (var (id, key, value) in new (string, string, string?)[]
                 {
                     ("device.target.detail.id", UiStrings.DeviceFactTarget, target.TargetId),
                     ("device.target.detail.connectKey", UiStrings.DeviceFactConnectKey, target.ConnectKey),
                     ("device.target.detail.bindingRevision", UiStrings.DeviceFactBindingRevision, target.BindingRevision.ToString(CultureInfo.InvariantCulture)),
                     ("device.target.detail.identity", UiStrings.WindowsDeviceTargetIdentity, target.StablePhysicalIdentitySha256),
                     ("device.target.detail.adoptedAt", UiStrings.WindowsDeviceTargetAdoptedAt, target.AdoptedAtUtc),
                     ("device.target.detail.toolVersion", UiStrings.WindowsDeviceTargetToolVersion, target.ToolVersion),
                     ("device.target.detail.model", UiStrings.DeviceFactModel, target.ObservedFacts?.Model),
                     ("device.target.detail.firmware", UiStrings.DeviceFactFirmware, target.ObservedFacts?.Firmware),
                     ("device.target.detail.transport", UiStrings.DeviceFactTransport, target.ObservedFacts?.Transport),
                     ("device.target.detail.confirmedAt", UiStrings.WindowsDeviceTargetConfirmedAt, target.ObservedFacts?.ConfirmedAtUtc),
                 })
        {
            if (value is not null) _detail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        if (state.Availability.Unavailable is { } availabilityWhy)
        {
            _detail.Children.Add(Ui.UnavailableNotice("device.target.availability.unavailable", UiStrings.WindowsDeviceTargetDetailUnavailable, availabilityWhy));
        }
        else
        {
            var availability = state.Availability.Value!;
            _detail.Children.Add(Ui.Fact("device.target.binding", S.Text(UiStrings.WindowsDeviceTargetBinding), availability.BindingState));
            AddState("device.target.presence", UiStrings.WindowsDeviceTargetPresence, availability.Presence);
            AddState("device.target.profile", UiStrings.WindowsDeviceTargetProfile, availability.Profile);
            AddState("device.target.tool", UiStrings.WindowsDeviceTargetTool, availability.Tool);
            _detail.Children.Add(Ui.Heading("device.target.operations.title", S.Text(UiStrings.WindowsDeviceTargetOperations), AutomationHeadingLevel.Level3));
            _detail.Children.Add(Ui.Text("device.target.operations.scope",
                S.Format(UiStrings.WindowsDeviceTargetOperationsScope, availability.OperationsScope, availability.OperationsReasonCode), "ArkDeckCaptionStyle"));
            var operations = Ui.List("device.target.operations", S.Text(UiStrings.WindowsDeviceTargetOperations));
            foreach (var operation in availability.Operations)
            {
                var text = operation.ReasonCodes.Count == 0
                    ? $"{operation.Reference} · {operation.Availability}"
                    : $"{operation.Reference} · {operation.Availability} ({string.Join(", ", operation.ReasonCodes)})";
                operations.Items.Add(Ui.Item("device.target.operation." + operation.Reference, text,
                    Ui.Text($"device.target.operation.{operation.Reference}.text", text, "ArkDeckMonoStyle")));
            }
            _detail.Children.Add(operations);
        }
    }

    private void AddState(string id, string labelKey, AvailabilityFact fact)
    {
        _detail.Children.Add(Ui.Fact(id, S.Text(labelKey), fact.Text));
        if (fact.Reason is { } reason) _detail.Children.Add(Ui.Text(id + ".reason", reason, "ArkDeckCaptionStyle"));
    }

    /// <summary>The macOS rename sheet as a Fluent dialog. The name is checked by the macOS
    /// rule before anything is sent; the Runtime's refusal (a name changed meanwhile, a name it
    /// does not accept) keeps the dialog open with the reason.</summary>
    private async Task RenameAsync(TargetDetail target)
    {
        var field = new TextBox { Header = S.Text(UiStrings.DeviceRenameField), Text = target.DisplayName ?? string.Empty, MaxLength = 256 };
        AutomationProperties.SetAutomationId(field, "device.rename.field");
        AutomationProperties.SetName(field, S.Text(UiStrings.DeviceRenameField));
        var problem = Ui.Status("device.rename.problem", AutomationLiveSetting.Assertive);
        var content = Ui.Stack(8, Ui.Text("device.rename.message", S.Text(UiStrings.DeviceRenameMessage)), field, problem);
        var dialog = Ui.Dialog(XamlRoot, "device.rename", S.Text(UiStrings.DeviceRenameTitle), content,
            S.Text(UiStrings.DeviceRenameCommit), S.Text(UiStrings.DeviceRenameCancel));
        DisplayNameChange? saved = null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                if (DisplayName.Normalize(field.Text) is not { } name)
                {
                    args.Cancel = true;
                    Ui.Say(problem, S.Text(UiStrings.DeviceRenameMessage));
                    return;
                }
                var state = await Task.Run(() => App.Loader.RenameTargetAsync(target.TargetId, name, target.DisplayNameGeneration));
                MainWindow.Instance.Report(state);
                if (state.Change.Unavailable is { } why)
                {
                    args.Cancel = !why.IsDaemonUnavailable;
                    Ui.Say(problem, $"{S.Text(UiStrings.WindowsDeviceRenameRefused)} · {why.ReasonText(S)}");
                    if (why.IsDaemonUnavailable) Ui.Say(_nameStatus, $"{S.Text(UiStrings.WindowsDeviceRenameRefused)} · {why.ReasonText(S)}");
                    return;
                }
                saved = state.Change.Value;
            }
            finally
            {
                deferral.Complete();
            }
        };
        await dialog.ShowAsync();
        if (saved is not null)
        {
            Ui.Say(_nameStatus, S.Format(UiStrings.WindowsDeviceRenameSaved, saved.Name ?? string.Empty));
            await RefreshAsync();
        }
    }

    private async Task ClearNameAsync(TargetDetail target)
    {
        var state = await Task.Run(() => App.Loader.ClearTargetNameAsync(target.TargetId, target.DisplayNameGeneration));
        MainWindow.Instance.Report(state);
        if (state.Change.Unavailable is { } why)
        {
            Ui.Say(_nameStatus, $"{S.Text(UiStrings.WindowsDeviceRenameRefused)} · {why.ReasonText(S)}");
            if (!why.IsDaemonUnavailable) await RefreshAsync();
            return;
        }
        Ui.Say(_nameStatus, S.Text(UiStrings.WindowsDeviceRenameCleared));
        await RefreshAsync();
    }
}
