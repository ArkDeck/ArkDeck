using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.App.UITests;

/// <summary>Actual Save/Folder common item dialogs, restricted to the App's own PID.
/// The scripted transport and task-owned outputs prove software behavior, never hardware.</summary>
[TestClass]
public sealed class NativePanelsFlowTests
{
    private const string TraceJob = "job-0000000000000000000000000000a003";
    private const string TraceArtifact = "ART-00000000000000000000000000000c01";

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void NativeSaveCancelWritesNothingAndConfirmedExportPreservesWholeArtifact()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var output = new TaskFolder();
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "history"]);
        app.Select("history.row." + TraceJob);
        app.Find("history.artifact.export." + TraceArtifact);
        // The published scripted product deliberately spans more than one artifact.read chunk.
        var expected = Enumerable.Range(0, 300_000).Select(i => (byte)(i * 31 % 251)).ToArray();
        var expectedSha = Sha256(expected);
        var destination = Path.Combine(output.Root, "exported-trace.htrace");
        OpenSavePreview(app, strings, expectedSha);
        var dialog = WaitDialog(app);
        Filename(dialog).Patterns.Value.Pattern.SetValue(destination);
        DialogButton(dialog, "2").Patterns.Invoke.Pattern.Invoke();
        WaitClosed(app);
        Assert.IsFalse(File.Exists(destination), "cancelled native Save must not create its selected output");
        CollectionAssert.AreEqual(output.InitialInventory, output.Inventory());
        Assert.IsNull(app.TryFind("history.artifact.exporting." + TraceArtifact, TimeSpan.FromMilliseconds(300)), "cancelled Save never enters the observable export phase");
        Assert.IsNull(app.TryFind("history.artifact.exported." + TraceArtifact, TimeSpan.Zero));

        OpenSavePreview(app, strings, expectedSha);
        dialog = WaitDialog(app);
        Filename(dialog).Patterns.Value.Pattern.SetValue(destination);
        DialogButton(dialog, "1").Patterns.Invoke.Pattern.Invoke();
        WaitClosed(app);
        app.WaitForName("history.artifact.exported." + TraceArtifact, n => n.Contains(destination, StringComparison.Ordinal));
        app.Find("history.artifact.explorer." + TraceArtifact);
        var actual = File.ReadAllBytes(destination);
        Assert.AreEqual(expected.Length, actual.Length);
        Assert.AreEqual(expectedSha, Sha256(actual));
        CollectionAssert.AreEqual(expected, actual, "the whole sensitive Artifact, not a preview or first chunk, was saved");
        CollectionAssert.AreEqual(new[] { "exported-trace.htrace", "sentinel.txt" }, output.Inventory());
        output.AssertSentinel();
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void NativeFolderCancelAndPreviewWriteNothingBeforeExplicitBoundedExport()
    {
        var exe = AppSession.RequireApp();
        var strings = Catalogue.Load("en-US");
        using var output = new TaskFolder();
        // No --pick-folder argument: Settings must invoke its actual native FolderPicker.
        using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings"]);
        app.Select("settings.tab.diagnostics");
        app.Invoke("settings.diagnostics.preview");
        DialogButton(WaitDialog(app), "2").Patterns.Invoke.Pattern.Invoke();
        WaitClosed(app);
        CollectionAssert.AreEqual(output.InitialInventory, output.Inventory(), "folder cancellation creates no output or staging entry");
        Assert.IsNull(app.TryFind("settings.diagnostics.destination", TimeSpan.FromMilliseconds(300)));
        Assert.IsNull(app.TryFind("settings.diagnostics.exportNow", TimeSpan.Zero));

        app.Invoke("settings.diagnostics.preview");
        var dialog = WaitDialog(app);
        FolderName(dialog).Patterns.Value.Pattern.SetValue(output.Root);
        DialogButton(dialog, "1").Patterns.Invoke.Pattern.Invoke();
        WaitClosed(app);
        var destination = app.WaitForName("settings.diagnostics.destination", n => n.Length > 0);
        Assert.AreEqual(Path.GetFullPath(output.Root), Path.GetDirectoryName(Path.GetFullPath(destination)), "the native choice is this exact task-owned parent");
        StringAssert.StartsWith(Path.GetFileName(destination), "ArkDeck-Diagnostics-");
        var scope = app.WaitForName("settings.diagnostics.scopeHash", n => n.Length == 64);
        Assert.IsTrue(scope.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f'));
        Assert.AreEqual(strings["settings.diagnostics.excluded"], AppSession.Name(app.Find("settings.diagnostics.deviceRaw")));
        string[] entries = ["bundle.json", "hdc/tool-placeholder.json", "metadata.json"];
        foreach (var entry in entries) Assert.AreEqual(entry, AppSession.Name(app.Find("settings.diagnostics.entry." + entry + ".name")));
        Assert.IsFalse(Directory.Exists(destination), "preview is read-only, even after a real native folder choice");
        CollectionAssert.AreEqual(output.InitialInventory, output.Inventory());
        app.Invoke("settings.diagnostics.exportNow");
        app.WaitForName("settings.diagnostics.status", n => n == strings["settings.diagnostics.exported"]);
        app.Find("settings.diagnostics.reveal");
        VerifySupportBundle(destination, output.Root, scope, entries);
        CollectionAssert.AreEqual(new[] { Path.GetFileName(destination)!, "sentinel.txt" }.Order(StringComparer.Ordinal).ToArray(), output.Inventory(), "only the approved output folder was published");
        output.AssertSentinel();
    }

    private static void OpenSavePreview(AppSession app, Catalogue strings, string digest)
    {
        app.Invoke("history.artifact.export." + TraceArtifact);
        var message = app.WaitForName("history.artifacts.exportPreview.message", n => n.Contains(digest, StringComparison.Ordinal));
        StringAssert.Contains(message, "trace.htrace");
        StringAssert.Contains(message, "sensitive");
        Assert.AreEqual(strings["history.artifacts.exportSensitive"], AppSession.Name(app.Find("PrimaryButton")));
        app.Invoke("PrimaryButton");
    }

    private static AutomationElement WaitDialog(AppSession app)
    {
        AutomationElement? dialog = null;
        SemanticSnapshotTests.WaitUntil(() => (dialog = FindDialog(app)) is not null, "the App's native common item dialog opens");
        return dialog!;
    }

    private static void WaitClosed(AppSession app) => SemanticSnapshotTests.WaitUntil(() => FindDialog(app) is null, "the App's native dialog closes");

    private static AutomationElement? FindDialog(AppSession app)
    {
        try
        {
            var condition = app.Automation.ConditionFactory.ByClassName("#32770").And(app.Automation.ConditionFactory.ByProcessId(app.ProcessId));
            var dialog = app.Window.FindFirstChild(condition) ?? app.Automation.GetDesktop().FindFirstChild(condition);
            if (dialog is not null) Assert.AreEqual(app.ProcessId, dialog.Properties.ProcessId.Value);
            return dialog;
        }
        catch (COMException) { return null; }
    }

    private static AutomationElement Filename(AutomationElement dialog)
    {
        AutomationElement? name = null;
        try
        {
            // This WinRT Save dialog exposes this exact host and nested edit;
            // their SearchEditBox and file-list property edits are unrelated.
            SemanticSnapshotTests.WaitUntil(() => (name = dialog.FindFirstDescendant(cf => cf.ByAutomationId("FileNameControlHost").And(cf.ByControlType(ControlType.ComboBox)))
                ?.FindFirstDescendant(cf => cf.ByAutomationId("1001").And(cf.ByControlType(ControlType.Edit)))) is not null,
                "the native Save filename field");
        }
        catch (AssertFailedException)
        {
            // Bounded control metadata of this App-owned dialog only. Never log names,
            // values, paths, or the user's file inventory while diagnosing a selector.
            foreach (var field in dialog.FindAllDescendants().Where(e => e.ControlType is ControlType.Edit or ControlType.ComboBox)
                         .Where(e => e.ClassName != "UIProperty").Take(20))
                Console.WriteLine($"native field: id={field.AutomationId}; type={field.ControlType}; class={field.ClassName}; valuePattern={field.Patterns.Value.IsSupported}");
            throw;
        }
        return name!;
    }

    private static AutomationElement FolderName(AutomationElement dialog)
    {
        AutomationElement? name = null;
        // The FolderPicker has its own exact folder edit. SearchEditBox is unrelated.
        SemanticSnapshotTests.WaitUntil(() => (name = dialog.FindFirstDescendant(cf => cf.ByAutomationId("1152").And(cf.ByControlType(ControlType.Edit)))) is not null,
            "the native FolderPicker folder field");
        return name!;
    }

    private static AutomationElement DialogButton(AutomationElement dialog, string id) =>
        dialog.FindFirstChild(cf => cf.ByAutomationId(id).And(cf.ByControlType(ControlType.Button)))
        ?? throw new AssertFailedException("the App-owned native dialog lacks button " + id);

    private static string Sha256(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    private static void VerifySupportBundle(string destination, string parent, string scope, string[] entries)
    {
        var files = Directory.GetFiles(destination, "*", SearchOption.AllDirectories)
            .Select(path => Path.GetRelativePath(destination, path).Replace('\\', '/')).Order(StringComparer.Ordinal).ToArray();
        CollectionAssert.AreEqual(entries, files, "fixed documents only: no raw, log, Session, credentials or unrelated files");
        var manifestBytes = File.ReadAllBytes(Path.Combine(destination, "bundle.json"));
        var metadataBytes = File.ReadAllBytes(Path.Combine(destination, "metadata.json"));
        var toolBytes = File.ReadAllBytes(Path.Combine(destination, "hdc", "tool-placeholder.json"));
        using var manifest = JsonDocument.Parse(manifestBytes);
        using var metadata = JsonDocument.Parse(metadataBytes);
        using var tool = JsonDocument.Parse(toolBytes);
        var root = manifest.RootElement;
        ExactKeys(root, ["automaticUploadEnabled", "generatedAt", "preview", "schemaVersion", "tool"]);
        Assert.AreEqual("1.0.0", root.GetProperty("schemaVersion").GetString());
        Assert.IsFalse(root.GetProperty("automaticUploadEnabled").GetBoolean());
        Assert.IsTrue(DateTimeOffset.TryParseExact(root.GetProperty("generatedAt").GetString(), "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out _));
        var preview = root.GetProperty("preview");
        ExactKeys(preview, ["deviceRawExcluded", "estimatedBytes", "includedEntries", "scopeSHA256", "sensitiveDataWarning"]);
        Assert.IsTrue(preview.GetProperty("deviceRawExcluded").GetBoolean());
        Assert.AreEqual(scope, preview.GetProperty("scopeSHA256").GetString());
        CollectionAssert.AreEqual(entries, preview.GetProperty("includedEntries").EnumerateArray().Select(v => v.GetString()!).ToArray());
        Assert.AreEqual((long)manifestBytes.Length + metadataBytes.Length + toolBytes.Length, preview.GetProperty("estimatedBytes").GetInt64());
        Assert.IsTrue(preview.GetProperty("estimatedBytes").GetInt64() <= 32 * 1024 * 1024);
        Assert.IsFalse(string.IsNullOrEmpty(preview.GetProperty("sensitiveDataWarning").GetString()));
        ExactKeys(metadata.RootElement, ["appName", "appVersion", "architecture", "buildVersion", "platform"]);
        Assert.AreEqual("ArkDeck", metadata.RootElement.GetProperty("appName").GetString());
        Assert.AreEqual("x86_64", metadata.RootElement.GetProperty("architecture").GetString());
        StringAssert.StartsWith(metadata.RootElement.GetProperty("platform").GetString()!, "Windows ");
        foreach (var key in new[] { "appVersion", "buildVersion" }) Assert.IsFalse(string.IsNullOrEmpty(metadata.RootElement.GetProperty(key).GetString()));
        ExactKeys(tool.RootElement, ["path", "serverEndpoint", "serverOwnership", "version"]);
        foreach (var key in new[] { "path", "serverEndpoint" }) Assert.AreEqual("redacted", tool.RootElement.GetProperty(key).GetString());
        foreach (var key in new[] { "serverOwnership", "version" }) Assert.AreEqual("unverified", tool.RootElement.GetProperty(key).GetString());
        Assert.AreEqual(tool.RootElement.GetRawText(), root.GetProperty("tool").GetRawText());
        var (volume, index) = DirectoryIdentity(parent);
        var canonicalScope = Path.TrimEndingDirectorySeparator(Path.GetFullPath(destination)) + "\nparent-device:" + volume + "\nparent-inode:" + index + "\n"
            + "hdc/tool-placeholder.json\0" + Sha256(toolBytes) + "\n" + "metadata.json\0" + Sha256(metadataBytes) + "\n";
        Assert.AreEqual(scope, Sha256(Encoding.UTF8.GetBytes(canonicalScope)), "the native folder choice and every whole document bind the approved digest");
    }

    private static void ExactKeys(JsonElement value, string[] keys) => CollectionAssert.AreEqual(keys,
        value.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).ToArray());

    private static (uint Volume, ulong Index) DirectoryIdentity(string parent)
    {
        using var handle = CreateFile(parent, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        Assert.IsFalse(handle.IsInvalid);
        Assert.IsTrue(GetFileInformationByHandle(handle, out var info));
        return (info.Volume, ((ulong)info.IndexHigh << 32) | info.IndexLow);
    }

    private sealed class TaskFolder : IDisposable
    {
        private readonly DirectoryInfo _directory = Directory.CreateTempSubdirectory("arkdeck-uitest-native-panels-");
        private readonly string _sentinel = Guid.NewGuid().ToString("N");
        internal TaskFolder()
        {
            File.WriteAllText(Path.Combine(Root, "sentinel.txt"), _sentinel, new UTF8Encoding(false));
            InitialInventory = Inventory();
        }
        internal string Root => _directory.FullName;
        internal string[] InitialInventory { get; }
        internal string[] Inventory() => Directory.GetFileSystemEntries(Root).Select(path => Path.GetFileName(path)!).Order(StringComparer.Ordinal).ToArray();
        internal void AssertSentinel() => Assert.AreEqual(_sentinel, File.ReadAllText(Path.Combine(Root, "sentinel.txt"), Encoding.UTF8));
        public void Dispose()
        {
            var resolved = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Root));
            Assert.AreEqual(_directory.FullName, resolved);
            Assert.IsTrue(Path.GetFileName(resolved).StartsWith("arkdeck-uitest-native-panels-", StringComparison.Ordinal));
            Assert.IsFalse(_directory.Attributes.HasFlag(FileAttributes.ReparsePoint));
            var remaining = new Stack<DirectoryInfo>();
            remaining.Push(_directory);
            while (remaining.TryPop(out var directory))
                foreach (var entry in directory.EnumerateFileSystemInfos())
                {
                    Assert.IsFalse(entry.Attributes.HasFlag(FileAttributes.ReparsePoint), "cleanup refuses any unexpected reparse entry before traversal");
                    if (entry is DirectoryInfo child) remaining.Push(child);
                }
            _directory.Delete(recursive: true); // Only the exact fresh task-owned tree checked above.
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes, CreateLow, CreateHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume,
            SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
}
