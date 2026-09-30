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
    public void HighContrastDefinesEveryTokenWithSystemColours()
    {
        // The high-contrast themes select the HighContrast dictionary: it must define every
        // token the light and dark themes define, and only as a system colour.
        var tokens = File.ReadAllText(RepoPaths.At("windows", "App", "Themes", "ArkDeckTokens.xaml"));
        var keys = new Regex("x:Key=\"(ArkDeck[A-Za-z0-9]+)\"");
        var light = keys.Matches(Section(tokens, "<ResourceDictionary x:Key=\"Light\">")).Select(m => m.Groups[1].Value).ToHashSet();
        var dark = keys.Matches(Section(tokens, "<ResourceDictionary x:Key=\"Dark\">")).Select(m => m.Groups[1].Value).ToHashSet();
        var contrast = Section(tokens, "<ResourceDictionary x:Key=\"HighContrast\">");
        var defined = keys.Matches(contrast).Select(m => m.Groups[1].Value).ToHashSet();
        Assert.IsTrue(light.Count > 10);
        CollectionAssert.AreEquivalent(light.Order().ToArray(), dark.Order().ToArray());
        var missing = light.Except(defined).ToArray();
        Assert.AreEqual(0, missing.Length, "no high-contrast value for " + string.Join(", ", missing));
        foreach (var line in contrast.Split('\n').Where(l => l.Contains("x:Key=\"ArkDeck", StringComparison.Ordinal)))
        {
            StringAssert.Contains(line, "SystemColor", line.Trim());
        }
    }

    [TestMethod]
    public void TheAppHoldsNoRuntimeSemantics()
    {
        // Stop condition: the App reads through ClientKit calls in App.Core and derives no
        // state. Its one write is the Runtime-owned display name of an adopted Target
        // (TASK-XPA-020, app.device.rename: host state, generation-guarded, the CLI's
        // `target display-name set|clear`), named only by the loader; no Job, adoption,
        // device or other business write is named anywhere in the App or App.Core.
        var forbidden = new[] { "job.submit", "job.run", "job.reconcile", "target.adopt", "device.display-name.set", "device.display-name.clear", "artifact.export", "artifact.import.begin", "trace.cache.purge", "workspace.project.register", "workspace.project.update", "workspace.project.remove", "workspace.preset.register", "workspace.preset.update", "workspace.preset.remove", "runtime.storage.policy", "runtime.storage.root", "runtime.tool.select", "runtime.hdc.restart" };
        // TASK-XPA-020 (sessions and Job actions): a Job's cancellation request and the Session
        // catalog's pin, unpin, cleanup and export, each preview-then-apply or generation-guarded.
        var allowed = new[] { "target.display-name.set", "target.display-name.clear", "job.cancel", "session.pin", "session.unpin",
            "session.cleanup.preview", "session.cleanup.apply", "session.export.preview", "session.export.apply" };
        var sources = RepoPaths.AppSources("*.cs")
            .Concat(Directory.EnumerateFiles(RepoPaths.At("windows", "App.Core"), "*.cs", SearchOption.AllDirectories)
                .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")));
        foreach (var file in sources)
        {
            var text = File.ReadAllText(file);
            foreach (var write in forbidden) Assert.IsFalse(text.Contains('"' + write + '"', StringComparison.Ordinal), $"{Path.GetFileName(file)} names {write}");
            if (Path.GetFileName(file) is not ("Surfaces.cs" or "Sessions.cs" or "ScriptedDaemon.cs"))
            {
                foreach (var write in allowed) Assert.IsFalse(text.Contains('"' + write + '"', StringComparison.Ordinal), $"{Path.GetFileName(file)} names {write}");
            }
            Assert.IsFalse(text.Contains("System.IO.Pipes", StringComparison.Ordinal), $"{Path.GetFileName(file)}: the daemon is reached only through ClientKit");
        }
    }

    [TestMethod]
    public void EveryBuildRunsTheTrimAnalyzer()
    {
        // The release candidate publishes the App trimmed, which PR builds never do: the trim
        // analyzer runs on every build instead (warnings are errors), so code the trimmer cannot
        // keep fails the windows lane, not first the RC (IL2026 in FocusWalk.cs, #2404).
        foreach (var project in new[] { RepoPaths.At("windows", "App", "ArkDeck.App.csproj"), RepoPaths.At("windows", "App.Core", "ArkDeck.App.Core.csproj") })
        {
            StringAssert.Contains(File.ReadAllText(project), "<EnableTrimAnalyzer>true</EnableTrimAnalyzer>", project);
        }
        StringAssert.Contains(File.ReadAllText(RepoPaths.At("windows", "ClientKit", "ArkDeck.ClientKit.csproj")), "<IsTrimmable>true</IsTrimmable>");
        StringAssert.Contains(File.ReadAllText(RepoPaths.At("windows", "Directory.Build.props")), "<TreatWarningsAsErrors>true</TreatWarningsAsErrors>");
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
        foreach (var command in new[]
                 {
                     CliCommands.Doctor, CliCommands.RuntimeHealth, CliCommands.DeviceCandidates, CliCommands.JobList, CliCommands.JobStatus, CliCommands.JobEvents,
                     CliCommands.TargetList, CliCommands.TargetShow, CliCommands.TargetAvailability, CliCommands.TargetDisplayNameSet, CliCommands.TargetDisplayNameClear,
                     CliCommands.ArtifactList, CliCommands.ArtifactRead, CliCommands.TraceInspect, RecoveryBannerState.DoctorCommand,
                     CliCommands.RuntimeServiceStatus, CliCommands.RuntimeServiceVerify, CliCommands.RuntimeServiceRestart, CliCommands.RuntimeSigningStatus,
                     CliCommands.RuntimeHdcStatus, CliCommands.RuntimeToolList, CliCommands.RuntimeStorageStatus, CliCommands.TraceCacheStatus,
                     CliCommands.WorkspaceProjectList, CliCommands.WorkspaceProjectRegister, CliCommands.WorkspaceProjectShow, CliCommands.WorkspacePresetList,
                     CliCommands.JobCancel, CliCommands.JobResult, CliCommands.JobEvidence, CliCommands.SessionList, CliCommands.SessionShow,
                     CliCommands.SessionPin, CliCommands.SessionUnpin, CliCommands.SessionCleanupPreview, CliCommands.SessionCleanupApply,
                     CliCommands.SessionExportPreview, CliCommands.SessionExportApply,
                 })
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
            Assert.IsTrue(new[] { "overview", "device", "history", "sessions", "settings" }.Contains(snapshot.GetProperty("page").GetString()));
            if (snapshot.TryGetProperty("steps", out var steps))
            {
                foreach (var step in steps.EnumerateArray())
                {
                    var action = step.EnumerateObject().Single();
                    Assert.IsTrue(action.Name is "select" or "invoke", $"{snapshot.GetProperty("id")}: step {action.Name}");
                }
            }
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
