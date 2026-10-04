using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// Settings, with the macOS Settings tabs the Windows daemon can speak to (General,
/// Toolchains, Storage, Trace) and two Windows tabs (Runtime, Workspace). Everything is read:
/// <c>health</c>, <c>doctor</c>, <c>runtime.hdc.status</c>, <c>runtime.tool.list</c>,
/// <c>runtime.storage.status</c>, <c>trace.cache.status</c>, <c>workspace.project.list|show</c>
/// and <c>workspace.preset.list</c>, each shown as it came or as
/// <c>unavailable(reasonCode)</c> with its CLI command. Changing a setting — the Runtime
/// service's verify and restart, signing, storage policy, projects and presets — is the CLI's,
/// and each tab names the command.
/// </summary>
public sealed partial class SettingsPage : SurfacePage<SettingsState>
{
    private static readonly (string Tag, string Key)[] Tabs =
    [
        ("general", UiStrings.SettingsTabGeneral),
        ("runtime", UiStrings.WindowsSettingsTabRuntime),
        ("toolchains", UiStrings.SettingsTabToolchains),
        ("remoteSources", UiStrings.SettingsTabRemoteSources),
        ("storage", UiStrings.SettingsTabStorage),
        ("trace", UiStrings.SettingsTabTrace),
        ("workspace", UiStrings.WindowsSettingsTabWorkspace),
    ];

    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _tab = new() { Spacing = 14 };
    private SettingsState? _state;
    private string _selectedTab = "general";
    private string? _selectedProject;
    private StackPanel _projectDetail = new() { Spacing = 8 };

    public SettingsPage()
        : base("settings", "settings.title", UiStrings.WindowsNavigationSettings,
            "settings.refresh", UiStrings.SettingsCommonRefresh, "settings.loading", UiStrings.SettingsCommonLoading)
    {
    }

    /// <summary>The macOS Settings tab bar as a Fluent SelectorBar, on the tab last chosen.</summary>
    private SelectorBar TabBar()
    {
        var bar = new SelectorBar();
        AutomationProperties.SetAutomationId(bar, "settings.tabs");
        AutomationProperties.SetName(bar, S.Text(UiStrings.WindowsNavigationSettings));
        foreach (var (tag, key) in Tabs)
        {
            var item = new SelectorBarItem { Text = S.Text(key), Tag = tag };
            AutomationProperties.SetAutomationId(item, "settings.tab." + tag);
            AutomationProperties.SetName(item, S.Text(key));
            bar.Items.Add(item);
            if (tag == _selectedTab) bar.SelectedItem = item;
        }
        bar.SelectionChanged += (_, _) =>
        {
            if (bar.SelectedItem is { Tag: string tag } && tag != _selectedTab)
            {
                _selectedTab = tag;
                RenderTab();
            }
        };
        return bar;
    }

    protected override Task<SettingsState> LoadAsync() => App.Loader.SettingsAsync();

    /// <summary>The tab the next render shows.</summary>
    public void ShowTab(string tab) => _selectedTab = Tabs.Any(t => t.Tag == tab) ? tab : _selectedTab;

    protected override void Render(SettingsState state, StackPanel body)
    {
        _state = state;
        _tab = new StackPanel { Spacing = 14 };
        body.Children.Add(TabBar());
        body.Children.Add(_tab);
        RenderTab();
    }

    private void RenderTab()
    {
        _tab.Children.Clear();
        if (_state is not { } state) return;
        switch (_selectedTab)
        {
            case "runtime": Runtime(state); break;
            case "toolchains": Toolchains(state); break;
            case "remoteSources": RemoteSourcesTab(); break;
            case "storage": Storage(state); break;
            case "trace": Trace(state); break;
            case "workspace": Workspace(state); break;
            default: General(); break;
        }
    }

    private void Subtitle(string key) => _tab.Children.Add(Ui.Text("settings.subtitle", S.Text(key), "ArkDeckCaptionStyle"));

    private StackPanel Section(string id, string titleKey)
    {
        var panel = Ui.Stack(6, Ui.Heading(id + ".title", S.Text(titleKey)));
        _tab.Children.Add(Ui.Card(panel, id));
        return panel;
    }

