import ArkDeckCore
import Foundation

/// Metadata-only Artifact inventory returned after the Runtime has reached a
/// terminal. Artifact contents never cross this verification surface.
public struct RuntimeHeadlessArtifact: Codable, Sendable, Equatable {
  public let artifactID: String
  public let jobID: String
  public let name: String
  public let byteCount: Int
  public let sha256: String
  public let status: String
  public let sourceOperation: String
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?

  enum CodingKeys: String, CodingKey {
    case artifactID = "artifactId"
    case jobID = "jobId"
    case name
    case byteCount
    case sha256
    case status
    case sourceOperation
    case targetID = "targetId"
    case bindingRevision
    case stableIdentitySHA256 = "stableIdentitySha256"
  }
}

public struct RuntimeHeadlessVerificationChecks: Codable, Sendable, Equatable {
  public let udsHealthVerified: Bool
  public let terminalReceiptVerified: Bool
  public let trustedEvidenceVerified: Bool
  public let artifactsVerified: Bool
  public let runtimePostflightVerified: Bool
}

/// Closed-loop proof for one headless observation. `runtimeVerified` means the
/// daemon-owned UDS receipt, immutable Artifact inventory and terminal
/// postflight agree. It is intentionally not named `REAL_DEVICE_PASS`: test
/// fixtures and simulations must never be promoted to hardware evidence.
public struct RuntimeHeadlessVerificationReport: Codable, Sendable, Equatable {
  public let schemaVersion: String
  public let classification: String
  public let daemonCatalogDigest: String
  public let receipt: RuntimeAgentExecutionReceipt
  public let artifactInventory: [RuntimeHeadlessArtifact]
  public let checks: RuntimeHeadlessVerificationChecks
  public let blockers: [String]
  public let runtimeVerified: Bool
}

public enum RuntimeHeadlessVerificationOutcome: Sendable, Equatable {
  case verified(RuntimeHeadlessVerificationReport)
  case awaitingHumanAction(RuntimeHumanActionReceipt, RuntimeAgentExecutionReceipt)
  case failed(reason: String, report: RuntimeHeadlessVerificationReport)
}

/// Production headless smoke path:
/// UDS -> native Agent executor -> published typed Runtime operation ->
/// daemon-owned evidence -> immutable Artifact inventory -> terminal checks.
///
/// This type owns no provider, process, argv or capability-administration
/// surface. Device dispatch remains exclusively inside `arkdeck-agentd`.
public struct RuntimeHeadlessVerifier: Sendable {
  private static let operationReference = "observe.device@1"
  private static let requiredArtifactNames: Set<String> = [
    "binding-snapshot.json", "device-facts.json", "tool-facts.json",
  ]
  private static let requiredStepKinds: Set<String> = [
    "probeDevice", "probeHDCServer", "probeHostTool", "runApprovedRemoteRead",
  ]

  private let client: AgentClient
  private let executor: AgentRuntimeExecutor

  public init(
    client: AgentClient,
    stateDirectory: URL? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.client = client
    self.executor = AgentRuntimeExecutor(
      client: client, stateDirectory: stateDirectory, nowUTC: nowUTC)
  }

  public func verifyObserveDevice(
    targetID: String? = nil,
    maximumWaitSeconds: Int = 90,
    executionID: String = UUID().uuidString.lowercased()
  ) throws -> RuntimeHeadlessVerificationOutcome {
    let daemonCatalogDigest = try healthCatalogDigest()
    let outcome = try executor.run(
      RuntimeAgentExecutionRequest(
        operationID: "observe.device", operationVersion: 1,
        targetID: targetID, maximumWaitSeconds: maximumWaitSeconds,
        executionID: executionID))

    switch outcome {
    case .awaitingHumanAction(let action, let receipt):
      return .awaitingHumanAction(action, receipt)
    case .failed(let reason, let receipt):
      let report = report(
        daemonCatalogDigest: daemonCatalogDigest, receipt: receipt,
        inventory: [], additionalBlockers: ["runtimeExecution:\(reason)"])
      return .failed(reason: reason, report: report)
    case .completed(let receipt):
      let inventory: [RuntimeHeadlessArtifact]
      var blockers: [String] = []
      do {
        inventory = try artifactInventory(jobID: receipt.jobID)
      } catch {
        inventory = []
        blockers.append("artifactInventory:\(error)")
      }
      let report = report(
        daemonCatalogDigest: daemonCatalogDigest, receipt: receipt,
        inventory: inventory, additionalBlockers: blockers)
      guard report.runtimeVerified else {
        return .failed(
          reason: "headless Runtime receipt, Artifact or postflight verification failed",
          report: report)
      }
      return .verified(report)
    }
  }

