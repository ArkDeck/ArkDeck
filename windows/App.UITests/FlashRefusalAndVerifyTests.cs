namespace ArkDeck.App.UITests;

/// <summary>
/// ArkForge handshake refusal and flash verification exits, over scripted transports only.
/// Exit 7 is a content mismatch and exit 9 is a typed skip; neither test needs a device or archive.
/// </summary>
[TestClass]
public sealed class FlashRefusalAndVerifyTests
{
    private const string HandshakeReason = "ArkForge PROTOCOL_REFUSED: protocol major 2 is not compatible with 1";

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void HandshakeRefusalShowsTheTypedProtocolReason()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "flash-handshake", "--language", "en-US", "--page", "flash"]);
        app.Invoke("flash.workspace.details");
        Assert.AreEqual(
            strings.Format("windows.unavailable.reason", ["unsupportedProtocolVersion", HandshakeReason]),
            AppSession.Name(app.Find("flash.deviceAccess.reason")));
    }

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void VerifyExit7And9ArePresented()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        AssertVerify(exe, strings, "flash-verify-exit-7", "failed", "7");
        AssertVerify(exe, strings, "flash-verify-exit-9", "partial", "9");
    }

    private static void AssertVerify(string exe, Catalogue strings, string scenario, string outcome, string exitCode)
    {
        using var app = AppSession.Launch(exe, ["--test-transport", scenario, "--language", "en-US", "--page", "flash"]);
        app.WaitForName("flash.workspace.readiness", n => n.Length > 0);
        app.Invoke("flash.maintenance.verify");
        Assert.AreEqual(
            strings.Format("flash.maintenance.result", [outcome, exitCode]),
            app.WaitForName("flash.maintenance.result", n => n.Length > 0));
    }
}
