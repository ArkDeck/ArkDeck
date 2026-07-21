import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

public enum ArkDeckOpenHarmonyModule {
  public static let identifier = "ArkDeckOpenHarmony"
}

/// Sources are ordered deliberately: a user-selected external HDC wins over
/// an SDK-discovered candidate, and the process `PATH` is never searched.
public enum HDCCandidateSource: String, Sendable, Equatable, CaseIterable {
  case userConfigured
  case devecoSDK
  case openHarmonySDK
}

public struct HDCDiscoveryRequest: Sendable, Equatable {
  public let userConfiguredPaths: [URL]
  public let devecoSDKPaths: [URL]
  public let openHarmonySDKPaths: [URL]
  /// Keyed by the resolved absolute executable path. The bookmark is carried
  /// into the candidate so discovery, hashing, and child launch can each hold
  /// the same sandbox capability for their complete file-access window.
  public let securityScopedBookmarks: [String: Data]

  public init(
    userConfiguredPaths: [URL] = [],
    devecoSDKPaths: [URL] = [],
    openHarmonySDKPaths: [URL] = [],
    securityScopedBookmarks: [String: Data] = [:]
  ) {
    self.userConfiguredPaths = userConfiguredPaths
    self.devecoSDKPaths = devecoSDKPaths
    self.openHarmonySDKPaths = openHarmonySDKPaths
    self.securityScopedBookmarks = securityScopedBookmarks
  }
}

public struct HDCCandidate: Sendable, Equatable {
  public let path: URL
  public let source: HDCCandidateSource
  public let sha256: String
  public let securityScopedBookmark: Data?

  public init(
    path: URL,
    source: HDCCandidateSource,
    sha256: String,
    securityScopedBookmark: Data? = nil
  ) {
    self.path = path
    self.source = source
    self.sha256 = sha256
    self.securityScopedBookmark = securityScopedBookmark
  }
}

private enum HDCSecurityScopedAccessError: Error {
  case staleBookmark
  case resolvedPathMismatch
}

/// Retains the PowerBox extension, when one is present, until `stop()` or
/// deinitialization. A false `startAccessing` result is not treated as proof of
/// access: the subsequent executable/hash operation still has to succeed.
final class HDCSecurityScopedExecutableAccess {
  private let url: URL?
  private var didStart = false

  init(path: URL, bookmark: Data?) throws {
    guard let bookmark else {
      url = nil
      return
    }
    var isStale = false
    let resolved = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale)
    guard !isStale else { throw HDCSecurityScopedAccessError.staleBookmark }
    guard
      resolved.resolvingSymlinksInPath().standardizedFileURL
        == path.resolvingSymlinksInPath().standardizedFileURL
    else {
      throw HDCSecurityScopedAccessError.resolvedPathMismatch
    }
    url = resolved
    didStart = resolved.startAccessingSecurityScopedResource()
  }

  func stop() {
    guard didStart, let url else { return }
    didStart = false
    url.stopAccessingSecurityScopedResource()
  }

  deinit { stop() }
}

public enum HDCDiscoveryIssue: Sendable, Equatable {
  case pathMustBeAbsolute(path: String, source: HDCCandidateSource)
  case notAnExecutableFile(path: String, source: HDCCandidateSource)
  case hashFailed(path: String, source: HDCCandidateSource, reason: String)
}

public struct HDCDiscoveryReport: Sendable, Equatable {
  public let candidates: [HDCCandidate]
  public let issues: [HDCDiscoveryIssue]

  public init(candidates: [HDCCandidate], issues: [HDCDiscoveryIssue]) {
    self.candidates = candidates
    self.issues = issues
  }
}

/// Revalidates the immutable toolchain snapshot immediately before a process
/// request enters the process port. A path is not an executable identity: a
/// replacement at the same path must fail closed instead of inheriting the
/// hash recorded by discovery or a Job snapshot.
public enum HDCCandidateIdentityVerifier {
  public static func sha256(of path: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
      hasher.update(data: bytes)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func matches(_ candidate: HDCCandidate) -> Bool {
    guard
      let access = try? HDCSecurityScopedExecutableAccess(
        path: candidate.path, bookmark: candidate.securityScopedBookmark)
    else { return false }
    defer { access.stop() }
    guard candidate.path.isFileURL,
      FileManager.default.isExecutableFile(atPath: candidate.path.path),
      let current = try? sha256(of: candidate.path)
    else { return false }
    return current == candidate.sha256
  }
}

/// Discovers only explicitly supplied external/SDK locations. It does not
/// execute a candidate and therefore cannot start, stop, or mutate an HDC
/// server.
public enum HDCExternalFirstDiscovery {
  public static func discover(_ request: HDCDiscoveryRequest) -> HDCDiscoveryReport {
    let orderedPaths: [(HDCCandidateSource, [URL])] = [
      (.userConfigured, request.userConfiguredPaths),
      (.devecoSDK, request.devecoSDKPaths),
      (.openHarmonySDK, request.openHarmonySDKPaths),
    ]
    var candidates: [HDCCandidate] = []
    var issues: [HDCDiscoveryIssue] = []
    var seenPaths = Set<String>()

    for (source, paths) in orderedPaths {
      for originalPath in paths {
        guard originalPath.isFileURL, originalPath.path.hasPrefix("/") else {
          issues.append(.pathMustBeAbsolute(path: originalPath.path, source: source))
          continue
        }
        let path = originalPath.resolvingSymlinksInPath().standardizedFileURL
        guard seenPaths.insert(path.path).inserted else { continue }
        let bookmark = request.securityScopedBookmarks[path.path]
        guard
          let access = try? HDCSecurityScopedExecutableAccess(path: path, bookmark: bookmark)
        else {
          issues.append(
            .hashFailed(
              path: path.path, source: source,
              reason: "security-scoped bookmark is stale or resolves to another executable"))
          continue
        }
        defer { access.stop() }
        guard FileManager.default.isExecutableFile(atPath: path.path) else {
          issues.append(.notAnExecutableFile(path: path.path, source: source))
          continue
        }
        do {
          candidates.append(
            HDCCandidate(
              path: path,
              source: source,
              sha256: try HDCCandidateIdentityVerifier.sha256(of: path),
              securityScopedBookmark: bookmark)
          )
        } catch {
          issues.append(
            .hashFailed(path: path.path, source: source, reason: error.localizedDescription))
        }
      }
    }
    return HDCDiscoveryReport(candidates: candidates, issues: issues)
  }
}

/// A diagnostic has a value only when a probe established it. Missing probe
/// fields are retained as explicit unknowns rather than omitted or guessed.
public enum HDCProbeValue<Value: Sendable & Equatable>: Sendable, Equatable {
  case known(Value)
  case unknown(reason: String)
}

public struct HDCProbeDetails: Sendable, Equatable {
  public let platformTrust: HDCProbeValue<String>
  public let clientVersion: HDCProbeValue<String>
  public let serverVersion: HDCProbeValue<String>
  public let daemonVersion: HDCProbeValue<String>
  public let serverGeneration: HDCProbeValue<Int>

  public init(
    platformTrust: HDCProbeValue<String>,
    clientVersion: HDCProbeValue<String>,
    serverVersion: HDCProbeValue<String>,
    daemonVersion: HDCProbeValue<String>,
    serverGeneration: HDCProbeValue<Int>
  ) {
    self.platformTrust = platformTrust
    self.clientVersion = clientVersion
    self.serverVersion = serverVersion
    self.daemonVersion = daemonVersion
    self.serverGeneration = serverGeneration
  }

  public static let unprobed = HDCProbeDetails(
    platformTrust: .unknown(reason: "ToolTrustInspector has not run"),
    clientVersion: .unknown(reason: "HDC version probe has not run"),
    serverVersion: .unknown(reason: "HDC server probe has not run"),
    daemonVersion: .unknown(reason: "HDC daemon probe has not run"),
    serverGeneration: .unknown(reason: "HDCServerSupervisor has not run")
  )
}

/// This is a value snapshot, not a reference to Settings. A Job can retain it
/// unchanged when the candidate list later changes.
public struct HDCJobToolchainSnapshot: Sendable, Equatable {
  public let path: URL
  public let source: HDCCandidateSource
  public let sha256: String
  public let endpoint: String
  /// In-memory observation metadata. The durable Core toolchain intent keeps
  /// the resolved endpoint while diagnostics also retain how it was selected
  /// and which keys ArkDeck overlays on child processes only.
  public let endpointSource: HDCServerEndpointSource?
  public let childEnvironmentKeys: [String]
  public let platformTrust: HDCProbeValue<String>
  public let clientVersion: HDCProbeValue<String>
  public let serverVersion: HDCProbeValue<String>
  public let daemonVersion: HDCProbeValue<String>
  public let serverGeneration: HDCProbeValue<Int>

  public init(
    candidate: HDCCandidate,
    endpoint: String,
    endpointSource: HDCServerEndpointSource? = nil,
    childEnvironmentKeys: [String] = [],
    details: HDCProbeDetails
  ) {
    self.path = candidate.path
    self.source = candidate.source
    self.sha256 = candidate.sha256
    self.endpoint = endpoint
    self.endpointSource = endpointSource
    self.childEnvironmentKeys = Array(Set(childEnvironmentKeys)).sorted()
    self.platformTrust = details.platformTrust
    self.clientVersion = details.clientVersion
    self.serverVersion = details.serverVersion
    self.daemonVersion = details.daemonVersion
    self.serverGeneration = details.serverGeneration
  }

