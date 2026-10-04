namespace ArkDeck.App.UITests;

/// <summary>
/// Debug's reviewed library deployment queue (macOS #2466) through UIA patterns only, over the
/// scripted <c>jobs</c> daemon: two libraries chosen in the system file dialog are added to the
/// queue, Validate and review prepares a plan for each against the Target and bundle, the review
/// lists both, and Deploy runs them in turn to verified success; removing one invalidates the
/// review.
/// </summary>
[TestClass]
public sealed class DebugQueueFlowTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TwoLibrariesAreReviewedAndDeployedInTurn()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-queue-");
        try
        {
            var first = Path.Combine(directory.FullName, "libexample.so");
            var second = Path.Combine(directory.FullName, "libsecond.so");
            File.WriteAllBytes(first, Enumerable.Range(0, 588).Select(i => (byte)i).ToArray());
            File.WriteAllBytes(second, Enumerable.Range(0, 588).Select(i => (byte)i).ToArray());

            using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "debug"]);
            app.Select("debug.tab.artifacts");
            app.Find("debug.artifacts.bundle").Patterns.Value.Pattern.SetValue("com.example.demo");
            foreach (var (file, name) in new[] { (first, "libexample.so"), (second, "libsecond.so") })
            {
                AgentImportFlowTests.ChooseFile(app, "debug.artifacts.chooseLibrary", file);
                app.WaitForName("debug.artifacts.selectedLibrary", n => n == name);
                app.Invoke("debug.artifacts.batch.add");
                app.Find("debug.artifacts.batch.row." + name);
            }
            app.Invoke("debug.artifacts.batch.prepare");
            var review = app.Find("debug.artifacts.batch.review");
            Assert.AreEqual(strings["debug.artifacts.batch.review"], AppSession.Name(review));
            app.Find("debug.artifacts.batch.review.libexample.so");
            app.Find("debug.artifacts.batch.review.libsecond.so");
            app.Invoke("PrimaryButton");
            var done = app.WaitForName("debug.artifacts.batch.status", n => n == strings["debug.artifacts.batch.phase.succeeded"] || n == strings["debug.artifacts.batch.phase.failed"]);
            TestContext.WriteLine("queue: " + done + " / " + (app.TryFind("debug.artifacts.batch.failure", TimeSpan.FromMilliseconds(300)) is { } f ? AppSession.Name(f) : ""));
            Assert.AreEqual(strings["debug.artifacts.batch.phase.succeeded"], done);
            Assert.AreEqual(strings["debug.artifacts.batch.row.succeeded"], AppSession.Name(app.Find("debug.artifacts.batch.row.libsecond.so.state")));
            StringAssert.StartsWith(AppSession.Name(app.Find("debug.artifacts.batch.row.libexample.so.job")), "job-");

            app.Invoke("debug.artifacts.batch.remove.libsecond.so");
            Assert.IsNull(app.TryFind("debug.artifacts.batch.row.libsecond.so", TimeSpan.FromSeconds(1)));
            Assert.AreEqual(strings["debug.artifacts.batch.phase.stopped"], app.WaitForName("debug.artifacts.batch.status", n => n.Length > 0));
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
