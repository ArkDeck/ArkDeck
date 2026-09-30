using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace ArkDeck.Spk4.Tests;

/// <summary>Guards the tokens.css → WinUI mapping against silent drift, with a parser that is
/// independent of tokens/gen_xaml_tokens.py.</summary>
[TestClass]
public sealed partial class TokenMappingTests
{
    private static readonly XNamespace X = "http://schemas.microsoft.com/winfx/2006/xaml";
    private static readonly XNamespace P = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";

    [GeneratedRegex(@"--ad-([a-z0-9-]+)\s*:\s*([^;]+);")]
    private static partial Regex Decl();

    private static (Dictionary<string, string> Light, Dictionary<string, string> Dark) Css()
    {
        var css = Regex.Replace(File.ReadAllText(RepoPaths.At("docs", "design", "arkdeck-ds", "src", "tokens.css")),
            @"/\*.*?\*/", "", RegexOptions.Singleline);
        var lightStart = css.IndexOf(":root {", StringComparison.Ordinal);
        var light = Parse(css[lightStart..css.IndexOf('}', lightStart)]);
        var mediaStart = css.IndexOf("@media (prefers-color-scheme: dark)", StringComparison.Ordinal);
        var dark = new Dictionary<string, string>(light);
        foreach (var (k, v) in Parse(css[mediaStart..css.IndexOf('}', mediaStart)])) dark[k] = v;
        return (light, dark);
    }

    private static Dictionary<string, string> Parse(string block) =>
        Decl().Matches(block).ToDictionary(m => m.Groups[1].Value, m => m.Groups[2].Value.Trim());

    private static string Pascal(string token) =>
        string.Concat(token.Split('-').Select(p => char.ToUpperInvariant(p[0]) + p[1..]));

    private static string? Argb(string css)
    {
        css = css.Trim().ToLowerInvariant();
        if (Regex.IsMatch(css, "^#[0-9a-f]{6}$")) return "#FF" + css[1..].ToUpperInvariant();
        var m = Regex.Match(css, @"^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)$");
        if (!m.Success) return null;
        var a = (int)Math.Round(double.Parse(m.Groups[4].Value, CultureInfo.InvariantCulture) * 255, MidpointRounding.ToEven);
        return $"#{a:X2}{int.Parse(m.Groups[1].Value):X2}{int.Parse(m.Groups[2].Value):X2}{int.Parse(m.Groups[3].Value):X2}";
    }

    private static XElement Xaml() =>
        XElement.Load(Path.Combine(RepoPaths.Spike, "ArkDeck.Spk4", "Themes", "ArkDeckTokens.xaml"));

    private static XElement Theme(XElement root, string key) =>
        root.Descendants(P + "ResourceDictionary").Single(d => (string?)d.Attribute(X + "Key") == key);

    [TestMethod]
    public void EveryColourTokenMapsVerbatimToLightAndDark()
    {
        var (light, dark) = Css();
        var root = Xaml();
        var colours = light.Where(kv => Argb(kv.Value) is not null).Select(kv => kv.Key).ToList();
        Assert.IsGreaterThanOrEqualTo(20, colours.Count, "tokens.css colour roles");
        foreach (var (theme, values) in new[] { ("Light", light), ("Dark", dark) })
        {
            var dict = Theme(root, theme);
            foreach (var token in colours)
            {
                var key = $"ArkDeck{Pascal(token)}Color";
                var el = dict.Elements(P + "Color").SingleOrDefault(e => (string?)e.Attribute(X + "Key") == key);
                Assert.IsNotNull(el, $"{theme}: {key} missing");
                Assert.AreEqual(Argb(values[token]), el.Value, $"{theme}: {key} drifted from --ad-{token}");
                Assert.IsTrue(dict.Elements(P + "SolidColorBrush").Any(e => (string?)e.Attribute(X + "Key") == $"ArkDeck{Pascal(token)}Brush"),
                    $"{theme}: brush for --ad-{token}");
            }
        }
    }

    [TestMethod]
    public void HighContrastUsesOnlySystemColours()
    {
        var (light, _) = Css();
        var hc = Theme(Xaml(), "HighContrast");
        var colours = light.Where(kv => Argb(kv.Value) is not null).Select(kv => Pascal(kv.Key)).ToList();
        foreach (var name in colours)
        {
            var brush = hc.Elements(P + "SolidColorBrush").Single(e => (string?)e.Attribute(X + "Key") == $"ArkDeck{name}Brush");
            StringAssert.Matches((string?)brush.Attribute("Color"), new Regex(@"^\{ThemeResource SystemColor\w+Color\}$"), name);
        }
        Assert.IsFalse(hc.ToString().Contains("#", StringComparison.Ordinal), "no literal colour in HighContrast");
    }

    [TestMethod]
    public void SpacingRadiiAndTypeRampMatch()
    {
        var (light, _) = Css();
        var root = Xaml();
        var byKey = root.Elements().Where(e => e.Attribute(X + "Key") is not null)
            .ToDictionary(e => (string)e.Attribute(X + "Key")!, e => e.Value);
        foreach (var (token, value) in light.Where(kv => kv.Key.StartsWith("radius-") || kv.Key.StartsWith("space-") || kv.Key.StartsWith("text-")))
        {
            Assert.AreEqual(value.Replace("px", ""), byKey[$"ArkDeck{Pascal(token)}"], $"--ad-{token}");
        }
    }
}