    private void General()
    {
        Subtitle(UiStrings.SettingsGeneralSubtitle);
        var build = Section("settings.general.build", UiStrings.SettingsGeneralBuild);
        var version = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                      ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "—";
        build.Children.Add(Ui.Fact("settings.general.app", S.Text(UiStrings.SettingsGeneralApp), S.Text(UiStrings.AppShellTitle)));
        build.Children.Add(Ui.Fact("settings.general.version", S.Text(UiStrings.SettingsGeneralVersion), version));
        build.Children.Add(Ui.Fact("settings.general.platform", S.Text(UiStrings.SettingsGeneralPlatform), RuntimeInformation.OSDescription));
        build.Children.Add(Ui.Fact("settings.general.architecture", S.Text(UiStrings.SettingsGeneralArchitecture),
            RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()));
        var privacy = Section("settings.general.privacy", UiStrings.SettingsGeneralPrivacy);
        privacy.Children.Add(Assurance("settings.general.localFirst", UiStrings.SettingsGeneralLocalFirst, UiStrings.SettingsGeneralLocalFirstDetail));
        privacy.Children.Add(Assurance("settings.general.noUpload", UiStrings.SettingsGeneralNoUpload, UiStrings.SettingsGeneralNoUploadDetail));
    }

    private static StackPanel Assurance(string id, string titleKey, string detailKey) =>
        Ui.Stack(2, Ui.Text(id, S.Text(titleKey), "ArkDeckSectionTitleStyle"), Ui.Text(id + ".detail", S.Text(detailKey), "ArkDeckCaptionStyle"));

