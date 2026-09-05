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

/// Shared filesystem layout for the CLI and daemon composition roots.
package enum ArkDeckAgentFilesystemLayout {
  package static let applicationSupportRelativeStateDirectory = "ArkDeck/Agentd"
  package static let socketFilename = "agentd.sock"

  package static func defaultStateDirectory(
    fileManager: FileManager = .default
  ) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: applicationSupportRelativeStateDirectory, directoryHint: .isDirectory)
  }

  package static func defaultSocketURL(fileManager: FileManager = .default) -> URL {
    defaultStateDirectory(fileManager: fileManager)
      .appending(path: socketFilename)
  }
}

package enum ArkDeckEnvironmentKey {
  package static let hdcPath = "ARKDECK_HDC_PATH"
}

package enum ArkDeckAgentClientName {
  public static let flashWorkspace = "ArkDeckApp.FlashWorkspace"
  public static let traceWorkspace = "ArkDeckApp.TraceWorkspace"
  package static let debugLogsWorkspace = "ArkDeckApp.DebugWorkspace.Logs"
  package static let debugArtifactsWorkspace = "ArkDeckApp.DebugWorkspace.Artifacts"
  package static let debugAppsWorkspace = "ArkDeckApp.DebugWorkspace.Apps"
  package static let debugNetworkWorkspace = "ArkDeckApp.DebugWorkspace.Network"
  package static let debugCommandsWorkspace = "ArkDeckApp.DebugWorkspace.Commands"
  /// Device's device-control workspace. It is named apart from the Viewer's
  /// client even though both capture a screenshot, because the daemon decides
  /// what an App may submit from the pair of client name and operation: a
  /// client that may also inject a gesture must be a distinct subject.
  // This published client identity also keys durable workspace history. The
  // Device product rename must not change admission or split existing threads.
  package static let deviceControl = "ArkDeckApp.Toolkit.DeviceControl"
}

