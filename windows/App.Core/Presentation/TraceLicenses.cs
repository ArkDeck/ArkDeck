namespace ArkDeck.App.Core.Presentation;

public enum TraceLicenseStatus { Loading, Available, Unavailable }

/// <summary>Original UTF-8 text, or a bounded local refusal. No Runtime state is consulted.</summary>
public sealed record TraceLicenseText(TraceLicenseStatus Status, string? Text = null, string? Reason = null);

public sealed record TraceLicenseSnapshot(TraceLicenseText Product, TraceLicenseText Notices, bool CanReveal)
{
    internal static TraceLicenseSnapshot Loading { get; } = new(new(TraceLicenseStatus.Loading), new(TraceLicenseStatus.Loading), false);
}

/// <summary>Settings › Trace's lazy App-local ArkTrace legal resources. The fixed layout is
/// ArkTrace/LICENSE, ArkTrace/THIRD_PARTY_NOTICES.md and ArkTrace/Licenses, beside the App.
/// A missing Windows ArkTrace bundle stays unavailable; another platform's notices are never substituted.</summary>
public sealed class TraceLicenses
{
    private readonly string? _appDirectory;
    private readonly Lazy<Task<TraceLicenseSnapshot>> _load;
    private TraceLicenseSnapshot _snapshot = TraceLicenseSnapshot.Loading;

    private TraceLicenses(string appDirectory)
        : this(() => TraceLicenseFiles.Load(appDirectory)) => _appDirectory = appDirectory;

    internal TraceLicenses(Func<TraceLicenseSnapshot> load) =>
        _load = new(() => Task.Run(() =>
        {
            var result = load();
            Volatile.Write(ref _snapshot, result);
            return result;
        }), LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>Uses only the running App's resource directory; construction performs no file I/O.</summary>
    public static TraceLicenses ForApp() => new(AppContext.BaseDirectory);

    internal static TraceLicenses At(string appDirectory) => new(appDirectory);

    public TraceLicenseSnapshot Snapshot => Volatile.Read(ref _snapshot);

    /// <summary>One bounded read, off the UI thread, on the first visit to Licenses.</summary>
    public Task<TraceLicenseSnapshot> LoadAsync() => _load.Value;

    /// <summary>Rechecks the local folder and holds its no-follow directory handles through Reveal.</summary>
    public TraceLicenseFolder? OpenLicenseFolder() =>
        Snapshot.CanReveal && _appDirectory is { } root ? TraceLicenseFiles.OpenLicenseFolder(root) : null;
}
