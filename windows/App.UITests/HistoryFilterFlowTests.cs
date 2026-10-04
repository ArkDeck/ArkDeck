namespace ArkDeck.App.UITests;

/// <summary>History's filters, older pages and saved filter through UIA patterns only, over the
/// scripted <c>history</c> daemon: Load Older appends the second page; the state filter, the
/// search and the reset narrow and restore the list with its count; the current filter is saved
/// in the Runtime, applied again after a reset, and deleted.</summary>
[TestClass]
public sealed class HistoryFilterFlowTests
{
    private const string Older = "job-0000000000000000000000000000a0f4";
    private const string Failed = "job-0000000000000000000000000000a002";

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TheListIsFilteredPagedAndItsFilterSaved()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "history", "--language", "en-US", "--page", "history"]);
        app.Find("history.row." + Failed);
        Assert.IsNull(app.TryFind("history.row." + Older, TimeSpan.FromMilliseconds(300)));
        var before = app.WaitForName("history.filter.resultCount", n => n.Length > 0);
        app.Invoke("history.loadOlder");
        app.Find("history.row." + Older);
        Assert.IsNull(app.TryFind("history.loadOlder", TimeSpan.FromMilliseconds(500)), "no page after the last");
        var all = app.WaitForName("history.filter.resultCount", n => n != before);

        app.Find("history.filter.status").Patterns.ExpandCollapse.Pattern.Expand();
        app.Select("history.filter.status.failed");
        Assert.AreEqual(strings.Format("history.filter.resultCount", ["1", all.Split(' ')[2]]), app.WaitForName("history.filter.resultCount", n => n.StartsWith("1 ", StringComparison.Ordinal)));
        app.Find("history.row." + Failed);

        // Save it in the Runtime, reset, and apply it again.
        app.Invoke("history.filter.save");
        Assert.AreEqual(strings["windows.history.filter.savedDone"], app.WaitForName("history.filter.status.line", n => n.Length > 0));
        app.Invoke("history.filter.reset");
        Assert.AreEqual(all, app.WaitForName("history.filter.resultCount", n => n == all));
        app.Invoke("history.filter.applySaved");
        app.WaitForName("history.filter.resultCount", n => n.StartsWith("1 ", StringComparison.Ordinal));

        app.Find("history.filter.search").Patterns.Value.Pattern.SetValue("no such job");
        Assert.AreEqual(strings["history.filter.empty.title"], app.WaitForName("history.filter.empty", n => n.Length > 0));
        app.Invoke("history.filter.empty.reset");
        Assert.AreEqual(all, app.WaitForName("history.filter.resultCount", n => n == all));

        app.Invoke("history.filter.deleteSaved");
        Assert.AreEqual(strings["windows.history.filter.deletedDone"], app.WaitForName("history.filter.status.line", n => n == strings["windows.history.filter.deletedDone"]));
        Assert.AreEqual(strings["windows.history.filter.savedNone"], AppSession.Name(app.Find("history.filter.saved.summary")));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    /// <summary>A record's detail sections: the summary, the journal (<c>job.show</c>), the
    /// correlation with Show related Jobs (a Session filter), and the recovery state.</summary>
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ARecordShowsItsSummaryJournalCorrelationAndRecovery()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "history"]);
        const string trace = "job-0000000000000000000000000000a003";
        app.Select("history.row." + trace);
        Assert.AreEqual("session-" + trace, app.WaitForName("history.detail.session", n => n.Length > 0));
        Assert.AreEqual(strings["history.outcome.confirmed"], AppSession.Name(app.Find("history.detail.outcomeCertainty")));
        Assert.AreEqual(strings["history.detail.timeline"], AppSession.Name(app.Find("history.detail.timeline.entries")));
        Assert.AreEqual("session-" + trace, AppSession.Name(app.Find("history.correlation.session")));
        Assert.AreEqual(strings["history.recovery.none"], AppSession.Name(app.Find("history.recovery.state")));
        app.Invoke("history.correlation.showSession");
        StringAssert.StartsWith(app.WaitForName("history.filter.resultCount", n => n.StartsWith("1 ", StringComparison.Ordinal)), "1 ");
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
