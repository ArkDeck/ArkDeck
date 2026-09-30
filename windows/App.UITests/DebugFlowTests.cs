using FlaUI.Core.AutomationElements;

namespace ArkDeck.App.UITests;

/// <summary>
/// The Debug workspace's five tabs through UIA patterns only (no synthetic input), over the
/// scripted <c>jobs</c> transport, which replays the recorded Swift Debug oracles: a HiLog capture,
/// a read-only template, a port rule added and deleted, a HAP lifecycle with its package chosen in
/// the system file dialog, and a native library planned, reviewed in the plan sheet and deployed.
/// </summary>
[TestClass]
public sealed class DebugFlowTests
{
    public TestContext TestContext { get; set; } = null!;

    private static AppSession Launch(string exe) => AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "debug"]);

    private static void Tab(AppSession app, string tab)
    {
        app.Select("debug.tab." + tab);
        app.Find(tab switch
        {
            "logs" => "debug.logs.start",
            "apps" => "debug.apps.run",
            "network" => "debug.network.add",
            "commands" => "debug.commands.run",
            _ => "debug.artifacts.preview",
        });
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void ALogCaptureAndATemplateRunAsTypedJobs()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = Launch(exe);
        Assert.AreEqual("TGT-FIXTURE-1", AppSession.Name(app.Find("debug.target")) is { Length: > 0 } ? app.Find("debug.target").AsComboBox().SelectedItem?.Properties.Name.ValueOrDefault : null);
        Assert.AreEqual(strings["debug.availability.available"], app.WaitForName("debug.availability.status", n => n.Length > 0));

        Tab(app, "logs");
        app.Find("debug.logs.tag").Patterns.Value.Pattern.SetValue("ArkUI");
        app.Invoke("debug.logs.start");
        var done = app.WaitForName("debug.logs.status", n => n.StartsWith("succeeded · job-", StringComparison.Ordinal));
        TestContext.WriteLine("logs: " + done);
        var jobId = done["succeeded · ".Length..];
        app.Find("debug.jobs.row." + jobId);
        Assert.AreEqual("running->succeeded", AppSession.Name(app.Find("debug.logs.viewport.3")));

        // An invalid filter is not sent: the page says which field.
        app.Find("debug.logs.pid").Patterns.Value.Pattern.SetValue("12 34");
        Tab(app, "commands");
        Tab(app, "logs");
        Assert.AreEqual(strings.Format("debug.logs.filters.invalid", ["pid"]), AppSession.Name(app.Find("debug.logs.filters.invalid")));
        app.Invoke("debug.logs.start");
        Assert.AreEqual(strings["windows.debug.needsInputs"], app.WaitForName("debug.logs.status", n => n == strings["windows.debug.needsInputs"]));

        Tab(app, "commands");
        app.Select("debug.commands.template.device.uptime");
        app.WaitForName("debug.commands.templateId", n => n == "device.uptime");
        app.Invoke("debug.commands.run");
        app.WaitForName("debug.commands.status", n => n.StartsWith("succeeded · job-", StringComparison.Ordinal));
        Assert.AreEqual("succeeded", AppSession.Name(app.Find("debug.commands.job.state")));
        Assert.AreEqual(strings["debug.commands.job.known"], AppSession.Name(app.Find("debug.commands.job.outcome")));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void APortRuleIsAddedAndDeletedThroughTheRuntime()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = Launch(exe);
        Tab(app, "network");
        app.Find("debug.network.rule.forward.9000.9001");
        app.Find("debug.network.localPort").Patterns.Value.Pattern.SetValue("80");
        Assert.AreEqual(strings["debug.network.validation.localPortOutOfRange"], app.WaitForName("debug.network.validation", n => n.Length > 0));
        app.Find("debug.network.localPort").Patterns.Value.Pattern.SetValue("9300");
        app.Find("debug.network.remotePort").Patterns.Value.Pattern.SetValue("9301");
        app.WaitForName("debug.network.validation", n => n == strings["debug.network.validation.valid"]);
        Assert.AreEqual("forward · tcp:9300 → tcp:9301", AppSession.Name(app.Find("debug.network.typedRule")));
        app.Invoke("debug.network.add");
        app.WaitForName("debug.network.status", n => n.StartsWith("succeeded · job-", StringComparison.Ordinal));
        app.Find("debug.network.rule.forward.9300.9301");
        app.Invoke("debug.network.rule.forward.9300.9301.delete");
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("debug.network.rule.forward.9300.9301", TimeSpan.FromMilliseconds(200)) is null, "the removed rule leaves the list");
    }

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void AHapAndANativeLibraryAreChosenPlannedAndRun()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-debug-");
        try
        {
            var hap = Path.Combine(directory.FullName, "entry.hap");
            var bytes = Enumerable.Range(0, 4096).Select(i => (byte)(i % 251)).ToArray();
            "PK\u0003\u0004"u8.CopyTo(bytes);
            File.WriteAllBytes(hap, bytes);
            var library = Path.Combine(directory.FullName, "libexample.so");
            File.WriteAllBytes(library, Enumerable.Range(0, 588).Select(i => (byte)i).ToArray());

            using var app = Launch(exe);
            Tab(app, "apps");
            app.Invoke("debug.apps.run");
            Assert.AreEqual(strings["debug.apps.noHAP"], app.WaitForName("debug.apps.status", n => n.Length > 0), "nothing chosen: nothing is sent");
            AgentImportFlowTests.ChooseFile(app, "debug.apps.entry.choose", hap);
            app.WaitForName("debug.apps.entry.name", n => n == "entry.hap");
            app.Find("debug.apps.bundle").Patterns.Value.Pattern.SetValue("com.example.demo");
            app.Find("debug.apps.ability").Patterns.Value.Pattern.SetValue("EntryAbility");
            app.Invoke("debug.apps.run");
            var run = app.WaitForName("debug.apps.status", n => n.StartsWith("succeeded · job-", StringComparison.Ordinal) || n.Contains("unavailable(", StringComparison.Ordinal));
            TestContext.WriteLine("apps: " + run);
            StringAssert.StartsWith(run, "succeeded · job-");
            Assert.AreEqual("com.example.alpha", app.WaitForName("debug.apps.inventory.com.example.alpha", n => n.Length > 0).Split(' ')[0]);

            Tab(app, "artifacts");
            AgentImportFlowTests.ChooseFile(app, "debug.artifacts.chooseLibrary", library);
            app.WaitForName("debug.artifacts.selectedLibrary", n => n == "libexample.so");
            app.Find("debug.artifacts.bundle").Patterns.Value.Pattern.SetValue("com.example.demo");
            app.Invoke("debug.artifacts.preview");
            var sheet = app.Find("debug.artifacts.sheet");
            Assert.AreEqual(strings["debug.artifacts.sheet.title"], AppSession.Name(sheet));
            Assert.AreEqual("600694d55fd146f2ddc3a8c7541f517f77a9a1f6b72f914be43dda94d0f3dc1a", AppSession.Name(app.Find("debug.artifacts.sheet.digest")));
            app.Find("debug.artifacts.sheet.step.verify-elf-locally");
            app.Invoke("PrimaryButton");
            app.WaitForName("debug.artifacts.status", n => n == strings["debug.artifacts.verified"]);
            Assert.AreEqual("arm64-v8a · ELF64 · machine 183", AppSession.Name(app.Find("debug.artifacts.plan.elf")));
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
