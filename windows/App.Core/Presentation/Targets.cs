using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>One adopted Target as <c>target.list</c> projects it. The display name is the
/// Runtime's (<c>target.display-name.set</c>), shared with the CLI; its generation is the
/// optimistic-concurrency token a rename or clear must name.</summary>
public sealed record TargetSummary(
    string TargetId,
    string? DisplayName,
    string DisplayNameGeneration,
    long BindingRevision,
    string AdoptedAtUtc,
    string ToolVersion)
{
    /// <summary>The Runtime's display name, else the Target identifier.</summary>
    public string Title => DisplayName ?? TargetId;

    public static IReadOnlyList<TargetSummary> ParseAll(JsonValue value) => TypedJson.List(value, item =>
    {
        var o = Json.Object(item, "a Target");
        return new TargetSummary(
            TypedJson.Required(o, "targetId", TypedJson.String),
            Json.NullableString(o, "displayName"),
            TypedJson.Required(o, "displayNameGeneration", TypedJson.String),
            TypedJson.Required(o, "bindingRevision", TypedJson.Int64),
            TypedJson.Required(o, "adoptedAtUtc", TypedJson.String),
            TypedJson.Required(o, "toolVersion", TypedJson.String));
    });
}

/// <summary>The facts a device last confirmed about a Target (<c>target.show</c> observedFacts).</summary>
public sealed record TargetObservedFacts(string Model, string Firmware, string Transport, string ConfirmedAtUtc);

/// <summary>One Target as <c>target.show</c> projects it.</summary>
public sealed record TargetDetail(
    string TargetId,
    string? DisplayName,
    string DisplayNameGeneration,
    string ConnectKey,
    long BindingRevision,
    string StablePhysicalIdentitySha256,
    string AdoptedAtUtc,
    string ToolVersion,
    TargetObservedFacts? ObservedFacts)
{
    public static TargetDetail Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Target");
        TargetObservedFacts? facts = null;
        if (o.TryGetValue("observedFacts", out var observed) && observed is JsonObject f)
        {
            facts = new TargetObservedFacts(
                TypedJson.Required(f, "model", TypedJson.String),
                TypedJson.Required(f, "firmware", TypedJson.String),
                TypedJson.Required(f, "transport", TypedJson.String),
                TypedJson.Required(f, "confirmedAtUtc", TypedJson.String));
        }
        return new TargetDetail(
            TypedJson.Required(o, "targetId", TypedJson.String),
            Json.NullableString(o, "displayName"),
            TypedJson.Required(o, "displayNameGeneration", TypedJson.String),
            TypedJson.Required(o, "connectKey", TypedJson.String),
            TypedJson.Required(o, "bindingRevision", TypedJson.Int64),
            TypedJson.Required(o, "stablePhysicalIdentitySha256", TypedJson.String),
            TypedJson.Required(o, "adoptedAtUtc", TypedJson.String),
            TypedJson.Required(o, "toolVersion", TypedJson.String),
            facts);
    }
}

/// <summary>One state line of <c>target.availability</c> (presence, profile, tool): the state
/// and, when the Runtime gives one, its reason code and reason, as they came.</summary>
public sealed record AvailabilityFact(string State, string? ReasonCode, string? Reason)
{
    public static AvailabilityFact Parse(JsonObject parent, string member)
    {
        var o = TypedJson.Required(parent, member, v => Json.Object(v, member));
        return new AvailabilityFact(
            TypedJson.Required(o, "state", TypedJson.String),
            Json.OptionalString(o, "reasonCode"),
            Json.OptionalString(o, "reason"));
    }

    /// <summary>"state (reasonCode)", or the state alone.</summary>
    public string Text => ReasonCode is null ? State : $"{State} ({ReasonCode})";
}

/// <summary>One operation of <c>target.availability</c>: its reference, availability and the
/// Runtime's reason codes.</summary>
public sealed record OperationAvailability(string Reference, string Availability, IReadOnlyList<string> ReasonCodes);

