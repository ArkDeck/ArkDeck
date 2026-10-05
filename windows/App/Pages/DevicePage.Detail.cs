using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// A device row's detail (macOS <c>DeviceDetailView</c>), opened from the sidebar: the state,
/// for an unauthorized device the three trust steps and the bounded wait for its confirmation,
/// Re-check, and the facts the observation carries; a device not adopted yet can be given an
/// App-local name. Nothing here adopts, restarts or sends anything to the device: the wait only
/// re-reads the observation.
/// </summary>
public sealed partial class DevicePage
{
    private enum WaitKind
    {
        Idle,
        Polling,
        TimedOut,
        Unavailable,
    }

    private string? _candidate;
    private (WaitKind Kind, string Key, DateTimeOffset Deadline, string? Reason) _wait = (WaitKind.Idle, "", default, null);
    private Loaded<IReadOnlyList<DeviceCandidate>>? _verdictObservation;
    private CancellationTokenSource? _waiting;

    /// <summary>The sidebar row's destination: this device's detail.</summary>
    public void ShowCandidate(string? candidateKey)
    {
        if (candidateKey != _candidate) CancelWait();
        _candidate = candidateKey;
    }

    private void CancelWait()
    {
        _waiting?.Cancel();
        _waiting = null;
        _wait = (WaitKind.Idle, "", default, null);
        _verdictObservation = null;
    }

    /// <summary>A finished wait's verdict ends once a later read shows the device in another state.</summary>
    private void EndVerdictIfTheDeviceMoved(Loaded<IReadOnlyList<DeviceCandidate>> current)
    {
        if (_wait.Kind is not (WaitKind.TimedOut or WaitKind.Unavailable) || _verdictObservation is not { } concluded) return;
        if (DeviceTrust.EndsVerdict(current, _wait.Key, concluded)) CancelWait();
    }