  public init(
    candidate: HDCCandidate,
    endpointSelection: HDCServerEndpointSelection,
    details: HDCProbeDetails
  ) {
    self.init(
      candidate: candidate,
      endpoint: endpointSelection.endpoint.rawValue,
      endpointSource: endpointSelection.source,
      childEnvironmentKeys: Array(endpointSelection.childEnvironment.keys),
      details: details)
  }
}

public enum HDCCommandSemanticResult: Sendable, Equatable {
  case success
  case failure(HDCCommandFailure)
  case unknownOutput
}

public enum HDCCommandFailure: Sendable, Equatable {
  case nonZeroExit(Int32)
  case explicitFailureMarker
  case unauthorized
  case offline
}

/// A bounded streaming parser for the currently declared fixture family. An
/// exit status of zero is necessary but deliberately insufficient for success.
/// Future output families must be added through an integration-profile change.
/// TASK-M1-006 will adopt `ProcessSemanticEvaluating`; this task deliberately
/// leaves that parser/executor wiring unchanged.
public struct HDCSemanticOutputParser: Sendable {
  private static let failureMarkers: [[UInt8]] = [
    Array("unauthorized".utf8),
    Array("e000002".utf8),
    Array("e000003".utf8),
    Array("offline".utf8),
    Array("[fail]".utf8),
    Array("errorcode".utf8),
  ]
  private static let successMarker = Array("[success]".utf8)
  private static let carryLength =
    max(
      successMarker.count,
      failureMarkers.map(\.count).max() ?? 0
    ) - 1

  /// ASCII-only marker matching keeps protocol markers intact across a UTF-8
  /// chunk boundary. Raw output itself remains available through the Process
  /// output stream and is not decoded or rewritten here.
  private var carry: [UInt8] = []
  private var hasSuccessMarker = false
  private var failure: HDCCommandFailure?

  public init() {}

  public mutating func consume(_ chunk: ProcessOutputChunk) {
    let normalizedChunk = chunk.bytes.map(asciiLowercased)
    let searchable = carry + normalizedChunk

    // Search the complete new chunk before retaining only a boundary carry.
    // A pipe may deliver 4–64 KiB at once, so truncating before this step
    // would allow an early failure marker to be hidden by later output.
    if contains(searchable, marker: Array("unauthorized".utf8))
      || contains(searchable, marker: Array("e000002".utf8))
      || contains(searchable, marker: Array("e000003".utf8))
    {
      failure = .unauthorized
    } else if contains(searchable, marker: Array("offline".utf8)) {
      if failure == nil || failure == .explicitFailureMarker {
        failure = .offline
      }
    } else if contains(searchable, marker: Array("[fail]".utf8))
      || contains(searchable, marker: Array("errorcode".utf8))
    {
      if failure == nil {
        failure = .explicitFailureMarker
      }
    }
    hasSuccessMarker = hasSuccessMarker || contains(searchable, marker: Self.successMarker)
    carry = Array(searchable.suffix(Self.carryLength))
  }

  public func finish(exitCode: Int32) -> HDCCommandSemanticResult {
    if exitCode != 0 {
      return .failure(.nonZeroExit(exitCode))
    }
    if let failure {
      return .failure(failure)
    }
    return hasSuccessMarker ? .success : .unknownOutput
  }

  private func asciiLowercased(_ byte: UInt8) -> UInt8 {
    (65...90).contains(byte) ? byte + 32 : byte
  }

  private func contains(_ bytes: [UInt8], marker: [UInt8]) -> Bool {
    guard !marker.isEmpty, bytes.count >= marker.count else { return false }
    return bytes.indices.contains { start in
      guard start + marker.count <= bytes.endIndex else { return false }
      return bytes[start..<(start + marker.count)].elementsEqual(marker)
    }
  }
}

// MARK: - Host-wide HDC server supervision

/// An endpoint is host-wide infrastructure, never a per-device connection
/// detail. The supervisor uses this type to keep all affected coordinators in
/// the same event and lifecycle domain.
public struct HDCServerEndpoint: Hashable, Sendable, Equatable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    precondition(!rawValue.isEmpty, "An HDC server endpoint must not be empty")
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public enum HDCServerOwnership: String, Sendable, Equatable {
  case external
  case arkDeckManaged
  case unknown
}

public enum HDCServerHealth: String, Sendable, Equatable {
  case healthy
  case unavailable
  case unknown
}

public struct HDCAutomaticDispatchSnapshot: Sendable, Equatable {
  public let automaticLifecycleDispatchCount: Int
  public let automaticSubserverDispatchCount: Int

  public init(
    automaticLifecycleDispatchCount: Int,
    automaticSubserverDispatchCount: Int
  ) {
    precondition(
      automaticLifecycleDispatchCount >= 0 && automaticSubserverDispatchCount >= 0,
      "HDC automatic dispatch counters cannot be negative")
    self.automaticLifecycleDispatchCount = automaticLifecycleDispatchCount
    self.automaticSubserverDispatchCount = automaticSubserverDispatchCount
  }
}

package enum HDCAutomaticDispatchKind: Sendable, Equatable {
  case lifecycle
  case subserver
}

package actor HDCAutomaticDispatchInstrumentation {
  private var automaticLifecycleDispatchCount = 0
  private var automaticSubserverDispatchCount = 0

  package init() {}

  func record(_ kind: HDCAutomaticDispatchKind) {
    switch kind {
    case .lifecycle: automaticLifecycleDispatchCount += 1
    case .subserver: automaticSubserverDispatchCount += 1
    }
  }

  func snapshot() -> HDCAutomaticDispatchSnapshot {
    HDCAutomaticDispatchSnapshot(
      automaticLifecycleDispatchCount: automaticLifecycleDispatchCount,
      automaticSubserverDispatchCount: automaticSubserverDispatchCount)
  }
}

/// Evidence behind the external/unknown label. External is reachable only
/// when all three approved observations are present; the basis is retained so
/// presentation never needs to infer why a label was selected.
public struct HDCServerOwnershipBasis: Sendable, Equatable {
  public let preExistingServerReceipt: Bool
  public let automaticLifecycleDispatchCount: Int?
  public let generationMintedFromObservation: Bool

  public init(
    preExistingServerReceipt: Bool,
    automaticLifecycleDispatchCount: Int?,
    generationMintedFromObservation: Bool
  ) {
    precondition(
      automaticLifecycleDispatchCount.map { $0 >= 0 } ?? true,
      "HDC automatic lifecycle dispatch evidence cannot be negative")
    self.preExistingServerReceipt = preExistingServerReceipt
    self.automaticLifecycleDispatchCount = automaticLifecycleDispatchCount
    self.generationMintedFromObservation = generationMintedFromObservation
  }

  public var establishesExternalOwnership: Bool {
    preExistingServerReceipt && automaticLifecycleDispatchCount == 0
      && generationMintedFromObservation
  }
}

public struct HDCServerState: Sendable, Equatable {
  public let endpoint: HDCServerEndpoint
  public let health: HDCServerHealth
  public let version: HDCProbeValue<String>
  /// The monotonic value is useful only when `generationEvidence` is known.
  /// A read-only `checkserver` result has no server identity and therefore
  /// must not make this value eligible for lifecycle confirmation.
  public let generation: Int
  public let generationEvidence: HDCProbeValue<Int>
  public let ownership: HDCServerOwnership
  public let ownershipBasis: HDCServerOwnershipBasis?

  init(
    endpoint: HDCServerEndpoint,
    health: HDCServerHealth,
    version: HDCProbeValue<String>,
    generation: Int,
    generationEvidence: HDCProbeValue<Int>? = nil,
    ownership: HDCServerOwnership,
    ownershipBasis: HDCServerOwnershipBasis? = nil
  ) {
    precondition(generation >= 0, "A server generation must not be negative")
    self.endpoint = endpoint
    self.health = health
    self.version = version
    self.generation = generation
    self.generationEvidence = generationEvidence ?? .known(generation)
    self.ownership = ownership
    self.ownershipBasis = ownershipBasis
  }
}

/// Observations of an already-running server can only establish external or
/// unknown ownership. ArkDeck-managed ownership has a separate evidence gate.
struct HDCExistingServerObservation: Sendable, Equatable {
  let state: HDCServerState

  init(state: HDCServerState) {
    precondition(state.ownership != .arkDeckManaged, "Managed ownership requires launch evidence")
    self.state = state
  }
}

struct HDCManagedServerLaunchEvidence: Sendable, Equatable {
  let endpoint: HDCServerEndpoint
  let pid: Int32
  let toolPath: URL
  /// Complete argv excluding argv[0]. This is compared verbatim to the
  /// live process before ArkDeck can claim managed ownership.
  let arguments: [String]
  let generation: Int
  let version: HDCProbeValue<String>
}

/// Verifies a managed-server claim against the live process table. A record is
/// not enough: PID liveness, executable identity, complete argv, and the
/// explicit endpoint argument must all still agree when ownership is claimed.
protocol HDCManagedServerProcessInspecting: Sendable {
  func matches(_ evidence: HDCManagedServerLaunchEvidence) -> Bool
}

struct SystemHDCManagedServerProcessInspector: HDCManagedServerProcessInspecting {
  func matches(_ evidence: HDCManagedServerLaunchEvidence) -> Bool {
    guard evidence.pid > 0,
      evidence.toolPath.isFileURL,
      evidence.toolPath.path.hasPrefix("/"),
      FileManager.default.isExecutableFile(atPath: evidence.toolPath.path),
      kill(evidence.pid, 0) == 0,
      let executable = executablePath(for: evidence.pid),
      executable == evidence.toolPath.resolvingSymlinksInPath().standardizedFileURL,
      let arguments = arguments(for: evidence.pid),
      arguments == evidence.arguments,
      declares(endpoint: evidence.endpoint, in: arguments),
      ownsListeningEndpoint(evidence.endpoint, pid: evidence.pid)
    else { return false }
    return true
  }

