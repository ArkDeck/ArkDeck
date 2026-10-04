using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace ArkDeck.App.Pages;

/// <summary>Settings › General's window icon, Updates and Diagnostics (macOS
/// <c>ApplicationIconPicker</c>, <c>AutoUpdateSettingsView</c> and
/// <c>DiagnosticsSettingsPane</c>). None of them reaches the Runtime.</summary>
public sealed partial class SettingsPage
{
    private string? _updateNote;
    private SupportBundlePreview? _bundle;
    private string? _bundleExported;
    private string? _bundleNote;

    /// <summary>A folder from the picker, or the test transport's answer without a dialog.</summary>
    private static async Task<string?> PickFolderAsync()
    {
        if (App.Options.PickedFolder is { } picked) return picked;
        var picker = new FolderPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        return (await picker.PickSingleFolderAsync())?.Path;
    }

    // ---- General: the window icon (macOS ApplicationIconPicker) ----

    private void AppIcon()
    {
        var section = Section("settings.general.appIcon", UiStrings.SettingsGeneralAppIcon);
        section.Children.Add(Ui.Text("settings.general.appIcon.detail", S.Text(UiStrings.WindowsSettingsGeneralAppIconDetail), "ArkDeckCaptionStyle"));
        var choices = new RadioButtons();
        AutomationProperties.SetAutomationId(choices, "settings.general.appIcon.choices");
        AutomationProperties.SetName(choices, S.Text(UiStrings.SettingsGeneralAppIcon));
        var current = App.Preferences.Icon;
        foreach (var choice in new[] { AppIconChoice.Waveform, AppIconChoice.Keycap })
        {
            var name = S.Text(choice == AppIconChoice.Keycap ? UiStrings.SettingsGeneralAppIconKeycap : UiStrings.SettingsGeneralAppIconWaveform);
            var button = new RadioButton { Content = name, Tag = choice };
            AutomationProperties.SetAutomationId(button, "settings.general.appIcon." + AppPreferences.Name(choice));
            AutomationProperties.SetName(button, name);
            choices.Items.Add(button);
            if (choice == current) choices.SelectedItem = button;
        }
        choices.SelectionChanged += (_, _) =>
        {
            if (choices.SelectedItem is not RadioButton { Tag: AppIconChoice choice } || choice == App.Preferences.Icon) return;
            App.Preferences.Icon = choice;
            // Applies at once (macOS apply()); the packaged App's Start and taskbar tiles stay the package's.
            MainWindow.Instance.AppWindow.SetIcon(AppPreferences.IconAsset(choice));
        };
        section.Children.Add(choices);
    }

    // ---- Updates (macOS AutoUpdateSettingsView over the App Installer feed) ----

