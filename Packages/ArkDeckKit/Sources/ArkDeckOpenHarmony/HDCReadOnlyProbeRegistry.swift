import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

/// Closed adoption of `OPENHARMONY-TOOLS@0.3.0` and
/// `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`.
///
/// Production keeps the small executable contract below compiled into the
/// adapter. Contract tests decode the immutable Bundle.module copy and prove
/// that it maps byte-for-byte to this catalog and its fail-closed classifier.
struct HDCReadOnlyProbeRegistry: Sendable, Equatable {
  static let integrationProfile = "OPENHARMONY-TOOLS@0.3.0"
  static let registryID = "OPENHARMONY-HDC-READONLY-PROBES"
  static let registryVersion = "1.0.0"
  static let registrySHA256 =
    "9014c480c3df61b5a6db7e54e52f29e89d7c93431e91d0856cf5710c22466b9d"
  static let resourceManifestSHA256 =
    "d93fcc2668006f7e23e3355a0855b5a7f07515baa95413aaa31777dced74ac02"
  static let controlVectorSHA256 =
    "68c4aa48eb293d22d3531091fcd5dfce89ec73700674bfb6532584a94672726f"
  static let targetPlatform = "macos"
  static let targetToolVersion = "3.2.0d"
  static let targetExecutableSHA256 =
    "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260"

  enum Family: String, CaseIterable, Sendable {
    case serverIdentityGeneration
    case selectedDeviceAuthorizationBinding
    case keyAccessDiagnostics
    case subserverCapability
  }

  enum Status: String, Sendable {
    case supported
    case unsupported
  }

  enum ProbeKind: String, Sendable {
    case hdcCommand
    case platformProcessObservation
    case platformFileAccess
  }

  struct Entry: Sendable, Equatable {
    let id: String
    let family: Family
    let status: Status
    let probeKind: ProbeKind
    let exactArguments: [String]
    let invocationAllowed: Bool
    let timeoutMilliseconds: Int
    let rawFamily: String
    let rawSHA256: String?
    let receiptID: String
    let receiptSHA256: String
    let unsupportedReason: String?
  }

  let entries: [Entry]
  let targetExecutableSHA256: String

  static let pinnedProduction = HDCReadOnlyProbeRegistry(
    entries: [
      Entry(
        id: "openharmony-hdc-server-identity-generation-3.2.0d-macos",
        family: .serverIdentityGeneration, status: .supported,
        probeKind: .platformProcessObservation, exactArguments: [], invocationAllowed: false,
        timeoutMilliseconds: 1_000, rawFamily: "redactedPlatformReceipt", rawSHA256: nil,
        receiptID: "i15-receipt-server-identity-generation",
        receiptSHA256: "6f71af96bcd6c25a8a7c900538e01c1aff6144ee85e6c928a37fbc654c003a69",
        unsupportedReason: nil),
      Entry(
        id: "openharmony-hdc-selected-device-authorization-binding-3.2.0d",
        family: .selectedDeviceAuthorizationBinding, status: .supported,
        probeKind: .hdcCommand, exactArguments: ["list", "targets", "-v"],
        invocationAllowed: true, timeoutMilliseconds: 2_000,
        rawFamily: "listTargetsVerbose.singleUSBRow.connected.3.2.0d",
        rawSHA256: "d8816e413776d80e6e577b78f6abbf8c114bfd570b3627f7a007c97681af9c48",
        receiptID: "i15-receipt-selected-device-authorization-binding",
        receiptSHA256: "ea8257eb7c8404805521963307f06a94634341ad1470ccf13118f7f9028e0383",
        unsupportedReason: nil),
      Entry(
        id: "openharmony-hdc-key-access-diagnostics-3.2.0d-macos",
        family: .keyAccessDiagnostics, status: .unsupported,
        probeKind: .platformFileAccess, exactArguments: [], invocationAllowed: false,
        timeoutMilliseconds: 0, rawFamily: "noneRegistered", rawSHA256: nil,
        receiptID: "i15-receipt-key-access-diagnostics",
        receiptSHA256: "a87c2cf3754cd380699939060b2250b4bf0e406f1920cb8a69b930c9a23839e5",
        unsupportedReason:
          "No configured or user-approved HDC key locator was identified; the captured conventional-path absence cannot grant production path authority."
      ),
      Entry(
        id: "openharmony-hdc-subserver-capability-3.2.0d",
        family: .subserverCapability, status: .unsupported,
        probeKind: .hdcCommand, exactArguments: [], invocationAllowed: false,
        timeoutMilliseconds: 0, rawFamily: "noneRegistered", rawSHA256: nil,
        receiptID: "i15-receipt-subserver-capability",
        receiptSHA256: "565beee8a8d0ca84e026968db13a12ea5ebcb419428423dd2ee7dcd1165734ea",
        unsupportedReason:
          "The reviewed upstream source is 3.2.0b rather than the exact 3.2.0d target and proves no client-local, zero-lifecycle/device-migration observation command for the target revision."
      ),
    ])

