using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ArkDeck.App.UITests;

/// <summary>
/// Opt-in acceptance of an installed RC reading an existing real capture. Supply the original
/// CLI job.result JSON in ARKDECK_RC_CAPTURE_RESULT (diagnostics/Trace) or
/// ARKDECK_RC_VIEWER_RESULT (screenshot/tree), plus the installed-RC connection inputs.
/// The App uses its production transport; every CLI call below is a read. No Job is submitted.
/// Raw HiLog text stays in memory and is never written into the test report.
/// </summary>
[TestClass]
public sealed class InstalledCaptureTests
{
    public TestContext TestContext { get; set; } = null!;

    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void HistoryReopensTheExactScreenshotAndComponentTree(string language)
    {
        var (exe, environment, resultPath) = Prerequisites("ARKDECK_RC_VIEWER_RESULT");
        using var document = JsonDocument.Parse(File.ReadAllBytes(resultPath));
        var envelope = document.RootElement;
        Assert.IsTrue(envelope.GetProperty("ok").GetBoolean());
        Assert.AreEqual("job.result", envelope.GetProperty("command").GetString());
        var result = envelope.GetProperty("result");
        var job = result.GetProperty("job");
        Assert.AreEqual("capture.diagnostics@1", job.GetProperty("operation").GetString());
        Assert.AreEqual("succeeded", job.GetProperty("state").GetString());
        Assert.AreEqual("execute", job.GetProperty("executionMode").GetString());
        Assert.IsFalse(result.GetProperty("evidence").GetProperty("outcomeUnknown").GetBoolean());
        var jobId = job.GetProperty("jobId").GetString()!;
        var artifacts = result.GetProperty("artifacts").EnumerateArray().ToArray();
        var png = Published(artifacts, "screenshot.png");
        var tree = Published(artifacts, "ui-tree.json");
        _ = Published(artifacts, "ui-dump.json");
        var before = ReadJobIds(exe, environment);
        CollectionAssert.Contains(before, jobId);
        using var treeDocument = JsonDocument.Parse(ReadVerifiedArtifact(exe, environment, jobId, tree));
        var root = treeDocument.RootElement;
        while (string.IsNullOrEmpty(root.GetProperty("attributes").GetProperty("type").GetString()))
        {
            var children = root.GetProperty("children");
            Assert.AreEqual(1, children.GetArrayLength(), "this acceptance input must have one typed component root");
            root = children[0];
        }
        var nodeCount = CountNodes(root);
        var rootType = root.GetProperty("attributes").GetProperty("type").GetString()!;
        var strings = Catalogue.Load(language);
        using (var app = AppSession.Launch(exe, ["--language", language, "--page", "history"], environment))
        {
            Assert.IsNull(app.TryFind("app.testTransport", TimeSpan.FromSeconds(1)));
            SelectHistoryJob(app, jobId);
            Assert.AreEqual(jobId, app.WaitForName("history.detail.job", n => n == jobId));
            foreach (var artifact in new[] { png, tree })
                Assert.AreEqual(artifact.GetProperty("sha256").GetString(),
                    AppSession.Name(app.Find($"history.artifact.{artifact.GetProperty("artifactId").GetString()}.sha256")));
            Assert.AreEqual(strings["history.activity.open.viewer"], AppSession.Name(app.Find("history.openWorkspace")));
            var opened = Stopwatch.StartNew();
            app.Invoke("history.openWorkspace");
            // The installed account reads the operation inventory (30 s budget), then the
            // descriptor, Targets, current observation and recent Jobs (10 s each). The
            // scripted tests' 20 s UI wait is shorter than this production read sequence.
            Assert.AreEqual(jobId, app.WaitForName("history.context.job", n => n == jobId, TimeSpan.FromSeconds(80)));
            Assert.AreEqual(job.GetProperty("targetId").GetString(), AppSession.Name(app.Find("history.context.target")));
            Assert.AreEqual(strings["history.context.readOnly"], AppSession.Name(app.Find("history.context.readOnly")));
            var footer = app.WaitForName("viewer.footer", n => n.Length > 0);
            StringAssert.StartsWith(footer, strings.Format("viewer.footer.nodes", [nodeCount.ToString(CultureInfo.InvariantCulture)]));
            Assert.AreEqual(rootType, AppSession.Name(app.Find("viewer.properties.type")));
            Assert.IsNull(app.TryFind("viewer.captureFailure", TimeSpan.FromMilliseconds(100)));
            Assert.IsNull(app.TryFind("viewer.screenshot.unavailable", TimeSpan.FromMilliseconds(100)), "the native image decoder loaded the real PNG");
            app.Find("viewer.screenshot.hitTest");
            Assert.IsNull(app.TryFind("viewer.pane.coordinatesUnverified", TimeSpan.FromMilliseconds(100)), "the real tree and screenshot share verified coordinates");
            var shownCount = AppSession.Name(app.Find("viewer.tree.count")).Split('/');
            Assert.AreEqual(nodeCount, int.Parse(shownCount[1].Trim(), CultureInfo.InvariantCulture));
            app.Find("viewer.inspector.tab.rawDump").Patterns.Toggle.Pattern.Toggle();
            using var shown = JsonDocument.Parse(app.WaitForName("viewer.rawDump", n => n.Length > 0));
            Assert.AreEqual(rootType, shown.RootElement.GetProperty("attributes").GetProperty("type").GetString());
            Assert.IsNull(app.TryFind("app.recovery.retry", TimeSpan.FromMilliseconds(100)));
            TestContext.WriteLine($"{language}: exact historical PNG/tree digests, native screenshot decoding, verified coordinates, {nodeCount} components and selected raw node passed for {jobId}; historical Viewer checks took {opened.ElapsedMilliseconds} ms (not a startup performance claim).");
        }
        CollectionAssert.AreEquivalent(before, ReadJobIds(exe, environment), "opening the historical Viewer does not recapture or create a Job");
    }

