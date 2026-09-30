using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;

namespace ArkDeck.App.UITests;

/// <summary>
/// The TASK-XPA-020 agent and Import actions through UIA patterns only (no synthetic input):
/// resuming a pick-a-device human action with a value of its selection schema, abandoning an
/// agent execution after its confirmation, and uploading a file chosen in the system file
/// dialog, releasing the Import, and the Runtime's flash-bundle refusal. The scripted
/// <c>jobs</c> transport answers from the recorded agent-human-action and import corpora.
/// </summary>
[TestClass]
public sealed class AgentImportFlowTests
{
    private const string Connect = "har-connect";
    private const string Ambiguous = "har-ambiguous";

    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void AHumanActionIsResumedWithOneOfItsValues()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "agents"]);
        app.Select("agents.humanAction.<har-3>");
        Assert.AreEqual(Ambiguous, app.WaitForName("agents.detail.title", n => n.Length > 0), "the action opens its execution");
        Assert.AreEqual("waitingForHuman", AppSession.Name(app.Find("agents.detail.state")));
        var choices = app.Find("agents.action.choices");
        Assert.AreEqual(strings["windows.agents.action.choose"], AppSession.Name(choices));
        var offered = choices.FindAllDescendants(cf => cf.ByControlType(ControlType.RadioButton)).Select(AppSession.Name).ToArray();
        CollectionAssert.AreEqual(new[] { new string('a', 32), new string('b', 32) }, offered, "exactly the schema's values");

        // Without a choice nothing is sent: the page says what is missing (the button stays enabled).
        app.Invoke("agents.action.resume");
        Assert.AreEqual(strings["windows.agents.action.chooseFirst"], app.WaitForName("agents.status", n => n.Length > 0));
        app.Select("agents.action.choice.<candidate-2>");
        app.Invoke("agents.action.resume");
        app.WaitForName("agents.status", n => n == strings["windows.agents.action.resumed"]);
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("agents.humanAction.<har-3>", TimeSpan.FromMilliseconds(200)) is null, "the resumed action leaves the list");
        app.WaitForName("agents.row." + Ambiguous, n => n.EndsWith("jobOwned", StringComparison.Ordinal));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
    }

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public void AnAgentExecutionIsAbandonedAfterItsConfirmation()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "agents"]);
        app.Select("agents.row.har-completed");
        app.WaitForName("agents.detail.title", n => n == "har-completed");
        Assert.IsNull(app.TryFind("agents.abandon", TimeSpan.FromMilliseconds(500)), "a terminal execution offers no abandon");

        app.Select("agents.row." + Connect);
        app.WaitForName("agents.detail.title", n => n == Connect);
        app.Invoke("agents.abandon");
        Assert.AreEqual(strings["windows.agents.abandon.title"], AppSession.Name(app.Find("agents.abandon.confirm")));
        TestContext.WriteLine(app.WaitForName("agents.abandon.message", n => n.Length > 0));
        app.Invoke("PrimaryButton");
        app.WaitForName("agents.status", n => n == strings["windows.agents.abandon.done"]);
        app.WaitForName("agents.row." + Connect, n => n.EndsWith("abandoned", StringComparison.Ordinal));
        SemanticSnapshotTests.WaitUntil(() => app.TryFind("agents.humanAction.<har-1>", TimeSpan.FromMilliseconds(200)) is null, "its human action is no longer waiting");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void AFileChosenInTheSystemDialogIsImportedAndReleased()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-import-");
        try
        {
            var hap = Path.Combine(directory.FullName, "entry.hap");
            var bytes = Enumerable.Range(0, 1_200_000).Select(i => (byte)(i * 7 % 253)).ToArray();
            "PK\u0003\u0004"u8.CopyTo(bytes);
            File.WriteAllBytes(hap, bytes);
            var flash = Path.Combine(directory.FullName, "images.tar.gz");
            File.WriteAllBytes(flash, new byte[4096]);

            using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "imports"]);
            app.Find("imports.row.imp-dcb7943f-d934-43da-b290-65d0066cae35");
            app.Invoke("imports.start");
            Assert.AreEqual(strings["windows.imports.chooseFileFirst"], app.WaitForName("imports.status", n => n.Length > 0), "no file: nothing is sent");

            Choose(app, hap);
            app.Invoke("imports.start");
            var done = app.WaitForName("imports.status", n => n.StartsWith("Imported", StringComparison.Ordinal) || n.StartsWith(strings["windows.imports.failed"], StringComparison.Ordinal));
            TestContext.WriteLine(done);
            StringAssert.StartsWith(done, "Imported entry.hap as Artifact ART-");
            // The new Import is selected and inspected.
            app.WaitForName("imports.detail.title", n => n == "entry.hap");
            Assert.AreEqual("committed", app.WaitForName("imports.detail.state", n => n.Length > 0));
            Assert.AreEqual("hap", AppSession.Name(app.Find("imports.detail.kind")));
            app.Invoke("imports.release");
            Assert.AreEqual(strings["windows.imports.release.title"], AppSession.Name(app.Find("imports.release.confirm")));
            app.Invoke("PrimaryButton");
            app.WaitForName("imports.status", n => n == strings["windows.imports.release.done"]);
            app.WaitForName("imports.detail.state", n => n == "released");

            // A flash bundle that is not an images archive is sent and refused by the Runtime's validator.
            app.Find("imports.kind").AsComboBox().Select(3);
            app.WaitForName("imports.file", n => n == strings["windows.imports.noFile"]);
            Choose(app, flash);
            app.Invoke("imports.start");
            var refused = app.WaitForName("imports.status", n => n.StartsWith(strings["windows.imports.failed"], StringComparison.Ordinal));
            Assert.AreEqual($"{strings["windows.imports.failed"]} · " + strings.Format("windows.unavailable.reason",
                ["invalidInput", "Import content failed its registered format validator"]), refused);
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    /// <summary>Chooses <paramref name="path"/> in the system file dialog the App opens (the
    /// common item dialog, driven through its UIA patterns: the file name box and Open).</summary>
    internal static void Choose(AppSession app, string path)
    {
        ChooseFile(app, "imports.chooseFile", path);
        app.WaitForName("imports.file", n => n == path);
    }

    /// <summary>Invokes <paramref name="buttonId"/> and chooses <paramref name="path"/> in the
    /// system file dialog it opens.</summary>
    internal static void ChooseFile(AppSession app, string buttonId, string path)
    {
        app.Invoke(buttonId);
        AutomationElement? dialog = null;
        SemanticSnapshotTests.WaitUntil(() => (dialog = FileDialog(app)) is not null, "the system file dialog opens");
        AutomationElement? name = null;
        SemanticSnapshotTests.WaitUntil(() => (name = dialog!.FindFirstDescendant(cf => cf.ByAutomationId("1148").And(cf.ByControlType(ControlType.Edit)))) is not null,
            "the file name box");
        name!.Patterns.Value.Pattern.SetValue(path);
        var open = dialog!.FindFirstChild(cf => cf.ByAutomationId("1").And(cf.ByControlType(ControlType.Button)))
                   ?? throw new AssertFailedException("the file dialog has no Open button");
        open.Patterns.Invoke.Pattern.Invoke();
        SemanticSnapshotTests.WaitUntil(() => FileDialog(app) is null, "the system file dialog closes");
    }

    private static AutomationElement? FileDialog(AppSession app)
    {
        try
        {
            var condition = app.Automation.ConditionFactory.ByClassName("#32770").And(app.Automation.ConditionFactory.ByProcessId(app.ProcessId));
            return app.Window.FindFirstChild(condition) ?? app.Automation.GetDesktop().FindFirstChild(condition);
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }
}
