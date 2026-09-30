using System.Globalization;
using System.Text;

namespace ArkDeck.ClientKit.Json;

/// <summary>
/// A JSON value with the semantics of the Rust client's <c>serde_json::Value</c> (T1):
/// numbers keep serde's three representations (non-negative integer, negative integer,
/// 64-bit float), and object members are ordered by code point like serde's
/// <c>BTreeMap&lt;String, Value&gt;</c>, which is the order the wire encoding writes them in.
/// </summary>
public abstract class JsonValue : IEquatable<JsonValue>
{
    private protected JsonValue() { }

    public abstract bool Equals(JsonValue? other);

    public sealed override bool Equals(object? obj) => obj is JsonValue other && Equals(other);

    public abstract override int GetHashCode();

    /// <summary>The compact encoding serde_json writes for this value.</summary>
    public sealed override string ToString() => Encoding.UTF8.GetString(CanonicalJson.Encode(this));

    /// <summary>serde_json's <c>value[key]</c>: the member, or null for anything else.</summary>
    public JsonValue this[string key] =>
        this is JsonObject o && o.TryGetValue(key, out var member) ? member : JsonNull.Instance;
}

public sealed class JsonNull : JsonValue
{
    public static readonly JsonNull Instance = new();

    private JsonNull() { }

    public override bool Equals(JsonValue? other) => other is JsonNull;

    public override int GetHashCode() => 0;
}

public sealed class JsonBool : JsonValue
{
    public static readonly JsonBool True = new(true);
    public static readonly JsonBool False = new(false);

    private JsonBool(bool value) => Value = value;

    public bool Value { get; }

    public static JsonBool Of(bool value) => value ? True : False;

    public override bool Equals(JsonValue? other) => other is JsonBool b && b.Value == Value;

    public override int GetHashCode() => Value ? 1 : 2;
}

public enum JsonNumberKind
{
    /// <summary>serde <c>N::PosInt(u64)</c>: every integer literal that is not negative.</summary>
    PositiveInteger,

    /// <summary>serde <c>N::NegInt(i64)</c>: a negative integer literal within i64.</summary>
    NegativeInteger,

    /// <summary>serde <c>N::Float(f64)</c>: a literal with a fraction or an exponent, an
    /// integer beyond 64 bits, or <c>-0</c>.</summary>
    Float,
}

public sealed class JsonNumber : JsonValue
{
    private readonly ulong _positive;
    private readonly long _negative;
    private readonly double _float;

    private JsonNumber(JsonNumberKind kind, ulong positive, long negative, double value)
    {
        Kind = kind;
        _positive = positive;
        _negative = negative;
        _float = value;
    }

    public JsonNumberKind Kind { get; }

    public static JsonNumber FromUInt64(ulong value) => new(JsonNumberKind.PositiveInteger, value, 0, 0);

    /// <summary>serde's <c>From&lt;i64&gt;</c>: a non-negative value is a <c>PosInt</c>.</summary>
    public static JsonNumber FromInt64(long value) =>
        value < 0 ? new(JsonNumberKind.NegativeInteger, 0, value, 0) : FromUInt64((ulong)value);

    /// <summary>A finite float; serde's <c>Number::from_f64</c> refuses NaN and infinities.</summary>
    public static JsonNumber FromDouble(double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value), "JSON numbers are finite");
        return new(JsonNumberKind.Float, 0, 0, value);
    }

    /// <summary>serde <c>as_i64</c>.</summary>
    public bool TryGetInt64(out long value)
    {
        switch (Kind)
        {
            case JsonNumberKind.PositiveInteger when _positive <= long.MaxValue:
                value = (long)_positive;
                return true;
            case JsonNumberKind.NegativeInteger:
                value = _negative;
                return true;
            default:
                value = 0;
                return false;
        }
    }

    /// <summary>serde <c>as_u64</c>.</summary>
    public bool TryGetUInt64(out ulong value)
    {
        value = _positive;
        return Kind == JsonNumberKind.PositiveInteger;
    }

    /// <summary>serde <c>as_f64</c>: every number converts.</summary>
    public double AsDouble() => Kind switch
    {
        JsonNumberKind.PositiveInteger => _positive,
        JsonNumberKind.NegativeInteger => _negative,
        _ => _float,
    };

    public bool IsFloat => Kind == JsonNumberKind.Float;

    public override bool Equals(JsonValue? other) =>
        other is JsonNumber n && n.Kind == Kind && Kind switch
        {
            JsonNumberKind.PositiveInteger => n._positive == _positive,
            JsonNumberKind.NegativeInteger => n._negative == _negative,
            _ => n._float == _float,
        };

    public override int GetHashCode() => HashCode.Combine(Kind, _positive, _negative, _float == 0 ? 0 : _float);

    internal void Write(StringBuilder output)
    {
        switch (Kind)
        {
            case JsonNumberKind.PositiveInteger:
                output.Append(_positive.ToString(CultureInfo.InvariantCulture));
                break;
            case JsonNumberKind.NegativeInteger:
                output.Append(_negative.ToString(CultureInfo.InvariantCulture));
                break;
            default:
                output.Append(RyuFormat.Format(_float));
                break;
        }
    }
}