    [TestMethod]
    [DataRow("en-US")]
    [DataRow("zh-Hans")]
    [Timeout(300_000, CooperativeCancellation = true)]
    public void HistoryReopensTheExactCaptureAndVerifiedTrace(string language)
    {
        var (exe, environment, resultPath) = Prerequisites();
        using var document = JsonDocument.Parse(File.ReadAllBytes(resultPath));
        var envelope = document.RootElement;
        Assert.IsTrue(envelope.GetProperty("ok").GetBoolean(), "supply a successful CLI job.result envelope");
        Assert.AreEqual("job.result", envelope.GetProperty("command").GetString());
        var result = envelope.GetProperty("result");
        var job = result.GetProperty("job");
        var evidence = result.GetProperty("evidence");
        Assert.AreEqual("capture.diagnostics@1", job.GetProperty("operation").GetString());
        Assert.AreEqual("succeeded", job.GetProperty("state").GetString());
        Assert.AreEqual("execute", job.GetProperty("executionMode").GetString());
        Assert.IsFalse(evidence.GetProperty("outcomeUnknown").GetBoolean());
        var jobId = job.GetProperty("jobId").GetString()!;
        var target = job.GetProperty("targetId").GetString()!;
        var artifacts = result.GetProperty("artifacts").EnumerateArray().ToArray();
        var trace = Published(artifacts, "trace.htrace");
        var hilog = Published(artifacts, "hilog.txt");
        var before = ReadJobIds(exe, environment);
        CollectionAssert.Contains(before, jobId, "the supplied capture belongs to this installed Runtime");
        var cache = Directory.CreateTempSubdirectory("arkdeck-installed-capture-");
        var strings = Catalogue.Load(language);
        try
        {
            using (var app = AppSession.Launch(exe, ["--language", language, "--page", "history", "--cache-root", cache.FullName], environment))
            {
                Assert.IsNull(app.TryFind("app.testTransport", TimeSpan.FromSeconds(1)), "production transport only");
                SelectHistoryJob(app, jobId);
                Assert.AreEqual(jobId, app.WaitForName("history.detail.job", n => n == jobId));
                Assert.AreEqual(target, AppSession.Name(app.Find("history.detail.target")));
                Assert.AreEqual(strings["history.state.succeeded"], AppSession.Name(app.Find("history.detail.state")));
                Assert.AreEqual(evidence.GetProperty("catalogDigest").GetString(), AppSession.Name(app.Find("history.evidence.catalog")));
                foreach (var artifact in artifacts)
                {
                    var id = artifact.GetProperty("artifactId").GetString()!;
                    var name = artifact.GetProperty("name").GetString()!;
                    var status = artifact.GetProperty("status").GetString()!;
                    Assert.AreEqual(name, AppSession.Name(app.Find($"history.artifact.{id}.name")));
                    Assert.AreEqual(status, AppSession.Name(app.Find($"history.artifact.{id}.status")));
                    if (status == "published")
                    {
                        Assert.IsTrue(artifact.GetProperty("bytesVerified").GetBoolean(), "the reference capture was fully verified");
                        Assert.AreEqual(artifact.GetProperty("sha256").GetString(), AppSession.Name(app.Find($"history.artifact.{id}.sha256")));
                    }
                    else
                    {
                        Assert.IsNull(app.TryFind("history.artifact.export." + id, TimeSpan.FromMilliseconds(100)), "unpublished bytes cannot be exported");
                    }
                }

                app.Invoke("history.openDiagnostics");
                Assert.AreEqual(jobId, app.WaitForName("diagnostics.session.job", n => n == jobId));
                Assert.AreEqual(jobId, AppSession.Name(app.Find("history.context.job")));
                Assert.AreEqual(target, AppSession.Name(app.Find("history.context.target")));
                Assert.AreEqual(strings["history.context.readOnly"], AppSession.Name(app.Find("history.context.readOnly")));
                foreach (var control in new[] { "arm", "mark", "stop", "cancelPreparation" })
                    Assert.IsNull(app.TryFind("diagnostics.capture." + control, TimeSpan.FromMilliseconds(100)), "historical capture has no live controls");
                foreach (var artifact in artifacts)
                {
                    var name = artifact.GetProperty("name").GetString()!;
                    Assert.AreEqual(name, AppSession.Name(app.Find("diagnostics.artifact." + name)));
                    Assert.AreEqual($"{artifact.GetProperty("status").GetString()} · {artifact.GetProperty("byteCount").GetString()} B · {artifact.GetProperty("privacy").GetString()}",
                        AppSession.Name(app.Find($"diagnostics.artifact.{name}.facts")));
                }

                Assert.IsNull(app.TryFind("diagnostics.preview.text", TimeSpan.FromMilliseconds(100)), "text is read only on explicit request");
                app.Invoke("diagnostics.artifact.read.hilog.txt");
                Assert.AreEqual("hilog.txt", app.WaitForName("diagnostics.preview.text", n => n == "hilog.txt"));
                var preview = app.Find("diagnostics.preview.text");
                Assert.IsTrue(preview.Patterns.Text.IsSupported, "the real preview is selectable text");
                var read = ReadCli(exe, environment, ["artifact", "read", "--job", jobId, "--artifact",
                    hilog.GetProperty("artifactId").GetString()!, "--offset", "0", "--max-bytes", "4096", "--allow-sensitive"]);
                Assert.AreEqual(hilog.GetProperty("sha256").GetString(), read.GetProperty("artifactDigest").GetString());
                var expectedText = Normalize(Encoding.UTF8.GetString(Convert.FromBase64String(read.GetProperty("base64").GetString()!)));
                Assert.IsTrue(expectedText.Length >= 256, "this acceptance capture must contain usable HiLog text");
                var shownText = Normalize(preview.Patterns.Text.Pattern.DocumentRange.GetText(1024));
                Assert.IsTrue(shownText.StartsWith(expectedText[..256], StringComparison.Ordinal), "the preview begins with the exact recorded HiLog bytes");

                app.Invoke("diagnostics.artifacts.openTrace");
                var fileName = app.WaitForName("trace.viewer.document", n => n.EndsWith(".htrace", StringComparison.Ordinal));
                var digest = trace.GetProperty("sha256").GetString()!;
                var byteCount = trace.GetProperty("byteCount").GetString()!;
                Assert.AreEqual(digest, AppSession.Name(app.Find("trace.viewer.inspector.sha256")));
                Assert.AreEqual(long.Parse(byteCount, CultureInfo.InvariantCulture),
                    long.Parse(AppSession.Name(app.Find("trace.viewer.inspector.sourceBytes")), NumberStyles.AllowThousands, CultureInfo.InvariantCulture));
                Assert.AreEqual(Path.GetFileName(fileName), fileName, "the viewer names one local cached file");
                var cached = Path.Combine(cache.FullName, "TraceInbox", fileName);
                Assert.AreEqual(long.Parse(byteCount, CultureInfo.InvariantCulture), new FileInfo(cached).Length);
                using var stream = File.OpenRead(cached);
                Assert.AreEqual(digest, Convert.ToHexStringLower(SHA256.HashData(stream)), "the App cached the complete exact Trace");
                Assert.IsNull(app.TryFind("app.recovery.retry", TimeSpan.FromMilliseconds(100)), "the installed Runtime remains connected");
                TestContext.WriteLine($"{language}: exact History inventory ({artifacts.Length} rows), read-only Diagnostics, matching HiLog prefix, and whole Trace SHA-256 passed for {jobId}.");
            }
            CollectionAssert.AreEquivalent(before, ReadJobIds(exe, environment), "reading existing records creates no Job");
        }
        finally
        {
            DeleteOwnedCache(cache);
        }
    }

