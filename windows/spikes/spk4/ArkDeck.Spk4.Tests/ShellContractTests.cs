using System.Text.Json;
using System.Xml.Linq;
using ArkDeck.Spk4.Fixtures;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace ArkDeck.Spk4.Tests;

/// <summary>Static checks of the shell XAML and the unavailable-capability catalogue
/// (design §H.6 item 1, XPA-AC-8).</summary>
[TestClass]
public sealed class ShellContractTests
{
    private static readonly XNamespace P = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";

    private static IEnumerable<string> AppXaml() =>
        Directory.EnumerateFiles(Path.Combine(RepoPaths.Spike, "ArkDeck.Spk4"), "*.xaml", SearchOption.AllDirectories)
            .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                        && !p.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"));

    [TestMethod]
    public void EveryFixedNavigationItemHasItsStableAutomationId()
    {
        var window = XElement.Load(Path.Combine(RepoPaths.Spike, "ArkDeck.Spk4", "MainWindow.xaml"));
        var ids = window.Descendants(P + "NavigationViewItem")
            .Select(e => (string?)e.Attribute("AutomationProperties.AutomationId"))
            .ToList();
        CollectionAssert.AreEqual(AutomationIds.FixedNavigationItems.ToList(), ids);
    }

    [TestMethod]
    public void NoControlIsDisabledInMarkup()
    {
        foreach (var file in AppXaml())
        {
            var text = File.ReadAllText(file);
            Assert.IsFalse(text.Contains("IsEnabled=\"False\"", StringComparison.OrdinalIgnoreCase),
                $"{Path.GetFileName(file)}: disabled placeholder controls are not allowed (XPA-AC-8)");
        }
    }

    [TestMethod]
    public void AppXamlUsesNoLiteralColours()
    {
        foreach (var file in AppXaml().Where(f => !f.EndsWith("ArkDeckTokens.xaml", StringComparison.Ordinal)))
        {
            var text = File.ReadAllText(file);
            StringAssert.DoesNotMatch(text, new System.Text.RegularExpressions.Regex("\"#[0-9A-Fa-f]{6,8}\""),
                $"{Path.GetFileName(file)}: colours come from the generated tokens, not a second palette");
        }
    }

    [TestMethod]
    public void UnavailableCapabilitiesCarryTheirCoverageCliPath()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("openspec", "contracts", "cli-feature-coverage.json")));
        var byFeature = doc.RootElement.GetProperty("entries").EnumerateArray()
            .ToDictionary(e => e.GetProperty("feature").GetString()!, e => e);
        foreach (var cap in UnavailableCatalog.DebugTabs.Append(UnavailableCatalog.TraceViewer))
        {
            Assert.IsTrue(byFeature.TryGetValue(cap.Feature, out var entry), cap.Feature);
            var commands = new List<string>();
            if (entry.TryGetProperty("targetCommand", out var t) && t.ValueKind == JsonValueKind.String) commands.Add(t.GetString()!);
            if (entry.TryGetProperty("equivalentCommands", out var eq)) commands.AddRange(eq.EnumerateArray().Select(c => c.GetString()!));
            CollectionAssert.Contains(commands, cap.CliPath, cap.Feature);
            StringAssert.StartsWith(cap.Heading, $"{cap.Title}: unavailable(");
        }
        CollectionAssert.AreEqual(new[] { "Artifacts", "Logs", "Apps", "Network", "Commands" },
            UnavailableCatalog.DebugTabs.Select(t => t.Title).ToArray(), "the five Debug tabs keep the macOS names");
    }

    [TestMethod]
    public void AutomationIdsAreUnique()
    {
        var ids = typeof(AutomationIds).GetFields()
            .Where(f => f.IsLiteral && f.FieldType == typeof(string))
            .Select(f => (string)f.GetRawConstantValue()!)
            .ToList();
        Assert.AreEqual(ids.Count, ids.Distinct().Count());
    }
}
