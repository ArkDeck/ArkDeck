using ArkDeck.Spk4.Fixtures;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace ArkDeck.Spk4.Tests;

[TestClass]
public sealed class FixtureTests
{
    [TestMethod]
    public void HistoryFixtureHasTenThousandDeterministicUniqueRows()
    {
        var a = HistoryFixture.Generate();
        var b = HistoryFixture.Generate();
        Assert.HasCount(10_000, a);
        CollectionAssert.AreEqual(a.ToList(), b.ToList());
        Assert.AreEqual(a.Count, a.Select(r => r.JobId).Distinct().Count());
    }

    [TestMethod]
    public void ViewerFixtureHasTwentyThousandNodes()
    {
        var root = ViewerFixture.Generate();
        var flat = ViewerFixture.Flatten(root);
        Assert.HasCount(20_000, flat);
        Assert.AreEqual(20_000, ViewerFixture.Count(root));
        Assert.AreEqual(0, flat[0].Id, "pre-order starts at the root");
        Assert.IsGreaterThanOrEqualTo(6, ViewerFixture.MaxDepth(root));
        Assert.AreEqual(flat.Count, flat.Select(n => n.Id).Distinct().Count());
    }

    [TestMethod]
    public void PercentileIsNearestRank()
    {
        var sample = Enumerable.Range(1, 100).Select(i => (double)i).Reverse().ToList();
        Assert.AreEqual(50, FrameStats.Percentile(sample, 50));
        Assert.AreEqual(95, FrameStats.Percentile(sample, 95));
        Assert.AreEqual(100, FrameStats.Percentile(sample, 100));
        Assert.AreEqual(1, FrameStats.Percentile(sample, 0));
    }

    [TestMethod]
    public void FrameSummaryAppliesTheH4aThreshold()
    {
        var smooth = Enumerable.Repeat(16.7, 95).Concat(Enumerable.Repeat(40.0, 5)).ToList();
        var janky = Enumerable.Repeat(16.7, 94).Concat(Enumerable.Repeat(40.0, 6)).ToList();
        Assert.IsTrue(FrameStats.Summarize(smooth).PassesH4a);
        Assert.IsFalse(FrameStats.Summarize(janky).PassesH4a);
        Assert.AreEqual(6, FrameStats.Summarize(janky).Over33);
    }

    [TestMethod]
    public void JobStateIsNeverColourOnly()
    {
        var states = Enum.GetValues<FixtureJobState>();
        Assert.AreEqual(states.Length, states.Select(FixtureJobStates.Label).Distinct().Count(), "distinct text per state");
        Assert.AreEqual(states.Length, states.Select(FixtureJobStates.Glyph).Distinct().Count(), "distinct glyph per state");
    }

    [TestMethod]
    public void CancelIsOfferedOnlyForLiveJobs()
    {
        Assert.IsTrue(FixtureJobStates.CanCancel(FixtureJobState.Running));
        Assert.IsTrue(FixtureJobStates.CanCancel(FixtureJobState.WaitingForHuman));
        Assert.IsFalse(FixtureJobStates.CanCancel(FixtureJobState.Succeeded));
        Assert.IsFalse(FixtureJobStates.CanCancel(FixtureJobState.Unknown), "unknown is never cancelled");
    }
}