/// <summary>What <c>target.availability</c> says about one Target.</summary>
public sealed record TargetAvailability(
    string TargetId,
    string ObservedAtUtc,
    string BindingState,
    AvailabilityFact Presence,
    AvailabilityFact Profile,
    AvailabilityFact Tool,
    string OperationsScope,
    string OperationsReasonCode,
    IReadOnlyList<OperationAvailability> Operations)
{
    public static TargetAvailability Parse(JsonValue value)
    {
        var o = Json.Object(value, "a Target availability");
        var binding = TypedJson.Required(o, "binding", v => Json.Object(v, "binding"));
        var operations = TypedJson.Required(o, "operations", v => Json.Object(v, "operations"));
        return new TargetAvailability(
            TypedJson.Required(o, "targetId", TypedJson.String),
            TypedJson.Required(o, "observedAtUtc", TypedJson.String),
            TypedJson.Required(binding, "state", TypedJson.String),
            AvailabilityFact.Parse(o, "presence"),
            AvailabilityFact.Parse(o, "profile"),
            AvailabilityFact.Parse(o, "tool"),
            TypedJson.Required(operations, "scope", TypedJson.String),
            TypedJson.Required(operations, "reasonCode", TypedJson.String),
            TypedJson.Required(operations, "items", v => TypedJson.List(v, item =>
            {
                var i = Json.Object(item, "an operation");
                return new OperationAvailability(
                    TypedJson.Required(i, "reference", TypedJson.String),
                    TypedJson.Required(i, "availability", TypedJson.String),
                    TypedJson.Required(i, "reasonCodes", r => TypedJson.List(r, TypedJson.String)));
            })));
    }
}

/// <summary>What a <c>target.display-name.set</c> or <c>clear</c> recorded: the Runtime's name
/// (null once cleared) and its new generation.</summary>
public sealed record DisplayNameChange(string TargetId, string? Name, string Generation, string UpdatedAtUtc)
{
    public static DisplayNameChange Parse(JsonValue value)
    {
        var o = Json.Object(value, "a display name change");
        return new DisplayNameChange(
            TypedJson.Required(o, "targetId", TypedJson.String),
            Json.NullableString(o, "name"),
            TypedJson.Required(o, "generation", TypedJson.String),
            TypedJson.Required(o, "updatedAtUtc", TypedJson.String));
    }
}

/// <summary>
/// The macOS App's rule for a device name a person types (<c>DeviceWorkspace.normalizedDisplayName</c>):
/// whitespace runs collapse to one space, and 1–64 characters (user-perceived characters, as
/// Swift counts them) remain. A name outside the rule is not sent; the rename dialog says why
/// (<c>device.rename.message</c>). The Runtime still checks its own bounds.
/// </summary>
public static class DisplayName
{
    public const int MaximumLength = 64;

    public static string? Normalize(string raw)
    {
        var name = string.Join(' ', raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var length = new System.Globalization.StringInfo(name).LengthInTextElements;
        return length is > 0 and <= MaximumLength ? name : null;
    }
}

/// <summary>Small JSON readers the projections share.</summary>
internal static class Json
{
    public static JsonObject Object(JsonValue value, string what) =>
        value as JsonObject ?? throw new ContractException(ContractErrorKind.SchemaMismatch, what + " is not an object");

    /// <summary>A required member that may be null.</summary>
    public static string? NullableString(JsonObject o, string key) =>
        TypedJson.Required(o, key, v => v is JsonNull ? null : TypedJson.String(v));

    /// <summary>A scalar as text (string as is; boolean, number and null as JSON spells them).</summary>
    public static string Text(JsonValue value) => value is JsonString s ? s.Value : value.ToString();

    /// <summary>A member that may be absent or null.</summary>
    public static string? OptionalString(JsonObject o, string key) =>
        o.TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;
}
