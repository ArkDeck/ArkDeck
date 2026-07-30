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
  /// Absent means the harness plane is not configured in this composition;
  /// `task.*` then fails closed instead of half-existing.
  let harnessCoordinator: HarnessTaskCoordinator?
  private let hapImports: HAPArtifactImportCoordinator
  private let nativeLibraryImports: NativeLibraryArtifactImportCoordinator
  /// Test seam: records which methods a client invoked. Production passes
  /// nil, so this cannot affect behaviour.
  private let methodObserver: (@Sendable (String) -> Void)?

  public init(
    engine: RuntimeJobEngine,
    capabilityStore: RuntimeCapabilityStore,
    providerIDs: [String],
    nowUTC: @escaping @Sendable () -> String,
    targetStore: RuntimeTargetStore? = nil,
    bootstrap: DeviceBootstrapMachine? = nil,
    artifactStore: RuntimeArtifactStore? = nil,
    harnessCoordinator: HarnessTaskCoordinator? = nil,
    methodObserver: (@Sendable (String) -> Void)? = nil
  ) {
    self.engine = engine
    self.capabilityStore = capabilityStore
    self.providerIDs = providerIDs
    self.nowUTC = nowUTC
    self.targetStore = targetStore
    self.bootstrap = bootstrap
    self.artifactStore = artifactStore
    self.harnessCoordinator = harnessCoordinator
    self.hapImports = HAPArtifactImportCoordinator()
    self.nativeLibraryImports = NativeLibraryArtifactImportCoordinator()
    self.methodObserver = methodObserver
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
    methodObserver?(request.method)
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
      let availability = await engine.operationAvailability()
      return success(
        id: request.id,
        result: .array(
          availability.map { item in
            .object([
              "reference": .string(item.reference),
              "availability": .string(item.state.rawValue),
              "reasons": .array(item.reasons.map(JSONValue.string)),
            ])
          }))

    case "operation.describe":
      guard case .string(let reference)? = request.params?["reference"],
        let descriptor = RuntimeOperationCatalog.descriptor(reference: reference)
      else {
        return failure(id: request.id, code: .notFound, message: "unknown operation reference")
      }
      let availability = await engine.operationAvailability()
        .first { $0.reference == descriptor.reference }
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
          "availability": .string(availability?.state.rawValue ?? "unavailable"),
          "availabilityReasons": .array(
            (availability?.reasons ?? ["runtime availability could not be resolved"])
              .map(JSONValue.string)),
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
                "maximumUses": .integer(Int64(status.capability.maximumUses)),
                "remainingUses": .integer(Int64(status.remainingUses)),
                "consumptionCount": .integer(Int64(status.consumptionCount)),
                "lineageAllowsNewExecution": .bool(status.lineageAllowsNewExecution),
                "lineageBlocker": status.lineageBlocker.map(JSONValue.string) ?? .null,
              ])
            }))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "capability.inspect":
      guard case .string(let capabilityID)? = request.params?["capabilityId"] else {
        return failure(id: request.id, code: .invalidParams, message: "capabilityId is required")
      }
      do {
        guard let status = try await capabilityStore.inspect(capabilityID: capabilityID) else {
          return failure(id: request.id, code: .notFound, message: "unknown capability")
        }
        let encoded = try JSONEncoder().encode(status)
        let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
        return success(id: request.id, result: json)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "capability.draft":
      guard case .string(let requestJson)? = request.params?["requestJson"] else {
        return failure(id: request.id, code: .invalidParams, message: "requestJson is required")
      }
      let validitySeconds: Int
      if case .integer(let raw)? = request.params?["validitySeconds"],
        let exact = Int(exactly: raw)
      {
        validitySeconds = exact
      } else {
        validitySeconds = 3_600
      }
      guard (300...86_400).contains(validitySeconds) else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "validitySeconds must be between 300 and 86400")
      }
      let maximumUses: Int
      if case .integer(let raw)? = request.params?["maximumUses"],
        let exact = Int(exactly: raw)
      {
        maximumUses = exact
      } else {
        maximumUses = 1
      }
      guard (1...32).contains(maximumUses) else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "maximumUses must be between 1 and 32")
      }
      let issuedAt = nowUTC()
      guard let expiresAt = Self.addingUTCSeconds(validitySeconds, to: issuedAt) else {
        return failure(
          id: request.id, code: .internalError,
          message: "daemon clock cannot produce a fixed-format UTC capability window")
      }
      do {
        let draft = try await engine.draftCapability(
          Data(requestJson.utf8),
          issuedAtUTC: issuedAt,
          expiresAtUTC: expiresAt,
          issuerReference: "PENDING-MAINTAINER-PR",
          maximumUses: maximumUses)
        let encoded = try JSONEncoder().encode(draft)
        let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
        return success(id: request.id, result: json)
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
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
        guard Self.isMergedPRIssuerReference(capability.issuer.reference) else {
          return failure(
            id: request.id, code: .invalidParams,
            message:
              "capability draft is not installable until issuer.reference names "
              + "a maintainer-merged PR")
        }
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

    case "job.evidence":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let snapshot = try await engine.evidenceSnapshot(jobID: jobID)
        var artifacts: [RuntimeVerifiedArtifactEvidence] = []
        var blockers: [String] = []
        if let artifactStore {
          do {
            let omitted = try await engine.intentionallyOmittedArtifactNames(jobID: jobID)
            artifacts = try await artifactStore.verifiedEvidenceArtifacts(
              jobID: jobID, intentionallyOmittedNames: omitted)
          } catch {
            blockers.append("artifactVerification:\(error)")
          }
        } else {
          blockers.append("artifactStoreUnavailable")
        }
        return success(
          id: request.id,
          result: Self.encodeEvidence(
            snapshot: snapshot, artifacts: artifacts, blockers: blockers))
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

    case "cleanupDebt.list":
      do {
        let debts = try await engine.listCleanupDebt()
        return success(
          id: request.id,
          result: .array(debts.map(Self.encodeCleanupDebt)))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "cleanupDebt.continue":
      guard case .string(let jobID)? = request.params?["jobId"],
        case .string(let remotePath)? = request.params?["remotePath"]
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "jobId and remotePath are required")
      }
      do {
        let result = try await engine.continueCleanupDebt(
          jobID: jobID, remotePath: remotePath)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(result.jobID),
            "remotePath": .string(result.remotePath),
            "state": .string(result.state.rawValue),
            "detail": .string(result.detail),
          ]))
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
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

    case "artifact.importHap.begin":
      guard artifactStore != nil, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for HAP import")
      }
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let name)? = request.params?["name"],
        case .integer(let byteCountValue)? = request.params?["byteCount"],
        case .string(let sha256)? = request.params?["sha256"],
        byteCountValue >= 0, byteCountValue <= Int64(Int.max)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId, name, byteCount and sha256 are required")
      }
      do {
        guard let target = try targetStore.find(targetID: targetID) else {
          return failure(
            id: request.id, code: .notFound, message: "unknown target \(targetID)")
        }
        let uploadID = try await hapImports.begin(
          target: target, name: name, byteCount: Int(byteCountValue), sha256: sha256)
        return success(
          id: request.id,
          result: .object([
            "uploadId": .string(uploadID),
            "maximumChunkBytes": .integer(
              Int64(HAPArtifactImportCoordinator.maximumChunkBytes)),
            "targetId": .string(target.targetID),
            "bindingRevision": .integer(Int64(target.bindingRevision)),
          ]))
      } catch let error as HAPArtifactImportError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importHap.append":
      guard artifactStore != nil, targetStore != nil else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for HAP import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"],
        case .integer(let offsetValue)? = request.params?["offset"],
        offsetValue >= 0, offsetValue <= Int64(Int.max),
        case .string(let base64)? = request.params?["base64"],
        base64.utf8.count <= ((HAPArtifactImportCoordinator.maximumChunkBytes + 2) / 3) * 4,
        let chunk = Data(base64Encoded: base64, options: [])
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "uploadId, non-negative offset and a bounded base64 chunk are required")
      }
      do {
        let nextOffset = try await hapImports.append(
          uploadID: uploadID, offset: Int(offsetValue), chunk: chunk)
        return success(
          id: request.id,
          result: .object(["nextOffset": .integer(Int64(nextOffset))]))
      } catch let error as HAPArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importHap.commit":
      guard let artifactStore, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for HAP import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      do {
        let completed = try await hapImports.commit(uploadID: uploadID)
        guard let currentTarget = try targetStore.find(targetID: completed.target.targetID),
          currentTarget.bindingRevision == completed.target.bindingRevision,
          currentTarget.stablePhysicalIdentitySHA256
            == completed.target.stablePhysicalIdentitySHA256
        else {
          return failure(
            id: request.id, code: .conflict,
            message: "target binding changed during HAP import")
        }
        let jobID =
          "input-hap-\(currentTarget.targetID)-r\(currentTarget.bindingRevision)-"
          + String(completed.sha256.prefix(16))
        let metadata = try await artifactStore.publish(
          RuntimeArtifactPublicationRequest(
            jobID: jobID,
            sessionID: "session-\(jobID)",
            stepID: "import-hap",
            name: completed.name,
            mediaType: "application/vnd.openharmony.hap",
            privacy: .standard,
            retentionClass: .pinnedUntilVerified,
            sourceOperation: "artifact.import-hap",
            providerID: "host",
            bindingSnapshot: ArtifactBindingSnapshot(
              targetID: currentTarget.targetID,
              bindingRevision: currentTarget.bindingRevision,
              stableIdentitySHA256: currentTarget.stablePhysicalIdentitySHA256),
            contents: completed.contents))
        let lease = try await artifactStore.leaseReference(
          jobID: metadata.jobID, artifactID: metadata.artifactID)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(metadata.jobID),
            "artifactId": .string(metadata.artifactID),
            "lease": .string(lease),
            "name": .string(metadata.name),
            "byteCount": .integer(Int64(metadata.byteCount)),
            "sha256": .string(metadata.sha256),
            "targetId": .string(currentTarget.targetID),
            "bindingRevision": .integer(Int64(currentTarget.bindingRevision)),
            "stableIdentitySha256": .string(
              currentTarget.stablePhysicalIdentitySHA256),
          ]))
      } catch let error as HAPArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch let error as RuntimeArtifactError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importHap.abort":
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      let aborted = await hapImports.abort(uploadID: uploadID)
      return success(
        id: request.id, result: .object(["aborted": .bool(aborted)]))

    case "artifact.importNativeLibrary.begin":
      guard artifactStore != nil, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for native library import")
      }
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let name)? = request.params?["name"],
        case .integer(let byteCountValue)? = request.params?["byteCount"],
        case .string(let sha256)? = request.params?["sha256"],
        byteCountValue >= 0, byteCountValue <= Int64(Int.max)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId, name, byteCount and sha256 are required")
      }
      do {
        guard let target = try targetStore.find(targetID: targetID) else {
          return failure(
            id: request.id, code: .notFound, message: "unknown target \(targetID)")
        }
        let uploadID = try await nativeLibraryImports.begin(
          target: target, name: name, byteCount: Int(byteCountValue),
          sha256: sha256)
        return success(
          id: request.id,
          result: .object([
            "uploadId": .string(uploadID),
            "maximumChunkBytes": .integer(
              Int64(NativeLibraryArtifactImportCoordinator.maximumChunkBytes)),
            "targetId": .string(target.targetID),
            "bindingRevision": .integer(Int64(target.bindingRevision)),
          ]))
      } catch let error as NativeLibraryArtifactImportError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importNativeLibrary.append":
      guard artifactStore != nil, targetStore != nil else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for native library import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"],
        case .integer(let offsetValue)? = request.params?["offset"],
        offsetValue >= 0, offsetValue <= Int64(Int.max),
        case .string(let base64)? = request.params?["base64"],
        base64.utf8.count
          <= ((NativeLibraryArtifactImportCoordinator.maximumChunkBytes + 2) / 3) * 4,
        let chunk = Data(base64Encoded: base64, options: [])
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "uploadId, non-negative offset and a bounded base64 chunk are required")
      }
      do {
        let nextOffset = try await nativeLibraryImports.append(
          uploadID: uploadID, offset: Int(offsetValue), chunk: chunk)
        return success(
          id: request.id,
          result: .object(["nextOffset": .integer(Int64(nextOffset))]))
      } catch let error as NativeLibraryArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importNativeLibrary.commit":
      guard let artifactStore, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for native library import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      do {
        let completed = try await nativeLibraryImports.commit(uploadID: uploadID)
        guard let currentTarget = try targetStore.find(
          targetID: completed.target.targetID),
          currentTarget.bindingRevision == completed.target.bindingRevision,
          currentTarget.stablePhysicalIdentitySHA256
            == completed.target.stablePhysicalIdentitySHA256
        else {
          return failure(
            id: request.id, code: .conflict,
            message: "target binding changed during native library import")
        }
        let jobID =
          "input-so-\(currentTarget.targetID)-r\(currentTarget.bindingRevision)-"
          + String(completed.sha256.prefix(16))
        let metadata = try await artifactStore.publish(
          RuntimeArtifactPublicationRequest(
            jobID: jobID, sessionID: "session-\(jobID)",
            stepID: "import-native-library", name: completed.name,
            mediaType: "application/x-elf",
            privacy: .standard, retentionClass: .pinnedUntilVerified,
            sourceOperation: "artifact.import-native-library",
            providerID: "host",
            bindingSnapshot: ArtifactBindingSnapshot(
              targetID: currentTarget.targetID,
              bindingRevision: currentTarget.bindingRevision,
              stableIdentitySHA256:
                currentTarget.stablePhysicalIdentitySHA256),
            contents: completed.contents))
        let lease = try await artifactStore.leaseReference(
          jobID: metadata.jobID, artifactID: metadata.artifactID)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(metadata.jobID),
            "artifactId": .string(metadata.artifactID),
            "lease": .string(lease),
            "name": .string(metadata.name),
            "byteCount": .integer(Int64(metadata.byteCount)),
            "sha256": .string(metadata.sha256),
            "abi": .string(completed.facts.abi.rawValue),
            "elfClassBits": .integer(
              Int64(completed.facts.elfClassBits)),
            "machine": .integer(Int64(completed.facts.machine)),
            "buildId": .string(completed.facts.buildID),
            "targetId": .string(currentTarget.targetID),
            "bindingRevision": .integer(
              Int64(currentTarget.bindingRevision)),
            "stableIdentitySha256": .string(
              currentTarget.stablePhysicalIdentitySHA256),
          ]))
      } catch let error as NativeLibraryArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch let error as RuntimeArtifactError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importNativeLibrary.abort":
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      let aborted = await nativeLibraryImports.abort(uploadID: uploadID)
      return success(
        id: request.id, result: .object(["aborted": .bool(aborted)]))

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

    case "artifact.export":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"],
        case .string(let artifactID)? = request.params?["artifactId"],
        case .string(let destination)? = request.params?["destinationDirectory"]
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "jobId, artifactId and destinationDirectory are required")
      }
      var allowSensitive = false
      if case .bool(let flag)? = request.params?["allowSensitive"] { allowSensitive = flag }
      do {
        let exported = try await artifactStore.export(
          jobID: jobID, artifactID: artifactID,
          destinationDirectory: URL(fileURLWithPath: destination, isDirectory: true),
          allowSensitive: allowSensitive)
        return success(
          id: request.id,
          result: .object([
            "artifactId": .string(artifactID),
            "exportedPath": .string(exported.path),
          ]))
      } catch let error as RuntimeArtifactError {
        if case .sensitiveAccessRequiresOptIn = error {
          return failure(
            id: request.id, code: .rejected,
            message: "artifact is sensitive; pass allowSensitive to export it")
        }
        return failure(id: request.id, code: .rejected, message: "\(error)")
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
      case .waitingForHuman(let kind, let prompt):
        return success(
          id: request.id,
          result: .object([
            "outcome": .string("waitingForHuman"),
            "humanActionKind": .string(kind.rawValue),
            "prompt": .string(prompt),
          ]))
      case .failed(let reason):
        return failure(id: request.id, code: .rejected, message: reason)
      }

    case let method where method.hasPrefix("task."):
      return await handleTaskMethod(method, request)

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
      "jobId": .string(metadata.jobID),
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
      "targetId": .string(metadata.bindingSnapshot.targetID),
      "bindingRevision": metadata.bindingSnapshot.bindingRevision
        .map { .integer(Int64($0)) } ?? .null,
      "stableIdentitySha256": metadata.bindingSnapshot.stableIdentitySHA256
        .map(JSONValue.string) ?? .null,
    ])
  }

  private static func encodeCleanupDebt(_ debt: CleanupDebtRecord) -> JSONValue {
    .object([
      "jobId": .string(debt.jobID),
      "stepId": .string(debt.stepID),
      "remotePath": .string(debt.remotePath),
      "reason": .string(debt.reason),
      "recordedAtUtc": .string(debt.recordedAtUTC),
      "retryOutcomeUnknown": .bool(
        debt.retryOutcomeUnknown == true || debt.retryAttemptStartedAtUTC != nil),
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

  private static func encodeEvidence(
    snapshot: RuntimeJobEvidenceSnapshot,
    artifacts: [RuntimeVerifiedArtifactEvidence],
    blockers: [String]
  ) -> JSONValue {
    func optionalString(_ value: String?) -> JSONValue {
      value.map(JSONValue.string) ?? .null
    }
    func optionalInteger(_ value: Int?) -> JSONValue {
      value.map { .integer(Int64($0)) } ?? .null
    }
    let effectLevel: String?
    switch snapshot.actualEffect {
    case "hostOnly", "readOnly": effectLevel = "E0"
    case "deviceMutation": effectLevel = "E1"
    case "destructive": effectLevel = "E2"
    default: effectLevel = nil
    }
    let authority: JSONValue
    if let value = snapshot.authority {
      authority = .object([
        "kind": .string(value.kind.rawValue),
        "reference": .string(value.reference),
        "admittedAtUtc": .string(value.admittedAtUTC),
        "validUntilUtc": optionalString(value.validUntilUTC),
        "consumptionFingerprintSha256": optionalString(
          value.consumptionFingerprintSHA256),
      ])
    } else {
      authority = .null
    }
    let observation: JSONValue
    if let value = snapshot.observation {
      observation = .object([
        "targetId": optionalString(value.targetID),
        "bindingRevision": optionalInteger(value.bindingRevision),
        "stableIdentitySha256": optionalString(value.stableIdentitySHA256),
        "model": optionalString(value.model),
        "firmware": optionalString(value.firmware),
        "transport": optionalString(value.transport),
        "providerId": .string(value.providerID),
        "toolVersion": .string(value.toolVersion),
        "toolSha256": .string(value.toolSHA256),
        "confirmedAtUtc": optionalString(value.confirmedAtUTC),
        "confirmationMethod": .string(value.confirmationMethod),
        "preflightSteps": .array(
          value.preflightSteps.map {
            .object([
              "stepId": .string($0.stepID),
              "stepKind": .string($0.stepKind),
              "outcomeAtUtc": .string($0.outcomeAtUTC),
            ])
          }),
      ])
    } else {
      observation = .null
    }
    return .object([
      "jobId": .string(snapshot.jobID),
      "operationReference": .string(snapshot.operationReference),
      "catalogDigest": .string(snapshot.catalogDigest),
      "targetId": .string(snapshot.targetID),
      "bindingRevision": optionalInteger(snapshot.bindingRevision),
      "providerId": .string(snapshot.providerID),
      "actualEffect": optionalString(effectLevel),
      "authority": authority,
      "observation": observation,
      "actualStepKinds": .array(snapshot.actualStepKinds.map(JSONValue.string)),
      "executionMode": .string(snapshot.executionMode),
      "terminalState": .string(snapshot.terminalState),
      "outcomeUnknown": .bool(snapshot.outcomeUnknown),
      "startedAtUtc": optionalString(snapshot.startedAtUTC),
      "firstEvidenceStepAtUtc": optionalString(snapshot.firstEvidenceStepAtUTC),
      "finishedAtUtc": optionalString(snapshot.finishedAtUTC),
      "artifacts": .array(
        artifacts.map { artifact in
          .object([
            "reference": .string(artifact.reference),
            "sha256": .string(artifact.sha256),
            "jobId": .string(artifact.jobID),
            "targetId": .string(artifact.targetID),
            "bindingRevision": optionalInteger(artifact.bindingRevision),
            "stableIdentitySha256": optionalString(artifact.stableIdentitySHA256),
            "providerId": .string(artifact.providerID),
            "byteCount": .integer(Int64(artifact.byteCount)),
            "bytesVerified": .bool(true),
          ])
        }),
      "blockers": .array(blockers.map(JSONValue.string)),
    ])
  }

  // Internal, not private: the `task.*` methods live in a sibling file so
  // this file stays the closed method table rather than growing a second
  // plane inside it.
  func success(id: String, result: JSONValue) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(id: id, ok: true, result: result, error: nil)
  }

  func failure(
    id: String, code: AgentDaemonErrorCode, message: String
  ) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(
      id: id, ok: false, result: nil,
      error: AgentWireProtocol.WireError(code: code.rawValue, message: message))
  }

  private static func addingUTCSeconds(_ seconds: Int, to value: String) -> String? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    guard let date = formatter.date(from: value) else { return nil }
    return formatter.string(from: date.addingTimeInterval(TimeInterval(seconds)))
  }

  private static func isMergedPRIssuerReference(_ reference: String) -> Bool {
    guard let token = reference.split(separator: " ").first,
      token.hasPrefix("PR#"),
      let number = Int(token.dropFirst(3)),
      number > 0
    else {
      return false
    }
    return true
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
