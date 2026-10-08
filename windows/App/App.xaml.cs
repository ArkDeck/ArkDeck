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

    /// <summary>The App's remote build sources (App-side SSH, no Runtime call); this executable
    /// answers the SSH client's prompts in its askpass mode (Program).</summary>
    public static ArkDeck.App.Core.RemoteSources.RemoteBuildSourceProvider RemoteSources { get; private set; } = null!;

    /// <summary>The App's own preferences (the window icon).</summary>
    public static AppPreferences Preferences { get; private set; } = null!;

    private Window? _window;

    /// <summary>A Trace file to open at launch: the packaged App's file activation, else the
    /// command line's (an unpackaged "Open with").</summary>
    public static string? TraceFile { get; private set; }

    public App()
    {
        Options = LaunchOptions.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray());
        if (Options.TestTheme is { } theme) RequestedTheme = theme == "dark" ? ApplicationTheme.Dark : ApplicationTheme.Light;

        // AC-I18N-001: the App's language is set explicitly before any UI exists, so WinUI's
        // own strings (NavigationView, TitleBar) and the catalogue agree (SPK-4 finding 3).
        var language = AppLanguage.Resolve(Options.Language, Windows.System.UserProfile.GlobalizationPreferences.Languages);
        Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = language;
        Strings = new Localizer(ResourceLookup(language), language);

        Loader = new SurfaceLoader(DaemonConfiguration.Create(Options, Environment.GetEnvironmentVariable, AppContext.BaseDirectory));
        RemoteSources = ArkDeck.App.Core.RemoteSources.RemoteBuildSourceProvider.Create(Environment.ProcessPath!, Options.RemoteSourcesRoot);
        Preferences = new AppPreferences(Options.PreferencesRoot ?? AppPreferences.DefaultDirectory);
        InitializeComponent();

    }

    private static string? ActivatedTraceFile()
    {
        try
        {
            var activated = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs();
            if (activated.Kind == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.File
                && activated.Data is Windows.ApplicationModel.Activation.IFileActivatedEventArgs files
                && files.Files.Count > 0 && files.Files[0] is Windows.Storage.IStorageItem item
                && LaunchOptions.TraceExtensions.Contains(Path.GetExtension(item.Path).ToLowerInvariant()))
            {
                return item.Path;
            }
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
        }
        return null;
    }

    /// <summary>Test runs only (<c>--high-contrast-tokens</c>): every ArkDeck token takes its
    /// high-contrast value in the light and dark themes as well, which is what the system's
    /// high-contrast themes select. WinUI's own resources are unchanged.</summary>
    private void UseHighContrastTokens()
    {
        var tokens = Resources.MergedDictionaries.First(d => d.Source?.OriginalString.EndsWith("ArkDeckTokens.xaml", StringComparison.Ordinal) == true);
        var contrast = (ResourceDictionary)tokens.ThemeDictionaries["HighContrast"];
        foreach (var theme in new[] { "Light", "Dark" })
        {
            var dictionary = (ResourceDictionary)tokens.ThemeDictionaries[theme];
            // A brush belongs to one dictionary: each theme gets its own, of the same system colour.
            foreach (var key in contrast.Keys.ToArray())
            {
                dictionary[key] = contrast[key] is Microsoft.UI.Xaml.Media.SolidColorBrush brush ? new Microsoft.UI.Xaml.Media.SolidColorBrush(brush.Color) : contrast[key];
            }
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (Options.HighContrastTokens) UseHighContrastTokens();
        TraceFile = ActivatedTraceFile() ?? Options.TraceFile;
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
