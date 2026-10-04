namespace ArkDeck.App.UITests;

/// <summary>The Job Inspector's macOS facts through UIA patterns only, over the scripted
/// <c>recovery</c> daemon: a superseded Flash names the recovery epoch that established the
/// current state and asks for no one; a capture shows its device residue and reads its standard
/// log locally (the last 200 lines).</summary>
[TestClass]
public sealed class JobInspectorFlowTests
{
    private const string Superseded = "job-0000000000000000000000000000a0f4";
    private const string Log = "job-0000000000000000000000000000a0f3";

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TheRelationTheResidueAndTheLogAreShown()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "recovery", "--language", "en-US"]);
        app.Select("jobInspector.row." + Superseded);
        Assert.AreEqual(strings["jobInspector.result.supersededByRecovery"], app.WaitForName("jobInspector.establishedCurrentEpoch.message", n => n.Length > 0));
        Assert.AreEqual("epoch-0000000000000000000000000000e001", AppSession.Name(app.Find("jobInspector.fact.recoveryRelation")));
        Assert.IsNull(app.TryFind("jobInspector.attention", TimeSpan.FromMilliseconds(300)), "an established epoch asks for no one");

        app.Select("jobInspector.row." + Log);
        Assert.AreEqual(strings.Format("jobInspector.residue", ["2"]), app.WaitForName("jobInspector.residue", n => n.Length > 0));
        app.Invoke("jobInspector.readLog.ART-00000000000000000000000000000d01");
        Assert.AreEqual("capture.log", app.WaitForName("jobInspector.log.text", n => n.Length > 0));
        Assert.AreEqual(strings["jobInspector.log.tail"], AppSession.Name(app.Find("jobInspector.log.tail")));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }
}