/// The global Mach service name the daemon vends and the App looks up. It is
/// duplicated in the App's `mach-lookup` exception and in the LaunchAgent
/// `MachServices` key; all three must agree or the lookup fails closed.
package enum ArkDeckAgentXPC {
  package static let machServiceName = "com.arkdeck.agentd"
  package static let wireProtocolVersion = ArkDeckControlProtocol.currentVersion

  /// Builds the single versioned request shape accepted by the daemon. Method
  /// admission remains in `AgentXPCEndpoint`; this only prevents App facades
  /// from drifting onto an obsolete or caller-shaped wire envelope.
  package static func requestFrame(
    method: String,
    params: [String: JSONValue]? = nil,
    requestID: String = UUID().uuidString,
    protocolVersion: String = wireProtocolVersion
  ) throws -> Data {
    guard protocolVersion == wireProtocolVersion else {
      throw RequestFrameFailure.unsupportedProtocolVersion
    }
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(
      RequestFrame(
        protocolVersion: protocolVersion,
        contractIdentity: ArkDeckControlProtocol.contractIdentity,
        id: requestID,
        method: method,
        params: params))
  }

  /// The exact read-only control-plane methods this transport will forward.
  ///
  /// This is an allowlist, not a denylist: a method that is absent — whether
  /// it is a mutation, a typo, or a method added to the daemon after this
  /// build — is refused before it reaches the handler. Every entry reads
  /// Runtime state and none of them can queue, execute, cancel, adopt or
  /// import anything, so a sandboxed client of this transport cannot produce
  /// a device effect at any level.
  ///
  /// `device.observations` is the discovery read behind the App's device list:
  /// it returns the daemon's timestamped HDC candidate observation with raw
  /// connection state and joins already-adopted targets by connect key. An
  /// explicit re-check may wait for a new observation, but both paths call
  /// bootstrap reads only — never `advance`, whose single-candidate path
  /// adopts — so listing candidates over this transport cannot create,
  /// select or change a binding. Adoption itself stays on `target.adopt`,
  /// which remains refused here.
  package static let forwardableReadOnlyMethods: Set<String> = [
    "artifact.inspect",
    "artifact.list",
    "artifact.quota",
    "artifact.read",
    "device.observations",
    "health",
    "debug.probe",
    "flash.bootloader-status",
    "flash.device-access",
    "flash.lanePlanPreview",
    "flash.prerequisites",
    "history.filter.list",
    "job.evidence",
    "job.list",
    "job.status",
    "job.show",
    "job.timeline",
    "operation.list",
    "runtime.hdc.status",
    "runtime.storage.status",
    "target.list",
    "trace.cache.status",
    "trace.probe",
  ]

  /// Generic import names remain constrained by typed kind and Runtime-owned
  /// upload identity in the endpoint and the shared Import gateway.
  package static let forwardableImportMethods: Set<String> = [
    "artifact.import.begin", "artifact.import.append", "artifact.import.commit", "artifact.import.abort",
  ]

  /// The App may ask Runtime to bind one freshly re-read Loader candidate to
  /// the explicitly selected adopted target. This method is not a device
  /// command and cannot dispatch Flash; the daemon applies Core rebind policy
  /// and persists the adjacent revision before returning.
  package static let forwardableRockchipBindingMethods: Set<String> = [
    "flash.bind-current-loader"
  ]

  /// History's single saved query preset is App-owned local presentation
  /// state. These methods can only replace or remove that bounded Runtime
  /// resource; they cannot submit a Job, touch an Artifact or reach a device.
  package static let forwardableHistoryFilterMethods: Set<String> = [
    "history.filter.delete",
    "history.filter.save",
  ]

  /// Trace cache maintenance is a local, lease-aware mutation over derived
  /// databases only. Runtime fixes the cache root at composition time; the App
  /// cannot supply a path or ask this method to remove original trace Artifacts.
  package static let forwardableTraceCacheMethods: Set<String> = [
    "trace.cache.purge"
  ]

  /// Session output configuration belongs to the daemon. These two methods
  /// can only replace a generation-bound policy or validated local root; they
  /// cannot dispatch a device operation or address the Artifact store.
  package static let forwardableRuntimeStorageMethods: Set<String> = [
    "runtime.storage.policy",
    "runtime.storage.root",
  ]

  /// Session discovery and pinning share the daemon-owned storage catalog.
  /// Inputs are closed at the XPC boundary: callers can name only one Session,
  /// a bounded opaque page cursor, or the exact catalog generation they read.
  package static let forwardableSessionMethods: Set<String> = [
    "session.cleanup.apply",
    "session.cleanup.preview",
    "session.export.apply",
    "session.export.preview",
    "session.list",
    "session.pin",
    "session.show",
    "session.unpin",
  ]

  /// These names are generic in the daemon protocol. The XPC endpoint must
  /// additionally prove one of the closed App-owned typed requests and bind
  /// the returned Job identifier before forwarding run or cancel.
  package static let gatedAppJobMethods: Set<String> = [
    "job.cancel",
    "job.run",
    "job.submit",
  ]

  package static let forwardableMethods =
    forwardableReadOnlyMethods
    .union(forwardableImportMethods)
    .union(forwardableRockchipBindingMethods)
    .union(forwardableHistoryFilterMethods)
    .union(forwardableTraceCacheMethods)
    .union(forwardableRuntimeStorageMethods)
    .union(forwardableSessionMethods)
    .union(gatedAppJobMethods)

  /// Reason codes returned to the client instead of a forwarded response.
  /// They are stable strings so the App can present an accurate cause rather
  /// than a generic failure.
  package enum RefusalReason: String, Sendable {
    case malformedRequestFrame
    case methodNotAllowlisted
  }

  private enum RequestFrameFailure: Error {
    case unsupportedProtocolVersion
  }

  private struct RequestFrame: Encodable {
    let protocolVersion: String
    let contractIdentity: String
    let id: String
    let method: String
    let params: [String: JSONValue]?
  }
}

/// The vended interface. `Data` in, `Data` out: one request frame, one
/// response frame, both in the daemon's existing wire protocol.
@objc package protocol ArkDeckAgentXPCProtocol {
  /// - Parameter reply: `(response, refusalReason)`. Exactly one is non-nil.
  ///   A refusal never reaches the daemon's request handler.
  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void)
}
