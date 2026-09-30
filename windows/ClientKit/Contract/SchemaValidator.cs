using ArkDeck.ClientKit.Json;

namespace ArkDeck.ClientKit.Contract;

/// <summary>
/// Port of the Rust contract's <c>validate_method_value</c> (<c>arkdeck-contract/src/schema.rs</c>,
/// T1): the closed schema vocabulary the Swift contract generator emits, every definition
/// checked before any instance is matched, and the same number, pattern and length rules.
/// </summary>
public static class SchemaValidator
{
    public static void ValidateMethodValue(string method, string part, JsonValue value)
    {
        if (!ContractSchemas.TryGetDefinition(method, part, out var schema))
        {
            throw new ContractException(ContractErrorKind.UnknownMethod, method);
        }
        ValidateSchema(schema);
        if (!Matches(schema, value)) throw new ContractException(ContractErrorKind.SchemaMismatch, $"{method} {part}");
    }

    private static bool KnownType(string kind) =>
        kind is "null" or "string" or "boolean" or "object" or "array" or "number" or "integer";

    private static void ValidateSchema(JsonValue schema)
    {
        if (schema is not JsonObject fields) throw Mismatch();
        foreach (var (key, constraint) in fields.Members)
        {
            switch (key)
            {
                case "type":
                    var valid = constraint switch
                    {
                        JsonString s => KnownType(s.Value),
                        JsonArray a => a.Items.Count > 0 && a.Items.All(k => k is JsonString s && KnownType(s.Value))
                                       && a.Items.Cast<JsonString>().Select(s => s.Value).Distinct(StringComparer.Ordinal).Count() == a.Items.Count,
                        _ => false,
                    };
                    if (!valid) throw Mismatch();
                    break;
                case "properties":
                    if (constraint is not JsonObject properties) throw Mismatch();
                    foreach (var (_, child) in properties.Members) ValidateSchema(child);
                    break;
                case "required":
                    if (constraint is not JsonArray required
                        || !required.Items.All(k => k is JsonString)
                        || required.Items.Cast<JsonString>().Select(s => s.Value).Distinct(StringComparer.Ordinal).Count() != required.Items.Count)
                    {
                        throw Mismatch();
                    }
                    break;
                case "items" or "not":
                    ValidateSchema(constraint);
                    break;
                case "additionalProperties" when constraint is JsonBool:
                    break;
                case "additionalProperties":
                    ValidateSchema(constraint);
                    break;
                case "enum" when constraint is JsonArray { Items.Count: > 0 }:
                    break;
                case "anyOf" or "oneOf":
                    if (constraint is not JsonArray { Items.Count: > 0 } alternatives) throw Mismatch();
                    foreach (var child in alternatives.Items) ValidateSchema(child);
                    break;
                case "const":
                    break;
                case "minLength" when constraint is JsonNumber n && n.TryGetUInt64(out _):
                    break;
                case "pattern" when constraint is JsonString p && SupportedPattern(p.Value):
                    break;
                default:
                    throw Mismatch();
            }
        }
    }

    private static bool SupportedPattern(string pattern) =>
        pattern == ControlContract.LowercaseSha256Pattern || pattern == ControlContract.NonnegativeInt64DecimalPattern;

    private static bool IntegerEqualsFloat(JsonNumber integer, double value)
    {
        if (!double.IsFinite(value) || value % 1 != 0) return false;
        // Exclusive at 2^63 and 2^64, as the Rust comparison is.
        if (integer.TryGetInt64(out var signed))
        {
            return value >= -9223372036854775808.0 && value < 9223372036854775808.0 && (long)value == signed;
        }
        if (integer.TryGetUInt64(out var unsigned))
        {
            return value >= 0 && value < 18446744073709551615.0 && (ulong)value == unsigned;
        }
        return false;
    }

