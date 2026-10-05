using System.Diagnostics;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>How a bounded trust wait ended (macOS <c>DeviceAuthorizationPresentation</c> as
/// <c>boundedAuthorizationWait</c> returns it).</summary>
public enum TrustWaitOutcome
{
    Ready,
    TimedOut,
    Unavailable,
    Cancelled,
}

/// <summary>A bounded trust wait's verdict and the observation it was drawn from.</summary>
public sealed record TrustWaitResult(TrustWaitOutcome Outcome, string? Reason, Loaded<IReadOnlyList<DeviceCandidate>> Latest);

/// <summary>
/// The Device sidebar's names and the trust wait (macOS <c>DeviceListViewModel</c>): an
/// App-local alias for a device not adopted yet (an adopted Target's name is the Runtime's,
/// <c>target.display-name.set</c>), and the bounded wait for the device's "Trust this computer"
/// confirmation, which only re-reads <c>device.observations</c>.
/// </summary>
public static class DeviceTrust
{
    public const int MaximumAliasLength = 64;

    /// <summary>macOS <c>authorizationWaitWindowSeconds</c> and its probe interval.</summary>
    public static readonly TimeSpan Window = TimeSpan.FromSeconds(180);

    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(5);

    /// <summary>macOS <c>normalizedDisplayName</c>: whitespace runs become one space; 1 to 64
    /// characters, else null.</summary>
    public static string? NormalizeAlias(string raw)
    {
        var name = string.Join(' ', raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return name.Length is > 0 and <= MaximumAliasLength ? name : null;
    }

    /// <summary>macOS <c>displayName(for:)</c> on Windows: the alias of a device not adopted yet,
    /// else the Runtime's name, the device's name, the Target, the connect key.</summary>
    public static string Title(DeviceCandidate candidate, IReadOnlyDictionary<string, string> aliases) =>
        candidate.AdoptedTargetId is null && aliases.TryGetValue(candidate.CandidateKey, out var alias)
            ? alias
            : candidate.DisplayName ?? candidate.DeviceName ?? candidate.AdoptedTargetId ?? candidate.CandidateKey;

    /// <summary>macOS <c>endsTrustWaitVerdict</c>: a later read in which the device's state differs
    /// from the one the verdict was drawn from ends it; a failed read ends nothing.</summary>
    public static bool EndsVerdict(Loaded<IReadOnlyList<DeviceCandidate>> current, string key, Loaded<IReadOnlyList<DeviceCandidate>> concluded)
    {
        if (current.Value is not { } now) return false;
        if (concluded.Value is not { } then) return true;
        return now.FirstOrDefault(c => c.CandidateKey == key)?.AuthorizationState != then.FirstOrDefault(c => c.CandidateKey == key)?.AuthorizationState;
    }
}

public sealed partial class SurfaceLoader
{
    /// <summary>The live device observation alone (the sidebar's rows).</summary>
    public async Task<Loaded<IReadOnlyList<DeviceCandidate>>> DeviceCandidatesAsync()
    {
        var run = new Run(channel);
        return await run.Load(c => c.RequestAsync("device.observations"), DeviceCandidate.ParseAll, CliCommands.DeviceCandidates).ConfigureAwait(false);
    }

    /// <summary>macOS <c>boundedAuthorizationWait</c>: re-reads the observation every
    /// <paramref name="interval"/> until the device is authorized (Connected), is gone, the read
    /// fails, or <paramref name="window"/> has passed. It sends nothing to the device.</summary>
    public async Task<TrustWaitResult> WaitForTrustAsync(string key, TimeSpan window, TimeSpan interval, CancellationToken cancellation)
    {
        var started = Stopwatch.GetTimestamp();
        var latest = await DeviceCandidatesAsync().ConfigureAwait(false);
        while (true)
        {
            if (cancellation.IsCancellationRequested) return new(TrustWaitOutcome.Cancelled, null, latest);
            if (latest.Unavailable is { } why) return new(TrustWaitOutcome.Unavailable, why.Detail, latest);
            if (latest.Value!.FirstOrDefault(c => c.CandidateKey == key) is not { } candidate)
            {
                return new(TrustWaitOutcome.Unavailable, "The selected device is no longer visible", latest);
            }
            if (candidate is { AuthorizationState: "Connected", Stale: false }) return new(TrustWaitOutcome.Ready, null, latest);
            var left = window - Stopwatch.GetElapsedTime(started);
            if (left <= TimeSpan.Zero) return new(TrustWaitOutcome.TimedOut, null, latest);
            try
            {
                await Task.Delay(left < interval ? left : interval, cancellation).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return new(TrustWaitOutcome.Cancelled, null, latest);
            }
            latest = await DeviceCandidatesAsync().ConfigureAwait(false);
        }
    }
}
