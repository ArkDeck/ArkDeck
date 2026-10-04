using System.Security.Cryptography;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// The Trace workspace's Runtime facts and its one action, as the macOS
/// <c>TraceApplicationFacade</c> has them: a bounded Trace capture is the typed
/// <c>capture.diagnostics@1</c> with one of the product's presets (<c>DiagnosticCapturePreset.trace</c>)
/// on one adopted Target whose Runtime probe (<c>trace.probe</c>) confirmed the adapter, the nine
/// debug parameters and the preset's tags. There is no parameter write and no free command.
/// </summary>
public static class TraceOperations
{
    public const string Reference = "capture.diagnostics@1";
    public const string Client = "ArkDeckApp.TraceWorkspace";

    /// <summary>The fixed capture buffer (macOS <c>defaultBufferKB</c>).</summary>
    public const int DefaultBufferKB = 8_192;

    public static readonly (long Minimum, long Maximum) DefaultDurationRange = (1, 600);
    public static readonly (long Minimum, long Maximum) DefaultBufferRange = (1_024, 65_536);

    public const string DefaultPreset = "arkuiDeep";

    /// <summary>The capture presets in catalog order, without <c>custom</c>
    /// (<c>TracePresetCatalog.definitions</c>, TraceCatalogContracts.swift).</summary>
    public static readonly IReadOnlyList<TracePreset> Presets =
    [
        new("attachmentPanorama", ["sched", "freq", "ace", "app", "binder", "disk", "ohos", "graphic", "sync", "workq", "ability"]),
        new("arkuiDeep", ["ace", "app", "ability", "graphic", "ohos", "sched", "freq", "sync"]),
        new("renderAnimation", ["graphic", "ace", "app", "sched", "freq", "sync"]),
        new("schedulingIpc", ["sched", "freq", "workq", "binder", "sync"]),
        new("io", ["disk", "sched", "workq", "binder"]),
    ];

    /// <summary>The nine debug parameters every probe reports (<c>RuntimeTraceParameterName</c>).</summary>
    public static readonly IReadOnlyList<string> ParameterNames =
    [
        "persist.ace.trace.syntax.enabled",
        "persist.ace.trace.layout.enabled",
        "persist.ace.trace.build.enabled",
        "persist.ace.trace.measure.debug.enabled",
        "persist.ace.trace.sync.debug.enabled",
        "persist.ace.debug.enabled",
        "persist.ace.performance.monitor.enabled",
        "persist.sys.graphic.openDebugTrace",
        "persist.rosen.animationtrace.enabled",
    ];

    public static TracePreset Preset(string id) => Presets.FirstOrDefault(p => p.Id == id) ?? Presets.First(p => p.Id == DefaultPreset);

    /// <summary>macOS <c>DiagnosticCapturePreset.trace</c>'s checks: 1...600 seconds, a
    /// 1024...65536 KiB buffer, 1...24 unique categories of ASCII letters, digits and underscores
    /// (at most 64 bytes each). Null when the request is inside them.</summary>
    public static string? PresetFailure(int durationSeconds, IReadOnlyList<string> categories, int bufferKB)
    {
        if (durationSeconds is < 1 or > 600) return "durationSeconds must be in 1...600";
        if (bufferKB is < 1_024 or > 65_536) return "traceBufferKB must be in 1024...65536";
        if (categories.Count is 0 or > 24 || categories.Distinct(StringComparer.Ordinal).Count() != categories.Count || !categories.All(IsCategory))
        {
            return "traceCategories must contain 1...24 unique ASCII letter, digit, or underscore values of at most 64 bytes";
        }
        return null;
    }

