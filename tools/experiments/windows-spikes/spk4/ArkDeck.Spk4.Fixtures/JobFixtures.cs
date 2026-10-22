namespace ArkDeck.Spk4.Fixtures;

/// <summary>Fixture-only Job states. The real client renders the daemon's `job.status`
/// projection; this closed set only exercises presentation (design §H.5).</summary>
public enum FixtureJobState
{
    Queued,
    Running,
    WaitingForHuman,
    Succeeded,
    Failed,
    Cancelled,
    Unknown,
}

public static class FixtureJobStates
{
    /// <summary>Text shown next to the glyph; state is never conveyed by colour alone.</summary>
    public static string Label(FixtureJobState s) => s switch
    {
        FixtureJobState.Queued => "Queued",
        FixtureJobState.Running => "Running",
        FixtureJobState.WaitingForHuman => "Waiting for you",
        FixtureJobState.Succeeded => "Succeeded",
        FixtureJobState.Failed => "Failed",
        FixtureJobState.Cancelled => "Cancelled",
        _ => "Unknown",
    };

    /// <summary>Segoe Fluent Icons glyph per state.</summary>
    public static string Glyph(FixtureJobState s) => s switch
    {
        FixtureJobState.Queued => "",          // Recent
        FixtureJobState.Running => "",         // Play
        FixtureJobState.WaitingForHuman => "", // Warning
        FixtureJobState.Succeeded => "",       // CheckMark
        FixtureJobState.Failed => "",          // ErrorBadge
        FixtureJobState.Cancelled => "",       // Cancel
        _ => "",                               // Unknown
    };

    /// <summary>Token role (tokens.css `--ad-*`) used for the state colour.</summary>
    public static string TokenRole(FixtureJobState s) => s switch
    {
        FixtureJobState.Succeeded => "Ok",
        FixtureJobState.WaitingForHuman => "Warn",
        FixtureJobState.Failed => "Danger",
        FixtureJobState.Queued => "Planned",
        _ => "Ink2",
    };

    /// <summary>The scripted sequence the Job Inspector fixture walks through.</summary>
    public static readonly IReadOnlyList<FixtureJobState> InspectorSequence =
    [
        FixtureJobState.Queued,
        FixtureJobState.Running,
        FixtureJobState.WaitingForHuman,
        FixtureJobState.Running,
        FixtureJobState.Succeeded,
    ];

    /// <summary>Cancel is offered only while the fixture Job is live.</summary>
    public static bool CanCancel(FixtureJobState s) =>
        s is FixtureJobState.Queued or FixtureJobState.Running or FixtureJobState.WaitingForHuman;
}
