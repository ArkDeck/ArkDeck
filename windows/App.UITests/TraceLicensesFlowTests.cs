using System.Security.Cryptography;
using System.Text;

namespace ArkDeck.App.UITests;

/// <summary>The ordinary App in task-owned copies, with generated local resources or none.
/// No production-root override or shipping legal asset is supplied by these UI fixtures.</summary>
[TestClass]
public sealed class TraceLicensesFlowTests
{
    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TraceLicensesShowsHonestMissingResourcesWithoutACliPlaceholder()
    {
        using var fixture = new AppCopy(AppSession.RequireApp());
        var strings = Catalogue.Load("en-US");
        using var app = AppSession.Launch(fixture.Exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings"]);
        app.Select("settings.tab.trace");
        app.Select("settings.trace.section.licenses");
        var missing = strings["windows.settings.trace.licenses.unavailable"];
        Assert.AreEqual(missing, app.WaitForName("settings.trace.licenses.product", n => n == missing));
        Assert.AreEqual(missing, app.WaitForName("settings.trace.licenses.notices", n => n == missing));
        Assert.IsNull(app.TryFind("settings.trace.licenses.reveal", TimeSpan.Zero));
        Assert.IsNull(app.TryFind("settings.trace.licenses.copyCli", TimeSpan.Zero), "local license resources have no Runtime RPC or CLI substitute");
        app.Select("settings.trace.section.cache");
        app.Find("settings.trace.cache.title");
        app.Select("settings.trace.section.licenses");
        Assert.AreEqual(missing, app.WaitForName("settings.trace.licenses.product", n => n == missing));
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id}");
    }

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TraceLicensesDisplaysAndSelectsFullOriginalLocalTextWithoutWritingIt()
    {
        using var fixture = new AppCopy(AppSession.RequireApp());
        // Deliberately generated content: this proves the consumer, never Windows bundle provenance.
        const string product = "Task-only license fixture ©\r\n\r\n  Original spacing and 中文 text.\r\nLast line.\r\n";
        const string notices = "# Task-only notices\r\n\r\nComponent A — unchanged text\r\n\tIndented details\r\nEND OF NOTICE\r\n";
        fixture.LegalText(product, notices);
        var before = fixture.LegalInventory();
        using var app = AppSession.Launch(fixture.Exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings"]);
        app.Select("settings.tab.trace");
        Assert.IsNull(app.TryFind("settings.trace.licenses.product", TimeSpan.Zero), "legal content is not loaded on the cache tab");
        app.Select("settings.trace.section.licenses");
        Assert.AreEqual(product, app.WaitForName("settings.trace.licenses.product", n => n == product));
        Assert.AreEqual(notices, app.WaitForName("settings.trace.licenses.notices", n => n == notices));
        foreach (var (id, text) in new[] { ("product", product), ("notices", notices) })
        {
            var element = app.Find("settings.trace.licenses." + id);
            Assert.IsTrue(element.Patterns.Text.IsSupported, "original legal text must support native text selection");
            var range = element.Patterns.Text.Pattern.DocumentRange;
            Assert.AreEqual(text, range.GetText(-1));
            range.Select();
            var selected = element.Patterns.Text.Pattern.GetSelection();
            Assert.AreEqual(1, selected.Length);
            Assert.AreEqual(text, selected[0].GetText(-1));
        }
        Assert.IsTrue(app.Find("settings.trace.licenses.reveal").IsEnabled, "only the safe fixed local folder offers Reveal");
        Assert.IsNull(app.TryFind("settings.trace.licenses.copyCli", TimeSpan.Zero));
        app.Select("settings.trace.section.cache");
        app.Find("settings.trace.cache.title");
        app.Select("settings.trace.section.licenses");
        Assert.AreEqual(product, app.WaitForName("settings.trace.licenses.product", n => n == product));
        Assert.AreEqual(notices, app.WaitForName("settings.trace.licenses.notices", n => n == notices));
        CollectionAssert.AreEqual(before, fixture.LegalInventory(), "native UI visits must preserve original bytes, attributes and write times");
        foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id}");
    }

    private sealed class AppCopy : IDisposable
    {
        private readonly DirectoryInfo _root;
        private readonly string _app;
        private long _copiedBytes;
        private int _copiedFiles;

        internal AppCopy(string sourceExe)
        {
            sourceExe = Path.GetFullPath(sourceExe);
            var buildRoot = Path.GetFullPath(RepoPaths.At("windows", "App", "bin")) + Path.DirectorySeparatorChar;
            Assert.IsTrue(sourceExe.StartsWith(buildRoot, StringComparison.OrdinalIgnoreCase), "only this checkout's task build may be copied; never an installed RC");
            _root = Directory.CreateTempSubdirectory("arkdeck-uitest-trace-licenses-");
            _app = Path.Combine(_root.FullName, "app");
            Exe = Path.Combine(_app, Path.GetFileName(sourceExe));
            try
            {
                Copy(new DirectoryInfo(Path.GetDirectoryName(sourceExe)!), _app, top: true);
                CollectionAssert.AreEqual(SHA256.HashData(File.ReadAllBytes(sourceExe)), SHA256.HashData(File.ReadAllBytes(Exe)), "the copied App is the exact tested product image");
                Assert.IsFalse(Directory.Exists(Path.Combine(_app, "ArkTrace")));
            }
            catch { Dispose(); throw; }
        }

        internal string Exe { get; }
        private string Group => Path.Combine(_app, "ArkTrace");

        private void Copy(DirectoryInfo source, string destination, bool top = false)
        {
            Assert.IsFalse(source.Attributes.HasFlag(FileAttributes.ReparsePoint), "task build copy never follows a directory reparse point");
            Directory.CreateDirectory(destination);
            foreach (var entry in source.EnumerateFileSystemInfos())
            {
                if (top && entry.Name.Equals("ArkTrace", StringComparison.OrdinalIgnoreCase)) continue;
                Assert.IsFalse(entry.Attributes.HasFlag(FileAttributes.ReparsePoint), "task build copy never follows a reparse entry");
                var target = Path.Combine(destination, entry.Name);
                if (entry is DirectoryInfo directory) Copy(directory, target);
                else if (entry is FileInfo file)
                {
                    _copiedBytes += file.Length;
                    _copiedFiles++;
                    Assert.IsTrue(file.Length <= 256L * 1024 * 1024 && _copiedBytes <= 512L * 1024 * 1024 && _copiedFiles <= 4096, "the task build copy must remain bounded");
                    File.Copy(file.FullName, target);
                }
            }
        }

        internal void LegalText(string product, string notices)
        {
            Directory.CreateDirectory(Path.Combine(Group, "Licenses"));
            File.WriteAllBytes(Path.Combine(Group, "LICENSE"), Encoding.UTF8.GetBytes(product));
            File.WriteAllBytes(Path.Combine(Group, "THIRD_PARTY_NOTICES.md"), Encoding.UTF8.GetBytes(notices));
            foreach (var file in Directory.GetFiles(Group)) File.SetAttributes(file, FileAttributes.ReadOnly);
        }

        internal string[] LegalInventory() => Directory.GetFiles(Group).Order(StringComparer.Ordinal).Select(file =>
            Path.GetFileName(file) + ":" + Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file))) + ":" + File.GetLastWriteTimeUtc(file).Ticks + ":" + File.GetAttributes(file)).ToArray();

        public void Dispose()
        {
            if (!_root.Exists) return;
            foreach (var file in _root.EnumerateFiles("*", SearchOption.AllDirectories)) file.Attributes &= ~FileAttributes.ReadOnly;
            _root.Delete(recursive: true);
        }
    }
}
