using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.Spk4.Pages;

/// <summary>Fixture Job whose state changes are announced through a UIA live region.</summary>
public sealed partial class JobInspectorPage : Page
{
    private int _step;

    public JobInspectorPage()
    {
        InitializeComponent();
        Apply(FixtureJobStates.InspectorSequence[0], announce: false);
    }

    private void Advance_Click(object sender, RoutedEventArgs e)
    {
        _step = (_step + 1) % FixtureJobStates.InspectorSequence.Count;
        Apply(FixtureJobStates.InspectorSequence[_step], announce: true);
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Apply(FixtureJobState.Cancelled, announce: true);

    private void Apply(FixtureJobState state, bool announce)
    {
        var label = FixtureJobStates.Label(state);
        StateGlyph.Glyph = FixtureJobStates.Glyph(state);
        StateGlyph.Foreground = StateVisuals.Brush(state);
        StateText.Text = label;
        AutomationProperties.SetName(StateText, $"Job state: {label}");
        NextStep.Text = state switch
        {
            FixtureJobState.WaitingForHuman => "Next: complete the requested action on the device, then resume.",
            FixtureJobState.Succeeded => "Next: open the evidence or export the result.",
            FixtureJobState.Cancelled => "Next: review the evidence recorded before cancellation.",
            _ => "Next: wait; the Runtime reports progress.",
        };
        var cancellable = FixtureJobStates.CanCancel(state);
        CancelButton.Visibility = cancellable ? Visibility.Visible : Visibility.Collapsed;
        CancelReason.Visibility = cancellable ? Visibility.Collapsed : Visibility.Visible;
        HumanBar.IsOpen = state == FixtureJobState.WaitingForHuman;

        if (announce)
        {
            var peer = FrameworkElementAutomationPeer.FromElement(StateText)
                ?? FrameworkElementAutomationPeer.CreatePeerForElement(StateText);
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
    }
}
