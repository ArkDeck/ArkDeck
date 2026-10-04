using ArkDeck.App.Core.Presentation;

namespace ArkDeck.App.Tests;

/// <summary>Debug's folder sources and reviewed deployment queue (macOS #2466:
/// <c>NativeLibraryDirectorySource</c> and <c>NativeLibraryDeploymentBatch</c>, pinned by
/// <c>NativeLibraryDeploymentBatchTests</c>).</summary>
[TestClass]
public sealed class NativeLibraryQueueTests
{
    private static DirectoryInfo Tree()
    {
        var root = Directory.CreateTempSubdirectory("arkdeck-queue-");
        Directory.CreateDirectory(Path.Combine(root.FullName, "arm64", "deep"));
        File.WriteAllBytes(Path.Combine(root.FullName, "libtop.so"), [1]);
        File.WriteAllBytes(Path.Combine(root.FullName, "arm64", "libentry.so"), [1]);
        File.WriteAllBytes(Path.Combine(root.FullName, "arm64", "deep", "libdeep.so"), [1]);
        File.WriteAllBytes(Path.Combine(root.FullName, "arm64", "notes.txt"), [1]);
        File.WriteAllBytes(Path.Combine(root.FullName, ".libhidden.so"), [1]);
        var hidden = Path.Combine(root.FullName, "libsecret.so");
        File.WriteAllBytes(hidden, [1]);
        File.SetAttributes(hidden, FileAttributes.Hidden);
        return root;
    }

    [TestMethod]
    public void FoldersAreSearchedForLibrariesWithoutFollowingLinks()
    {
        var root = Tree();
        var outside = Directory.CreateTempSubdirectory("arkdeck-queue-outside-");
        try
        {
            File.WriteAllBytes(Path.Combine(outside.FullName, "liboutside.so"), [1]);
            Directory.CreateSymbolicLink(Path.Combine(root.FullName, "link"), outside.FullName);
        }
        catch (IOException)
        {
            // Creating a symbolic link may need Developer Mode; the rest still runs.
        }
        catch (UnauthorizedAccessException)
        {
        }
        try
        {
            var found = NativeLibraryDirectorySource.Libraries([root.FullName]);
            CollectionAssert.AreEqual(new[] { "libdeep.so", "libentry.so", "libtop.so" }, found.Select(f => f.Name).ToArray());
            Assert.IsTrue(found.All(f => f is NativeLibrarySource.File { Directory: not null }));
            Assert.AreEqual(3, NativeLibraryDirectorySource.Libraries([root.FullName, root.FullName]).Count, "a library is counted once");
            Assert.IsTrue(NativeLibraryDirectorySource.Contains(Path.Combine(root.FullName, "arm64", "libentry.so"), root.FullName));
            Assert.IsFalse(NativeLibraryDirectorySource.Contains(Path.Combine(outside.FullName, "liboutside.so"), root.FullName));
            Assert.IsFalse(NativeLibraryDirectorySource.Contains(root.FullName + "-sibling\\libx.so", root.FullName));
        }
        finally
        {
            root.Delete(recursive: true);
            outside.Delete(recursive: true);
        }
    }

    [TestMethod]
    public void TheSearchIsBounded()
    {
        Assert.AreEqual(NativeLibraryDirectoryException.InvalidDirectory,
            Assert.ThrowsExactly<NativeLibraryDirectoryException>(() => NativeLibraryDirectorySource.Libraries([])).Message);
        Assert.AreEqual(NativeLibraryDirectoryException.InvalidDirectory,
            Assert.ThrowsExactly<NativeLibraryDirectoryException>(() => NativeLibraryDirectorySource.Libraries(["C:\\"])).Message, "a drive root is refused");
        Assert.AreEqual(NativeLibraryDirectoryException.InvalidDirectory,
            Assert.ThrowsExactly<NativeLibraryDirectoryException>(() => NativeLibraryDirectorySource.Libraries(["a", "b", "c", "d", "e"])).Message);
        var many = Directory.CreateTempSubdirectory("arkdeck-queue-many-");
        var libraries = Directory.CreateTempSubdirectory("arkdeck-queue-libs-");
        try
        {
            for (var i = 0; i < 501; i++) File.WriteAllBytes(Path.Combine(many.FullName, $"f{i}.txt"), [1]);
            Assert.AreEqual(NativeLibraryDirectoryException.TooManyEntries,
                Assert.ThrowsExactly<NativeLibraryDirectoryException>(() => NativeLibraryDirectorySource.Libraries([many.FullName])).Message);
            for (var i = 0; i < 101; i++) File.WriteAllBytes(Path.Combine(libraries.FullName, $"lib{i}.so"), [1]);
            Assert.AreEqual(NativeLibraryDirectoryException.TooManyLibraries,
                Assert.ThrowsExactly<NativeLibraryDirectoryException>(() => NativeLibraryDirectorySource.Libraries([libraries.FullName])).Message);
        }
        finally
        {
            many.Delete(recursive: true);
            libraries.Delete(recursive: true);
        }
    }

    // ---- the queue ----

    private static readonly TargetSummary Target = new("TGT-1", null, "1", 3, "2026-10-04T00:00:00Z", "3.2.0f");

    private sealed class Fake : INativeLibraryDeployment
    {
        public List<string> Calls { get; } = [];
        public Func<NativeLibrarySource, NativeLibraryPreparation?> Plan { get; set; } = s => Prepared(s.Name);
        public Func<string, SubmitOutcome> Submit { get; set; } = name => new SubmitOutcome("job-" + name, null, null, true);
        public Func<string, JobTerminal?> Terminal { get; set; } = job => new JobTerminal(job, "succeeded", false, null, []);

