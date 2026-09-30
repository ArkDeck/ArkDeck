using System.Diagnostics;
using System.Xml.Linq;

namespace ArkDeck.App.Tests;

internal static class RepoPaths
{
    public static string Root { get; } = FindRoot();

    public static string At(params string[] parts) => Path.Combine([Root, .. parts]);

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "windows", "ArkDeck.Windows.slnx"))) return dir.FullName;
        }
        throw new InvalidOperationException("repository root not found above " + AppContext.BaseDirectory);
    }

    /// <summary>The App's own sources (not generated, not build output).</summary>
    public static IEnumerable<string> AppSources(params string[] patterns) =>
        patterns.SelectMany(pattern => Directory.EnumerateFiles(At("windows", "App"), pattern, SearchOption.AllDirectories))
            .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                        && !p.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"));
}

internal static class Resw
{
    /// <summary>The generated .resw of one language as resource name → value.</summary>
    public static Dictionary<string, string> Load(string language) =>
        XElement.Load(RepoPaths.At("windows", "App", "Strings", language, "Resources.resw"))
            .Elements("data")
            .ToDictionary(d => (string)d.Attribute("name")!, d => (string)d.Element("value")!);

    /// <summary>A lookup as the App's MRT lookup does it (key "." → "_").</summary>
    public static Func<string, string?> Lookup(string language)
    {
        var values = Load(language);
        return key => values.TryGetValue(key.Replace('.', '_'), out var value) ? value : null;
    }
}

internal static class Python
{
    public static (int ExitCode, string Output) Run(params string[] arguments)
    {
        var python = Environment.GetEnvironmentVariable("ARKDECK_PYTHON") is { Length: > 0 } configured ? configured : "python";
        var start = new ProcessStartInfo(python, arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = RepoPaths.Root,
        };
        start.Environment["PYTHONUTF8"] = "1";
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        process.WaitForExit();
        return (process.ExitCode, output);
    }
}
