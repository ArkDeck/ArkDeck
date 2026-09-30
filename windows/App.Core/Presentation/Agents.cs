using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>One choice a human action offers: the opaque value the Runtime accepts and the
/// words a person reads (the candidate's key when the Runtime names one).</summary>
public sealed record HumanChoice(string Value, string Label);

/// <summary>A human action the Runtime is waiting on (<c>human-action.list|show</c>, the
/// <c>humanAction</c> of <c>agent.status</c>): what to do physically, until when, and — for a
/// choice such as which device — the closed set of values (<c>selectionSchema.enum</c>).</summary>
public sealed record HumanAction(
    string ActionId,
    string Category,
    string MinimumAction,
    string ReasonCode,
    string Status,
    string ResumeReference,
    string CreatedAt,
    string ExpiresAt,
    string OwnerKind,
    string OwnerId,
    IReadOnlyList<HumanChoice> Choices,
    IReadOnlyList<string>? SelectionValues)
{
    public bool IsWaiting => Status == "waiting";

    /// <summary>A resume must name one of these values (a pick-a-device action).</summary>
    public bool NeedsSelection => SelectionValues is { Count: > 0 };

    /// <summary>The value the Runtime accepts: one of <see cref="SelectionValues"/>, never
    /// free text.</summary>
    public bool Accepts(string? selection) => SelectionValues is null ? selection is null : selection is not null && SelectionValues.Contains(selection);

    public static HumanAction Parse(JsonValue value)
    {
        var o = Json.Object(value, "a human action");
        var owner = TypedJson.Required(o, "owner", v => Json.Object(v, "an owner"));
        IReadOnlyList<string>? values = null;
        if (o.TryGetValue("selectionSchema", out var schema) && schema is JsonObject s)
        {
            if (TypedJson.Required(s, "type", TypedJson.String) != "string") throw new ContractException(ContractErrorKind.SchemaMismatch, "a selection that is not a string");
            values = TypedJson.Required(s, "enum", v => TypedJson.List(v, TypedJson.String));
        }
        var choices = TypedJson.Required(o, "choices", v => TypedJson.List(v, item =>
        {
            var c = Json.Object(item, "a choice");
            var choice = TypedJson.Required(c, "value", TypedJson.String);
            return new HumanChoice(choice, Json.OptionalString(c, "candidateKey") ?? Json.OptionalString(c, "label") ?? choice);
        }));
        if (values is not null && choices.Any(c => !values.Contains(c.Value)))
        {
            throw new ContractException(ContractErrorKind.SchemaMismatch, "a choice outside the action's selection schema");
        }
        string S(string key) => TypedJson.Required(o, key, TypedJson.String);
        return new(S("actionId"), S("category"), S("minimumAction"), S("reasonCode"), S("status"), S("resumeReference"), S("createdAt"), S("expiresAt"),
            TypedJson.Required(owner, "kind", TypedJson.String), TypedJson.Required(owner, "id", TypedJson.String),
            choices.Count > 0 ? choices : values?.Select(v => new HumanChoice(v, v)).ToArray() ?? [], values);
    }

    public static IReadOnlyList<HumanAction> ParsePage(JsonValue value) =>
        TypedJson.Required(Json.Object(value, "a human-action page"), "items", v => TypedJson.List(v, Parse));
}

/// <summary>One agent execution (<c>agent.list|status</c>): its state, the Job it owns once it
/// has one, and the human action it waits on, if any.</summary>
public sealed record AgentExecution(
    string ExecutionId,
    string Operation,
    string State,
    string Generation,
    string? JobId,
    string? JobState,
    string? TargetId,
    string CreatedAt,
    string Deadline,
    string LastObservedAt,
    bool OutcomeUnknown,
    string? FailureCode,
    string? NextActionKind,
    string? NextActionReason,
    HumanAction? HumanAction)
{
    /// <summary>The terminal states of an agent execution (<c>arkdeck-hoststore</c>
    /// <c>agent_execution::TERMINAL</c>): no further transition, nothing to abandon.</summary>
    public static readonly IReadOnlySet<string> TerminalStates = new HashSet<string>(StringComparer.Ordinal) { "completed", "failed", "abandoned", "budgetExpired", "clockUntrusted" };

    public bool IsTerminal => TerminalStates.Contains(State);

    public static AgentExecution Parse(JsonValue value)
    {
        var o = Json.Object(value, "an agent execution");
        var next = o.TryGetValue("nextAction", out var n) && n is JsonObject no ? no : null;
        var human = o.TryGetValue("humanAction", out var h) && h is JsonObject ? HumanAction.Parse(h) : null;
        return new(
            TypedJson.Required(o, "executionId", TypedJson.String),
            TypedJson.Required(o, "operation", TypedJson.String),
            TypedJson.Required(o, "state", TypedJson.String),
            TypedJson.Required(o, "generation", TypedJson.String),
            Json.NullableString(o, "jobId"),
            Json.NullableString(o, "jobState"),
            Json.NullableString(o, "targetId"),
            TypedJson.Required(o, "createdAt", TypedJson.String),
            TypedJson.Required(o, "deadline", TypedJson.String),
            TypedJson.Required(o, "lastObservedAt", TypedJson.String),
            TypedJson.Required(o, "outcomeUnknown", TypedJson.Bool),
            Json.NullableString(o, "failureCode"),
            next is null ? null : TypedJson.Required(next, "kind", TypedJson.String),
            next is null ? null : TypedJson.Required(next, "reasonCode", TypedJson.String),
            human);
    }

    public static (IReadOnlyList<AgentExecution> Items, string? NextCursor) ParsePage(JsonValue value)
    {
        var page = Json.Object(value, "an agent execution page");
        var more = TypedJson.Required(page, "hasMore", TypedJson.Bool);
        var cursor = Json.NullableString(page, "nextCursor");
        if (more != cursor is not null) throw new ContractException(ContractErrorKind.SchemaMismatch, "a cursor without more rows, or more rows without a cursor");
        return (TypedJson.Required(page, "items", v => TypedJson.List(v, Parse)), cursor);
    }
}

