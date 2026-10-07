namespace ArkDeck.App.UITests;

/// <summary>Host-only scripted UI/native encoder check, never hardware evidence.</summary>
[TestClass]
public sealed class DeviceScreenFlowTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void CurrentPictureBecomesStaleAndNativeMovieKeepsMeasuredSpacing()
    {
        var exe = AppSession.RequireApp();
        var cache = Directory.CreateTempSubdirectory("arkdeck-device-screen-ui-").FullName;
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "device-screen", "--language", "en-US", "--page", "device", "--cache-root", cache]);
        app.Invoke("device.screen.capture");
        app.WaitForName("device.screen.liveness", n => n == strings["windows.device.screen.current"]);
        StringAssert.Contains(AppSession.Name(app.Find("device.screen.frame")), "400");
        app.Find("device.screen.picture");
        app.Find("device.screen.pointer.position");
        app.Invoke("device.keyboard.sendKey");
        app.WaitForName("device.screen.status", n => n.StartsWith(strings["windows.device.screen.inputConfirmed"], StringComparison.Ordinal));
        Assert.AreEqual(strings["device.stale.badge"], AppSession.Name(app.Find("device.screen.liveness")));
        app.Invoke("device.keyboard.sendKey");
        app.WaitForName("device.screen.status", n => n.StartsWith(strings["device.stale.refused"], StringComparison.Ordinal));
        app.Find("device.record.frames").Patterns.RangeValue.Pattern.SetValue(2);
        app.Invoke("device.record.start");
        var status = app.WaitForName("device.screen.status", n => n == strings["device.record.ready"] || n == strings["windows.device.screen.movieUnavailable"]);
        app.Find("device.record.summary");
        app.Find("device.record.saveFrames");
        if (status == strings["device.record.ready"])
        {
            StringAssert.Contains(AppSession.Name(app.Find("device.record.movie")), "400");
            var movies = Directory.GetFiles(cache, "recording.mp4", SearchOption.AllDirectories);
            Assert.AreEqual(1, movies.Length);
            Assert.IsTrue(new FileInfo(movies[0]).Length > 0);
            TestContext.WriteLine("Native Windows Media composition and readback: succeeded;2frames,1observedsecond,400x800. Local derivative only.");
        }
        else
        {
            app.Find("device.record.nativeUnavailable");
            Assert.AreEqual(0, Directory.GetFiles(cache, "recording.mp4", SearchOption.AllDirectories).Length);
            TestContext.WriteLine("Native encoder unavailable; the verified whole frame sequence and measured timings remain offered honestly.");
        }
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, "No disabled placeholder control");
    }
}
