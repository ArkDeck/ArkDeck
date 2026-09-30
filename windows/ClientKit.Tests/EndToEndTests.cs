using System.Diagnostics;
using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Json;
using ArkDeck.ClientKit.Transport;
using Microsoft.Win32;

namespace ArkDeck.ClientKit.Tests;

/// <summary>
/// <c>health</c> and <c>doctor</c> through ClientKit against the real Rust daemon, signed with
/// the host-trusted development certificate (<c>rust/scripts/windows-dev-identity.ps1</c>,
/// design §L.1 item 22) exactly as <c>rust/scripts/check-readonly.py</c>'s
/// <c>signed_windows_matrix</c> signs its copy: the client checks the pinned image path and
/// the pinned signer; nothing skips the check. Needs <c>ARKDECK_DEV_SIGNER_THUMBPRINT</c>
/// (process environment or HKCU\Environment), PowerShell 7 and a built daemon
/// (<c>ARKDECK_CLIENTKIT_DAEMON</c>, else <c>rust/target/debug/arkdeck-agentd.exe</c>);
/// otherwise it is reported as skipped (inconclusive) with the missing input.
/// </summary>
[TestClass]
public sealed class EndToEndTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [Timeout(180_000, CooperativeCancellation = true)]
    public async Task HealthAndDoctorAgainstADevSignedDaemon()
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
        var pwsh = FindPwsh();
        if (pwsh is null) Assert.Inconclusive("skipped: PowerShell 7 (pwsh) is required to sign the development daemon");

        var directory = Directory.CreateTempSubdirectory("arkdeck-clientkit-e2e-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh!, thumbprint!, signed);
            var endpoint = new PipeEndpoint($@"\\.\pipe\arkdeck-clientkit-e2e-{Guid.NewGuid():N}");
            process = Start(signed, endpoint);
            var identity = new DaemonIdentity(signed, pin);
            var session = new ControlSession(endpoint, identity, TimeSpan.FromSeconds(10));

            var health = await WaitForHealth(session, process);
            var typedHealth = TypedMethods.ParseHealthResult(health);
            Assert.AreEqual("ok", typedHealth.Status);
            Assert.AreEqual(ControlContract.ContractIdentity, typedHealth.ContractIdentity);
            CollectionAssert.AreEqual(ControlContract.Methods.ToArray(), typedHealth.PublishedMethods.ToArray());

            var doctor = await session.RequestAsync("doctor", new JsonObject([new("deep", JsonBool.False)]));
            Assert.IsTrue(doctor.Succeeded, doctor.Failure?.Message);
            var typedDoctor = TypedMethods.ParseDoctorResult(doctor.Value!);
            TestContext.WriteLine($"doctor: {typedDoctor.Findings.Count} findings, runtime protocol {typedDoctor.Checks.Runtime.ProtocolVersion}");

            // One connection: health first, then two business requests, no second health.
            using (var client = ControlClient.Connect(endpoint, identity, TimeSpan.FromSeconds(10)))
            {
                await client.RequestAsync("e2e-doctor", "doctor");
                TypedMethods.ParseOperationListResult(await client.RequestAsync("e2e-operations", "operation.list"));
            }

            // The real daemon under a wrong pin, and the unsigned original under its own path.
            foreach (var wrong in new[] { new DaemonIdentity(signed, new string('0', 64)), new DaemonIdentity(daemon, pin) })
            {
                var refused = await new ControlSession(endpoint, wrong, TimeSpan.FromSeconds(10)).HealthAsync();
                Assert.AreEqual(DaemonUnavailableReason.InstanceMismatch, refused.Failure?.Reason, wrong.ToString());
                Assert.IsNull(refused.Value);
            }
        }
        finally
        {
            if (process is { HasExited: false })
            {
                process.Kill();
                await process.WaitForExitAsync();
            }
            if (process is not null)
            {
                lock (Log) TestContext.WriteLine("daemon output: " + Log);
                process.Dispose();
            }
            // The killed image can stay mapped for a moment; a leftover temporary copy is
            // not a test result, so it is reported rather than failed on.
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    directory.Delete(recursive: true);
                    break;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    if (attempt == 20)
                    {
                        TestContext.WriteLine($"left {directory.FullName}: {error.Message}");
                        break;
                    }
                    await Task.Delay(100);
                }
            }
        }
    }

    private static string? FindPwsh()
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(Path.PathSeparator))
        {
            if (directory.Length > 0 && File.Exists(Path.Combine(directory, "pwsh.exe"))) return Path.Combine(directory, "pwsh.exe");
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
        return ((JsonString)StrictJson.Parse(System.Text.Encoding.UTF8.GetBytes(output.Trim()))["pin"]).Value;
    }

    private static Process Start(string daemon, PipeEndpoint endpoint)
    {
        var start = new ProcessStartInfo(daemon)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        // As check-readonly.py: no inherited ArkDeck or HDC configuration, a private endpoint.
        foreach (var key in start.Environment.Keys.ToArray())
        {
            if (key.StartsWith("ARKDECK_", StringComparison.OrdinalIgnoreCase) || key.StartsWith("OHOS_HDC_", StringComparison.OrdinalIgnoreCase))
            {
                start.Environment.Remove(key);
            }
        }
        start.Environment["ARKDECK_ENDPOINT"] = endpoint.Name;
        var process = new Process { StartInfo = start };
        process.OutputDataReceived += (_, line) => { lock (Log) Log.AppendLine(line.Data); };
        process.ErrorDataReceived += (_, line) => { lock (Log) Log.AppendLine(line.Data); };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }

    private static readonly System.Text.StringBuilder Log = new();

    private static async Task<JsonValue> WaitForHealth(ControlSession session, Process process)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(20);
        while (true)
        {
            var result = await session.HealthAsync();
            if (result.Succeeded) return result.Value!;
            Assert.IsFalse(process.HasExited, "the daemon exited during startup");
            if (result.Failure!.Reason != DaemonUnavailableReason.EndpointUnavailable || DateTime.UtcNow > deadline)
            {
                Assert.Fail($"health failed: {result.Failure}");
            }
            await Task.Delay(100);
        }
    }
}
