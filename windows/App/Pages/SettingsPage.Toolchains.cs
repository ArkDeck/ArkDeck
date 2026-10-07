using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;

namespace ArkDeck.App.Pages;

public sealed partial class SettingsPage
{
    // This is the Runtime's Boolean fact, not a GUI choice or a selection action.
    private string ToolInventoryText(ToolSummary tool) =>
        $"{tool.ToolRef} · {tool.Kind} · {tool.Platform} · {tool.State} · {S.Text(UiStrings.WindowsSettingsToolsSelected)}: {tool.Selected}";

    private void BundleInventory(SettingsState state)
    {
        var section = Section("settings.toolchains.bundles", UiStrings.WindowsSettingsBundlesTitle);
        if (state.Bundles.Unavailable is { } why)
        {
            section.Children.Add(Ui.UnavailableNotice("settings.toolchains.bundles.unavailable", UiStrings.WindowsSettingsBundlesUnavailable, why));
        }
        else if (state.Bundles.Value!.Count == 0)
        {
            section.Children.Add(Ui.Text("settings.toolchains.bundles.empty", S.Text(UiStrings.WindowsSettingsBundlesEmpty), "ArkDeckCaptionStyle"));
        }
        else
        {
            var list = Ui.List("settings.toolchains.bundles.list", S.Text(UiStrings.WindowsSettingsBundlesTitle));
            foreach (var bundle in state.Bundles.Value!)
            {
                var id = "settings.toolchains.bundle." + bundle.BundleRef;
                var text = $"{bundle.BundleRef} · {bundle.Kind} · {bundle.Platform} · {bundle.Version} · {bundle.State}";
                var trust = bundle.Trust;
                list.Items.Add(Ui.Item(id, text, Ui.Stack(4,
                    Ui.Text(id + ".text", text, "ArkDeckMonoStyle"),
                    Ui.Fact(id + ".digest", S.Text(UiStrings.SettingsToolchainsSha256), bundle.ContentDigest),
                    Ui.Fact(id + ".bytes", S.Text(UiStrings.WindowsSettingsBundlesBytes), bundle.ByteCount),
                    Ui.Fact(id + ".entries", S.Text(UiStrings.WindowsSettingsBundlesEntries), bundle.EntryCount),
                    Ui.Fact(id + ".retained", S.Text(UiStrings.WindowsSettingsBundlesRetained), bundle.ContentRetained ? "true" : "false"),
                    Ui.Fact(id + ".references", S.Text(UiStrings.WindowsSettingsBundlesReferences), bundle.References.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                    Ui.Fact(id + ".trust", S.Text(UiStrings.WindowsSettingsBundlesTrust), $"{trust.Policy} · {trust.Signature} · {trust.ExecutionAssessment} · {trust.TeamIdentifier}"))));
            }
            section.Children.Add(list);
        }
        section.Children.Add(CliRow("settings.toolchains.bundles", SurfaceLoader.RuntimeBundleListCommand));
    }
}
