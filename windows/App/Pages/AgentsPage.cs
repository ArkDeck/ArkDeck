using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Pages;

/// <summary>
/// Agents: the agent executions the Runtime runs (<c>agent.list|status</c>) and the human
/// actions they wait on (<c>human-action.list|show</c>), as the CLI shows them. A waiting action
/// is resumed once the person did what it asks (<c>agent.resume</c> for an agent execution's
/// action, <c>human-action.resume</c> otherwise); a pick-a-device action offers exactly the
/// values of its <c>selectionSchema</c> enum as radio buttons, and nothing else can be sent.
/// An execution that is not terminal can be abandoned after a confirmation, guarded by the
/// generation the App read (<c>agent.abandon</c>). Starting an agent stays in the CLI.
/// </summary>
public sealed partial class AgentsPage() : SurfacePage<AgentsState>(
    "agents", "agents.title", UiStrings.WindowsNavigationAgents,
    "agents.refresh", UiStrings.SettingsCommonRefresh, "agents.loading", UiStrings.SettingsCommonLoading)
{
    protected override double PageMaxWidth => double.PositiveInfinity;

    // Rebuilt by each render (an element is never moved between renders).
    private StackPanel _detail = new() { Spacing = 8 };
    private TextBlock _status = Ui.Status("agents.status");
    private IReadOnlyList<AgentExecution> _executions = [];
    private string? _selected;

    protected override Task<AgentsState> LoadAsync() => App.Loader.AgentsAsync();

    protected override void Render(AgentsState state, StackPanel body)
    {
        var said = _status.Text;
        _status = Ui.Status("agents.status");
        Ui.SetText(_status, said);
        _detail = new StackPanel { Spacing = 8 };
        body.Children.Add(Ui.Text("agents.subtitle", S.Text(UiStrings.WindowsAgentsSubtitle), "ArkDeckCaptionStyle"));
        body.Children.Add(_status);
        var records = Ui.Stack(16);
        body.Children.Add(Ui.MasterDetail(records, Ui.Card(_detail, "agents.detail")));
        records.Children.Add(Ui.Heading("agents.humanActions.title", S.Text(UiStrings.WindowsAgentsHumanActions)));
        if (state.HumanActions.Unavailable is { } noActions)
        {
            records.Children.Add(Ui.Card(Ui.UnavailableNotice("agents.humanActions.unavailable", UiStrings.WindowsAgentsHumanActionsUnavailable, noActions)));
        }
        else if (state.HumanActions.Value!.Count(a => a.IsWaiting) == 0)
        {
            records.Children.Add(Ui.Text("agents.humanActions.empty", S.Text(UiStrings.WindowsAgentsHumanActionsEmpty)));
        }
        else
        {
            var actions = Ui.Choice("agents.humanActions", S.Text(UiStrings.WindowsAgentsHumanActions));
            foreach (var action in state.HumanActions.Value!.Where(a => a.IsWaiting))
            {
                var summary = S.Format(UiStrings.WindowsAgentsActionRow, action.Category, action.MinimumAction, action.ExpiresAt);
                var row = Ui.Stack(2,
                    Ui.Text($"agents.humanAction.{action.ActionId}.title", action.ActionId, "ArkDeckMonoStyle"),
                    Ui.Text($"agents.humanAction.{action.ActionId}.summary", summary, "ArkDeckCaptionStyle"));
                var item = Ui.Item("agents.humanAction." + action.ActionId, $"{action.ActionId}, {summary}", row);
                item.Tag = action;
                actions.Items.Add(item);
            }
            actions.SelectionChanged += async (_, e) =>
            {
                if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: HumanAction action }) await ShowHumanActionAsync(action);
            };
            records.Children.Add(Ui.Card(actions));
        }

        records.Children.Add(Ui.Heading("agents.executions.title", S.Text(UiStrings.WindowsAgentsExecutions)));
        if (state.Executions.Unavailable is { } why)
        {
            _executions = [];
            records.Children.Add(Ui.Card(Ui.UnavailableNotice("agents.unavailable", UiStrings.WindowsAgentsUnavailable, why)));
            return;
        }
        _executions = state.Executions.Value!;
        if (_executions.Count == 0)
        {
            records.Children.Add(Ui.Text("agents.empty", S.Text(UiStrings.WindowsAgentsEmpty)));
            return;
        }
        var list = Ui.Choice("agents.list", S.Text(UiStrings.WindowsAgentsExecutions));
        foreach (var execution in _executions)
        {
            var summary = S.Format(UiStrings.WindowsAgentsRow, execution.Operation, execution.State);
            var row = Ui.Stack(2,
                Ui.Text($"agents.row.{execution.ExecutionId}.title", execution.ExecutionId, "ArkDeckMonoStyle"),
                Ui.Text($"agents.row.{execution.ExecutionId}.summary", summary, "ArkDeckCaptionStyle"));
            var item = Ui.Item("agents.row." + execution.ExecutionId, $"{execution.ExecutionId}, {summary}", row);
            item.Tag = execution.ExecutionId;
            list.Items.Add(item);
            if (execution.ExecutionId == _selected) list.SelectedItem = item;
        }
        list.SelectionChanged += async (_, e) =>
        {
            if (e.AddedItems.FirstOrDefault() is ListViewItem { Tag: string id }) await ShowExecutionAsync(id);
        };
        records.Children.Add(Ui.Card(list));
        if (_selected is { } selected && _executions.Any(e => e.ExecutionId == selected)) _ = ShowExecutionAsync(selected);
        else
        {
            _selected = null;
            _detail.Children.Add(Ui.Text("agents.select", S.Text(UiStrings.WindowsAgentsSelect), "ArkDeckCaptionStyle"));
        }
    }

    /// <summary>An agent execution as <c>agent.status</c> reads it now (its generation and its
    /// human action are the current ones, not the list's).</summary>
    private async Task ShowExecutionAsync(string executionId)
    {
        _selected = executionId;
        var detail = _detail;
        var state = await Task.Run(() => App.Loader.AgentAsync(executionId));
        MainWindow.Instance.Report(state);
        if (_selected != executionId || detail != _detail) return;
        detail.Children.Clear();
        if (state.Answer.Unavailable is { } why)
        {
            detail.Children.Add(Ui.UnavailableNotice("agents.detail.unavailable", UiStrings.WindowsAgentsUnavailable, why));
            return;
        }
        var execution = state.Answer.Value!;
        detail.Children.Add(Ui.Heading("agents.detail.title", execution.ExecutionId, AutomationHeadingLevel.Level3));
        foreach (var (id, key, value) in new (string, string, string?)[]
                 {
                     ("agents.detail.operation", UiStrings.WindowsAgentsOperation, execution.Operation),
                     ("agents.detail.state", UiStrings.WindowsAgentsState, execution.State),
                     ("agents.detail.generation", UiStrings.WindowsAgentsGeneration, execution.Generation),
                     ("agents.detail.job", UiStrings.WindowsAgentsJob, execution.JobId is { } job ? $"{job} · {execution.JobState}" : null),
                     ("agents.detail.target", UiStrings.WindowsAgentsTarget, execution.TargetId),
                     ("agents.detail.deadline", UiStrings.WindowsAgentsDeadline, execution.Deadline),
                     ("agents.detail.observed", UiStrings.WindowsAgentsObserved, execution.LastObservedAt),
                     ("agents.detail.next", UiStrings.WindowsAgentsNext, execution.NextActionKind is { } kind ? $"{kind} · {execution.NextActionReason}" : null),
                     ("agents.detail.failure", UiStrings.WindowsAgentsFailure, execution.FailureCode),
                 })
        {
            if (value is not null) detail.Children.Add(Ui.Fact(id, S.Text(key), value));
        }
        if (execution.OutcomeUnknown) detail.Children.Add(Ui.Text("agents.detail.outcomeUnknown", S.Text(UiStrings.WindowsAgentsOutcomeUnknown)));
        if (execution.HumanAction is { IsWaiting: true } action) detail.Children.Add(ActionCard(action));
        if (!execution.IsTerminal)
        {
            detail.Children.Add(Ui.Row(Ui.Button("agents.abandon", S.Text(UiStrings.WindowsAgentsAbandon), async (_, _) => await AbandonAsync(execution))));
        }
    }

    /// <summary>A waiting human action picked from the list: its execution when it belongs to
    /// one this page lists, else the action as <c>human-action.show</c> reads it.</summary>
    private async Task ShowHumanActionAsync(HumanAction listed)
    {
        if (listed.OwnerKind == "agentExecution" && _executions.Any(e => e.ExecutionId == listed.OwnerId))
        {
            await ShowExecutionAsync(listed.OwnerId);
            return;
        }
        _selected = null;
        var detail = _detail;
        var state = await Task.Run(() => App.Loader.HumanActionAsync(listed.ActionId));
        MainWindow.Instance.Report(state);
        if (detail != _detail) return;
        detail.Children.Clear();
        if (state.Answer.Unavailable is { } why)
        {
            detail.Children.Add(Ui.UnavailableNotice("agents.detail.unavailable", UiStrings.WindowsAgentsHumanActionsUnavailable, why));
            return;
        }
        detail.Children.Add(ActionCard(state.Answer.Value!));
    }

    /// <summary>What the Runtime waits on, and its Resume. A selection is a radio group of the
    /// schema's values (one Tab stop, arrow keys between them, named by its header); Resume
    /// without a choice says so rather than being disabled.</summary>
    private StackPanel ActionCard(HumanAction action)
    {
        var card = Ui.Stack(8,
            Ui.Heading("agents.action.title", S.Text(UiStrings.JobRecoveryHumanRequiredTitle), AutomationHeadingLevel.Level3),
            Ui.Text("agents.action.guidance", S.Text(UiStrings.JobRecoveryHumanRequiredGuidance), "ArkDeckCaptionStyle"),
            Ui.Fact("agents.action.id", S.Text(UiStrings.WindowsAgentsActionId), action.ActionId),
            Ui.Fact("agents.action.category", S.Text(UiStrings.WindowsAgentsActionCategory), action.Category),
            Ui.Fact("agents.action.minimum", S.Text(UiStrings.WindowsAgentsActionMinimum), action.MinimumAction),
            Ui.Fact("agents.action.expires", S.Text(UiStrings.WindowsAgentsActionExpires), action.ExpiresAt));
        RadioButtons? choices = null;
        if (action.NeedsSelection)
        {
            var header = S.Text(UiStrings.WindowsAgentsActionChoose);
            choices = new RadioButtons { Header = header };
            AutomationProperties.SetAutomationId(choices, "agents.action.choices");
            AutomationProperties.SetName(choices, header);
            foreach (var choice in action.Choices)
            {
                var button = new RadioButton { Content = choice.Label, Tag = choice.Value };
                AutomationProperties.SetAutomationId(button, "agents.action.choice." + choice.Value);
                AutomationProperties.SetName(button, choice.Label);
                choices.Items.Add(button);
            }
            card.Children.Add(choices);
        }
        card.Children.Add(Ui.Row(Ui.Button("agents.action.resume", S.Text(UiStrings.WindowsAgentsActionResume), async (_, _) =>
        {
            var selection = (choices?.SelectedItem as RadioButton)?.Tag as string;
            if (!action.Accepts(selection))
            {
                Ui.Say(_status, S.Text(UiStrings.WindowsAgentsActionChooseFirst));
                return;
            }
            await ResumeAsync(action, selection);
        }, accent: true)));
        return card;
    }

    private async Task ResumeAsync(HumanAction action, string? selection)
    {
        var state = await Task.Run(() => App.Loader.ResumeAsync(action, selection));
        MainWindow.Instance.Report(state);
        Ui.Say(_status, state.Answer.Unavailable is { } why
            ? $"{S.Text(UiStrings.WindowsAgentsActionRefused)} · {why.ReasonText(S)}"
            : S.Text(UiStrings.WindowsAgentsActionResumed));
        await RefreshAsync();
    }

    private async Task AbandonAsync(AgentExecution execution)
    {
        var content = Ui.Text("agents.abandon.message", S.Format(UiStrings.WindowsAgentsAbandonMessage, execution.ExecutionId, execution.Generation));
        var dialog = Ui.Dialog(XamlRoot, "agents.abandon.confirm", S.Text(UiStrings.WindowsAgentsAbandonTitle), content,
            S.Text(UiStrings.WindowsAgentsAbandonConfirm), S.Text(UiStrings.SettingsCommonCancel));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var state = await Task.Run(() => App.Loader.AbandonAsync(execution));
        MainWindow.Instance.Report(state);
        Ui.Say(_status, state.Answer.Unavailable is { } why
            ? $"{S.Text(UiStrings.WindowsAgentsAbandonFailed)} · {why.ReasonText(S)}"
            : S.Text(UiStrings.WindowsAgentsAbandonDone));
        await RefreshAsync();
    }
}