    private void Runtime(SettingsState state)
    {
        Subtitle(UiStrings.WindowsSettingsRuntimeSubtitle);
        var identity = Section("settings.runtime.identity", UiStrings.WindowsSettingsRuntimeIdentity);
        if (state.Runtime.Unavailable is { } why)
        {
            identity.Children.Add(Ui.UnavailableNotice("settings.runtime.unavailable", UiStrings.WindowsOverviewDoctorUnavailable, why));
        }
        else
        {
            var runtime = state.Runtime.Value!;
            identity.Children.Add(Ui.Fact("settings.runtime.status", S.Text(UiStrings.WindowsSettingsRuntimeStatus), runtime.Status));
            identity.Children.Add(Ui.Fact("settings.runtime.protocol", S.Text(UiStrings.WindowsOverviewRuntimeProtocol), runtime.ProtocolVersion));
            identity.Children.Add(Ui.Fact("settings.runtime.contract", S.Text(UiStrings.WindowsOverviewRuntimeContract), runtime.ContractIdentity));
            identity.Children.Add(Ui.Fact("settings.runtime.catalog", S.Text(UiStrings.WindowsSettingsRuntimeCatalog), runtime.CatalogDigest));
            identity.Children.Add(Ui.Fact("settings.runtime.methods", S.Text(UiStrings.WindowsSettingsRuntimeMethods),
                runtime.PublishedMethodCount.ToString(CultureInfo.InvariantCulture)));
            identity.Children.Add(Ui.Fact("settings.runtime.providers", S.Text(UiStrings.WindowsSettingsRuntimeProviders),
                runtime.Providers.Count == 0 ? S.Text(UiStrings.WindowsSettingsRuntimeNone) : string.Join(", ", runtime.Providers)));
        }

        var checks = Section("settings.runtime.checks", UiStrings.WindowsSettingsRuntimeChecks);
        if (state.Checks.Unavailable is { } checksWhy)
        {
            checks.Children.Add(Ui.UnavailableNotice("settings.runtime.checks.unavailable", UiStrings.WindowsOverviewDoctorUnavailable, checksWhy));
        }
        else
        {
            var c = state.Checks.Value!;
            var overallKey = "windows.overview.doctor.overall." + c.Overall;
            checks.Children.Add(Ui.Text("settings.runtime.overall",
                S.Format(UiStrings.WindowsOverviewDoctorOverall, UiStrings.All.Contains(overallKey) ? S.Text(overallKey) : c.Overall), "ArkDeckSectionTitleStyle"));
            checks.Children.Add(Ui.Fact("settings.runtime.operations", S.Text(UiStrings.WindowsOverviewRuntimeOperations),
                S.Format(UiStrings.WindowsOverviewRuntimeOperationsValue, c.AvailableOperations, c.Operations)));
            checks.Children.Add(Ui.Fact("settings.runtime.check.hdc", S.Text(UiStrings.WindowsSettingsRuntimeCheckHdc),
                $"{c.HdcAvailability} ({c.HdcReasonCode}) · {c.HdcOwnership} · {c.HdcServerHealth}"));
            checks.Children.Add(Ui.Fact("settings.runtime.check.targets", S.Text(UiStrings.WindowsSettingsRuntimeCheckTargets),
                !c.TargetConfigured ? S.Text(UiStrings.WindowsSettingsRuntimeNotConfigured)
                : c.AdoptedTargetCount is { } adopted ? S.Format(UiStrings.WindowsSettingsRuntimeAdoptedCount, adopted)
                : S.Text(UiStrings.WindowsSettingsRuntimeConfigured)));
            checks.Children.Add(Ui.Fact("settings.runtime.check.recovery", S.Text(UiStrings.WindowsSettingsRuntimeCheckRecovery),
                !c.RecoveryChecked ? S.Text(UiStrings.WindowsSettingsRuntimeNotChecked)
                : S.Format(UiStrings.WindowsSettingsRuntimeOutstanding, c.OutstandingCleanupCount ?? 0)));
            checks.Children.Add(Ui.Fact("settings.runtime.check.sessionOutput", S.Text(UiStrings.WindowsSettingsRuntimeCheckSessionOutput),
                $"{c.SessionOutputAvailability} ({c.SessionOutputReasonCode})"));
            checks.Children.Add(Ui.Fact("settings.runtime.check.artifacts", S.Text(UiStrings.WindowsSettingsRuntimeCheckArtifacts),
                S.Text(c.RuntimeArtifactsConfigured ? UiStrings.WindowsSettingsRuntimeConfigured : UiStrings.WindowsSettingsRuntimeNotConfigured)));
            if (state.Doctor.Value is { Findings.Count: > 0 } doctor)
            {
                var findings = Ui.List("settings.runtime.findings", S.Text(UiStrings.WindowsOverviewDoctorTitle));
                foreach (var finding in doctor.Findings)
                {
                    var severityKey = "windows.overview.doctor.severity." + finding.Severity;
                    var severity = UiStrings.All.Contains(severityKey) ? S.Text(severityKey) : finding.Severity;
                    var text = $"{severity}: {finding.Summary} ({finding.Code})";
                    findings.Items.Add(Ui.Item("settings.runtime.finding." + finding.Code, text,
                        Ui.Text($"settings.runtime.finding.{finding.Code}.text", text)));
                }
                checks.Children.Add(findings);
            }
        }

        var service = Section("settings.runtime.service", UiStrings.WindowsSettingsServiceTitle);
        service.Children.Add(Ui.Text("settings.runtime.service.detail", S.Text(UiStrings.WindowsSettingsServiceDetail)));
        foreach (var (id, command) in new[]
                 {
                     ("status", CliCommands.RuntimeServiceStatus),
                     ("verify", CliCommands.RuntimeServiceVerify),
                     ("restart", CliCommands.RuntimeServiceRestart),
                 })
        {
            service.Children.Add(CliRow("settings.runtime.service." + id, command));
        }
        var signing = Section("settings.runtime.signing", UiStrings.WindowsSettingsSigningTitle);
        signing.Children.Add(Ui.Text("settings.runtime.signing.detail", S.Text(UiStrings.WindowsSettingsSigningDetail)));
        signing.Children.Add(CliRow("settings.runtime.signing.status", CliCommands.RuntimeSigningStatus));
    }

    /// <summary>A CLI command and a working copy action ("CLI: …", Copy CLI command).</summary>
    private static FlowPanel CliRow(string id, string command) =>
        Ui.Row(Ui.Text(id + ".cli", S.Format(UiStrings.WindowsCliEquivalent, command), "ArkDeckMonoStyle"), Ui.CopyCli(id + ".copyCli", command));