/// <summary>The Agent page: the agent executions and the human actions the Runtime waits on.</summary>
public sealed record AgentsState(Loaded<IReadOnlyList<AgentExecution>> Executions, Loaded<IReadOnlyList<HumanAction>> HumanActions,
    ControlFailure? DaemonFailure, bool Reached) : SurfaceState(DaemonFailure, Reached);

/// <summary>A resume's answer: accepted (the state is read back), or why not.</summary>
public sealed record ResumeAnswer(string SchemaVersion)
{
    public static ResumeAnswer Parse(JsonValue value) =>
        new(TypedJson.Required(Json.Object(value, "a resume answer"), "schemaVersion", TypedJson.String));
}

public sealed partial class SurfaceLoader
{
    public const int AgentPageSize = 200;
    public const int AgentPageLimit = 16;

    public async Task<AgentsState> AgentsAsync()
    {
        var run = new Run(channel);
        var executions = await run.LoadPages(async c =>
        {
            var items = new List<AgentExecution>();
            var cursors = new HashSet<string>(StringComparer.Ordinal);
            string? cursor = null;
            for (var page = 0; page < AgentPageLimit; page++)
            {
                var parameters = cursor is null
                    ? Params(("pageSize", JsonNumber.FromInt64(AgentPageSize)))
                    : Params(("pageSize", JsonNumber.FromInt64(AgentPageSize)), ("cursor", new JsonString(cursor)));
                var result = await c.RequestAsync("agent.list", parameters).ConfigureAwait(false);
                if (result.Failure is { } failure) return ((IReadOnlyList<AgentExecution>?)null, failure);
                var (rows, next) = AgentExecution.ParsePage(result.Value!);
                items.AddRange(rows);
                if (next is null) return (items, null);
                if (!cursors.Add(next)) throw new ContractException(ContractErrorKind.SchemaMismatch, "agent.list repeated a cursor");
                cursor = next;
            }
            throw new ContractException(ContractErrorKind.SchemaMismatch, $"agent.list returned more than {AgentPageLimit} pages");
        }, CliCommands.AgentList);
        var human = await run.Load(c => c.RequestAsync("human-action.list", Params(("pageSize", JsonNumber.FromInt64(AgentPageSize)))),
            HumanAction.ParsePage, CliCommands.HumanActionList);
        return new(executions, human, run.DaemonFailure, run.Reached);
    }

    public Task<SessionActionState<AgentExecution>> AgentAsync(string executionId) =>
        Action("agent.status", Params(("executionId", new JsonString(executionId))), AgentExecution.Parse, CliCommands.ForExecution(CliCommands.AgentStatus, executionId));

    public Task<SessionActionState<HumanAction>> HumanActionAsync(string actionId) =>
        Action("human-action.show", Params(("humanAction", new JsonString(actionId))), HumanAction.Parse, CliCommands.ForHumanAction(CliCommands.HumanActionShow, actionId));

    /// <summary>Resumes after the person did what the action asks, naming the chosen value
    /// when the action has a selection schema (a value outside it is never sent): an agent
    /// execution's action through <c>agent.resume</c> with its resume reference (the macOS
    /// resume), any other through <c>human-action.resume</c> with the action and the reference.</summary>
    public Task<SessionActionState<ResumeAnswer>> ResumeAsync(HumanAction action, string? selection)
    {
        if (!action.Accepts(selection)) throw new ArgumentException("the selection is not one of the action's values", nameof(selection));
        if (action.OwnerKind == "agentExecution")
        {
            var reference = selection is null
                ? Params(("resumeReference", new JsonString(action.ResumeReference)))
                : Params(("resumeReference", new JsonString(action.ResumeReference)), ("selection", new JsonString(selection)));
            return Action("agent.resume", reference, ResumeAnswer.Parse, CliCommands.AgentResume);
        }
        var parameters = selection is null
            ? Params(("humanAction", new JsonString(action.ActionId)), ("resumeReference", new JsonString(action.ResumeReference)))
            : Params(("humanAction", new JsonString(action.ActionId)), ("resumeReference", new JsonString(action.ResumeReference)), ("selection", new JsonString(selection)));
        return Action("human-action.resume", parameters, ResumeAnswer.Parse, CliCommands.ForHumanAction(CliCommands.HumanActionResume, action.ActionId));
    }

    /// <summary>Abandons an agent execution (<c>agent.abandon</c>), guarded by the generation
    /// the App read.</summary>
    public Task<SessionActionState<AgentExecution>> AbandonAsync(AgentExecution execution) =>
        Action("agent.abandon", Params(("executionId", new JsonString(execution.ExecutionId)), ("expectedGeneration", new JsonString(execution.Generation))),
            AgentExecution.Parse, CliCommands.ForExecution(CliCommands.AgentAbandon, execution.ExecutionId));
}
