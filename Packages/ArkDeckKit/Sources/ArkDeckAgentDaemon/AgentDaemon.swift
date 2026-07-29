// arkdeck-agentd: local device-runtime control plane (CHG-2026-047, T07).
//
// One composition root for device execution. Transport is a user-private
// Unix domain socket (0700 directory, 0600 socket, zero network listeners)
// carrying a versioned JSON line protocol; the method table is closed and
// the handler is transport-free so contract tests drive it directly.
// Single-instance: an flock'd lock plus an instance document - a second
// start returns the existing instance's info instead of competing.

import ArkDeckCore
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation

// MARK: - Wire protocol (v1)

public enum AgentWireProtocol {
  public static let version = "1.0.0"
  public static let requiredMajor = 1

  public struct Request: Codable, Sendable {
    public let protocolVersion: String
    public let id: String
    public let method: String
    public let params: [String: JSONValue]?

    public init(id: String, method: String, params: [String: JSONValue]? = nil) {
      self.protocolVersion = AgentWireProtocol.version
      self.id = id
      self.method = method
      self.params = params
    }
  }

  public struct WireError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
  }

  public struct Response: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: WireError?
  }
}

public enum AgentDaemonErrorCode: String, Sendable {
  case unsupportedProtocolVersion
  case malformedFrame
  case unknownMethod
  case invalidParams
  case rejected
  case conflict
  case notFound
  case notImplementedUntilMU3
  case internalError
}

// MARK: - Handler (transport-free)

public struct RuntimeControlPlaneHandler: Sendable {
  private let engine: RuntimeJobEngine
  private let capabilityStore: RuntimeCapabilityStore
  private let providerIDs: [String]
  private let nowUTC: @Sendable () -> String
  private let targetStore: RuntimeTargetStore?
  private let bootstrap: DeviceBootstrapMachine?
  private let artifactStore: RuntimeArtifactStore?

  public init(
    engine: RuntimeJobEngine,
    capabilityStore: RuntimeCapabilityStore,
    providerIDs: [String],
    nowUTC: @escaping @Sendable () -> String,
    targetStore: RuntimeTargetStore? = nil,
    bootstrap: DeviceBootstrapMachine? = nil,
    artifactStore: RuntimeArtifactStore? = nil
  ) {
    self.engine = engine
    self.capabilityStore = capabilityStore
    self.providerIDs = providerIDs
    self.nowUTC = nowUTC
    self.targetStore = targetStore
    self.bootstrap = bootstrap
    self.artifactStore = artifactStore
  }

  public func handleLine(_ line: Data) async -> Data {
    let response = await handleFrame(line)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = (try? encoder.encode(response)) ?? Data("{}".utf8)
    return payload + Data("\n".utf8)
  }

  func handleFrame(_ line: Data) async -> AgentWireProtocol.Response {
    let request: AgentWireProtocol.Request
    do {
      request = try JSONDecoder().decode(AgentWireProtocol.Request.self, from: line)
    } catch {
      return failure(id: "-", code: .malformedFrame, message: "undecodable request frame")
    }
    let majorText = request.protocolVersion.split(separator: ".").first.map(String.init) ?? ""
    guard Int(majorText) == AgentWireProtocol.requiredMajor else {
      return failure(
        id: request.id, code: .unsupportedProtocolVersion,
        message: "this daemon speaks protocol major \(AgentWireProtocol.requiredMajor)")
    }
    return await dispatch(request)
  }

