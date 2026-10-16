using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Contract;

namespace ArkDeck.App.Tests;

[TestClass]
public sealed class ArkForgeHandshakeTests
{
    [TestMethod]
    public void FlashRefusalPreservesTypedCodeAndDaemonReason()
    {
        const string reason = "ArkForge PROTOCOL_REFUSED: protocol major 2 is not compatible with 1";
        var error = new WireError("unsupportedProtocolVersion", reason, null);
        var failure = new ControlFailure(ControlFailureKind.Remote, reason, Remote: error);
        var shown = Unavailable.From(failure, "arkdeck flash device-access");
        Assert.AreEqual("unsupportedProtocolVersion", shown.ReasonCode);
        Assert.AreEqual(reason, shown.Detail);
        Assert.AreEqual(error, shown.Failure!.Remote);
        var english = new Localizer(Resw.Lookup("en-US"), AppLanguage.English);
        StringAssert.Contains(shown.ReasonText(english), reason);
    }
}
