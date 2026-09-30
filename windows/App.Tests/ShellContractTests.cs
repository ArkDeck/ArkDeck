using System.Text.Json;
using System.Text.RegularExpressions;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;

namespace ArkDeck.App.Tests;

/// <summary>Static contracts of the App sources and the semantic source (XPA-AC-8,
/// ruling 16, the TASK-XPA-007 stop condition).</summary>
[TestClass]
public sealed class ShellContractTests
{
    [TestMethod]
    public void NoControlIsDisabled()
    {
        foreach (var file in RepoPaths.AppSources("*.xaml", "*.cs"))
        {
            var text = File.ReadAllText(file);
            Assert.IsFalse(Regex.IsMatch(text, @"IsEnabled\s*(=\s*""False""|=\s*false)", RegexOptions.IgnoreCase),
                $"{Path.GetFileName(file)}: disabled placeholder controls are not allowed (XPA-AC-8)");
        }
    }

    [TestMethod]
    public void AppXamlUsesNoLiteralColours()
    {
        foreach (var file in RepoPaths.AppSources("*.xaml").Where(f => !f.EndsWith("ArkDeckTokens.xaml", StringComparison.Ordinal)))
        {
            StringAssert.DoesNotMatch(File.ReadAllText(file), new Regex("\"#[0-9A-Fa-f]{6,8}\""),
                $"{Path.GetFileName(file)}: colours come from the generated tokens");
        }
    }

    [TestMethod]
    public void ControlsUseTheProductAccentAndHighContrastKeepsSystemColours()
    {
        var tokens = File.ReadAllText(RepoPaths.At("windows", "App", "Themes", "ArkDeckTokens.xaml"));
        var light = Section(tokens, "<ResourceDictionary x:Key=\"Light\">");
        var dark = Section(tokens, "<ResourceDictionary x:Key=\"Dark\">");
        var contrast = Section(tokens, "<ResourceDictionary x:Key=\"HighContrast\">");
        StringAssert.Contains(light, "<Color x:Key=\"SystemAccentColor\">#FF006EDB</Color>");
        StringAssert.Contains(light, "<Color x:Key=\"SystemAccentColorDark1\">#FF0065CA</Color>");
        StringAssert.Contains(dark, "<Color x:Key=\"SystemAccentColor\">#FF58A6FF</Color>");
        StringAssert.Contains(dark, "<Color x:Key=\"SystemAccentColorLight2\">#FF58A6FF</Color>");
        Assert.IsFalse(contrast.Contains("SystemAccentColor", StringComparison.Ordinal), "high contrast keeps the system accent");
        Assert.IsFalse(Regex.IsMatch(contrast, "#[0-9A-F]{8}"), "high contrast uses system colours only");
    }

    [TestMethod]
    public void TheAppHoldsNoRuntimeSemantics()
    {
        // Stop condition: the App only reads (ClientKit calls through App.Core); no business
        // write method is named anywhere in the App or App.Core.
        var writes = new[] { "job.submit", "job.cancel", "job.run", "job.reconcile", "target.adopt", "target.display-name.set", "device.display-name.set" };
        var sources = RepoPaths.AppSources("*.cs")
            .Concat(Directory.EnumerateFiles(RepoPaths.At("windows", "App.Core"), "*.cs", SearchOption.AllDirectories)
                .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")));
        foreach (var file in sources)
        {
            var text = File.ReadAllText(file);
            foreach (var write in writes) Assert.IsFalse(text.Contains('"' + write + '"', StringComparison.Ordinal), $"{Path.GetFileName(file)} names {write}");
            Assert.IsFalse(text.Contains("System.IO.Pipes", StringComparison.Ordinal), $"{Path.GetFileName(file)}: the daemon is reached only through ClientKit");
        }
    }

    [TestMethod]
    public void CliCommandsAreTheCoverageTargetCommands()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("openspec", "contracts", "cli-feature-coverage.json")));
        var commands = doc.RootElement.GetProperty("entries").EnumerateArray()
            .SelectMany(e => new[] { e.TryGetProperty("targetCommand", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString()! : null }
                .Concat(e.TryGetProperty("equivalentCommands", out var eq) ? eq.EnumerateArray().Select(c => c.GetString()) : []))
            .Where(c => c is not null)
            .ToHashSet();
        foreach (var command in new[] { CliCommands.Doctor, CliCommands.RuntimeHealth, CliCommands.DeviceCandidates, CliCommands.JobList, CliCommands.JobStatus, CliCommands.JobEvents, RecoveryBannerState.DoctorCommand })
        {
            Assert.IsTrue(commands.Contains(command), command);
        }
    }

    [TestMethod]
    public void TerminalStatesAreTheRecoveryTablesTerminalClass()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "recovery", "job-state-preflight.json")));
        var terminal = doc.RootElement.GetProperty("states").EnumerateObject().Where(p => p.Value.GetString() == "terminal").Select(p => p.Name).Order().ToArray();
        CollectionAssert.AreEqual(terminal, JobSummary.TerminalStates.Order().ToArray());
    }

    [TestMethod]
    public void EverySnapshotNamesKnownKeysAndRoles()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "ui-semantics", "surfaces.json")));
        var roles = doc.RootElement.GetProperty("roles").EnumerateObject().Select(p => p.Name).ToHashSet();
        var keys = UiStrings.All.ToHashSet();
        var scenarios = ArkDeck.App.Core.Testing.ScriptedDaemon.Scenarios.ToHashSet();
        foreach (var snapshot in doc.RootElement.GetProperty("snapshots").EnumerateArray())
        {
            Assert.IsTrue(scenarios.Contains(snapshot.GetProperty("scenario").GetString()!));
            Assert.IsTrue(new[] { "overview", "device", "history" }.Contains(snapshot.GetProperty("page").GetString()));
            var ids = new HashSet<string>();
            foreach (var element in snapshot.GetProperty("elements").EnumerateArray())
            {
                var id = element.GetProperty("automationId").GetString()!;
                Assert.IsTrue(ids.Add(id), $"{snapshot.GetProperty("id")}: {id} twice");
                Assert.IsTrue(roles.Contains(element.GetProperty("role").GetString()!), id);
                Assert.IsTrue(element.GetProperty("origin").GetString() is "macos" or "windows", id);
                foreach (var reference in References(element.GetProperty("name")))
                {
                    Assert.IsTrue(keys.Contains(reference), $"{id}: unknown key {reference}");
                }
            }
        }
    }

    private static IEnumerable<string> References(JsonElement name)
    {
        foreach (var part in name.EnumerateArray())
        {
            if (part.ValueKind == JsonValueKind.String)
            {
                if (part.GetString()!.StartsWith('@')) yield return part.GetString()![1..];
                continue;
            }
            yield return part.GetProperty("format").GetString()!;
            foreach (var arg in part.GetProperty("args").EnumerateArray())
            {
                if (arg.GetString()!.StartsWith('@')) yield return arg.GetString()![1..];
            }
        }
    }

    private static string Section(string xaml, string start)
    {
        var from = xaml.IndexOf(start, StringComparison.Ordinal);
        Assert.IsTrue(from >= 0, start);
        return xaml[from..xaml.IndexOf("</ResourceDictionary>", from, StringComparison.Ordinal)];
    }
}