    private static bool IsCategory(string value) =>
        value.Length is > 0 and <= 64 && value.All(c => c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z') or (>= '0' and <= '9') or '_');
}

/// <summary>One capture preset: its identifier (the catalogue's <c>trace.preset.&lt;id&gt;</c>)
/// and the logical tags it requests.</summary>
public sealed record TracePreset(string Id, IReadOnlyList<string> Tags);

/// <summary>The duration field's entry unit; requests stay canonical seconds.</summary>
public enum TraceDurationUnit
{
    Seconds,
    Minutes,
}

/// <summary>Why a duration entry is not a request (macOS <c>TraceNumericInputFailure</c>).</summary>
public enum TraceDurationFailure
{
    Missing,
    NotDecimal,
    OutsideRange,
}

/// <summary>A validated duration entry: the canonical seconds, or the failure and the range
/// in the entry unit.</summary>
public sealed record TraceDurationValidation(int? Seconds, TraceDurationFailure? Failure, (long Minimum, long Maximum) InputRange)
{
    public bool IsValid => Seconds is not null;
}

/// <summary>macOS <c>TraceDurationInputUnit</c> and <c>TraceNumericInputValidator</c>.</summary>
public static class TraceDuration
{
    public static IReadOnlyList<int> QuickValues(TraceDurationUnit unit) => unit == TraceDurationUnit.Seconds ? [5, 10, 15, 30] : [1, 2, 3];

    /// <summary>The entry range in the unit, or null when the unit has none (minutes round the
    /// lower bound up and the upper bound down).</summary>
    public static (long Minimum, long Maximum)? InputRange(TraceDurationUnit unit, (long Minimum, long Maximum) seconds)
    {
        if (unit == TraceDurationUnit.Seconds) return seconds;
        if (seconds.Minimum <= 0) return null;
        var lower = seconds.Minimum / 60 + (seconds.Minimum % 60 == 0 ? 0 : 1);
        var upper = seconds.Maximum / 60;
        return lower <= upper ? (lower, upper) : null;
    }

    public static int? DurationSeconds(TraceDurationUnit unit, long value, (long Minimum, long Maximum) seconds)
    {
        if (InputRange(unit, seconds) is not { } range || value < range.Minimum || value > range.Maximum) return null;
        var total = unit == TraceDurationUnit.Seconds ? value : value * 60;
        return total >= seconds.Minimum && total <= seconds.Maximum && total <= int.MaxValue ? (int)total : null;
    }

    /// <summary>The entry that keeps a duration when the unit changes; minutes round up, so a
    /// unit change never shortens a capture.</summary>
    public static long? InputValue(TraceDurationUnit unit, long durationSeconds, (long Minimum, long Maximum) seconds)
    {
        if (InputRange(unit, seconds) is not { } range) return null;
        var bounded = Math.Min(seconds.Maximum, Math.Max(seconds.Minimum, durationSeconds));
        var value = unit == TraceDurationUnit.Seconds ? bounded : bounded / 60 + (bounded % 60 == 0 ? 0 : 1);
        return value >= range.Minimum && value <= range.Maximum ? value : null;
    }

