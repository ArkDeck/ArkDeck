using ArkDeck.ClientKit.Json;

namespace ArkDeck.ClientKit.Contract;

/// <summary>
/// Helpers the generated records use. They decode like the Rust twins' serde derive:
/// closed objects (<c>deny_unknown_fields</c>), required members present (a required
/// nullable member may be null but not absent), <c>i64</c> from integer literals only,
/// <c>f64</c> from any number. Any mismatch is <see cref="ContractErrorKind.SchemaMismatch"/>.
/// </summary>
public static class TypedJson
{
    public static T Parse<T>(JsonValue value, Func<JsonValue, T> parse) => parse(value);

    public static JsonValue Json<T>(T value, Func<T, JsonValue> write) => write(value);

    public static JsonObject Object(JsonValue value, string[] members)
    {
        if (value is not JsonObject o) throw Mismatch("expected an object");
        foreach (var key in o.Keys)
        {
            if (Array.IndexOf(members, key) < 0) throw Mismatch($"unknown member {key}");
        }
        return o;
    }

    public static T Required<T>(JsonObject o, string key, Func<JsonValue, T> parse) =>
        o.TryGetValue(key, out var member) ? parse(member) : throw Mismatch($"missing member {key}");

    public static T? OptionalValue<T>(JsonObject o, string key, Func<JsonValue, T> parse) where T : struct =>
        o.TryGetValue(key, out var member) ? parse(member) : null;

    public static T? OptionalRef<T>(JsonObject o, string key, Func<JsonValue, T> parse) where T : class =>
        o.TryGetValue(key, out var member) ? parse(member) : null;

    public static string String(JsonValue value) =>
        value is JsonString s ? s.Value : throw Mismatch("expected a string");

    public static bool Bool(JsonValue value) =>
        value is JsonBool b ? b.Value : throw Mismatch("expected a boolean");

    public static long Int64(JsonValue value) =>
        value is JsonNumber { IsFloat: false } n && n.TryGetInt64(out var result)
            ? result
            : throw Mismatch("expected a 64-bit integer");

    public static double Double(JsonValue value) =>
        value is JsonNumber n ? n.AsDouble() : throw Mismatch("expected a number");

    public static JsonNull Null(JsonValue value) =>
        value is JsonNull n ? n : throw Mismatch("expected null");

    public static IReadOnlyList<T> List<T>(JsonValue value, Func<JsonValue, T> parse) =>
        value is JsonArray a ? a.Items.Select(parse).ToArray() : throw Mismatch("expected an array");

    public static JsonArray ListJson<T>(IReadOnlyList<T> values, Func<T, JsonValue> write) =>
        new(values.Select(write));

    private static ContractException Mismatch(string detail) => new(ContractErrorKind.SchemaMismatch, detail);
}
