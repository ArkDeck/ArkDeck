import Darwin
import Foundation

/// Closed Sources-side adoption of
/// `OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0`.
///
/// The family is commandless: it can only mint a generation from the exact
/// selected 3.2.0f executable, endpoint, process, start identity, and listener
/// observed by the platform adapter. It carries no health or version
/// authority and has no fallback to the 3.2.0d read-only registry.
package enum HDCSupervisorObservationProbeCatalog {
  package static let registryID =
    "OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES"
  package static let registryVersion = "1.0.0"
  package static let integrationProfile = "OPENHARMONY-TOOLS@0.6.0"
  package static let entryID =
    "openharmony-hdc-supervisor-identity-generation-3.2.0f-macos"
  package static let family = "serverIdentityGeneration"
  package static let targetToolVersion = "3.2.0f"
  package static let targetExecutableSHA256 =
    "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
  package static let exactEndpoint = "127.0.0.1:8710"
  package static let exactArguments: [String] = []
  package static let invocationAllowed = false
  package static let timeoutMilliseconds = 1_000
}

package enum HDCSupervisorObservationClassification: Sendable, Equatable {
  case observed(generation: Int)
  case unavailable(reason: String)
  case unknown(reason: String)
  case timedOut
  case cancelled
  case unsupported(reason: String)
}

package struct HDCSupervisorObservationResult: Sendable, Equatable {
  package let classification: HDCSupervisorObservationClassification
  package let identity: HDCServerProcessIdentityReceipt?

  package init(
    classification: HDCSupervisorObservationClassification,
    identity: HDCServerProcessIdentityReceipt? = nil
  ) {
    self.classification = classification
    self.identity = identity
  }
}

/// The production factory accepts only the already-selected candidate,
/// endpoint, and host-wide supervisor. The registry and system observer are
/// constructed here, so Workflows/App callers cannot provide a receipt,
/// generation, process/socket list, runner, or alternate authority.
package actor HDCSupervisorObservationApplicationSession {
  private let supervisor: HDCServerSupervisor
  private let toolchain: HDCCandidate
  private let endpointSelection: HDCServerEndpointSelection
  private let identityObserver: any HDCServerProcessIdentityObserving
  private let timeoutMilliseconds: Int

  package static func makeProduction(
    supervisor: HDCServerSupervisor,
    toolchain: HDCCandidate,
    endpointSelection: HDCServerEndpointSelection
  ) -> HDCSupervisorObservationApplicationSession {
    HDCSupervisorObservationApplicationSession(
      supervisor: supervisor,
      toolchain: toolchain,
      endpointSelection: endpointSelection,
      identityObserver:
        HDCExact320FSystemIdentityObserver.supervisorObservationProduction,
      timeoutMilliseconds: HDCSupervisorObservationProbeCatalog.timeoutMilliseconds)
  }

  /// Contract-only seam. It is module-internal and cannot be referenced by
  /// ArkDeckWorkflows or the App production composition root.
  static func makeContract(
    supervisor: HDCServerSupervisor,
    toolchain: HDCCandidate,
    endpointSelection: HDCServerEndpointSelection,
    identityObserver: any HDCServerProcessIdentityObserving,
    timeoutMilliseconds: Int = HDCSupervisorObservationProbeCatalog.timeoutMilliseconds
  ) -> HDCSupervisorObservationApplicationSession {
    HDCSupervisorObservationApplicationSession(
      supervisor: supervisor,
      toolchain: toolchain,
      endpointSelection: endpointSelection,
      identityObserver: identityObserver,
      timeoutMilliseconds: timeoutMilliseconds)
  }

  private init(
    supervisor: HDCServerSupervisor,
    toolchain: HDCCandidate,
    endpointSelection: HDCServerEndpointSelection,
    identityObserver: any HDCServerProcessIdentityObserving,
    timeoutMilliseconds: Int
  ) {
    self.supervisor = supervisor
    self.toolchain = toolchain
    self.endpointSelection = endpointSelection
    self.identityObserver = identityObserver
    self.timeoutMilliseconds = max(1, timeoutMilliseconds)
  }

  @discardableResult
  package func observe() async -> HDCSupervisorObservationResult {
    guard HDCSupervisorObservationProbeCatalog.exactArguments.isEmpty,
      !HDCSupervisorObservationProbeCatalog.invocationAllowed
    else {
      return await fail(
        .unsupported(reason: "supervisor identity family is not commandless"),
        reason: "supervisor identity family is not commandless")
    }
    guard
      toolchain.sha256 == HDCSupervisorObservationProbeCatalog.targetExecutableSHA256
    else {
      return await fail(
        .unsupported(
          reason: "selected executable is outside OPENHARMONY-TOOLS@0.6.0"),
        reason: "selected executable is outside OPENHARMONY-TOOLS@0.6.0")
    }
    guard
      endpointSelection.endpoint.rawValue
        == HDCSupervisorObservationProbeCatalog.exactEndpoint
    else {
      return await fail(
        .unsupported(reason: "selected endpoint is outside the supervisor registry"),
        reason: "selected endpoint is outside the supervisor registry")
    }

    let observation = await observeIdentity()
    guard case .observed(let receipt) = observation else {
      switch observation {
      case .observed:
        return await fail(
          .unknown(reason: "unexpected supervisor identity state"),
          reason: "unexpected supervisor identity state")
      case .unavailable(let reason):
        return await fail(.unavailable(reason: reason), reason: reason)
      case .unknown(let reason):
        return await fail(.unknown(reason: reason), reason: reason)
      case .timedOut:
        return await fail(
          .timedOut, reason: "supervisor identity observation timed out")
      case .cancelled:
        return await fail(
          .cancelled, reason: "supervisor identity observation was cancelled")
      }
    }

    let expectedPath = toolchain.path.resolvingSymlinksInPath().standardizedFileURL
    guard receipt.pid > 0,
      receipt.startMicroseconds < 1_000_000,
      receipt.endpoint == endpointSelection.endpoint,
      receipt.executablePath == expectedPath,
      receipt.executableSHA256 == toolchain.sha256
    else {
      return await fail(
        .unknown(reason: "observer receipt does not match the selected candidate and endpoint"),
        reason: "observer receipt does not match the selected candidate and endpoint")
    }
    guard let generation = receipt.stableGeneration else {
      return await fail(
        .unknown(reason: "observed process start identity cannot represent a generation"),
        reason: "observed process start identity cannot represent a generation")
    }

    await supervisor.observeRegisteredServerIdentity(
      endpoint: endpointSelection.endpoint,
      health: .unknown,
      version: .unknown(
        reason: "OPENHARMONY-TOOLS@0.6.0 has no registered HDC health or version source"),
      generation: generation,
      reason:
        "OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0 commandless identity observation")
    return HDCSupervisorObservationResult(
      classification: .observed(generation: generation),
      identity: receipt)
  }

  private func observeIdentity() async -> HDCServerProcessIdentityRawObservation {
    await withTaskGroup(of: HDCServerProcessIdentityRawObservation.self) { group in
      group.addTask {
        await self.identityObserver.observe(
          endpoint: self.endpointSelection.endpoint,
          selectedToolchain: self.toolchain)
      }
      group.addTask {
        do {
          try await Task.sleep(for: .milliseconds(self.timeoutMilliseconds))
          return .timedOut
        } catch {
          return .cancelled
        }
      }
      let result =
        await group.next()
        ?? .unknown(reason: "supervisor identity observation produced no result")
      group.cancelAll()
      return result
    }
  }

  private func fail(
    _ classification: HDCSupervisorObservationClassification,
    reason: String
  ) async -> HDCSupervisorObservationResult {
    await supervisor.recordUnverifiedServerProbeFailure(
      endpoint: endpointSelection.endpoint, reason: reason)
    return HDCSupervisorObservationResult(classification: classification)
  }
}

