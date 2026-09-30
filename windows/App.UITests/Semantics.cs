using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ArkDeck.App.UITests;

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
}

/// <summary>The shared catalogue (spec/ui-semantics/strings.json) in one language.</summary>
internal sealed partial class Catalogue
{
    private readonly Dictionary<string, string> _values;

    private Catalogue(string language, Dictionary<string, string> values)
    {
        Language = language;
        _values = values;
    }

    public string Language { get; }

    /// <summary>The App language tag → the catalogue's language member.</summary>
    public static Catalogue Load(string appLanguage)
    {
        var member = appLanguage == "zh-Hans" ? "zh-Hans" : "en";
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "ui-semantics", "strings.json")));
        var values = doc.RootElement.GetProperty("entries").EnumerateArray()
            .ToDictionary(e => e.GetProperty("key").GetString()!, e => e.GetProperty(member).GetString()!);
        return new Catalogue(appLanguage, values);
    }

    public string this[string key] => _values.TryGetValue(key, out var value) ? value : throw new KeyNotFoundException(key);

    public string Format(string key, IReadOnlyList<string> args)
    {
        var next = 0;
        return Placeholder().Replace(this[key], m =>
        {
            var index = m.Groups[1].Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) - 1 : next++;
            return args[index];
        });
    }

    [GeneratedRegex(@"%(?:(\d+)\$)?(?:@|lld|ld|d)")]
    private static partial Regex Placeholder();
}

internal sealed record ExpectedElement(string AutomationId, string Origin, string Role, string Name, bool Prefix, string? Live);

internal sealed record Snapshot(string Id, string Scenario, string Page, IReadOnlyList<ExpectedElement> Elements);

/// <summary>spec/ui-semantics/surfaces.json, with names resolved in one language.</summary>
internal static class SurfaceSpec
{
    public static IReadOnlyDictionary<string, string> Roles { get; } = LoadRoles();

    public static IReadOnlyList<Snapshot> Load(Catalogue strings)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "ui-semantics", "surfaces.json")));
        return doc.RootElement.GetProperty("snapshots").EnumerateArray().Select(s => new Snapshot(
            s.GetProperty("id").GetString()!,
            s.GetProperty("scenario").GetString()!,
            s.GetProperty("page").GetString()!,
            s.GetProperty("elements").EnumerateArray().Select(e => new ExpectedElement(
                e.GetProperty("automationId").GetString()!,
                e.GetProperty("origin").GetString()!,
                e.GetProperty("role").GetString()!,
                string.Concat(e.GetProperty("name").EnumerateArray().Select(p => Part(p, strings))),
                e.TryGetProperty("match", out var m) && m.GetString() == "prefix",
                e.TryGetProperty("live", out var l) ? l.GetString() : null)).ToArray())).ToArray();
    }

    private static string Part(JsonElement part, Catalogue strings)
    {
        if (part.ValueKind == JsonValueKind.String) return Resolve(part.GetString()!, strings);
        var args = part.GetProperty("args").EnumerateArray().Select(a => Resolve(a.GetString()!, strings)).ToArray();
        return strings.Format(part.GetProperty("format").GetString()!, args);
    }

    private static string Resolve(string value, Catalogue strings) => value.StartsWith('@') ? strings[value[1..]] : value;

    private static Dictionary<string, string> LoadRoles()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.At("spec", "ui-semantics", "surfaces.json")));
        return doc.RootElement.GetProperty("roles").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!);
    }
}