public sealed class JsonString : JsonValue
{
    public JsonString(string value) => Value = value ?? throw new ArgumentNullException(nameof(value));

    public string Value { get; }

    public override bool Equals(JsonValue? other) => other is JsonString s && string.Equals(s.Value, Value, StringComparison.Ordinal);

    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Value);
}

public sealed class JsonArray : JsonValue
{
    private readonly JsonValue[] _items;

    public JsonArray(IEnumerable<JsonValue> items) => _items = items.ToArray();

    public IReadOnlyList<JsonValue> Items => _items;

    public override bool Equals(JsonValue? other) =>
        other is JsonArray a && a._items.Length == _items.Length && _items.Zip(a._items).All(p => p.First.Equals(p.Second));

    public override int GetHashCode() => HashCode.Combine(_items.Length, _items.Length > 0 ? _items[0].GetHashCode() : 0);
}

public sealed class JsonObject : JsonValue
{
    private readonly SortedDictionary<string, JsonValue> _members = new(CodePointComparer.Instance);

    /// <summary>Members of a new object. A repeated key is refused, as the strict wire
    /// parser refuses it; callers never rely on a last-wins rule.</summary>
    public JsonObject(IEnumerable<KeyValuePair<string, JsonValue>> members)
    {
        foreach (var (key, value) in members)
        {
            ArgumentNullException.ThrowIfNull(key);
            ArgumentNullException.ThrowIfNull(value);
            if (!_members.TryAdd(key, value)) throw new ArgumentException($"duplicate JSON member: {key}");
        }
    }

    public JsonObject() { }

    public int Count => _members.Count;

    /// <summary>Members in code-point order of their keys.</summary>
    public IEnumerable<KeyValuePair<string, JsonValue>> Members => _members;

    public IEnumerable<string> Keys => _members.Keys;

    public bool ContainsKey(string key) => _members.ContainsKey(key);

    public bool TryGetValue(string key, out JsonValue value)
    {
        if (_members.TryGetValue(key, out var found))
        {
            value = found;
            return true;
        }
        value = JsonNull.Instance;
        return false;
    }

    public override bool Equals(JsonValue? other) =>
        other is JsonObject o && o._members.Count == _members.Count
        && _members.All(m => o._members.TryGetValue(m.Key, out var v) && v.Equals(m.Value));

    public override int GetHashCode() => _members.Count;
}

/// <summary>Orders strings by Unicode scalar value, which is the byte order of their UTF-8
/// encodings and so the order of Rust's <c>String</c> keys. Ordinal UTF-16 comparison
/// differs for characters above U+FFFF against U+E000..U+FFFF.</summary>
public sealed class CodePointComparer : IComparer<string>
{
    public static readonly CodePointComparer Instance = new();

    public int Compare(string? x, string? y)
    {
        if (ReferenceEquals(x, y)) return 0;
        if (x is null) return -1;
        if (y is null) return 1;
        var left = x.EnumerateRunes();
        var right = y.EnumerateRunes();
        while (true)
        {
            var hasLeft = left.MoveNext();
            var hasRight = right.MoveNext();
            if (!hasLeft || !hasRight) return hasLeft == hasRight ? 0 : hasLeft ? 1 : -1;
            var order = left.Current.Value.CompareTo(right.Current.Value);
            if (order != 0) return order;
        }
    }
}
