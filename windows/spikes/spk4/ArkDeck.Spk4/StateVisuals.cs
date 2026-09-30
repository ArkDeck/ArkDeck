using ArkDeck.Spk4.Fixtures;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace ArkDeck.Spk4;

/// <summary>x:Bind function helpers: fixture Job state -> token brush. The brush is looked up
/// from the generated theme dictionaries (Light/Dark/HighContrast) at bind time; state is also
/// always shown as glyph + text (AC-UX-005-01).</summary>
public static class StateVisuals
{
    public static Brush Brush(FixtureJobState state) =>
        (Brush)Application.Current.Resources[$"ArkDeck{FixtureJobStates.TokenRole(state)}Brush"];
}
