using System.Text;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.ClientKit.Tests;

/// <summary>The strict parser and the canonical writer against outputs recorded from the
/// Rust crate itself (<c>Fixtures/serde-json-vectors.json</c>): numbers, escapes, member
/// order, duplicate keys, UTF-8, depth and surrounding bytes.</summary>
[TestClass]
public sealed class JsonTests
{
    [TestMethod]
    public void EveryRecordedSerdeJsonVectorDecodesAndEncodesAsRustDoes()
    {
        var document = StrictJson.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "serde-json-vectors.json")));
        var vectors = ((JsonArray)document["vectors"]).Items;
        Assert.IsTrue(vectors.Count >= 60);
        foreach (var vector in vectors)
        {
            var input = Convert.FromHexString(((JsonString)vector["inputHex"]).Value);
            var shown = Encoding.UTF8.GetString(input[..Math.Min(input.Length, 40)]);
            if (vector["expected"] is JsonString expected)
            {
                var encoded = Encoding.UTF8.GetString(CanonicalJson.Encode(StrictJson.Parse(input)));
                Assert.AreEqual(expected.Value, encoded, $"input {shown}");
            }
            else
            {
                Assert.ThrowsExactly<MalformedJsonException>(() => StrictJson.Parse(input), $"input {shown} must be refused");
            }
        }
    }

    [TestMethod]
    public void NumbersKeepSerdesThreeRepresentations()
    {
        Assert.AreEqual(JsonNumberKind.PositiveInteger, ((JsonNumber)StrictJson.Parse("0"u8)).Kind);
        Assert.AreEqual(JsonNumberKind.Float, ((JsonNumber)StrictJson.Parse("-0"u8)).Kind);
        Assert.AreEqual(JsonNumberKind.NegativeInteger, ((JsonNumber)StrictJson.Parse("-9223372036854775808"u8)).Kind);
        Assert.AreEqual(JsonNumberKind.Float, ((JsonNumber)StrictJson.Parse("-9223372036854775809"u8)).Kind);
        Assert.AreEqual(JsonNumberKind.Float, ((JsonNumber)StrictJson.Parse("1.0"u8)).Kind);
        // serde's Value equality: 1 and 1.0 are different values.
        Assert.AreNotEqual(StrictJson.Parse("1"u8), StrictJson.Parse("1.0"u8));
    }

    [TestMethod]
    public void MembersAreOrderedByCodePointNotUtf16()
    {
        var o = new JsonObject([new("\U0001F600", JsonBool.True), new("\uFF61", JsonBool.False), new("a", JsonNull.Instance)]);
        Assert.AreEqual("{\"a\":null,\"\uFF61\":false,\"\U0001F600\":true}", o.ToString());
    }

    [TestMethod]
    public void AnUnpairedSurrogateCannotBeEncoded()
    {
        Assert.ThrowsExactly<ArgumentException>(() => CanonicalJson.Encode(new JsonString("\uD800")));
    }
}