  private func healthCatalogDigest() throws -> String {
    let health = try client.request(method: "health")
    guard case .object(let fields) = health,
      case .string(let digest)? = fields["catalogDigest"],
      Self.validSHA256(digest)
    else {
      throw RuntimeAgentExecutorError.malformedResponse(
        "LaunchAgent UDS health lacks a valid catalog digest")
    }
    return digest
  }

  private func artifactInventory(jobID: String?) throws -> [RuntimeHeadlessArtifact] {
    guard let jobID, !jobID.isEmpty else {
      throw RuntimeAgentExecutorError.malformedResponse(
        "terminal receipt has no job id for Artifact lookup")
    }
    let listed = try client.request(
      method: "artifact.list", params: ["jobId": .string(jobID)])
    guard case .array(let rows) = listed else {
      throw RuntimeAgentExecutorError.malformedResponse(
        "artifact.list did not return an array")
    }
    return try rows.map(Self.decodeArtifact).sorted { $0.artifactID < $1.artifactID }
  }

  private static func decodeArtifact(_ value: JSONValue) throws -> RuntimeHeadlessArtifact {
    guard case .object(let fields) = value,
      case .string(let artifactID)? = fields["artifactId"], validIdentifier(artifactID),
      case .string(let jobID)? = fields["jobId"], validIdentifier(jobID),
      case .string(let name)? = fields["name"], !name.isEmpty,
      let byteCount = exactInt(fields["byteCount"]), byteCount >= 0,
      case .string(let sha256)? = fields["sha256"],
      case .string(let status)? = fields["status"],
      case .string(let sourceOperation)? = fields["sourceOperation"],
      case .string(let targetID)? = fields["targetId"], validIdentifier(targetID)
    else {
      throw RuntimeAgentExecutorError.malformedResponse(
        "artifact.list contains incomplete metadata")
    }
    let bindingRevision = exactInt(fields["bindingRevision"])
    let stableIdentitySHA256: String?
    if case .string(let identity)? = fields["stableIdentitySha256"] {
      stableIdentitySHA256 = identity
    } else {
      stableIdentitySHA256 = nil
    }
    return RuntimeHeadlessArtifact(
      artifactID: artifactID, jobID: jobID, name: name,
      byteCount: byteCount, sha256: sha256, status: status,
      sourceOperation: sourceOperation, targetID: targetID,
      bindingRevision: bindingRevision,
      stableIdentitySHA256: stableIdentitySHA256)
  }

