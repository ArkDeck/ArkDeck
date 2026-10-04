using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using ArkDeck.App.Core.RemoteSources;

namespace ArkDeck.App.Tests;

/// <summary>
/// The remote build source over Windows' own OpenSSH: <c>ssh.exe</c> (the connector the App uses)
/// against <c>sshd.exe</c> run by this user on a loopback port with a test host key, a test client
/// key and an SFTP root in a temporary directory. A probe pins the host key it saw, the saved
/// source lists and reads through it, and a server presenting another key is refused. Inconclusive
/// where Windows' OpenSSH server is not present.
/// </summary>
[TestClass]
public sealed class RemoteBuildSourceSshTests
{
    private static string OpenSsh(string name) => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", name);

    private sealed class Server : IDisposable
    {
        private readonly Process _process;

        public int Port { get; }

        private Server(Process process, int port)
        {
            _process = process;
            Port = port;
        }

        public static Server Start(DirectoryInfo directory, string hostKey, string authorizedKeys)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            string Slashes(string path) => path.Replace('\\', '/');
            var config = Path.Combine(directory.FullName, "sshd_config-" + port);
            File.WriteAllText(config, $"""
                Port {port}
                ListenAddress 127.0.0.1
                HostKey {Slashes(hostKey)}
                PidFile {Slashes(Path.Combine(directory.FullName, "sshd-" + port + ".pid"))}
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
                    return new Server(process, port);
                }
                catch (SocketException)
                {
                    if (process.HasExited) break;
                    Thread.Sleep(100);
                }
            }
            process.Dispose();
            throw new AssertFailedException("sshd did not start");
        }

        public void Dispose()
        {
            if (!_process.HasExited) _process.Kill(entireProcessTree: true);
            _process.WaitForExit(10_000);
            _process.Dispose();
        }
    }

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

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public async Task ASourceIsProbedPinnedListedAndReadThroughOpenSsh()
    {
        if (!File.Exists(OpenSsh("sshd.exe")) || !File.Exists(OpenSsh("ssh.exe")) || !File.Exists(OpenSsh("sftp-server.exe")))
        {
            Assert.Inconclusive("Windows' OpenSSH client and server are not present");
        }
        var directory = Directory.CreateTempSubdirectory("arkdeck-remote-ssh-");
        try
        {
            var hostKey = KeyPair(directory, "host");
            var otherHostKey = KeyPair(directory, "other-host");
            var clientKey = KeyPair(directory, "client");
            var authorized = Path.Combine(directory.FullName, "authorized_keys");
            File.Copy(clientKey + ".pub", authorized);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "out"));
            Directory.CreateDirectory(Path.Combine(root.FullName, "arm64"));
            var library = Enumerable.Range(0, 5000).Select(i => (byte)(i % 253)).ToArray();
            File.WriteAllBytes(Path.Combine(root.FullName, "arm64", "libentry.so"), library);
            File.WriteAllText(Path.Combine(root.FullName, "notes.txt"), "not a library");
            var rootPath = "/" + root.FullName.Replace('\\', '/');

            var files = new RemoteBuildSourceFiles(Path.Combine(directory.FullName, "state"));
            var credentials = new MemoryCredentials();
            var provider = new RemoteBuildSourceProvider(files, files, credentials, files, new OpenSshConnector(Path.Combine(directory.FullName, "no-askpass.exe")));
            var draft = new RemoteBuildSourceDraft(null, "Loopback", "127.0.0.1", 0, Environment.UserName, rootPath, RemoteBuildSourceAuthentication.PrivateKey);
            var key = new RemoteBuildSourceCredentialInput.PrivateKey(File.ReadAllBytes(clientKey), null);

            RemoteBuildSourcePresentation saved;
            using (var server = Server.Start(directory, hostKey, authorized))
            {
                var probe = await provider.ProbeAsync(draft with { Port = server.Port }, key);
                Assert.IsTrue(probe.RequiresNewHostTrust);
                var publicKey = File.ReadAllText(hostKey + ".pub").Split(' ');
                Assert.AreEqual(RemoteBuildSourceProvider.Fingerprint($"{publicKey[0]} {publicKey[1]}"), probe.HostKeyFingerprint, "the key the server presented");
                StringAssert.EndsWith(probe.CanonicalRootPath, "/out");
                saved = await provider.SaveAsync(probe);

                var listing = await provider.ListDirectoryAsync(saved.Id, "");
                CollectionAssert.AreEqual(new[] { "arm64" }, listing.Entries.Select(e => e.Name).ToArray());
                var nested = await provider.ListDirectoryAsync(saved.Id, "arm64");
                Assert.AreEqual(("libentry.so", 5000UL), (nested.Entries.Single().Name, nested.Entries.Single().ByteCount!.Value));
                var fetched = await provider.FetchNativeLibraryAsync(saved.Id, "arm64/libentry.so");
                CollectionAssert.AreEqual(library, fetched.Contents);
                Assert.AreEqual(RemoteBuildSourceErrorCode.PathOutsideRoot,
                    (await Assert.ThrowsExactlyAsync<RemoteBuildSourceException>(() => provider.ListDirectoryAsync(saved.Id, "../.."))).Code);
            }

            // The same address now presents another host key: refused, nothing listed.
            using (var impostor = Server.Start(directory, otherHostKey, authorized))
            {
                var probe = await provider.ProbeAsync(draft with { Id = saved.Id, Port = impostor.Port }, key);
                Assert.IsTrue(probe.RequiresNewHostTrust, "another port is another host");
                IRemoteBuildSourceRecordStore records = files;
                var pinned = records.Load().Single();
                records.Replace([pinned with { Port = impostor.Port }]);
                var refused = await Assert.ThrowsExactlyAsync<RemoteBuildSourceException>(() => provider.ListDirectoryAsync(saved.Id, ""));
                Assert.AreEqual(RemoteBuildSourceErrorCode.HostKeyChanged, refused.Code, refused.Message);
            }
            var audit = File.ReadAllText(Path.Combine(directory.FullName, "state", "audit-v1.jsonl"));
            Assert.IsFalse(audit.Contains("libentry", StringComparison.Ordinal) || audit.Contains(root.FullName.Replace('\\', '/'), StringComparison.Ordinal));
        }
        finally
        {
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