    private void Toolchains(SettingsState state)
    {
        Subtitle(UiStrings.SettingsToolchainsSubtitle);
        var hdc = Section("settings.toolchains.hdc", UiStrings.SettingsToolchainsHdc);
        if (state.Hdc.Unavailable is { } why)
        {
            hdc.Children.Add(Ui.UnavailableNotice("settings.toolchains.hdc.unavailable", UiStrings.WindowsSettingsHdcUnavailable, why));
        }
        else
        {
            var status = state.Hdc.Value!;
            hdc.Children.Add(Ui.Fact("settings.toolchains.health", S.Text(UiStrings.WindowsSettingsRuntimeStatus),
                $"{status.Availability} ({status.ReasonCode}) · {status.ServerHealth}"));
            foreach (var (id, key, value) in new (string, string, string?)[]
                     {
                         ("settings.toolchains.path", UiStrings.SettingsToolchainsPath, status.ExecutablePath),
                         ("settings.toolchains.sha256", UiStrings.SettingsToolchainsSha256, status.ExecutableSha256),
                         ("settings.toolchains.source", UiStrings.SettingsToolchainsSource, status.ExecutableSource),
                         ("settings.toolchains.clientVersion", UiStrings.SettingsToolchainsClientVersion, status.ClientVersion),
                         ("settings.toolchains.daemonVersion", UiStrings.SettingsToolchainsDaemonVersion, status.DaemonVersion),
                         ("settings.toolchains.endpoint", UiStrings.SettingsToolchainsEndpoint, status.Endpoint),
                     })
            {
                if (value is not null) hdc.Children.Add(Ui.Fact(id, S.Text(key), value));
            }
        }
        var tools = Section("settings.toolchains.tools", UiStrings.WindowsSettingsToolsTitle);
        if (state.Tools.Unavailable is { } toolsWhy)
        {
            tools.Children.Add(Ui.UnavailableNotice("settings.toolchains.tools.unavailable", UiStrings.WindowsSettingsToolsUnavailable, toolsWhy));
        }
        else if (state.Tools.Value!.Count == 0)
        {
            tools.Children.Add(Ui.Text("settings.toolchains.tools.empty", S.Text(UiStrings.WindowsSettingsToolsEmpty), "ArkDeckCaptionStyle"));
        }
        else
        {
            var list = Ui.List("settings.toolchains.tools.list", S.Text(UiStrings.WindowsSettingsToolsTitle));
            foreach (var tool in state.Tools.Value!)
            {
                var text = $"{tool.ToolRef} · {tool.Kind} · {tool.Platform} · {tool.State}";
                list.Items.Add(Ui.Item("settings.toolchains.tool." + tool.ToolRef, text, Ui.Text($"settings.toolchains.tool.{tool.ToolRef}.text", text, "ArkDeckMonoStyle")));
            }
            tools.Children.Add(list);
        }
        tools.Children.Add(CliRow("settings.toolchains.signing", CliCommands.RuntimeSigningStatus));
    }

    private void Storage(SettingsState state)
    {
        Subtitle(UiStrings.SettingsStorageSubtitle);
        var runtime = Section("settings.storage.runtimeUsage", UiStrings.SettingsStorageRuntimeUsage);
        if (state.Storage.Unavailable is { } why)
        {
            runtime.Children.Add(Ui.UnavailableNotice("settings.storage.unavailable", UiStrings.SettingsStorageRuntimeUnavailable, why));
            return;
        }
        var s = state.Storage.Value!;
        runtime.Children.Add(Ui.Fact("settings.storage.runtime.used", S.Text(UiStrings.SettingsStorageCurrentUsage), S.Format(UiStrings.WindowsBytes, s.ArtifactUsedBytes)));
        runtime.Children.Add(Ui.Fact("settings.storage.runtime.remaining", S.Text(UiStrings.SettingsStorageRemaining), S.Format(UiStrings.WindowsBytes, s.ArtifactRemainingBytes)));
        runtime.Children.Add(Ui.Fact("settings.storage.runtime.total", S.Text(UiStrings.SettingsStorageRuntimeTotal), S.Format(UiStrings.WindowsBytes, s.ArtifactTotalBytes)));
        runtime.Children.Add(Ui.Text("settings.storage.runtimeUsage.detail", S.Text(UiStrings.SettingsStorageRuntimeUsageDetail), "ArkDeckCaptionStyle"));
        var session = Section("settings.storage.sessionUsage", UiStrings.SettingsStorageSessionUsage);
        session.Children.Add(Ui.Fact("settings.storage.root", S.Text(UiStrings.SettingsStorageRoot), s.SessionRootPath));
        session.Children.Add(Ui.Fact("settings.storage.quota", S.Text(UiStrings.SettingsStorageQuota), S.Format(UiStrings.WindowsBytes, s.QuotaBytes)));
        session.Children.Add(Ui.Fact("settings.storage.margin", S.Text(UiStrings.SettingsStorageMargin), S.Format(UiStrings.WindowsBytes, s.SafetyMarginBytes)));
        session.Children.Add(Ui.Fact("settings.storage.retention", S.Text(UiStrings.SettingsStorageRetention), s.RetentionDays));
        session.Children.Add(Ui.Fact("settings.storage.session.used", S.Text(UiStrings.SettingsStorageCurrentUsage), S.Format(UiStrings.WindowsBytes, s.SessionUsedBytes)));
        session.Children.Add(Ui.Fact("settings.storage.pinned", S.Text(UiStrings.SettingsStoragePinned), $"{s.PinnedSessionCount} · {S.Format(UiStrings.WindowsBytes, s.PinnedBytes)}"));
        if (s.MeasurementIncomplete) session.Children.Add(Ui.Text("settings.storage.measurementUnavailable", S.Text(UiStrings.SettingsStorageMeasurementUnavailable), "ArkDeckCaptionStyle"));
        session.Children.Add(Ui.Text("settings.storage.sessionUsage.detail", S.Text(UiStrings.SettingsStorageSessionUsageDetail), "ArkDeckCaptionStyle"));
        session.Children.Add(Ui.Text("settings.storage.pinGuarantee", S.Text(UiStrings.SettingsStoragePinGuarantee), "ArkDeckCaptionStyle"));
    }

