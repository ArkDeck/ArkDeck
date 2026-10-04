using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// Overview's HDC environment (macOS <c>HDCClientDiagnosticsDecoding</c> over
/// <c>runtime.hdc.status</c> and the shared device observation). The literal values are the
/// macOS App's own fact texts, which it shows untranslated in every language; a status that is
/// not complete is unavailable with its reason, never partly filled.
/// </summary>
public sealed record HdcEnvironment(
    string Health,
    string Endpoint,
    string ClientVersion,
    string ServerVersion,
    string DaemonVersion,
    string Hash,
    string Generation,
    string Ownership,
    string? EndpointSource,
    string Trust,
    string? TrustReason,
    string? LoadFailure)
{
    public const string AbsolutePath = "not exposed by Runtime";
    public const string Source = "ArkDeck Runtime";
    public const string PlatformTrust = "descriptor-bound SHA-256 verified by Runtime";
    public const string ChannelProtection = "unverified; assumed unprotected";
    public const string Subserver = "unknown — Not reported by Runtime";
    public const string LifecycleAvailability = "unavailable";
    public const string RecoveryUnavailable = "Recovery approval is not available through this Runtime connection";
    public const string RecoveryRequirement = "Server recovery is host-wide: it requires an impact preview, an exact-generation user confirmation, and a dispatch-time recheck.";
    public const string OwnershipBasis = "unavailable";
    public const string Counter = "unknown";
    public const string DeviceEvents = "not reported by Runtime";

    private const string NotObserved = "not currently observed";
    private const string Unknown = "unknown";

    private static readonly HashSet<string> Healths = ["healthy", "unavailable", "unknown"];
    private static readonly HashSet<string> Ownerships = ["external", "arkDeckManaged", "unknown"];
    private static readonly HashSet<string> EndpointSources = ["explicit", "inheritedEnvironment", "default"];

    /// <summary>The device authorization: <c>ready</c>, <c>waiting</c> or <c>unavailable</c>.</summary>
    public bool TrustReady => Trust == "ready";

    /// <summary>macOS <c>authorizationText</c>.</summary>
    public string AuthorizationText => Trust switch
    {
        "ready" => "ready",
        "waiting" => "unauthorized — unlock and trust the device, then retry",
        _ => "unavailable — " + TrustReason,
    };

    /// <summary>The environment of a status read (or its failure) and a device observation.</summary>
    public static HdcEnvironment From(Loaded<JsonObject> status, Loaded<IReadOnlyList<DeviceCandidate>>? devices)
    {
        if (status.Unavailable is { } refused)
        {
            return Failed(refused.Failure?.Remote is { } wire
                ? $"Runtime refused HDC status ({wire.Code}): {refused.Detail}"
                : refused.Detail);
        }
        var o = status.Value!;
        string? Text(string key) => o.TryGetValue(key, out var v) && v is JsonString { Value.Length: > 0 } s ? s.Value : null;
        if (Text("schemaVersion") != "arkdeck.runtime-hdc-status/1") return Failed("Runtime returned an unreadable HDC status. Refresh to check again.");
        if (Text("availability") is not "available")
        {
            return Text("availability") is "unavailable" or "unknown"
                ? Failed($"Runtime reports HDC {Text("availability")}: {Text("reasonCode") ?? "hdc.statusUnavailable"}")
                : Failed("Runtime returned an unrecognized HDC availability. Refresh to check again.");
        }
        var digest = Text("executableSHA256");
        var endpoint = Text("endpoint");
        var generation = Text("generation");
        var complete = digest is { Length: 64 } && digest.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')
            && endpoint is not null && endpoint.StartsWith("127.0.0.1:", StringComparison.Ordinal)
            && ushort.TryParse(endpoint["127.0.0.1:".Length..], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var port) && port > 0
            && generation is not null && ulong.TryParse(generation, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var number)
            && number > 0 && number.ToString(System.Globalization.CultureInfo.InvariantCulture) == generation
            && Text("ownership") is { } ownership && Ownerships.Contains(ownership)
            && Text("serverHealth") is { } health && Healths.Contains(health)
            && Text("endpointSource") is { } source && EndpointSources.Contains(source);
        if (!complete) return Failed("Runtime returned incomplete HDC identity or health facts. Refresh to check again.");
        var (trust, reason) = Authorization(devices);
        return new(Text("serverHealth")!, endpoint!, Text("clientVersion") ?? NotObserved, Text("serverVersion") ?? NotObserved, Text("daemonVersion") ?? NotObserved,
            digest!, generation!, Text("ownership")!, Text("endpointSource"), trust, reason, null);
    }

    private static HdcEnvironment Failed(string reason) =>
        new(Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, null, "unavailable", reason, reason);

    /// <summary>macOS <c>authorization(_:)</c> over the current device observations.</summary>
    private static (string Trust, string? Reason) Authorization(Loaded<IReadOnlyList<DeviceCandidate>>? devices)
    {
        if (devices?.Value is not { } candidates) return ("unavailable", "Runtime device authorization could not be read");
        var current = candidates.Where(c => !c.Stale).ToArray();
        if (current.Any(c => c.AuthorizationState == "Connected")) return ("ready", null);
        if (current.Any(c => c.AuthorizationState == "Unauthorized")) return ("waiting", null);
        if (current.Any(c => c.AuthorizationState == "Offline")) return ("unavailable", "HDC reported the target offline");
        if (candidates.Count == 0) return ("unavailable", "No HDC device candidate is visible");
        return ("unavailable", "Runtime has no current recognized device authorization state");
    }
}