  init(
    entries: [Entry],
    targetExecutableSHA256: String = Self.targetExecutableSHA256
  ) {
    self.entries = entries
    self.targetExecutableSHA256 = targetExecutableSHA256
  }

  init(registryData: Data) throws {
    let actualHash = SHA256.hash(data: registryData)
      .map { String(format: "%02x", $0) }.joined()
    guard actualHash == Self.registrySHA256 else {
      throw HDCReadOnlyProbeRegistryError.registryHashMismatch(
        expected: Self.registrySHA256, actual: actualHash)
    }
    let decoded = try JSONDecoder().decode(DecodedRegistry.self, from: registryData)
    guard decoded.schemaVersion == "1.0.0",
      decoded.serializationFormat == "json-compatible-yaml-1.2",
      decoded.registryId == Self.registryID,
      decoded.registryVersion == Self.registryVersion,
      decoded.integrationProfile == Self.integrationProfile,
      decoded.unknownFamilyDisposition == "unsupported",
      decoded.toolContext.platform == Self.targetPlatform,
      decoded.toolContext.reportedVersion == Self.targetToolVersion,
      decoded.toolContext.executableSHA256 == Self.targetExecutableSHA256
    else { throw HDCReadOnlyProbeRegistryError.invalidHeader }

    let mapped = try decoded.entries.map(Self.map)
    let candidate = HDCReadOnlyProbeRegistry(
      entries: mapped, targetExecutableSHA256: decoded.toolContext.executableSHA256)
    guard candidate == .pinnedProduction else {
      throw HDCReadOnlyProbeRegistryError.catalogMismatch
    }
    self = candidate
  }

  func entry(for family: Family) -> Entry {
    // The pinned initializer is private to this file and the decoded path
    // proves the exact four-family set, so absence is a programmer error.
    entries.first { $0.family == family }!
  }

  func disposition(
    forFamily rawFamily: String,
    observation: HDCReadOnlyProbeObservation
  ) -> HDCReadOnlyProbeDisposition {
    guard let family = Family(rawValue: rawFamily),
      let entry = entries.first(where: { $0.family == family })
    else { return .unsupported }
    guard entry.status == .supported, !observation.mutationName else { return .unsupported }
    if observation.cancelled { return .cancelled }
    if observation.timedOut { return .timedOut }
    guard observation.preconditionValid, observation.authorityPresent else {
      return .unavailable
    }
    if observation.deniedObservation { return .unknown }
    guard observation.provenanceValid, observation.effectProven,
      observation.rawFamilyKnown, observation.identityMatches, observation.bindingMatches
    else { return .unknown }
    return .observed
  }

