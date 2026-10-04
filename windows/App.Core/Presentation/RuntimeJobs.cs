using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using ArkDeck.App.Core.Daemon;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// One typed Runtime operation request (<c>runtime-operation-request</c> 1.0.0), built exactly
/// as the macOS App's facades build it (<c>RuntimeOperationRequest</c> with a workspace
/// <c>clientContext</c>): a fixed operation reference, typed inputs, the target and binding
/// revision the App read, and the workspace's client name, which the daemon reads together with
/// the operation to decide what an App may submit. The App never sends an executable, argv or
/// device path; the daemon owns lowering. Encoded canonically (sorted keys), as the App's
/// <c>CanonicalJSONEncoders.canonical()</c> encodes it.
/// </summary>
public sealed record RuntimeRequest(string Json)
{
    public const string DocumentType = "runtime-operation-request";
    public const string SchemaVersion = "1.0.0";

    /// <summary>A per-process salt: consecutive work on one device groups under one thread
    /// (<c>RuntimeWorkspaceThread</c>), and a new App run starts a new one.</summary>
    private static readonly string ProcessSalt = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));

    public static RuntimeRequest Build(string requestPrefix, string operationId, int version, string targetId, long? bindingRevision,
        IEnumerable<(string Key, JsonValue Value)> inputs, IEnumerable<string> requestedOutputs, string clientName, bool threaded = true)
    {
        var nonce = Guid.NewGuid().ToString("D");
        var target = bindingRevision is { } revision
            ? SurfaceLoader.Params(("expectedBindingRevision", JsonNumber.FromInt64(revision)), ("targetId", new JsonString(targetId)))
            : SurfaceLoader.Params(("targetId", new JsonString(targetId)));
        var client = threaded
            ? SurfaceLoader.Params(("clientName", new JsonString(clientName)),
                ("provenance", SurfaceLoader.Params(("arkdeck.threadId", new JsonString(ThreadId(clientName, targetId))))))
            : SurfaceLoader.Params(("clientName", new JsonString(clientName)));
        var document = SurfaceLoader.Params(
            ("clientContext", client),
            ("documentType", new JsonString(DocumentType)),
            ("idempotencyKey", new JsonString($"{requestPrefix}-{nonce}")),
            ("inputs", SurfaceLoader.Params(inputs.ToArray())),
            ("operation", SurfaceLoader.Params(("id", new JsonString(operationId)), ("version", JsonNumber.FromInt64(version)))),
            ("requestId", new JsonString($"{requestPrefix}-{nonce}")),
            ("requestedOutputs", new JsonArray(requestedOutputs.Select(o => (JsonValue)new JsonString(o)))),
            ("schemaVersion", new JsonString(SchemaVersion)),
            ("target", target));
        return new(document.ToString());
    }

    /// <summary>The run-grouping thread of one workspace on one device: <c>t-</c> and the first
    /// 12 hex digits of SHA-256(salt|client|target) (<c>RuntimeWorkspaceThread.identifier</c>).</summary>
    public static string ThreadId(string clientName, string targetId, string? salt = null) =>
        "t-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{salt ?? ProcessSalt}|{clientName}|{targetId}")))[..12];

    /// <summary>The same request with the reviewed plan's digest pinned
    /// (<c>reviewedPlanDigest</c>): the admitted Job must be the plan the person reviewed.</summary>
    public RuntimeRequest Reviewed(string planDigest)
    {
        var document = (JsonObject)StrictJson.Parse(Encoding.UTF8.GetBytes(Json));
        var members = document.Members.Where(m => m.Key != "reviewedPlanDigest")
            .Append(new KeyValuePair<string, JsonValue>("reviewedPlanDigest", new JsonString(planDigest)));
        return new(new JsonObject(members).ToString());
    }
}

