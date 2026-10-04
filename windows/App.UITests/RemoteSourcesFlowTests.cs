using System.Diagnostics;
using System.Net;
using System.Net.Sockets;

namespace ArkDeck.App.UITests;

/// <summary>
/// Remote build sources through UIA patterns only, against Windows' own OpenSSH: <c>sshd.exe</c>
/// run by this user on a loopback port with a test host key, a test client key and a build root in
/// a temporary directory. In Settings › Servers a server is added with the key chosen in the system
/// file dialog, tested (the host key's fingerprint shown, trust on save) and saved; in Debug ›
/// Artifacts the remote browser lists the root, opens a folder and chooses its lib*.so; the server
/// is removed again (with its Credential Manager entry). Inconclusive without Windows' OpenSSH server.
/// </summary>
[TestClass]
public sealed class RemoteSourcesFlowTests
{
    public TestContext TestContext { get; set; } = null!;

    private static string OpenSsh(string name) => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", name);

    private static string KeyPair(DirectoryInfo directory, string name)
    {
        var file = Path.Combine(directory.FullName, name);
        var start = new ProcessStartInfo(OpenSsh("ssh-keygen.exe")) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in new[] { "-q", "-t", "ed25519", "-f", file, "-N", "", "-C", name }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        process.WaitForExit(30_000);
        Assert.AreEqual(0, process.ExitCode);
        return file;
    }