  private func report(
    daemonCatalogDigest: String,
    receipt: RuntimeAgentExecutionReceipt,
    inventory: [RuntimeHeadlessArtifact],
    additionalBlockers: [String]
  ) -> RuntimeHeadlessVerificationReport {
    var blockers = receipt.evidenceBlockers + additionalBlockers

    let udsHealthVerified =
      Self.validSHA256(daemonCatalogDigest)
      && receipt.catalogDigest == daemonCatalogDigest
    if !udsHealthVerified {
      blockers.append("udsHealth:catalog digest is missing or drifted")
    }

    let terminalReceiptVerified =
      receipt.operationReference == Self.operationReference
      && receipt.executionMode == "execute"
      && receipt.terminalState == "succeeded"
      && !receipt.outcomeUnknown
      && receipt.jobID?.isEmpty == false
      && receipt.targetID?.isEmpty == false
      && (receipt.bindingRevision ?? 0) >= 1
      && !receipt.startedAtUTC.isEmpty
      && !receipt.finishedAtUTC.isEmpty
    if !terminalReceiptVerified {
      blockers.append("terminalReceipt:operation, identity, timestamps or terminal drifted")
    }

    let observation = receipt.evidenceObservation
    let trustedEvidenceVerified =
      receipt.executor == .agent
      && receipt.actualEffect == .readOnly
      && receipt.authority?.kind == .defaultReadOnlyPolicy
      && receipt.providerID == observation?.providerID
      && receipt.targetID == observation?.targetID
      && receipt.bindingRevision == observation?.bindingRevision
      && Self.validSHA256(observation?.stableIdentitySHA256 ?? "")
      && observation?.model?.isEmpty == false
      && observation?.firmware?.isEmpty == false
      && observation?.transport != nil
      && !(observation?.toolVersion.isEmpty ?? true)
      && Self.validSHA256(observation?.toolSHA256 ?? "")
      && observation?.confirmedAtUTC?.isEmpty == false
      && observation?.confirmationMethod == "machineReadback"
    if !trustedEvidenceVerified {
      blockers.append("trustedEvidence:daemon-owned target/tool observation is incomplete")
    }

    let requiredNames = Set(inventory.map(\.name))
    let inventoryIDs = Set(inventory.map(\.artifactID))
    let evidenceReferences = Set(receipt.artifacts.map(\.reference))
    let observedIdentity = observation?.stableIdentitySHA256
    let artifactsVerified =
      !inventory.isEmpty
      && requiredNames == Self.requiredArtifactNames
      && inventory.count == receipt.artifacts.count
      && inventoryIDs.count == inventory.count
      && evidenceReferences.count == receipt.artifacts.count
      && inventory.allSatisfy { artifact in
        let reference = "arkdeck-artifact://\(artifact.jobID)/\(artifact.artifactID)"
        guard let evidence = receipt.artifacts.first(where: { $0.reference == reference }) else {
          return false
        }
        return artifact.status == "published"
          && artifact.sourceOperation == Self.operationReference
          && artifact.jobID == receipt.jobID
          && artifact.targetID == receipt.targetID
          && artifact.bindingRevision == receipt.bindingRevision
          && artifact.stableIdentitySHA256 == observedIdentity
          && Self.validSHA256(artifact.sha256)
          && artifact.sha256 == evidence.sha256
          && artifact.byteCount == evidence.byteCount
          && evidence.jobID == receipt.jobID
          && evidence.targetID == receipt.targetID
          && evidence.bindingRevision == receipt.bindingRevision
          && evidence.stableIdentitySHA256 == observedIdentity
          && evidence.providerID == receipt.providerID
          && evidence.bytesVerified
      }
    if !artifactsVerified {
      blockers.append("artifacts:required immutable inventory is incomplete or drifted")
    }

    let runtimePostflightVerified =
      terminalReceiptVerified
      && trustedEvidenceVerified
      && artifactsVerified
      && Set(receipt.stepKinds).isSuperset(of: Self.requiredStepKinds)
    if !runtimePostflightVerified {
      blockers.append("runtimePostflight:typed steps, evidence or Artifact closure is incomplete")
    }

    blockers = Array(Set(blockers)).sorted()
    let checks = RuntimeHeadlessVerificationChecks(
      udsHealthVerified: udsHealthVerified,
      terminalReceiptVerified: terminalReceiptVerified,
      trustedEvidenceVerified: trustedEvidenceVerified,
      artifactsVerified: artifactsVerified,
      runtimePostflightVerified: runtimePostflightVerified)
    return RuntimeHeadlessVerificationReport(
      schemaVersion: "arkdeck-headless-runtime-verification/v1",
      classification: "runtimeReceipt",
      daemonCatalogDigest: daemonCatalogDigest, receipt: receipt,
      artifactInventory: inventory, checks: checks, blockers: blockers,
      runtimeVerified: blockers.isEmpty)
  }

  private static func exactInt(_ value: JSONValue?) -> Int? {
    switch value {
    case .integer(let raw)?: return Int(exactly: raw)
    case .unsignedInteger(let raw)?: return Int(exactly: raw)
    default: return nil
    }
  }

  private static func validSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
      ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
    }
  }

  private static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 160 && value.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
    }
  }
}
