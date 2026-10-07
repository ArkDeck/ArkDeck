using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using ArkDeck.App.Core.Presentation;
using Microsoft.Win32.SafeHandles;

namespace ArkDeck.App.Tests;

/// <summary>Actual task-private files and native no-follow handles; no App package or Runtime state.</summary>
[TestClass]
public sealed class TraceLicenseTests
{
    [TestMethod]
    public async Task ConstructionIsLazyAndConcurrentVisitsShareOneRead()
    {
        var calls = 0;
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var expected = new TraceLicenseSnapshot(new(TraceLicenseStatus.Available, "original license"), new(TraceLicenseStatus.Unavailable, Reason: "missing"), false);
        var model = new TraceLicenses(() =>
        {
            Interlocked.Increment(ref calls);
            entered.Set();
            if (!release.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException("fixture release missing");
            return expected;
        });
        Assert.AreEqual(0, calls);
        Assert.AreEqual(TraceLicenseStatus.Loading, model.Snapshot.Product.Status);
        Assert.IsFalse(model.Snapshot.CanReveal);
        var first = model.LoadAsync();
        try
        {
            Assert.IsTrue(entered.Wait(TimeSpan.FromSeconds(5)));
            Assert.AreSame(first, model.LoadAsync(), "second visits cannot reread or substitute another source");
            Assert.AreEqual(TraceLicenseStatus.Loading, model.Snapshot.Notices.Status);
        }
        finally { release.Set(); }
        Assert.AreEqual(expected, await first);
        Assert.AreSame(first, model.LoadAsync());
        Assert.AreEqual(expected, model.Snapshot);
        Assert.AreEqual(1, calls);
    }

    [TestMethod]
    public async Task MissingWindowsGroupNeverReadsSiblingMacOrWorkingDirectoryNotices()
    {
        using var fixture = new Files();
        var decoy = Path.Combine(fixture.Root, "Mac", "ArkTrace");
        Directory.CreateDirectory(decoy);
        File.WriteAllText(Path.Combine(decoy, "LICENSE"), "not the Windows App's license");
        File.WriteAllText(Path.Combine(fixture.App, "LICENSE"), "not the ArkTrace group");
        var model = TraceLicenses.At(fixture.App);
        var result = await model.LoadAsync();
        Assert.AreEqual(TraceLicenseStatus.Unavailable, result.Product.Status);
        Assert.AreEqual("missing", result.Product.Reason);
        Assert.IsNull(result.Product.Text);
        Assert.AreEqual(TraceLicenseStatus.Unavailable, result.Notices.Status);
        Assert.IsFalse(result.CanReveal);
        Assert.IsNull(model.OpenLicenseFolder());
        CollectionAssert.AreEqual(new[] { "LICENSE" }, Directory.GetFiles(fixture.App).Select(Path.GetFileName).ToArray());
    }

    [TestMethod]
    public async Task FullRawUtf8ContentIsReadIndependentlyWithoutWritingOrTranslation()
    {
        using var fixture = new Files();
        const string license = "MIT 原文\r\n\n  verbatim © text\t\n";
        const string notices = "# Notices\n\nOriginal component text\r\n尾部\n";
        fixture.Write("LICENSE", Encoding.UTF8.GetBytes(license));
        fixture.Write("THIRD_PARTY_NOTICES.md", Encoding.UTF8.GetBytes(notices));
        Directory.CreateDirectory(Path.Combine(fixture.Group, "Licenses"));
        var before = fixture.Inventory();
        var result = await TraceLicenses.At(fixture.App).LoadAsync();
        Assert.AreEqual((TraceLicenseStatus.Available, license), (result.Product.Status, result.Product.Text));
        Assert.AreEqual((TraceLicenseStatus.Available, notices), (result.Notices.Status, result.Notices.Text));
        Assert.IsTrue(result.CanReveal);
        CollectionAssert.AreEqual(before, fixture.Inventory(), "original content, paths, timestamps and attributes are unchanged");

        File.Delete(Path.Combine(fixture.Group, "LICENSE"));
        var partial = await TraceLicenses.At(fixture.App).LoadAsync();
        Assert.AreEqual(TraceLicenseStatus.Unavailable, partial.Product.Status);
        Assert.AreEqual(notices, partial.Notices.Text, "one missing resource cannot hide another valid original document");
    }

    [TestMethod]
    public void DirectoriesEmptyFilesAndInvalidUtf8NeverBecomeLegalText()
    {
        using var fixture = new Files();
        Directory.CreateDirectory(Path.Combine(fixture.Group, "LICENSE"));
        var directory = TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product);
        Assert.AreEqual(TraceLicenseStatus.Unavailable, directory.Status);
        Assert.AreEqual("nonRegularFile", directory.Reason);
        Directory.Delete(Path.Combine(fixture.Group, "LICENSE"));
        fixture.Write("LICENSE", []);
        Assert.AreEqual("invalidSize", TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product).Reason);
        fixture.Write("LICENSE", [0xc3, 0x28]);
        Assert.AreEqual("invalidUtf8", TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product).Reason);
        fixture.Write("LICENSE", [0xff, 0xfe, 0x61, 0x00]);
        Assert.AreEqual("invalidUtf8", TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product).Reason, "UTF-16 is not silently decoded as UTF-8");
    }

    [TestMethod]
    public void BothDocumentsRemainBoundToOneHeldSourceGroup()
    {
        using var fixture = new Files();
        fixture.Write("LICENSE", "first original"u8.ToArray());
        fixture.Write("THIRD_PARTY_NOTICES.md", "second original"u8.ToArray());
        var attempted = false;
        var result = TraceLicenseFiles.Load(fixture.App, () =>
        {
            attempted = true;
            Assert.ThrowsExactly<IOException>(() => Directory.Move(fixture.Group, fixture.Group + "-replaced"));
        });
        Assert.IsTrue(attempted);
        Assert.AreEqual("first original", result.Product.Text);
        Assert.AreEqual("second original", result.Notices.Text);
    }

    [TestMethod]
    public void ExactByteBoundsApplyBeforeAnyContentIsReturned()
    {
        using var fixture = new Files();
        foreach (var (name, document, maximum) in new[]
                 {
                     ("LICENSE", TraceLicenseFiles.Document.Product, 32 * 1024),
                     ("THIRD_PARTY_NOTICES.md", TraceLicenseFiles.Document.Notices, 128 * 1024),
                 })
        {
            fixture.Write(name, Encoding.UTF8.GetBytes(new string('x', maximum)));
            Assert.AreEqual(maximum, TraceLicenseFiles.Read(fixture.App, document).Text!.Length);
            fixture.Write(name, Encoding.UTF8.GetBytes(new string('x', maximum + 1)));
            var tooLarge = TraceLicenseFiles.Read(fixture.App, document);
            Assert.AreEqual(TraceLicenseStatus.Unavailable, tooLarge.Status);
            Assert.AreEqual("invalidSize", tooLarge.Reason);
            Assert.IsNull(tooLarge.Text);
        }
        // Limits are bytes, not characters; 16,385 two-byte letters exceed the 32 KiB LICENSE bound.
        fixture.Write("LICENSE", Encoding.UTF8.GetBytes(new string('é', 16_385)));
        Assert.AreEqual("invalidSize", TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product).Reason);
    }

    [TestMethod]
    public void RelativeTraversalNamespaceAndAlternateStreamRootsAreRefused()
    {
        using var fixture = new Files();
        fixture.Write("LICENSE", "actual license"u8.ToArray());
        foreach (var root in new[] { ".", "ArkTrace", fixture.App + "\\..\\App", fixture.App + ":stream", @"\\?\" + fixture.App, @"\\localhost\c$\App", fixture.App + " " })
        {
            var result = TraceLicenseFiles.Read(root, TraceLicenseFiles.Document.Product);
            Assert.AreEqual(TraceLicenseStatus.Unavailable, result.Status, root);
            Assert.IsNull(result.Text);
            Assert.IsNull(TraceLicenseFiles.OpenLicenseFolder(root));
        }
    }

    [TestMethod]
    public void AReadOnlySnapshotDeniesConcurrentWritesAndReplacement()
    {
        using var fixture = new Files();
        fixture.Write("LICENSE", "unchanged original"u8.ToArray());
        var path = Path.Combine(fixture.Group, "LICENSE");
        var before = fixture.Inventory();
        var attempted = false;
        var result = TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product, () =>
        {
            attempted = true;
            Assert.ThrowsExactly<IOException>(() => File.WriteAllText(path, "replacement"));
            Assert.ThrowsExactly<IOException>(() => File.Move(path, path + ".moved"));
            Assert.ThrowsExactly<IOException>(() => Directory.Move(fixture.Group, fixture.Group + "-moved"));
        });
        Assert.IsTrue(attempted);
        Assert.AreEqual("unchanged original", result.Text);
        CollectionAssert.AreEqual(before, fixture.Inventory());
        File.SetAttributes(path, FileAttributes.ReadOnly);
        Assert.AreEqual("unchanged original", TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product).Text, "the consumer needs no write grant");
        File.SetAttributes(path, FileAttributes.Normal);
    }

    [TestMethod]
    public async Task RevealRevalidatesTheDirectoryInsteadOfTrustingTheCachedPath()
    {
        using var fixture = new Files();
        fixture.Write("LICENSE", "original"u8.ToArray());
        var licenses = Path.Combine(fixture.Group, "Licenses");
        Directory.CreateDirectory(licenses);
        var model = TraceLicenses.At(fixture.App);
        Assert.IsTrue((await model.LoadAsync()).CanReveal);
        using (var folder = model.OpenLicenseFolder())
        {
            Assert.IsNotNull(folder);
            StringAssert.EndsWith(folder.Path, "\\ArkTrace\\Licenses");
            Assert.ThrowsExactly<IOException>(() => Directory.Move(licenses, licenses + "-moved"));
        }
        Directory.Delete(licenses);
        File.WriteAllText(licenses, "not a folder");
        Assert.IsNull(model.OpenLicenseFolder());
    }

    [TestMethod]
    public void AChangedDescriptorSnapshotIsRefusedWithoutReturningPartialText()
    {
        using var fixture = new Files();
        fixture.Write("LICENSE", "unchanged original bytes"u8.ToArray());
        var path = Path.Combine(fixture.Group, "LICENSE");
        var before = File.ReadAllBytes(path);
        var time = File.GetLastWriteTimeUtc(path);
        var result = TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product,
            () => File.SetLastWriteTimeUtc(path, time.AddMinutes(1)));
        Assert.AreEqual(TraceLicenseStatus.Unavailable, result.Status);
        Assert.AreEqual("sourceChanged", result.Reason);
        Assert.IsNull(result.Text);
        CollectionAssert.AreEqual(before, File.ReadAllBytes(path));
    }

    [TestMethod]
    public async Task AReparseGroupAncestorOrRevealFolderCannotRedirectTheApp()
    {
        using var fixture = new Files();
        var outside = Path.Combine(fixture.Root, "outside");
        Directory.CreateDirectory(outside);
        File.WriteAllText(Path.Combine(outside, "LICENSE"), "foreign legal text");
        Directory.Delete(fixture.Group);
        Junction(fixture.Group, outside);
        try
        {
            var result = await TraceLicenses.At(fixture.App).LoadAsync();
            Assert.AreEqual(TraceLicenseStatus.Unavailable, result.Product.Status);
            Assert.IsNull(result.Product.Text);
            Assert.IsFalse(result.CanReveal);
        }
        finally { Directory.Delete(fixture.Group); }
        Directory.CreateDirectory(fixture.Group);
        fixture.Write("LICENSE", "original"u8.ToArray());
        var licenses = Path.Combine(fixture.Group, "Licenses");
        Directory.CreateDirectory(licenses);
        var model = TraceLicenses.At(fixture.App);
        Assert.IsTrue((await model.LoadAsync()).CanReveal);
        Directory.Delete(licenses);
        Junction(licenses, outside);
        try { Assert.IsNull(model.OpenLicenseFolder(), "a cached reveal flag cannot follow a replaced junction"); }
        finally { Directory.Delete(licenses); }

        var redirectedApp = Path.Combine(fixture.Root, "redirected-app");
        Junction(redirectedApp, fixture.App);
        try
        {
            Assert.AreEqual(TraceLicenseStatus.Unavailable, TraceLicenseFiles.Read(redirectedApp, TraceLicenseFiles.Document.Product).Status);
        }
        finally { Directory.Delete(redirectedApp); }
        File.Delete(Path.Combine(fixture.Group, "LICENSE"));
        Junction(Path.Combine(fixture.Group, "LICENSE"), outside);
        try
        {
            Assert.AreEqual(TraceLicenseStatus.Unavailable, TraceLicenseFiles.Read(fixture.App, TraceLicenseFiles.Document.Product).Status,
                "the final resource entry is also opened without following a reparse point");
        }
        finally { Directory.Delete(Path.Combine(fixture.Group, "LICENSE")); }
    }

    private sealed class Files : IDisposable
    {
        internal string Root { get; } = Directory.CreateTempSubdirectory("arkdeck-license-").FullName;
        internal string App => Path.Combine(Root, "App");
        internal string Group => Path.Combine(App, "ArkTrace");
        internal Files() => Directory.CreateDirectory(Group);
        internal void Write(string name, byte[] bytes) => File.WriteAllBytes(Path.Combine(Group, name), bytes);
        internal string[] Inventory() => Directory.EnumerateFileSystemEntries(Root, "*", SearchOption.AllDirectories)
            .Order(StringComparer.Ordinal).Select(path =>
            {
                var info = new FileInfo(path);
                var digest = Directory.Exists(path) ? "directory" : Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
                return $"{Path.GetRelativePath(Root, path)}|{info.Attributes}|{info.LastWriteTimeUtc.Ticks}|{digest}";
            }).ToArray();
        public void Dispose() => Directory.Delete(Root, recursive: true);
    }

    // A task-private NTFS mount point needs no symbolic-link privilege. It exercises the real
    // reparse attribute without a shell, an external path, or modification of an existing directory.
    private static void Junction(string path, string target)
    {
        Directory.CreateDirectory(path);
        var substitute = Encoding.Unicode.GetBytes(@"\??\" + Path.GetFullPath(target));
        var printed = Encoding.Unicode.GetBytes(Path.GetFullPath(target));
        var data = new byte[16 + substitute.Length + 2 + printed.Length + 2];
        BitConverter.GetBytes(0xa0000003u).CopyTo(data, 0);
        BitConverter.GetBytes(checked((ushort)(data.Length - 8))).CopyTo(data, 4);
        BitConverter.GetBytes(checked((ushort)substitute.Length)).CopyTo(data, 10);
        BitConverter.GetBytes(checked((ushort)(substitute.Length + 2))).CopyTo(data, 12);
        BitConverter.GetBytes(checked((ushort)printed.Length)).CopyTo(data, 14);
        substitute.CopyTo(data, 16);
        printed.CopyTo(data, 18 + substitute.Length);
        using var directory = CreateFile(path, 0x40000000, 0, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        Assert.IsFalse(directory.IsInvalid);
        Assert.IsTrue(DeviceIoControl(directory, 0x000900a4, data, (uint)data.Length, IntPtr.Zero, 0, out _, IntPtr.Zero),
            "own mount-point fixture creation failed: " + Marshal.GetLastWin32Error());
        Assert.IsTrue(File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint));
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
}
