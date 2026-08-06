// The daemon's second transport: a launchd-vended Mach service.
//
// The Unix socket stays exactly as it is and remains the only transport for
// the CLI, CI and host agents. This adds a strictly narrower door for App
// Sandbox clients, which cannot reach an AF_UNIX path at all.
//
// Narrower in one specific way: every frame is checked against the read-only
// allowlist before it reaches `RuntimeControlPlaneHandler`. A refused frame
// is never handled, so it cannot admit, queue, journal or dispatch anything.

import ArkDeckCore
import Foundation

public final class AgentXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  /// Re-exported so the daemon executable can report the vended name without
  /// taking a second import for one string.
  public static var machServiceName: String { ArkDeckAgentXPC.machServiceName }

  private let handler: RuntimeControlPlaneHandler
  private let listener: NSXPCListener

  public init(handler: RuntimeControlPlaneHandler) {
    self.handler = handler
    listener = NSXPCListener(machServiceName: ArkDeckAgentXPC.machServiceName)
    super.init()
    listener.delegate = self
  }

  /// Best effort by design. A daemon started directly from a shell is not a
  /// launchd job and has no Mach service to check in to; that is a normal
  /// configuration for CLI and CI use and must not stop the Unix socket from
  /// serving. Callers get the outcome so it can be reported, not so it can
  /// be treated as fatal.
  public func activate() {
    listener.resume()
  }

  public func invalidate() {
    listener.invalidate()
  }

  public func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
    connection.exportedObject = AgentXPCEndpoint(handler: handler)
    connection.resume()
    return true
  }
}

/// The exported object. It owns exactly one decision — forward or refuse —
/// and holds no state between frames.
final class AgentXPCEndpoint: NSObject, ArkDeckAgentXPCProtocol, @unchecked Sendable {
  private let handler: RuntimeControlPlaneHandler

  init(handler: RuntimeControlPlaneHandler) {
    self.handler = handler
  }

  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void
  ) {
    guard let method = Self.readOnlyMethod(of: frame) else {
      reply(nil, Self.refusal(for: frame).rawValue)
      return
    }
    // The method is on the allowlist, so this is the same request path the
    // Unix socket uses: same decode, same admission, same audit record.
    _ = method
    let handler = self.handler
    Task {
      let response = await handler.handleLine(frame)
      reply(response, nil)
    }
  }

  /// Returns the method only when the frame parses *and* names an allowlisted
  /// read-only method. Anything else fails closed.
  static func readOnlyMethod(of frame: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
      let method = object["method"] as? String,
      ArkDeckAgentXPC.forwardableReadOnlyMethods.contains(method)
    else { return nil }
    return method
  }

  static func refusal(for frame: Data) -> ArkDeckAgentXPC.RefusalReason {
    guard
      let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
      object["method"] is String
    else { return .malformedRequestFrame }
    return .methodNotReadOnly
  }
}
