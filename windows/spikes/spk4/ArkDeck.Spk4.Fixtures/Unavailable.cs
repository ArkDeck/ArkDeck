namespace ArkDeck.Spk4.Fixtures;

/// <summary>An unimplemented capability shown as `unavailable(reasonCode)` plus its CLI path
/// (XPA-AC-8), never as a disabled placeholder control. CLI paths are the target commands in
/// openspec/contracts/cli-feature-coverage.json for the named feature.</summary>
public sealed record UnavailableCapability(string Feature, string Title, string ReasonCode, string CliPath)
{
    public string Heading => $"{Title}: unavailable({ReasonCode})";
    public string Body => $"This Windows client does not implement {Feature} yet. The CLI does: {CliPath}";
}

public static class UnavailableCatalog
{
    public static readonly IReadOnlyList<UnavailableCapability> DebugTabs =
    [
        new("app.debug.artifacts", "Artifacts", "notImplemented", "arkdeck artifact import native-library ..."),
        new("app.debug.logs", "Logs", "notImplemented", "arkdeck debug logs --inputs-file <path>"),
        new("app.debug.apps", "Apps", "notImplemented", "arkdeck debug hap --inputs-file <path>"),
        new("app.debug.network", "Network", "notImplemented", "arkdeck port-forward create --inputs-file <path>"),
        new("app.debug.commands", "Commands", "notImplemented", "arkdeck debug template list"),
    ];

    public static readonly UnavailableCapability TraceViewer =
        new("app.traceViewer.timeline", "Trace Viewer", "notImplemented", "arkdeck trace inspect ...");
}
