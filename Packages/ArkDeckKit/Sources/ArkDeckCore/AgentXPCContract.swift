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
  /// The frozen App/XPC and legacy client version. Exact versions are generated
  /// from Contracts/control-negotiation.json; a target client negotiates instead.
  package static let wireProtocolVersion = ArkDeckControlProtocol.legacyVersion

  /// The major this build speaks, derived rather than restated.
  ///
  /// A major stated separately is the same defect one octave down: it can
  /// disagree with the version it is supposed to be the major of, and the
  /// daemon's admission check compares against it. Deriving it means the two
  /// cannot part company.
  package static let wireProtocolMajor: Int = {
    guard let text = wireProtocolVersion.split(separator: ".").first, let major = Int(text) else {
      preconditionFailure("the wire protocol version must begin with a numeric major")
    }
    return major
  }()

  /// Numeric-descending exact versions. Supporting a format does not publish
  /// every method on it: the generated target method table remains explicit.
  package static let supportedWireProtocolExactVersions = ArkDeckControlProtocol
    .supportedExactVersions

  /// Builds the single versioned request shape accepted by the daemon. Method
  /// admission remains in `AgentXPCEndpoint`; this only prevents App facades
  /// from drifting onto an obsolete or caller-shaped wire envelope.
  package static func requestFrame(
    method: String,
    params: [String: JSONValue]? = nil,
    requestID: String = UUID().uuidString,
    protocolVersion: String = wireProtocolVersion
  ) throws -> Data {
    guard supportedWireProtocolExactVersions.contains(protocolVersion) else {
      throw RequestFrameFailure.unsupportedProtocolVersion
    }
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(
      RequestFrame(
        protocolVersion: protocolVersion,
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
    "artifact.quota",
    "artifact.read",
    "device.candidates",
    "debug.probe",
    "debug.template.run",
    "flash.bootloader-status",
    "flash.device-access",
    "flash.lanePlanPreview",
    "flash.prerequisites",
    "history.filter.list",
    "job.evidence",
    "job.list",
    "job.list-page",
    "job.status",
    "operation.list",
    "runtime.hdc-status",
    "runtime.storage.status",
    "target.list",
    "trace.cache.status",
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

  /// Native-library ingestion is the closed App-owned upload for the
  /// published deploy.native-library.app-owned operation. The caller supplies
  /// a selected target, a safe lib*.so basename, exact byte facts and bounded
  /// chunks; Runtime validates the signed ELF and returns an identity-bound
  /// lease. No host path or device destination crosses XPC.
  package static let forwardableNativeLibraryImportMethods: Set<String> = [
    "artifact.importNativeLibrary.abort",
    "artifact.importNativeLibrary.append",
    "artifact.importNativeLibrary.begin",
    "artifact.importNativeLibrary.commit",
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
    .union(forwardableFlashBundleMethods)
    .union(forwardableHAPImportMethods)
    .union(forwardableNativeLibraryImportMethods)
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