/// Shared exact-3.2.0f production observer used by both supervisor identity
/// bootstrap and device observation. Its listener policy admits only the
/// registered IPv4 loopback spelling or the macOS IPv4-mapped IPv6 equivalent;
/// wildcard and port-only matches never establish a receipt.
struct HDCExact320FSystemIdentityObserver: HDCServerProcessIdentityObserving {
  static let supervisorObservationProduction =
    HDCExact320FSystemIdentityObserver(
      exactEndpoint: HDCSupervisorObservationProbeCatalog.exactEndpoint,
      targetExecutableSHA256:
        HDCSupervisorObservationProbeCatalog.targetExecutableSHA256)

  static let deviceObservationProduction =
    HDCExact320FSystemIdentityObserver(
      exactEndpoint: HDCDeviceObservationProbeCatalog.exactEndpoint,
      targetExecutableSHA256:
        HDCDeviceObservationProbeCatalog.targetExecutableSHA256)

  private let exactEndpoint: String
  private let targetExecutableSHA256: String

  private init(exactEndpoint: String, targetExecutableSHA256: String) {
    self.exactEndpoint = exactEndpoint
    self.targetExecutableSHA256 = targetExecutableSHA256
  }

  func observe(
    endpoint: HDCServerEndpoint,
    selectedToolchain: HDCCandidate
  ) async -> HDCServerProcessIdentityRawObservation {
    guard !Task.isCancelled else { return .cancelled }
    guard endpoint.rawValue == exactEndpoint,
      selectedToolchain.sha256 == targetExecutableSHA256,
      HDCCandidateIdentityVerifier.matches(selectedToolchain)
    else {
      return .unknown(
        reason: "selected HDC executable or endpoint does not match the exact 3.2.0f registry")
    }

    let first = scan(endpoint: endpoint, selectedToolchain: selectedToolchain)
    guard case .observed(let firstReceipt) = first else { return first }
    guard !Task.isCancelled else { return .cancelled }
    let second = scan(endpoint: endpoint, selectedToolchain: selectedToolchain)
    guard case .observed(let secondReceipt) = second else { return second }
    guard firstReceipt == secondReceipt,
      HDCCandidateIdentityVerifier.matches(selectedToolchain)
    else {
      return .unknown(reason: "server process/listener identity changed during observation")
    }
    return .observed(secondReceipt)
  }

