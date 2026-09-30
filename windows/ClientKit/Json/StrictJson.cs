using System.Globalization;
using System.Text.Json;

namespace ArkDeck.ClientKit.Json;

/// <summary>A document the strict parser refuses (the Rust client's <c>ContractError::Malformed</c>).</summary>
public sealed class MalformedJsonException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// The Rust client's <c>strict_json</c> (T1): one JSON document, surrounding JSON whitespace
/// only, no BOM, no comments, no trailing commas, valid UTF-8, at most 127 nested
/// arrays/objects (serde_json's recursion limit of 128 counts down to zero), and any
/// duplicate object key refused — including escaped spellings of the same decoded key and
/// duplicates nested at any depth. Numbers follow serde_json's parser: an integer literal is
/// a non-negative or negative 64-bit integer when it fits, <c>-0</c> and anything else a
/// correctly rounded float, and a literal that rounds to infinity is refused.
/// </summary>
public static class StrictJson
{
    // serde_json starts remaining_depth at 128 and fails when a nested value brings it to 0.
    private const int MaxDepth = 127;

    public static JsonValue Parse(ReadOnlySpan<byte> utf8)
    {
        var reader = new Utf8JsonReader(utf8, new JsonReaderOptions
        {
            CommentHandling = JsonCommentHandling.Disallow,
            AllowTrailingCommas = false,
            AllowMultipleValues = false,
            MaxDepth = MaxDepth,
        });
        try
        {
            if (!reader.Read()) throw new MalformedJsonException("empty document");
            var value = ReadValue(ref reader);
            if (reader.Read()) throw new MalformedJsonException("trailing content");
            return value;
        }
        catch (JsonException error)
        {
            throw new MalformedJsonException(error.Message, error);
        }
        catch (InvalidOperationException error)
        {
            // Invalid UTF-8 or an unpaired surrogate escape inside a string.
            throw new MalformedJsonException(error.Message, error);
        }
    }

    private static JsonValue ReadValue(ref Utf8JsonReader reader)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null:
                return JsonNull.Instance;
            case JsonTokenType.True:
                return JsonBool.True;
            case JsonTokenType.False:
                return JsonBool.False;
            case JsonTokenType.String:
                return new JsonString(reader.GetString()!);
            case JsonTokenType.Number:
                // A reader over one span never splits a token into a sequence.
                return ParseNumber(reader.ValueSpan);
            case JsonTokenType.StartArray:
            {
                var items = new List<JsonValue>();
                while (true)
                {
                    if (!reader.Read()) throw new MalformedJsonException("unterminated array");
                    if (reader.TokenType == JsonTokenType.EndArray) return new JsonArray(items);
                    items.Add(ReadValue(ref reader));
                }
            }
            case JsonTokenType.StartObject:
            {
                var members = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
                while (true)
                {
                    if (!reader.Read()) throw new MalformedJsonException("unterminated object");
                    if (reader.TokenType == JsonTokenType.EndObject) return new JsonObject(members);
                    if (reader.TokenType != JsonTokenType.PropertyName) throw new MalformedJsonException("expected a member name");
                    var key = reader.GetString()!;
                    if (!reader.Read()) throw new MalformedJsonException("missing member value");
                    var value = ReadValue(ref reader);
                    if (!members.TryAdd(key, value)) throw new MalformedJsonException("duplicate key");
                }
            }
            default:
                throw new MalformedJsonException($"unexpected token {reader.TokenType}");
        }
    }

    /// <summary>serde_json's number grammar result for a literal the reader accepted.</summary>
    internal static JsonNumber ParseNumber(ReadOnlySpan<byte> literal)
    {
        var text = System.Text.Encoding.ASCII.GetString(literal);
        var integer = text.AsSpan().IndexOfAny('.', 'e', 'E') < 0;
        if (integer)
        {
            var negative = text.StartsWith('-');
            var magnitude = negative ? text[1..] : text;
            if (ulong.TryParse(magnitude, NumberStyles.None, CultureInfo.InvariantCulture, out var significand))
            {
                if (!negative) return JsonNumber.FromUInt64(significand);
                // parse_number: `(significand as i64).wrapping_neg()`; a result >= 0 (that
                // is -0, or a magnitude beyond i64) becomes `-(significand as f64)`.
                var wrapped = unchecked(-(long)significand);
                if (wrapped < 0) return JsonNumber.FromInt64(wrapped);
                return JsonNumber.FromDouble(-(double)significand);
            }
            // Beyond u64: serde_json's parse_long_integer continues as a float.
        }
        var value = double.Parse(text, NumberStyles.Float, CultureInfo.InvariantCulture);
        if (!double.IsFinite(value)) throw new MalformedJsonException("number out of range");
        return JsonNumber.FromDouble(value);
    }
}
