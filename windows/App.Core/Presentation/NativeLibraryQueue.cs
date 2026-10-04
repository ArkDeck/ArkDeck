namespace ArkDeck.App.Core.Presentation;

/// <summary>A library the deployment queue can hold (macOS <c>NativeLibraryDeploymentSource</c>):
/// a local file (found in a chosen folder, or chosen alone) or a file of a saved SSH source.</summary>
public abstract record NativeLibrarySource
{
    private NativeLibrarySource() { }

    public sealed record File(string Path, string? Directory = null) : NativeLibrarySource;

    public sealed record Ssh(Guid SourceId, string SourceName, string RelativePath) : NativeLibrarySource;

    public string Id => this switch
    {
        File f => "file:" + System.IO.Path.GetFullPath(f.Path),
        Ssh s => $"ssh:{s.SourceId:D}:{s.RelativePath}",
        _ => "",
    };

    public string Name => this switch
    {
        File f => System.IO.Path.GetFileName(f.Path),
        Ssh s => s.RelativePath.Split('/')[^1],
        _ => "",
    };

    public string Location => this switch
    {
        File f => System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(f.Path)) ?? "",
        Ssh s => $"{s.SourceName} · {s.RelativePath}",
        _ => "",
    };
}

/// <summary>Why a folder search stopped (macOS <c>NativeLibraryDirectorySource.Failure</c>).</summary>
public sealed class NativeLibraryDirectoryException(string reason) : Exception(reason)
{
    public const string InvalidDirectory = "Choose 1–4 readable directories. Symbolic links are not followed.";
    public const string TooManyEntries = "The selected directories contain more than 500 entries. Choose a narrower build directory.";
    public const string TooManyLibraries = "More than 100 libraries were found. Choose a narrower build directory.";
}

/// <summary>
/// The lib*.so files in 1–4 chosen folders (macOS <c>NativeLibraryDirectorySource</c>): their
/// subfolders searched, hidden entries skipped, no reparse point (symbolic link or junction)
/// followed, at most 500 entries and 100 libraries, a library counted once, sorted by name. A
/// mounted share works as any folder; nothing is written.
/// </summary>
public static class NativeLibraryDirectorySource
{
    public const int MaximumDirectories = 4;
    public const int MaximumEntries = 500;
    public const int MaximumLibraries = 100;

