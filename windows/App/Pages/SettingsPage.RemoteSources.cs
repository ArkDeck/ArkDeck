using System.Globalization;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.RemoteSources;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace ArkDeck.App.Pages;

/// <summary>
/// Settings › Servers (macOS <c>RemoteSourcesSettingsPane</c>): the saved SSH servers the Debug
/// workspace browses for remote build artifacts, each with its endpoint, build root, host-key
/// fingerprint and where its credential is kept; Add and Edit open the server editor, whose
/// "Test connection and inspect host key" verifies the connection, the credential, the SFTP root
/// and the host key, and whose "Save verified server" trusts exactly that key; Remove asks first.
/// Everything here is the App's own (no Runtime call).
/// </summary>
public sealed partial class SettingsPage
{
    private IReadOnlyList<RemoteBuildSourcePresentation>? _sources;
    private string? _sourcesError;
    private bool _sourcesBusy;
    private TextBlock _sourcesStatus = Ui.Status("settings.remoteSources.status");

    /// <summary>The catalogue text of a remote-source refusal (macOS <c>errorDescription</c>).</summary>
    internal static string RemoteError(Exception error) => error is RemoteBuildSourceException refusal
        ? refusal.Detail is { } detail && refusal.Code is RemoteBuildSourceErrorCode.ConnectionFailed or RemoteBuildSourceErrorCode.CredentialStoreFailed
            ? S.Format(refusal.MessageKey, detail)
            : S.Text(refusal.MessageKey)
        : S.Format(UiStrings.WindowsRemoteSourcesErrorConnectionFailed, error.Message);

    private void RemoteSourcesTab()
    {
        Subtitle(UiStrings.SettingsRemoteSourcesSubtitle);
        var said = _sourcesStatus.Text;
        _sourcesStatus = Ui.Status("settings.remoteSources.status");
        Ui.SetText(_sourcesStatus, said);
        var servers = Section("settings.remoteSources", UiStrings.SettingsRemoteSourcesTitle);
        if (_sources is null && _sourcesError is null)
        {
            servers.Children.Add(Ui.Progress("settings.remoteSources.loading", S.Text(UiStrings.WindowsRemoteSourcesLoading)));
            if (!_sourcesBusy) _ = LoadSourcesAsync();
        }
        else if (_sources is { Count: 0 })
        {
            servers.Children.Add(Ui.Text("settings.remoteSources.empty.title", S.Text(UiStrings.SettingsRemoteSourcesEmptyTitle), "ArkDeckSectionTitleStyle"));
            servers.Children.Add(Ui.Text("settings.remoteSources.empty.detail", S.Text(UiStrings.SettingsRemoteSourcesEmptyDetail), "ArkDeckCaptionStyle"));
        }
        else if (_sources is not null)
        {
            foreach (var source in _sources) servers.Children.Add(SourceRow(source));
        }
        servers.Children.Add(Ui.Row(
            Ui.Button("settings.remoteSources.add", S.Text(UiStrings.SettingsRemoteSourcesAdd), async (_, _) => await EditSourceAsync(null)),
            Ui.Button("settings.remoteSources.refresh", S.Text(UiStrings.SettingsRemoteSourcesRefresh), async (_, _) => await LoadSourcesAsync())));
        if (_sourcesError is { } error) servers.Children.Add(Ui.Text("settings.remoteSources.error", error, "ArkDeckCaptionStyle"));
        servers.Children.Add(_sourcesStatus);

        var security = Section("settings.remoteSources.security", UiStrings.SettingsRemoteSourcesSecurityTitle);
        security.Children.Add(Assurance("settings.remoteSources.security.keychain", UiStrings.SettingsRemoteSourcesSecurityKeychain, UiStrings.WindowsRemoteSourcesSecurityCredentialsDetail));
        security.Children.Add(Assurance("settings.remoteSources.security.hostKey", UiStrings.SettingsRemoteSourcesSecurityHostKey, UiStrings.SettingsRemoteSourcesSecurityHostKeyDetail));
        security.Children.Add(Assurance("settings.remoteSources.security.readOnly", UiStrings.SettingsRemoteSourcesSecurityReadOnly, UiStrings.SettingsRemoteSourcesSecurityReadOnlyDetail));
        security.Children.Add(Ui.Text("settings.remoteSources.client", S.Text(UiStrings.WindowsRemoteSourcesClient), "ArkDeckCaptionStyle"));
    }

