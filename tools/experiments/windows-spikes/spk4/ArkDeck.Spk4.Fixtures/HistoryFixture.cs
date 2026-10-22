namespace ArkDeck.Spk4.Fixtures;

public sealed record HistoryRow(
    int Index,
    string JobId,
    string Operation,
    FixtureJobState State,
    string Target,
    DateTimeOffset StartedAt,
    int DurationMs)
{
    public string StateLabel => FixtureJobStates.Label(State);
    public string StateGlyph => FixtureJobStates.Glyph(State);
    public string StartedText => StartedAt.ToString("yyyy-MM-dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);
    public string DurationText => DurationMs < 1000
        ? $"{DurationMs} ms"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{DurationMs / 1000.0:0.0} s");
    public string AutomationName => $"{JobId}, {Operation}, {StateLabel}, {StartedText}";
}

/// <summary>Deterministic History list fixture (design §I.2: History 10k rows).</summary>
public static class HistoryFixture
{
    public const int DefaultRows = 10_000;

    static readonly string[] Operations =
    [
        "observe.device", "capture.screen", "debug.hap", "flash.image", "trace.capture",
        "diagnostics.session", "input.tap", "ui.dump", "artifact.export", "hdc.restart",
    ];

    static readonly FixtureJobState[] States =
    [
        FixtureJobState.Succeeded, FixtureJobState.Succeeded, FixtureJobState.Succeeded,
        FixtureJobState.Failed, FixtureJobState.Cancelled, FixtureJobState.WaitingForHuman,
        FixtureJobState.Running, FixtureJobState.Queued, FixtureJobState.Unknown,
    ];

    public static IReadOnlyList<HistoryRow> Generate(int count = DefaultRows, int seed = 4)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(count);
        var rng = new Random(seed);
        var start = new DateTimeOffset(2026, 9, 30, 9, 0, 0, TimeSpan.Zero);
        var rows = new HistoryRow[count];
        for (var i = 0; i < count; i++)
        {
            rows[i] = new HistoryRow(
                i,
                $"job-{i + 1:D6}",
                Operations[rng.Next(Operations.Length)],
                States[rng.Next(States.Length)],
                $"fixture-target-{rng.Next(1, 5)}",
                start.AddSeconds(-37L * i),
                rng.Next(40, 90_000));
        }
        return rows;
    }
}