  private func dispatch(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    switch request.method {
    case "health":
      return success(
        id: request.id,
        result: .object([
          "status": .string("ok"),
          "protocolVersion": .string(AgentWireProtocol.version),
          "catalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
          "providers": .array(providerIDs.map(JSONValue.string)),
        ]))

    case "operation.list":
      let references = RuntimeOperationCatalog.operations.map(\.reference).sorted()
      return success(id: request.id, result: .array(references.map(JSONValue.string)))

    case "operation.describe":
      guard case .string(let reference)? = request.params?["reference"],
        let descriptor = RuntimeOperationCatalog.descriptor(reference: reference)
      else {
        return failure(id: request.id, code: .notFound, message: "unknown operation reference")
      }
      return success(
        id: request.id,
        result: .object([
          "reference": .string(descriptor.reference),
          "title": .string(descriptor.title),
          "provider": .string(descriptor.provider.rawValue),
          "minimumEffect": .string(descriptor.minimumEffect.rawValue),
          "binding": .string(descriptor.binding.rawValue),
          "timeoutSeconds": .integer(Int64(descriptor.timeoutSeconds)),
          "stepCount": .integer(Int64(descriptor.steps.count)),
        ]))

    case "capability.list":
      do {
        let statuses = try await capabilityStore.list()
        return success(
          id: request.id,
          result: .array(
            statuses.map { status in
              .object([
                "capabilityId": .string(status.capability.capabilityID),
                "effectCeiling": .string(status.capability.effectCeiling.rawValue),
                "remainingUses": .integer(Int64(status.remainingUses)),
              ])
            }))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "capability.install":
      guard case .string(let json)? = request.params?["capabilityJson"] else {
        return failure(id: request.id, code: .invalidParams, message: "capabilityJson is required")
      }
      do {
        let capability = try JSONDecoder().decode(
          RuntimeCapability.self, from: Data(json.utf8))
        try await capabilityStore.install(capability)
        return success(id: request.id, result: .object(["installed": .bool(true)]))
      } catch let error as RuntimeCapabilityStoreError {
        return failure(id: request.id, code: .conflict, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .invalidParams, message: "invalid capability: \(error)")
      }

    case "capability.revoke":
      guard case .string(let capabilityID)? = request.params?["capabilityId"] else {
        return failure(id: request.id, code: .invalidParams, message: "capabilityId is required")
      }
      do {
        try await capabilityStore.revoke(
          capabilityID: capabilityID, atUTC: nowUTC(), reason: "revoked via control plane")
        return success(id: request.id, result: .object(["revoked": .bool(true)]))
      } catch let error as RuntimeCapabilityStoreError {
        return failure(id: request.id, code: .notFound, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.submit":
      guard case .string(let requestJson)? = request.params?["requestJson"] else {
        return failure(id: request.id, code: .invalidParams, message: "requestJson is required")
      }
      do {
        let acceptance = try await engine.submit(Data(requestJson.utf8))
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(acceptance.jobID),
            "deduplicated": .bool(acceptance.deduplicated),
          ]))
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.run":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let status = try await engine.run(jobID: jobID)
        return success(id: request.id, result: Self.encodeStatus(status))
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.list":
      let statuses = await engine.listJobs()
      return success(id: request.id, result: .array(statuses.map(Self.encodeStatus)))

    case "job.status":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let status = try await engine.status(jobID: jobID)
        return success(id: request.id, result: Self.encodeStatus(status))
      } catch {
        return failure(id: request.id, code: .notFound, message: "unknown job \(jobID)")
      }

    case "job.cancel":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        try await engine.requestCancel(jobID: jobID)
        return success(id: request.id, result: .object(["cancelRequested": .bool(true)]))
      } catch {
        return failure(id: request.id, code: .notFound, message: "unknown job \(jobID)")
      }

    case "job.reconcile":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let status = try await engine.reconcile(jobID: jobID)
        return success(id: request.id, result: Self.encodeStatus(status))
      } catch {
        return failure(id: request.id, code: .notFound, message: "unknown job \(jobID)")
      }

    case "doctor":
      var report: [String: JSONValue] = [
        "protocolVersion": .string(AgentWireProtocol.version),
        "catalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
        "providers": .array(providerIDs.map(JSONValue.string)),
        "targetStore": .string(targetStore == nil ? "unavailable" : "ready"),
        "bootstrap": .string(bootstrap == nil ? "unavailable" : "ready"),
      ]
      if let targetStore, let targets = try? targetStore.list() {
        report["adoptedTargetCount"] = .integer(Int64(targets.count))
      }
      return success(id: request.id, result: .object(report))