    private async Task LoadSourcesAsync()
    {
        if (_sourcesBusy) return;
        _sourcesBusy = true;
        try
        {
            _sources = await Task.Run(() => App.RemoteSources.ListSourcesAsync());
            _sourcesError = null;
        }
        catch (RemoteBuildSourceException error)
        {
            _sourcesError = RemoteError(error);
            _sources ??= [];
        }
        finally
        {
            _sourcesBusy = false;
        }
        if (_selectedTab == "remoteSources") RenderTab();
    }

    private Border SourceRow(RemoteBuildSourcePresentation source)
    {
        var id = "settings.remoteSources.row." + source.Id.ToString("D").ToLowerInvariant();
        var badge = S.Text(source.UsesSystemDefaultCredential ? UiStrings.SettingsRemoteSourcesCredentialSystemDefault : UiStrings.WindowsRemoteSourcesCredentialStored);
        var title = Ui.Row(Ui.Text(id + ".name", source.Name, "ArkDeckSectionTitleStyle"),
            Ui.Text(id + ".credential", source.CredentialStored ? badge : S.Text(UiStrings.WindowsRemoteSourcesErrorCredentialUnavailable), "ArkDeckCaptionStyle"));
        var remove = Ui.Button(id + ".remove", S.Text(UiStrings.SettingsRemoteSourcesRemove), async (_, _) => await RemoveSourceAsync(source));
        AutomationProperties.SetName(remove, $"{S.Text(UiStrings.SettingsRemoteSourcesRemove)}: {source.Name}");
        var edit = Ui.Button(id + ".edit", S.Text(UiStrings.SettingsRemoteSourcesEdit), async (_, _) => await EditSourceAsync(source));
        AutomationProperties.SetName(edit, $"{S.Text(UiStrings.SettingsRemoteSourcesEdit)}: {source.Name}");
        var panel = Ui.Stack(4, title,
            Ui.Fact(id + ".endpoint", S.Text(UiStrings.WindowsRemoteSourcesEndpoint), source.Endpoint),
            Ui.Fact(id + ".root", S.Text(UiStrings.WindowsRemoteSourcesRoot), source.RootPath),
            Ui.Fact(id + ".fingerprint", S.Text(UiStrings.WindowsRemoteSourcesFingerprint), source.HostKeyFingerprint),
            Ui.Row(edit, remove));
        return Ui.Card(panel, id);
    }

