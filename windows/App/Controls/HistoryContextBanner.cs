using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Controls;

/// <summary>A workspace that History can reopen on one of its records (macOS
/// <c>openHistoryContext</c>); the next refresh restores the record's read-only context.</summary>
public interface IHistoryContextPage
{
    void OpenHistoryContext(HistoryWorkspaceContext context);
}

/// <summary>
/// The macOS <c>HistoryWorkspaceContextBanner</c>: which record a workspace was reopened on (its
/// Job, Target, operation, state and Artifacts), that the context is read-only, and Dismiss.
/// </summary>
public static class HistoryContextBanner
{
    public static Border Create(HistoryWorkspaceContext context, Action dismiss)
    {
        var s = App.Strings;
        var close = Ui.Button("history.context.dismiss", s.Text(UiStrings.HistoryContextDismiss), (_, _) => dismiss());
        var title = new Grid { ColumnSpacing = 8 };
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.Children.Add(Ui.Heading("history.context.title", s.Text(UiStrings.HistoryContextTitle), AutomationHeadingLevel.Level2));
        Grid.SetColumn(close, 1);
        title.Children.Add(close);
        var panel = Ui.Stack(6, title,
            Ui.Text("history.context.readOnly", s.Text(UiStrings.HistoryContextReadOnly), "ArkDeckCaptionStyle"),
            Ui.Fact("history.context.job", s.Text(UiStrings.HistoryContextJob), context.JobId),
            Ui.Fact("history.context.target", s.Text(UiStrings.HistoryContextTarget), context.TargetId),
            Ui.Fact("history.context.operation", s.Text(UiStrings.HistoryContextOperation), context.OperationReference),
            Ui.Fact("history.context.state", s.Text(UiStrings.HistoryContextState), context.State));
        if (context.Artifacts.Count > 0)
        {
            panel.Children.Add(Ui.Fact("history.context.artifacts", s.Text(UiStrings.HistoryContextArtifacts), string.Join(", ", context.Artifacts.Select(a => a.Name))));
        }
        return Ui.Card(panel, "history.context");
    }
}
