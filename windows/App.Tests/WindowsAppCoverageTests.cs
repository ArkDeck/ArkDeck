using System.Text.Json;
using System.Text.RegularExpressions;

namespace ArkDeck.App.Tests;

/// <summary>Check links in the actual rendered App metadata against the complete checkout.
/// Isolated Rust contract views deliberately contain neither Windows sources nor GUI run notes.
/// A source link establishes reviewability, never a passing GUI or hardware result.</summary>
[TestClass]
public sealed class WindowsAppCoverageTests
{
    [TestMethod]
    public void EveryAppClaimLinksItsExactWindowsFixtureAndRecord()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(RepoPaths.At("openspec", "contracts", "cli-feature-coverage.json")));
        var rows = document.RootElement.GetProperty("entries").EnumerateArray()
            .Where(row => row.GetProperty("source").GetString()!.StartsWith("app:", StringComparison.Ordinal)).ToArray();
        Assert.AreEqual(68, rows.Length);
        Assert.AreEqual(68, rows.Select(row => row.GetProperty("feature").GetString()!).Distinct(StringComparer.Ordinal).Count());
        foreach (var row in rows)
        {
            var feature = row.GetProperty("feature").GetString()!;
            CollectionAssert.Contains(row.GetProperty("requiredPlatforms").EnumerateArray().Select(v => v.GetString()!).ToArray(), "windows", feature);
            var note = row.GetProperty("note").GetString()!;
            StringAssert.Contains(note, "The argv conformance fixture covers the CLI equivalent, not the GUI.", feature);
            var evidence = Regex.Match(note, @" Evidence: ([^ ]+)\. The argv");
            Assert.IsTrue(evidence.Success, feature + ": missing GUI source record");
            var evidencePath = evidence.Groups[1].Value.Split('#')[0];
            Assert.IsTrue(File.Exists(SourcePath(evidencePath)), feature + ": " + evidencePath);
            var fixture = Regex.Match(note, @"Windows GUI fixture: ([^ ]+)\.");
            if (!fixture.Success)
            {
                Assert.AreNotEqual("implemented", row.GetProperty("implementationStatusByPlatform").GetProperty("windows").GetString(), feature);
                continue;
            }
            var parts = fixture.Groups[1].Value.Split('#');
            Assert.AreEqual(2, parts.Length, feature);
            Assert.IsTrue(parts[0].StartsWith("windows/App.Tests/", StringComparison.Ordinal)
                || parts[0].StartsWith("windows/App.UITests/", StringComparison.Ordinal), feature);
            var source = File.ReadAllText(SourcePath(parts[0]));
            Assert.IsTrue(Regex.IsMatch(source, @"\b(?:void|Task(?:<[^>]+>)?)\s+" + Regex.Escape(parts[1]) + @"\s*\("),
                feature + ": exact GUI fixture method missing: " + fixture.Groups[1].Value);
        }
    }

    private static string SourcePath(string relative)
    {
        Assert.IsFalse(Path.IsPathRooted(relative));
        Assert.IsFalse(relative.Split('/').Any(part => part is "" or "." or ".."));
        return RepoPaths.At(relative.Split('/'));
    }
}