    internal static bool EqualValues(JsonValue left, JsonValue right) => (left, right) switch
    {
        (JsonNumber l, JsonNumber r) => l.Equals(r)
            || (l.IsFloat && !r.IsFloat && IntegerEqualsFloat(r, l.AsDouble()))
            || (r.IsFloat && !l.IsFloat && IntegerEqualsFloat(l, r.AsDouble())),
        (JsonArray l, JsonArray r) => l.Items.Count == r.Items.Count && l.Items.Zip(r.Items).All(p => EqualValues(p.First, p.Second)),
        (JsonObject l, JsonObject r) => l.Count == r.Count
            && l.Members.All(m => r.TryGetValue(m.Key, out var other) && EqualValues(m.Value, other)),
        _ => left.Equals(right),
    };

    private static bool MatchesPattern(string pattern, string value)
    {
        if (pattern == ControlContract.LowercaseSha256Pattern)
        {
            return value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
        }
        if (pattern == ControlContract.NonnegativeInt64DecimalPattern)
        {
            return value.Length is > 0 and <= 19
                   && (value == "0" || !value.StartsWith('0'))
                   && value.All(c => c is >= '0' and <= '9')
                   && long.TryParse(value, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out _);
        }
        return false;
    }

    private static bool MatchesType(string kind, JsonValue value) => kind switch
    {
        "null" => value is JsonNull,
        "string" => value is JsonString,
        "boolean" => value is JsonBool,
        "object" => value is JsonObject,
        "array" => value is JsonArray,
        "number" => value is JsonNumber,
        "integer" => value is JsonNumber n && (n.TryGetInt64(out _) || n.TryGetUInt64(out _) || n.AsDouble() % 1 == 0),
        _ => false,
    };

    private static bool Matches(JsonValue schema, JsonValue value)
    {
        if (schema["anyOf"] is JsonArray anyOf && !anyOf.Items.Any(s => Matches(s, value))) return false;
        if (schema["oneOf"] is JsonArray oneOf && oneOf.Items.Where(s => Matches(s, value)).Take(2).Count() != 1) return false;
        if (schema is JsonObject o && o.TryGetValue("not", out var excluded) && Matches(excluded, value)) return false;
        if (schema is JsonObject c && c.TryGetValue("const", out var constant) && !EqualValues(constant, value)) return false;
        if (schema["enum"] is JsonArray variants && !variants.Items.Any(v => EqualValues(v, value))) return false;
        switch (schema["type"])
        {
            case JsonString kind when !MatchesType(kind.Value, value):
                return false;
            case JsonArray kinds when !kinds.Items.Any(k => k is JsonString s && MatchesType(s.Value, value)):
                return false;
            case JsonNumber or JsonBool or JsonObject:
                // Present but not a string or an array: the Rust `kind.as_array().is_some_and(..)` is false.
                return false;
        }
        if (value is JsonString text)
        {
            if (schema["minLength"] is JsonNumber minimum && minimum.TryGetUInt64(out var least)
                && (ulong)text.Value.EnumerateRunes().Count() < least)
            {
                return false;
            }
            if (schema["pattern"] is JsonString pattern && !MatchesPattern(pattern.Value, text.Value)) return false;
        }
        if (value is JsonObject fields)
        {
            if (schema["required"] is JsonArray required
                && required.Items.Any(k => !(k is JsonString s && fields.ContainsKey(s.Value))))
            {
                return false;
            }
            var properties = schema["properties"];
            var hasAdditional = schema is JsonObject so && so.TryGetValue("additionalProperties", out _);
            var additional = schema["additionalProperties"];
            foreach (var (key, member) in fields.Members)
            {
                if (properties is JsonObject p && p.TryGetValue(key, out var child))
                {
                    if (!Matches(child, member)) return false;
                }
                else if (hasAdditional && additional is JsonBool { Value: false })
                {
                    return false;
                }
                else if (hasAdditional && additional is JsonObject)
                {
                    if (!Matches(additional, member)) return false;
                }
            }
        }
        if (value is JsonArray items && schema is JsonObject s2 && s2.TryGetValue("items", out var itemSchema))
        {
            foreach (var item in items.Items)
            {
                if (!Matches(itemSchema, item)) return false;
            }
        }
        return true;
    }

    private static ContractException Mismatch() => new(ContractErrorKind.SchemaMismatch, "unsupported schema definition");
}
