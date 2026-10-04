namespace ArkDeck.App.Core.Presentation;

/// <summary>One adopted Target online now (macOS <c>OverviewCapabilityTarget</c>).</summary>
public sealed record OverviewTarget(string TargetId, long BindingRevision, DeviceCandidate Candidate)
{
    /// <summary>macOS <c>displayName(for:)</c>: "name · target", or the Target alone.</summary>
    public string Title => Candidate.DeviceName is { Length: > 0 } name ? $"{name} · {TargetId}" : TargetId;
}

/// <summary>
/// The device Overview describes (macOS <c>OverviewRecordView.deviceScope</c> and
/// <c>OverviewCapabilityApplicationFacade.presentation</c>): the adopted Targets online now — an
/// authorized, current device observation with an adopted Target and binding — and the one in
/// scope: the person's choice while it is online, else the only one, else none.
/// </summary>
public static class OverviewScope
{
    public static IReadOnlyList<OverviewTarget> Online(IReadOnlyList<DeviceCandidate>? candidates)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return (candidates ?? [])
            .Where(c => c is { AuthorizationState: "Connected", Stale: false, AdoptedTargetId: not null, BindingRevision: not null } && seen.Add(c.AdoptedTargetId!))
            .Select(c => new OverviewTarget(c.AdoptedTargetId!, c.BindingRevision!.Value, c))
            .ToArray();
    }

    public static OverviewTarget? Selected(IReadOnlyList<OverviewTarget> online, string? preferred) =>
        online.FirstOrDefault(t => t.TargetId == preferred) ?? (online.Count == 1 ? online[0] : null);

    /// <summary>macOS <c>boundDeviceFacts</c> after the Target and its binding: the observed system
    /// version and transport.</summary>
    public static IReadOnlyList<string> Facts(OverviewTarget target) =>
        new[] { target.Candidate.SystemVersion, target.Candidate.Transport }
            .Where(f => !string.IsNullOrEmpty(f)).Select(f => f!).ToArray();
}

/// <summary>The remote build server bound to the Target in scope (macOS
/// <c>OverviewRemoteServerPresentation</c>): only an explicit binding counts.</summary>
public enum RemoteServerBindingState
{
    Loading,
    Unbound,
    Bound,
    Stale,
    Unavailable,
}

public sealed record RemoteServerBinding(RemoteServerBindingState State, string? Name = null, string? Endpoint = null, string? Reason = null);
