using System.Diagnostics;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
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

            // History: the Job owner over the root, which holds no Job.
            app.Navigate("history");
            Assert.AreEqual(strings["history.empty.title"], app.WaitForName("history.empty.title", n => n.Length > 0));
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
            // The Session owner over the root: its default Sessions root and policy.
            Assert.AreEqual(Path.Combine(root, "sessions"), app.WaitForName("settings.storage.root", n => n.Length > 0));
            TestContext.WriteLine("storage: retention " + AppSession.Name(app.Find("settings.storage.retention")) + " · Session bytes "
                                  + AppSession.Name(app.Find("settings.storage.session.used")));
            app.Select("settings.tab.trace");
            TestContext.WriteLine("trace cache: " + app.WaitForName("settings.trace.entries", n => n.Length > 0) + " · " + AppSession.Name(app.Find("settings.trace.scope")));
            app.Select("settings.tab.toolchains");
            // Since #2453 the Windows daemon answers runtime.hdc.status as macOS does without an
            // HDC host: the unconfigured status, not a refusal.
            StringAssert.StartsWith(app.WaitForName("settings.toolchains.health", n => n.Length > 0), "unavailable (hdc.notConfigured)");
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

    /// <summary>
    /// Sessions against the real daemon (the Job and Session owners, TASK-XPA-005) over a
    /// development root holding the recorded observe.device@1 Sessions: the App lists them,
    /// pins one, and — after a retention policy the Sessions exceed (set over the pipe, as the
    /// CLI's <c>runtime storage policy</c> does) — cleans up through the Runtime's preview:
    /// exactly the unpinned Session is removed from the disk. The Job Inspector reads the
    /// daemon's empty Job store and a cancellation of an unknown Job is refused as it came.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void SessionsArePinnedAndCleanedUpByTheRealRuntime()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        const string observed = "session-job-0f77f8c52864d676372962eccb17389c";
        const string failed = "session-job-efd52ab9c633074171a19ddd916fffd9";
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-sessions-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            // The first start creates the owner-only Sessions root; the recorded Sessions are
            // copied into it (inheriting its DACL) before the second start reads the catalog.
            (process, _) = StartRootDaemon(signed, root);
            process.Kill();
            process.WaitForExit();
            process.Dispose();
            CopyTree(RepoPaths.At("rust", "tests", "fixtures", "observe-device", "sessions"), Path.Combine(root, "sessions"));
            (process, var endpoint) = StartRootDaemon(signed, root);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "sessions"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            if (app.TryFind("sessions.row." + observed, AppSession.Timeout) is null)
            {
                Assert.Fail("no Session listed: " + (app.TryFind("sessions.unavailable.reason", TimeSpan.FromSeconds(1)) is { } why ? AppSession.Name(why) : "no refusal shown")
                            + " / inspector " + (app.TryFind("jobInspector.unavailable.reason", TimeSpan.FromSeconds(1)) is { } j ? AppSession.Name(j) : "-"));
            }
            app.Select("sessions.row." + observed);
            app.Find("sessions.row." + failed);
            app.Invoke("sessions.pin");
            Assert.AreEqual(strings["windows.sessions.pinnedDone"], app.WaitForName("sessions.status", n => n.Length > 0));

            var status = Frame(endpoint, "runtime.storage.status", "{}");
            var generation = status.GetProperty("result").GetProperty("sessionDomain").GetProperty("generation").GetString();
            Frame(endpoint, "runtime.storage.policy",
                $$"""{"expectedGeneration":"{{generation}}","retentionDays":"1","safetyMarginBytes":"1","totalQuotaBytes":"2"}""");

            app.Invoke("sessions.cleanup");
            TestContext.WriteLine("cleanup preview: " + app.WaitForName("sessions.cleanup.message", n => n.Length > 0));
            app.Find("sessions.cleanup.session." + failed);
            Assert.IsNull(app.TryFind("sessions.cleanup.session." + observed, TimeSpan.FromMilliseconds(300)), "the pinned Session is kept");
            app.Invoke("PrimaryButton");
            TestContext.WriteLine("cleanup: " + app.WaitForName("sessions.status", n => n.StartsWith("Removed", StringComparison.Ordinal)));
            SemanticSnapshotTests.WaitUntil(() => app.TryFind("sessions.row." + failed, TimeSpan.FromMilliseconds(200)) is null, "the removed Session leaves the list");
            Assert.IsFalse(Directory.Exists(Path.Combine(root, "sessions", "2026", "09", failed)), "the Runtime removed the Session");
            Assert.IsTrue(File.Exists(Path.Combine(root, "sessions", "2026", "09", observed, "manifest.json")), "the pinned Session stays");

            // The Job Inspector over the empty Job store.
            Assert.AreEqual(strings["jobInspector.compact.empty"], app.WaitForName("jobInspector.compact.status", n => n == strings["jobInspector.compact.empty"]));
            var refused = Frame(endpoint, "job.cancel", """{"jobId":"job-00000000000000000000000000000000"}""", expectOk: false);
            TestContext.WriteLine("cancel of an unknown Job: " + refused.GetProperty("error").GetProperty("code").GetString());
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
    /// The Agents page against the real Runtime's agent execution and human-action owners
    /// (TASK-XPA-005 S1), over a development root holding the recorded agent-human-action
    /// executions and their Target: the pick-a-device action offers exactly its selection
    /// schema's values, its resume is answered by the Runtime (the recorded deadline has long
    /// passed, so it expires, and the execution ends <c>budgetExpired</c>), and an orchestrating
    /// execution is abandoned after its confirmation, each written to the Runtime's record.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void AgentExecutionsAreResumedAndAbandonedThroughTheRealRuntime()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        const string ambiguousAction = "har-00000000-0000-4000-8000-000000000003";
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-agents-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            // The first start creates the owner-only roots; the recorded executions (their
            // labelled identities read as valid ones, as the Rust process test lays them down)
            // and the adopted Target are copied in before the second start.
            (process, _) = StartRootDaemon(signed, root);
            process.Kill();
            process.WaitForExit();
            process.Dispose();
            var fixture = RepoPaths.At("rust", "tests", "fixtures", "agent-human-action");
            CopyTree(Path.Combine(fixture, "targets-state"), Path.Combine(root, "targets-state"));
            foreach (var file in Directory.GetFiles(Path.Combine(fixture, "agent-executions")))
            {
                File.WriteAllText(Path.Combine(root, "agent-executions", Path.GetFileName(file)), Unlabelled(File.ReadAllText(file)));
            }
            (process, var endpoint) = StartRootDaemon(signed, root);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "agents"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            if (app.TryFind("agents.row.har-ambiguous", AppSession.Timeout) is null)
            {
                Assert.Fail("no execution listed: " + (app.TryFind("agents.unavailable.reason", TimeSpan.FromSeconds(1)) is { } why ? AppSession.Name(why) : "no refusal shown"));
            }
            foreach (var id in new[] { "har-connect", "har-trust", "har-unproven" }) app.Find("agents.row." + id);

            // The waiting pick-a-device action: exactly the Runtime's values, then its answer.
            app.Select("agents.humanAction." + ambiguousAction);
            app.WaitForName("agents.detail.title", n => n == "har-ambiguous");
            var choices = app.Find("agents.action.choices");
            var offered = choices.FindAllDescendants(cf => cf.ByControlType(FlaUI.Core.Definitions.ControlType.RadioButton)).Select(AppSession.Name).ToArray();
            CollectionAssert.AreEqual(new[] { new string('a', 32), new string('b', 32) }, offered);
            app.Invoke("agents.action.resume");
            Assert.AreEqual(strings["windows.agents.action.chooseFirst"], app.WaitForName("agents.status", n => n.Length > 0), "no value: nothing is sent");
            app.Select("agents.action.choice.candidate-00000000-0000-4000-8000-000000000002");
            app.Invoke("agents.action.resume");
            var resumed = app.WaitForName("agents.status", n => n != strings["windows.agents.action.chooseFirst"]);
            TestContext.WriteLine("resume: " + resumed);
            Assert.AreEqual($"{strings["windows.agents.action.refused"]} · "
                            + strings.Format("windows.unavailable.reason", ["humanActionExpired", "the durable orchestration deadline has expired"]), resumed);
            app.WaitForName("agents.row.har-ambiguous", n => n.EndsWith("budgetExpired", StringComparison.Ordinal));
            SemanticSnapshotTests.WaitUntil(() => app.TryFind("agents.humanAction." + ambiguousAction, TimeSpan.FromMilliseconds(200)) is null, "the expired action leaves the waiting list");
            Assert.AreEqual("budgetExpired", Execution(root, "har-ambiguous").GetProperty("state").GetString(), "the Runtime's record");

            // A terminal execution offers no abandon; an orchestrating one is abandoned.
            app.Select("agents.row.har-trust");
            app.WaitForName("agents.detail.title", n => n == "har-trust");
            Assert.IsNull(app.TryFind("agents.abandon", TimeSpan.FromMilliseconds(500)));
            app.Select("agents.row.har-unproven");
            app.WaitForName("agents.detail.title", n => n == "har-unproven");
            app.Invoke("agents.abandon");
            TestContext.WriteLine(app.WaitForName("agents.abandon.message", n => n.Length > 0));
            app.Invoke("PrimaryButton");
            app.WaitForName("agents.status", n => n == strings["windows.agents.abandon.done"]);
            app.WaitForName("agents.row.har-unproven", n => n.EndsWith("abandoned", StringComparison.Ordinal));
            Assert.AreEqual("abandoned", Execution(root, "har-unproven").GetProperty("state").GetString(), "the Runtime's record");
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            Stop(process, directory);
        }
    }

    /// <summary>
    /// The Flash page against the real Runtime over a development root holding the recorded
    /// adopted Target. The Windows daemon composes no ArkForge lane (no HDC tuple is registered),
    /// so Flash is unavailable (<c>provider arkforge is not registered</c>) and its device access
    /// observation fails; a real DAYU200 archive chosen in the system file dialog is reviewed on
    /// the host, passes the Runtime's flash-bundle validator and is imported, and <c>job.plan</c>
    /// is refused before admission with the lane's absence, which ends the preparation. No button
    /// is offered, and nothing reaches the device.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TheFlashPageShowsTheRuntimesRefusalWithoutTheLane()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-flash-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            (process, _) = StartRootDaemon(signed, root);
            process.Kill();
            process.WaitForExit();
            process.Dispose();
            CopyTree(RepoPaths.At("rust", "tests", "fixtures", "agent-human-action", "targets-state"), Path.Combine(root, "targets-state"));
            (process, var endpoint) = StartRootDaemon(signed, root);
            var archive = Path.Combine(Directory.CreateDirectory(Path.Combine(directory.FullName, "files")).FullName, "images.tar.gz");
            File.Copy(RepoPaths.At("rust", "tests", "fixtures", "flash-archive", "archives", "complete.tar.gz"), archive);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "flash"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            Assert.AreEqual(strings["flash.workspace.readiness.blocked"], app.WaitForName("flash.workspace.readiness", n => n.Length > 0));
            Assert.AreEqual("provider arkforge is not registered", AppSession.Name(app.Find("flash.workspace.readiness.detail")));
            Assert.AreEqual(strings.Format("flash.workspace.device.detail", ["TGT-3ba3f5f43b92", "1"]), AppSession.Name(app.Find("flash.workspace.currentDevice.detail")));
            app.Invoke("flash.workspace.details");
            Assert.AreEqual(strings["flash.availability.unavailable"], app.WaitForName("flash.availability.status", n => n.Length > 0));
            Assert.AreEqual(strings.Format("windows.unavailable.reason", ["rejected", "Rockchip device access observation failed"]),
                AppSession.Name(app.Find("flash.deviceAccess.reason")));

            AgentImportFlowTests.ChooseFile(app, "flash.image.choose", archive);
            Assert.AreEqual(strings["flash.error.plan"], app.WaitForName("flash.plan.error", n => n.Length > 0));
            var detail = AppSession.Name(app.Find("flash.plan.error.detail"));
            TestContext.WriteLine("flash plan: " + detail);
            Assert.AreEqual("invalidInput: flash.full-restore@1 is runtime unavailable: no ArkForge lane: ARKDECK_ARKFORGE_BUNDLE_PATH is unset, "
                + "so this daemon performs no Rockchip writes. canonical ArkForge Flash refuses before authorization", detail);
            Assert.IsNull(app.TryFind("flash.execute.submit", TimeSpan.FromMilliseconds(500)), "no button without a plan");
            var imports = Frame(endpoint, "artifact.import.list", """{"pageSize":200}""").GetProperty("result").GetProperty("items").EnumerateArray()
                .Select(i => $"{i.GetProperty("metadata").GetProperty("kind").GetString()}:{i.GetProperty("state").GetString()}").ToArray();
            TestContext.WriteLine("Runtime Imports: " + string.Join(", ", imports));
            CollectionAssert.AreEqual(new[] { "flash-bundle:committed" }, imports);
            Assert.AreEqual(0, Frame(endpoint, "job.list", """{"pageSize":200,"order":"createdAtDescJobIdAsc","includeTimeline":false,"includeCurrent":true}""")
                .GetProperty("result").GetProperty("items").GetArrayLength(), "nothing was admitted");
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            Stop(process, directory);
        }
    }

    /// <summary>
    /// The Debug page against the real Runtime over a development root holding the recorded
    /// adopted Target. No Windows HDC tuple is registered, so the Runtime refuses every Debug
    /// operation before admission and has no Debug probe; the page shows exactly that — each
    /// tab's availability with the Runtime's reason, the probe's refusal where the inventory and
    /// rules would be — and sends nothing an unavailable operation would refuse. A typed request
    /// sent over the pipe is refused the same way (<c>provider hdc is not registered</c>).
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TheDebugPageShowsTheRuntimesRefusalWithoutHdc()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-debug-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            (process, _) = StartRootDaemon(signed, root);
            process.Kill();
            process.WaitForExit();
            process.Dispose();
            CopyTree(RepoPaths.At("rust", "tests", "fixtures", "agent-human-action", "targets-state"), Path.Combine(root, "targets-state"));
            (process, var endpoint) = StartRootDaemon(signed, root);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "debug"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            Assert.AreEqual(strings.Format("debug.target.binding", ["1", "3.2.0d"]), app.WaitForName("debug.target.binding", n => n.Length > 0));
            Assert.AreEqual(strings["debug.availability.unavailable"], app.WaitForName("debug.availability.status", n => n.Length > 0));
            Assert.AreEqual("provider hdc is not registered", app.WaitForName("debug.availability.reason.0", n => n.Length > 0));

            app.Select("debug.tab.logs");
            app.Invoke("debug.logs.start");
            Assert.AreEqual(strings["windows.debug.operationUnavailable"], app.WaitForName("debug.logs.status", n => n.Length > 0), "nothing is sent");
            app.Select("debug.tab.apps");
            var probe = app.WaitForName("debug.apps.inventory.empty.detail", n => n.StartsWith("unavailable(", StringComparison.Ordinal));
            TestContext.WriteLine("probe: " + probe);
            Assert.AreEqual(strings.Format("windows.unavailable.reason", ["internalError", "Debug Runtime probing is not configured"]), probe);
            Assert.AreEqual(strings["debug.jobs.empty"], AppSession.Name(app.Find("debug.apps.jobs.empty")));

            var refused = Frame(endpoint, "job.submit", $$"""{"requestJson":{{JsonSerializer.Serialize(
                """{"documentType":"runtime-operation-request","idempotencyKey":"debug-logs-ui-uitest","inputs":{"durationSeconds":5},"operation":{"id":"capture.diagnostics","version":1},"requestId":"debug-logs-ui-uitest","requestedOutputs":["derivedArtifacts"],"schemaVersion":"1.0.0","target":{"expectedBindingRevision":1,"targetId":"TGT-3ba3f5f43b92"}}""")}}}""", expectOk: false);
            Assert.AreEqual("provider hdc is not registered", refused.GetProperty("error").GetProperty("message").GetString());
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            Stop(process, directory);
        }
    }

    /// <summary>
    /// The Trace, Trace viewer and Viewer pages against the real Runtime over a development root
    /// holding the recorded adopted Target. No Windows HDC tuple is registered, so
    /// <c>capture.diagnostics@1</c> is unavailable (<c>provider hdc is not registered</c>), the
    /// Runtime has no Trace probe and no device observation: the Trace page's first blocker says
    /// so and Start sends nothing; the Viewer's device is not Connected, with the Runtime's reason,
    /// and Capture sends nothing; a local Trace opens in the viewer, which names the missing
    /// parser. No Job is admitted.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TheTraceAndViewerPagesShowTheRuntimesRefusalWithoutHdc()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-trace-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            (process, _) = StartRootDaemon(signed, root);
            process.Kill();
            process.WaitForExit();
            process.Dispose();
            CopyTree(RepoPaths.At("rust", "tests", "fixtures", "agent-human-action", "targets-state"), Path.Combine(root, "targets-state"));
            (process, var endpoint) = StartRootDaemon(signed, root);
            var cache = Directory.CreateDirectory(Path.Combine(directory.FullName, "cache")).FullName;
            var trace = Path.Combine(cache, "local.htrace");
            File.WriteAllBytes(trace, [1, 2, 3]);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "trace", "--cache-root", cache], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            Assert.AreEqual(strings["trace.availability.unavailable"], app.WaitForName("trace.availability.status", n => n.Length > 0));
            var status = app.Find("trace.capture.status");
            Assert.AreEqual(strings["trace.blocker.operation"], AppSession.Name(status));
            var details = status.Properties.FullDescription.ValueOrDefault ?? "";
            TestContext.WriteLine("blockers: " + details.Replace(Environment.NewLine, " | ", StringComparison.Ordinal));
            StringAssert.Contains(details, "provider hdc is not registered");
            StringAssert.Contains(details, strings.Format("windows.unavailable.reason", ["internalError", "Trace Runtime probing is not configured"]));
            Assert.AreEqual("TGT-3ba3f5f43b92", AppSession.Name(app.Find("trace.target.picker").Patterns.Selection.Pattern.Selection.Value.Single()));
            app.Invoke("trace.start");
            Assert.AreEqual(strings["trace.blocker.operation"], app.WaitForName("trace.submission.failure", n => n.Length > 0), "nothing is sent");

            app.Navigate("traceViewer");
            AgentImportFlowTests.ChooseFile(app, "trace.viewer.idle.open", trace);
            Assert.AreEqual(strings["error.title.bundledParserUnavailable"], app.WaitForName("trace.viewer.error.title", n => n.Length > 0));
            Assert.AreEqual("039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81", AppSession.Name(app.Find("trace.viewer.inspector.sha256")));

            app.Navigate("viewer");
            Assert.AreEqual(strings["viewer.empty.selectTarget"], app.WaitForName("viewer.empty.message", n => n.Length > 0));
            app.Find("viewer.target").Patterns.ExpandCollapse.Pattern.Expand();
            var target = app.Find("viewer.target.TGT-3ba3f5f43b92");
            var reason = "Could not read current device state: hdc.notConfigured";
            Assert.AreEqual($"TGT-3ba3f5f43b92 · {reason}", AppSession.Name(target));
            target.Patterns.SelectionItem.Pattern.Select();
            var blocked = strings.Format("viewer.empty.targetBlocked", ["TGT-3ba3f5f43b92", reason]);
            Assert.AreEqual(blocked, app.WaitForName("viewer.empty.message", n => n == blocked));
            app.Invoke("viewer.recapture");
            Assert.AreEqual(blocked, app.WaitForName("viewer.captureFailure", n => n.Length > 0), "nothing is sent");

            Assert.AreEqual(0, Frame(endpoint, "job.list", """{"pageSize":200,"order":"createdAtDescJobIdAsc","includeTimeline":false,"includeCurrent":true}""")
                .GetProperty("result").GetProperty("items").GetArrayLength(), "nothing was admitted");
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            Stop(process, directory);
        }
    }

    /// <summary>
    /// Diagnostics against the Windows daemon over a development root (TASK-XPA-020): no
    /// Diagnostic Session capture is connected, so Arm and Mark say so with the macOS reason code;
    /// with no saved record the page says how to open one, and History has none to open (the
    /// daemon admits no capture without an HDC). Nothing is admitted.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void TheDiagnosticsPageRefusesCaptureWithoutAConfirmedTarget()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-diagnostics-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            (process, var endpoint) = StartRootDaemon(signed, root);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "diagnostics"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            Assert.AreEqual(strings["diagnostics.session.none"], app.WaitForName("diagnostics.session.empty", n => n.Length > 0));
            app.Invoke("diagnostics.capture.arm");
            Assert.AreEqual(strings["diagnostics.capture.chooseTarget"], app.WaitForName("diagnostics.status", n => n.Length > 0));
            app.Invoke("diagnostics.capture.mark");
            Assert.AreEqual("diagnostics_session_control_not_ready", app.WaitForName("diagnostics.status", n => n.Length > 0));
            app.Navigate("history");
            Assert.AreEqual(strings["history.empty.title"], app.WaitForName("history.empty.title", n => n.Length > 0));
            Assert.IsNull(app.TryFind("history.openDiagnostics", TimeSpan.FromMilliseconds(300)));

            Assert.AreEqual(0, Frame(endpoint, "job.list", """{"pageSize":200,"order":"createdAtDescJobIdAsc","includeTimeline":false,"includeCurrent":true}""")
                .GetProperty("result").GetProperty("items").GetArrayLength(), "nothing was admitted");
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            Stop(process, directory);
        }
    }

    /// <summary>
    /// The Imports page against the real Runtime's Import owner (TASK-XPA-008), over a
    /// development root holding the recorded adopted Target: the recorded HAP chosen in the
    /// system file dialog is uploaded in verified chunks and published, then released; a flash
    /// bundle that is not an image archive is sent and refused by its format validator.
    /// </summary>
    [TestMethod]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void AFileIsImportedAndReleasedByTheRealRuntime()
    {
        var exe = AppSession.RequireApp();
        var (thumbprint, daemon, pwsh) = Prerequisites();
        var strings = Catalogue.Load("en-US");
        var directory = Directory.CreateTempSubdirectory("arkdeck-app-uitest-imports-");
        Process? process = null;
        try
        {
            var signed = Path.Combine(directory.FullName, "arkdeck-agentd.exe");
            File.Copy(daemon, signed);
            var pin = Sign(pwsh, thumbprint, signed);
            var root = Directory.CreateDirectory(Path.Combine(directory.FullName, "root")).FullName;
            (process, _) = StartRootDaemon(signed, root);
            process.Kill();
            process.WaitForExit();
            process.Dispose();
            CopyTree(RepoPaths.At("rust", "tests", "fixtures", "agent-human-action", "targets-state"), Path.Combine(root, "targets-state"));
            (process, var endpoint) = StartRootDaemon(signed, root);
            var files = Directory.CreateDirectory(Path.Combine(directory.FullName, "files")).FullName;
            var hap = Path.Combine(files, "fixture.hap");
            File.Copy(RepoPaths.At("rust", "tests", "fixtures", "import-upload-current", "fixture.hap"), hap);
            var flash = Path.Combine(files, "images.tar.gz");
            File.WriteAllBytes(flash, new byte[4096]);

            using var app = AppSession.Launch(exe, ["--language", "en-US", "--page", "imports"], new Dictionary<string, string>
            {
                ["ARKDECK_ENDPOINT"] = endpoint,
                ["ARKDECK_DAEMON_PATH"] = signed,
                ["ARKDECK_DAEMON_SIGNER_SHA256"] = pin,
            });
            if (app.TryFind("imports.empty", AppSession.Timeout) is null)
            {
                Assert.Fail("no Import list: " + (app.TryFind("imports.unavailable.reason", TimeSpan.FromSeconds(1)) is { } why ? AppSession.Name(why) : "no refusal shown"));
            }

            AgentImportFlowTests.Choose(app, hap);
            app.Invoke("imports.start");
            var done = app.WaitForName("imports.status", n => n.Length > 0);
            TestContext.WriteLine("import: " + done);
            StringAssert.StartsWith(done, "Imported fixture.hap as Artifact ART-");
            app.WaitForName("imports.detail.title", n => n == "fixture.hap");
            Assert.AreEqual("committed", app.WaitForName("imports.detail.state", n => n.Length > 0));
            Assert.AreEqual(OracleTarget, AppSession.Name(app.Find("imports.detail.target")));
            Assert.AreEqual("399a301718f951e835b8630ac1666120b96eefb28da9e37f568596a227a9b67a", AppSession.Name(app.Find("imports.detail.sha256")));
            Assert.AreEqual("application/vnd.openharmony.hap", AppSession.Name(app.Find("imports.detail.mediaType")));
            app.Invoke("imports.release");
            app.Find("imports.release.confirm");
            app.Invoke("PrimaryButton");
            app.WaitForName("imports.status", n => n == strings["windows.imports.release.done"]);
            app.WaitForName("imports.detail.state", n => n == "released");

            app.Find("imports.kind").AsComboBox().Select(3);
            app.WaitForName("imports.file", n => n == strings["windows.imports.noFile"]);
            AgentImportFlowTests.Choose(app, flash);
            app.Invoke("imports.start");
            var refused = app.WaitForName("imports.status", n => n.StartsWith(strings["windows.imports.failed"], StringComparison.Ordinal));
            TestContext.WriteLine("flash bundle: " + refused);
            Assert.AreEqual($"{strings["windows.imports.failed"]} · " + strings.Format("windows.unavailable.reason",
                ["invalidInput", "Import content failed its registered format validator"]), refused);

            var listed = Frame(endpoint, "artifact.import.list", """{"pageSize":200}""").GetProperty("result").GetProperty("items").EnumerateArray()
                .Select(i => $"{i.GetProperty("metadata").GetProperty("name").GetString()}:{i.GetProperty("state").GetString()}").ToArray();
            TestContext.WriteLine("Runtime Imports: " + string.Join(", ", listed));
            CollectionAssert.Contains(listed, "fixture.hap:released");
            CollectionAssert.Contains(listed, "images.tar.gz:inProgress");
            foreach (var button in app.Buttons()) Assert.IsTrue(button.Enabled, $"disabled button {button.Id} (XPA-AC-8)");
        }
        finally
        {
            Stop(process, directory);
        }
    }

    /// <summary>The agent-human-action oracle's text with each labelled identity (<c>&lt;har-2&gt;</c>)
    /// read as a valid one of its kind, as the Rust process test lays the records down.</summary>
    private static string Unlabelled(string text) => System.Text.RegularExpressions.Regex.Replace(text, "<(har|resume|candidate|obs)-([0-9]+)>",
        m => $"{m.Groups[1].Value}-00000000-0000-4000-8000-{long.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture):D12}");

    /// <summary>The Runtime's record of one agent execution (named by its identifier's SHA-256).</summary>
    private static JsonElement Execution(string root, string executionId)
    {
        var name = $"execution-{Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(executionId)))}.json";
        return JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "agent-executions", name))).RootElement.Clone();
    }

    private static void Stop(Process? process, DirectoryInfo directory)
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

    private static void CopyTree(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        foreach (var child in Directory.GetDirectories(from)) CopyTree(child, Path.Combine(to, Path.GetFileName(child)));
    }

    /// <summary>One control frame on a plain handle of the daemon's pipe (test setup only, as
    /// the Rust process tests register a project); the reply must succeed.</summary>
    private static JsonElement Frame(string endpoint, string method, string parameters, bool expectOk = true)
    {
        using var pipe = new System.IO.Pipes.NamedPipeClientStream(".", endpoint[@"\\.\pipe\".Length..], System.IO.Pipes.PipeDirection.InOut);
        pipe.Connect(10_000);
        var frame = $$"""{"contractIdentity":"{{ArkDeck.ClientKit.Contract.ControlContract.ContractIdentity}}","id":"setup","method":"{{method}}","params":{{parameters}},"protocolVersion":"{{ArkDeck.ClientKit.Contract.ControlContract.ProtocolVersion}}"}""" + "\n";
        pipe.Write(System.Text.Encoding.UTF8.GetBytes(frame));
        var reply = new List<byte>();
        for (var b = pipe.ReadByte(); b >= 0 && b != '\n'; b = pipe.ReadByte()) reply.Add((byte)b);
        var document = JsonDocument.Parse(reply.ToArray()).RootElement.Clone();
        Assert.AreEqual(expectOk, document.GetProperty("ok").GetBoolean(), $"{method}: {System.Text.Encoding.UTF8.GetString(reply.ToArray())}");
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