    private static (Process Process, int Port) StartSshd(DirectoryInfo directory, string hostKey, string authorizedKeys)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        string Slashes(string path) => path.Replace('\\', '/');
        var config = Path.Combine(directory.FullName, "sshd_config");
        File.WriteAllText(config, $"""
            Port {port}
            ListenAddress 127.0.0.1
            HostKey {Slashes(hostKey)}
            PidFile {Slashes(Path.Combine(directory.FullName, "sshd.pid"))}
            AuthorizedKeysFile {Slashes(authorizedKeys)}
            StrictModes no
            PasswordAuthentication no
            PubkeyAuthentication yes
            Subsystem sftp {Slashes(OpenSsh("sftp-server.exe"))}
            """);
        var start = new ProcessStartInfo(OpenSsh("sshd.exe")) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true, CreateNoWindow = true };
        foreach (var argument in new[] { "-D", "-e", "-f", config }) start.ArgumentList.Add(argument);
        var process = Process.Start(start)!;
        _ = process.StandardError.ReadToEndAsync();
        _ = process.StandardOutput.ReadToEndAsync();
        for (var i = 0; i < 100; i++)
        {
            try
            {
                using var probe = new TcpClient();
                probe.Connect(IPAddress.Loopback, port);
                return (process, port);
            }
            catch (SocketException)
            {
                Thread.Sleep(100);
            }
        }
        process.Kill();
        throw new AssertFailedException("sshd did not start");
    }

    private static void SetText(AppSession app, string id, string value) => app.Find(id).Patterns.Value.Pattern.SetValue(value);

    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void AServerIsVerifiedSavedBrowsedAndRemoved()
    {
        var exe = AppSession.RequireApp();
        if (!File.Exists(OpenSsh("sshd.exe")) || !File.Exists(OpenSsh("sftp-server.exe"))) Assert.Inconclusive("Windows' OpenSSH server is not present");
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-remote-");
        Process? sshd = null;
        try
        {
            var hostKey = KeyPair(directory, "host");
            var clientKey = KeyPair(directory, "client");
            var authorized = Path.Combine(directory.FullName, "authorized_keys");
            File.Copy(clientKey + ".pub", authorized);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "out"));
            Directory.CreateDirectory(Path.Combine(root.FullName, "arm64"));
            File.WriteAllBytes(Path.Combine(root.FullName, "arm64", "libentry.so"), Enumerable.Range(0, 4096).Select(i => (byte)i).ToArray());
            (sshd, var port) = StartSshd(directory, hostKey, authorized);

            using var app = AppSession.Launch(exe, ["--test-transport", "jobs", "--language", "en-US", "--page", "settings",
                "--remote-sources-root", Path.Combine(directory.FullName, "state")]);
            app.Select("settings.tab.remoteSources");
            Assert.AreEqual(strings["settings.remoteSources.empty.title"], app.WaitForName("settings.remoteSources.empty.title", n => n.Length > 0));
            app.Invoke("settings.remoteSources.add");
            SetText(app, "settings.remoteSources.field.name", "Loopback builder");
            SetText(app, "settings.remoteSources.field.host", "127.0.0.1");
            SetText(app, "settings.remoteSources.field.port", port.ToString(System.Globalization.CultureInfo.InvariantCulture));
            SetText(app, "settings.remoteSources.field.username", Environment.UserName);
            SetText(app, "settings.remoteSources.field.root", "/" + root.FullName.Replace('\\', '/'));
            app.Find("settings.remoteSources.field.authentication").Patterns.ExpandCollapse.Pattern.Expand();
            app.Select("settings.remoteSources.field.authentication.privateKey");
            AgentImportFlowTests.ChooseFile(app, "settings.remoteSources.choosePrivateKey", clientKey);
            app.WaitForName("settings.remoteSources.keyStatus", n => n.EndsWith("client", StringComparison.Ordinal));

            // Save before a test is refused: only a just-verified host key is trusted.
            app.Invoke("PrimaryButton");
            Assert.AreEqual(strings["windows.remoteSources.saveNeedsProbe"], app.WaitForName("settings.remoteSources.probeError", n => n.Length > 0));
            app.Invoke("settings.remoteSources.testConnection");
            var fingerprint = app.WaitForName("settings.remoteSources.probe.fingerprint", n => n.StartsWith("SHA256:", StringComparison.Ordinal));
            TestContext.WriteLine("fingerprint: " + fingerprint);
            Assert.AreEqual(strings["settings.remoteSources.trustOnSave"], AppSession.Name(app.Find("settings.remoteSources.trustOnSave")));
            app.Invoke("PrimaryButton");
            Assert.AreEqual(strings["windows.remoteSources.saved"], app.WaitForName("settings.remoteSources.status", n => n.Length > 0));
            string? rowId = null;
            SemanticSnapshotTests.WaitUntil(() => (rowId = app.Window.FindAllDescendants(cf => cf.ByControlType(FlaUI.Core.Definitions.ControlType.Text))
                .Select(e => e.Properties.AutomationId.ValueOrDefault ?? "")
                .FirstOrDefault(id => id.StartsWith("settings.remoteSources.row.", StringComparison.Ordinal) && id.EndsWith(".name", StringComparison.Ordinal))) is not null,
                "the saved server's row");
            var row = rowId![..^".name".Length];
            Assert.AreEqual("Loopback builder", AppSession.Name(app.Find(row + ".name")));
            Assert.AreEqual(fingerprint, AppSession.Name(app.Find(row + ".fingerprint")));
            Assert.AreEqual(strings["windows.remoteSources.credentialStored"], AppSession.Name(app.Find(row + ".credential")));

            // Debug › Artifacts › Remote server: the browser lists the root, opens arm64 and chooses its library.
            app.Navigate("debug");
            app.Select("debug.tab.artifacts");
            app.Select("debug.artifacts.source.remote");
            app.Invoke("debug.artifacts.browseRemote");
            app.Invoke("debug.artifacts.remoteBrowser.entry.arm64");
            app.Invoke("debug.artifacts.remoteBrowser.entry.arm64/libentry.so");
            app.WaitForName("debug.artifacts.remoteBrowser.status", n => n == "libentry.so");
            app.Invoke("PrimaryButton");
            Assert.AreEqual("libentry.so", app.WaitForName("debug.artifacts.selectedLibrary", n => n == "libentry.so"));
            Assert.AreEqual("Loopback builder · arm64/libentry.so", AppSession.Name(app.Find("debug.artifacts.selectedLibrary.source")));
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");

            // Removing the server asks first, then removes it and its credential.
            app.Navigate("settings");
            app.Select("settings.tab.remoteSources");
            app.Invoke(row + ".remove");
            app.Invoke("PrimaryButton");
            app.WaitForName("settings.remoteSources.status", n => n == strings["windows.remoteSources.removed"]);
            app.Find("settings.remoteSources.empty.title");
        }
        finally
        {
            if (sshd is { HasExited: false }) sshd.Kill(entireProcessTree: true);
            sshd?.Dispose();
            try
            {
                directory.Delete(recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }
}