    public static TraceDurationValidation Validate(string text, TraceDurationUnit unit, (long Minimum, long Maximum) seconds)
    {
        var range = InputRange(unit, seconds) ?? seconds;
        if (text.Length == 0) return new(null, TraceDurationFailure.Missing, range);
        if (!text.All(char.IsAsciiDigit) || !long.TryParse(text, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var value))
        {
            return new(null, TraceDurationFailure.NotDecimal, range);
        }
        if (value < range.Minimum || value > range.Maximum) return new(null, TraceDurationFailure.OutsideRange, range);
        return DurationSeconds(unit, value, seconds) is { } total ? new(total, null, range) : new(null, TraceDurationFailure.OutsideRange, range);
    }
}

/// <summary>One tool row of a Trace probe.</summary>
public sealed record TraceProbeTool(string Tool, string Disposition, string? Family, string? Detail);

/// <summary>One debug parameter of a Trace probe: its value, or why it has none.</summary>
public sealed record TraceProbeParameter(string Name, string State, string? Value, string? Detail);

/// <summary>What <c>trace.probe</c> observed for one Target at one binding revision, checked as
/// the macOS App checks it (<c>TraceRuntimeProbeResponseDecoding</c>).</summary>
public sealed record TraceProbe(
    string TargetId,
    long BindingRevision,
    string AdapterDisposition,
    string? Tool,
    string? Family,
    IReadOnlyList<string> SupportedTags,
    IReadOnlyList<TraceProbeTool> Tools,
    IReadOnlyList<TraceProbeParameter> Parameters)
{
    private static readonly string[] ToolStates = ["captureEligible", "probeOnly", "unrecognized", "probeFailed"];
    private static readonly string[] ParameterStates = ["missing", "unreadable", "value"];

    public bool IsCaptureEligible => AdapterDisposition == "captureEligible";

    public static TraceProbe Parse(JsonValue value, TargetSummary target)
    {
        var o = Json.Object(value, "a Trace probe");
        var disposition = Json.OptionalString(o, "adapterDisposition");
        var tags = o.TryGetValue("supportedTags", out var t) && t is JsonArray ? TypedJson.List(t, TypedJson.String) : null;
        if (Json.OptionalString(o, "targetId") != target.TargetId
            || !(o.TryGetValue("bindingRevision", out var r) && r is JsonNumber n && n.TryGetInt64(out var revision) && revision == target.BindingRevision)
            || disposition is not ("captureEligible" or "unsupported")
            || tags is null || tags.Distinct(StringComparer.Ordinal).Count() != tags.Count
            || !(o.TryGetValue("tools", out var tr) && tr is JsonArray toolRows)
            || !(o.TryGetValue("parameters", out var pr) && pr is JsonArray parameterRows))
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned mismatched probe facts");
        }
        var tools = new List<TraceProbeTool>();
        foreach (var row in toolRows.Items)
        {
            if (row is not JsonObject tool || Json.OptionalString(tool, "tool") is not ("hitrace" or "bytrace") || !ToolStates.Contains(Json.OptionalString(tool, "disposition")))
            {
                throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned malformed tool facts");
            }
            tools.Add(new(Json.OptionalString(tool, "tool")!, Json.OptionalString(tool, "disposition")!, Json.OptionalString(tool, "family"), Json.OptionalString(tool, "detail")));
        }
        if (!tools.Select(x => x.Tool).ToHashSet().SetEquals(["hitrace", "bytrace"]))
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime omitted a required tool probe");
        }
        var parameters = new List<TraceProbeParameter>();
        foreach (var row in parameterRows.Items)
        {
            if (row is not JsonObject parameter || Json.OptionalString(parameter, "name") is not { } name || !TraceOperations.ParameterNames.Contains(name)
                || parameters.Any(p => p.Name == name) || Json.OptionalString(parameter, "state") is not { } state || !ParameterStates.Contains(state))
            {
                throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned malformed parameter facts");
            }
            var parameterValue = Json.OptionalString(parameter, "value");
            var detail = Json.OptionalString(parameter, "detail");
            if ((state == "value") != (parameterValue is not null) || (state == "unreadable" && detail is null))
            {
                throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned contradictory parameter facts");
            }
            parameters.Add(new(name, state, parameterValue, detail));
        }
        if (parameters.Count != TraceOperations.ParameterNames.Count)
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime omitted parameter facts");
        }
        var probeTool = Json.OptionalString(o, "tool");
        var family = Json.OptionalString(o, "family");
        if (disposition == "captureEligible" && (probeTool != "hitrace" || family is null || tags.Count == 0))
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "Runtime returned incomplete adapter facts");
        }
        return new(target.TargetId, target.BindingRevision, disposition, probeTool, family, tags, tools, parameters);
    }
}

/// <summary>An adopted Target joined with its one current device observation (macOS
/// <c>TraceApplicationFacade.rejoin</c>): the device's name, system version, connect key and
/// transport, when exactly one authorized candidate matches its binding.</summary>
public sealed record TraceTarget(TargetSummary Target, string? DeviceName, string? SystemVersion, string? ConnectKey, string? Transport, bool Connected)
{
    public string TargetId => Target.TargetId;

    /// <summary>The picker title: the observed name, else the Runtime's, else the identifier.</summary>
    public string Title => Nonempty(DeviceName) ?? Target.DisplayName ?? Target.TargetId;

    /// <summary>"systemVersion · connectKey · TRANSPORT", the connect key shortened past 10.</summary>
    public string? ConnectionSummary => Join(" · ", Nonempty(ConnectKey) is { } key && key.Length > 10 ? $"{key[..4]}…{key[^5..]}" : Nonempty(ConnectKey));

