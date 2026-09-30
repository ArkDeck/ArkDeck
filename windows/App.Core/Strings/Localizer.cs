using System.Globalization;
using System.Text.RegularExpressions;

namespace ArkDeck.App.Core.Strings;

/// <summary>
/// Looks strings up in the shared bilingual catalogue (spec/ui-semantics/strings.json, as
/// generated into the App's <c>.resw</c>) and formats the macOS printf placeholders it keeps
/// (<c>%@</c>, <c>%d</c>, <c>%lld</c>, positional <c>%1$@</c>). A key the catalogue lacks is
/// shown as the key itself, as the macOS String Catalog does, and recorded in
/// <see cref="Missing"/> (AC-I18N-001: a missing key is visible, never blank).
/// </summary>
public sealed partial class Localizer(Func<string, string?> lookup, string language)
{
    private readonly HashSet<string> _missing = [];

    /// <summary>The language this localizer resolves (<c>en-US</c> or <c>zh-Hans</c>).</summary>
    public string Language { get; } = language;

    public IReadOnlyCollection<string> Missing
    {
        get
        {
            lock (_missing) return _missing.ToArray();
        }
    }

    public string Text(string key)
    {
        var value = lookup(key);
        if (!string.IsNullOrEmpty(value)) return value;
        lock (_missing) _missing.Add(key);
        return key;
    }

    public string Format(string key, params object[] arguments) => Printf(Text(key), arguments);

    /// <summary>Formats a macOS-style format string with invariant number formatting.</summary>
    public static string Printf(string format, IReadOnlyList<object> arguments)
    {
        var next = 0;
        return Placeholder().Replace(format, match =>
        {
            if (match.Value == "%%") return "%";
            var index = match.Groups[1].Success ? int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) - 1 : next++;
            if (index < 0 || index >= arguments.Count) return match.Value;
            return Convert.ToString(arguments[index], CultureInfo.InvariantCulture) ?? string.Empty;
        });
    }

    [GeneratedRegex(@"%%|%(?:(\d+)\$)?(?:@|lld|ld|d)")]
    private static partial Regex Placeholder();
}

/// <summary>The App's language, set explicitly at start (SPK-4 finding 3: otherwise WinUI's
/// built-in strings follow the OS language while the App's follow the resources).</summary>
public static class AppLanguage
{
    public const string English = "en-US";
    public const string SimplifiedChinese = "zh-Hans";

    /// <summary>The explicit choice if it names a supported language, else the first of the
    /// user's preferred languages the catalogue has, else English.</summary>
    public static string Resolve(string? requested, IEnumerable<string> preferred)
    {
        if (Match(requested) is { } explicitLanguage) return explicitLanguage;
        foreach (var tag in preferred)
        {
            if (Match(tag) is { } language) return language;
        }
        return English;
    }

    private static string? Match(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        var t = tag.Trim().ToLowerInvariant();
        if (t == "zh-hans" || t.StartsWith("zh-hans-", StringComparison.Ordinal) || t is "zh-cn" or "zh-sg" or "zh") return SimplifiedChinese;
        if (t == "en" || t.StartsWith("en-", StringComparison.Ordinal)) return English;
        return null;
    }
}