  private static func map(_ decoded: DecodedRegistry.Entry) throws -> Entry {
    guard let family = Family(rawValue: decoded.family),
      let status = Status(rawValue: decoded.status),
      let kind = ProbeKind(rawValue: decoded.probeKind),
      decoded.platform == targetPlatform,
      decoded.toolReportedVersion == targetToolVersion,
      decoded.executableIdentityPolicy.required,
      decoded.executableIdentityPolicy.replacementInvalidatesReceipt,
      decoded.executableIdentityPolicy.sha256 == targetExecutableSHA256,
      decoded.executableIdentityPolicy.pathSource == "selectedToolchainSnapshot",
      !decoded.preconditions.isEmpty,
      !decoded.semanticMappings.isEmpty,
      !decoded.authorityLimit.neverEstablish.isEmpty,
      decoded.cancellation.mayKillHDCServer == false,
      Set(["serverStart", "serverStop", "serverRestart", "deviceMutation", "destructive"])
        .isSubset(of: Set(decoded.forbiddenEffects)),
      decoded.inputContract.receiptSHA256.count == 64,
      decoded.provenance.evidenceClass != "fakeControlOnly",
      decoded.provenance.sourcePath.hasPrefix("openspec/changes/"),
      decoded.provenance.sourceSHA256.count == 64,
      !decoded.provenance.acceptedBy.isEmpty
    else { throw HDCReadOnlyProbeRegistryError.invalidEntry(decoded.family) }

    switch status {
    case .supported:
      guard decoded.unsupportedReason == nil,
        decoded.effectClassification.hasPrefix("readOnly"),
        decoded.timeout.milliseconds > 0
      else { throw HDCReadOnlyProbeRegistryError.invalidEntry(decoded.family) }
      if kind == .hdcCommand {
        guard decoded.invocationAllowed, !decoded.exactArgv.isEmpty,
          decoded.endpointPolicy.existingServerRequired,
          decoded.endpointPolicy.serverAbsentDisposition == "unavailable"
        else { throw HDCReadOnlyProbeRegistryError.invalidEntry(decoded.family) }
      } else {
        guard !decoded.invocationAllowed, decoded.exactArgv.isEmpty else {
          throw HDCReadOnlyProbeRegistryError.invalidEntry(decoded.family)
        }
      }
    case .unsupported:
      guard !decoded.invocationAllowed, decoded.exactArgv.isEmpty,
        decoded.effectClassification == "noneUnsupported",
        decoded.timeout.milliseconds == 0,
        decoded.unsupportedReason?.isEmpty == false,
        decoded.semanticMappings.allSatisfy({ $0.result == "unsupported" })
      else { throw HDCReadOnlyProbeRegistryError.invalidEntry(decoded.family) }
    }

    return Entry(
      id: decoded.id, family: family, status: status, probeKind: kind,
      exactArguments: decoded.exactArgv, invocationAllowed: decoded.invocationAllowed,
      timeoutMilliseconds: decoded.timeout.milliseconds,
      rawFamily: decoded.inputContract.rawFamily,
      rawSHA256: decoded.inputContract.rawSHA256,
      receiptID: decoded.inputContract.receiptId,
      receiptSHA256: decoded.inputContract.receiptSHA256,
      unsupportedReason: decoded.unsupportedReason)
  }
}

enum HDCReadOnlyProbeRegistryError: Error, Equatable {
  case registryHashMismatch(expected: String, actual: String)
  case invalidHeader
  case invalidEntry(String)
  case catalogMismatch
}

enum HDCReadOnlyProbeDisposition: String, Sendable, Equatable {
  case observed
  case unavailable
  case unknown
  case timedOut
  case cancelled
  case unsupported
}

struct HDCReadOnlyProbeObservation: Sendable, Equatable {
  let provenanceValid: Bool
  let preconditionValid: Bool
  let identityMatches: Bool
  let bindingMatches: Bool
  let authorityPresent: Bool
  let rawFamilyKnown: Bool
  let deniedObservation: Bool
  let effectProven: Bool
  let cancelled: Bool
  let timedOut: Bool
  let mutationName: Bool

  static func supportedObservation(
    preconditionValid: Bool = true,
    identityMatches: Bool = true,
    bindingMatches: Bool = true,
    rawFamilyKnown: Bool = true
  ) -> Self {
    Self(
      provenanceValid: true, preconditionValid: preconditionValid,
      identityMatches: identityMatches, bindingMatches: bindingMatches,
      authorityPresent: true, rawFamilyKnown: rawFamilyKnown,
      deniedObservation: false, effectProven: true, cancelled: false,
      timedOut: false, mutationName: false)
  }
}

