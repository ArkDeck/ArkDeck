// The daemon's second transport: a launchd-vended Mach service.
//
// The Unix socket stays exactly as it is and remains the only transport for
// the CLI, CI and host agents. This adds a strictly narrower door for App
// Sandbox clients, which cannot reach an AF_UNIX path at all.
//
// Narrower in one specific way: every frame is checked against an exact App
// allowlist before it reaches `RuntimeControlPlaneHandler`. Besides reads,
// the only effectful entries form the closed typed Flash path. A refused frame
// is never handled.

import ArkDeckCore
import Foundation

public final class AgentXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  /// Re-exported so the daemon executable can report the vended name without
  /// taking a second import for one string.
  public static var machServiceName: String { ArkDeckAgentXPC.machServiceName }

  private let handler: RuntimeControlPlaneHandler
  private let listener: NSXPCListener
  private let flashJobs = AgentXPCFlashJobGate()

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
    connection.exportedObject = AgentXPCEndpoint(handler: handler, flashJobs: flashJobs)
    connection.resume()
    return true
  }
}

/// Jobs are the one place where a method-name allowlist is not narrow enough:
/// `job.submit` can name any Catalog operation and `job.run` can name any
/// queued Job. The listener therefore shares the identifiers returned by
/// successful, typed Flash submissions across the App's short-lived XPC
/// connections. Only those identifiers may cross the run boundary, once.
actor AgentXPCFlashJobGate {
  private var runnableJobIDs: Set<String> = []

  func record(_ jobID: String) {
    guard !jobID.isEmpty, jobID.count <= 128 else { return }
    runnableJobIDs.insert(jobID)
  }

  func consume(_ jobID: String) -> Bool {
    runnableJobIDs.remove(jobID) != nil
  }
}

/// The exported object. It owns exactly one decision — forward or refuse.
/// The only shared state is the fail-closed Flash Job gate above.
final class AgentXPCEndpoint: NSObject, ArkDeckAgentXPCProtocol, @unchecked Sendable {
  enum Admission: Equatable {
    case direct(method: String)
    case flashSubmit(requestID: String)
    case flashRun(jobID: String)
  }

  private let handler: RuntimeControlPlaneHandler
  private let flashJobs: AgentXPCFlashJobGate

  init(handler: RuntimeControlPlaneHandler, flashJobs: AgentXPCFlashJobGate) {
    self.handler = handler
    self.flashJobs = flashJobs
  }

  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void
  ) {
    guard let admission = Self.admission(of: frame) else {
      reply(nil, Self.refusal(for: frame).rawValue)
      return
    }
    let handler = self.handler
    let flashJobs = self.flashJobs
    Task {
      if case .flashRun(let jobID) = admission,
        !(await flashJobs.consume(jobID))
      {
        reply(nil, ArkDeckAgentXPC.RefusalReason.methodNotAllowlisted.rawValue)
        return
      }
      // This is the same request path the Unix socket uses: same decode, same
      // Runtime admission and same audit record. The XPC boundary adds only a
      // narrower operation/job ownership check.
      let response = await handler.handleLine(frame)
      if case .flashSubmit(let requestID) = admission,
        let jobID = Self.successfulSubmittedJobID(in: response, requestID: requestID)
      {
        await flashJobs.record(jobID)
      }
      reply(response, nil)
    }
  }

  /// Parses the exact wire envelope and classifies the request before the
  /// daemon handler sees it. `job.submit` is admitted only for the typed UI
  /// Flash request; `job.run` still requires the shared one-shot Job gate.
  static func admission(of frame: Data) -> Admission? {
    guard
      let request = try? JSONDecoder().decode(AgentWireProtocol.Request.self, from: frame),
      request.protocolVersion == AgentWireProtocol.version
    else { return nil }

    if ArkDeckAgentXPC.forwardableReadOnlyMethods.contains(request.method)
      || ArkDeckAgentXPC.forwardableFlashBundleMethods.contains(request.method)
    {
      return .direct(method: request.method)
    }
    switch request.method {
    case "job.submit":
      guard
        request.params?.count == 1,
        case .string(let requestJSON)? = request.params?["requestJson"],
        isTypedFlashUIRequest(requestJSON)
      else { return nil }
      return .flashSubmit(requestID: request.id)
    case "job.run":
      guard
        request.params?.count == 1,
        case .string(let jobID)? = request.params?["jobId"],
        !jobID.isEmpty, jobID.count <= 128
      else { return nil }
      return .flashRun(jobID: jobID)
    default:
      return nil
    }
  }

  private static func isTypedFlashUIRequest(_ requestJSON: String) -> Bool {
    guard
      let data = requestJSON.data(using: .utf8),
      case .object(let request)? = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .string("runtime-operation-request")? = request["documentType"],
      case .string("2.0.0")? = request["schemaVersion"],
      case .object(let operation)? = request["operation"],
      case .string("flash.dayu200")? = operation["id"],
      case .integer(1)? = operation["version"],
      request["authorization"] == nil,
      request["campaignReservation"] == nil,
      case .object(let context)? = request["clientContext"],
      case .string("ArkDeckApp.FlashWorkspace")? = context["clientName"]
    else { return false }
    return true
  }

  static func successfulSubmittedJobID(in response: Data, requestID: String) -> String? {
    guard
      let wire = try? JSONDecoder().decode(AgentWireProtocol.Response.self, from: response),
      wire.id == requestID, wire.ok,
      case .object(let result)? = wire.result,
      case .string(let jobID)? = result["jobId"],
      !jobID.isEmpty, jobID.count <= 128
    else { return nil }
    return jobID
  }

  static func refusal(for frame: Data) -> ArkDeckAgentXPC.RefusalReason {
    guard
      let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
      object["method"] is String
    else { return .malformedRequestFrame }
    return .methodNotAllowlisted
  }
}