    public string? AccessibleConnectionSummary => Join(", ", Nonempty(ConnectKey));

    private string? Join(string separator, string? key)
    {
        var parts = new[] { Nonempty(SystemVersion), key, Nonempty(Transport)?.ToUpperInvariant() }.OfType<string>().ToArray();
        return parts.Length == 0 ? null : string.Join(separator, parts);
    }

    private static string? Nonempty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    public static IReadOnlyList<TraceTarget> Join(IReadOnlyList<TargetSummary> targets, IReadOnlyList<DeviceCandidate>? candidates) =>
        targets.Select(target =>
        {
            var matches = (candidates ?? []).Where(c => c.AdoptedTargetId == target.TargetId && c.BindingRevision == target.BindingRevision).ToArray();
            return matches is [{ } candidate]
                ? new TraceTarget(target, candidate.DisplayName ?? candidate.DeviceName, candidate.SystemVersion, candidate.CandidateKey, candidate.Transport,
                    candidate is { Stale: false, AuthorizationState: "Connected" })
                : new TraceTarget(target, null, null, null, null, false);
        }).ToArray();
}

/// <summary>Why a capture cannot start: a catalogue key, or a Runtime reason shown as it is.</summary>
public sealed record TraceBlocker(string? Key, string? Text);

/// <summary>The Trace workspace: the operation's facts, the Targets joined with the device
/// observation, the probe of the selected Target, and the recent diagnostics Jobs.</summary>
public sealed record TraceState(
    OperationFacts Operation,
    Loaded<IReadOnlyList<TargetSummary>> Targets,
    IReadOnlyList<DeviceCandidate>? Candidates,
    Loaded<TraceProbe>? Probe,
    Loaded<IReadOnlyList<RecentJob>> Jobs,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached)
{
    public IReadOnlyList<TraceTarget> JoinedTargets => TraceTarget.Join(Targets.Value ?? [], Candidates);

    public (long Minimum, long Maximum) DurationRange => Operation.RangeOf("durationSeconds") ?? TraceOperations.DefaultDurationRange;

    /// <summary>The fixed buffer, or null when the Catalog's range excludes it.</summary>
    public int? CaptureBufferKB =>
        (Operation.RangeOf("traceBufferKB") ?? TraceOperations.DefaultBufferRange) is var range && TraceOperations.DefaultBufferKB >= range.Minimum && TraceOperations.DefaultBufferKB <= range.Maximum
            ? TraceOperations.DefaultBufferKB
            : null;

    /// <summary>The probe of exactly this Target at its binding revision, or null.</summary>
    public TraceProbe? ProbeOf(TraceTarget? target) =>
        Probe?.Value is { } probe && target is not null && probe.TargetId == target.TargetId && probe.BindingRevision == target.Target.BindingRevision ? probe : null;

    /// <summary>The first choice the macOS page makes after a refresh: the pinned Target, the
    /// current selection when still listed, the first Connected candidate's Target, the probed
    /// Target, else the first.</summary>
    public string? ResolveSelection(string? pinned, string? current)
    {
        var targets = JoinedTargets;
        if (pinned is not null) return pinned;
        if (current is not null && targets.Any(t => t.TargetId == current)) return current;
        if (targets.FirstOrDefault(t => t.Connected) is { } connected) return connected.TargetId;
        if (Probe?.Value is { } probe && targets.Any(t => t.TargetId == probe.TargetId)) return probe.TargetId;
        return targets.FirstOrDefault()?.TargetId;
    }

    /// <summary>macOS <c>captureBlockers</c>, in its order.</summary>
    public IReadOnlyList<TraceBlocker> Blockers(TraceTarget? target, TracePreset preset, bool durationValid)
    {
        var blockers = new List<TraceBlocker>();
        switch (Operation.Availability.Kind)
        {
            case AvailabilityKind.Checking:
                blockers.Add(new("trace.blocker.checking", null));
                break;
            case AvailabilityKind.Unavailable:
                blockers.Add(new("trace.blocker.operation", null));
                blockers.AddRange(Operation.Availability.Reasons.Select(r => new TraceBlocker(null, r)));
                break;
        }
        if (target is null) blockers.Add(new("trace.blocker.target", null));
        if (!durationValid) blockers.Add(new("trace.blocker.duration", null));
        if (CaptureBufferKB is null) blockers.Add(new("trace.blocker.buffer", null));
        if (ProbeOf(target) is not { } probe)
        {
            blockers.Add(new("trace.blocker.capability", null));
        }
        else if (!probe.IsCaptureEligible)
        {
            blockers.Add(new("trace.blocker.adapterUnsupported", null));
        }
        else
        {
            if (probe.Parameters.Count != TraceOperations.ParameterNames.Count) blockers.Add(new("trace.blocker.capability", null));
            if (preset.Tags.Count == 0) blockers.Add(new("trace.blocker.noTags", null));
            else if (preset.Tags.Any(tag => !probe.SupportedTags.Contains(tag))) blockers.Add(new("trace.blocker.tags", null));
        }
        return blockers;
    }
}