private struct DecodedRegistry: Decodable {
  let schemaVersion: String
  let serializationFormat: String
  let registryId: String
  let registryVersion: String
  let integrationProfile: String
  let unknownFamilyDisposition: String
  let toolContext: ToolContext
  let entries: [Entry]

  struct ToolContext: Decodable {
    let platform: String
    let reportedVersion: String
    let executableSHA256: String
  }

  struct Entry: Decodable {
    let id: String
    let family: String
    let status: String
    let probeKind: String
    let platform: String
    let toolReportedVersion: String
    let executableIdentityPolicy: ExecutableIdentityPolicy
    let exactArgv: [String]
    let invocationAllowed: Bool
    let preconditions: [String]
    let endpointPolicy: EndpointPolicy
    let effectClassification: String
    let forbiddenEffects: [String]
    let inputContract: InputContract
    let semanticMappings: [SemanticMapping]
    let authorityLimit: AuthorityLimit
    let timeout: Timeout
    let cancellation: Cancellation
    let provenance: Provenance
    let unsupportedReason: String?
  }

  struct ExecutableIdentityPolicy: Decodable {
    let required: Bool
    let sha256: String
    let pathSource: String
    let replacementInvalidatesReceipt: Bool
  }

  struct EndpointPolicy: Decodable {
    let existingServerRequired: Bool
    let serverAbsentDisposition: String
  }

  struct InputContract: Decodable {
    let rawFamily: String
    let rawSHA256: String?
    let receiptId: String
    let receiptSHA256: String
  }

  struct SemanticMapping: Decodable { let result: String }
  struct AuthorityLimit: Decodable { let neverEstablish: [String] }
  struct Timeout: Decodable { let milliseconds: Int }
  struct Cancellation: Decodable { let mayKillHDCServer: Bool }
  struct Provenance: Decodable {
    let evidenceClass: String
    let sourcePath: String
    let sourceSHA256: String
    let acceptedBy: String
  }
}

// MARK: - Registered server identity/generation observation

public struct HDCServerProcessIdentityReceipt: Sendable, Equatable {
  public let pid: Int32
  public let startSeconds: UInt64
  public let startMicroseconds: UInt64
  public let executablePath: URL
  public let executableSHA256: String
  public let endpoint: HDCServerEndpoint

  public init(
    pid: Int32,
    startSeconds: UInt64,
    startMicroseconds: UInt64,
    executablePath: URL,
    executableSHA256: String,
    endpoint: HDCServerEndpoint
  ) {
    self.pid = pid
    self.startSeconds = startSeconds
    self.startMicroseconds = startMicroseconds
    self.executablePath = executablePath
    self.executableSHA256 = executableSHA256
    self.endpoint = endpoint
  }
}

extension HDCServerProcessIdentityReceipt {
  /// Converts the commandless process start identity into the generation used
  /// by the host-wide Supervisor. A non-representable or zero value cannot be
  /// guessed into lifecycle authority.
  package var stableGeneration: Int? {
    let (seconds, secondsOverflow) = startSeconds.multipliedReportingOverflow(by: 1_000_000)
    let (microseconds, sumOverflow) = seconds.addingReportingOverflow(startMicroseconds)
    guard !secondsOverflow, !sumOverflow, microseconds > 0,
      microseconds <= UInt64(Int.max)
    else { return nil }
    return Int(microseconds)
  }
}

enum HDCServerProcessIdentityRawObservation: Sendable, Equatable {
  case observed(HDCServerProcessIdentityReceipt)
  case unavailable(reason: String)
  case unknown(reason: String)
  case timedOut
  case cancelled
}

protocol HDCServerProcessIdentityObserving: Sendable {
  func observe(
    endpoint: HDCServerEndpoint,
    selectedToolchain: HDCCandidate
  ) async -> HDCServerProcessIdentityRawObservation
}

