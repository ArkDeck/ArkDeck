using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// Device: the candidates <c>device.observations</c> reports, named as the macOS Device
/// sidebar names them, or the daemon's structured refusal as it came
/// (<c>unavailable(rejected): hdc.notConfigured</c> on today's Windows daemon) with
/// <c>arkdeck device candidates</c> and a working Re-check. Adoption stays in the CLI.
/// </summary>
public sealed partial class DevicePage() : SurfacePage<DeviceState>(
    "device", "device.title", UiStrings.AppNavigationDevice,
    "hdc.devices.refresh", UiStrings.HdcDevicesRefresh, "app.devices.checking", UiStrings.OverviewStatusRefreshing)
{
    protected override Task<DeviceState> LoadAsync() => App.Loader.DeviceAsync();

    protected override void Render(DeviceState state, StackPanel body)
    {
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
            foreach (var candidate in state.Candidates.Value!)
            {
                var stateText = candidate.StateKey is { } key ? S.Text(key) : candidate.AuthorizationState;
                var facts = Ui.Stack(2,
                    Ui.Text($"device.row.{candidate.CandidateKey}.title", candidate.Title, "ArkDeckSectionTitleStyle"),
                    Ui.Text($"device.row.{candidate.CandidateKey}.state", stateText));
                foreach (var (fact, labelKey, value) in new (string, string, string?)[]
                         {
                             ("connectKey", UiStrings.DeviceFactConnectKey, candidate.CandidateKey),
                             ("target", UiStrings.DeviceFactTarget, candidate.AdoptedTargetId),
                             ("bindingRevision", UiStrings.DeviceFactBindingRevision, candidate.BindingRevision?.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                             ("model", UiStrings.DeviceFactModel, candidate.DeviceName),
                             ("firmware", UiStrings.DeviceFactFirmware, candidate.SystemVersion),
                             ("transport", UiStrings.DeviceFactTransport, candidate.Transport),
                         })
                {
                    if (value is null) continue;
                    facts.Children.Add(Ui.Row(
                        Ui.Text($"device.row.{candidate.CandidateKey}.{fact}.label", S.Text(labelKey), "ArkDeckCaptionStyle"),
                        Ui.Text($"device.row.{candidate.CandidateKey}.{fact}", value, "ArkDeckMonoStyle")));
                }
                list.Items.Add(Ui.Item("device.row." + candidate.CandidateKey, $"{candidate.Title}, {stateText}", facts));
            }
            body.Children.Add(Ui.Card(list));
        }
        body.Children.Add(Ui.Text("device.detail.adoptViaCLI", S.Text(UiStrings.DeviceDetailAdoptViaCLI), "ArkDeckCaptionStyle"));
    }
}