/// <summary>Where the page puts a captured Trace to open it: <c>TraceInbox\&lt;sha256&gt;.htrace</c>
/// under the App's own cache (macOS <c>Caches/ArkDeck/TraceInbox</c>, created 0700 and never a
/// symbolic link; on Windows the App's cache root, by default in the per-user temporary
/// directory, a reparse point refused).</summary>
public static class TraceInbox
{
    public static string Root(string cacheRoot) => Path.Combine(cacheRoot, "TraceInbox");

    /// <summary>The staging path of a Trace with this digest, or null when it cannot be made.</summary>
    public static string? PathFor(string root, string sha256)
    {
        if (sha256.Length != 64 || !sha256.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'))) return null;
        try
        {
            var directory = Directory.CreateDirectory(root);
            if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) return null;
            var destination = Path.Combine(directory.FullName, sha256 + ".htrace");
            if (File.Exists(destination) && File.GetAttributes(destination).HasFlag(FileAttributes.ReparsePoint)) return null;
            return Directory.Exists(destination) ? null : destination;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }
}

/// <summary>A Trace the viewer has open: the file, its size and SHA-256, and — for a captured
/// Trace — the Job and Artifact it came from, so the Runtime's inspector can be asked about it.</summary>
public sealed record TraceDocument(string Path, string Name, long ByteCount, string Sha256, string? JobId, ArtifactSummary? Artifact)
{
    public static readonly IReadOnlyList<string> Extensions = [".htrace", ".ftrace", ".systrace", ".trace"];

    /// <summary>Reads a local Trace file's size and digest; null when it cannot be read.</summary>
    public static async Task<TraceDocument?> OpenAsync(string path, string? jobId = null, ArtifactSummary? artifact = null)
    {
        try
        {
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            var digest = Convert.ToHexStringLower(await SHA256.HashDataAsync(file).ConfigureAwait(false));
            return new(System.IO.Path.GetFullPath(path), System.IO.Path.GetFileName(path), file.Length, digest, jobId, artifact);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }
}

/// <summary>The viewer's recent Traces (at most eight, newest first), kept beside the inbox so
/// they come back when the App starts again.</summary>
public sealed class TraceRecents(string file)
{
    public const int Limit = 8;

    public static TraceRecents In(string cacheRoot) => new(System.IO.Path.Combine(cacheRoot, "recent-traces.json"));

    public IReadOnlyList<string> Load()
    {
        try
        {
            if (!File.Exists(file)) return [];
            var value = StrictJson.Parse(File.ReadAllBytes(file));
            return value is JsonArray a ? a.Items.OfType<JsonString>().Select(s => s.Value).Take(Limit).ToArray() : [];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or MalformedJsonException)
        {
            return [];
        }
    }

    public IReadOnlyList<string> Add(string path) => Save([path, .. Load().Where(p => !string.Equals(p, path, StringComparison.OrdinalIgnoreCase))]);

    public IReadOnlyList<string> Remove(string path) => Save(Load().Where(p => !string.Equals(p, path, StringComparison.OrdinalIgnoreCase)).ToArray());

    private IReadOnlyList<string> Save(IReadOnlyList<string> paths)
    {
        var kept = paths.Take(Limit).ToArray();
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(file)!);
            File.WriteAllBytes(file, CanonicalJson.Encode(new JsonArray(kept.Select(p => (JsonValue)new JsonString(p)))));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // The list stays for this session only.
        }
        return kept;
    }
}