/// <summary>One row of the device capability matrix (macOS
/// <c>OverviewCapabilityItemPresentation</c>): <c>available</c>, <c>limited</c>,
/// <c>unavailable</c> or <c>unknown</c>, and the probe evidence as the macOS App words it.</summary>
public sealed record CapabilityItem(string Id, string Name, string State, string Evidence);

/// <summary>The device capability matrix of the Target in scope (macOS
/// <c>OverviewCapabilityProductionProvider</c>): Trace tools from <c>trace.probe</c>, the
/// canonical Flash row from <c>operation.list</c>, and the hidumper row from a read-only
/// <c>debug.template@1</c> window inventory when one was run.</summary>
public sealed record CapabilityMatrix(string? TargetId, long? BindingRevision, IReadOnlyList<CapabilityItem> Items, string? Failure)
{
    public const string FlashReference = "flash.full-restore@1";

    /// <summary>The matrix for the scope: none online, several and none chosen, or one Target
    /// with its probe read (or why not).</summary>
    public static CapabilityMatrix For(IReadOnlyList<OverviewTarget> online, OverviewTarget? scoped, Loaded<JsonArray>? operations, Loaded<JsonObject>? probe)
    {
        var flash = Flash(operations);
        if (operations?.Unavailable is { } unread) return new(null, null, [], unread.Detail);
        if (scoped is null)
        {
            return new(null, null, [flash], online.Count == 0
                ? "No adopted target is available for device capability probing"
                : $"{online.Count} adopted targets are available; choose which one to describe");
        }
        var items = new List<CapabilityItem> { Hidumper(null) };
        items.AddRange(Trace(probe, scoped));
        items.Add(flash);
        return new(scoped.TargetId, scoped.BindingRevision, items, null);
    }

    /// <summary>The same matrix with the hidumper row of a window-inventory Job.</summary>
    public CapabilityMatrix WithWindowInventory(string jobId, string state, bool outcomeUnknown) =>
        this with { Items = Items.Select(i => i.Id == "hidumper" ? Hidumper((jobId, state, outcomeUnknown)) : i).ToArray() };

    /// <summary>The same matrix with the hidumper row of a run that could not complete.</summary>
    public CapabilityMatrix WithWindowInventoryFailure(string reason) =>
        this with { Items = Items.Select(i => i.Id == "hidumper" ? new CapabilityItem("hidumper", "hidumper", "unknown", reason) : i).ToArray() };