  private func scan(
    endpoint: HDCServerEndpoint,
    selectedToolchain: HDCCandidate
  ) -> HDCServerProcessIdentityRawObservation {
    guard let processIDs = allProcessIDs() else {
      return .unknown(reason: "macOS process scan failed")
    }
    var matches: [HDCServerProcessIdentityReceipt] = []
    let expectedPath = selectedToolchain.path.resolvingSymlinksInPath().standardizedFileURL
    for pid in processIDs {
      guard let path = executablePath(for: pid), path == expectedPath else { continue }
      let listenerCount: Int
      switch registeredListeningEndpointCount(endpoint, pid: pid) {
      case .count(let count):
        listenerCount = count
      case .unregisteredAddress:
        return .unknown(
          reason: "selected HDC process owns an unregistered listener address")
      case .failed:
        return .unknown(reason: "macOS socket scan failed for the selected HDC process")
      }
      guard listenerCount <= 1 else {
        return .unknown(reason: "multiple registered listeners belong to the selected HDC process")
      }
      guard listenerCount == 1, let start = startIdentity(for: pid) else { continue }
      matches.append(
        HDCServerProcessIdentityReceipt(
          pid: pid,
          startSeconds: start.seconds,
          startMicroseconds: start.microseconds,
          executablePath: path,
          executableSHA256: selectedToolchain.sha256,
          endpoint: endpoint))
    }
    switch matches.count {
    case 0:
      return .unavailable(reason: "no existing selected HDC process owns the exact endpoint")
    case 1:
      return .observed(matches[0])
    default:
      return .unknown(reason: "multiple selected HDC processes own the endpoint")
    }
  }

  private func allProcessIDs() -> [Int32]? {
    let estimatedCount = max(Int(proc_listallpids(nil, 0)), 64)
    var values = [pid_t](repeating: 0, count: estimatedCount + 64)
    let count = values.withUnsafeMutableBytes { bytes in
      proc_listallpids(bytes.baseAddress, Int32(bytes.count))
    }
    guard count > 0 else { return nil }
    return values.prefix(Int(count)).filter { $0 > 0 }
  }

  private func executablePath(for pid: Int32) -> URL? {
    var buffer = [CChar](repeating: 0, count: 4 * 1_024)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
      let terminator = buffer.firstIndex(of: 0)
    else { return nil }
    let path = String(
      decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
      as: UTF8.self)
    return URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
  }

  private func startIdentity(for pid: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
  }

  private func registeredListeningEndpointCount(
    _ endpoint: HDCServerEndpoint,
    pid: Int32
  ) -> RegisteredListenerScanResult {
    guard let selectedPort = localIPv4Port(endpoint) else { return .failed }
    let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard requiredBytes > 0 else { return .failed }
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(),
      count: Int(requiredBytes) / MemoryLayout<proc_fdinfo>.stride + 8)
    let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard actualBytes >= MemoryLayout<proc_fdinfo>.stride else { return .failed }
    var matches = 0
    for descriptor in descriptors.prefix(Int(actualBytes) / MemoryLayout<proc_fdinfo>.stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var socket = socket_fdinfo()
      let socketBytes = withUnsafeMutablePointer(to: &socket) { pointer in
        proc_pidfdinfo(
          pid,
          descriptor.proc_fd,
          PROC_PIDFDSOCKETINFO,
          pointer,
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
      guard port == selectedPort else { continue }
      // Decode the address the way the kernel labels it (`insi_vflag`), not
      // by the socket family: real hdc 3.2.0f listens through a dual-stack
      // AF_INET6 socket whose local address is the plain IPv4 loopback.
      guard let local = HDCListenerAddressFacts.localAddress(socket.psi) else {
        return .unregisteredAddress
      }
      if Self.isRegisteredListenerAddress(family: local.family, addressBytes: local.bytes) {
        matches += 1
      } else {
        return .unregisteredAddress
      }
    }
    return .count(matches)
  }

  static func isRegisteredListenerAddress(
    family: Int32,
    addressBytes: [UInt8]
  ) -> Bool {
    if family == AF_INET {
      return addressBytes == [127, 0, 0, 1]
    }
    guard family == AF_INET6, addressBytes.count == 16 else { return false }
    return addressBytes[0..<10].allSatisfy { $0 == 0 }
      && addressBytes[10] == 0xFF
      && addressBytes[11] == 0xFF
      && Array(addressBytes[12..<16]) == [127, 0, 0, 1]
  }

  private func localIPv4Port(_ endpoint: HDCServerEndpoint) -> UInt16? {
    guard let separator = endpoint.rawValue.lastIndex(of: ":"),
      endpoint.rawValue[..<separator] == "127.0.0.1",
      let port = UInt16(endpoint.rawValue[endpoint.rawValue.index(after: separator)...]),
      port > 0
    else { return nil }
    return port
  }

  private enum RegisteredListenerScanResult {
    case count(Int)
    case unregisteredAddress
    case failed
  }
}
