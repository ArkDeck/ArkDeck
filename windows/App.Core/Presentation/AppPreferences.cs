using System.Text;
using ArkDeck.ClientKit.Json;

namespace ArkDeck.App.Core.Presentation;

/// <summary>The window icon Settings › General offers (macOS <c>ApplicationIconChoice</c>).</summary>
public enum AppIconChoice
{
    Keycap,
    Waveform,
}

/// <summary>
/// The App's own per-user preferences (macOS <c>UserDefaults</c>): today only the window icon.
/// A JSON file written whole through a staging file; an unreadable or unknown value reads as the
/// default, never as an error. Nothing here reaches the Runtime.
/// </summary>
public sealed class AppPreferences(string directory)
{
    /// <summary>macOS <c>ApplicationIconChoice.defaultChoice</c>.</summary>
    public const AppIconChoice DefaultIcon = AppIconChoice.Waveform;

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ArkDeck", "App");

    private string FilePath => Path.Combine(directory, "preferences-v1.json");

    public AppIconChoice Icon
    {
        get => Text("appIcon") is { } name ? Parse(name) ?? DefaultIcon : DefaultIcon;
        set => Write("appIcon", Name(value));
    }

    /// <summary>The navigation item shown last (macOS <c>storedSelection</c>), restored at launch.</summary>
    public string? LastPage
    {
        get => Text("lastPage");
        set
        {
            if (value is not null && value != LastPage) Write("lastPage", value);
        }
    }

    private JsonObject Read()
    {
        try
        {
            return StrictJson.Parse(File.ReadAllBytes(FilePath)) as JsonObject ?? new JsonObject();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or MalformedJsonException or FormatException)
        {
            return new JsonObject();
        }
    }

    private string? Text(string key) => Read().TryGetValue(key, out var v) && v is JsonString s ? s.Value : null;

    /// <summary>One value written, the others kept, the file replaced whole.</summary>
    private void Write(string key, string value)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var members = Read().Members.Where(m => m.Key != key).Append(new(key, new JsonString(value)));
            var staging = FilePath + ".staging";
            File.WriteAllBytes(staging, Encoding.UTF8.GetBytes(new JsonObject(members).ToString() + "\n"));
            File.Move(staging, FilePath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A preference that cannot be kept is not an error the person can act on.
        }
    }

    public static string Name(AppIconChoice choice) => choice == AppIconChoice.Keycap ? "keycap" : "waveform";

    public static AppIconChoice? Parse(string name) => name switch
    {
        "keycap" => AppIconChoice.Keycap,
        "waveform" => AppIconChoice.Waveform,
        _ => null,
    };

    /// <summary>The generated icon file of a choice (generate-app-icons.py).</summary>
    public static string IconAsset(AppIconChoice choice) => choice == AppIconChoice.Keycap ? "Assets/AppIcon.Keycap.ico" : "Assets/AppIcon.Waveform.ico";
}
