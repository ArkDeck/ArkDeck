namespace ArkDeck.Spk4.Fixtures;

public sealed record FrameSummary(
    int Frames, double P50, double P95, double P99, double Max, int Over33, int Over100)
{
    /// <summary>Design §H.4 (a): fail if p95 frame time exceeds 33 ms.</summary>
    public bool PassesH4a => Frames > 0 && P95 <= 33.0;
}

public static class FrameStats
{
    /// <summary>Nearest-rank percentile (p in 0..100) of an unsorted sample.</summary>
    public static double Percentile(IReadOnlyList<double> values, double p)
    {
        if (values.Count == 0) throw new ArgumentException("empty sample", nameof(values));
        ArgumentOutOfRangeException.ThrowIfLessThan(p, 0);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(p, 100);
        var sorted = values.Order().ToArray();
        var rank = (int)Math.Ceiling(p / 100.0 * sorted.Length);
        return sorted[Math.Clamp(rank, 1, sorted.Length) - 1];
    }

    public static FrameSummary Summarize(IReadOnlyList<double> frameMs) => new(
        frameMs.Count,
        Percentile(frameMs, 50),
        Percentile(frameMs, 95),
        Percentile(frameMs, 99),
        frameMs.Max(),
        frameMs.Count(f => f > 33.0),
        frameMs.Count(f => f > 100.0));
}
