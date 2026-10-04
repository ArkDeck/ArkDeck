using ArkDeck.App.Core.RemoteSources;

namespace ArkDeck.App;

/// <summary>
/// The App's entry point. Run by Windows' OpenSSH client as <c>SSH_ASKPASS</c> for a remote build
/// source (the prompt as its one argument and the App's askpass pipe named in its environment), the
/// executable answers the prompt from the App that started the connection and exits without any UI;
/// otherwise it starts the WinUI App as the XAML compiler's generated entry point does.
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (AskPassClient.IsRequested(args)) return AskPassClient.Run(args[0]);
        XamlGeneratedProgram.XamlGeneratedMain();
        return 0;
    }
}
