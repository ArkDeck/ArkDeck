using System.Text.Json;
using ArkDeck.App.Core.Strings;

namespace ArkDeck.App.Tests;

/// <summary>The shared bilingual catalogue (AC-I18N-001): one source, the generated .resw
/// and the macOS .xcstrings agree; the App's language is chosen explicitly; a missing key is
/// visible, never blank.</summary>
[TestClass]
public sealed class CatalogueTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    public void TheGeneratedStringsMatchTheSharedSource()
    {
        var (code, output) = Python.Run(RepoPaths.At("windows", "scripts", "generate-ui-strings.py"), "--check");
        TestContext.WriteLine(output);
        Assert.AreEqual(0, code, output);
    }

    [TestMethod]
    public void TheGeneratedTokensMatchTokensCss()
    {
        var (code, output) = Python.Run(RepoPaths.At("windows", "scripts", "generate-xaml-tokens.py"), "--check");
        TestContext.WriteLine(output);
        Assert.AreEqual(0, code, output);
    }

    [TestMethod]
    public void BothLanguagesCarryEveryKeyWithTheSourceValues()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "ui-semantics", "strings.json")));
        var entries = doc.RootElement.GetProperty("entries").EnumerateArray().ToArray();
        CollectionAssert.AreEqual(entries.Select(e => e.GetProperty("key").GetString()).ToArray(), UiStrings.All.ToArray());
        foreach (var (language, member) in new[] { ("en-US", "en"), ("zh-Hans", "zh-Hans") })
        {
            var lookup = Resw.Lookup(language);
            foreach (var entry in entries)
            {
                Assert.AreEqual(entry.GetProperty(member).GetString(), lookup(entry.GetProperty("key").GetString()!), $"{language} {entry.GetProperty("key")}");
            }
        }
    }

    [TestMethod]
    public void SharedEntriesKeepTheMacOSValues()
    {
        // Independent of the generator: read the .xcstrings tables directly.
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "ui-semantics", "strings.json")));
        var shared = 0;
        foreach (var entry in doc.RootElement.GetProperty("entries").EnumerateArray())
        {
            if (entry.GetProperty("table").ValueKind == JsonValueKind.Null)
            {
                StringAssert.StartsWith(entry.GetProperty("key").GetString(), "windows.");
                continue;
            }
            shared++;
            var table = entry.GetProperty("table").GetString()!;
            using var catalog = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("ArkDeckApp", "Resources", table + ".xcstrings")));
            var localizations = catalog.RootElement.GetProperty("strings").GetProperty(entry.GetProperty("key").GetString()!).GetProperty("localizations");
            foreach (var language in new[] { "en", "zh-Hans" })
            {
                Assert.AreEqual(entry.GetProperty(language).GetString(),
                    localizations.GetProperty(language).GetProperty("stringUnit").GetProperty("value").GetString(), $"{table} {entry.GetProperty("key")} {language}");
            }
        }
        Assert.IsTrue(shared > 90, "the surfaces reuse the macOS strings");
    }

    [TestMethod]
    public void MissingKeysAreVisibleAndRecorded()
    {
        var strings = new Localizer(Resw.Lookup("zh-Hans"), AppLanguage.SimplifiedChinese);
        Assert.AreEqual("无法读取 Runtime 历史", strings.Text(UiStrings.HistoryUnavailableTitle));
        Assert.AreEqual("history.state.recovered", strings.Text("history.state.recovered"));
        CollectionAssert.AreEqual(new[] { "history.state.recovered" }, strings.Missing.ToArray());
    }

    [TestMethod]
    public void PlaceholdersFormatLikeTheMacOSCatalogue()
    {
        Assert.AreEqual("3 active", Localizer.Printf("%d active", [3]));
        Assert.AreEqual("unavailable(rejected): hdc.notConfigured", Localizer.Printf("unavailable(%1$@): %2$@", ["rejected", "hdc.notConfigured"]));
        Assert.AreEqual("b a", Localizer.Printf("%2$@ %1$@", ["a", "b"]));
        Assert.AreEqual("2 blockers · 0 warnings · 1 info", Localizer.Printf("%1$lld blockers · %2$lld warnings · %3$lld info", [2L, 0L, 1L]));
        Assert.AreEqual("100%", Localizer.Printf("100%%", []));
        var english = new Localizer(Resw.Lookup("en-US"), AppLanguage.English);
        Assert.AreEqual("CLI: arkdeck doctor", english.Format(UiStrings.WindowsCliEquivalent, "arkdeck doctor"));
    }

    [TestMethod]
    public void TheLanguageIsResolvedExplicitly()
    {
        Assert.AreEqual("zh-Hans", AppLanguage.Resolve("zh-Hans", ["en-US"]));
        Assert.AreEqual("en-US", AppLanguage.Resolve("en-GB", ["zh-CN"]));
        Assert.AreEqual("zh-Hans", AppLanguage.Resolve(null, ["fr-FR", "zh-Hans-CN", "en-US"]));
        Assert.AreEqual("zh-Hans", AppLanguage.Resolve("de-DE", ["zh-CN"]));
        Assert.AreEqual("en-US", AppLanguage.Resolve(null, ["fr-FR", "ja-JP"]));
    }

    [TestMethod]
    public void LongTranslationsWrap()
    {
        // AC-I18N-001 long text: every text the pages build wraps instead of clipping.
        var ui = File.ReadAllText(RepoPaths.At("windows", "App", "Controls", "Ui.cs"));
        StringAssert.Contains(ui, "TextWrapping = TextWrapping.Wrap");
        var longest = Resw.Load("zh-Hans").Values.Concat(Resw.Load("en-US").Values).Max(v => v.Length);
        Assert.IsTrue(longest > 100, "the catalogue has long strings the layout must wrap");
    }
}
