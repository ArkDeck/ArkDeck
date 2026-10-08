using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace ArkDeck.App.Pages;

/// <summary>
/// Sessions: the Session catalog the Runtime keeps (<c>session.list|show</c>), a Session's
/// pin and unpin (<c>session.pin|unpin</c>, guarded by the generation the App read), its export
/// and the retention cleanup. Export and cleanup are preview-then-apply, as on macOS and in
/// the CLI: the Runtime previews exactly what it would write or remove, the person confirms
/// that preview, and the apply names its id and digest, so nothing else can be written or
/// removed. The export destination is a new folder the person chooses; the Runtime proves it
/// absent and writes it (sensitive Artifacts excluded).
/// </summary>
public sealed partial class SessionsPage() : SurfacePage<SessionsState>(
    "sessions", "sessions.title", UiStrings.WindowsNavigationSessions,
    "sessions.refresh", UiStrings.SettingsCommonRefresh, "sessions.loading", UiStrings.SettingsCommonLoading)
{
    protected override double PageMaxWidth => double.PositiveInfinity;

    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _detail = new() { Spacing = 8 };
    private TextBlock _status = Ui.Status("sessions.status");
    private IReadOnlyList<SessionSummary> _sessions = [];
    private string? _selected;

    protected override Task<SessionsState> LoadAsync() => App.Loader.SessionsAsync();

    protected override void Render(SessionsState state, StackPanel body)
    {
        var said = _status.Text;
        _status = Ui.Status("sessions.status");
        Ui.SetText(_status, said);
        _detail = new StackPanel { Spacing = 8 };
        body.Children.Add(Ui.Text("sessions.subtitle", S.Text(UiStrings.WindowsSessionsSubtitle), "ArkDeckCaptionStyle"));
        if (state.Sessions.Unavailable is { } why)
        {
            _sessions = [];
            body.Children.Add(Ui.Card(Ui.UnavailableNotice("sessions.unavailable", UiStrings.WindowsSessionsUnavailable, why)));
            return;
        }
        _sessions = state.Sessions.Value!;
        body.Children.Add(Ui.Row(Ui.Button("sessions.cleanup", S.Text(UiStrings.WindowsSessionsCleanup), async (_, _) => await CleanupAsync())));
        body.Children.Add(_status);
        if (_sessions.Count == 0)
        {
            body.Children.Add(Ui.Text("sessions.empty", S.Text(UiStrings.WindowsSessionsEmpty)));
            return;
        }
        var list = Ui.Choice("sessions.list", S.Text(UiStrings.WindowsNavigationSessions));
        foreach (var session in _sessions)
        {
            var summary = $"{S.Format(UiStrings.WindowsBytes, session.SizeBytes)} · {session.CompletedAtUtc}"
                          + (session.Pinned ? " · " + S.Text(UiStrings.WindowsSessionsPinned) : string.Empty);
            var row = Ui.Stack(2,
                Ui.Text($"sessions.row.{session.SessionId}.title", session.SessionId, "ArkDeckMonoStyle"),
                Ui.Text($"sessions.row.{session.SessionId}.summary", summary, "ArkDeckCaptionStyle"));
            var item = Ui.Item("sessions.row." + session.SessionId, $"{session.SessionId}, {summary}", row);
            item.Tag = session.SessionId;
            list.Items.Add(item);
            if (session.SessionId == _selected) list.SelectedItem = item;
        }
        list.SelectionChanged += (_, e) =>
        {
            if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string id }) ShowSession(id);
        };
        body.Children.Add(Ui.MasterDetail(Ui.Card(list), Ui.Card(_detail, "sessions.detail")));
        if (_selected is { } selected && _sessions.Any(s => s.SessionId == selected)) ShowSession(selected);
        else
        {
            _selected = null;
            _detail.Children.Add(Ui.Text("sessions.select", S.Text(UiStrings.WindowsSessionsSelect), "ArkDeckCaptionStyle"));
        }
    }

    private void ShowSession(string sessionId)
    {
        _selected = sessionId;
        _detail.Children.Clear();
        if (_sessions.FirstOrDefault(s => s.SessionId == sessionId) is not { } session) return;
        _detail.Children.Add(Ui.Heading("sessions.detail.title", session.SessionId, AutomationHeadingLevel.Level3));
        foreach (var (id, key, value) in new (string, string, string)[]
                 {
                     ("sessions.detail.completed", UiStrings.WindowsSessionsCompleted, session.CompletedAtUtc),
                     ("sessions.detail.expires", UiStrings.WindowsSessionsExpires, session.ExpiresAtUtc),
                     ("sessions.detail.size", UiStrings.WindowsSessionsSize, S.Format(UiStrings.WindowsBytes, session.SizeBytes)),
                     ("sessions.detail.pinned", UiStrings.WindowsSessionsPinned, S.Text(session.Pinned ? UiStrings.WindowsSessionsPinnedYes : UiStrings.WindowsSessionsPinnedNo)),
                     ("sessions.detail.generation", UiStrings.WindowsSessionsGeneration, session.Generation),
                 })
        {
            _detail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        _detail.Children.Add(Ui.Row(
            Ui.Button(session.Pinned ? "sessions.unpin" : "sessions.pin", S.Text(session.Pinned ? UiStrings.WindowsSessionsUnpin : UiStrings.WindowsSessionsPin),
                async (_, _) => await PinAsync(session, !session.Pinned)),
            Ui.Button("sessions.export", S.Text(UiStrings.WindowsSessionsExport), async (_, _) => await ExportAsync(session))));
    }

    private async Task PinAsync(SessionSummary session, bool pin)
    {
        var state = await Task.Run(() => App.Loader.PinSessionAsync(session, pin));
        MainWindow.Instance.Report(state);
        Ui.Say(_status, state.Answer.Unavailable is { } why
            ? $"{S.Text(UiStrings.WindowsSessionsRefused)} · {why.ReasonText(S)}"
            : S.Text(pin ? UiStrings.WindowsSessionsPinnedDone : UiStrings.WindowsSessionsUnpinnedDone));
        await RefreshAsync();
    }

    /// <summary>The Session export: a new folder inside the one the person picks, the Runtime's
    /// preview of it, the person's confirmation of that preview, then the Runtime's write.</summary>
    private async Task ExportAsync(SessionSummary session)
    {
        var picker = new FolderPicker(MainWindow.Instance.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null || string.IsNullOrEmpty(folder.Path)) return;
        var destination = Path.Combine(folder.Path, session.SessionId);
        for (var n = 2; Directory.Exists(destination) || File.Exists(destination); n++) destination = Path.Combine(folder.Path, $"{session.SessionId}-{n}");

        var preview = await Task.Run(() => App.Loader.ExportPreviewAsync(session.SessionId, destination));
        MainWindow.Instance.Report(preview);
        if (preview.Answer.Unavailable is { } why)
        {
            Ui.Say(_status, $"{S.Text(UiStrings.WindowsSessionsExportFailed)} · {why.ReasonText(S)}");
            return;
        }
        var p = preview.Answer.Value!;
        var content = Ui.Stack(6, Ui.Text("sessions.export.message", S.Format(UiStrings.WindowsSessionsExportMessage,
            p.SessionId, p.DestinationPath, S.Format(UiStrings.WindowsBytes, p.EstimatedBytes), p.DeviceIdentifierPolicy)));
        foreach (var artifact in p.Artifacts)
        {
            content.Children.Add(Ui.Text("sessions.export.artifact." + artifact.ArtifactId,
                S.Format(UiStrings.WindowsSessionsExportArtifact, artifact.Role, artifact.Privacy, artifact.Disposition), "ArkDeckCaptionStyle"));
        }
        var dialog = Ui.Dialog(XamlRoot, "sessions.export.preview", S.Text(UiStrings.WindowsSessionsExportTitle), content,
            S.Text(UiStrings.WindowsSessionsExportConfirm), S.Text(UiStrings.SettingsCommonCancel));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var applied = await Task.Run(() => App.Loader.ExportApplyAsync(p));
        MainWindow.Instance.Report(applied);
        Ui.Say(_status, applied.Answer.Unavailable is { } failed
            ? $"{S.Text(UiStrings.WindowsSessionsExportFailed)} · {failed.ReasonText(S)}"
            : S.Format(UiStrings.WindowsSessionsExportDone, applied.Answer.Value!.ExportedPath));
    }

    /// <summary>The retention cleanup: the Runtime's preview of exactly which Sessions it would
    /// remove (pinned ones never), the person's confirmation, then that removal and no other.</summary>
    private async Task CleanupAsync()
    {
        var preview = await Task.Run(() => App.Loader.CleanupPreviewAsync());
        MainWindow.Instance.Report(preview);
        if (preview.Answer.Unavailable is { } why)
        {
            Ui.Say(_status, $"{S.Text(UiStrings.WindowsSessionsCleanupFailed)} · {why.ReasonText(S)}");
            return;
        }
        var p = preview.Answer.Value!;
        var reclaimed = p.Reclaimed.ToArray();
        if (reclaimed.Length == 0)
        {
            Ui.Say(_status, S.Text(UiStrings.WindowsSessionsCleanupNothing));
            return;
        }
        var content = Ui.Stack(6, Ui.Text("sessions.cleanup.message", S.Format(UiStrings.WindowsSessionsCleanupMessage,
            reclaimed.Length, S.Format(UiStrings.WindowsBytes, p.ReclaimBytes), S.Format(UiStrings.WindowsBytes, p.CurrentBytes), S.Format(UiStrings.WindowsBytes, p.ProjectedBytes))));
        foreach (var session in reclaimed)
        {
            content.Children.Add(Ui.Text("sessions.cleanup.session." + session.SessionId,
                $"{session.SessionId} · {session.Reason} · {S.Format(UiStrings.WindowsBytes, session.SizeBytes)}", "ArkDeckMonoStyle"));
        }
        var dialog = Ui.Dialog(XamlRoot, "sessions.cleanup.preview", S.Text(UiStrings.WindowsSessionsCleanupTitle), content,
            S.Text(UiStrings.WindowsSessionsCleanupConfirm), S.Text(UiStrings.SettingsCommonCancel));
        dialog.DefaultButton = ContentDialogButton.Close;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var applied = await Task.Run(() => App.Loader.CleanupApplyAsync(p));
        MainWindow.Instance.Report(applied);
        Ui.Say(_status, applied.Answer.Unavailable is { } failed
            ? $"{S.Text(UiStrings.WindowsSessionsCleanupFailed)} · {failed.ReasonText(S)}"
            : S.Format(UiStrings.WindowsSessionsCleanupDone, applied.Answer.Value!.RemovedSessionIds.Count, S.Format(UiStrings.WindowsBytes, applied.Answer.Value.ReclaimedBytes)));
        await RefreshAsync();
    }
}
