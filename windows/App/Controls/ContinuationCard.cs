using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Controls;

/// <summary>
/// macOS <c>WorkspaceContinuationCard</c>: the prepared read-only request, visible in its
/// workspace before anything is submitted. Starting it creates one new Job after fresh identity
/// checks (<see cref="SurfaceLoader.SubmitContinuationAsync"/>), then runs it; it is started at
/// most once and never retried or replayed. No past authority, Artifact lease or Runtime Session
/// is carried.
/// </summary>
public sealed partial class ContinuationCard : UserControl
{
    private static Localizer S => App.Strings;

    private readonly long? _currentBindingRevision;
    private readonly string? _currentTargetId;
    private readonly TextBlock _note;
    private readonly TextBlock _status;
    private readonly FlowPanel _actions;
    private bool _attempted;

    public ContinuationCard(WorkspaceContinuation draft, string? currentTargetId, long? currentBindingRevision, Action close)
    {
        Draft = draft;
        _currentTargetId = currentTargetId;
        _currentBindingRevision = currentBindingRevision;
        AutomationProperties.SetAutomationId(this, "overview.continuation");
        AutomationProperties.SetName(this, S.Text(UiStrings.OverviewContinuationTitle));

        var title = Ui.Row(Ui.Heading("overview.continuation.title", S.Text(UiStrings.OverviewContinuationTitle), AutomationHeadingLevel.Level2),
            Ui.Text("overview.continuation.source", draft.SourceJob.JobId, "ArkDeckMonoStyle"),
            Ui.Button("overview.continuation.close", S.Text(UiStrings.OverviewContinuationClose), (_, _) => close()));
        _note = Ui.Text("overview.continuation.note", S.Text(UiStrings.OverviewContinuationExplanation), "ArkDeckCaptionStyle");
        var inputs = Ui.Text("overview.continuation.inputs", draft.Inputs.ToString(), "ArkDeckMonoStyle");
        inputs.IsTextSelectionEnabled = true;
        AutomationProperties.SetName(inputs, $"{draft.SourceJob.Operation} · {draft.SourceJob.TargetId}");
        var panel = Ui.Stack(8, title, _note,
            Ui.Text("overview.continuation.operation", $"{draft.SourceJob.Operation} · {draft.SourceJob.TargetId}", "ArkDeckMonoStyle"),
            inputs,
            Ui.Text("overview.continuation.thread", draft.SourceJob.ThreadId ?? S.Text(UiStrings.OverviewRecordThreadUngrouped), "ArkDeckMonoStyle"));
        if (!TargetMatches)
        {
            panel.Children.Add(Ui.Text("overview.continuation.drift", S.Text(UiStrings.OverviewResumeDriftTarget)));
        }
        _status = Ui.Status("overview.continuation.result");
        _actions = Ui.Row(Ui.Button("overview.continuation.submit", S.Text(UiStrings.OverviewContinuationSubmit), async (_, _) => await SubmitAsync(), accent: true), _status);
        panel.Children.Add(_actions);
        Content = Ui.Card(panel, "overview.continuation.card");
    }

    public WorkspaceContinuation Draft { get; }

    private bool TargetMatches => _currentTargetId == Draft.SourceJob.TargetId && _currentBindingRevision == Draft.BindingRevision;

    private async Task SubmitAsync()
    {
        // XPA-AC-8: the button stays enabled; a second start or a changed Target is refused in words.
        if (_attempted)
        {
            Ui.Say(_status, S.Text(UiStrings.WindowsOverviewContinuationAttempted));
            return;
        }
        if (!TargetMatches)
        {
            Ui.Say(_status, S.Text(UiStrings.OverviewResumeDriftTarget));
            return;
        }
        _attempted = true;
        _note.Text = S.Text(UiStrings.OverviewContinuationStatusNote);
        var submitted = await Task.Run(() => App.Loader.SubmitContinuationAsync(Draft));
        MainWindow.Instance.Report(submitted);
        if (submitted.Answer.Unavailable is { } refused)
        {
            Ui.Say(_status, refused.ReasonCode == refused.Detail ? refused.ReasonCode : $"{refused.ReasonCode}: {refused.Detail}");
            return;
        }
        var jobId = submitted.Answer.Value!.JobId;
        _actions.Children.Insert(1, Ui.Button("overview.continuation.openJob", S.Text(UiStrings.OverviewContinuationOpenJob),
            async (_, _) => await MainWindow.Instance.OpenJobAsync(jobId)));
        Ui.Say(_status, S.Text(UiStrings.OverviewContinuationSubmitted));
        var ran = await Task.Run(() => App.Loader.RunContinuationAsync(Draft, jobId));
        MainWindow.Instance.Report(ran);
        Ui.Say(_status, ran.Answer.Value is { } shown && shown.Status.TryGetValue("state", out var state) && state is ArkDeck.ClientKit.Json.JsonString s
            ? s.Value
            : ran.Answer.Unavailable!.ReasonCode);
    }
}