    private async Task RemoveSourceAsync(RemoteBuildSourcePresentation source)
    {
        var dialog = Ui.Dialog(XamlRoot, "settings.remoteSources.removeConfirm", S.Text(UiStrings.SettingsRemoteSourcesRemoveTitle),
            Ui.Text("settings.remoteSources.remove.detail", S.Text(UiStrings.WindowsRemoteSourcesRemoveDetail)),
            S.Text(UiStrings.SettingsRemoteSourcesRemove), S.Text(UiStrings.SettingsCommonCancel));
        dialog.DefaultButton = ContentDialogButton.Close;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await Task.Run(() => App.RemoteSources.RemoveAsync(source.Id));
            Ui.Say(_sourcesStatus, S.Text(UiStrings.WindowsRemoteSourcesRemoved));
        }
        catch (RemoteBuildSourceException error)
        {
            _sourcesError = RemoteError(error);
        }
        _sources = null;
        await LoadSourcesAsync();
    }

    /// <summary>The server editor (macOS <c>RemoteSourceEditorSheet</c>). Any edit discards a
    /// probe, so Save trusts only the key of the connection just tested.</summary>
    private async Task EditSourceAsync(RemoteBuildSourcePresentation? existing)
    {
        RemoteBuildSourceProbe? probe = null;
        var generation = 0;
        byte[]? privateKey = null;
        string? privateKeyName = null;
        var useSystemDefault = existing is null || existing.UsesSystemDefaultCredential;
        var authentication = existing?.Authentication ?? RemoteBuildSourceAuthentication.Password;

        TextBox Field(string id, string key, string value)
        {
            var box = new TextBox { Header = S.Text(key), Text = value, MinWidth = 320 };
            AutomationProperties.SetAutomationId(box, "settings.remoteSources.field." + id);
            AutomationProperties.SetName(box, S.Text(key));
            return box;
        }
        PasswordBox Secret(string id, string key)
        {
            var box = new PasswordBox { Header = S.Text(key), MinWidth = 320 };
            AutomationProperties.SetAutomationId(box, "settings.remoteSources.field." + id);
            AutomationProperties.SetName(box, S.Text(key));
            return box;
        }

        var name = Field("name", UiStrings.SettingsRemoteSourcesFieldName, existing?.Name ?? "");
        var host = Field("host", UiStrings.SettingsRemoteSourcesFieldHost, existing?.Host ?? "");
        var port = Field("port", UiStrings.SettingsRemoteSourcesFieldPort, (existing?.Port ?? 22).ToString(CultureInfo.InvariantCulture));
        var username = Field("username", UiStrings.SettingsRemoteSourcesFieldUsername, existing?.Username ?? "");
        var root = Field("root", UiStrings.SettingsRemoteSourcesFieldRoot, existing?.RootPath ?? "");
        var method = new ComboBox { Header = S.Text(UiStrings.SettingsRemoteSourcesFieldAuthentication), MinWidth = 320 };
        AutomationProperties.SetAutomationId(method, "settings.remoteSources.field.authentication");
        AutomationProperties.SetName(method, S.Text(UiStrings.SettingsRemoteSourcesFieldAuthentication));
        foreach (var (tag, key) in new[] { (RemoteBuildSourceAuthentication.Password, UiStrings.SettingsRemoteSourcesAuthPassword), (RemoteBuildSourceAuthentication.PrivateKey, UiStrings.SettingsRemoteSourcesAuthPrivateKey) })
        {
            var item = new ComboBoxItem { Content = S.Text(key), Tag = tag };
            AutomationProperties.SetAutomationId(item, "settings.remoteSources.field.authentication." + (tag == RemoteBuildSourceAuthentication.Password ? "password" : "privateKey"));
            method.Items.Add(item);
            if (tag == authentication) method.SelectedItem = item;
        }
        var password = Secret("password", existing?.Authentication == RemoteBuildSourceAuthentication.Password ? UiStrings.WindowsRemoteSourcesFieldPasswordOptional : UiStrings.SettingsRemoteSourcesFieldPassword);
        var passphrase = Secret("passphrase", UiStrings.SettingsRemoteSourcesFieldPassphrase);
        var keyStatus = Ui.Text("settings.remoteSources.keyStatus", "", "ArkDeckMonoStyle");
        var keyProblem = Ui.Status("settings.remoteSources.keyProblem", AutomationLiveSetting.Assertive);
        var credential = Ui.Stack(8);
        var verification = Ui.Stack(6);
        var problem = Ui.Status("settings.remoteSources.probeError", AutomationLiveSetting.Assertive);

        void Discard()
        {
            generation++;
            if (probe is null && verification.Children.Count == 0) return;
            probe = null;
            verification.Children.Clear();
        }

        void RenderCredential()
        {
            credential.Children.Clear();
            credential.Children.Add(method);
            var stored = existing is not null && existing.Authentication == authentication;
            if (authentication == RemoteBuildSourceAuthentication.Password)
            {
                credential.Children.Add(password);
            }
            else
            {
                var choose = Ui.Button("settings.remoteSources.choosePrivateKey", S.Text(UiStrings.SettingsRemoteSourcesChoosePrivateKey), async (_, _) =>
                {
                    var picker = new FileOpenPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
                    picker.FileTypeFilter.Add("*");
                    var picked = await picker.PickSingleFileAsync();
                    if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
                    try
                    {
                        var info = new FileInfo(picked.Path);
                        if (info.Length is < 1 or > RemoteBuildSourceBounds.MaximumKeyBytes)
                        {
                            Ui.Say(keyProblem, S.Text(UiStrings.SettingsRemoteSourcesPrivateKeyInvalid));
                            return;
                        }
                        privateKey = await File.ReadAllBytesAsync(picked.Path);
                        privateKeyName = info.Name;
                        useSystemDefault = false;
                        Ui.SetText(keyProblem, "");
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                    {
                        Ui.Say(keyProblem, S.Text(UiStrings.SettingsRemoteSourcesPrivateKeyReadFailed));
                        return;
                    }
                    Discard();
                    RenderCredential();
                });
                var row = Ui.Row(choose);
                if (!useSystemDefault)
                {
                    row.Children.Add(Ui.Button("settings.remoteSources.useSystemDefault", S.Text(UiStrings.SettingsRemoteSourcesUseSystemDefault), (_, _) =>
                    {
                        useSystemDefault = true;
                        privateKey = null;
                        privateKeyName = null;
                        Discard();
                        RenderCredential();
                    }));
                }
                credential.Children.Add(row);
                Ui.SetText(keyStatus, privateKeyName is { } chosen ? S.Format(UiStrings.WindowsRemoteSourcesPrivateKeyChosen, chosen)
                    : useSystemDefault ? S.Text(UiStrings.WindowsRemoteSourcesSystemDefaultIdentity)
                    : S.Text(UiStrings.SettingsRemoteSourcesNoPrivateKey));
                credential.Children.Add(keyStatus);
                credential.Children.Add(keyProblem);
                credential.Children.Add(Ui.Text("settings.remoteSources.systemDefaultHint", S.Text(UiStrings.WindowsRemoteSourcesSystemDefaultHint), "ArkDeckCaptionStyle"));
                credential.Children.Add(passphrase);
            }
            if (stored && password.Password.Length == 0 && privateKey is null)
            {
                credential.Children.Add(Ui.Text("settings.remoteSources.usingStoredCredential", S.Text(UiStrings.WindowsRemoteSourcesUsingStoredCredential), "ArkDeckCaptionStyle"));
            }
        }

        foreach (var box in new[] { name, host, port, username, root }) box.TextChanging += (_, _) => Discard();
        password.PasswordChanging += (_, _) => Discard();
        passphrase.PasswordChanging += (_, _) => Discard();
        method.SelectionChanged += (_, _) =>
        {
            if (method.SelectedItem is not ComboBoxItem { Tag: RemoteBuildSourceAuthentication chosen } || chosen == authentication) return;
            authentication = chosen;
            if (chosen == RemoteBuildSourceAuthentication.PrivateKey && existing?.Authentication != RemoteBuildSourceAuthentication.PrivateKey) useSystemDefault = true;
            Discard();
            RenderCredential();
        };
        RenderCredential();

        RemoteBuildSourceDraft Draft() => new(existing?.Id, name.Text, host.Text,
            int.TryParse(port.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var number) ? number : 0,
            username.Text, root.Text, authentication);

        RemoteBuildSourceCredentialInput? Input()
        {
            if (authentication == RemoteBuildSourceAuthentication.Password)
            {
                return password.Password.Length > 0 ? new RemoteBuildSourceCredentialInput.Password(password.Password) : null;
            }
            var phrase = passphrase.Password.Length > 0 ? passphrase.Password : null;
            if (privateKey is { } key) return new RemoteBuildSourceCredentialInput.PrivateKey(key, phrase);
            if (useSystemDefault) return phrase is null && existing?.Authentication == RemoteBuildSourceAuthentication.PrivateKey ? null : new RemoteBuildSourceCredentialInput.SystemDefault(phrase);
            return null;
        }

        var testing = Ui.Status("settings.remoteSources.testing");
        var test = Ui.Button("settings.remoteSources.testConnection", S.Text(UiStrings.SettingsRemoteSourcesTestConnection), async (_, _) =>
        {
            if (_sourcesBusy) return;
            var ticket = ++generation;
            verification.Children.Clear();
            Ui.SetText(problem, "");
            Ui.Say(testing, S.Text(UiStrings.SettingsRemoteSourcesTesting));
            _sourcesBusy = true;
            try
            {
                var draft = Draft();
                var input = Input();
                var result = await Task.Run(() => App.RemoteSources.ProbeAsync(draft, input));
                if (ticket != generation) return;
                probe = result;
                verification.Children.Add(Ui.Text("settings.remoteSources.verified", S.Text(UiStrings.SettingsRemoteSourcesVerified), "ArkDeckSectionTitleStyle"));
                verification.Children.Add(Ui.Fact("settings.remoteSources.probe.endpoint", S.Text(UiStrings.WindowsRemoteSourcesEndpoint), result.Endpoint));
                verification.Children.Add(Ui.Fact("settings.remoteSources.probe.root", S.Text(UiStrings.WindowsRemoteSourcesCanonicalRoot), result.CanonicalRootPath));
                verification.Children.Add(Ui.Fact("settings.remoteSources.probe.fingerprint", S.Text(UiStrings.WindowsRemoteSourcesFingerprint), result.HostKeyFingerprint));
                if (result.RequiresNewHostTrust) verification.Children.Add(Ui.Text("settings.remoteSources.trustOnSave", S.Text(UiStrings.SettingsRemoteSourcesTrustOnSave), "ArkDeckCaptionStyle"));
                Ui.Say(testing, S.Text(UiStrings.SettingsRemoteSourcesVerified));
            }
            catch (RemoteBuildSourceException error)
            {
                if (ticket != generation) return;
                Ui.SetText(testing, "");
                Ui.Say(problem, RemoteError(error));
            }
            finally
            {
                _sourcesBusy = false;
            }
        });

        var content = Ui.Stack(10,
            Ui.Text("settings.remoteSources.editor.detail", S.Text(UiStrings.SettingsRemoteSourcesEditorDetail), "ArkDeckCaptionStyle"),
            Ui.Heading("settings.remoteSources.editor.server", S.Text(UiStrings.SettingsRemoteSourcesEditorServer), AutomationHeadingLevel.Level3),
            name, host, port, username, root,
            Ui.Heading("settings.remoteSources.editor.credential", S.Text(UiStrings.SettingsRemoteSourcesEditorCredential), AutomationHeadingLevel.Level3),
            credential,
            Ui.Heading("settings.remoteSources.editor.verify", S.Text(UiStrings.SettingsRemoteSourcesEditorVerify), AutomationHeadingLevel.Level3),
            Ui.Row(test), testing, verification, problem);
        var scroller = new ScrollViewer { Content = content, MaxHeight = 560 };
        var dialog = Ui.Dialog(XamlRoot, "settings.remoteSources.editor",
            S.Text(existing is null ? UiStrings.SettingsRemoteSourcesEditorAddTitle : UiStrings.SettingsRemoteSourcesEditorEditTitle), scroller,
            S.Text(UiStrings.SettingsRemoteSourcesSave), S.Text(UiStrings.SettingsCommonCancel));
        dialog.DefaultButton = ContentDialogButton.None;
        var saved = false;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                if (probe is not { } verified || _sourcesBusy)
                {
                    args.Cancel = true;
                    Ui.Say(problem, S.Text(UiStrings.WindowsRemoteSourcesSaveNeedsProbe));
                    return;
                }
                _sourcesBusy = true;
                try
                {
                    await Task.Run(() => App.RemoteSources.SaveAsync(verified));
                    saved = true;
                }
                catch (RemoteBuildSourceException error)
                {
                    probe = null;
                    args.Cancel = true;
                    Ui.Say(problem, RemoteError(error));
                }
                finally
                {
                    _sourcesBusy = false;
                }
            }
            finally
            {
                deferral.Complete();
            }
        };
        await dialog.ShowAsync();
        generation++;
        if (saved) Ui.Say(_sourcesStatus, S.Text(UiStrings.WindowsRemoteSourcesSaved));
        _sources = null;
        await LoadSourcesAsync();
    }
}
