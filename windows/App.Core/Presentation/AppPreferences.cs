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
        get
        {
            try
            {
                var o = (JsonObject)StrictJson.Parse(File.ReadAllBytes(FilePath));
                return o.TryGetValue("appIcon", out var v) && v is JsonString s ? Parse(s.Value) ?? DefaultIcon : DefaultIcon;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or MalformedJsonException or InvalidCastException or FormatException)
            {
                return DefaultIcon;
            }
        }
        set
        {
            Directory.CreateDirectory(directory);
            var staging = FilePath + ".staging";
            File.WriteAllBytes(staging, Encoding.UTF8.GetBytes(new JsonObject([new("appIcon", new JsonString(Name(value)))]).ToString() + "\n"));
            File.Move(staging, FilePath, overwrite: true);
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