    case "artifact.list":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let artifacts = try await artifactStore.list(jobID: jobID)
        return success(
          id: request.id,
          result: .array(artifacts.map(Self.encodeArtifact)))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.inspect":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"],
        case .string(let artifactID)? = request.params?["artifactId"]
      else {
        return failure(
          id: request.id, code: .invalidParams, message: "jobId and artifactId are required")
      }
      do {
        let metadata = try await artifactStore.inspect(jobID: jobID, artifactID: artifactID)
        return success(id: request.id, result: Self.encodeArtifact(metadata))
      } catch {
        return failure(id: request.id, code: .notFound, message: "\(error)")
      }

    case "artifact.read":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"],
        case .string(let artifactID)? = request.params?["artifactId"]
      else {
        return failure(
          id: request.id, code: .invalidParams, message: "jobId and artifactId are required")
      }
      var maximumBytes = 1 << 20
      if case .integer(let requested)? = request.params?["maxBytes"] {
        maximumBytes = max(1, min(Int(requested), 1 << 22))
      }
      var allowSensitive = false
      if case .bool(let flag)? = request.params?["allowSensitive"] { allowSensitive = flag }
      do {
        let data = try await artifactStore.read(
          jobID: jobID, artifactID: artifactID, maximumBytes: maximumBytes,
          allowSensitive: allowSensitive)
        return success(
          id: request.id,
          result: .object([
            "artifactId": .string(artifactID),
            "byteCount": .integer(Int64(data.count)),
            "base64": .string(data.base64EncodedString()),
          ]))
      } catch let error as RuntimeArtifactError {
        if case .sensitiveAccessRequiresOptIn = error {
          return failure(
            id: request.id, code: .rejected,
            message: "artifact is sensitive; pass allowSensitive to read it")
        }
        return failure(id: request.id, code: .notFound, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "target.list":
      guard let targetStore else {
        return failure(
          id: request.id, code: .internalError, message: "target store is not configured")
      }
      do {
        let targets = try targetStore.list()
        return success(
          id: request.id,
          result: .array(
            targets.map { record in
              .object([
                "targetId": .string(record.targetID),
                "bindingRevision": .integer(Int64(record.bindingRevision)),
                "toolVersion": .string(record.toolVersion),
                "adoptedAtUtc": .string(record.adoptedAtUTC),
              ])
            }))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "target.adopt":
      guard let bootstrap else {
        return failure(
          id: request.id, code: .internalError,
          message: "bootstrap is not configured in this composition")
      }
      var selected: String?
      if case .string(let candidate)? = request.params?["candidate"] {
        selected = candidate
      }
      switch await bootstrap.advance(selectedConnectKey: selected) {
      case .adopted(let record):
        return success(
          id: request.id,
          result: .object([
            "outcome": .string("adopted"),
            "targetId": .string(record.targetID),
            "bindingRevision": .integer(Int64(record.bindingRevision)),
          ]))
      case .needsSelection(let candidates):
        return success(
          id: request.id,
          result: .object([
            "outcome": .string("needsSelection"),
            "candidates": .array(
              candidates.map {
                .object(["candidate": .string($0.connectKey), "state": .string($0.state)])
              }),
          ]))
      case .waitingForHuman(let prompt):
        return success(
          id: request.id,
          result: .object([
            "outcome": .string("waitingForHuman"), "prompt": .string(prompt),
          ]))
      case .failed(let reason):
        return failure(id: request.id, code: .rejected, message: reason)
      }

    default:
      return failure(
        id: request.id, code: .unknownMethod, message: "unknown method \(request.method)")
    }
  }

  private static func encodeArtifact(_ metadata: RuntimeArtifactMetadata) -> JSONValue {
    var status = "published"
    var detail: JSONValue = .null
    switch metadata.status {
    case .published: break
    case .missing(let reason):
      status = "missing"
      detail = .string(reason)
    case .truncated(let atBytes):
      status = "truncated"
      detail = .integer(Int64(atBytes))
    }
    return .object([
      "artifactId": .string(metadata.artifactID),
      "name": .string(metadata.name),
      "mediaType": .string(metadata.mediaType),
      "byteCount": .integer(Int64(metadata.byteCount)),
      "sha256": .string(metadata.sha256),
      "privacy": .string(metadata.privacy.rawValue),
      "status": .string(status),
      "statusDetail": detail,
      "sourceOperation": .string(metadata.sourceOperation),
      "createdAtUtc": .string(metadata.createdAtUTC),
      "redactionApplied": .bool(metadata.redactionApplied),
    ])
  }

  private static func encodeStatus(_ status: RuntimeJobStatus) -> JSONValue {
    .object([
      "jobId": .string(status.jobID),
      "operation": .string(status.operationReference),
      "targetId": .string(status.targetID),
      "state": .string(status.state),
      "waitingForHuman": .bool(status.waitingForHuman),
      "outcomeUnknown": .bool(status.outcomeUnknown),
      "timeline": .array(status.timeline.map(JSONValue.string)),
    ])
  }

  private func success(id: String, result: JSONValue) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(id: id, ok: true, result: result, error: nil)
  }

  private func failure(
    id: String, code: AgentDaemonErrorCode, message: String
  ) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(
      id: id, ok: false, result: nil,
      error: AgentWireProtocol.WireError(code: code.rawValue, message: message))
  }
}

// MARK: - Instance document

public struct AgentDaemonInstance: Codable, Sendable, Equatable {
  public let pid: Int32
  public let socketPath: String
  public let protocolVersion: String
  public let startedAtUTC: String
}

public enum AgentDaemonStartResult: Sendable, Equatable {
  case started
  case alreadyRunning(AgentDaemonInstance)
}

