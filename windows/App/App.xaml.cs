using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI.Xaml;
using Microsoft.Windows.ApplicationModel.Resources;

namespace ArkDeck.App;

public partial class App : Application
{
    /// <summary>The shared bilingual catalogue in the App's language.</summary>
    public static Localizer Strings { get; private set; } = null!;

    /// <summary>The only way to the daemon (ClientKit).</summary>
    public static SurfaceLoader Loader { get; private set; } = null!;

    public static LaunchOptions Options { get; private set; } = new(null, null, null);

    private Window? _window;

    public App()
    {
        Options = LaunchOptions.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());

        // AC-I18N-001: the App's language is set explicitly before any UI exists, so WinUI's
        // own strings (NavigationView, TitleBar) and the catalogue agree (SPK-4 finding 3).
        var language = AppLanguage.Resolve(Options.Language, Windows.System.UserProfile.GlobalizationPreferences.Languages);
        Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = language;
        Strings = new Localizer(ResourceLookup(language), language);

        Loader = new SurfaceLoader(DaemonConfiguration.Create(Options, Environment.GetEnvironmentVariable, AppContext.BaseDirectory));
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }

    /// <summary>MRT Core lookup of a catalogue key in <paramref name="language"/> (the .resw
    /// resource name is the key with "." replaced by "_", as the generator writes it).</summary>
    private static Func<string, string?> ResourceLookup(string language)
    {
        var manager = new ResourceManager();
        var context = manager.CreateResourceContext();
        context.QualifierValues["Language"] = language;
        var map = manager.MainResourceMap.GetSubtree("Resources");
        return key => map.TryGetValue(key.Replace('.', '_'), context)?.ValueAsString;
    }
}