struct SystemHDCServerProcessIdentityObserver: HDCServerProcessIdentityObserving {
  func observe(
    endpoint: HDCServerEndpoint,
    selectedToolchain: HDCCandidate
  ) async -> HDCServerProcessIdentityRawObservation {
    guard !Task.isCancelled else { return .cancelled }
    guard selectedToolchain.sha256 == HDCReadOnlyProbeRegistry.targetExecutableSHA256,
      HDCCandidateIdentityVerifier.matches(selectedToolchain)
    else { return .unknown(reason: "selected HDC executable identity does not match the registry") }

    let first = scan(endpoint: endpoint, selectedToolchain: selectedToolchain)
    guard case .observed(let firstReceipt) = first else { return first }
    guard !Task.isCancelled else { return .cancelled }
    let second = scan(endpoint: endpoint, selectedToolchain: selectedToolchain)
    guard case .observed(let secondReceipt) = second else { return second }
    guard firstReceipt == secondReceipt,
      HDCCandidateIdentityVerifier.matches(selectedToolchain)
    else { return .unknown(reason: "server process/listener identity changed during observation") }
    return .observed(secondReceipt)
  }

  private func scan(
    endpoint: HDCServerEndpoint,
    selectedToolchain: HDCCandidate
  ) -> HDCServerProcessIdentityRawObservation {
    let matches = allProcessIDs().compactMap { pid -> HDCServerProcessIdentityReceipt? in
      guard let path = executablePath(for: pid),
        path == selectedToolchain.path.resolvingSymlinksInPath().standardizedFileURL,
        ownsListeningEndpoint(endpoint, pid: pid),
        let start = startIdentity(for: pid)
      else { return nil }
      return HDCServerProcessIdentityReceipt(
        pid: pid, startSeconds: start.seconds, startMicroseconds: start.microseconds,
        executablePath: path, executableSHA256: selectedToolchain.sha256, endpoint: endpoint)
    }
    switch matches.count {
    case 0: return .unavailable(reason: "no existing selected HDC process owns the exact endpoint")
    case 1: return .observed(matches[0])
    default: return .unknown(reason: "multiple selected HDC processes own the endpoint")
    }
  }

  private func allProcessIDs() -> [Int32] {
    let estimatedCount = max(Int(proc_listallpids(nil, 0)), 64)
    var values = [pid_t](repeating: 0, count: estimatedCount + 64)
    let count = values.withUnsafeMutableBytes { bytes in
      proc_listallpids(bytes.baseAddress, Int32(bytes.count))
    }
    guard count > 0 else { return [] }
    return values.prefix(Int(count)).filter { $0 > 0 }
  }