/// <summary>The Catalog facts of one operation as <c>operation.describe</c> and
/// <c>operation.list</c> answer them: its title, effect, budgets, steps and Artifacts, and
/// whether this Runtime can run it now (with the reasons when it cannot).</summary>
public sealed record OperationFacts(
    string Reference,
    string Title,
    string MinimumEffect,
    long TimeoutSeconds,
    long OutputByteBudget,
    OperationReadiness Availability,
    IReadOnlyList<OperationStep> Steps,
    IReadOnlyList<OperationInput>? Inputs = null)
{
    public bool IsAvailable => Availability.Kind == AvailabilityKind.Available;

    /// <summary>An operation whose facts could not be read: its reference, and why.</summary>
    public static OperationFacts Unread(string reference, IReadOnlyList<string> reasons) =>
        new(reference, reference, "", 0, 0, new OperationReadiness(AvailabilityKind.Unavailable, reasons), []);

    public static OperationFacts Parse(JsonValue describe, JsonObject? listed)
    {
        var o = Json.Object(describe, "an operation description");
        var reference = TypedJson.Required(o, "reference", TypedJson.String);
        var steps = o.TryGetValue("steps", out var s) && s is JsonArray
            ? TypedJson.List(s, row =>
            {
                var step = Json.Object(row, "an operation step");
                return new OperationStep(
                    TypedJson.Required(step, "stepId", TypedJson.String),
                    TypedJson.Required(step, "kind", TypedJson.String),
                    TypedJson.Required(step, "effect", TypedJson.String),
                    step.TryGetValue("optional", out var optional) && optional is JsonBool { Value: true });
            })
            : [];
        long Number(string key) => o.TryGetValue(key, out var v) && v is JsonNumber n && n.TryGetInt64(out var value) ? value : 0;
        var inputs = o.TryGetValue("inputs", out var i) && i is JsonArray
            ? TypedJson.List(i, row =>
            {
                var input = Json.Object(row, "an operation input");
                long? Bound(string key) => input.TryGetValue(key, out var v) && v is JsonNumber n && n.TryGetInt64(out var value) ? value : null;
                return new OperationInput(TypedJson.Required(input, "name", TypedJson.String), Bound("minimum"), Bound("maximum"));
            })
            : [];
        var availability = listed is null
            ? OperationReadiness.From(o, "availability", "availabilityReasons")
            : OperationReadiness.From(listed, "availability", "reasons");
        return new(reference, Json.OptionalString(o, "title") ?? reference, Json.OptionalString(o, "minimumEffect") ?? "",
            Number("timeoutSeconds"), Number("outputByteBudget"), availability, steps, inputs);
    }

    /// <summary>The published bounds of one integer input, or null when the Catalog publishes
    /// none (macOS <c>closedRange(_:)</c> over the descriptor's minimum and maximum).</summary>
    public (long Minimum, long Maximum)? RangeOf(string input) =>
        Inputs?.FirstOrDefault(i => i.Name == input) is { Minimum: { } minimum, Maximum: { } maximum } ? (minimum, maximum) : null;
}

/// <summary>One input of an operation's Catalog description, with its integer bounds.</summary>
public sealed record OperationInput(string Name, long? Minimum, long? Maximum);

public enum AvailabilityKind
{
    Checking,
    Available,
    Unavailable,
}

public sealed record OperationReadiness(AvailabilityKind Kind, IReadOnlyList<string> Reasons)
{
    public static readonly OperationReadiness Checking = new(AvailabilityKind.Checking, []);

    public static OperationReadiness From(JsonObject o, string stateKey, string reasonsKey)
    {
        var state = Json.OptionalString(o, stateKey);
        var reasons = o.TryGetValue(reasonsKey, out var r) && r is JsonArray ? TypedJson.List(r, TypedJson.String) : [];
        return state == "available"
            ? new(AvailabilityKind.Available, [])
            : new(AvailabilityKind.Unavailable, reasons.Count > 0 ? reasons : ["Runtime did not report an availability reason"]);
    }
}

public sealed record OperationStep(string Id, string Kind, string Effect, bool IsOptional);