    public static IReadOnlyList<NativeLibrarySource> Libraries(IReadOnlyList<string> directories, CancellationToken cancellation = default)
    {
        if (directories.Count is < 1 or > MaximumDirectories) throw new NativeLibraryDirectoryException(NativeLibraryDirectoryException.InvalidDirectory);
        var libraries = new List<NativeLibrarySource>();
        var visited = 0;
        foreach (var chosen in directories)
        {
            var directory = new DirectoryInfo(Path.GetFullPath(chosen));
            if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0
                || string.Equals(directory.FullName.TrimEnd('\\'), Path.GetPathRoot(directory.FullName)?.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            {
                throw new NativeLibraryDirectoryException(NativeLibraryDirectoryException.InvalidDirectory);
            }
            var pending = new Stack<DirectoryInfo>([directory]);
            while (pending.TryPop(out var parent))
            {
                cancellation.ThrowIfCancellationRequested();
                FileSystemInfo[] children;
                try
                {
                    children = parent.GetFileSystemInfos();
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    throw new NativeLibraryDirectoryException(NativeLibraryDirectoryException.InvalidDirectory);
                }
                var shown = children.Where(c => !c.Name.StartsWith('.') && (c.Attributes & FileAttributes.Hidden) == 0).ToArray();
                visited += shown.Length;
                if (visited > MaximumEntries) throw new NativeLibraryDirectoryException(NativeLibraryDirectoryException.TooManyEntries);
                foreach (var child in shown)
                {
                    if ((child.Attributes & FileAttributes.ReparsePoint) != 0 || !Contains(child.FullName, directory.FullName)) continue;
                    if (child is DirectoryInfo folder)
                    {
                        pending.Push(folder);
                    }
                    else if (DebugOperations.IsValidNativeLibraryName(child.Name))
                    {
                        libraries.Add(new NativeLibrarySource.File(child.FullName, directory.FullName));
                        if (libraries.Count > MaximumLibraries) throw new NativeLibraryDirectoryException(NativeLibraryDirectoryException.TooManyLibraries);
                    }
                }
            }
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return libraries.Where(l => seen.Add(l.Id)).OrderBy(l => l.Name, StringComparer.Ordinal).ThenBy(l => l.Id, StringComparer.Ordinal).ToArray();
    }

    /// <summary>The file is below the folder by its path, and neither the folder nor anything
    /// between them is a reparse point (macOS: its resolved path is the folder's resolved path
    /// plus the same relative path).</summary>
    public static bool Contains(string file, string directory)
    {
        var root = Path.GetFullPath(directory).TrimEnd('\\') + "\\";
        var path = Path.GetFullPath(file);
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            for (var current = new DirectoryInfo(Path.GetDirectoryName(path)!); ; current = current.Parent!)
            {
                if ((current.Attributes & FileAttributes.ReparsePoint) != 0) return false;
                if (string.Equals(current.FullName.TrimEnd('\\') + "\\", root, StringComparison.OrdinalIgnoreCase)) return true;
                if (current.Parent is null) return false;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}

/// <summary>What the queue asks of the App for one library (macOS
/// <c>NativeLibraryDeploymentProviding</c>): each item keeps the published single-library
/// operation, its reviewed plan and its own Runtime admission, backup and verification.</summary>
public interface INativeLibraryDeployment
{
    Task<(NativeLibraryPreparation? Plan, string? Failure)> PrepareAsync(NativeLibrarySource source, TargetSummary target, string targetBundle);

    Task<SubmitOutcome> SubmitAsync(NativeLibraryPreparation plan);

    Task<(JobTerminal? Terminal, string? Failure)> RunAsync(string jobId);
}

public enum NativeLibraryRowState
{
    Pending,
    Preparing,
    Prepared,
    Submitting,
    Running,
    Succeeded,
    Failed,
}

public sealed class NativeLibraryDeploymentRow(NativeLibrarySource source)
{
    public NativeLibrarySource Source { get; } = source;
    public NativeLibraryRowState State { get; internal set; } = NativeLibraryRowState.Pending;
    public NativeLibraryPreparation? Preparation { get; internal set; }
    public string? JobId { get; internal set; }
    public string? Detail { get; internal set; }
}

public enum NativeLibraryBatchPhase
{
    Idle,
    Preparing,
    Review,
    Running,
    Stopped,
    Succeeded,
    Failed,
}

/// <summary>
/// The reviewed library deployment queue (macOS <c>NativeLibraryDeploymentBatch</c>): 1–16
/// libraries with different lib&lt;name&gt;.so names and one bundle, each prepared as its own plan
/// for the same Target and checked against it, reviewed together, then submitted and run one at a
/// time. The first failure or uncertainty stops the queue: nothing is retried or advanced past it.
/// Changing the Target, bundle or queue invalidates a review; a submitted Job keeps its Target and
/// finishes, and no later item is submitted.
/// </summary>
public sealed class NativeLibraryDeploymentBatch(INativeLibraryDeployment provider)
{
    public const int MaximumLibraries = 16;
    public const string SelectionFailure = "Select 1–16 libraries with different lib<name>.so names and a valid bundle.";

    private int _generation;

    public NativeLibraryBatchPhase Phase { get; private set; } = NativeLibraryBatchPhase.Idle;
    public IReadOnlyList<NativeLibraryDeploymentRow> Rows { get; private set; } = [];
    public TargetSummary? Target { get; private set; }
    public string TargetBundle { get; private set; } = "";
    public string? Failure { get; private set; }
    public bool StopRequested { get; private set; }
    public bool IsBusy { get; private set; }

    /// <summary>Raised after every state change (for the page to re-render).</summary>
    public event Action? Changed;

    public void Invalidate()
    {
        _generation++;
        StopRequested = true;
        if (!IsBusy && Phase != NativeLibraryBatchPhase.Idle) Phase = NativeLibraryBatchPhase.Stopped;
        Changed?.Invoke();
    }

    public void Stop() => Invalidate();

    public async Task PrepareAsync(IReadOnlyList<NativeLibrarySource> sources, TargetSummary target, string targetBundle)
    {
        if (IsBusy) return;
        var current = ++_generation;
        Target = target;
        TargetBundle = targetBundle;
        Rows = sources.Select(s => new NativeLibraryDeploymentRow(s)).ToArray();
        Failure = null;
        StopRequested = false;
        if (sources.Count is < 1 or > MaximumLibraries
            || sources.Select(s => s.Id).Distinct(StringComparer.Ordinal).Count() != sources.Count
            || sources.Select(s => s.Name).Distinct(StringComparer.Ordinal).Count() != sources.Count
            || !sources.All(s => DebugOperations.IsValidNativeLibraryName(s.Name))
            || !DebugOperations.IsValidBundleName(targetBundle))
        {
            Phase = NativeLibraryBatchPhase.Failed;
            Failure = SelectionFailure;
            Changed?.Invoke();
            return;
        }
        IsBusy = true;
        Phase = NativeLibraryBatchPhase.Preparing;
        Changed?.Invoke();
        try
        {
            foreach (var row in Rows)
            {
                if (current != _generation) { Phase = NativeLibraryBatchPhase.Stopped; return; }
                row.State = NativeLibraryRowState.Preparing;
                Changed?.Invoke();
                (NativeLibraryPreparation? Plan, string? Failure) result;
                if (row.Source is NativeLibrarySource.File { Directory: { } directory } file && !NativeLibraryDirectorySource.Contains(file.Path, directory))
                {
                    result = (null, "The selected library is no longer inside its source directory.");
                }
                else
                {
                    result = await provider.PrepareAsync(row.Source, target, targetBundle);
                }
                if (current != _generation) { Phase = NativeLibraryBatchPhase.Stopped; return; }
                if (result.Plan is not { } plan)
                {
                    Fail(row, result.Failure ?? "The plan could not be prepared.");
                    return;
                }
                if (plan.TargetId != target.TargetId || plan.BindingRevision != target.BindingRevision || plan.TargetBundle != targetBundle
                    || plan.LibraryName != row.Source.Name || plan.VerificationProfile != "hashProcessAndMaps" || plan.RollbackPolicy != "autoRollback"
                    || !ArtifactSummary.IsSha256(plan.PlanDigest) || !ArtifactSummary.IsSha256(plan.Sha256))
                {
                    Fail(row, "The plan does not match the selected target and library.");
                    return;
                }
                row.Preparation = plan;
                row.State = NativeLibraryRowState.Prepared;
            }
            Phase = NativeLibraryBatchPhase.Review;
        }
        finally
        {
            IsBusy = false;
            Changed?.Invoke();
        }
    }

    public async Task SubmitReviewedAsync()
    {
        if (IsBusy || Phase != NativeLibraryBatchPhase.Review || StopRequested || Rows.Count == 0
            || !Rows.All(r => r.State == NativeLibraryRowState.Prepared && r.Preparation is not null))
        {
            return;
        }
        IsBusy = true;
        Phase = NativeLibraryBatchPhase.Running;
        var current = _generation;
        Changed?.Invoke();
        try
        {
            foreach (var row in Rows)
            {
                if (current != _generation) { Phase = NativeLibraryBatchPhase.Stopped; return; }
                row.State = NativeLibraryRowState.Submitting;
                Changed?.Invoke();
                var submitted = await provider.SubmitAsync(row.Preparation!);
                if (submitted.JobId is not { Length: > 0 } jobId)
                {
                    // A lost submit reply can hide an admitted Job: never retry or advance.
                    Fail(row, submitted.Failure?.Detail ?? "Runtime did not return the accepted Job ID.");
                    return;
                }
                row.JobId = jobId;
                row.State = NativeLibraryRowState.Running;
                Changed?.Invoke();
                // The accepted Job belongs to the reviewed queue even if the view changed meanwhile.
                var (terminal, failure) = await provider.RunAsync(jobId);
                if (terminal is null)
                {
                    Fail(row, failure ?? $"Job {jobId} did not report its result.");
                    return;
                }
                if (terminal.JobId != jobId || terminal.State != "succeeded" || terminal.OutcomeUnknown || terminal.FailureCode is not null)
                {
                    Fail(row, $"Job {jobId} did not report verified success ({terminal.State}).");
                    return;
                }
                row.State = NativeLibraryRowState.Succeeded;
            }
            Phase = current == _generation ? NativeLibraryBatchPhase.Succeeded : NativeLibraryBatchPhase.Stopped;
        }
        finally
        {
            IsBusy = false;
            Changed?.Invoke();
        }
    }

    private void Fail(NativeLibraryDeploymentRow row, string detail)
    {
        row.State = NativeLibraryRowState.Failed;
        row.Detail = detail;
        Failure = detail;
        Phase = NativeLibraryBatchPhase.Failed;
    }
}
