using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>
/// The Flash workspace through UIA patterns only (no synthetic input). Over the scripted
/// <c>flash</c> daemon (the recorded Flash oracles), a real DAYU200 archive of the flash-archive
/// corpus chosen in the system file dialog is reviewed on the host, planned by the Runtime, and
/// flashed with the one fully named button, ending with its postflight checks; over the
/// <c>jobs</c> daemon (the Windows daemon's measured answers) the same archive is reviewed and
/// the Runtime imports it and refuses its plan without a lane, with no button offered.
/// </summary>
[TestClass]
public sealed class FlashFlowTests
{
    public TestContext TestContext { get; set; } = null!;

    private static string CopyArchive(DirectoryInfo directory)
    {
        var path = Path.Combine(directory.FullName, "images.tar.gz");
        File.Copy(RepoPaths.At("rust", "tests", "fixtures", "flash-archive", "archives", "complete.tar.gz"), path);
        return path;
    }

    private static void OpenDetails(AppSession app)
    {
        var strings = Catalogue.Load("en-US");
        app.Invoke("flash.workspace.details");
        app.WaitForName("flash.workspace.details", n => n == strings["flash.workspace.details.hide"]);
        app.Find("flash.availability.status");
    }

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void AnArchiveIsReviewedPlannedAndFlashedWithTheOneNamedButton()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-flash-");
        try
        {
            var archive = CopyArchive(directory);
            using var app = AppSession.Launch(exe, ["--test-transport", "flash", "--language", "en-US", "--page", "flash"]);
            Assert.AreEqual(strings["flash.workspace.readiness.selected"], app.WaitForName("flash.workspace.readiness", n => n.Length > 0));
            Assert.IsNull(app.TryFind("flash.execute.submit", TimeSpan.FromMilliseconds(500)), "no plan, no button");

            AgentImportFlowTests.ChooseFile(app, "flash.image.choose", archive);
            app.WaitForName("flash.workspace.readiness", n => n == strings["flash.workspace.readiness.ready"]);
            Assert.AreEqual("images.tar.gz", AppSession.Name(app.Find("flash.image.value")));
            Assert.AreEqual(strings.Format("flash.workspace.action.impact", ["TGT-FIXTURE-1"]), AppSession.Name(app.Find("flash.impact.userdata")));
            var submit = app.Find("flash.execute.submit");
            Assert.AreEqual(strings["flash.workspace.action.submit"], AppSession.Name(submit), "the one fully named primary button");

            OpenDetails(app);
            Assert.AreEqual(strings["flash.availability.available"], AppSession.Name(app.Find("flash.availability.status")));
            Assert.AreEqual(strings["flash.deviceAccess.verdict.accessible"], AppSession.Name(app.Find("flash.deviceAccess.verdict")));
            app.Find("flash.bootloader.bound");
            Assert.AreEqual("9ddf625692a74679bab6af60ef9a12a662149ec98609b9bfad147a7c50c34f04", AppSession.Name(app.Find("flash.plan.digest")));
            Assert.AreEqual("c1ab01f8c7c24649080d109c481f9c034ffb73edcc62033684ac8a59875e0b12", AppSession.Name(app.Find("flash.plan.stepSetDigest")));
            Assert.AreEqual("OpenHarmony-7.0.0.36", AppSession.Name(app.Find("flash.plan.build")));
            Assert.AreEqual(strings["flash.plan.lanePlan.bundleNotInLaneStore"], app.WaitForName("flash.plan.lanePlan", n => n != strings["flash.plan.lanePlan.pending"]));

            submit.Patterns.Invoke.Pattern.Invoke();
            var result = app.WaitForName("flash.execute.terminal", n => n.Length > 0);
            TestContext.WriteLine("flash: " + result + " / " + AppSession.Name(app.Find("flash.execute.description")));
            Assert.AreEqual(strings["flash.workspace.result.success"], result);
            app.Find("flash.postflight.build.match");
            app.Find("flash.postflight.binding.match");
            StringAssert.StartsWith(AppSession.Name(app.Find("flash.execute.jobId")), "job-");
            app.Invoke("flash.workspace.result.again");
            app.WaitForName("flash.image.value", n => n == strings["flash.workspace.image.chooseTitle"]);
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TheWindowsDaemonsRefusalEndsThePreparationWithoutAButton()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-flash-");
        try
        {
            var archive = CopyArchive(directory);
            using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "flash"]);
            Assert.AreEqual(strings["flash.workspace.readiness.blocked"], app.WaitForName("flash.workspace.readiness", n => n.Length > 0));
            AgentImportFlowTests.ChooseFile(app, "flash.image.choose", archive);
            Assert.AreEqual(strings["flash.error.plan"], app.WaitForName("flash.plan.error", n => n.Length > 0));
            Assert.AreEqual("invalidInput: flash.full-restore@1 is runtime unavailable: no ArkForge lane: ARKDECK_ARKFORGE_BUNDLE_PATH is unset, "
                + "so this daemon performs no Rockchip writes. canonical ArkForge Flash refuses before authorization", AppSession.Name(app.Find("flash.plan.error.detail")));
            Assert.IsNull(app.TryFind("flash.execute.submit", TimeSpan.FromMilliseconds(500)));
            app.Find("flash.plan.retry");
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