/// <summary>A recent Job of one of a workspace's operations (<c>job.list</c>, the
/// <c>arkdeck.job-summary/1</c> rows): its state, and why it needs attention.</summary>
public sealed record RecentJob(
    string JobId,
    string Operation,
    string TargetId,
    string State,
    bool WaitingForHuman,
    bool OutcomeUnknown,
    string? FailureCode,
    long ResidueCount)
{
    public bool IsActive => !JobSummary.TerminalStates.Contains(State);

    public bool NeedsAttention => WaitingForHuman || OutcomeUnknown || (FailureCode is { } code && code != "cancelled") || ResidueCount > 0;

    public static RecentJob Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Job summary");
        if (TypedJson.Required(o, "schemaVersion", TypedJson.String) != "arkdeck.job-summary/1")
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "a Job summary of another schema");
        }
        var state = TypedJson.Required(o, "state", TypedJson.String);
        var unknown = TypedJson.Required(o, "outcomeUnknown", TypedJson.Bool);
        return new(
            TypedJson.Required(o, "jobId", TypedJson.String),
            TypedJson.Required(o, "operation", TypedJson.String),
            TypedJson.Required(o, "targetId", TypedJson.String),
            state,
            TypedJson.Required(o, "waitingForHuman", TypedJson.Bool),
            unknown,
            JobTerminal.FailureCodeOf(o, state, unknown),
            TypedJson.Required(o, "outstandingResidueCount", TypedJson.Int64));
    }

    public static IReadOnlyList<RecentJob> ParsePage(JsonValue value) =>
        TypedJson.Required(Json.Object(value, "a Job page"), "items", v => TypedJson.List(v, Parse));
}

/// <summary>What a run ended with: the Job's state, whether its outcome is known, its
/// machine-readable failure code, and its timeline (<c>job.show</c>, with <c>job.timeline</c>
/// pages when the timeline does not fit inline).</summary>
public sealed record JobTerminal(string JobId, string State, bool OutcomeUnknown, string? FailureCode, IReadOnlyList<string> Timeline)
{
    public bool Succeeded => State == "succeeded" && !OutcomeUnknown;

    /// <summary>The failure code a Job carries, or the one its state implies when the Runtime
    /// sends none (the macOS <c>compatibilityFailure</c>).</summary>
    public static string? FailureCodeOf(JsonObject o, string state, bool outcomeUnknown)
    {
        if (o.TryGetValue("failure", out var failure) && failure is JsonObject f) return TypedJson.Required(f, "code", TypedJson.String);
        if (outcomeUnknown || state == "waitingForRecovery") return "outcomeUnknown";
        return state switch
        {
            "failed" => "legacyFailure",
            "cancelled" => "cancelled",
            "interrupted" => "interrupted",
            _ => null,
        };
    }
}

/// <summary>A Job as <c>job.show</c> reads it: its terminal facts and its status object.</summary>
public sealed record JobShown(JobTerminal Terminal, JsonObject Status);

/// <summary>A submitted Job: its identifier (<c>arkdeck.job-acceptance/1</c>).</summary>
public sealed record JobAcceptance(string JobId)
{
    public static JobAcceptance Parse(JsonValue value)
    {
        var id = TypedJson.Required(Json.Object(value, "a Job acceptance"), "jobId", TypedJson.String);
        if (id.Length == 0) throw new ContractException(ContractErrorKind.SchemaMismatch, "a Job acceptance without a Job ID");
        return new(id);
    }
}

/// <summary>The Runtime-materialized plan of one request (<c>job.plan</c>, plan only: nothing is
/// admitted or dispatched): its digest, steps, effect and the inputs as the Runtime read them.</summary>
public sealed partial record JobPlan(
    string Operation,
    long BindingRevision,
    string ProviderId,
    string EffectiveEffect,
    string PlanDigest,
    string? AdmissionBlocker,
    JsonObject Inputs,
    IReadOnlyList<OperationStep> Steps)
{
    public static JobPlan Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Job plan");
        if (TypedJson.Required(o, "executionMode", TypedJson.String) != "planOnly"
            || TypedJson.Required(o, "jobAdmitted", TypedJson.Bool)
            || TypedJson.Required(o, "dispatchDisposition", TypedJson.String) != "notDispatched")
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "a plan that admitted or dispatched work");
        }
        var digest = TypedJson.Required(o, "materializedPlanDigest", TypedJson.String);
        if (!Sha256().IsMatch(digest)) throw new ContractException(ContractErrorKind.SchemaMismatch, "a plan digest that is not a SHA-256");
        return new(
            TypedJson.Required(o, "operation", TypedJson.String),
            TypedJson.Required(o, "bindingRevision", TypedJson.Int64),
            TypedJson.Required(o, "providerId", TypedJson.String),
            TypedJson.Required(o, "effectiveEffect", TypedJson.String),
            digest,
            Json.NullableString(o, "providerAdmissionBlocker"),
            TypedJson.Required(o, "inputs", v => Json.Object(v, "plan inputs")),
            TypedJson.Required(o, "steps", v => TypedJson.List(v, row =>
            {
                var step = Json.Object(row, "a plan step");
                return new OperationStep(
                    TypedJson.Required(step, "stepId", TypedJson.String),
                    TypedJson.Required(step, "kind", TypedJson.String),
                    TypedJson.Required(step, "effect", TypedJson.String),
                    step.TryGetValue("optional", out var optional) && optional is JsonBool { Value: true });
            })));
    }

    [GeneratedRegex("^[0-9a-f]{64}$")]
    private static partial Regex Sha256();
}