        public Task<(NativeLibraryPreparation? Plan, string? Failure)> PrepareAsync(NativeLibrarySource source, TargetSummary target, string targetBundle)
        {
            Calls.Add("prepare " + source.Name);
            var plan = Plan(source);
            return Task.FromResult((plan, plan is null ? "refused" : (string?)null));
        }

        public Task<SubmitOutcome> SubmitAsync(NativeLibraryPreparation plan)
        {
            Calls.Add("submit " + plan.LibraryName);
            return Task.FromResult(Submit(plan.LibraryName));
        }

        public Task<(JobTerminal? Terminal, string? Failure)> RunAsync(string jobId)
        {
            Calls.Add("run " + jobId);
            var terminal = Terminal(jobId);
            return Task.FromResult((terminal, terminal is null ? "unreadable" : (string?)null));
        }
    }

    private static NativeLibraryPreparation Prepared(string name, string target = "TGT-1", long binding = 3) =>
        new(target, binding, name, 588, new string('a', 64), "arm64-v8a", 64, 183, "build", "com.example.demo", "hashProcessAndMaps", "autoRollback",
            new string('b', 64), [], null!);

    private static NativeLibrarySource Library(string name) => new NativeLibrarySource.File("C:\\out\\" + name);

    [TestMethod]
    public async Task EveryLibraryIsPlannedReviewedThenRunInTurn()
    {
        var fake = new Fake();
        var batch = new NativeLibraryDeploymentBatch(fake);
        await batch.PrepareAsync([Library("liba.so"), Library("libb.so")], Target, "com.example.demo");
        Assert.AreEqual(NativeLibraryBatchPhase.Review, batch.Phase);
        Assert.IsTrue(batch.Rows.All(r => r.State == NativeLibraryRowState.Prepared));
        await batch.SubmitReviewedAsync();
        Assert.AreEqual(NativeLibraryBatchPhase.Succeeded, batch.Phase);
        CollectionAssert.AreEqual(new[] { "prepare liba.so", "prepare libb.so", "submit liba.so", "run job-liba.so", "submit libb.so", "run job-libb.so" }, fake.Calls);
    }

    [TestMethod]
    public async Task ASelectionOutsideTheRulesIsRefusedBeforeAnythingIsPlanned()
    {
        var fake = new Fake();
        var batch = new NativeLibraryDeploymentBatch(fake);
        await batch.PrepareAsync([Library("liba.so"), new NativeLibrarySource.File("C:\\other\\liba.so")], Target, "com.example.demo");
        Assert.AreEqual((NativeLibraryBatchPhase.Failed, NativeLibraryDeploymentBatch.SelectionFailure), (batch.Phase, batch.Failure));
        await batch.PrepareAsync(Enumerable.Range(0, 17).Select(i => Library($"lib{i}.so")).ToArray(), Target, "com.example.demo");
        Assert.AreEqual(NativeLibraryBatchPhase.Failed, batch.Phase);
        await batch.PrepareAsync([Library("liba.so")], Target, "not a bundle");
        Assert.AreEqual(NativeLibraryBatchPhase.Failed, batch.Phase);
        Assert.AreEqual(0, fake.Calls.Count);
    }

    [TestMethod]
    public async Task APlanForAnotherTargetOrLibraryStopsTheQueue()
    {
        var fake = new Fake { Plan = s => s.Name == "libb.so" ? Prepared("libb.so", binding: 4) : Prepared(s.Name) };
        var batch = new NativeLibraryDeploymentBatch(fake);
        await batch.PrepareAsync([Library("liba.so"), Library("libb.so"), Library("libc.so")], Target, "com.example.demo");
        Assert.AreEqual((NativeLibraryBatchPhase.Failed, "The plan does not match the selected target and library."), (batch.Phase, batch.Failure));
        CollectionAssert.AreEqual(new[] { "prepare liba.so", "prepare libb.so" }, fake.Calls);
    }

    [TestMethod]
    public async Task ALostSubmitOrAnUncertainResultStopsWithoutRetrying()
    {
        var lost = new Fake { Submit = name => name == "libb.so" ? new SubmitOutcome(null, new Unavailable("outcomeUnknown", "no reply", "cli", null), null, true) : new("job-" + name, null, null, true) };
        var batch = new NativeLibraryDeploymentBatch(lost);
        await batch.PrepareAsync([Library("liba.so"), Library("libb.so"), Library("libc.so")], Target, "com.example.demo");
        await batch.SubmitReviewedAsync();
        Assert.AreEqual((NativeLibraryBatchPhase.Failed, "no reply"), (batch.Phase, batch.Failure));
        Assert.AreEqual(1, lost.Calls.Count(c => c == "submit libb.so"));
        Assert.IsFalse(lost.Calls.Contains("submit libc.so"));

        var unknown = new Fake { Terminal = job => new JobTerminal(job, "succeeded", true, "outcomeUnknown", []) };
        batch = new NativeLibraryDeploymentBatch(unknown);
        await batch.PrepareAsync([Library("liba.so"), Library("libb.so")], Target, "com.example.demo");
        await batch.SubmitReviewedAsync();
        Assert.AreEqual(NativeLibraryBatchPhase.Failed, batch.Phase);
        Assert.IsFalse(unknown.Calls.Contains("submit libb.so"));
    }

    [TestMethod]
    public async Task AnInvalidatedReviewIsNotSubmitted()
    {
        var fake = new Fake();
        var batch = new NativeLibraryDeploymentBatch(fake);
        await batch.PrepareAsync([Library("liba.so")], Target, "com.example.demo");
        batch.Invalidate();
        Assert.AreEqual(NativeLibraryBatchPhase.Stopped, batch.Phase);
        await batch.SubmitReviewedAsync();
        Assert.IsFalse(fake.Calls.Any(c => c.StartsWith("submit", StringComparison.Ordinal)));
    }
}