// MARK: - UDS server

public final class AgentDaemonServer: @unchecked Sendable {
  public let stateDirectory: URL
  public let socketURL: URL
  private let handler: RuntimeControlPlaneHandler
  private let nowUTC: @Sendable () -> String
  private var listenerFD: Int32 = -1
  private var lockFD: Int32 = -1
  private var acceptThread: Thread?
  private let stopFlag = NSLock()
  private var stopped = false

  public init(
    stateDirectory: URL,
    handler: RuntimeControlPlaneHandler,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.stateDirectory = stateDirectory
    self.socketURL = stateDirectory.appendingPathComponent("agentd.sock")
    self.handler = handler
    self.nowUTC = nowUTC
  }

  public func start() throws -> AgentDaemonStartResult {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    let lockURL = stateDirectory.appendingPathComponent("instance.lock")
    let instanceURL = stateDirectory.appendingPathComponent("instance.json")
    lockFD = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else { throw AgentDaemonError.io("cannot open instance lock") }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
      close(lockFD)
      lockFD = -1
      if let data = try? Data(contentsOf: instanceURL),
        let instance = try? JSONDecoder().decode(AgentDaemonInstance.self, from: data)
      {
        return .alreadyRunning(instance)
      }
      throw AgentDaemonError.io("another instance holds the lock but left no instance document")
    }

    unlink(socketURL.path)
    listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerFD >= 0 else { throw AgentDaemonError.io("cannot create socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketURL.path
    // sun_path is 104 bytes on Darwin: a deep state directory silently
    // becomes an unusable socket, so say exactly what to do about it.
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw AgentDaemonError.io(
        "socket path is \(path.utf8.count) bytes but the platform limit is "
          + "\(MemoryLayout.size(ofValue: address.sun_path) - 1); "
          + "choose a shorter --state-dir (the socket is <state-dir>/agentd.sock)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      path.utf8CString.withUnsafeBytes { source in
        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count)))
      }
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(listenerFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else { throw AgentDaemonError.io("bind failed: errno \(errno)") }
    guard chmod(socketURL.path, 0o600) == 0 else {
      throw AgentDaemonError.io("cannot restrict socket permissions")
    }
    guard listen(listenerFD, 16) == 0 else { throw AgentDaemonError.io("listen failed") }

    let instance = AgentDaemonInstance(
      pid: getpid(), socketPath: socketURL.path,
      protocolVersion: AgentWireProtocol.version, startedAtUTC: nowUTC())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try (try encoder.encode(instance)).write(to: instanceURL, options: [])

    let thread = Thread { [weak self] in self?.acceptLoop() }
    thread.name = "arkdeck-agentd-accept"
    thread.start()
    acceptThread = thread
    return .started
  }

  public func stop() {
    stopFlag.lock()
    stopped = true
    stopFlag.unlock()
    if listenerFD >= 0 {
      close(listenerFD)
      listenerFD = -1
    }
    unlink(socketURL.path)
    if lockFD >= 0 {
      flock(lockFD, LOCK_UN)
      close(lockFD)
      lockFD = -1
    }
  }

  private var isStopped: Bool {
    stopFlag.lock()
    defer { stopFlag.unlock() }
    return stopped
  }

  private func acceptLoop() {
    while !isStopped {
      let connectionFD = accept(listenerFD, nil, nil)
      guard connectionFD >= 0 else {
        if isStopped { return }
        continue
      }
      let handler = self.handler
      Task.detached {
        await Self.serve(connectionFD: connectionFD, handler: handler)
      }
    }
  }

  private static func serve(connectionFD: Int32, handler: RuntimeControlPlaneHandler) async {
    defer { close(connectionFD) }
    var buffer = Data()
    let chunkSize = 64 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let count = read(connectionFD, &chunk, chunkSize)
      if count <= 0 { return }
      buffer.append(contentsOf: chunk[0..<count])
      if buffer.count > 4 * 1024 * 1024 { return }  // frame bomb guard
      while let newlineIndex = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        guard !line.isEmpty else { continue }
        let response = await handler.handleLine(line)
        var written = 0
        let total = response.count
        let sent: Bool = response.withUnsafeBytes { raw in
          guard let base = raw.baseAddress else { return false }
          while written < total {
            let result = write(connectionFD, base + written, total - written)
            if result <= 0 { return false }
            written += result
          }
          return true
        }
        if !sent { return }
      }
    }
  }
}

public enum AgentDaemonError: Error, Equatable, Sendable {
  case io(String)
}
