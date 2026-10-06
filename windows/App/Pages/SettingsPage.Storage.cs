using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>Settings › Storage and Trace writes (macOS <c>StorageSettingsPane</c> and
/// <c>TraceCacheSettingsView</c>): the Session root and retention policy, bound to the generation
/// the Runtime reported, and the purge of inactive derived Trace databases. Each is confirmed by
/// the person; the Runtime validates, decides and answers, and that answer is shown.</summary>
public sealed partial class SettingsPage
{
    private string? _storageNote;
    private string? _traceNote;

    /// <summary>The Session location and the retention policy drafts, from the Runtime's values.</summary>
    private void StorageEditing(StorageStatus s)
    {
        var status = Ui.Status("settings.storage.status");
        if (_storageNote is { } note) Ui.Say(status, note);

        var location = Section("settings.storage.location", UiStrings.SettingsStorageLocation);
        location.Children.Add(Ui.Fact("settings.storage.location.root", S.Text(UiStrings.SettingsStorageRoot), s.SessionRootPath));
        location.Children.Add(Ui.Fact("settings.storage.rootSource", S.Text(UiStrings.SettingsStorageRootSource),
            S.Text(s.SessionRootKind == "custom" ? UiStrings.SettingsStorageRootSourceCustom : UiStrings.WindowsSettingsStorageRootSourceDefault)));
        location.Children.Add(Ui.Row(
            Ui.Button("settings.storage.chooseRoot", S.Text(UiStrings.SettingsStorageChooseRoot), async (_, _) => await ChooseRootAsync(status)),
            Ui.Button("settings.storage.resetRoot", S.Text(UiStrings.SettingsStorageResetRoot), async (_, _) =>
            {
                if (s.SessionRootKind != "custom")
                {
                    Ui.Say(status, S.Text(UiStrings.WindowsSettingsStorageAlreadyDefault));
                    return;
                }
                await WriteRootAsync(null, status);
            })));
        location.Children.Add(Ui.Text("settings.storage.futureJobs", S.Text(UiStrings.SettingsStorageFutureJobs), "ArkDeckCaptionStyle"));

        var policy = Section("settings.storage.policy", UiStrings.SettingsStoragePolicy);
        TextBox Field(string id, string labelKey, string value, string unitKey)
        {
            var box = new TextBox { Text = value, MinWidth = 110, Header = $"{S.Text(labelKey)} ({S.Text(unitKey)})" };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(box, id);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, S.Text(labelKey));
            return box;
        }
        var quota = Field("settings.storage.policy.quota", UiStrings.SettingsStorageQuota, StorageStatus.GiB(s.QuotaBytes), UiStrings.SettingsStorageGib);
        var margin = Field("settings.storage.policy.margin", UiStrings.SettingsStorageMargin, StorageStatus.GiB(s.SafetyMarginBytes), UiStrings.SettingsStorageGib);
        var retention = Field("settings.storage.policy.retention", UiStrings.SettingsStorageRetention, s.RetentionDays, UiStrings.SettingsStorageDays);
        policy.Children.Add(Ui.Row(quota, margin, retention));
        policy.Children.Add(Ui.Row(Ui.Button("settings.storage.save", S.Text(UiStrings.SettingsStorageSave),
            async (_, _) => await SavePolicyAsync(quota.Text, margin.Text, retention.Text, status), accent: true), status));
        policy.Children.Add(Ui.Text("settings.storage.policyDetail", S.Text(UiStrings.SettingsStoragePolicyDetail), "ArkDeckCaptionStyle"));
    }

    private async Task SavePolicyAsync(string quotaGiB, string marginGiB, string retentionDays, TextBlock status)
    {
        if (StorageStatus.Draft(quotaGiB, marginGiB, retentionDays) is not { } draft)
        {
            Ui.Say(status, S.Text(UiStrings.SettingsStorageValidationError));
            return;
        }
        var content = Ui.Stack(6, Ui.Text("settings.storage.confirm.message", S.Format(UiStrings.WindowsSettingsStorageConfirmPolicy,
            S.Format(UiStrings.WindowsBytes, draft.QuotaBytes.ToString(System.Globalization.CultureInfo.InvariantCulture)),
            S.Format(UiStrings.WindowsBytes, draft.MarginBytes.ToString(System.Globalization.CultureInfo.InvariantCulture)),
            (long)draft.RetentionDays)));
        var dialog = Ui.Dialog(XamlRoot, "settings.storage.confirm", S.Text(UiStrings.SettingsStoragePolicy), content,
            S.Text(UiStrings.SettingsStorageSave), S.Text(UiStrings.SettingsCommonCancel));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        Ui.Say(status, S.Text(UiStrings.SettingsCommonSaving));
        var written = await Task.Run(() => App.Loader.SaveStoragePolicyAsync(draft.QuotaBytes, draft.MarginBytes, draft.RetentionDays));
        await FinishStorageWriteAsync(written, status);
    }

    private async Task ChooseRootAsync(TextBlock status)
    {
        string? path;
        try
        {
            path = await PickFolderAsync();
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            Ui.Say(status, S.Text(UiStrings.SettingsStorageSelectionError));
            return;
        }
        if (path is null) return;
        await WriteRootAsync(path, status);
    }

    private async Task WriteRootAsync(string? path, TextBlock status)
    {
        var content = Ui.Stack(6, Ui.Text("settings.storage.confirm.message", path is null
                ? S.Text(UiStrings.WindowsSettingsStorageConfirmReset)
                : S.Format(UiStrings.WindowsSettingsStorageConfirmRoot, path)),
            Ui.Text("settings.storage.confirm.futureJobs", S.Text(UiStrings.SettingsStorageFutureJobs), "ArkDeckCaptionStyle"));
        var dialog = Ui.Dialog(XamlRoot, "settings.storage.confirm", S.Text(UiStrings.SettingsStorageLocation), content,
            S.Text(path is null ? UiStrings.SettingsStorageResetRoot : UiStrings.WindowsSettingsStorageUseFolder), S.Text(UiStrings.SettingsCommonCancel));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        Ui.Say(status, S.Text(UiStrings.SettingsCommonSaving));
        var written = await Task.Run(() => App.Loader.SetStorageRootAsync(path));
        await FinishStorageWriteAsync(written, status);
    }

    /// <summary>The Runtime's answer: saved, superseded by another writer (its state is shown), or
    /// refused with its reason.</summary>
    private async Task FinishStorageWriteAsync(SessionActionState<StorageWrite> written, TextBlock status)
    {
        MainWindow.Instance.Report(written);
        _storageNote = written.Answer.Unavailable is { } why
            ? $"{S.Text(UiStrings.WindowsSettingsStorageRefused)} · {why.ReasonText(S)}"
            : written.Answer.Value!.Superseded ? S.Text(UiStrings.WindowsSettingsStorageSuperseded) : S.Text(UiStrings.WindowsSettingsStorageSaved);
        Ui.Say(status, _storageNote);
        await RefreshAsync();
    }

    /// <summary>macOS <c>TraceCacheSettingsView</c>'s purge: the person confirms, the Runtime
    /// removes inactive derived databases only and reports what it removed.</summary>
    private void TracePurge(StackPanel cache, TraceCacheStatus c)
    {
        var status = Ui.Status("settings.trace.status");
        if (_traceNote is { } note) Ui.Say(status, note);
        cache.Children.Add(Ui.Row(Ui.Button("settings.trace.purge", S.Text(UiStrings.WindowsSettingsTracePurge), async (_, _) =>
        {
            var dialog = Ui.Dialog(XamlRoot, "settings.trace.confirm", S.Text(UiStrings.WindowsSettingsTracePurge),
                Ui.Text("settings.trace.confirm.message", S.Format(UiStrings.WindowsSettingsTracePurgeConfirm, c.InactiveEntryCount)),
                S.Text(UiStrings.WindowsSettingsTracePurge), S.Text(UiStrings.SettingsCommonCancel));
            dialog.DefaultButton = ContentDialogButton.Close;
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            Ui.Say(status, S.Text(UiStrings.SettingsCommonWorking));
            var purged = await Task.Run(() => App.Loader.PurgeTraceCacheAsync());
            MainWindow.Instance.Report(purged);
            _traceNote = purged.Answer.Unavailable is { } why
                ? $"{S.Text(UiStrings.WindowsSettingsTracePurgeFailed)} · {why.ReasonText(S)}"
                : S.Format(UiStrings.WindowsSettingsTracePurgeDone, purged.Answer.Value!.RemovedEntryCount);
            Ui.Say(status, _traceNote);
            await RefreshAsync();
        }), status));
        cache.Children.Add(Ui.Text("settings.trace.purgeNote", S.Text(UiStrings.WindowsSettingsTracePurgeNote), "ArkDeckCaptionStyle"));
    }
}
