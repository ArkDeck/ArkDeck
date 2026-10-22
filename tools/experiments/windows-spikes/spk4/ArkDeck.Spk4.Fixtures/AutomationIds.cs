namespace ArkDeck.Spk4.Fixtures;

/// <summary>Stable UIA AutomationIds (design §H.6 item 1): independent of localized text
/// and row position. Shared by the app and the UIA probe.</summary>
public static class AutomationIds
{
    public const string Nav = "Shell.Navigation";
    public const string NavOverview = "Nav.Overview";
    public const string NavHistory = "Nav.History";
    public const string NavViewer = "Nav.Viewer";
    public const string NavJob = "Nav.JobInspector";
    public const string NavDebug = "Nav.Debug";
    public const string NavTrace = "Nav.Trace";

    public const string FixtureBanner = "Shell.FixtureBanner";
    public const string HistoryList = "History.List";
    public const string HistoryStats = "History.LoadStats";
    public const string ViewerTree = "Viewer.Tree";
    public const string ViewerStats = "Viewer.LoadStats";
    public const string JobState = "Job.State";
    public const string JobAdvance = "Job.Advance";
    public const string JobCancel = "Job.Cancel";
    public const string TraceUnavailable = "Trace.Unavailable";
    public const string DebugTabs = "Debug.Tabs";
    public const string DebugUnavailable = "Debug.Unavailable";

    public static readonly IReadOnlyList<string> FixedNavigationItems =
        [NavOverview, NavHistory, NavViewer, NavJob, NavDebug, NavTrace];
}