    private static JsonElement Published(JsonElement[] artifacts, string name)
    {
        var found = artifacts.Single(a => a.GetProperty("name").GetString() == name);
        Assert.AreEqual("published", found.GetProperty("status").GetString(), name);
        Assert.IsTrue(long.Parse(found.GetProperty("byteCount").GetString()!, CultureInfo.InvariantCulture) > 0, name);
        return found;
    }

    private static string Normalize(string text) => text.Replace("\r\n", "\n", StringComparison.Ordinal);

    private static void SelectHistoryJob(AppSession app, string jobId)
    {
        // Filter through the real search control so off-screen virtualized rows do not
        // determine whether UIA can select the record. This changes no saved filter.
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < TimeSpan.FromSeconds(80))
        {
            if (app.TryFind("history.unavailable.reason", TimeSpan.FromMilliseconds(100)) is { } unavailable)
                Assert.Fail("the installed App reports History unavailable: " + AppSession.Name(unavailable));
            if (app.TryFind("history.filter.search", TimeSpan.FromMilliseconds(200)) is { } search)
            {
                search.Patterns.Value.Pattern.SetValue(jobId);
                for (var page = 0; page < 10; page++)
                {
                    if (app.TryFind("history.row." + jobId, TimeSpan.FromSeconds(1)) is { } row)
                    {
                        row.Patterns.SelectionItem.Pattern.Select();
                        return;
                    }
                    if (app.TryFind("history.loadOlder", TimeSpan.FromMilliseconds(100)) is not { } older) break;
                    var count = AppSession.Name(app.Find("history.filter.resultCount"));
                    older.Patterns.Invoke.Pattern.Invoke();
                    app.WaitForName("history.filter.resultCount", n => n != count);
                }
                Assert.Fail("the recorded Job was not found through History's search and bounded older-page reads");
                return;
            }
            if (app.TryFind("app.recovery.reason", TimeSpan.FromMilliseconds(100)) is { } failure)
                Assert.Fail("the installed App could not read History: " + AppSession.Name(failure));
        }
        Assert.Fail("History was not ready in the installed App's bounded readiness window");
    }

    private static (string Exe, Dictionary<string, string> Environment, string Result) Prerequisites(string resultVariable = "ARKDECK_RC_CAPTURE_RESULT")
    {
        var exe = Environment.GetEnvironmentVariable("ARKDECK_RC_APP");
        var endpoint = Environment.GetEnvironmentVariable("ARKDECK_RC_ENDPOINT");
        var result = Environment.GetEnvironmentVariable(resultVariable);
        var pin = Environment.GetEnvironmentVariable("ARKDECK_RC_SIGNER_SHA256");
        var organization = Environment.GetEnvironmentVariable("ARKDECK_RC_PUBLISHER_ORGANIZATION");
        var eku = Environment.GetEnvironmentVariable("ARKDECK_RC_PUBLISHER_EKU");
        var publisher = !string.IsNullOrEmpty(organization) && !string.IsNullOrEmpty(eku);
        if (Environment.GetEnvironmentVariable("ARKDECK_APP_UITESTS") != "1"
            || string.IsNullOrEmpty(exe) || string.IsNullOrEmpty(endpoint) || string.IsNullOrEmpty(result)
            || (!publisher && string.IsNullOrEmpty(pin)))
            Assert.Inconclusive($"skipped: set installed-RC connection inputs and {resultVariable} to a real capture's CLI job.result JSON");
        Assert.IsTrue(File.Exists(exe) && File.Exists(result), "installed App and captured result must exist");
        Assert.IsTrue(new FileInfo(result!).Length <= 16 * 1024 * 1024, "bounded capture metadata");
        var environment = new Dictionary<string, string> { ["ARKDECK_ENDPOINT"] = endpoint! };
        if (publisher)
        {
            environment["ARKDECK_DAEMON_PUBLISHER_ORGANIZATION"] = organization!;
            environment["ARKDECK_DAEMON_PUBLISHER_EKU"] = eku!;
        }
        else environment["ARKDECK_DAEMON_SIGNER_SHA256"] = pin!;
        return (exe!, environment, result!);
    }

    private static string[] ReadJobIds(string exe, Dictionary<string, string> environment)
    {
        var result = ReadCli(exe, environment, ["job", "list", "--page-size", "1000"]);
        Assert.IsFalse(result.GetProperty("hasMore").GetBoolean(), "a complete bounded Job census is required");
        var ids = result.GetProperty("items").EnumerateArray().Select(j => j.GetProperty("jobId").GetString()!).ToArray();
        Assert.AreEqual(ids.Length, ids.Distinct(StringComparer.Ordinal).Count(), "one entry per Job");
        return ids;
    }

    private static int CountNodes(JsonElement node) => 1 + (node.TryGetProperty("children", out var children)
        ? children.EnumerateArray().Sum(CountNodes) : 0);

    private static byte[] ReadVerifiedArtifact(string exe, Dictionary<string, string> environment, string jobId, JsonElement artifact)
    {
        var expected = long.Parse(artifact.GetProperty("byteCount").GetString()!, CultureInfo.InvariantCulture);
        Assert.IsTrue(expected is > 0 and <= 16 * 1024 * 1024, "bounded component-tree acceptance input");
        using var bytes = new MemoryStream();
        while (true)
        {
            var read = ReadCli(exe, environment, ["artifact", "read", "--job", jobId, "--artifact",
                artifact.GetProperty("artifactId").GetString()!, "--offset", bytes.Length.ToString(CultureInfo.InvariantCulture),
                "--max-bytes", "4194304", "--allow-sensitive"]);
            Assert.AreEqual(bytes.Length, read.GetProperty("offset").GetInt64());
            var chunk = Convert.FromBase64String(read.GetProperty("base64").GetString()!);
            Assert.IsTrue(chunk.Length > 0 && bytes.Length + chunk.Length <= expected);
            bytes.Write(chunk);
            if (read.GetProperty("eof").GetBoolean()) break;
        }
        Assert.AreEqual(expected, bytes.Length);
        var payload = bytes.ToArray();
        Assert.AreEqual(artifact.GetProperty("sha256").GetString(), Convert.ToHexStringLower(SHA256.HashData(payload)));
        return payload;
    }

    private static JsonElement ReadCli(string exe, Dictionary<string, string> environment, string[] arguments)
    {
        var root = Path.GetDirectoryName(exe)!;
        var start = new ProcessStartInfo(Path.Combine(root, "bin", "arkdeck.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root,
            RedirectStandardOutput = true, RedirectStandardError = true,
        };
        foreach (var key in start.Environment.Keys.ToArray())
            if (key.StartsWith("ARKDECK_", StringComparison.OrdinalIgnoreCase)) start.Environment.Remove(key);
        foreach (var (key, value) in environment) start.Environment[key] = value;
        start.Environment["ARKDECK_DAEMON_PATH"] = Path.Combine(root, "arkdeck-agentd.exe");
        foreach (var argument in new[] { "--output", "json" }.Concat(arguments)) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(60_000))
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
            Assert.Fail("published CLI read exceeded its deadline");
        }
        Task.WaitAll(stdout, stderr);
        Assert.AreEqual(0, process.ExitCode, "published CLI read must succeed; raw output is not included in the report");
        using var document = JsonDocument.Parse(stdout.Result);
        Assert.IsTrue(document.RootElement.GetProperty("ok").GetBoolean());
        return document.RootElement.GetProperty("result").Clone();
    }

    private static void DeleteOwnedCache(DirectoryInfo directory)
    {
        var path = Path.GetFullPath(directory.FullName);
        var temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) + Path.DirectorySeparatorChar;
        Assert.IsTrue(path.StartsWith(temp, StringComparison.OrdinalIgnoreCase)
            && directory.Name.StartsWith("arkdeck-installed-capture-", StringComparison.Ordinal), "cleanup stays in this test's private temporary directory");
        var pending = new Stack<DirectoryInfo>();
        pending.Push(directory);
        while (pending.TryPop(out var current))
        {
            Assert.IsFalse(current.Attributes.HasFlag(FileAttributes.ReparsePoint), "cleanup refuses reparse directories");
            foreach (var entry in current.EnumerateFileSystemInfos())
            {
                Assert.IsFalse(entry.Attributes.HasFlag(FileAttributes.ReparsePoint), "cleanup refuses reparse entries");
                if (entry is DirectoryInfo child) pending.Push(child);
            }
        }
        directory.Delete(recursive: true);
    }
}
