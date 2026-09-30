namespace ArkDeck.Spk4.Tests;

internal static class RepoPaths
{
    /// <summary>The repository root, found by walking up from the test binaries.</summary>
    public static string Root { get; } = FindRoot();

    public static string Spike => Path.Combine(Root, "windows", "spikes", "spk4");

    public static string At(params string[] parts) => Path.Combine([Root, .. parts]);

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "windows", "spikes", "spk4", "global.json"))) return dir.FullName;
        }
        throw new InvalidOperationException("repository root not found above " + AppContext.BaseDirectory);
    }
}
