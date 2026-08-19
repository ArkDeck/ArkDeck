// The daemon's second transport: a launchd-vended Mach service.
//
// The Unix socket stays exactly as it is and remains the only transport for
// the CLI, CI and host agents. This adds a strictly narrower door for App
// Sandbox clients, which cannot reach an AF_UNIX path at all.
//
// Narrower in one specific way: every frame is checked against an exact App
// allowlist before it reaches `RuntimeControlPlaneHandler`. Besides reads,
// effectful entries are limited to closed App-owned Artifact uploads and
// typed Job requests. A refused frame is never handled.

import ArkDeckCore
import Foundation

package final class AgentXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  /// Re-exported so the daemon executable can report the vended name without
  /// taking a second import for one string.
  public static var machServiceName: String { ArkDeckAgentXPC.machServiceName }

  private let handler: RuntimeControlPlaneHandler
  private let listener: NSXPCListener
  private let appJobs = AgentXPCAppJobGate()

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

  package func invalidate() {
    listener.invalidate()
  }

  package func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
    connection.exportedObject = AgentXPCEndpoint(handler: handler, appJobs: appJobs)
    connection.resume()
    return true
  }
}

/// Jobs are the one place where a method-name allowlist is not narrow enough:
/// `job.submit` can name any Catalog operation and `job.run` can name any
/// queued Job. The listener therefore shares the identifiers returned by
/// successful, typed App submissions across the App's short-lived XPC
/// connections. Only those identifiers may cross the run boundary, once.
enum AgentXPCAppJobKind: String, Sendable, Equatable {
  case flash
  case trace
  case debugLogs
  case debugHAP
  case debugPorts
}

actor AgentXPCAppJobGate {
  private var runnableJobs: [String: AgentXPCAppJobKind] = [:]
  private var runningJobs: [String: AgentXPCAppJobKind] = [:]

  func record(_ jobID: String, kind: AgentXPCAppJobKind) {
    guard !jobID.isEmpty, jobID.count <= 128 else { return }
    runnableJobs[jobID] = kind
  }

  func beginRun(_ jobID: String) -> Bool {
    guard let kind = runnableJobs.removeValue(forKey: jobID) else { return false }
    runningJobs[jobID] = kind
    return true
  }

  func owns(_ jobID: String) -> Bool {
    runnableJobs[jobID] != nil || runningJobs[jobID] != nil
  }

  func finish(_ jobID: String) {
    runningJobs.removeValue(forKey: jobID)
    runnableJobs.removeValue(forKey: jobID)
  }
}

/// The exported object. It owns exactly one decision — forward or refuse.
/// The only shared state is the fail-closed typed App Job gate above.
final class AgentXPCEndpoint: NSObject, ArkDeckAgentXPCProtocol, @unchecked Sendable {
  enum Admission: Equatable {
    case direct(method: String)
    case appSubmit(requestID: String, kind: AgentXPCAppJobKind)
    case appRun(jobID: String)
    case appCancel(jobID: String)
  }

  private let handler: RuntimeControlPlaneHandler
  private let appJobs: AgentXPCAppJobGate

  init(handler: RuntimeControlPlaneHandler, appJobs: AgentXPCAppJobGate) {
    self.handler = handler
    self.appJobs = appJobs
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
    let appJobs = self.appJobs
    Task {
      switch admission {
      case .appRun(let jobID):
        guard await appJobs.beginRun(jobID) else {
          reply(nil, ArkDeckAgentXPC.RefusalReason.methodNotAllowlisted.rawValue)
          return
        }
      case .appCancel(let jobID):
        guard await appJobs.owns(jobID) else {
          reply(nil, ArkDeckAgentXPC.RefusalReason.methodNotAllowlisted.rawValue)
          return
        }
      case .direct, .appSubmit:
        break
      }
      // This is the same request path the Unix socket uses: same decode, same
      // Runtime admission and same audit record. The XPC boundary adds only a
      // narrower operation/job ownership check.
      let response = await handler.handleLine(frame)
      if case .appSubmit(let requestID, let kind) = admission,
        let jobID = Self.successfulSubmittedJobID(in: response, requestID: requestID)
      {
        await appJobs.record(jobID, kind: kind)
      }
      if case .appRun(let jobID) = admission {
        await appJobs.finish(jobID)
      }
      reply(response, nil)
    }
  }

  /// Parses the exact wire envelope and classifies the request before the
  /// daemon handler sees it. `job.submit` is admitted only for the typed UI
  /// request families; `job.run` still requires the shared one-shot Job gate.
  static func admission(of frame: Data) -> Admission? {
    guard
      let request = try? JSONDecoder().decode(AgentWireProtocol.Request.self, from: frame),
      request.protocolVersion == AgentWireProtocol.version
    else { return nil }

    if ArkDeckAgentXPC.forwardableReadOnlyMethods.contains(request.method)
      || ArkDeckAgentXPC.forwardableFlashBundleMethods.contains(request.method)
      || ArkDeckAgentXPC.forwardableHAPImportMethods.contains(request.method)
      || ArkDeckAgentXPC.forwardableRockchipBindingMethods.contains(request.method)
    {
      return .direct(method: request.method)
    }
    switch request.method {
    case "job.submit":
      guard
        request.params?.count == 1,
        case .string(let requestJSON)? = request.params?["requestJson"],
        let kind = typedAppJobKind(requestJSON)
      else { return nil }
      return .appSubmit(requestID: request.id, kind: kind)
    case "job.run":
      guard
        request.params?.count == 1,
        case .string(let jobID)? = request.params?["jobId"],
        !jobID.isEmpty, jobID.count <= 128
      else { return nil }
      return .appRun(jobID: jobID)
    case "job.cancel":
      guard
        request.params?.count == 1,
        case .string(let jobID)? = request.params?["jobId"],
        !jobID.isEmpty, jobID.count <= 128
      else { return nil }
      return .appCancel(jobID: jobID)
    default:
      return nil
    }
  }

  private static func typedAppJobKind(_ requestJSON: String) -> AgentXPCAppJobKind? {
    guard
      let data = requestJSON.data(using: .utf8),
      case .object(let request)? = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .string("runtime-operation-request")? = request["documentType"],
      case .string("2.0.0")? = request["schemaVersion"],
      case .object(let operation)? = request["operation"],
      case .string(let operationID)? = operation["id"],
      request["authorization"] == nil,
      request["campaignReservation"] == nil,
      case .object(let context)? = request["clientContext"],
      case .string(let clientName)? = context["clientName"]
    else { return nil }
    switch (clientName, operationID) {
    case (ArkDeckAgentClientName.flashWorkspace, "flash.dayu200"):
      guard operation["version"] == nil else { return nil }
      return .flash
    case (ArkDeckAgentClientName.traceWorkspace, "capture.diagnostics"):
      guard case .integer(1)? = operation["version"] else { return nil }
      return .trace
    case (ArkDeckAgentClientName.debugLogsWorkspace, "capture.diagnostics"):
      guard case .integer(1)? = operation["version"] else { return nil }
      return .debugLogs
    case (ArkDeckAgentClientName.debugAppsWorkspace, "debug.hap"):
      guard case .integer(1)? = operation["version"] else { return nil }
      return .debugHAP
    case (ArkDeckAgentClientName.debugNetworkWorkspace, "port-forward.create"),
      (ArkDeckAgentClientName.debugNetworkWorkspace, "port-forward.remove"):
      guard case .integer(1)? = operation["version"] else { return nil }
      return .debugPorts
    default:
      return nil
    }
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