  /// Process identity and argv only show intent. Managed ownership also
  /// requires the same PID to own a live TCP listener for the declared local
  /// endpoint. Remote/non-numeric hosts fail closed because they cannot be an
  /// ArkDeck-launched local daemon identity.
  private func ownsListeningEndpoint(_ endpoint: HDCServerEndpoint, pid: Int32) -> Bool {
    guard let selectedPort = localIPv4Port(endpoint) else { return false }
    let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard requiredBytes > 0 else { return false }
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(),
      count: Int(requiredBytes) / MemoryLayout<proc_fdinfo>.stride + 8)
    let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(
        pid, PROC_PIDLISTFDS, 0, buffer.baseAddress,
        Int32(buffer.count))
    }
    guard actualBytes >= MemoryLayout<proc_fdinfo>.stride else { return false }
    let descriptorCount = Int(actualBytes) / MemoryLayout<proc_fdinfo>.stride
    for descriptor in descriptors.prefix(descriptorCount)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var socket = socket_fdinfo()
      let socketBytes = withUnsafeMutablePointer(to: &socket) { pointer in
        proc_pidfdinfo(
          pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, pointer,
          Int32(MemoryLayout<socket_fdinfo>.size))
      }
      guard socketBytes == MemoryLayout<socket_fdinfo>.size,
        socket.psi.soi_family == AF_INET,
        socket.psi.soi_protocol == IPPROTO_TCP,
        socket.psi.soi_kind == SOCKINFO_TCP,
        socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
      else { continue }
      let socketPort = UInt16(
        bigEndian: UInt16(
          truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
      let address = socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr
      if socketPort == selectedPort,
        address == in_addr_t(INADDR_ANY) || address == inet_addr("127.0.0.1")
      {
        return true
      }
    }
    return false
  }

  private func localIPv4Port(_ endpoint: HDCServerEndpoint) -> UInt16? {
    guard let separator = endpoint.rawValue.lastIndex(of: ":") else { return nil }
    let host = String(endpoint.rawValue[..<separator])
    guard host == "127.0.0.1",
      let port = UInt16(endpoint.rawValue[endpoint.rawValue.index(after: separator)...]),
      port > 0
    else { return nil }
    return port
  }

  private func executablePath(for pid: Int32) -> URL? {
    // `PROC_PIDPATHINFO_MAXSIZE` is a C macro that Swift cannot import on
    // current macOS SDKs. `proc_pidpath` accepts this documented upper bound
    // (four MAXPATHLEN values) without relying on that unavailable macro.
    var buffer = [CChar](repeating: 0, count: 4 * 1_024)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    guard let terminator = buffer.firstIndex(of: 0) else { return nil }
    let path = String(
      decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
      .standardizedFileURL
  }

  private func arguments(for pid: Int32) -> [String]? {
    var maximumArguments = 0
    var maximumArgumentsSize = MemoryLayout<Int>.size
    var maximumArgumentsMIB = [CTL_KERN, KERN_ARGMAX]
    guard
      sysctl(
        &maximumArgumentsMIB, u_int(maximumArgumentsMIB.count), &maximumArguments,
        &maximumArgumentsSize, nil, 0
      ) == 0, maximumArguments > MemoryLayout<Int32>.size
    else { return nil }

    var buffer = [CChar](repeating: 0, count: maximumArguments)
    var actualSize = buffer.count
    var processArgumentsMIB = [CTL_KERN, KERN_PROCARGS2, pid]
    guard
      sysctl(
        &processArgumentsMIB, u_int(processArgumentsMIB.count), &buffer, &actualSize, nil, 0
      ) == 0, actualSize > MemoryLayout<Int32>.size
    else { return nil }
    let argumentCount = buffer.withUnsafeBytes { bytes in
      bytes.loadUnaligned(fromByteOffset: 0, as: Int32.self)
    }
    guard argumentCount > 0 else { return nil }

    var cursor = MemoryLayout<Int32>.size
    func skipNULs() {
      while cursor < actualSize && buffer[cursor] == 0 { cursor += 1 }
    }
    while cursor < actualSize && buffer[cursor] != 0 { cursor += 1 }
    skipNULs()

    var values: [String] = []
    for _ in 0..<argumentCount {
      skipNULs()
      guard cursor < actualSize else { return nil }
      let start = cursor
      while cursor < actualSize && buffer[cursor] != 0 { cursor += 1 }
      guard cursor < actualSize else { return nil }
      values.append(String(cString: Array(buffer[start...cursor])))
    }
    guard !values.isEmpty else { return nil }
    return Array(values.dropFirst())
  }

  private func declares(endpoint: HDCServerEndpoint, in arguments: [String]) -> Bool {
    guard let option = arguments.firstIndex(of: "-s"), arguments.indices.contains(option + 1)
    else { return false }
    return arguments[option + 1] == endpoint.rawValue
  }
}

public enum HDCServerRecipientKind: String, Sendable, Equatable {
  case deviceCoordinator
  case job
}

public struct HDCServerRecipient: Hashable, Sendable, Equatable {
  public let id: String
  public let kind: HDCServerRecipientKind
  public let endpoint: HDCServerEndpoint

  public init(id: String, kind: HDCServerRecipientKind, endpoint: HDCServerEndpoint) {
    precondition(!id.isEmpty, "A host-wide event recipient must have an identifier")
    self.id = id
    self.kind = kind
    self.endpoint = endpoint
  }
}

public enum HDCServerCriticalState: Sendable, Equatable {
  case none
  case criticalNonInterruptible(stepID: String, safeBoundaryAction: String)
  case waitingForSafeBoundary(stepID: String, safeBoundaryAction: String)
}

public struct HDCServerCriticalJob: Sendable, Equatable {
  public let jobID: String
  public let stepID: String
  public let safeBoundaryAction: String

  public init(jobID: String, stepID: String, safeBoundaryAction: String) {
    self.jobID = jobID
    self.stepID = stepID
    self.safeBoundaryAction = safeBoundaryAction
  }
}

public enum HDCServerOtherClientDetection: Sendable, Equatable {
  case detected([String])
  case noneDetectedExternalClientsMayStillExist
  case unavailableExternalClientsMayStillExist
}

public enum HDCServerLifecycleAction: String, Sendable, Equatable {
  case startManaged
  case stopConfirmedGeneration
  case restartConfirmedGeneration
}

public enum HDCServerExpectedOwnership: String, Sendable, Equatable {
  case absent
  case arkDeckManaged
  case external
  case unknown

  fileprivate init(_ ownership: HDCServerOwnership) {
    switch ownership {
    case .external: self = .external
    case .arkDeckManaged: self = .arkDeckManaged
    case .unknown: self = .unknown
    }
  }
}

/// This mirrors the Core `mutateHDCServerLifecycle` argument contract. It is a
/// typed authorization object, not a command line and cannot contain argv.
public struct HDCServerLifecycleStep: Sendable, Equatable {
  public let id: UUID
  public let auditID: UUID
  public let action: HDCServerLifecycleAction
  public let endpoint: HDCServerEndpoint
  public let expectedGeneration: Int?
  public let expectedOwnership: HDCServerExpectedOwnership
  public let impactSnapshotHash: String
  public let confirmationID: UUID?

  public init(
    id: UUID,
    auditID: UUID,
    action: HDCServerLifecycleAction,
    endpoint: HDCServerEndpoint,
    expectedGeneration: Int?,
    expectedOwnership: HDCServerExpectedOwnership,
    impactSnapshotHash: String,
    confirmationID: UUID?
  ) {
    self.id = id
    self.auditID = auditID
    self.action = action
    self.endpoint = endpoint
    self.expectedGeneration = expectedGeneration
    self.expectedOwnership = expectedOwnership
    self.impactSnapshotHash = impactSnapshotHash
    self.confirmationID = confirmationID
  }

  package static func coreWorkflowStep(
    id: UUID = UUID(),
    confirmation: HDCServerLifecycleConfirmation
  ) throws -> WorkflowStep {
    try WorkflowStep(
      id: id.uuidString,
      kind: .mutateHDCServerLifecycle,
      declaredEffect: .destructive,
      declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .none,
      arguments: [
        "action": .string(confirmation.action.rawValue),
        "endpoint": .string(confirmation.endpoint.rawValue),
        "expectedGeneration": .integer(Int64(confirmation.generation)),
        "expectedOwnership": .string(
          HDCServerExpectedOwnership(confirmation.ownership).rawValue),
        "impactSnapshotHash": .string(confirmation.scopeHash),
        "confirmationId": .string(confirmation.id.uuidString),
      ])
  }
}

public struct HDCServerImpactSnapshot: Sendable, Equatable {
  public let action: HDCServerLifecycleAction
  public let endpoint: HDCServerEndpoint
  public let generation: Int
  public let ownership: HDCServerOwnership
  public let affectedDeviceCoordinators: [String]
  public let affectedJobs: [String]
  public let otherClientDetection: HDCServerOtherClientDetection
  public let expectedInterruption: String
  public let recoveryPath: String

  public init(
    action: HDCServerLifecycleAction,
    endpoint: HDCServerEndpoint,
    generation: Int,
    ownership: HDCServerOwnership,
    affectedDeviceCoordinators: [String],
    affectedJobs: [String],
    otherClientDetection: HDCServerOtherClientDetection,
    expectedInterruption: String,
    recoveryPath: String
  ) {
    self.action = action
    self.endpoint = endpoint
    self.generation = generation
    self.ownership = ownership
    self.affectedDeviceCoordinators = affectedDeviceCoordinators.sorted()
    self.affectedJobs = affectedJobs.sorted()
    self.otherClientDetection = otherClientDetection
    self.expectedInterruption = expectedInterruption
    self.recoveryPath = recoveryPath
  }