    private static CapabilityItem Hidumper((string JobId, string State, bool OutcomeUnknown)? run) => run switch
    {
        null => new("hidumper", "hidumper", "unknown", "not probed: run the read-only window inventory to check"),
        { State: "succeeded", OutcomeUnknown: false } r => new("hidumper", "hidumper", "available", "debug.template@1 Job succeeded · " + r.JobId),
        { } r => new("hidumper", "hidumper", "unknown", $"debug.template@1 Job {r.State} · {r.JobId}"),
    };

    private static IEnumerable<CapabilityItem> Trace(Loaded<JsonObject>? probe, OverviewTarget scoped)
    {
        string[] tools = ["hitrace", "bytrace"];
        if (probe is null || probe.Unavailable is not null)
        {
            var reason = probe?.Unavailable?.Detail ?? "Runtime returned mismatched Trace facts";
            return tools.Select(t => new CapabilityItem(t, t, "unknown", reason));
        }
        var result = probe.Value!;
        string? Text(JsonObject o, string key) => o.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
        if (Text(result, "targetId") != scoped.TargetId
            || !result.TryGetValue("bindingRevision", out var b) || b is not JsonNumber n || !n.TryGetInt64(out var revision) || revision != scoped.BindingRevision
            || !result.TryGetValue("tools", out var r) || r is not JsonArray rows
            || !result.TryGetValue("supportedTags", out var t) || t is not JsonArray tags)
        {
            return tools.Select(tool => new CapabilityItem(tool, tool, "unknown", "Runtime returned mismatched Trace facts"));
        }
        return tools.Select(tool =>
        {
            var row = rows.Items.OfType<JsonObject>().FirstOrDefault(x => Text(x, "tool") == tool);
            var disposition = row is null ? null : Text(row, "disposition");
            if (row is null || disposition is not ("captureEligible" or "probeOnly" or "unrecognized" or "probeFailed"))
            {
                return new CapabilityItem(tool, tool, "unknown", "Required probe result was omitted");
            }
            var digest = Text(row, "rawHelpSha256");
            var family = Text(row, "family");
            string? Help() => digest is null ? null : $"help sha256 {digest[..Math.Min(12, digest.Length)]}…";
            return disposition switch
            {
                "captureEligible" => new CapabilityItem(tool, tool, "available",
                    string.Join(" · ", new[] { family, tool == "hitrace" ? $"tags × {tags.Items.Count}" : null, Help() }.Where(p => p is not null))),
                "probeOnly" => new CapabilityItem(tool, tool, "limited", string.Join(" · ", new[] { family, "probe-only", Help() }.Where(p => p is not null))),
                "unrecognized" => new CapabilityItem(tool, tool, "unknown",
                    digest is null ? "Help family could not be recognized" : $"Unregistered help family · sha256 {digest[..Math.Min(12, digest.Length)]}…"),
                _ => new CapabilityItem(tool, tool, "unknown", Text(row, "detail") ?? "Read-only probe failed"),
            };
        }).ToArray();
    }

    private static CapabilityItem Flash(Loaded<JsonArray>? operations)
    {
        var row = operations?.Value?.Items.OfType<JsonObject>().FirstOrDefault(o => o.TryGetValue("reference", out var r) && r is JsonString { Value: FlashReference });
        if (row is null || !row.TryGetValue("availability", out var a) || a is not JsonString availability
            || !row.TryGetValue("reasons", out var r) || r is not JsonArray reasons)
        {
            return new("rockusb-flash", "RockUSB Flash", "unknown", "Runtime omitted canonical ArkForge Flash availability");
        }
        var texts = reasons.Items.OfType<JsonString>().Select(s => s.Value).ToArray();
        return availability.Value == "available"
            ? new("rockusb-flash", "RockUSB Flash", "available", "canonical ArkForge Flash provider and lowering are available")
            : new("rockusb-flash", "RockUSB Flash", "unavailable", texts.Length == 0 ? "Runtime reported unavailable" : string.Join(" · ", texts));
    }
}
