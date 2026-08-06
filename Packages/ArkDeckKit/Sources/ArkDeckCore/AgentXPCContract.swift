// App <-> daemon XPC contract.
//
// The daemon's Unix socket is unreachable from an App Sandbox container: the
// sandbox classifies AF_UNIX `connect()` as its own operation, so no file
// entitlement can reach it (measured, not assumed). A launchd-vended Mach
// service is the only transport a sandboxed client can reach, and only with
// an explicit `mach-lookup` exception naming this service.
//
// This is a transport contract and nothing else. It carries one opaque
// request frame in the daemon's existing versioned JSON line protocol, so
// adding it changes no request shape, no admission rule and no audit record.
// It deliberately has nowhere to put an executable, argv, or authority.

import Foundation

/// The global Mach service name the daemon vends and the App looks up. It is
/// duplicated in the App's `mach-lookup` exception and in the LaunchAgent
/// `MachServices` key; all three must agree or the lookup fails closed.
public enum ArkDeckAgentXPC {
  public static let machServiceName = "com.arkdeck.agentd"

  /// The exact set of control-plane methods this transport will forward.
  ///
  /// This is an allowlist, not a denylist: a method that is absent — whether
  /// it is a mutation, a typo, or a method added to the daemon after this
  /// build — is refused before it reaches the handler. Every entry reads
  /// Runtime state and none of them can queue, execute, cancel, adopt or
  /// import anything, so a sandboxed client of this transport cannot produce
  /// a device effect at any level.
  public static let forwardableReadOnlyMethods: Set<String> = [
    "artifact.inspect",
    "artifact.list",
    "job.evidence",
    "job.list",
    "job.list-page",
    "job.status",
    "target.list",
  ]

  /// Reason codes returned to the client instead of a forwarded response.
  /// They are stable strings so the App can present an accurate cause rather
  /// than a generic failure.
  public enum RefusalReason: String, Sendable {
    case malformedRequestFrame
    case methodNotReadOnly
  }
}

/// The vended interface. `Data` in, `Data` out: one request frame, one
/// response frame, both in the daemon's existing wire protocol.
@objc public protocol ArkDeckAgentXPCProtocol {
  /// - Parameter reply: `(response, refusalReason)`. Exactly one is non-nil.
  ///   A refusal never reaches the daemon's request handler.
  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void)
}
