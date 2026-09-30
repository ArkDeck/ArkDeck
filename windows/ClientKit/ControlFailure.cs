using ArkDeck.ClientKit.Contract;
using ArkDeck.ClientKit.Transport;

namespace ArkDeck.ClientKit;

/// <summary>What went wrong with a control call, from the point of view of what the daemon
/// may have done.</summary>
public enum ControlFailureKind
{
    /// <summary>The daemon could not be reached, was not authenticated, or failed the
    /// same-connection <c>health</c> preflight. No business frame was sent, so nothing ran.
    /// The UI shows the recovery banner.</summary>
    DaemonUnavailable,

    /// <summary>This client refused the request itself before writing any byte.</summary>
    InvalidRequest,

    /// <summary>The business frame was (or may have been) sent and no valid reply arrived:
    /// lost, malformed or late. It is never replayed; read the state back instead
    /// (<c>job.status</c>/<c>job.list</c>).</summary>
    OutcomeUnknown,

    /// <summary>The daemon answered with a wire error.</summary>
    Remote,

    /// <summary>An earlier exchange on this connection failed; open a new connection (which
    /// re-verifies <c>health</c>).</summary>
    ConnectionUnusable,
}

/// <summary>A typed control failure. <see cref="ControlFailureKind.DaemonUnavailable"/> carries the reason;
/// <see cref="ControlFailureKind.Remote"/> the daemon's wire error.</summary>
public sealed record ControlFailure(
    ControlFailureKind Kind,
    string Message,
    DaemonUnavailableReason? Reason = null,
    WireError? Remote = null)
{
    /// <summary>Whether the UI shows the daemon-unavailable recovery banner instead of data.</summary>
    public bool ShowsRecoveryBanner => Kind == ControlFailureKind.DaemonUnavailable;

    /// <summary>The recovery banner for a daemon-unavailable failure, otherwise null.</summary>
    public RecoveryBanner? Banner => ShowsRecoveryBanner ? RecoveryBanner.For(Reason ?? DaemonUnavailableReason.EndpointUnavailable, Message) : null;

    internal static ControlFailure Unavailable(DaemonUnavailableReason reason, string message) =>
        new(ControlFailureKind.DaemonUnavailable, message, reason);
}

public sealed class ControlClientException(ControlFailure failure, Exception? inner = null)
    : Exception(failure.Message, inner)
{
    public ControlFailure Failure { get; } = failure;
}

/// <summary>
/// The daemon-unavailable recovery banner (XPA-AC-6, TASK-XPA-007): shown instead of any
/// data, so an impostor server's bytes can never be displayed. The strings are the English
/// source; the bilingual catalogue (one source → <c>.resw</c> + <c>.xcstrings</c>) is a
/// later TASK-XPA-007 slice.
/// </summary>
public sealed record RecoveryBanner(string Code, DaemonUnavailableReason Reason, string Title, string Message, string Remedy, string Detail)
{
    public const string BannerCode = "daemonUnavailable";

    public static RecoveryBanner For(DaemonUnavailableReason reason, string detail) => reason switch
    {
        DaemonUnavailableReason.OwnerMismatch or DaemonUnavailableReason.InstanceMismatch => new(BannerCode, reason,
            "ArkDeck Runtime unavailable",
            "The local endpoint is served by a process that is not the installed ArkDeck Runtime, so nothing was sent to it.",
            "Quit whatever holds the endpoint, then start ArkDeck again; `arkdeck doctor` reports the held name.",
            detail),
        DaemonUnavailableReason.ContractMismatch => new(BannerCode, reason,
            "ArkDeck Runtime unavailable",
            "The running ArkDeck Runtime speaks another control contract than this app.",
            "Install matching ArkDeck app and Runtime versions, then start ArkDeck again.",
            detail),
        _ => new(BannerCode, reason,
            "ArkDeck Runtime unavailable",
            "The local ArkDeck Runtime is not running or did not answer.",
            "Start the ArkDeck Runtime (arkdeck-agentd) and retry; `arkdeck doctor` shows what is wrong.",
            detail),
    };
}