public sealed partial class SurfaceLoader
{
    /// <summary>The recent Jobs <c>job.list</c> answers (250, newest first, no timeline), as
    /// every macOS workspace reads them (<c>RuntimeAppReadResources.recentSummaryParams</c>).</summary>
    internal static JsonObject RecentJobParams() => Params(
        ("includeTimeline", JsonBool.False), ("order", new JsonString("createdAtDescJobIdAsc")), ("pageSize", JsonNumber.FromInt64(250)));

    /// <summary>Each operation's Catalog facts: <c>operation.list</c> once for availability,
    /// then <c>operation.describe</c> per reference. A failure leaves the operation unavailable
    /// with that reason, as the macOS workspaces show it.</summary>
    internal static async Task<IReadOnlyList<OperationFacts>> OperationsAsync(IControlChannel c, IReadOnlyList<string> references)
    {
        var listed = await c.RequestAsync("operation.list", Params()).ConfigureAwait(false);
        if (listed.Failure is { } failure) return references.Select(r => OperationFacts.Unread(r, [Describe(failure)])).ToArray();
        var rows = listed.Value is JsonArray a ? a.Items.OfType<JsonObject>().ToArray() : [];
        var facts = new List<OperationFacts>();
        foreach (var reference in references)
        {
            var row = rows.FirstOrDefault(r => Json.OptionalString(r, "reference") == reference);
            if (row is null)
            {
                facts.Add(OperationFacts.Unread(reference, [$"{reference} is missing complete availability facts"]));
                continue;
            }
            var described = await c.RequestAsync("operation.describe", Params(("reference", new JsonString(reference)))).ConfigureAwait(false);
            try
            {
                facts.Add(described.Failure is { } why ? OperationFacts.Unread(reference, [Describe(why)]) : OperationFacts.Parse(described.Value!, row));
            }
            catch (Exception error) when (error is ContractException or InvalidCastException or KeyNotFoundException or FormatException)
            {
                facts.Add(OperationFacts.Unread(reference, [error.Message]));
            }
        }
        return facts;
    }

    private static string Describe(ControlFailure failure) =>
        failure.Remote is { } wire ? $"{wire.Code}: {failure.Message}" : failure.Message;

    /// <summary>Plans one typed request (<c>job.plan</c>): the plan, or why not.</summary>
    public Task<SessionActionState<JobPlan>> PlanAsync(RuntimeRequest request, string cli) =>
        Action("job.plan", Params(("requestJson", new JsonString(request.Json))), JobPlan.Parse, cli);

    /// <summary>Submits one typed request (<c>job.submit</c>): the admitted Job, or why not.</summary>
    public Task<SessionActionState<JobAcceptance>> SubmitAsync(RuntimeRequest request, string cli) =>
        Action("job.submit", Params(("requestJson", new JsonString(request.Json))), JobAcceptance.Parse, cli);

    /// <summary>Runs one admitted Job to its end (<c>job.run</c>) and reads its terminal facts
    /// (<c>job.show</c>, and <c>job.timeline</c> when the timeline is paged): <c>job.run</c>
    /// answers the status projection, which carries no timeline.</summary>
    public async Task<SessionActionState<JobTerminal>> RunJobAsync(string jobId, string cli)
    {
        var shown = await RunAndShowAsync(jobId, cli).ConfigureAwait(false);
        return new(shown.Answer.Value is { } value ? Loaded<JobTerminal>.Of(value.Terminal) : Loaded<JobTerminal>.Not(shown.Answer.Unavailable!),
            shown.DaemonFailure, shown.Reached);
    }