    private void Trace(SettingsState state)
    {
        Subtitle(UiStrings.WindowsSettingsTraceSubtitle);
        var cache = Section("settings.trace.cache", UiStrings.WindowsSettingsTraceTitle);
        if (state.TraceCache.Unavailable is { } why)
        {
            cache.Children.Add(Ui.UnavailableNotice("settings.trace.unavailable", UiStrings.WindowsSettingsTraceUnavailable, why));
            return;
        }
        var c = state.TraceCache.Value!;
        cache.Children.Add(Ui.Text("settings.trace.entries", S.Format(UiStrings.WindowsSettingsTraceEntries, c.EntryCount, c.ActiveEntryCount, c.InactiveEntryCount)));
        cache.Children.Add(Ui.Fact("settings.trace.bytes", S.Text(UiStrings.SettingsStorageCurrentUsage), S.Format(UiStrings.WindowsBytes, c.TotalByteCount)));
        cache.Children.Add(Ui.Fact("settings.trace.scope", S.Text(UiStrings.WindowsSettingsTraceScope), c.PurgeScope));
    }

    private void Workspace(SettingsState state)
    {
        Subtitle(UiStrings.WindowsSettingsWorkspaceSubtitle);
        var projects = Section("settings.workspace.projects", UiStrings.WindowsSettingsWorkspaceProjects);
        _projectDetail = new StackPanel { Spacing = 8 };
        if (state.Projects.Unavailable is { } why)
        {
            projects.Children.Add(Ui.UnavailableNotice("settings.workspace.unavailable", UiStrings.WindowsSettingsWorkspaceUnavailable, why));
            return;
        }
        if (state.Projects.Value!.Count == 0)
        {
            projects.Children.Add(Ui.Text("settings.workspace.empty", S.Text(UiStrings.WindowsSettingsWorkspaceEmpty), "ArkDeckCaptionStyle"));
            projects.Children.Add(CliRow("settings.workspace.register", CliCommands.WorkspaceProjectRegister));
            return;
        }
        var list = Ui.Choice("settings.workspace.list", S.Text(UiStrings.WindowsSettingsWorkspaceProjects));
        foreach (var project in state.Projects.Value!)
        {
            var text = $"{project.ProjectRef} · {project.Kind} · {project.Availability}";
            var row = Ui.Stack(2,
                Ui.Text($"settings.workspace.project.{project.ProjectRef}.title", project.ProjectRef, "ArkDeckSectionTitleStyle"),
                Ui.Text($"settings.workspace.project.{project.ProjectRef}.state",
                    $"{project.Kind} · {project.Availability} · {project.ConfigurationStatus}", "ArkDeckCaptionStyle"));
            var item = Ui.Item("settings.workspace.project." + project.ProjectRef, text, row);
            item.Tag = project.ProjectRef;
            list.Items.Add(item);
            if (project.ProjectRef == _selectedProject) list.SelectedItem = item;
        }
        list.SelectionChanged += async (_, e) =>
        {
            if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string reference }) await ShowProjectAsync(reference);
        };
        projects.Children.Add(list);
        projects.Children.Add(_projectDetail);
        if (_selectedProject is { } selected && state.Projects.Value!.Any(p => p.ProjectRef == selected))
        {
            DispatcherQueue.TryEnqueue(async () => await ShowProjectAsync(selected));
        }
        else
        {
            _selectedProject = null;
            _projectDetail.Children.Add(Ui.Text("settings.workspace.select", S.Text(UiStrings.WindowsSettingsWorkspaceSelect), "ArkDeckCaptionStyle"));
        }
    }

    private async Task ShowProjectAsync(string projectRef)
    {
        _selectedProject = projectRef;
        _projectDetail.Children.Clear();
        _projectDetail.Children.Add(Ui.Progress("settings.workspace.loading", S.Text(UiStrings.SettingsCommonLoading)));
        var state = await Task.Run(() => App.Loader.ProjectAsync(projectRef));
        if (_selectedProject != projectRef) return;
        MainWindow.Instance.Report(state);
        _projectDetail.Children.Clear();
        if (state.Project.Unavailable is { } why)
        {
            _projectDetail.Children.Add(Ui.UnavailableNotice("settings.workspace.detail.unavailable", UiStrings.WindowsSettingsWorkspaceDetailUnavailable, why));
            return;
        }
        var project = state.Project.Value!;
        _projectDetail.Children.Add(Ui.Heading("settings.workspace.detail.title", project.ProjectRef, AutomationHeadingLevel.Level3));
        foreach (var (id, key, value) in new (string, string, string?)[]
                 {
                     ("settings.workspace.detail.kind", UiStrings.WindowsSettingsWorkspaceKind, project.Kind),
                     ("settings.workspace.detail.availability", UiStrings.WindowsSettingsWorkspaceAvailability,
                         project.ReasonCode is null ? project.Availability : $"{project.Availability} ({project.ReasonCode})"),
                     ("settings.workspace.detail.configuration", UiStrings.WindowsSettingsWorkspaceConfiguration, project.ConfigurationStatus),
                     ("settings.workspace.detail.generation", UiStrings.WindowsSettingsWorkspaceGeneration, project.Generation),
                     ("settings.workspace.detail.registered", UiStrings.WindowsSettingsWorkspaceRegistered, project.RegisteredAtUtc),
                 })
        {
            if (value is not null) _projectDetail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        if (project.Reason is { } reason) _projectDetail.Children.Add(Ui.Text("settings.workspace.detail.reason", reason, "ArkDeckCaptionStyle"));
        _projectDetail.Children.Add(Ui.Heading("settings.workspace.presets.title", S.Text(UiStrings.WindowsSettingsWorkspacePresets), AutomationHeadingLevel.Level3));
        if (state.Presets.Unavailable is { } presetsWhy)
        {
            _projectDetail.Children.Add(Ui.UnavailableNotice("settings.workspace.presets.unavailable", UiStrings.WindowsSettingsWorkspacePresetsUnavailable, presetsWhy));
        }
        else if (state.Presets.Value!.Count == 0)
        {
            _projectDetail.Children.Add(Ui.Text("settings.workspace.presets.empty", S.Text(UiStrings.WindowsSettingsWorkspacePresetsEmpty), "ArkDeckCaptionStyle"));
        }
        else
        {
            var presets = Ui.List("settings.workspace.presets", S.Text(UiStrings.WindowsSettingsWorkspacePresets));
            foreach (var preset in state.Presets.Value!)
            {
                var text = $"{preset.PresetRef} · {preset.Kind} · {preset.TemplateRef} · {S.Format(UiStrings.WindowsSettingsWorkspaceTimeout, preset.TimeoutSeconds)} · {preset.ConfigurationStatus}";
                var content = Ui.Stack(2, Ui.Text($"settings.workspace.preset.{preset.PresetRef}.text", text, "ArkDeckMonoStyle"));
                foreach (var (name, value) in preset.Constraints)
                {
                    content.Children.Add(Ui.Text($"settings.workspace.preset.{preset.PresetRef}.{name}", $"{name}: {value}", "ArkDeckCaptionStyle"));
                }
                presets.Items.Add(Ui.Item("settings.workspace.preset." + preset.PresetRef, text, content));
            }
            _projectDetail.Children.Add(presets);
        }
        _projectDetail.Children.Add(CliRow("settings.workspace.presets.cli", CliCommands.ForProject(CliCommands.WorkspacePresetList, projectRef)));
    }
}
