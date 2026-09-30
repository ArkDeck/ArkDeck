using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32;

namespace ArkDeck.App.UITests;

/// <summary>
/// The App against the real Rust daemon, signed with the host-trusted development certificate
/// exactly as the ClientKit end-to-end test signs it, on a private endpoint. The App is given
/// only the installation inputs the CLI reads (ARKDECK_ENDPOINT, ARKDECK_DAEMON_PATH,
/// ARKDECK_DAEMON_SIGNER_SHA256). It shows what today's Windows daemon answers — doctor,
/// the device refusal, the Job owner refusal — and the recovery banner once the daemon is
/// gone. Skipped without ARKDECK_APP_UITESTS=1, ARKDECK_DEV_SIGNER_THUMBPRINT, PowerShell 7
/// or a built daemon (ARKDECK_CLIENTKIT_DAEMON or rust/target/debug/arkdeck-agentd.exe).
/// </summary>
[TestClass]
public sealed class RealDaemonTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(240_000, CooperativeCancellation = true)]
    public void TheAppShowsTheDevSignedDaemonAndItsAbsence()
    {
        var exe = AppSession.RequireApp();
        var thumbprint = Environment.GetEnvironmentVariable("ARKDECK_DEV_SIGNER_THUMBPRINT");
        if (string.IsNullOrEmpty(thumbprint))
        {
            using var environment = Registry.CurrentUser.OpenSubKey("Environment");
            thumbprint = environment?.GetValue("ARKDECK_DEV_SIGNER_THUMBPRINT") as string;
        }
        if (string.IsNullOrEmpty(thumbprint)) Assert.Inconclusive("skipped: ARKDECK_DEV_SIGNER_THUMBPRINT is not set on this host");
        var daemon = Environment.GetEnvironmentVariable("ARKDECK_CLIENTKIT_DAEMON") is { Length: > 0 } configured
            ? configured
            : RepoPaths.At("rust", "target", "debug", "arkdeck-agentd.exe");
        if (!File.Exists(daemon)) Assert.Inconclusive($"skipped: no daemon binary at {daemon} (cargo build -p arkdeck-agentd)");
        var pwsh = FindPwsh() ?? throw new AssertInconclusiveException("skipped: PowerShell 7 (pwsh) is required to sign the development daemon");

        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint!, signed);
            var endpoint = $@"\\.\pipe\arkdeck-app-uitest-{Guid.NewGuid():N}";
            process = StartDaemon(signed, endpoint);
            WaitForPipe(endpoint, process);

            using var app = AppSession.Launch(exe, ["--language", "en-US"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            Assert.IsNull(app.TryFind("app.testTransport", TimeSpan.FromSeconds(1)), "no test transport");

            // Overview: the daemon's own doctor report.
            var overall = app.WaitForName("overview.doctor.overall", n => n.Length > 0);
            TestContext.WriteLine("overview: " + overall + " / " + AppSession.Name(app.Find("overview.doctor.counts")));
            StringAssert.StartsWith(AppSession.Name(app.Find("overview.runtime.protocol")), "1.0.0");
            Assert.IsNull(app.TryFind("app.recovery.retry", TimeSpan.FromMilliseconds(500)), "no recovery banner while the daemon answers");

            // Device: the structured refusal, as it came.
            app.Navigate("device");
            var device = app.WaitForName("app.devices.unavailable.reason", n => n.StartsWith("unavailable(", StringComparison.Ordinal));
            TestContext.WriteLine("device: " + device);
            StringAssert.StartsWith(device, "unavailable(rejected): hdc.");

            // History: no Job owner on today's Windows daemon.
            app.Navigate("history");
            var history = app.WaitForName("history.unavailable.reason", n => n.StartsWith("unavailable(", StringComparison.Ordinal));
            TestContext.WriteLine("history: " + history);
            Assert.AreEqual(strings.Format("windows.unavailable.reason", ["rejected", "The Job owner is not configured"]), history);

            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");

            // The daemon goes away: Retry shows the recovery banner instead of any data.
            process.Kill();
            process.WaitForExit();
            app.Invoke("history.refresh");
            var banner = app.Find("app.recovery.daemonUnavailable");
            Assert.AreEqual(strings["windows.recovery.title"], app.WaitForName("app.recovery.daemonUnavailable", n => n.Length > 0));
            var reason = app.WaitForName("history.unavailable.reason", n => n.StartsWith("unavailable(daemonUnavailable)", StringComparison.Ordinal));
            TestContext.WriteLine("after the daemon stopped: " + reason + " / " + AppSession.Name(app.Find("app.recovery.reason")));
            Assert.IsNotNull(banner);
        }
        finally
        {
            if (process is { HasExited: false })
            {
                process.Kill();
                process.WaitForExit();
            }
            process?.Dispose();
            for (var attempt = 0; attempt < 20; attempt++)
            {
                try
                {
                    directory.Delete(recursive: true);
                    break;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    Thread.Sleep(100);
                }
            }
        }
    }

    private static string? FindPwsh()
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (dir.Length > 0 && File.Exists(Path.Combine(dir, "pwsh.exe"))) return Path.Combine(dir, "pwsh.exe");
        }
        var alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "pwsh.exe");
        return File.Exists(alias) ? alias : null;
    }

    private static string Sign(string pwsh, string thumbprint, string path)
    {
        var start = new ProcessStartInfo(pwsh,
            ["-NoProfile", "-NonInteractive", "-File", RepoPaths.At("rust", "scripts", "windows-dev-identity.ps1"), "sign", "-Thumbprint", thumbprint, "-Path", path])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        using var signer = Process.Start(start)!;
        signer.StandardInput.Close();
        var output = signer.StandardOutput.ReadToEnd();
        var error = signer.StandardError.ReadToEnd();
        signer.WaitForExit();
        Assert.AreEqual(0, signer.ExitCode, output + error);
        using var doc = JsonDocument.Parse(output.Trim());
        return doc.RootElement.GetProperty("pin").GetString()!;
    }

    private static Process StartDaemon(string daemon, string endpoint)
    {
        var start = new ProcessStartInfo(daemon) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var key in start.Environment.Keys.ToArray())
        {
            if (key.StartsWith("ARKDECK_", StringComparison.OrdinalIgnoreCase) || key.StartsWith("OHOS_HDC_", StringComparison.OrdinalIgnoreCase))
            {
                start.Environment.Remove(key);
            }
        }
        start.Environment["ARKDECK_ENDPOINT"] = endpoint;
        var process = Process.Start(start)!;
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }

    private static void WaitForPipe(string endpoint, Process process)
    {
        var name = endpoint[@"\\.\pipe\".Length..];
        var watch = Stopwatch.StartNew();
        while (!File.Exists(@"\\.\pipe\" + name))
        {
            Assert.IsFalse(process.HasExited, "the daemon exited during startup");
            if (watch.Elapsed > TimeSpan.FromSeconds(20)) Assert.Fail("the daemon did not open its pipe");
            Thread.Sleep(100);
        }
    }
}