    /// <summary><see cref="RunJobAsync"/> with the whole status the terminal was read from (the
    /// Viewer checks that nobody is waited for and no residue is left).</summary>
    internal async Task<SessionActionState<JobShown>> RunAndShowAsync(string jobId, string cli)
    {
        var run = await Action("job.run", Params(("jobId", new JsonString(jobId))), v => Json.Object(v, "a Job status"), cli).ConfigureAwait(false);
        if (run.Answer.Unavailable is { } refused) return new(Loaded<JobShown>.Not(refused), run.DaemonFailure, run.Reached);
        return await ShowAsync(jobId, cli).ConfigureAwait(false);
    }

    /// <summary>A Job's status presentation (<c>job.show</c>, its timeline inline or paged
    /// through <c>job.timeline</c>): the terminal facts, and the status object for the facts a
    /// workspace reads beyond them (a Flash's <c>processProgress</c>).</summary>
    internal async Task<SessionActionState<JobShown>> ShowAsync(string jobId, string cli)
    {
        var detail = await Action("job.show", Params(("jobId", new JsonString(jobId))), v => Json.Object(v, "a Job"), cli).ConfigureAwait(false);
        if (detail.Answer.Unavailable is { } unread) return new(Loaded<JobShown>.Not(unread), detail.DaemonFailure, detail.Reached);
        try
        {
            var show = detail.Answer.Value!;
            if (TypedJson.Required(show, "schemaVersion", TypedJson.String) != "arkdeck.job/1") throw new ContractException(ContractErrorKind.SchemaMismatch, "a Job of another schema");
            var job = TypedJson.Required(show, "job", v => Json.Object(v, "a Job status"));
            if (TypedJson.Required(job, "jobId", TypedJson.String) != jobId) throw new ContractException(ContractErrorKind.SchemaMismatch, "another Job's status");
            var timeline = TypedJson.Required(show, "timeline", v => Json.Object(v, "a timeline"));
            IReadOnlyList<string> entries = Json.OptionalString(timeline, "kind") == "inline"
                ? TypedJson.Required(timeline, "entries", v => TypedJson.List(v, TypedJson.String))
                : await TimelinePagesAsync(jobId).ConfigureAwait(false);
            var state = TypedJson.Required(job, "state", TypedJson.String);
            var unknown = TypedJson.Required(job, "outcomeUnknown", TypedJson.Bool);
            return new(Loaded<JobShown>.Of(new JobShown(new JobTerminal(jobId, state, unknown, JobTerminal.FailureCodeOf(job, state, unknown), entries), job)),
                detail.DaemonFailure, detail.Reached);
        }
        catch (Exception error) when (error is ContractException or InvalidCastException or KeyNotFoundException or FormatException)
        {
            return new(Loaded<JobShown>.Not(Unavailable.Unreadable(error, cli)), detail.DaemonFailure, true);
        }
    }

    /// <summary>A paged timeline (<c>job.timeline</c>): each entry's parts in order, joined.</summary>
    private async Task<IReadOnlyList<string>> TimelinePagesAsync(string jobId)
    {
        var entries = new SortedDictionary<long, StringBuilder>();
        string? cursor = null;
        for (var page = 0; page < 64; page++)
        {
            var parameters = cursor is null
                ? Params(("jobId", new JsonString(jobId)), ("pageSize", JsonNumber.FromInt64(500)))
                : Params(("cursor", new JsonString(cursor)), ("jobId", new JsonString(jobId)), ("pageSize", JsonNumber.FromInt64(500)));
            var result = await channel.RequestAsync("job.timeline", parameters).ConfigureAwait(false);
            if (result.Failure is { } failure) throw new ContractException(ContractErrorKind.SchemaMismatch, failure.Message);
            var o = Json.Object(result.Value!, "a timeline page");
            foreach (var item in TypedJson.Required(o, "items", v => TypedJson.List(v, i => Json.Object(i, "a timeline part"))))
            {
                var index = long.Parse(TypedJson.Required(item, "entryIndex", TypedJson.String), System.Globalization.CultureInfo.InvariantCulture);
                if (!entries.TryGetValue(index, out var text)) entries[index] = text = new StringBuilder();
                text.Append(TypedJson.Required(item, "text", TypedJson.String));
            }
            cursor = Json.NullableString(o, "nextCursor");
            if (cursor is null) return entries.Values.Select(b => b.ToString()).ToArray();
        }
        throw new ContractException(ContractErrorKind.SchemaMismatch, "job.timeline returned more than 64 pages");
    }
}
