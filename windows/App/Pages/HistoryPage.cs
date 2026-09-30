using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// History: the Jobs <c>job.list</c> returns (read only), or the macOS "Runtime History
/// Unavailable" state with the daemon's reason (<c>unavailable(rejected): The Job owner is
/// not configured</c> on today's Windows daemon) and <c>arkdeck job list</c>. Choosing a
/// Job shows it in the Job Inspector.
/// </summary>
public sealed partial class HistoryPage() : SurfacePage<HistoryState>(
    "history", "history.title", UiStrings.AppNavigationHistory,
    "history.refresh", UiStrings.HistoryActionRefresh, "history.loading", UiStrings.HistoryLoading)
{
    protected override Task<HistoryState> LoadAsync() => App.Loader.HistoryAsync();

    protected override void Render(HistoryState state, StackPanel body)
    {
        if (state.Jobs.Unavailable is { } why)
        {
            body.Children.Add(Ui.Card(Ui.UnavailableNotice("history.unavailable", UiStrings.HistoryUnavailableTitle, why,
                UiStrings.HistoryUnavailableGuidance, titleId: "history.unavailable.title")));
        }
        else if (state.Jobs.Value!.Count == 0)
        {
            body.Children.Add(Ui.Card(Ui.Stack(4,
                Ui.Text("history.empty.title", S.Text(UiStrings.HistoryEmptyTitle), "ArkDeckSectionTitleStyle"),
                Ui.Text("history.empty.description", S.Text(UiStrings.HistoryEmptyDescription)))));
        }
        else
        {
            var table = Ui.List("history.table", S.Text(UiStrings.AppNavigationHistory));
            table.SelectionMode = ListViewSelectionMode.Single;
            foreach (var job in state.Jobs.Value!)
            {
                var stateText = Ui.JobState("history.state.", job.State) + (job.OutcomeUnknown ? S.Text(UiStrings.HistoryStateOutcomeUnknownSuffix) : string.Empty);
                var row = Ui.Row(
                    Ui.Text($"history.row.state.{job.JobId}", stateText),
                    Ui.Text($"history.row.{job.JobId}.operation", job.Operation, "ArkDeckMonoStyle"),
                    Ui.Text($"history.row.{job.JobId}.job", job.JobId, "ArkDeckMonoStyle"),
                    Ui.Text($"history.row.{job.JobId}.created", S.Text(UiStrings.WindowsHistoryColumnCreated) + " " + job.CreatedAtUtc, "ArkDeckCaptionStyle"));
                var item = Ui.Item("history.row." + job.JobId, $"{job.JobId}, {job.Operation}, {stateText}", row);
                item.Tag = job.JobId;
                table.Items.Add(item);
            }
            table.SelectionChanged += async (_, e) =>
            {
                if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string jobId }) await MainWindow.Instance.Inspector.ShowJobAsync(jobId);
            };
            body.Children.Add(Ui.Card(table));
        }
        body.Children.Add(Ui.Text("history.readOnlyNote", S.Text(UiStrings.HistoryReadOnlyNote), "ArkDeckCaptionStyle"));
    }
}