  public var scopeHash: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let canonical = try? encoder.encode(HDCServerImpactCanonicalScope(self)) else {
      preconditionFailure("The fixed HDC impact scope schema must be JSON encodable")
    }
    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
  }
}

/// A versioned, typed JSON payload gives every scalar and array an explicit
/// structural boundary. In particular, `["a,b"]` cannot collide with
/// `["a", "b"]`, and a client identifier cannot escape into another field.
private struct HDCServerImpactCanonicalScope: Encodable {
  struct OtherClientScope: Encodable {
    let kind: String
    let clients: [String]
  }

  let schemaVersion: Int
  let action: String
  let endpoint: String
  let generation: Int
  let ownership: String
  let affectedDeviceCoordinators: [String]
  let affectedJobs: [String]
  let otherClientDetection: OtherClientScope
  let expectedInterruption: String
  let recoveryPath: String

  init(_ snapshot: HDCServerImpactSnapshot) {
    schemaVersion = 1
    action = snapshot.action.rawValue
    endpoint = snapshot.endpoint.rawValue
    generation = snapshot.generation
    ownership = snapshot.ownership.rawValue
    affectedDeviceCoordinators = snapshot.affectedDeviceCoordinators
    affectedJobs = snapshot.affectedJobs
    expectedInterruption = snapshot.expectedInterruption
    recoveryPath = snapshot.recoveryPath
    switch snapshot.otherClientDetection {
    case .detected(let clients):
      otherClientDetection = OtherClientScope(kind: "detected", clients: clients.sorted())
    case .noneDetectedExternalClientsMayStillExist:
      otherClientDetection = OtherClientScope(
        kind: "noneDetectedExternalClientsMayStillExist", clients: [])
    case .unavailableExternalClientsMayStillExist:
      otherClientDetection = OtherClientScope(
        kind: "unavailableExternalClientsMayStillExist", clients: [])
    }
  }
}

public struct HDCServerLifecycleImpactPreview: Sendable, Equatable {
  public let id: UUID
  public let auditID: UUID
  public let snapshot: HDCServerImpactSnapshot

  public init(id: UUID, auditID: UUID, snapshot: HDCServerImpactSnapshot) {
    self.id = id
    self.auditID = auditID
    self.snapshot = snapshot
  }
}

public struct HDCServerLifecycleConfirmation: Sendable, Equatable {
  public let id: UUID
  public let auditID: UUID
  public let previewID: UUID
  public let action: HDCServerLifecycleAction
  public let endpoint: HDCServerEndpoint
  public let generation: Int
  public let ownership: HDCServerOwnership
  public let scopeHash: String

  public init(id: UUID, preview: HDCServerLifecycleImpactPreview) {
    self.id = id
    auditID = preview.auditID
    previewID = preview.id
    action = preview.snapshot.action
    endpoint = preview.snapshot.endpoint
    generation = preview.snapshot.generation
    ownership = preview.snapshot.ownership
    scopeHash = preview.snapshot.scopeHash
  }
}

public enum HDCServerLifecycleExecutionOutcome: Sendable, Equatable {
  case succeeded(resultingGeneration: Int)
  /// A confirmed stop is only complete once a post-dispatch probe observes
  /// the selected endpoint unavailable. It must not be represented as a
  /// healthy generation.
  case stopped
  case failed(reason: String)
  case outcomeUnknown(reason: String)
}

/// Complete typed Supervisor scope observed while finalizing an already
/// durable lifecycle result. Optional state fields distinguish an absent
/// endpoint from an unknown value; generation evidence is retained verbatim
/// rather than collapsing unknown identity into a caller-supplied integer.
public struct HDCServerLifecycleObservedScope: Sendable, Equatable {
  public let action: HDCServerLifecycleAction
  public let endpoint: HDCServerEndpoint
  public let health: HDCServerHealth?
  public let version: HDCProbeValue<String>?
  public let generation: Int?
  public let generationEvidence: HDCProbeValue<Int>?
  public let ownership: HDCServerOwnership?
  public let affectedDeviceCoordinators: [String]
  public let affectedJobs: [String]
  public let otherClientDetection: HDCServerOtherClientDetection
  public let criticalJobs: [HDCServerCriticalJob]
  public let impactReliable: Bool
  public let scopeHash: String?

  public init(
    action: HDCServerLifecycleAction,
    endpoint: HDCServerEndpoint,
    health: HDCServerHealth?,
    version: HDCProbeValue<String>?,
    generation: Int?,
    generationEvidence: HDCProbeValue<Int>?,
    ownership: HDCServerOwnership?,
    affectedDeviceCoordinators: [String],
    affectedJobs: [String],
    otherClientDetection: HDCServerOtherClientDetection,
    criticalJobs: [HDCServerCriticalJob],
    impactReliable: Bool,
    scopeHash: String?
  ) {
    self.action = action
    self.endpoint = endpoint
    self.health = health
    self.version = version
    self.generation = generation
    self.generationEvidence = generationEvidence
    self.ownership = ownership
    self.affectedDeviceCoordinators = affectedDeviceCoordinators.sorted()
    self.affectedJobs = affectedJobs.sorted()
    self.otherClientDetection = otherClientDetection
    self.criticalJobs = criticalJobs.sorted {
      ($0.jobID, $0.stepID, $0.safeBoundaryAction)
        < ($1.jobID, $1.stepID, $1.safeBoundaryAction)
    }
    self.impactReliable = impactReliable
    self.scopeHash = scopeHash
  }
}

/// Terminal durable interpretation of a lifecycle process result. Every
/// successful/stopped historical outcome receives one of these records, even
/// when the Supervisor scope is unchanged. Recovery can therefore treat a
/// success with no terminal record as `outcomeUnknown` instead of trusting an
/// append that may have failed during re-entrant reconciliation.
public struct HDCServerLifecycleReconciliation: Sendable, Equatable {
  public let id: UUID
  public let stepID: UUID
  public let auditID: UUID
  public let expectedScopeHash: String
  public let historicalOutcome: HDCServerLifecycleExecutionOutcome
  public let outwardOutcome: HDCServerLifecycleExecutionOutcome
  public let observedScope: HDCServerLifecycleObservedScope
  /// The process-backed probe result is retained separately from the
  /// Supervisor actor's current scope. This prevents a generation observed
  /// after launch from being silently replaced by the pre-dispatch actor
  /// generation while still preserving both facts for recovery.
  public let postDispatchObservation: HDCServerLifecyclePostDispatchObservation?
  public let requiresReconcile: Bool
  public let reason: String

  public init(
    id: UUID = UUID(),
    stepID: UUID,
    auditID: UUID,
    expectedScopeHash: String,
    historicalOutcome: HDCServerLifecycleExecutionOutcome,
    outwardOutcome: HDCServerLifecycleExecutionOutcome,
    observedScope: HDCServerLifecycleObservedScope,
    postDispatchObservation: HDCServerLifecyclePostDispatchObservation? = nil,
    requiresReconcile: Bool,
    reason: String
  ) {
    self.id = id
    self.stepID = stepID
    self.auditID = auditID
    self.expectedScopeHash = expectedScopeHash
    self.historicalOutcome = historicalOutcome
    self.outwardOutcome = outwardOutcome
    self.observedScope = observedScope
    self.postDispatchObservation = postDispatchObservation
    self.requiresReconcile = requiresReconcile
    self.reason = reason
  }
}

/// A one-shot capability issued only after the Supervisor has persisted an
/// intent and revalidated its impact scope. It intentionally carries no
/// authority by itself: the Supervisor consumes it immediately before a
/// lifecycle executor hands argv to the process port.
struct HDCServerLifecycleDispatchLease: Sendable, Equatable {
  let id: UUID
  let stepID: UUID
  let auditID: UUID
  let endpoint: HDCServerEndpoint
  let launchGate: ProcessAtomicLaunchGate

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.stepID == rhs.stepID && lhs.auditID == rhs.auditID
      && lhs.endpoint == rhs.endpoint && lhs.launchGate === rhs.launchGate
  }
}

/// The executor must consume this capability after its durable actual-command
/// write and immediately before process launch. State mutations remove every
/// affected lease, making a re-entrant Supervisor update fail closed.
protocol HDCServerLifecycleDispatchLeaseValidating: Sendable {
  func consumeDispatchLease(
    _ lease: HDCServerLifecycleDispatchLease,
    for step: HDCServerLifecycleStep
  ) async -> Bool
}

protocol HDCServerLifecycleExecutor: Sendable {
  func execute(
    _ step: HDCServerLifecycleStep,
    lease: HDCServerLifecycleDispatchLease
  ) async -> HDCServerLifecycleExecutorResult
}

/// Internal executor receipt. The lifecycle outcome remains the public
/// presentation value, while the process-backed observation is carried to the
/// Supervisor solely for durable reconciliation.
struct HDCServerLifecycleExecutorResult: Sendable, Equatable {
  let outcome: HDCServerLifecycleExecutionOutcome
  let postDispatchObservation: HDCServerLifecyclePostDispatchObservation?

  init(
    outcome: HDCServerLifecycleExecutionOutcome,
    postDispatchObservation: HDCServerLifecyclePostDispatchObservation? = nil
  ) {
    self.outcome = outcome
    self.postDispatchObservation = postDispatchObservation
  }
}

