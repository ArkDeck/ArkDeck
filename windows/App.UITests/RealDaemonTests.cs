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

    /// <summary>
    /// The real daemon over an isolated development state root (TASK-XPA-004's composition on
    /// <c>origin/main</c>), holding the Swift adoption oracle's Target: the Device page lists
    /// it although no HDC is registered, shows <c>target.show</c> and <c>target.availability</c>,
    /// and a rename in the App's dialog is recorded by the Runtime (its display-name document)
    /// and cleared again.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TheAppRenamesTheDevelopmentRootsTargetInTheRuntime()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-root-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;

            // The first start creates the owner-only Target store directory; the oracle's
            // targets.json goes into it before the second start reads it.
            (process, _) = StartRootDaemon(signed, root);
            process.Kill();
            process.WaitForExit();
            process.Dispose();
            File.Copy(RepoPaths.At("rust", "tests", "fixtures", "target-adoption", "targets-state", "targets.json"),
                Path.Combine(root, "targets-state", "targets.json"));
            (process, var endpoint) = StartRootDaemon(signed, root);
            TestContext.WriteLine("daemon over the development root at " + endpoint);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "device"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            var device = app.WaitForName("app.devices.unavailable.reason", n => n.StartsWith("unavailable(", StringComparison.Ordinal));
            TestContext.WriteLine("device: " + device);
            StringAssert.StartsWith(device, "unavailable(rejected): hdc.");
            app.Select("device.target." + OracleTarget);
            Assert.AreEqual(new string('a', 32), app.WaitForName("device.target.detail.connectKey", n => n.Length > 0));
            TestContext.WriteLine("presence: " + app.WaitForName("device.target.presence", n => n.Length > 0));
            TestContext.WriteLine("tool: " + AppSession.Name(app.Find("device.target.tool")));

            app.Invoke("device.target.rename");
            app.Find("device.rename.field").Patterns.Value.Pattern.SetValue("Bench board");
            app.Invoke("PrimaryButton");
            Assert.AreEqual(strings.Format("windows.device.rename.saved", ["Bench board"]), app.WaitForName("device.target.nameStatus", n => n.Length > 0));
            app.WaitForName("device.target." + OracleTarget, n => n == "Bench board, " + OracleTarget);
            var names = File.ReadAllText(Path.Combine(root, "targets-state", "target-display-names.json"));
            TestContext.WriteLine("target-display-names.json: " + names);
            StringAssert.Contains(names, "Bench board");

            app.Invoke("device.target.clearName");
            app.WaitForName("device.target.nameStatus", n => n == strings["windows.device.rename.cleared"]);
            app.WaitForName("device.target." + OracleTarget, n => n == OracleTarget);

            // History: no Job owner is composed over the root yet.
            app.Navigate("history");
            var history = app.WaitForName("history.unavailable.reason", n => n.StartsWith("unavailable(", StringComparison.Ordinal));
            TestContext.WriteLine("history: " + history);
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
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

    /// <summary>
    /// Settings against the real daemon over a development root: the Runtime tab shows the
    /// daemon's own health and doctor; Storage and Trace show its refusals as they came; the
    /// Workspace tab lists a project registered over the pipe (as the CLI's
    /// <c>workspace project register</c> does) with its symbol preset.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void SettingsShowTheDevelopmentRootsRuntimeAndWorkspace()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-settings-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            (process, var endpoint) = StartRootDaemon(signed, root);
            var source = Directory.CreateDirectory(Path.Combine(root, "sources", "first")).FullName;
            var project = Frame(endpoint, "workspace.project.register",
                $$"""{"kind":"openharmony","registrationRequestId":"request-first","root":{{JsonSerializer.Serialize(source)}}}""");
            var reference = project.GetProperty("result").GetProperty("projectRef").GetString()!;
            var preset = Frame(endpoint, "workspace.preset.register",
                $$"""{"kind":"symbol","projectRef":"{{reference}}","registrationRequestId":"preset-one","relativeSourceMap":"entry/build/sourceMaps.map","templateRef":"openharmony.arkts-symbol@1","timeoutSeconds":"600"}""");
            var presetRef = preset.GetProperty("result").GetProperty("presetRef").GetString()!;

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "settings"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            app.Select("settings.tab.runtime");
            Assert.AreEqual("ok", app.WaitForName("settings.runtime.status", n => n.Length > 0));
            TestContext.WriteLine("runtime checks: " + AppSession.Name(app.Find("settings.runtime.overall")) + " / hdc " + AppSession.Name(app.Find("settings.runtime.check.hdc"))
                                  + " / targets " + AppSession.Name(app.Find("settings.runtime.check.targets")));
            app.Select("settings.tab.storage");
            TestContext.WriteLine("storage: " + app.WaitForName("settings.storage.unavailable.reason", n => n.StartsWith("unavailable(", StringComparison.Ordinal)));
            app.Select("settings.tab.trace");
            TestContext.WriteLine("trace cache: " + app.WaitForName("settings.trace.unavailable.reason", n => n.StartsWith("unavailable(", StringComparison.Ordinal)));
            app.Select("settings.tab.toolchains");
            TestContext.WriteLine("hdc: " + app.WaitForName("settings.toolchains.hdc.unavailable.reason", n => n.StartsWith("unavailable(", StringComparison.Ordinal)));
            app.Select("settings.tab.workspace");
            app.Select("settings.workspace.project." + reference);
            Assert.AreEqual("runtimeRestartRequired", app.WaitForName("settings.workspace.detail.configuration", n => n.Length > 0));
            TestContext.WriteLine("preset: " + app.WaitForName("settings.workspace.preset." + presetRef, n => n.Length > 0));
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
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

    /// <summary>One control frame on a plain handle of the daemon's pipe (test setup only, as
    /// the Rust process tests register a project); the reply must succeed.</summary>
    private static JsonElement Frame(string endpoint, string method, string parameters)
    {
        using var pipe = new System.IO.Pipes.NamedPipeClientStream(".", endpoint[@"\\.\pipe\".Length..], System.IO.Pipes.PipeDirection.InOut);
        pipe.Connect(10_000);
        var frame = $$"""{"contractIdentity":"{{ArkDeck.ClientKit.Contract.ControlContract.ContractIdentity}}","id":"setup","method":"{{method}}","params":{{parameters}},"protocolVersion":"{{ArkDeck.ClientKit.Contract.ControlContract.ProtocolVersion}}"}""" + "\n";
        pipe.Write(System.Text.Encoding.UTF8.GetBytes(frame));
        var reply = new List<byte>();
        for (var b = pipe.ReadByte(); b >= 0 && b != '\n'; b = pipe.ReadByte()) reply.Add((byte)b);
        var document = JsonDocument.Parse(reply.ToArray()).RootElement.Clone();
        Assert.IsTrue(document.GetProperty("ok").GetBoolean(), $"{method}: {System.Text.Encoding.UTF8.GetString(reply.ToArray())}");
        return document;
    }

    private const string OracleTarget = "TGT-3ba3f5f43b92";

    /// <summary>The development signer, a built daemon and PowerShell 7, or the test is skipped.</summary>
    private static (string Thumbprint, string Daemon, string Pwsh) Prerequisites()
    {
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
        return (thumbprint!, daemon, pwsh);
    }

    /// <summary>A daemon over a development state root, and the pipe it announces
    /// (<c>arkdeck-agentd listening on …</c>). Every other ArkDeck and HDC input is removed.</summary>
    private static (Process Process, string Endpoint) StartRootDaemon(string daemon, string root)
    {
        var start = new ProcessStartInfo(daemon) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var key in start.Environment.Keys.ToArray())
        {
            if (key.StartsWith("ARKDECK_", StringComparison.OrdinalIgnoreCase) || key.StartsWith("OHOS_HDC_", StringComparison.OrdinalIgnoreCase))
            {
                start.Environment.Remove(key);
            }
        }
        start.Environment["ARKDECK_DEVELOPMENT_STATE_ROOT"] = root;
        var process = Process.Start(start)!;
        var announced = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        const string prefix = "arkdeck-agentd listening on ";
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is { } line && line.StartsWith(prefix, StringComparison.Ordinal)) announced.TrySetResult(line[prefix.Length..].Trim());
        };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        if (!announced.Task.Wait(TimeSpan.FromSeconds(30)))
        {
            if (!process.HasExited) process.Kill();
            Assert.Fail("the daemon did not announce its pipe");
        }
        return (process, announced.Task.Result);
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
