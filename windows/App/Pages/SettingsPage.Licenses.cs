using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>The App's local ArkTrace legal group; no Runtime read or command supplies licenses.</summary>
public sealed partial class SettingsPage
{
    private readonly TraceLicenses _traceLicenses = TraceLicenses.ForApp();
    private string _traceSection = "cache";
    private bool _licensesLoading;
    private string? _licenseRevealNote;

    private void TraceSectionBar()
    {
        var bar = new SelectorBar();
        AutomationProperties.SetAutomationId(bar, "settings.trace.sections");
        AutomationProperties.SetName(bar, S.Text(UiStrings.SettingsTabTrace));
        foreach (var (tag, key) in new[]
                 {
                     ("cache", UiStrings.WindowsSettingsTraceTitle),
                     ("licenses", UiStrings.WindowsSettingsTraceLicensesTitle),
                 })
        {
            var item = new SelectorBarItem { Text = S.Text(key), Tag = tag };
            AutomationProperties.SetAutomationId(item, "settings.trace.section." + tag);
            AutomationProperties.SetName(item, S.Text(key));
            bar.Items.Add(item);
            if (tag == _traceSection) bar.SelectedItem = item;
        }
        bar.SelectionChanged += (_, _) =>
        {
            if (bar.SelectedItem is { Tag: string tag } && tag != _traceSection)
            {
                _traceSection = tag;
                RenderTab();
            }
        };
        _tab.Children.Add(bar);
    }

    private void TraceLicenseContent()
    {
        var section = Section("settings.trace.licenses", UiStrings.WindowsSettingsTraceLicensesTitle);
        var snapshot = _traceLicenses.Snapshot;
        foreach (var (id, key, value) in new[]
                 {
                     ("product", UiStrings.WindowsSettingsTraceLicensesProduct, snapshot.Product),
                     ("notices", UiStrings.WindowsSettingsTraceLicensesNotices, snapshot.Notices),
                 })
        {
            section.Children.Add(Ui.Heading("settings.trace.licenses." + id + ".title", S.Text(key)));
            var text = value.Status switch
            {
                TraceLicenseStatus.Available => value.Text!,
                TraceLicenseStatus.Loading => S.Text(UiStrings.SettingsCommonLoading),
                _ => S.Text(UiStrings.WindowsSettingsTraceLicensesUnavailable),
            };
            section.Children.Add(Ui.Text("settings.trace.licenses." + id, text, "ArkDeckMonoStyle"));
        }
        if (snapshot.CanReveal)
        {
            section.Children.Add(Ui.Button("settings.trace.licenses.reveal", S.Text(UiStrings.WindowsSettingsTraceLicensesReveal), async (_, _) =>
            {
                // Hold the revalidated, App-local directory chain until Explorer receives the request.
                using var folder = _traceLicenses.OpenLicenseFolder();
                var opened = false;
                if (folder is not null)
                {
                    try { opened = await Windows.System.Launcher.LaunchFolderPathAsync(folder.Path); }
                    catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException) { }
                }
                _licenseRevealNote = opened ? null : S.Text(UiStrings.WindowsSettingsTraceLicensesRevealFailed);
                if (_selectedTab == "trace" && _traceSection == "licenses") RenderTab();
            }));
        }
        if (_licenseRevealNote is { } note) section.Children.Add(Ui.Text("settings.trace.licenses.revealStatus", note, "ArkDeckCaptionStyle"));
        if (snapshot.Product.Status != TraceLicenseStatus.Loading || _licensesLoading) return;
        _licensesLoading = true;
        DispatcherQueue.TryEnqueue(async () =>
        {
            await _traceLicenses.LoadAsync();
            _licensesLoading = false;
            if (_selectedTab == "trace" && _traceSection == "licenses") RenderTab();
        });
    }
}