    private Border? CandidateDetail(DeviceState state)
    {
        if (_candidate is not { } key || state.Candidates.Value is not { } candidates) return null;
        var panel = Ui.Stack(8);
        if (candidates.FirstOrDefault(c => c.CandidateKey == key) is not { } candidate)
        {
            // A successful observation no longer lists the chosen device.
            panel.Children.Add(Ui.Heading("app.devices.gone", S.Text(UiStrings.AppDevicesGone)));
            panel.Children.Add(Ui.Text("app.devices.goneDetail", S.Text(UiStrings.AppDevicesGoneDetail), "ArkDeckCaptionStyle"));
            return Ui.Card(panel, "device.detail");
        }
        var aliases = App.Preferences.DeviceAliases;
        panel.Children.Add(Ui.Heading("device.detail.title", S.Format(UiStrings.DeviceDetailTitle, DeviceTrust.Title(candidate, aliases))));
        panel.Children.Add(Ui.Heading("device.detail.statusTitle", S.Text(UiStrings.DeviceDetailStatusTitle), AutomationHeadingLevel.Level3));
        var (stateId, stateText) = candidate.Stale
            ? ("device.trust.needsRecheck", S.Text(UiStrings.DeviceStateNeedsRecheck))
            : candidate.AuthorizationState switch
            {
                "Unauthorized" => ("device.trust.waiting", S.Text(UiStrings.DeviceTrustWaiting)),
                "Offline" => ("device.trust.offline", S.Text(UiStrings.DeviceTrustOffline)),
                "Connected" => ("device.trust.ready", S.Text(candidate.AdoptedTargetId is null ? UiStrings.DeviceTrustAuthorizedUnadopted : UiStrings.DeviceTrustReady)),
                _ => ("device.trust.unknownState", S.Format(UiStrings.DeviceTrustUnknownState, candidate.AuthorizationState)),
            };
        panel.Children.Add(Ui.Text(stateId, stateText, "ArkDeckSectionTitleStyle"));
        var unauthorized = candidate.AuthorizationState == "Unauthorized";
        var waiting = _wait.Kind != WaitKind.Idle && _wait.Key == key ? _wait.Kind : WaitKind.Idle;
        if (unauthorized)
        {
            panel.Children.Add(Ui.Text("device.trust.stepsTitle", S.Text(UiStrings.DeviceTrustStepsTitle), "ArkDeckCaptionStyle"));
            var steps = Ui.List("device.trust.steps", S.Text(UiStrings.DeviceTrustStepsTitle));
            foreach (var (number, stepKey) in new[] { (1, UiStrings.DeviceTrustStep1), (2, UiStrings.DeviceTrustStep2), (3, UiStrings.DeviceTrustStep3) })
            {
                var text = $"{number}. {S.Text(stepKey)}";
                steps.Items.Add(Ui.Item("device.trust.step" + number, text, Ui.Text($"device.trust.step{number}.text", text)));
            }
            panel.Children.Add(steps);
            switch (waiting)
            {
                case WaitKind.Polling:
                    panel.Children.Add(Ui.Text("device.wait.polling", $"{S.Text(UiStrings.DeviceWaitPolling)} {S.Format(UiStrings.WindowsDeviceWaitUntil, _wait.Deadline.ToLocalTime().ToString("T", System.Globalization.CultureInfo.CurrentCulture))}"));
                    break;
                case WaitKind.TimedOut:
                    panel.Children.Add(Ui.Text("device.wait.timedOut", S.Text(UiStrings.DeviceWaitTimedOut)));
                    break;
                case WaitKind.Unavailable:
                    panel.Children.Add(Ui.Text("device.wait.unavailable", S.Format(UiStrings.DeviceWaitUnavailable, _wait.Reason ?? "")));
                    break;
            }
        }
        var status = Ui.Status("device.detail.status");
        var actions = Ui.Row();
        if (unauthorized)
        {
            actions.Children.Add(Ui.Button("device.action.beginWait",
                S.Text(waiting is WaitKind.TimedOut or WaitKind.Unavailable ? UiStrings.DeviceActionRetryWait : UiStrings.DeviceActionBeginWait), (_, _) =>
                {
                    // XPA-AC-8: enabled while polling; a second wait is refused in words.
                    if (waiting == WaitKind.Polling)
                    {
                        Ui.Say(status, S.Text(UiStrings.DeviceWaitPolling));
                        return;
                    }
                    BeginWait(key);
                }, accent: true));
        }
        actions.Children.Add(Ui.Button("device.action.recheck", S.Text(UiStrings.DeviceActionRecheck), async (_, _) => await RefreshAsync()));
        if (candidate.AdoptedTargetId is null)
        {
            actions.Children.Add(Ui.Button("device.action.rename", S.Text(UiStrings.DeviceActionRename), async (_, _) => await RenameAliasAsync(candidate)));
            if (aliases.ContainsKey(key))
            {
                actions.Children.Add(Ui.Button("device.action.clearAlias", S.Text(UiStrings.WindowsDeviceAliasClear), async (_, _) =>
                {
                    App.Preferences.SetDeviceAlias(key, null);
                    await RefreshAsync();
                }));
            }
        }
        actions.Children.Add(status);
        panel.Children.Add(actions);
        panel.Children.Add(Ui.Text("device.detail.recheckNote", S.Text(UiStrings.DeviceDetailRecheckNote), "ArkDeckCaptionStyle"));
        if (candidate.AdoptedTargetId is null && candidate.AuthorizationState == "Connected")
        {
            panel.Children.Add(Ui.Text("device.detail.adoptViaCLI.candidate", S.Text(UiStrings.DeviceDetailAdoptViaCLI), "ArkDeckCaptionStyle"));
        }

        panel.Children.Add(Ui.Heading("device.detail.factsTitle", S.Text(UiStrings.DeviceDetailFactsTitle), AutomationHeadingLevel.Level3));
        foreach (var (id, labelKey, value) in new (string, string, string?)[]
                 {
                     ("device.fact.connectKey", UiStrings.DeviceFactConnectKey, candidate.CandidateKey),
                     ("device.fact.state", UiStrings.DeviceFactState, candidate.AuthorizationState),
                     ("device.fact.target", UiStrings.DeviceFactTarget, candidate.AdoptedTargetId),
                     ("device.fact.bindingRevision", UiStrings.DeviceFactBindingRevision, candidate.BindingRevision?.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                     ("device.fact.model", UiStrings.DeviceFactModel, candidate.DeviceName),
                     ("device.fact.firmware", UiStrings.DeviceFactFirmware, candidate.SystemVersion),
                     ("device.fact.transport", UiStrings.DeviceFactTransport, candidate.Transport),
                 })
        {
            if (value is not null) panel.Children.Add(Ui.Fact(id, S.Text(labelKey), value));
        }
        if (candidate.DeviceName is not null || candidate.SystemVersion is not null)
        {
            panel.Children.Add(Ui.Text("device.fact.liveProvenance", S.Text(UiStrings.DeviceFactLiveProvenance), "ArkDeckCaptionStyle"));
        }
        return Ui.Card(panel, "device.detail");
    }

    /// <summary>macOS <c>beginAuthorizationWait</c>: the bounded wait, its deadline shown; the
    /// verdict comes from the wait, never from this page's clock.</summary>
    private void BeginWait(string key)
    {
        CancelWait();
        var (window, interval) = App.Options.FastTrustWait
            ? (TimeSpan.FromSeconds(2), TimeSpan.FromMilliseconds(250))
            : (DeviceTrust.Window, DeviceTrust.Interval);
        _wait = (WaitKind.Polling, key, DateTimeOffset.Now + window, null);
        var cancellation = _waiting = new CancellationTokenSource();
        Rerender();
        _ = Task.Run(async () =>
        {
            var result = await App.Loader.WaitForTrustAsync(key, window, interval, cancellation.Token);
            DispatcherQueue.TryEnqueue(async () =>
            {
                if (cancellation.IsCancellationRequested || _wait.Kind != WaitKind.Polling || _wait.Key != key) return;
                _waiting = null;
                _wait = result.Outcome switch
                {
                    TrustWaitOutcome.TimedOut => (WaitKind.TimedOut, key, default, null),
                    TrustWaitOutcome.Unavailable => (WaitKind.Unavailable, key, default, result.Reason),
                    _ => (WaitKind.Idle, "", default, null),
                };
                _verdictObservation = _wait.Kind == WaitKind.Idle ? null : result.Latest;
                await RefreshAsync();
            });
        });
    }

    private async Task RenameAliasAsync(DeviceCandidate candidate)
    {
        var aliases = App.Preferences.DeviceAliases;
        var field = new TextBox
        {
            Header = S.Text(UiStrings.DeviceRenameField),
            Text = aliases.TryGetValue(candidate.CandidateKey, out var current) ? current : DeviceTrust.Title(candidate, aliases),
            MaxLength = 256,
        };
        AutomationProperties.SetAutomationId(field, "device.rename.field");
        AutomationProperties.SetName(field, S.Text(UiStrings.DeviceRenameField));
        var problem = Ui.Status("device.rename.problem", AutomationLiveSetting.Assertive);
        var dialog = Ui.Dialog(XamlRoot, "device.rename", S.Text(UiStrings.DeviceRenameTitle),
            Ui.Stack(8, Ui.Text("device.rename.message", S.Text(UiStrings.DeviceRenameMessage)), field, problem),
            S.Text(UiStrings.DeviceRenameCommit), S.Text(UiStrings.DeviceRenameCancel));
        string? saved = null;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (DeviceTrust.NormalizeAlias(field.Text) is not { } name)
            {
                args.Cancel = true;
                Ui.Say(problem, S.Text(UiStrings.DeviceRenameMessage));
                return;
            }
            saved = name;
        };
        await dialog.ShowAsync();
        if (saved is null) return;
        App.Preferences.SetDeviceAlias(candidate.CandidateKey, saved);
        await RefreshAsync();
    }
}