package enum HDCServerLifecycleAuditEvent: Sendable, Equatable {
  case impactPreview(HDCServerLifecycleImpactPreview)
  case confirmation(HDCServerLifecycleConfirmation)
  case intent(HDCServerLifecycleStep)
  case outcome(stepID: UUID, auditID: UUID, outcome: HDCServerLifecycleExecutionOutcome)
  case reconciliation(HDCServerLifecycleReconciliation)
}

/// Production wiring must provide durable storage. The prototype accepts this
/// narrow sink so that a failed intent write can block an executor dispatch.
package protocol HDCServerLifecycleAuditStore: Sendable {
  func append(_ event: HDCServerLifecycleAuditEvent) async throws
  /// Commits the terminal interpretation without an actor suspension. The
  /// Supervisor calculates the final scope and applies the resulting endpoint
  /// state in the same actor turn, so an audit callback cannot invalidate the
  /// scope between terminal persistence and state application.
  func appendTerminalReconciliation(_ reconciliation: HDCServerLifecycleReconciliation) throws
}

final class InMemoryHDCServerLifecycleAuditStore: HDCServerLifecycleAuditStore,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var entries: [HDCServerLifecycleAuditEvent] = []

  init() {}

  func append(_ event: HDCServerLifecycleAuditEvent) {
    lock.lock()
    defer { lock.unlock() }
    entries.append(event)
  }

  func appendTerminalReconciliation(_ reconciliation: HDCServerLifecycleReconciliation) {
    lock.lock()
    defer { lock.unlock() }
    entries.append(.reconciliation(reconciliation))
  }

  func events() -> [HDCServerLifecycleAuditEvent] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }
}

public struct HDCServerGenerationChange: Sendable, Equatable {
  public let endpoint: HDCServerEndpoint
  public let previousGeneration: Int
  public let currentGeneration: Int
  public let ownership: HDCServerOwnership
  public let reason: String

  public init(
    endpoint: HDCServerEndpoint,
    previousGeneration: Int,
    currentGeneration: Int,
    ownership: HDCServerOwnership,
    reason: String
  ) {
    self.endpoint = endpoint
    self.previousGeneration = previousGeneration
    self.currentGeneration = currentGeneration
    self.ownership = ownership
    self.reason = reason
  }
}

public struct HDCServerHealthChange: Sendable, Equatable {
  public let endpoint: HDCServerEndpoint
  public let generation: Int
  public let ownership: HDCServerOwnership
  public let previousHealth: HDCServerHealth
  public let currentHealth: HDCServerHealth
  public let reason: String

  public init(
    endpoint: HDCServerEndpoint,
    generation: Int,
    ownership: HDCServerOwnership,
    previousHealth: HDCServerHealth,
    currentHealth: HDCServerHealth,
    reason: String
  ) {
    self.endpoint = endpoint
    self.generation = generation
    self.ownership = ownership
    self.previousHealth = previousHealth
    self.currentHealth = currentHealth
    self.reason = reason
  }
}

public struct HDCServerLifecycleBroadcast: Sendable, Equatable {
  public let stepID: UUID
  public let auditID: UUID
  public let endpoint: HDCServerEndpoint
  public let outcome: HDCServerLifecycleExecutionOutcome
  public let requiresReconcile: Bool

  public init(
    stepID: UUID,
    auditID: UUID,
    endpoint: HDCServerEndpoint,
    outcome: HDCServerLifecycleExecutionOutcome,
    requiresReconcile: Bool
  ) {
    self.stepID = stepID
    self.auditID = auditID
    self.endpoint = endpoint
    self.outcome = outcome
    self.requiresReconcile = requiresReconcile
  }
}

public enum HDCDevicePresenceChange: String, Sendable, Equatable {
  case appeared
  case disappeared
}

/// A snapshot immediately irreversibly redacts device identifiers. The raw
/// connect key is never retained in supervisor state, events, or presentation.
public struct HDCReadOnlyDeviceSnapshot: Sendable, Equatable {
  public let endpoint: HDCServerEndpoint
  public let redactedDeviceIdentifiers: Set<String>
  public let observedAt: Date

  public init(
    endpoint: HDCServerEndpoint,
    sensitiveDeviceIdentifiers: [String],
    observedAt: Date = Date()
  ) {
    self.endpoint = endpoint
    redactedDeviceIdentifiers = Set(
      sensitiveDeviceIdentifiers.filter { !$0.isEmpty }.map(Self.redact))
    self.observedAt = observedAt
  }

