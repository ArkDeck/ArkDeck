using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Tests;

/// <summary>Settings' App-local parts: the support bundle (macOS
/// <c>RuntimeSupportBundleApplicationFacade</c>, the Rust CLI's <c>support_bundle.rs</c>) and
/// the window icon preference (macOS <c>ApplicationIconChoice</c>).</summary>
[TestClass]
public sealed class SettingsLocalTests
{
    [TestMethod]
    public void ABundleIsPreviewedThenExportedForThatScopeOnly()
    {
        var parent = Directory.CreateTempSubdirectory("arkdeck-bundle-").FullName;
        try
        {
            var destination = Path.Combine(parent, "bundle");
            var preview = SupportBundle.Preview(destination);
            Assert.IsFalse(Directory.Exists(destination), "a preview writes nothing");
            CollectionAssert.AreEqual(new[] { "bundle.json", "hdc/tool-placeholder.json", "metadata.json" }, preview.IncludedEntries.ToArray());
            Assert.IsTrue(preview.DeviceRawExcluded);
            Assert.AreEqual(64, preview.ScopeSha256.Length);

            Assert.AreEqual("previewDrifted", Assert.ThrowsExactly<SupportBundleException>(() => SupportBundle.Export(destination, new string('0', 64))).Code);
            Assert.IsFalse(Directory.Exists(destination));

            SupportBundle.Export(destination, preview.ScopeSha256);
            var files = Directory.EnumerateFiles(destination, "*", SearchOption.AllDirectories).Select(f => Path.GetRelativePath(destination, f).Replace('\\', '/')).Order().ToArray();
            CollectionAssert.AreEqual(preview.IncludedEntries.ToArray(), files);
            Assert.AreEqual(preview.EstimatedBytes, files.Sum(f => new FileInfo(Path.Combine(destination, f)).Length), "the manifest states the bundle's size");
            var tool = (JsonObject)StrictJson.Parse(File.ReadAllBytes(Path.Combine(destination, "hdc", "tool-placeholder.json")));
            Assert.AreEqual("redacted", ((JsonString)tool["path"]).Value);
            var manifest = (JsonObject)StrictJson.Parse(File.ReadAllBytes(Path.Combine(destination, "bundle.json")));
            Assert.AreEqual(JsonBool.False, manifest["automaticUploadEnabled"]);
            Assert.AreEqual(1, Directory.EnumerateFileSystemEntries(parent).Count(), "no staging folder is left");

            Assert.AreEqual("resourceConflict", Assert.ThrowsExactly<SupportBundleException>(() => SupportBundle.Preview(destination)).Code, "never over an existing folder");
            Assert.AreEqual("invalidInput", Assert.ThrowsExactly<SupportBundleException>(() => SupportBundle.Preview("relative\\bundle")).Code);
            Assert.AreEqual("invalidInput", Assert.ThrowsExactly<SupportBundleException>(() => SupportBundle.Preview(Path.Combine(parent, "missing", "bundle"))).Code);
        }
        finally
        {
            Directory.Delete(parent, recursive: true);
        }
    }

    [TestMethod]
    public void TheIconPreferenceDefaultsToTheWaveform()
    {
        var root = Directory.CreateTempSubdirectory("arkdeck-preferences-").FullName;
        try
        {
            var preferences = new AppPreferences(root);
            Assert.AreEqual(AppIconChoice.Waveform, preferences.Icon);
            preferences.Icon = AppIconChoice.Keycap;
            Assert.AreEqual(AppIconChoice.Keycap, new AppPreferences(root).Icon);
            File.WriteAllText(Path.Combine(root, "preferences-v1.json"), """{"appIcon":"rainbow"}""");
            Assert.AreEqual(AppIconChoice.Waveform, preferences.Icon, "an unknown value is the default");
            File.WriteAllText(Path.Combine(root, "preferences-v1.json"), "not json");
            Assert.AreEqual(AppIconChoice.Waveform, preferences.Icon);
            Assert.AreEqual("Assets/AppIcon.Keycap.ico", AppPreferences.IconAsset(AppIconChoice.Keycap));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public void OnlyATestTransportRunAnswersAPickerWithoutADialog()
    {
        Assert.IsNull(LaunchOptions.Parse(["--pick-folder", @"C:\x"]).PickedFolder);
        Assert.AreEqual(@"C:\x", LaunchOptions.Parse(["--test-transport", "jobs", "--pick-folder", @"C:\x"]).PickedFolder);
        Assert.AreEqual(@"C:\p", LaunchOptions.Parse(["--preferences-root", @"C:\p"]).PreferencesRoot);
    }
}