    /// <summary>The MSIX App Installer channel (docs/release/windows-update.md): Windows checks the
    /// feed, verifies the signature and installs; ArkDeck neither downloads nor replaces itself.
    /// A copy installed from the xcopy package has no update channel.</summary>
    private void Updates()
    {
        Subtitle(UiStrings.WindowsUpdatePrivacy);
        var section = Section("update", UiStrings.UpdateTitle);
        var status = Ui.Status("update.status");
        Windows.ApplicationModel.Package? package;
        try
        {
            package = Windows.ApplicationModel.Package.Current;
        }
        catch (InvalidOperationException)
        {
            package = null;
        }
        if (package is null)
        {
            Ui.Say(status, S.Text(UiStrings.WindowsUpdateNotPackaged));
            section.Children.Add(status);
            return;
        }
        Uri? feed;
        try
        {
            feed = package.GetAppInstallerInfo()?.Uri;
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            feed = null;
        }
        section.Children.Add(Ui.Fact("update.version", S.Text(UiStrings.SettingsGeneralVersion),
            $"{package.Id.Version.Major}.{package.Id.Version.Minor}.{package.Id.Version.Build}.{package.Id.Version.Revision}"));
        section.Children.Add(Ui.Fact("update.channel", S.Text(UiStrings.WindowsUpdateChannel), feed?.ToString() ?? S.Text(UiStrings.WindowsUpdateNoFeed)));
        Ui.Say(status, _updateNote ?? S.Text(UiStrings.UpdateStatusIdle));
        var available = false;
        section.Children.Add(Ui.Row(
            Ui.Button("update.checkNow", S.Text(UiStrings.UpdateCheckNow), async (_, _) =>
            {
                if (feed is null)
                {
                    Ui.Say(status, S.Text(UiStrings.WindowsUpdateNoFeed));
                    return;
                }
                Ui.Say(status, S.Text(UiStrings.UpdateStatusChecking));
                try
                {
                    var result = await package.CheckUpdateAvailabilityAsync();
                    available = result.Availability is Windows.ApplicationModel.PackageUpdateAvailability.Available or Windows.ApplicationModel.PackageUpdateAvailability.Required;
                    _updateNote = result.Availability switch
                    {
                        Windows.ApplicationModel.PackageUpdateAvailability.Available or Windows.ApplicationModel.PackageUpdateAvailability.Required => S.Text(UiStrings.UpdateStatusAvailable),
                        Windows.ApplicationModel.PackageUpdateAvailability.NoUpdates => S.Text(UiStrings.UpdateStatusCurrent),
                        _ => $"{S.Text(UiStrings.UpdateStatusFailed)} · {result.ExtendedError?.Message}",
                    };
                }
                catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
                {
                    _updateNote = $"{S.Text(UiStrings.UpdateStatusFailed)} · {error.Message}";
                }
                Ui.Say(status, _updateNote);
            }),
            Ui.Button("update.install", S.Text(UiStrings.WindowsUpdateInstall), async (_, _) =>
            {
                if (feed is null || !available)
                {
                    Ui.Say(status, S.Text(UiStrings.WindowsUpdateInstallUnavailable));
                    return;
                }
                // App Installer takes over: it shows the update, asks, verifies and installs.
                var launched = await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-appinstaller:?source=" + Uri.EscapeDataString(feed.ToString())));
                _updateNote = launched ? S.Text(UiStrings.WindowsUpdateHandedOff) : S.Text(UiStrings.UpdateStatusFailed);
                Ui.Say(status, _updateNote);
            }),
            status));
        section.Children.Add(Ui.Text("update.manualInstallDisclosure", S.Text(UiStrings.WindowsUpdateManual), "ArkDeckCaptionStyle"));
    }

    // ---- Diagnostics: the local support bundle (macOS DiagnosticsSettingsPane) ----