  private static func redact(_ identifier: String) -> String {
    let digest = SHA256.hash(data: Data(identifier.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "redacted-device-\(digest.prefix(24))"
  }
}

public struct HDCDeviceObservationEvent: Sendable, Equatable {
  public let endpoint: HDCServerEndpoint
  public let change: HDCDevicePresenceChange
  public let redactedDeviceIdentifier: String
  public let observedAt: Date

  public init(
    endpoint: HDCServerEndpoint,
    change: HDCDevicePresenceChange,
    redactedDeviceIdentifier: String,
    observedAt: Date
  ) {
    self.endpoint = endpoint
    self.change = change
    self.redactedDeviceIdentifier = redactedDeviceIdentifier
    self.observedAt = observedAt
  }
}

public enum HDCServerEvent: Sendable, Equatable {
  case generationChanged(HDCServerGenerationChange)
  case healthChanged(HDCServerHealthChange)
  case lifecycleOutcome(HDCServerLifecycleBroadcast)
  case devicePresenceChanged(HDCDeviceObservationEvent)
  case diagnostic(endpoint: HDCServerEndpoint, reason: String)
}

public enum HDCServerLifecycleDispatchBlock: Sendable, Equatable {
  case startManagedRequiresAbsentEndpointPrecondition
  case endpointStateUnknown
  case impactCannotBeReliablyDetermined
  case previewNotFound
  case confirmationNotFound
  case confirmationStale(HDCServerLifecycleImpactPreview)
  case criticalJobs([HDCServerCriticalJob])
  case invalidTypedStep
  case auditPersistenceFailed
  case recoveryRequired(reason: String)
}

public enum HDCServerImpactPreviewResult: Sendable, Equatable {
  case ready(HDCServerLifecycleImpactPreview)
  case blocked(HDCServerLifecycleDispatchBlock)
}

public enum HDCServerConfirmationResult: Sendable, Equatable {
  case accepted(HDCServerLifecycleConfirmation)
  case blocked(HDCServerLifecycleDispatchBlock)
}

public enum HDCServerLifecycleDispatchResult: Sendable, Equatable {
  case completed(HDCServerLifecycleExecutionOutcome)
  case blocked(HDCServerLifecycleDispatchBlock)
}

struct HDCManagedStartAuthorization: Sendable, Equatable, Hashable {
  let id: UUID
  let endpoint: HDCServerEndpoint
}

/// The only host-wide owner of HDC server state. It deliberately has no
/// automatic lifecycle executor: automatic diagnostic/recovery paths can only
/// publish diagnostics, never stop, restart, or move an external/unknown HDC
/// server. Manual mutation is gated by a typed step, impact snapshot,
/// confirmation, revalidation, critical-job gate, and audit sink.
public actor HDCServerSupervisor: HDCServerLifecycleDispatchLeaseValidating {
  static let deviceObservationBufferLimit = 32

  nonisolated let automaticDispatchInstrumentation: HDCAutomaticDispatchInstrumentation
  private let auditStore: any HDCServerLifecycleAuditStore
  private let managedProcessInspector: any HDCManagedServerProcessInspecting
  private var endpoints: [HDCServerEndpoint: HDCServerState] = [:]
  private var recipients: [HDCServerRecipient: HDCServerCriticalState] = [:]
  private var deliveredEvents: [HDCServerRecipient: [HDCServerEvent]] = [:]
  private var otherClientDetection: [HDCServerEndpoint: HDCServerOtherClientDetection] = [:]
  private var impactReliability: [HDCServerEndpoint: Bool] = [:]
  private var participantImpactReliability: [HDCServerEndpoint: Bool] = [:]
  private var previews: [UUID: HDCServerLifecycleImpactPreview] = [:]
  private var confirmations: [UUID: HDCServerLifecycleConfirmation] = [:]
  private var managedStartAuthorizations: [UUID: HDCManagedStartAuthorization] = [:]
  private var activeDispatchLeases: [UUID: HDCServerLifecycleDispatchLease] = [:]
  private var deviceSnapshots: [HDCServerEndpoint: Set<String>] = [:]
  private var deviceObservationEvents: [HDCServerEndpoint: [HDCDeviceObservationEvent]] = [:]
  private let permitsImplicitTestFixtureReliability: Bool

  /// Legacy `@testable` module contracts predate the production participant
  /// inventory. Keeping that behavior module-internal prevents Workflows and
  /// other normal package consumers from constructing a lifecycle-eligible
  /// Supervisor without an explicit production participant disposition.
  init(auditStore: any HDCServerLifecycleAuditStore) {
    automaticDispatchInstrumentation = HDCAutomaticDispatchInstrumentation()
    self.auditStore = auditStore
    managedProcessInspector = SystemHDCManagedServerProcessInspector()
    permitsImplicitTestFixtureReliability = true
  }

  package init(
    auditStore: any HDCServerLifecycleAuditStore,
    endpoint: HDCServerEndpoint,
    participantImpactReliable: Bool
  ) {
    automaticDispatchInstrumentation = HDCAutomaticDispatchInstrumentation()
    self.auditStore = auditStore
    managedProcessInspector = SystemHDCManagedServerProcessInspector()
    permitsImplicitTestFixtureReliability = false
    participantImpactReliability[endpoint] = participantImpactReliable
  }

  public func register(_ recipient: HDCServerRecipient) {
    invalidateDispatchLeases(for: recipient.endpoint)
    recipients[recipient] = recipients[recipient] ?? HDCServerCriticalState.none
    deliveredEvents[recipient] = deliveredEvents[recipient] ?? []
  }

  public func unregister(_ recipient: HDCServerRecipient) {
    invalidateDispatchLeases(for: recipient.endpoint)
    recipients.removeValue(forKey: recipient)
    deliveredEvents.removeValue(forKey: recipient)
  }

  public func updateCriticalState(
    _ state: HDCServerCriticalState, for recipient: HDCServerRecipient
  ) {
    // Only a registered Job participates in the host-wide critical gate.
    // Ignoring stale device/unregistered notifications prevents an unknown
    // sender from manufacturing a blocker for an unrelated endpoint.
    guard recipient.kind == .job, recipients[recipient] != nil else { return }
    invalidateDispatchLeases(for: recipient.endpoint)
    recipients[recipient] = state
  }

  public func setOtherClientDetection(
    _ detection: HDCServerOtherClientDetection, for endpoint: HDCServerEndpoint
  ) {
    invalidateDispatchLeases(for: endpoint)
    otherClientDetection[endpoint] = detection
  }

  /// This control models a failed host-wide inspection. It is intentionally
  /// separate from best-effort external-client discovery, which remains a
  /// visible uncertainty but does not make the HDC endpoint unknowable.
  func setImpactReliability(_ isReliable: Bool, for endpoint: HDCServerEndpoint) {
    invalidateDispatchLeases(for: endpoint)
    impactReliability[endpoint] = isReliable
  }

  /// App/runtime composition owns the completeness of the host-wide
  /// DeviceCoordinator/Job inventory. A verified server identity cannot make
  /// lifecycle impact reliable while that production participant feed is
  /// absent or incomplete.
  package func setParticipantImpactReliability(
    _ isReliable: Bool, for endpoint: HDCServerEndpoint
  ) {
    invalidateDispatchLeases(for: endpoint)
    participantImpactReliability[endpoint] = isReliable
  }

  public func state(for endpoint: HDCServerEndpoint) -> HDCServerState? {
    endpoints[endpoint]
  }

  public func automaticDispatchSnapshot() async -> HDCAutomaticDispatchSnapshot {
    await automaticDispatchInstrumentation.snapshot()
  }

  public func recentDeviceObservationEvents(
    for endpoint: HDCServerEndpoint
  ) -> [HDCDeviceObservationEvent] {
    deviceObservationEvents[endpoint] ?? []
  }

  /// Consumes a snapshot already obtained through an approved read-only feed.
  /// This method owns no process runner and cannot issue a device command.
  public func observeReadOnlyDeviceSnapshot(_ snapshot: HDCReadOnlyDeviceSnapshot) {
    let previous = deviceSnapshots[snapshot.endpoint] ?? []
    let appeared = snapshot.redactedDeviceIdentifiers.subtracting(previous).sorted()
    let disappeared = previous.subtracting(snapshot.redactedDeviceIdentifiers).sorted()
    deviceSnapshots[snapshot.endpoint] = snapshot.redactedDeviceIdentifiers

    for identifier in appeared {
      appendDeviceObservationEvent(
        HDCDeviceObservationEvent(
          endpoint: snapshot.endpoint,
          change: .appeared,
          redactedDeviceIdentifier: identifier,
          observedAt: snapshot.observedAt))
    }
    for identifier in disappeared {
      appendDeviceObservationEvent(
        HDCDeviceObservationEvent(
          endpoint: snapshot.endpoint,
          change: .disappeared,
          redactedDeviceIdentifier: identifier,
          observedAt: snapshot.observedAt))
    }
  }

  public func takeDeliveredEvents(for recipient: HDCServerRecipient) -> [HDCServerEvent] {
    let events = deliveredEvents[recipient] ?? []
    deliveredEvents[recipient] = []
    return events
  }

  /// Automatic paths are diagnostics-only by construction. There is no
  /// executor parameter and therefore no reachable automatic kill/restart.
  public func recordAutomaticDiagnosticFailure(endpoint: HDCServerEndpoint, reason: String) {
    broadcast(.diagnostic(endpoint: endpoint, reason: reason), endpoint: endpoint)
  }

  func observeExistingServer(_ observation: HDCExistingServerObservation, reason: String) {
    let next = observation.state
    invalidateDispatchLeases(for: next.endpoint)
    let previous = endpoints[next.endpoint]
    endpoints[next.endpoint] = next

    guard let previous else { return }
    if previous.generation != next.generation {
      broadcast(
        .generationChanged(
          HDCServerGenerationChange(
            endpoint: next.endpoint,
            previousGeneration: previous.generation,
            currentGeneration: next.generation,
            ownership: next.ownership,
            reason: reason
          )
        ),
        endpoint: next.endpoint
      )
    } else if previous.health != next.health {
      broadcast(
        .healthChanged(
          HDCServerHealthChange(
            endpoint: next.endpoint,
            generation: next.generation,
            ownership: next.ownership,
            previousHealth: previous.health,
            currentHealth: next.health,
            reason: reason
          )
        ),
        endpoint: next.endpoint
      )
    }
  }

  /// Applies a read-only server observation that does not carry a process or
  /// server identity. `checkserver` can report health and a version string,
  /// but it cannot prove a generation: a healthy server may have been
  /// replaced between two successful probes. Keep the diagnostic state while
  /// deliberately making lifecycle impact unreliable until a separately
  /// verified identity source observes the endpoint.
  @discardableResult
  func observeUnidentifiedServer(
    endpoint: HDCServerEndpoint,
    health: HDCServerHealth,
    version: HDCProbeValue<String>,
    reason: String
  ) -> HDCServerState {
    let previous = endpoints[endpoint]
    let generation = previous?.generation ?? 0
    let next = HDCServerState(
      endpoint: endpoint, health: health, version: version, generation: generation,
      generationEvidence: .unknown(
        reason: "checkserver does not provide a verifiable server identity or generation"),
      ownership: .unknown)
    impactReliability[endpoint] = false
    observeExistingServer(HDCExistingServerObservation(state: next), reason: reason)
    if previous?.ownership == .arkDeckManaged {
      broadcast(
        .diagnostic(
          endpoint: endpoint,
          reason: "checkserver did not revalidate the previously managed process identity"),
        endpoint: endpoint)
    }
    return next
  }

  /// Applies a commandless, bracketed process/start/listener identity receipt
  /// from the registered 0.3.0 platform observer. The generation is minted by
  /// the adapter from receipt equality/change; no caller-supplied generation
  /// or `checkserver` text can reach this path on its own.
  @discardableResult
  func observeRegisteredServerIdentity(
    endpoint: HDCServerEndpoint,
    health: HDCServerHealth,
    version: HDCProbeValue<String>,
    generation: Int,
    ownershipBasis: HDCServerOwnershipBasis,
    reason: String
  ) -> HDCServerState {
    let ownership: HDCServerOwnership =
      ownershipBasis.establishesExternalOwnership ? .external : .unknown
    let next = HDCServerState(
      endpoint: endpoint, health: health, version: version,
      generation: generation, generationEvidence: .known(generation),
      ownership: ownership, ownershipBasis: ownershipBasis)
    impactReliability[endpoint] = true
    observeExistingServer(HDCExistingServerObservation(state: next), reason: reason)
    return next
  }

  /// A tool identity error, launch failure, registered failure response, or
  /// unregistered output is a probe failure—not proof that a server is absent
  /// or external. Do not create endpoint state from it. If state already
  /// exists, revoke its identity/generation claims and retain only an unknown
  /// diagnostic state until an approved identity source observes it again.
  func recordUnverifiedServerProbeFailure(endpoint: HDCServerEndpoint, reason: String) {
    invalidateDispatchLeases(for: endpoint)
    impactReliability[endpoint] = false
    if let previous = endpoints[endpoint] {
      let next = HDCServerState(
        endpoint: endpoint,
        health: .unknown,
        version: .unknown(reason: reason),
        generation: previous.generation,
        generationEvidence: .unknown(reason: reason),
        ownership: .unknown
      )
      observeExistingServer(HDCExistingServerObservation(state: next), reason: reason)
    }
    broadcast(.diagnostic(endpoint: endpoint, reason: reason), endpoint: endpoint)
  }

  /// A managed server cannot be claimed merely because it is healthy or uses
  /// the expected port. The endpoint must have been absent when authorization
  /// was created, and the recorded PID, absolute tool path, and endpoint must
  /// all verify after the managed launch.
  func authorizeManagedStart(at endpoint: HDCServerEndpoint) -> HDCManagedStartAuthorization? {
    guard endpoints[endpoint] == nil else { return nil }
    let authorization = HDCManagedStartAuthorization(id: UUID(), endpoint: endpoint)
    managedStartAuthorizations[authorization.id] = authorization
    return authorization
  }

  @discardableResult
  func recordManagedStart(
    authorization: HDCManagedStartAuthorization,
    evidence: HDCManagedServerLaunchEvidence
  ) -> Bool {
    guard managedStartAuthorizations.removeValue(forKey: authorization.id) == authorization,
      endpoints[authorization.endpoint] == nil,
      evidence.endpoint == authorization.endpoint,
      evidence.pid > 0,
      evidence.generation >= 0,
      evidence.toolPath.isFileURL,
      evidence.toolPath.path.hasPrefix("/"),
      managedProcessInspector.matches(evidence)
    else {
      return false
    }

    invalidateDispatchLeases(for: authorization.endpoint)
    endpoints[authorization.endpoint] = HDCServerState(
      endpoint: authorization.endpoint,
      health: .healthy,
      version: .unknown(
        reason: "managed process identity does not prove the daemon version"),
      generation: evidence.generation,
      generationEvidence: .unknown(
        reason: "managed process identity does not prove the server generation"),
      ownership: .arkDeckManaged
    )
    return true
  }

  public func createImpactPreview(
    action: HDCServerLifecycleAction,
    endpoint: HDCServerEndpoint
  ) async -> HDCServerImpactPreviewResult {
    guard action != .startManaged else {
      return .blocked(.startManagedRequiresAbsentEndpointPrecondition)
    }
    guard let snapshot = currentImpactSnapshot(action: action, endpoint: endpoint) else {
      return .blocked(
        !impactIsReliable(for: endpoint)
          ? .impactCannotBeReliablyDetermined : .endpointStateUnknown)
    }
    return await persistPreview(snapshot)
  }

  public func confirm(_ previewID: UUID) async -> HDCServerConfirmationResult {
    guard let preview = previews[previewID] else { return .blocked(.previewNotFound) }
    guard
      let snapshot = currentImpactSnapshot(
        action: preview.snapshot.action, endpoint: preview.snapshot.endpoint)
    else {
      return .blocked(
        !impactIsReliable(for: preview.snapshot.endpoint)
          ? .impactCannotBeReliablyDetermined : .endpointStateUnknown)
    }
    guard snapshot.scopeHash == preview.snapshot.scopeHash else {
      return await staleConfirmation(for: snapshot)
    }

    let confirmation = HDCServerLifecycleConfirmation(id: UUID(), preview: preview)
    do {
      try await auditStore.append(.confirmation(confirmation))
    } catch {
      return .blocked(.auditPersistenceFailed)
    }
    confirmations[confirmation.id] = confirmation
    return .accepted(confirmation)
  }

  func dispatch(
    confirmationID: UUID,
    using executor: any HDCServerLifecycleExecutor
  ) async -> HDCServerLifecycleDispatchResult {
    guard let confirmation = confirmations[confirmationID] else {
      return .blocked(.confirmationNotFound)
    }
    guard let coreStep = try? HDCServerLifecycleStep.coreWorkflowStep(confirmation: confirmation)
    else {
      return .blocked(.invalidTypedStep)
    }
    return await dispatchValidated(
      confirmationID: confirmationID, coreStep: coreStep, using: executor)
  }

  package func dispatch(
    confirmationID: UUID,
    coreStep: WorkflowStep,
    using executor: HDCProcessLifecycleExecutor
  ) async -> HDCServerLifecycleDispatchResult {
    await dispatchValidated(
      confirmationID: confirmationID, coreStep: coreStep, using: executor)
  }

  private func dispatchValidated(
    confirmationID: UUID,
    coreStep: WorkflowStep,
    using executor: any HDCServerLifecycleExecutor
  ) async -> HDCServerLifecycleDispatchResult {
    guard let confirmation = confirmations.removeValue(forKey: confirmationID) else {
      return .blocked(.confirmationNotFound)
    }
    guard let stepID = UUID(uuidString: coreStep.id),
      coreStep
        == (try? HDCServerLifecycleStep.coreWorkflowStep(
          id: stepID, confirmation: confirmation))
    else {
      return .blocked(.invalidTypedStep)
    }
    guard
      let snapshot = currentImpactSnapshot(
        action: confirmation.action, endpoint: confirmation.endpoint)
    else {
      return .blocked(
        !impactIsReliable(for: confirmation.endpoint)
          ? .impactCannotBeReliablyDetermined : .endpointStateUnknown)
    }
    guard snapshot.scopeHash == confirmation.scopeHash else {
      let stale = await staleConfirmation(for: snapshot)
      if case .blocked(let block) = stale { return .blocked(block) }
      return .blocked(.auditPersistenceFailed)
    }

    let blockers = criticalJobs(for: confirmation.endpoint)
    guard blockers.isEmpty else { return .blocked(.criticalJobs(blockers)) }

    let step = HDCServerLifecycleStep(
      id: stepID,
      auditID: confirmation.auditID,
      action: confirmation.action,
      endpoint: confirmation.endpoint,
      expectedGeneration: confirmation.generation,
      expectedOwnership: HDCServerExpectedOwnership(confirmation.ownership),
      impactSnapshotHash: confirmation.scopeHash,
      confirmationID: confirmation.id
    )
    do {
      try await auditStore.append(.intent(step))
    } catch {
      return .blocked(.auditPersistenceFailed)
    }

    // `auditStore.append` is a suspension point. A Job coordinator or a
    // fresh server observation can update this actor while the intent is
    // being persisted, so this is deliberately the final non-suspending
    // scope/gate validation before dispatch reaches the executor.
    guard
      let postIntentSnapshot = currentImpactSnapshot(
        action: confirmation.action, endpoint: confirmation.endpoint)
    else {
      let block: HDCServerLifecycleDispatchBlock =
        !impactIsReliable(for: confirmation.endpoint)
        ? .impactCannotBeReliablyDetermined
        : .endpointStateUnknown
      return await recordPostIntentBlock(step: step, block: block)
    }
    guard postIntentSnapshot.scopeHash == confirmation.scopeHash else {
      let staleResult = await staleConfirmation(for: postIntentSnapshot)
      guard case .blocked(let block) = staleResult else {
        return await recordPostIntentBlock(step: step, block: .auditPersistenceFailed)
      }
      return await recordPostIntentBlock(step: step, block: block)
    }

    let postIntentBlockers = criticalJobs(for: confirmation.endpoint)
    guard postIntentBlockers.isEmpty else {
      return await recordPostIntentBlock(step: step, block: .criticalJobs(postIntentBlockers))
    }

    let lease = HDCServerLifecycleDispatchLease(
      id: UUID(), stepID: step.id, auditID: step.auditID, endpoint: step.endpoint,
      launchGate: ProcessAtomicLaunchGate())
    activeDispatchLeases[lease.id] = lease
    let executorResult = await executor.execute(step, lease: lease)
    activeDispatchLeases.removeValue(forKey: lease.id)
    let outcome = reconciledLifecycleOutcome(executorResult.outcome, for: step)
    do {
      try await auditStore.append(
        .outcome(stepID: step.id, auditID: step.auditID, outcome: outcome))
    } catch {
      let unknown = HDCServerLifecycleExecutionOutcome.outcomeUnknown(
        reason: "Lifecycle outcome audit could not be persisted")
      broadcastLifecycleOutcome(step: step, outcome: unknown)
      return .completed(unknown)
    }

    // The outcome append can re-enter this actor. A successful/stopped result
    // and every result from an entered launch window are not terminal until a
    // second durable record captures the complete current scope and its
    // outward interpretation. Missing reconciliation is therefore
    // conservatively recoverable as outcomeUnknown after reopen.
    let requiresTerminalReconciliation: Bool
    switch outcome {
    case .succeeded, .stopped:
      requiresTerminalReconciliation = true
    case .outcomeUnknown:
      requiresTerminalReconciliation = true
    case .failed:
      // The production executor emits failed only before its durable launch
      // window marker, so no external lifecycle effect needs reconciliation.
      requiresTerminalReconciliation = false
    }
    if requiresTerminalReconciliation {
      let stillMatches: Bool
      let requiresReconcile: Bool
      switch outcome {
      case .succeeded, .stopped:
        stillMatches = lifecycleStateStillMatches(step)
        requiresReconcile = !stillMatches
      case .outcomeUnknown:
        stillMatches = false
        requiresReconcile = true
      case .failed:
        preconditionFailure("failed outcomes do not enter terminal reconciliation")
      }
      let reason: String
      if case .outcomeUnknown = outcome {
        reason = "entered lifecycle launch window has an uncertain external effect"
      } else if stillMatches {
        reason = "durable lifecycle outcome reconciled against unchanged supervisor scope"
      } else {
        reason = "server state changed during durable lifecycle outcome persistence"
      }
      let outwardOutcome: HDCServerLifecycleExecutionOutcome
      if case .outcomeUnknown = outcome {
        outwardOutcome = outcome
      } else {
        outwardOutcome =
          stillMatches ? outcome : .outcomeUnknown(reason: reason)
      }
      let reconciliation = HDCServerLifecycleReconciliation(
        stepID: step.id,
        auditID: step.auditID,
        expectedScopeHash: step.impactSnapshotHash,
        historicalOutcome: outcome,
        outwardOutcome: outwardOutcome,
        observedScope: observedLifecycleScope(action: step.action, endpoint: step.endpoint),
        postDispatchObservation: executorResult.postDispatchObservation,
        requiresReconcile: requiresReconcile,
        reason: reason
      )
      do {
        try auditStore.appendTerminalReconciliation(reconciliation)
      } catch {
        let unknown = HDCServerLifecycleExecutionOutcome.outcomeUnknown(
          reason: "Lifecycle reconciliation audit could not be persisted")
        broadcastLifecycleOutcome(step: step, outcome: unknown)
        return .completed(unknown)
      }
      guard stillMatches else {
        broadcastLifecycleOutcome(step: step, outcome: outwardOutcome)
        return .completed(outwardOutcome)
      }
    }

    if let current = endpoints[step.endpoint] {
      switch outcome {
      case .succeeded(let resultingGeneration):
        endpoints[step.endpoint] = HDCServerState(
          endpoint: current.endpoint,
          health: .healthy,
          version: current.version,
          generation: resultingGeneration,
          ownership: current.ownership,
          ownershipBasis: current.ownershipBasis
        )
      case .stopped:
        endpoints[step.endpoint] = HDCServerState(
          endpoint: current.endpoint,
          health: .unavailable,
          version: .unknown(reason: "confirmed lifecycle stop"),
          generation: current.generation,
          ownership: current.ownership,
          ownershipBasis: current.ownershipBasis
        )
      case .failed, .outcomeUnknown:
        break
      }
    }
    broadcastLifecycleOutcome(step: step, outcome: outcome)
    return .completed(outcome)
  }

  /// Atomically consume a lease against the latest actor-owned state.  A
  /// state change that re-entered while the executor awaited durable storage
  /// removes the lease before this method can return true.
  func consumeDispatchLease(
    _ lease: HDCServerLifecycleDispatchLease,
    for step: HDCServerLifecycleStep
  ) -> Bool {
    guard activeDispatchLeases[lease.id] == lease,
      lease.stepID == step.id,
      lease.auditID == step.auditID,
      lease.endpoint == step.endpoint,
      let snapshot = currentImpactSnapshot(action: step.action, endpoint: step.endpoint),
      snapshot.scopeHash == step.impactSnapshotHash,
      snapshot.generation == step.expectedGeneration,
      HDCServerExpectedOwnership(snapshot.ownership) == step.expectedOwnership,
      criticalJobs(for: step.endpoint).isEmpty
    else {
      return false
    }
    return true
  }

  /// This helper is only called after a durable intent exists but before an
  /// executor is invoked. It closes the audit record and broadcasts the
  /// failed lifecycle result; no caller can continue to external dispatch.
  private func recordPostIntentBlock(
    step: HDCServerLifecycleStep,
    block: HDCServerLifecycleDispatchBlock
  ) async -> HDCServerLifecycleDispatchResult {
    let outcome = HDCServerLifecycleExecutionOutcome.failed(
      reason: "blocked after intent persistence")
    do {
      try await auditStore.append(
        .outcome(stepID: step.id, auditID: step.auditID, outcome: outcome))
    } catch {
      let unknown = HDCServerLifecycleExecutionOutcome.outcomeUnknown(
        reason: "Lifecycle block outcome audit could not be persisted")
      broadcastLifecycleOutcome(step: step, outcome: unknown)
      return .blocked(.auditPersistenceFailed)
    }
    broadcastLifecycleOutcome(step: step, outcome: outcome)
    return .blocked(block)
  }

  private func currentImpactSnapshot(
    action: HDCServerLifecycleAction,
    endpoint: HDCServerEndpoint
  ) -> HDCServerImpactSnapshot? {
    guard impactIsReliable(for: endpoint),
      let state = endpoints[endpoint],
      state.health == .healthy,
      case .known(let verifiedGeneration) = state.generationEvidence
    else {
      return nil
    }
    let affected = recipients.keys.filter { $0.endpoint == endpoint }
    return HDCServerImpactSnapshot(
      action: action,
      endpoint: endpoint,
      generation: verifiedGeneration,
      ownership: state.ownership,
      affectedDeviceCoordinators: affected.filter { $0.kind == .deviceCoordinator }.map(\.id),
      affectedJobs: affected.filter { $0.kind == .job }.map(\.id),
      otherClientDetection: otherClientDetection[endpoint]
        ?? .unavailableExternalClientsMayStillExist,
      expectedInterruption: "HDC requests using this endpoint will be interrupted.",
      recoveryPath: "Re-probe the shared endpoint and reconcile every affected Job."
    )
  }

  private func observedLifecycleScope(
    action: HDCServerLifecycleAction,
    endpoint: HDCServerEndpoint
  ) -> HDCServerLifecycleObservedScope {
    let state = endpoints[endpoint]
    let affected = recipients.keys.filter { $0.endpoint == endpoint }
    return HDCServerLifecycleObservedScope(
      action: action,
      endpoint: endpoint,
      health: state?.health,
      version: state?.version,
      generation: state?.generation,
      generationEvidence: state?.generationEvidence,
      ownership: state?.ownership,
      affectedDeviceCoordinators: affected.filter { $0.kind == .deviceCoordinator }.map(\.id),
      affectedJobs: affected.filter { $0.kind == .job }.map(\.id),
      otherClientDetection: otherClientDetection[endpoint]
        ?? .unavailableExternalClientsMayStillExist,
      criticalJobs: criticalJobs(for: endpoint),
      impactReliable: impactIsReliable(for: endpoint),
      scopeHash: currentImpactSnapshot(action: action, endpoint: endpoint)?.scopeHash
    )
  }

  /// A lifecycle executor may suspend for process completion and a
  /// post-dispatch probe. Before its result becomes durable, revalidate that
  /// the exact state, affected-recipient scope, ownership, and critical gate
  /// that authorized the step still exist. A restart generation must advance
  /// monotonically even when an internal test executor is used.
  private func reconciledLifecycleOutcome(
    _ outcome: HDCServerLifecycleExecutionOutcome,
    for step: HDCServerLifecycleStep
  ) -> HDCServerLifecycleExecutionOutcome {
    switch outcome {
    case .succeeded(let generation):
      guard let expectedGeneration = step.expectedGeneration, generation > expectedGeneration else {
        return .outcomeUnknown(
          reason: "lifecycle outcome did not establish a strictly newer server generation")
      }
    case .stopped, .failed, .outcomeUnknown:
      break
    }

    switch outcome {
    case .succeeded, .stopped:
      guard lifecycleStateStillMatches(step) else {
        return .outcomeUnknown(
          reason: "server state changed before lifecycle outcome reconciliation")
      }
    case .failed, .outcomeUnknown:
      break
    }
    return outcome
  }

  /// This check is intentionally repeated after durable outcome persistence
  /// before changing endpoint state. The audit sink is asynchronous, so a
  /// newer observation may arrive in that interval; retain it rather than
  /// applying an older success/unavailable result over it.
  private func lifecycleStateStillMatches(_ step: HDCServerLifecycleStep) -> Bool {
    guard
      let snapshot = currentImpactSnapshot(action: step.action, endpoint: step.endpoint),
      snapshot.scopeHash == step.impactSnapshotHash,
      snapshot.generation == step.expectedGeneration,
      HDCServerExpectedOwnership(snapshot.ownership) == step.expectedOwnership,
      criticalJobs(for: step.endpoint).isEmpty
    else {
      return false
    }
    return true
  }

  private func criticalJobs(for endpoint: HDCServerEndpoint) -> [HDCServerCriticalJob] {
    recipients.compactMap { recipient, state in
      guard recipient.endpoint == endpoint, recipient.kind == .job else { return nil }
      switch state {
      case .none:
        return nil
      case .criticalNonInterruptible(let stepID, let safeBoundaryAction),
        .waitingForSafeBoundary(let stepID, let safeBoundaryAction):
        return HDCServerCriticalJob(
          jobID: recipient.id,
          stepID: stepID,
          safeBoundaryAction: safeBoundaryAction
        )
      }
    }.sorted { $0.jobID < $1.jobID }
  }

  private func impactIsReliable(for endpoint: HDCServerEndpoint) -> Bool {
    let fallback = permitsImplicitTestFixtureReliability
    return (impactReliability[endpoint] ?? fallback)
      && (participantImpactReliability[endpoint] ?? fallback)
  }

  private func persistPreview(_ snapshot: HDCServerImpactSnapshot) async
    -> HDCServerImpactPreviewResult
  {
    let preview = HDCServerLifecycleImpactPreview(id: UUID(), auditID: UUID(), snapshot: snapshot)
    do {
      try await auditStore.append(.impactPreview(preview))
    } catch {
      return .blocked(.auditPersistenceFailed)
    }
    previews[preview.id] = preview
    return .ready(preview)
  }

  private func staleConfirmation(for snapshot: HDCServerImpactSnapshot) async
    -> HDCServerConfirmationResult
  {
    switch await persistPreview(snapshot) {
    case .ready(let preview):
      return .blocked(.confirmationStale(preview))
    case .blocked(let block):
      return .blocked(block)
    }
  }

  private func broadcastLifecycleOutcome(
    step: HDCServerLifecycleStep,
    outcome: HDCServerLifecycleExecutionOutcome
  ) {
    let requiresReconcile: Bool
    switch outcome {
    case .succeeded, .stopped:
      requiresReconcile = false
    case .failed, .outcomeUnknown:
      requiresReconcile = true
    }
    broadcast(
      .lifecycleOutcome(
        HDCServerLifecycleBroadcast(
          stepID: step.id,
          auditID: step.auditID,
          endpoint: step.endpoint,
          outcome: outcome,
          requiresReconcile: requiresReconcile
        )
      ),
      endpoint: step.endpoint
    )
  }

  private func broadcast(_ event: HDCServerEvent, endpoint: HDCServerEndpoint) {
    for recipient in recipients.keys where recipient.endpoint == endpoint {
      deliveredEvents[recipient, default: []].append(event)
    }
  }

  private func appendDeviceObservationEvent(_ event: HDCDeviceObservationEvent) {
    var events = deviceObservationEvents[event.endpoint] ?? []
    events.append(event)
    if events.count > Self.deviceObservationBufferLimit {
      events.removeFirst(events.count - Self.deviceObservationBufferLimit)
    }
    deviceObservationEvents[event.endpoint] = events
    broadcast(.devicePresenceChanged(event), endpoint: event.endpoint)
  }

  private func invalidateDispatchLeases(for endpoint: HDCServerEndpoint) {
    for lease in activeDispatchLeases.values where lease.endpoint == endpoint {
      lease.launchGate.invalidate()
    }
    activeDispatchLeases = activeDispatchLeases.filter { $0.value.endpoint != endpoint }
  }
}
