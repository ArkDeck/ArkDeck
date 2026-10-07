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
        // Runtime remains authoritative. Only the named App.Core facades may send their
        // fixed published requests (including Device screenshot/input/recording); the UI
        // owns presentation and local liveness, never admission, capabilities or lowering.
        // Adopted Target display names remain generation-guarded host owner writes.
        var forbidden = new[] { "job.reconcile", "target.adopt", "device.display-name.set", "device.display-name.clear", "artifact.export", "agent.run", "agent.chat", "workspace.project.register", "workspace.project.update", "workspace.project.remove", "workspace.preset.register", "workspace.preset.update", "workspace.preset.remove", "runtime.tool.select", "runtime.hdc.restart" };
        // TASK-XPA-020 (sessions and Job actions): a Job's cancellation request and the Session
        // catalog's pin, unpin, cleanup and export, each preview-then-apply or generation-guarded.
        var allowed = new[] { "target.display-name.set", "target.display-name.clear", "job.cancel", "session.pin", "session.unpin",
            "session.cleanup.preview", "session.cleanup.apply", "session.export.preview", "session.export.apply",
            // TASK-XPA-020 (agents and Imports): resuming a human action with a value its
            // selection schema names, a generation-guarded abandon, and an Import's verified
            // chunked upload, abort and generation-guarded release. The App starts no execution.
            "agent.resume", "agent.abandon", "human-action.resume",
            "artifact.import.begin", "artifact.import.append", "artifact.import.commit", "artifact.import.abort", "artifact.import.release",
            // TASK-XPA-020 (Debug; delegated minor decision, pending the next rulings batch): the
            // macOS workspaces' closed typed Jobs, planned, submitted, run and cancelled through
            // the one typed request builder; which operations is pinned below.
            "job.plan", "job.submit", "job.run",
            // TASK-XPA-020 (Flash): binding the board in Loader mode to the selected Target before
            // the one submission, as the macOS Flash page does (flash.bind-current-loader).
            "flash.bind-current-loader",
            // TASK-XPA-020 (Settings; delegated minor decision, macOS parity, pending the next
            // rulings batch): the macOS SettingsApplicationFacade's generation-bound storage
            // policy and root, and RuntimeTraceCacheApplicationFacade's purge of inactive derived
            // databases, each confirmed by the person; the Runtime validates and decides.
            "runtime.storage.policy", "runtime.storage.root", "trace.cache.purge" };
        var sources = RepoPaths.AppSources("*.cs")
            .Concat(Directory.EnumerateFiles(RepoPaths.At("windows", "App.Core"), "*.cs", SearchOption.AllDirectories)
                .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")));
        foreach (var file in sources)
        {
            var text = File.ReadAllText(file);
            foreach (var write in forbidden) Assert.IsFalse(text.Contains('"' + write + '"', StringComparison.Ordinal), $"{Path.GetFileName(file)} names {write}");
            if (Path.GetFileName(file) is not ("Surfaces.cs" or "Sessions.cs" or "Settings.cs" or "Agents.cs" or "Imports.cs" or "RuntimeJobs.cs" or "Flash.cs"
                or "DeviceOperations.cs" or "DeviceKeyboardUpload.cs" or "DiagnosticCapture.cs" or "ControlChannel.cs"
                or "ScriptedDaemon.cs" or "ScriptedDaemon.Debug.cs" or "ScriptedDaemon.Flash.cs" or "ScriptedDaemon.Continue.cs" or "ScriptedDaemon.Settings.cs" or "ScriptedDaemon.DeviceScreen.cs" or "ScriptedDaemon.DiagnosticCapture.cs"))
            {
                foreach (var write in allowed) Assert.IsFalse(text.Contains('"' + write + '"', StringComparison.Ordinal), $"{Path.GetFileName(file)} names {write}");
            }
            if (Path.GetFileName(file) == "SshConnector.cs")
            {
                // Its one pipe is the remote build source's per-connection SSH_ASKPASS channel
                // (an owner-only arkdeck-askpass-<random> pipe), not the daemon's.
                StringAssert.Contains(text, "\"arkdeck-askpass-\" + Guid.NewGuid()");
                Assert.IsFalse(text.Contains("ClientKit", StringComparison.Ordinal) || text.Contains("ARKDECK_ENDPOINT", StringComparison.Ordinal));
                continue;
            }
            Assert.IsFalse(text.Contains("System.IO.Pipes", StringComparison.Ordinal), $"{Path.GetFileName(file)}: the daemon is reached only through ClientKit");
        }
    }

    /// <summary>The operations the App submits are exactly the macOS workspaces' fixed
    /// references (<c>DebugApplicationFacade</c>): every typed request is built by
    /// <see cref="RuntimeRequest.Build"/> with a literal operation, and no other code builds one.</summary>
    [TestMethod]
    public void TheAppSubmitsOnlyTheMacOsWorkspaceOperations()
    {
        var published = new HashSet<string>(StringComparer.Ordinal)
        {
            "capture.diagnostics", "debug.hap", "debug.template", "deploy.native-library.app-owned", "port-forward.create", "port-forward.remove",
            "flash.full-restore",
            // TASK-XPA-020 Device: the six existing DeviceControlFacade references;
            // request authority and capability reservation remain Runtime-owned.
            "input.tap", "input.long-press", "input.swipe", "input.keyboard", "capture.screen-sequence",
            // Overview's prepared continuation (macOS RuntimeWorkspaceContinuation): a new
            // read-only Job of one of the two published observation operations.
            "observe.device",
            // The existing macOS DiagnosticCaptureFacade's one interactive capture request.
            "capture.diagnostic-session",
        };
        var built = new List<string>();
        foreach (var file in RepoPaths.AppSources("*.cs").Concat(Directory.EnumerateFiles(RepoPaths.At("windows", "App.Core"), "*.cs", SearchOption.AllDirectories)
                     .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") && !p.Contains("Testing"))))
        {
            var text = File.ReadAllText(file);
            Assert.IsFalse(text.Contains("\"runtime-operation-request\"", StringComparison.Ordinal) && Path.GetFileName(file) != "RuntimeJobs.cs",
                $"{Path.GetFileName(file)} builds a request outside RuntimeRequest");
            foreach (System.Text.RegularExpressions.Match call in System.Text.RegularExpressions.Regex.Matches(text, @"RuntimeRequest\.Build\(\s*""[^""]+"",\s*(?<operation>[^,]+),"))
            {
                built.Add(call.Groups["operation"].Value.Trim());
            }
        }
        Assert.IsTrue(built.Count >= 5, string.Join(", ", built));
        foreach (var operation in built)
        {
            var literals = System.Text.RegularExpressions.Regex.Matches(operation, "\"([^\"]+)\"").Select(m => m.Groups[1].Value).ToArray();
            Assert.IsTrue(literals.Length > 0, $"{operation}: the operation is a literal");
            foreach (var literal in literals) Assert.IsTrue(published.Contains(literal), $"{literal} is not a macOS workspace operation");
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
                     CliCommands.AgentList, CliCommands.AgentStatus, CliCommands.AgentResume, CliCommands.AgentAbandon,
                     CliCommands.HumanActionList, CliCommands.HumanActionShow, CliCommands.HumanActionResume,
                     CliCommands.ImportList, CliCommands.ImportInspect, CliCommands.ImportRelease, CliCommands.ImportHap,
                     CliCommands.ImportFlashBundle, CliCommands.ImportWorkspacePatch, CliCommands.ImportNativeLibrary,
                     CliCommands.TraceProbe, CliCommands.TraceCapture,
                     CliCommands.UiDumpCapture, CliCommands.UiDumpComponentDetail,
                     CliCommands.JobPlan, CliCommands.JobSubmit, CliCommands.OperationList,
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
            Assert.IsTrue(new[] { "overview", "device", "history", "sessions", "agents", "imports", "debug", "flash", "trace", "traceViewer", "viewer", "diagnostics", "settings" }.Contains(snapshot.GetProperty("page").GetString()));
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
