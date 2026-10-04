using System.Globalization;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.RemoteSources;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// The macOS remote build browser (<c>DebugRemoteBuildBrowserSheet</c> and
/// <c>DebugRemoteBuildBrowserViewModel</c>): a saved server, the folders below its verified build
/// root and the lib*.so files in them; Up, Refresh, and Use selected library. A listing that comes
/// back for another server than the one now selected, or after a newer request, is dropped (a
/// generation counter), so an old entry can never be chosen. Choosing binds the server to the
/// current Target, as macOS does.
/// </summary>
public sealed partial class DebugPage
{
    private async Task RemoteBrowserAsync()
    {
        IReadOnlyList<RemoteBuildSourcePresentation> sources;
        string? loadError = null;
        try
        {
            sources = await Task.Run(() => App.RemoteSources.ListSourcesAsync());
        }
        catch (RemoteBuildSourceException refused)
        {
            sources = [];
            loadError = SettingsPage.RemoteError(refused);
        }

        var generation = 0;
        RemoteBuildSourcePresentation? source = null;
        string requestedPath = "";
        RemoteBuildDirectoryListing? listing = null;
        RemoteBuildDirectoryEntry? selected = null;
        string? error = loadError;
        var loading = false;

        var body = Ui.Stack(8);
        var status = Ui.Status("debug.artifacts.remoteBrowser.status");
        var content = Ui.Stack(8,
            Ui.Text("debug.artifacts.remoteBrowser.detail", S.Text(UiStrings.DebugArtifactsRemoteBrowserDetail), "ArkDeckCaptionStyle"),
            body, status);
        var dialog = Ui.Dialog(XamlRoot, "debug.artifacts.remoteBrowser", S.Text(UiStrings.DebugArtifactsRemoteBrowserTitle),
            new ScrollViewer { Content = content, MaxHeight = 560 },
            S.Text(UiStrings.DebugArtifactsRemoteBrowserChoose), S.Text(UiStrings.DebugArtifactsRemoteBrowserCancel));
        dialog.DefaultButton = ContentDialogButton.None;
        var openSettings = false;

        async Task LoadAsync(string path)
        {
            if (source is not { } current) return;
            var ticket = ++generation;
            requestedPath = path;
            loading = true;
            error = null;
            Render();
            try
            {
                var result = await Task.Run(() => App.RemoteSources.ListDirectoryAsync(current.Id, path));
                if (ticket != generation) return;
                if (result.SourceId != source?.Id)
                {
                    listing = null;
                    error = S.Text(UiStrings.WindowsRemoteSourcesErrorSourceNotFound);
                }
                else
                {
                    listing = result;
                }
            }
            catch (RemoteBuildSourceException failure)
            {
                if (ticket != generation) return;
                listing = null;
                error = SettingsPage.RemoteError(failure);
            }
            loading = false;
            selected = null;
            Render();
        }

        void Render()
        {
            body.Children.Clear();
            if (sources.Count == 0)
            {
                body.Children.Add(Ui.Heading("debug.artifacts.remoteBrowser.empty.title", S.Text(UiStrings.DebugArtifactsRemoteBrowserEmptyTitle), AutomationHeadingLevel.Level3));
                body.Children.Add(Ui.Text("debug.artifacts.remoteBrowser.empty.detail", S.Text(UiStrings.DebugArtifactsRemoteBrowserEmptyDetail)));
                body.Children.Add(Ui.Row(Ui.Button("debug.artifacts.remoteBrowser.openSettings", S.Text(UiStrings.DebugArtifactsRemoteBrowserOpenSettings), (_, _) =>
                {
                    openSettings = true;
                    dialog.Hide();
                })));
                if (error is not null) body.Children.Add(Ui.Text("debug.artifacts.remoteBrowser.error", error, "ArkDeckCaptionStyle"));
                return;
            }
            var server = new ComboBox { Header = S.Text(UiStrings.DebugArtifactsRemoteBrowserServer), MinWidth = 320 };
            AutomationProperties.SetAutomationId(server, "debug.artifacts.remoteBrowser.server");
            AutomationProperties.SetName(server, S.Text(UiStrings.DebugArtifactsRemoteBrowserServer));
            foreach (var candidate in sources)
            {
                var item = new ComboBoxItem { Content = $"{candidate.Name} · {candidate.Endpoint}", Tag = candidate.Id };
                AutomationProperties.SetAutomationId(item, "debug.artifacts.remoteBrowser.server." + candidate.Id.ToString("D").ToLowerInvariant());
                server.Items.Add(item);
                if (candidate.Id == source?.Id) server.SelectedItem = item;
            }
            server.SelectionChanged += async (_, _) =>
            {
                if (server.SelectedItem is not ComboBoxItem { Tag: Guid id } || id == source?.Id) return;
                source = sources.First(s => s.Id == id);
                listing = null;
                selected = null;
                await LoadAsync("");
            };
            body.Children.Add(server);
            var up = Ui.Button("debug.artifacts.remoteBrowser.up", S.Text(UiStrings.DebugArtifactsRemoteBrowserUp), async (_, _) =>
            {
                if (loading) return;
                var path = requestedPath;
                if (path.Length == 0)
                {
                    Ui.Say(status, S.Text(UiStrings.DebugArtifactsRemoteBrowserRoot));
                    return;
                }
                await LoadAsync(path.Contains('/') ? path[..path.LastIndexOf('/')] : "");
            });
            var refresh = Ui.Button("debug.artifacts.remoteBrowser.refresh", S.Text(UiStrings.DebugArtifactsRemoteBrowserRefresh), async (_, _) => await LoadAsync(requestedPath));
            body.Children.Add(Ui.Row(up, refresh,
                Ui.Text("debug.artifacts.remoteBrowser.path", requestedPath.Length == 0 ? S.Text(UiStrings.DebugArtifactsRemoteBrowserRoot) : requestedPath, "ArkDeckMonoStyle")));
            if (loading) body.Children.Add(Ui.Progress("debug.artifacts.remoteBrowser.loading", S.Text(UiStrings.SettingsRemoteSourcesTesting)));
            if (error is not null) body.Children.Add(Ui.Text("debug.artifacts.remoteBrowser.error", error, "ArkDeckCaptionStyle"));
            if (!loading && listing is { } shown)
            {
                if (shown.Entries.Count == 0)
                {
                    body.Children.Add(Ui.Text("debug.artifacts.remoteBrowser.noArtifacts", S.Text(UiStrings.DebugArtifactsRemoteBrowserNoArtifacts), "ArkDeckCaptionStyle"));
                }
                foreach (var entry in shown.Entries)
                {
                    var kind = S.Text(entry.Kind == RemoteBuildEntryKind.Directory ? UiStrings.DebugArtifactsRemoteBrowserDirectory : UiStrings.DebugArtifactsRemoteBrowserLibrary);
                    var label = entry.Kind == RemoteBuildEntryKind.Directory ? $"{entry.Name}/"
                        : $"{(ReferenceEquals(entry, selected) ? "✓ " : "")}{entry.Name} · {(entry.ByteCount ?? 0).ToString("N0", CultureInfo.InvariantCulture)} B";
                    var button = Ui.Button("debug.artifacts.remoteBrowser.entry." + entry.RelativePath, label, async (_, _) =>
                    {
                        if (loading || listing is null || listing.SourceId != source?.Id || !listing.Entries.Contains(entry)) return;
                        if (entry.Kind == RemoteBuildEntryKind.Directory)
                        {
                            await LoadAsync(entry.RelativePath);
                            return;
                        }
                        selected = entry;
                        Render();
                        Ui.Say(status, entry.Name);
                    });
                    AutomationProperties.SetName(button, $"{entry.Name}, {kind}");
                    body.Children.Add(button);
                }
            }
        }

        source = sources.FirstOrDefault();
        Render();
        if (source is not null) _ = LoadAsync("");

        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (loading || selected is null || listing is null || listing.SourceId != source?.Id || !listing.Entries.Contains(selected)
                || selected.Kind != RemoteBuildEntryKind.NativeLibrary)
            {
                args.Cancel = true;
                Ui.Say(status, S.Text(UiStrings.DebugArtifactsRemoteBrowserLibrary) + ": " + S.Text(UiStrings.DebugArtifactsNoLibrary));
            }
        };
        var result = await dialog.ShowAsync();
        generation++;
        if (openSettings)
        {
            MainWindow.Instance.OpenSettings("remoteSources");
            return;
        }
        if (result != ContentDialogResult.Primary || selected is not { } library || source is not { } chosenSource) return;
        _remoteLibrary = (chosenSource.Id, chosenSource.Name, library.RelativePath, library.Name);
        _libraryPath = null;
        _libraryName = library.Name;
        _preparation = null;
        _nativeFailure = null;
        if (Target is { } target)
        {
            try
            {
                await Task.Run(() => App.RemoteSources.BindAsync(chosenSource.Id, target.TargetId));
            }
            catch (RemoteBuildSourceException failure)
            {
                _nativeFailure = $"{S.Text(UiStrings.DebugArtifactsRemoteBindingFailed)} {SettingsPage.RemoteError(failure)}";
            }
        }
        RenderTab();
        if (_nativeFailure is { } why) Ui.Say(_artifactsStatus, why);
    }
}