    private void Diagnostics()
    {
        Subtitle(UiStrings.SettingsDiagnosticsSubtitle);
        var scope = Section("settings.diagnostics.defaultScope", UiStrings.SettingsDiagnosticsDefaultScope);
        scope.Children.Add(Assurance("settings.diagnostics.metadata", UiStrings.SettingsDiagnosticsMetadata, UiStrings.WindowsSettingsDiagnosticsMetadataDetail));
        scope.Children.Add(Assurance("settings.diagnostics.redactedHDC", UiStrings.SettingsDiagnosticsRedactedHDC, UiStrings.SettingsDiagnosticsRedactedHDCDetail));
        scope.Children.Add(Assurance("settings.diagnostics.rawExcluded", UiStrings.SettingsDiagnosticsRawExcluded, UiStrings.SettingsDiagnosticsRawExcludedDetail));

        var export = Section("settings.diagnostics.export", UiStrings.SettingsDiagnosticsExport);
        var status = Ui.Status("settings.diagnostics.status");
        if (_bundleNote is { } note) Ui.Say(status, note);
        export.Children.Add(Ui.Text("settings.diagnostics.previewFirst", S.Text(UiStrings.SettingsDiagnosticsPreviewFirst)));
        export.Children.Add(Ui.Row(Ui.Button("settings.diagnostics.preview", S.Text(UiStrings.SettingsDiagnosticsChooseAndPreview), async (_, _) =>
        {
            var parent = await PickFolderAsync();
            if (parent is null) return;
            var destination = Path.Combine(parent, $"ArkDeck-Diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}");
            try
            {
                _bundle = SupportBundle.Preview(destination);
                _bundleExported = null;
                _bundleNote = null;
            }
            catch (SupportBundleException error)
            {
                _bundle = null;
                _bundleNote = $"{S.Text(UiStrings.WindowsSettingsDiagnosticsFailed)} · {error.Code}: {error.Message}";
            }
            Rerender();
        }), status));
        if (_bundle is { } preview)
        {
            export.Children.Add(Ui.Fact("settings.diagnostics.destination", S.Text(UiStrings.SettingsDiagnosticsDestination), preview.Destination));
            export.Children.Add(Ui.Fact("settings.diagnostics.size", S.Text(UiStrings.SettingsDiagnosticsSize),
                S.Format(UiStrings.WindowsBytes, preview.EstimatedBytes.ToString(System.Globalization.CultureInfo.InvariantCulture))));
            export.Children.Add(Ui.Fact("settings.diagnostics.scopeHash", S.Text(UiStrings.SettingsDiagnosticsScopeHash), preview.ScopeSha256));
            export.Children.Add(Ui.Fact("settings.diagnostics.deviceRaw", S.Text(UiStrings.SettingsDiagnosticsDeviceRaw),
                S.Text(preview.DeviceRawExcluded ? UiStrings.SettingsDiagnosticsExcluded : UiStrings.SettingsDiagnosticsNotExcluded)));
            var entries = Ui.List("settings.diagnostics.entries", S.Text(UiStrings.SettingsDiagnosticsEntries));
            foreach (var entry in preview.IncludedEntries) entries.Items.Add(Ui.Item("settings.diagnostics.entry." + entry, entry, Ui.Text("settings.diagnostics.entry." + entry + ".name", entry, "ArkDeckMonoStyle")));
            export.Children.Add(Ui.Text("settings.diagnostics.entries.title", S.Text(UiStrings.SettingsDiagnosticsEntries), "ArkDeckCaptionStyle"));
            export.Children.Add(entries);
            export.Children.Add(Ui.Text("settings.diagnostics.warning", S.Text(UiStrings.SettingsDiagnosticsWarning)));
            var actions = Ui.Row(Ui.Button("settings.diagnostics.exportNow", S.Text(UiStrings.SettingsDiagnosticsExportNow), (_, _) =>
            {
                // XPA-AC-8: enabled; a second export of one preview is refused in words.
                if (_bundleExported is not null)
                {
                    Ui.Say(status, S.Text(UiStrings.SettingsDiagnosticsExported));
                    return;
                }
                try
                {
                    _bundleExported = SupportBundle.Export(preview.Destination, preview.ScopeSha256).Destination;
                    _bundleNote = S.Text(UiStrings.SettingsDiagnosticsExported);
                }
                catch (SupportBundleException error)
                {
                    _bundleNote = $"{S.Text(UiStrings.WindowsSettingsDiagnosticsFailed)} · {error.Code}: {error.Message}";
                }
                Rerender();
            }, accent: true));
            if (_bundleExported is { } folder)
            {
                actions.Children.Add(Ui.Button("settings.diagnostics.reveal", S.Text(UiStrings.WindowsSettingsDiagnosticsReveal),
                    async (_, _) => await Windows.System.Launcher.LaunchFolderPathAsync(folder)));
            }
            export.Children.Add(actions);
        }
        export.Children.Add(Ui.Text("settings.diagnostics.noAutomaticUpload", S.Text(UiStrings.SettingsDiagnosticsNoAutomaticUpload), "ArkDeckCaptionStyle"));
    }
}
