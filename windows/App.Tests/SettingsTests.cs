using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.App.Core.Testing;
using ArkDeck.ClientKit.Contract;

namespace ArkDeck.App.Tests;

/// <summary>
/// The Settings reads through ClientKit. <see cref="ScriptedDaemon.Foundation"/> and
/// <see cref="ScriptedDaemon.DevelopmentRoot"/> answer as the real Windows daemon does
/// (recorded in the run record); <see cref="ScriptedDaemon.Jobs"/> stands for a daemon with
/// every Settings owner.
/// </summary>
[TestClass]
public sealed class SettingsTests
{
    private static readonly Localizer English = new(Resw.Lookup("en-US"), AppLanguage.English);

    private static SurfaceLoader Loader(string scenario) => new(ScriptedDaemon.Channel(scenario));

    [TestMethod]
    public async Task TheFoundationShowsItsRuntimeAndEveryAbsentOwnerAsItCame()
    {
        var settings = await Loader(ScriptedDaemon.Foundation).SettingsAsync();
        Assert.IsNull(settings.DaemonFailure);
        Assert.AreEqual(ControlContract.ContractIdentity, settings.Runtime.Value!.ContractIdentity);
        Assert.AreEqual(ControlContract.Methods.Count, settings.Runtime.Value.PublishedMethodCount);
        Assert.AreEqual("unavailable", settings.Checks.Value!.HdcAvailability);
        Assert.AreEqual("hdc.notConfigured", settings.Checks.Value.HdcReasonCode);
        Assert.AreEqual(3, settings.Doctor.Value!.Findings.Count);
        foreach (var (loaded, text, cli) in new (Unavailable?, string, string)[]
                 {
                     (settings.Hdc.Unavailable, "unavailable(rejected): this method is unavailable in the read-only Rust foundation", "arkdeck runtime hdc status"),
                     (settings.Tools.Unavailable, "unavailable(operationUnavailable): Bootstrap bundle list owner is not configured", "arkdeck runtime tool list"),
                     (settings.Storage.Unavailable, "unavailable(rejected): Runtime storage owners are not configured", "arkdeck runtime storage status"),
                     (settings.TraceCache.Unavailable, "unavailable(rejected): Trace cache owner is not configured", "arkdeck trace cache status"),
                     (settings.Projects.Unavailable, "unavailable(operationUnavailable): workspace project owner is unavailable", "arkdeck workspace project list"),
                 })
        {
            Assert.AreEqual(text, loaded!.ReasonText(English));
            Assert.AreEqual(cli, loaded.CliCommand);
            Assert.IsFalse(loaded.IsDaemonUnavailable);
        }
    }

    [TestMethod]
    public async Task TheDevelopmentRootListsItsProjectAndPresets()
    {
        var loader = Loader(ScriptedDaemon.DevelopmentRoot);
        var project = (await loader.SettingsAsync()).Projects.Value!.Single();
        Assert.AreEqual(ScriptedDaemon.ProjectRef, project.ProjectRef);
        Assert.AreEqual("runtimeRestartRequired", project.ConfigurationStatus);
        Assert.AreEqual("workspace_runtime_restart_required", project.ReasonCode);

        var detail = await loader.ProjectAsync(ScriptedDaemon.ProjectRef);
        var preset = detail.Presets.Value!.Single();
        Assert.AreEqual(ScriptedDaemon.PresetRef, preset.PresetRef);
        Assert.AreEqual("symbol", preset.Kind);
        Assert.AreEqual(600, preset.TimeoutSeconds);
        CollectionAssert.AreEqual(new[] { new KeyValuePair<string, string>("relativeSourceMap", "entry/build/sourceMaps.map") }, preset.Constraints.ToArray());

        var missing = await loader.ProjectAsync("project-unknown");
        Assert.AreEqual("unavailable(workspaceReferenceNotFound): workspace project is not registered", missing.Project.Unavailable!.ReasonText(English));
        Assert.AreEqual("arkdeck workspace project show --project project-unknown", missing.Project.Unavailable.CliCommand);
        Assert.AreEqual("arkdeck workspace preset list --project project-unknown", missing.Presets.Unavailable!.CliCommand);
    }

    [TestMethod]
    public async Task EveryOwnerAnsweringIsShownAsTheRuntimeMeasuredIt()
    {
        var settings = await Loader(ScriptedDaemon.Jobs).SettingsAsync();
        Assert.AreEqual("available", settings.Hdc.Value!.Availability);
        Assert.AreEqual(@"C:\Tools\hdc\hdc.exe", settings.Hdc.Value.ExecutablePath);
        var tool = settings.Tools.Value!.Single();
        Assert.AreEqual("tool-hdc-3.2.0f", tool.ToolRef);
        Assert.AreEqual("true", tool.Selected);
        Assert.AreEqual("1073741824", settings.Storage.Value!.ArtifactUsedBytes);
        Assert.AreEqual("30", settings.Storage.Value.RetentionDays);
        Assert.AreEqual(2, settings.TraceCache.Value!.EntryCount);
        Assert.AreEqual("inactiveDerivedEntries", settings.TraceCache.Value.PurgeScope);
    }

    [TestMethod]
    public async Task NothingAnsweringReachesTheBanner()
    {
        var settings = await Loader(ScriptedDaemon.Unavailable).SettingsAsync();
        Assert.IsNotNull(settings.DaemonFailure);
        Assert.AreEqual(Unavailable.DaemonUnavailableCode, settings.Projects.Unavailable!.ReasonCode);
        Assert.IsNotNull((await Loader(ScriptedDaemon.Unavailable).ProjectAsync(ScriptedDaemon.ProjectRef)).DaemonFailure);
    }
}