/// <summary>How opening a captured Trace ended: the staged document, or the catalogue key of the
/// macOS failure (<c>trace.viewer.artifactListUnavailable|artifactInvalid|stagingUnavailable|readFailed</c>)
/// with the Runtime's reason when there is one.</summary>
public sealed record TraceOpenOutcome(TraceDocument? Document, string? FailureKey, Unavailable? Reason, ControlFailure? DaemonFailure, bool Reached)
    : SurfaceState(DaemonFailure, Reached);

/// <summary>The Trace viewer: the Trace it has open (if any), what the Runtime's Trace inspector
/// answered about a captured one, and the recent Traces. Windows has no ArkTrace parser, so the
/// viewer draws no timeline; it says so, and shows what the file and the Runtime can tell.</summary>
public sealed record TraceViewerState(
    TraceDocument? Document,
    Loaded<TraceInspection>? Inspection,
    IReadOnlyList<string> Recents,
    ControlFailure? DaemonFailure,
    bool Reached) : SurfaceState(DaemonFailure, Reached)
{
    /// <summary>macOS <c>formatDuration</c> of a nanosecond count: seconds with three decimals from
    /// one second, then milliseconds, microseconds, else whole nanoseconds.</summary>
    public static string FormatDuration(long nanoseconds) => nanoseconds switch
    {
        >= 1_000_000_000 => (nanoseconds / 1e9).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture) + " s",
        >= 1_000_000 => (nanoseconds / 1e6).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture) + " ms",
        >= 1_000 => (nanoseconds / 1e3).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture) + " µs",
        _ => nanoseconds.ToString(System.Globalization.CultureInfo.InvariantCulture) + " ns",
    };
}

public sealed partial class SurfaceLoader
{
    /// <summary>The Trace viewer's facts: a captured Trace is asked of the Runtime's Trace
    /// inspector (<c>trace.inspect</c>); a local file has nothing to ask.</summary>
    public async Task<TraceViewerState> TraceViewerAsync(TraceDocument? document, TraceRecents recents)
    {
        var listed = recents.Load();
        if (document is not { JobId: { } jobId, Artifact: { } artifact }) return new(document, null, listed, null, false);
        var inspection = await InspectTraceAsync(jobId, artifact).ConfigureAwait(false);
        return new(document, inspection.Inspection, listed, inspection.DaemonFailure, inspection.Reached);
    }

    /// <summary>The Trace workspace (macOS <c>refreshWorkspace</c>): the operation's facts, the
    /// Targets and the recent diagnostics Jobs, the device observation to name the Targets, then
    /// <c>trace.probe</c> of the selected Target (the first when none is selected).</summary>
    public async Task<TraceState> TraceAsync(string? targetId)
    {
        var run = new Run(channel);
        OperationFacts operation;
        try
        {
            operation = (await OperationsAsync(channel, [TraceOperations.Reference]).ConfigureAwait(false))[0];
        }
        catch (ControlClientException error) when (error.Failure.ShowsRecoveryBanner)
        {
            operation = OperationFacts.Unread(TraceOperations.Reference, [error.Failure.Message]);
        }
        var targets = await run.Load(c => c.RequestAsync("target.list"), TargetSummary.ParseAll, CliCommands.TargetList);
        var jobs = await run.Load(c => c.RequestAsync("job.list", RecentJobParams()),
            v => (IReadOnlyList<RecentJob>)RecentJob.ParsePage(v).Where(j => j.Operation == TraceOperations.Reference).ToArray(), CliCommands.JobList);
        var candidates = (await run.Load(c => c.RequestAsync("device.observations"), DeviceCandidate.ParseAll, CliCommands.DeviceCandidates)).Value;
        Loaded<TraceProbe>? probe = null;
        if (targets.Value is { Count: > 0 } all && (all.FirstOrDefault(t => t.TargetId == targetId) ?? all[0]) is { } target)
        {
            probe = await run.Load(c => c.RequestAsync("trace.probe", Params(("targetId", new JsonString(target.TargetId)))),
                v => TraceProbe.Parse(v, target), CliCommands.TraceProbe);
        }
        return new(operation, targets, candidates, probe, jobs, run.DaemonFailure, run.Reached);
    }