  private func executablePath(for pid: Int32) -> URL? {
    var buffer = [CChar](repeating: 0, count: 4 * 1_024)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
      let terminator = buffer.firstIndex(of: 0)
    else { return nil }
    let path = String(
      decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
  }

  private func startIdentity(for pid: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
  }

  private func ownsListeningEndpoint(_ endpoint: HDCServerEndpoint, pid: Int32) -> Bool {
    guard let selectedPort = localIPv4Port(endpoint) else { return false }
    let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard requiredBytes > 0 else { return false }
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(),
      count: Int(requiredBytes) / MemoryLayout<proc_fdinfo>.stride + 8)
    let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard actualBytes >= MemoryLayout<proc_fdinfo>.stride else { return false }
    for descriptor in descriptors.prefix(Int(actualBytes) / MemoryLayout<proc_fdinfo>.stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var socket = socket_fdinfo()
      let socketBytes = withUnsafeMutablePointer(to: &socket) { pointer in
        proc_pidfdinfo(
          pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, pointer,
          Int32(MemoryLayout<socket_fdinfo>.size))
      }
      guard socketBytes == MemoryLayout<socket_fdinfo>.size,
        socket.psi.soi_family == AF_INET || socket.psi.soi_family == AF_INET6,
        socket.psi.soi_protocol == IPPROTO_TCP,
        socket.psi.soi_kind == SOCKINFO_TCP,
        socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
      else { continue }
      let port = UInt16(
        bigEndian: UInt16(
          truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
      if port == selectedPort, isLoopbackOrWildcardListener(socket.psi) {
        return true
      }
    }
    return false
  }

  private func isLoopbackOrWildcardListener(_ socket: socket_info) -> Bool {
    let address = socket.soi_proto.pri_tcp.tcpsi_ini.insi_laddr
    if socket.soi_family == AF_INET {
      let value = address.ina_46.i46a_addr4.s_addr
      return value == in_addr_t(INADDR_ANY) || value == inet_addr("127.0.0.1")
    }
    let bytes = withUnsafeBytes(of: address.ina_6) { Array($0) }
    let wildcard = bytes.allSatisfy { $0 == 0 }
    let mappedLoopback =
      bytes.count == 16
      && bytes[0..<10].allSatisfy { $0 == 0 }
      && bytes[10] == 0xFF && bytes[11] == 0xFF
      && Array(bytes[12..<16]) == [127, 0, 0, 1]
    return wildcard || mappedLoopback
  }

  private func localIPv4Port(_ endpoint: HDCServerEndpoint) -> UInt16? {
    guard let separator = endpoint.rawValue.lastIndex(of: ":"),
      endpoint.rawValue[..<separator] == "127.0.0.1",
      let port = UInt16(endpoint.rawValue[endpoint.rawValue.index(after: separator)...]),
      port > 0
    else { return nil }
    return port
  }
}

/// Commandless production reconciliation after a confirmed lifecycle child
/// exits. This observer has no process runner and therefore cannot start an
/// HDC server while trying to prove the effect of stop/restart.
package struct HDCRegisteredLifecyclePostDispatchProbe: Sendable {
  private let toolchain: HDCCandidate
  private let registry: HDCReadOnlyProbeRegistry
  private let identityObserver: any HDCServerProcessIdentityObserving
  private let maximumAttempts: Int
  private let timeoutMilliseconds: Int
  private let pause: @Sendable () async -> Void

  package init(toolchain: HDCCandidate) {
    let registry = HDCReadOnlyProbeRegistry.pinnedProduction
    let entry = registry.entry(for: .serverIdentityGeneration)
    let intervalMilliseconds = 50
    self.toolchain = toolchain
    self.registry = registry
    identityObserver = SystemHDCServerProcessIdentityObserver()
    maximumAttempts = max(
      1, (entry.timeoutMilliseconds + intervalMilliseconds - 1) / intervalMilliseconds)
    timeoutMilliseconds = entry.timeoutMilliseconds
    pause = {
      try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
    }
  }

  init(
    toolchain: HDCCandidate,
    registry: HDCReadOnlyProbeRegistry,
    identityObserver: any HDCServerProcessIdentityObserving,
    maximumAttempts: Int,
    pause: @escaping @Sendable () async -> Void = {}
  ) {
    self.toolchain = toolchain
    self.registry = registry
    self.identityObserver = identityObserver
    self.maximumAttempts = max(1, maximumAttempts)
    timeoutMilliseconds = registry.entry(for: .serverIdentityGeneration).timeoutMilliseconds
    self.pause = pause
  }

  package func observe(
    after step: HDCServerLifecycleStep
  ) async -> HDCServerLifecyclePostDispatchObservation? {
    let entry = registry.entry(for: .serverIdentityGeneration)
    guard entry.status == .supported, entry.probeKind == .platformProcessObservation,
      entry.exactArguments.isEmpty, !entry.invocationAllowed,
      toolchain.sha256 == registry.targetExecutableSHA256,
      HDCCandidateIdentityVerifier.matches(toolchain)
    else { return nil }

    switch step.action {
    case .restartConfirmedGeneration:
      guard step.expectedGeneration != nil else { return nil }
    case .stopConfirmedGeneration:
      break
    case .startManaged:
      return nil
    }

    return await withTaskGroup(
      of: HDCServerLifecyclePostDispatchObservation?.self,
      returning: HDCServerLifecyclePostDispatchObservation?.self
    ) { group in
      group.addTask { await poll(step: step) }
      group.addTask {
        do {
          try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
        } catch {}
        return nil
      }
      let result = await group.next() ?? nil
      group.cancelAll()
      return result
    }
  }

  private func poll(
    step: HDCServerLifecycleStep
  ) async -> HDCServerLifecyclePostDispatchObservation? {
    for attempt in 0..<maximumAttempts {
      guard !Task.isCancelled else { return nil }
      let observation = await identityObserver.observe(
        endpoint: step.endpoint, selectedToolchain: toolchain)
      switch observation {
      case .observed(let receipt):
        guard receipt.endpoint == step.endpoint,
          receipt.executableSHA256 == toolchain.sha256,
          receipt.executablePath
            == toolchain.path.resolvingSymlinksInPath().standardizedFileURL,
          let generation = receipt.stableGeneration
        else { return nil }
        if case .restartConfirmedGeneration = step.action,
          let expectedGeneration = step.expectedGeneration,
          generation > expectedGeneration
        {
          return .generation(generation)
        }
      case .unavailable:
        if case .stopConfirmedGeneration = step.action { return .unavailable }
      case .unknown, .timedOut, .cancelled:
        return nil
      }
      if attempt + 1 < maximumAttempts { await pause() }
    }
    return nil
  }
}

public enum HDCRegisteredServerObservationClassification: Sendable, Equatable {
  case observed(generation: Int, serverVersion: String)
  case unavailable(reason: String)
  case unknown(reason: String)
  case timedOut
  case cancelled
  case unsupported(reason: String)
}

public struct HDCRegisteredServerObservationResult: Sendable, Equatable {
  public let classification: HDCRegisteredServerObservationClassification
  public let identity: HDCServerProcessIdentityReceipt?
  public let execution: ProcessExecutionResult?

  public init(
    classification: HDCRegisteredServerObservationClassification,
    identity: HDCServerProcessIdentityReceipt? = nil,
    execution: ProcessExecutionResult? = nil
  ) {
    self.classification = classification
    self.identity = identity
    self.execution = execution
  }
}

// MARK: - Registered selected-device authorization family

struct HDCSelectedDeviceAuthorizationRowParser {
  struct Row: Sendable, Equatable { let connectKey: String }

  func parse(_ data: Data) -> Row? {
    guard !data.isEmpty, data.last == 0x0A,
      let value = String(data: data, encoding: .utf8),
      value.filter({ $0 == "\n" }).count == 1,
      !value.contains("\r")
    else { return nil }
    let columns = String(value.dropLast()).components(separatedBy: "\t")
    guard columns.count == 5, columns[1].isEmpty,
      columns[2] == "USB", columns[3] == "Connected", columns[4] == "localhost",
      columns[0].utf8.count == 32,
      columns[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    return Row(connectKey: columns[0])
  }

  func matches(_ row: Row, durableBinding: DurableCurrentDeviceBinding) -> Bool {
    guard durableBinding.binding.transport == .usb,
      durableBinding.binding.connectKey == row.connectKey,
      case .string(let serial)? = durableBinding.binding.identitySnapshot.attributes["serial"]
    else { return false }
    return serial == row.connectKey
  }
}

public struct HDCSelectedDeviceAuthorizationProbeResult: Sendable, Equatable {
  public let authorization: HDCAuthorizationState
  public let execution: ProcessExecutionResult?

  public init(authorization: HDCAuthorizationState, execution: ProcessExecutionResult? = nil) {
    self.authorization = authorization
    self.execution = execution
  }
}

public actor HDCSelectedDeviceAuthorizationProbe {
  private let registry: HDCReadOnlyProbeRegistry
  private let semanticProfile: HDCRegisteredSemanticProfile
  private let identityObserver: any HDCServerProcessIdentityObserving
  private let runner: HDCProcessCommandRunner
  private let additionalChildEnvironment: [String: String]

  public init() {
    registry = .pinnedProduction
    semanticProfile = .pinnedProduction
    identityObserver = SystemHDCServerProcessIdentityObserver()
    runner = HDCProcessCommandRunner(semanticProfile: semanticProfile)
    additionalChildEnvironment = [:]
  }

  init(
    registry: HDCReadOnlyProbeRegistry,
    semanticProfile: HDCRegisteredSemanticProfile,
    identityObserver: any HDCServerProcessIdentityObserving,
    runner: HDCProcessCommandRunner? = nil,
    additionalChildEnvironment: [String: String] = [:]
  ) {
    self.registry = registry
    self.semanticProfile = semanticProfile
    self.identityObserver = identityObserver
    self.runner = runner ?? HDCProcessCommandRunner(semanticProfile: semanticProfile)
    self.additionalChildEnvironment = additionalChildEnvironment
  }

  public func probe(
    endpoint: HDCServerEndpointSelection,
    toolchain: HDCCandidate,
    serverIdentity: HDCServerProcessIdentityReceipt,
    durableBinding: DurableCurrentDeviceBinding
  ) async -> HDCSelectedDeviceAuthorizationProbeResult {
    let entry = registry.entry(for: .selectedDeviceAuthorizationBinding)
    guard entry.status == .supported, entry.invocationAllowed,
      entry.exactArguments == ["list", "targets", "-v"]
    else {
      return HDCSelectedDeviceAuthorizationProbeResult(
        authorization: .unavailable(reason: "selected-device authorization family unsupported"))
    }
    guard toolchain.sha256 == registry.targetExecutableSHA256,
      semanticProfile.integrationProfile == HDCReadOnlyProbeRegistry.integrationProfile,
      semanticProfile.toolVersion == HDCReadOnlyProbeRegistry.targetToolVersion,
      semanticProfile.targetExecutableSHA256 == registry.targetExecutableSHA256,
      semanticProfile.matchesSelectedDeviceAuthorizationRawSHA256(entry.rawSHA256),
      serverIdentity.executableSHA256 == toolchain.sha256,
      serverIdentity.executablePath == toolchain.path.resolvingSymlinksInPath().standardizedFileURL,
      serverIdentity.endpoint == endpoint.endpoint
    else {
      return HDCSelectedDeviceAuthorizationProbeResult(
        authorization: .unavailable(reason: "toolchain or server identity does not match"))
    }

    let before = await identityObserver.observe(
      endpoint: endpoint.endpoint, selectedToolchain: toolchain)
    guard before == .observed(serverIdentity) else {
      return HDCSelectedDeviceAuthorizationProbeResult(
        authorization: .unavailable(reason: "server identity precondition is stale or unavailable"))
    }

    do {
      let evaluated = try await runner.execute(
        HDCProcessCommand(
          toolchain: toolchain, endpoint: endpoint, arguments: entry.exactArguments,
          additionalChildEnvironment: additionalChildEnvironment,
          timeout: TimeInterval(entry.timeoutMilliseconds) / 1_000))
      let after = await identityObserver.observe(
        endpoint: endpoint.endpoint, selectedToolchain: toolchain)
      guard after == .observed(serverIdentity) else {
        return HDCSelectedDeviceAuthorizationProbeResult(
          authorization: .unavailable(reason: "server identity changed during authorization probe"),
          execution: evaluated.execution)
      }
      if evaluated.execution.termination == .timedOut {
        return HDCSelectedDeviceAuthorizationProbeResult(
          authorization: .timedOut, execution: evaluated.execution)
      }
      if evaluated.execution.termination == .cancelled {
        return HDCSelectedDeviceAuthorizationProbeResult(
          authorization: .cancelled, execution: evaluated.execution)
      }
      let rawHash = SHA256.hash(data: evaluated.execution.stdout.data)
        .map { String(format: "%02x", $0) }
        .joined()
      let row = HDCSelectedDeviceAuthorizationRowParser().parse(evaluated.execution.stdout.data)
      let rawKnown =
        row != nil && evaluated.execution.termination == .exited(0)
        && evaluated.execution.stderr.totalByteCount == 0
        && rawHash == entry.rawSHA256
      let bindingMatches =
        row.map {
          HDCSelectedDeviceAuthorizationRowParser().matches($0, durableBinding: durableBinding)
        } ?? false
      let disposition = registry.disposition(
        forFamily: HDCReadOnlyProbeRegistry.Family.selectedDeviceAuthorizationBinding.rawValue,
        observation: .supportedObservation(
          bindingMatches: bindingMatches, rawFamilyKnown: rawKnown))
      return HDCSelectedDeviceAuthorizationProbeResult(
        authorization: disposition == .observed
          ? .ready
          : .unavailable(reason: "authorization output is unknown or does not match the binding"),
        execution: evaluated.execution)
    } catch {
      return HDCSelectedDeviceAuthorizationProbeResult(
        authorization: .unavailable(reason: "authorization probe process could not run"))
    }
  }
}
