using ArkDeck.App.Core.Daemon;
using ArkDeck.App.Core.Strings;
using ArkDeck.ClientKit;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.App.Core.Presentation;

/// <summary>
/// Why a surface shows no data: <c>unavailable(reasonCode)</c>, the detail the daemon or
/// ClientKit gave, and the CLI command that reads the same thing (XPA-AC-8). The reason code
/// is taken as it came: the daemon's wire error code (e.g. <c>rejected</c>), or ClientKit's
/// failure kind when nothing answered (<c>daemonUnavailable</c>, <c>outcomeUnknown</c>, …).
/// </summary>
public sealed record Unavailable(string ReasonCode, string Detail, string CliCommand, ControlFailure? Failure)
{
    public const string DaemonUnavailableCode = "daemonUnavailable";
    public const string ResultUnreadableCode = "resultUnreadable";

    /// <summary>The daemon was not reached, so the shell shows the recovery banner.</summary>
    public bool IsDaemonUnavailable => Failure?.Kind == ControlFailureKind.DaemonUnavailable;

    public static Unavailable From(ControlFailure failure, string cliCommand) => failure.Kind switch
    {
        ControlFailureKind.DaemonUnavailable => new(DaemonUnavailableCode, failure.Message, cliCommand, failure),
        ControlFailureKind.Remote => new(failure.Remote!.Code, failure.Remote.Message, cliCommand, failure),
        ControlFailureKind.OutcomeUnknown => new("outcomeUnknown", failure.Message, cliCommand, failure),
        ControlFailureKind.InvalidRequest => new("invalidRequest", failure.Message, cliCommand, failure),
        _ => new("connectionUnusable", failure.Message, cliCommand, failure),
    };

    public static Unavailable Unreadable(Exception error, string cliCommand) =>
        new(ResultUnreadableCode, error.Message, cliCommand, null);

    /// <summary>"unavailable(rejected): hdc.notConfigured".</summary>
    public string ReasonText(Localizer strings) => strings.Format(UiStrings.WindowsUnavailableReason, ReasonCode, Detail);

    public string CliText(Localizer strings) => strings.Format(UiStrings.WindowsCliEquivalent, CliCommand);
}

/// <summary>A surface's data, or why it has none.</summary>
public sealed record Loaded<T>(T? Value, Unavailable? Unavailable) where T : class
{
    public bool IsAvailable => Unavailable is null;

    public static Loaded<T> Of(T value) => new(value, null);

    public static Loaded<T> Not(Unavailable why) => new(null, why);

    /// <summary>Runs one ClientKit call and parses its result; any failure becomes
    /// <see cref="Unavailable"/> with <paramref name="cliCommand"/>.</summary>
    public static async Task<Loaded<T>> From(Task<ControlResult> call, Func<ClientKit.Json.JsonValue, T> parse, string cliCommand)
    {
        var result = await call.ConfigureAwait(false);
        if (result.Failure is { } failure) return Not(Unavailable.From(failure, cliCommand));
        try
        {
            return Of(parse(result.Value!));
        }
        catch (Exception error) when (error is InvalidCastException or KeyNotFoundException or FormatException
                                          or ClientKit.Contract.ContractException or InvalidOperationException)
        {
            return Not(Unavailable.Unreadable(error, cliCommand));
        }
    }
}

/// <summary>Which recovery banner a daemon-unavailable failure shows (the reason ClientKit
/// gives; the strings are the shared catalogue's <c>windows.recovery.*</c>).</summary>
public enum RecoveryKind
{
    NotRunning,
    Impostor,
    Contract,
    NotConfigured,
}

/// <summary>The daemon-unavailable recovery banner (InfoBar): what happened, what to do,
/// the CLI command, and ClientKit's own reason. Shown instead of any data.</summary>
public sealed record RecoveryBannerState(RecoveryKind Kind, string Title, string Message, string Remedy, string Reason, string CliCommand, string CliText)
{
    /// <summary>The command that starts the Runtime when it is not running (any CLI command
    /// that needs it starts it, decision 11) and reports what is wrong.</summary>
    public const string DoctorCommand = "arkdeck doctor";

    public static RecoveryBannerState For(ControlFailure failure, Localizer strings)
    {
        var kind = failure.Message.StartsWith(UnconfiguredChannel.Marker, StringComparison.Ordinal)
            ? RecoveryKind.NotConfigured
            : failure.Reason switch
            {
                DaemonUnavailableReason.OwnerMismatch or DaemonUnavailableReason.InstanceMismatch => RecoveryKind.Impostor,
                DaemonUnavailableReason.ContractMismatch => RecoveryKind.Contract,
                _ => RecoveryKind.NotRunning,
            };
        var (message, remedy) = kind switch
        {
            RecoveryKind.Impostor => (UiStrings.WindowsRecoveryMessageImpostor, UiStrings.WindowsRecoveryRemedyImpostor),
            RecoveryKind.Contract => (UiStrings.WindowsRecoveryMessageContract, UiStrings.WindowsRecoveryRemedyContract),
            RecoveryKind.NotConfigured => (UiStrings.WindowsRecoveryMessageNotConfigured, UiStrings.WindowsRecoveryRemedyNotConfigured),
            _ => (UiStrings.WindowsRecoveryMessageNotRunning, UiStrings.WindowsRecoveryRemedyNotRunning),
        };
        var reason = $"{failure.Reason ?? DaemonUnavailableReason.EndpointUnavailable}: {failure.Message}";
        return new(kind, strings.Text(UiStrings.WindowsRecoveryTitle), strings.Text(message), strings.Text(remedy),
            strings.Format(UiStrings.WindowsRecoveryReason, reason), DoctorCommand, strings.Format(UiStrings.WindowsCliEquivalent, DoctorCommand));
    }
}