    /// <summary>Submits one bounded Trace capture (<c>capture.diagnostics@1</c> with
    /// <c>DiagnosticCapturePreset.trace</c>: the Trace leg only, every other leg off).</summary>
    public Task<SubmitOutcome> SubmitTraceAsync(TargetSummary target, int durationSeconds, IReadOnlyList<string> categories, int bufferKB)
    {
        if (TraceOperations.PresetFailure(durationSeconds, categories, bufferKB) is { } failure)
        {
            return Task.FromResult(SubmitOutcome.Refused(failure, CliCommands.TraceCapture));
        }
        var request = RuntimeRequest.Build("trace-ui", "capture.diagnostics", 1, target.TargetId, target.BindingRevision,
        [
            ("durationSeconds", JsonNumber.FromInt64(durationSeconds)),
            ("hilogFilters", new JsonArray([])),
            ("traceCategories", new JsonArray(categories.Select(c => (JsonValue)new JsonString(c)))),
            ("traceBufferKB", JsonNumber.FromInt64(bufferKB)),
            ("uiDump", JsonBool.False),
            ("crashLogs", JsonBool.False),
            ("uiScreenshot", JsonBool.False),
            ("uiComponentTree", JsonBool.False),
            ("redactionProfile", new JsonString("standard")),
        ], ["rawArtifacts", "derivedArtifacts", "hardwareEvidence"], TraceOperations.Client);
        return SubmitTypedAsync(request, CliCommands.TraceCapture);
    }

    /// <summary>Opens a captured Job's raw Trace for the viewer (macOS <c>openPublishedTrace</c>):
    /// every <c>artifact.list</c> page, exactly one raw <c>trace.htrace</c> of the capture,
    /// read through <c>artifact.read</c> (sensitive, by the person's own capture) into the
    /// inbox, its SHA-256 checked.</summary>
    public async Task<TraceOpenOutcome> OpenCapturedTraceAsync(string jobId, string inboxRoot, CancellationToken cancellation = default)
    {
        var run = new Run(channel);
        var artifacts = await run.LoadPages(c => ArtifactPagesAsync(c, jobId), CliCommands.ArtifactListForJob(jobId));
        if (artifacts.Value is not { } rows) return new(null, "trace.viewer.artifactListUnavailable", artifacts.Unavailable, run.DaemonFailure, run.Reached);
        var candidates = rows.Where(IsRawTrace).ToArray();
        if (candidates is not [{ } trace]) return new(null, "trace.viewer.artifactInvalid", null, run.DaemonFailure, run.Reached);
        if (TraceInbox.PathFor(inboxRoot, trace.Digest!) is not { } destination) return new(null, "trace.viewer.stagingUnavailable", null, run.DaemonFailure, run.Reached);
        var exported = await new ArtifactExporter(channel).ExportAsync(jobId, trace, destination, allowSensitive: true, cancellation).ConfigureAwait(false);
        if (exported.ExportedPath is not { } path) return new(null, "trace.viewer.readFailed", exported.Failure, exported.DaemonFailure ?? run.DaemonFailure, true);
        return await TraceDocument.OpenAsync(path, jobId, trace).ConfigureAwait(false) is { } document
            ? new(document, null, null, run.DaemonFailure, true)
            : new(null, "trace.viewer.readFailed", null, run.DaemonFailure, true);
    }

    /// <summary>macOS <c>TracePublishedArtifactPolicy.selectRawTrace</c>: the capture's raw
    /// <c>trace.htrace</c> (raw by the operation's Catalog), octet-stream, sensitive, published,
    /// non-empty, with a lowercase SHA-256.</summary>
    public static bool IsRawTrace(ArtifactSummary artifact) =>
        artifact is { Name: ArtifactSummary.TraceName, MediaType: "application/octet-stream", IsSensitive: true, IsPublished: true, SourceOperation: TraceOperations.Reference, ByteCount: > 0 }
        && artifact.Digest is { Length: 64 } digest && digest.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));
}
