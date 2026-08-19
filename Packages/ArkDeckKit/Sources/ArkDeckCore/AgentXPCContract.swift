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
  package static let debugAppsWorkspace = "ArkDeckApp.DebugWorkspace.Apps"
  package static let debugNetworkWorkspace = "ArkDeckApp.DebugWorkspace.Network"
}

/// The global Mach service name the daemon vends and the App looks up. It is
/// duplicated in the App's `mach-lookup` exception and in the LaunchAgent
/// `MachServices` key; all three must agree or the lookup fails closed.
package enum ArkDeckAgentXPC {
  package static let machServiceName = "com.arkdeck.agentd"
  /// The App's XPC door forwards the daemon's existing wire frame;
  /// keeping the version here prevents App clients from inventing a legacy
  /// key that passes the XPC allowlist but fails daemon decoding.
  package static let wireProtocolVersion = "1.0.0"

  /// Builds the single versioned request shape accepted by the daemon. Method
  /// admission remains in `AgentXPCEndpoint`; this only prevents App facades
  /// from drifting onto an obsolete or caller-shaped wire envelope.
  package static func requestFrame(
    method: String,
    params: [String: JSONValue]? = nil,
    requestID: String = UUID().uuidString
  ) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(
      RequestFrame(
        protocolVersion: wireProtocolVersion,
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
  /// `device.candidates` is the discovery read behind the App's device list:
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
    "artifact.read",
    "device.candidates",
    "debug.probe",
    "debug.template.run",
    "flash.bootloader-status",
    "flash.lanePlanPreview",
    "flash.prerequisites",
    "job.evidence",
    "job.list",
    "job.list-page",
    "job.status",
    "operation.list",
    "runtime.hdc-status",
    "target.list",
    "trace.probe",
  ]

  /// Bundle ingestion is the stateless effectful part of the closed Flash
  /// workflow. Unlike the generic job method names below, each entry is
  /// intrinsically scoped to a Flash bundle.
  package static let forwardableFlashBundleMethods: Set<String> = [
    "artifact.importFlashBundle.abort",
    "artifact.importFlashBundle.append",
    "artifact.importFlashBundle.begin",
    "artifact.importFlashBundle.commit",
  ]

  /// HAP ingestion is the other closed App-owned Artifact upload. The caller
  /// supplies only an adopted target, a safe basename, exact byte facts and
  /// bounded chunks; Runtime validates the container and returns an
  /// identity-bound lease. No host or device path crosses XPC.
  package static let forwardableHAPImportMethods: Set<String> = [
    "artifact.importHap.abort",
    "artifact.importHap.append",
    "artifact.importHap.begin",
    "artifact.importHap.commit",
  ]

  /// The App may ask Runtime to bind one freshly re-read Loader candidate to
  /// the explicitly selected adopted target. This method is not a device
  /// command and cannot dispatch Flash; the daemon applies Core rebind policy
  /// and persists the adjacent revision before returning.
  package static let forwardableRockchipBindingMethods: Set<String> = [
    "flash.bind-current-loader"
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
    .union(forwardableFlashBundleMethods)
    .union(forwardableHAPImportMethods)
    .union(forwardableRockchipBindingMethods)
    .union(gatedAppJobMethods)

  /// Reason codes returned to the client instead of a forwarded response.
  /// They are stable strings so the App can present an accurate cause rather
  /// than a generic failure.
  package enum RefusalReason: String, Sendable {
    case malformedRequestFrame
    case methodNotAllowlisted
  }

  private struct RequestFrame: Encodable {
    let protocolVersion: String
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
