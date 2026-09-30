using System.Globalization;
using System.Text;

namespace ArkDeck.ClientKit.Json;

/// <summary>
/// The compact encoding <c>serde_json::to_vec</c> writes (T0: the Rust client's request
/// bytes). Members in code-point order of their keys, no whitespace, strings escaped as
/// serde_json escapes them (<c>\"</c>, <c>\\</c>, <c>\b \f \n \r \t</c>, other controls as
/// lowercase <c>\u00XX</c>, everything else raw UTF-8), floats in Ryu's shortest form.
/// </summary>
public static class CanonicalJson
{
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <exception cref="ArgumentException">A string holds an unpaired surrogate, which no
    /// Rust <c>String</c> can hold.</exception>
    public static byte[] Encode(JsonValue value)
    {
        var output = new StringBuilder();
        Write(value, output);
        try
        {
            return StrictUtf8.GetBytes(output.ToString());
        }
        catch (EncoderFallbackException error)
        {
            throw new ArgumentException("a JSON string holds an unpaired surrogate", error);
        }
    }

    private static void Write(JsonValue value, StringBuilder output)
    {
        switch (value)
        {
            case JsonNull:
                output.Append("null");
                break;
            case JsonBool b:
                output.Append(b.Value ? "true" : "false");
                break;
            case JsonNumber n:
                n.Write(output);
                break;
            case JsonString s:
                WriteString(s.Value, output);
                break;
            case JsonArray a:
                output.Append('[');
                for (var i = 0; i < a.Items.Count; i++)
                {
                    if (i > 0) output.Append(',');
                    Write(a.Items[i], output);
                }
                output.Append(']');
                break;
            case JsonObject o:
                output.Append('{');
                var first = true;
                foreach (var (key, member) in o.Members)
                {
                    if (!first) output.Append(',');
                    first = false;
                    WriteString(key, output);
                    output.Append(':');
                    Write(member, output);
                }
                output.Append('}');
                break;
            default:
                throw new ArgumentException("unknown JSON value");
        }
    }

    private static void WriteString(string value, StringBuilder output)
    {
        output.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                case < ' ':
                    output.Append("\\u00").Append(((int)c).ToString("x2", CultureInfo.InvariantCulture));
                    break;
                default:
                    output.Append(c);
                    break;
            }
        }
        output.Append('"');
    }
}

/// <summary>
/// The float text serde_json writes: the shortest digits that round-trip, as
/// <c>d.ToString("R")</c> also finds them, laid out by Ryu's <c>format64</c> rules (plain
/// decimal for decimal exponents -5 &lt; kk &lt;= 16, otherwise scientific), with an explicit
/// sign on the exponent as the Rust crate writes it.
/// </summary>
public static class RyuFormat
{
    public static string Format(double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        var negative = double.IsNegative(value);
        if (value == 0) return negative ? "-0.0" : "0.0";

        // Shortest round-trip digits and their decimal exponent from .NET's "R" text.
        var text = Math.Abs(value).ToString("R", CultureInfo.InvariantCulture);
        var exponentAt = text.IndexOfAny(['E', 'e']);
        var mantissa = exponentAt < 0 ? text : text[..exponentAt];
        var exponent = exponentAt < 0 ? 0 : int.Parse(text[(exponentAt + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        var point = mantissa.IndexOf('.');
        var integerDigits = point < 0 ? mantissa.Length : point;
        var digits = mantissa.Replace(".", string.Empty, StringComparison.Ordinal);
        var leading = digits.Length - digits.TrimStart('0').Length;
        digits = digits[leading..];
        integerDigits -= leading;
        digits = digits.TrimEnd('0');
        // value = 0.digits × 10^kk, i.e. digits × 10^k with k = kk - length (Ryu's names).
        var length = digits.Length;
        var kk = integerDigits + exponent;
        var k = kk - length;

        var output = new StringBuilder();
        if (negative) output.Append('-');
        if (0 <= k && kk <= 16)
        {
            output.Append(digits).Append('0', k).Append(".0");
        }
        else if (0 < kk && kk <= 16)
        {
            output.Append(digits, 0, kk).Append('.').Append(digits, kk, length - kk);
        }
        else if (-5 < kk && kk <= 0)
        {
            output.Append("0.").Append('0', -kk).Append(digits);
        }
        else if (length == 1)
        {
            output.Append(digits);
            AppendExponent(output, kk - 1);
        }
        else
        {
            output.Append(digits[0]).Append('.').Append(digits, 1, length - 1);
            AppendExponent(output, kk - 1);
        }
        return output.ToString();
    }

    // serde_json writes `e+16` and `e-7` (recorded from the Rust crate, serde-json-vectors.json).
    private static void AppendExponent(StringBuilder output, int exponent)
    {
        output.Append('e').Append(exponent < 0 ? '-' : '+').Append(Math.Abs(exponent).ToString(CultureInfo.InvariantCulture));
    }
}
