// Legacy v1 -> v2 request adapter (CHG-2026-046, T02).
//
// One-way compatibility: an AgentDeviceOperationRequest (v1, changeId/taskId
// mandatory) upgrades into a RuntimeOperationRequest (v2) plus explicit
// deprecation notes. Governance identity is demoted to clientContext
// provenance - display/audit only, no authority. There is deliberately no
// v2 -> v1 path, and the upgrade fails closed for v1 operations that have
// no published composite operation yet, instead of inventing one.

import ArkDeckCore
import ArkDeckRuntime
import Foundation

public struct RuntimeUpgradedRequest: Sendable {
  public let request: RuntimeOperationRequest
  /// Human-readable deprecation notes; non-empty for every upgraded request.
  public let deprecations: [String]
}

public enum RuntimeLegacyAdapterError: Error, Equatable, Sendable {
  /// The v1 operation has no v2 composite operation to map onto. Listing is
  /// closed: guessing a mapping would silently change semantics.
  case unsupportedLegacyOperation(AgentDeviceOperationID)
  /// Non-execute v1 modes (planOnly/simulated) have no v2 wire equivalent
  /// in MU-1; the plan surface arrives with the daemon (MU-2).
  case unsupportedExecutionMode(AgentDeviceOperationExecutionMode)
  case upgradeProducedInvalidRequest(String)
}

public enum RuntimeOperationLegacyAdapter {
  /// v1 operation id -> v2 catalog reference. Closed table; extending it is
  /// a catalog decision, not an adapter default.
  static let operationMap: [AgentDeviceOperationID: RuntimeOperationReference] = [
    .observeDevice: RuntimeOperationReference(id: "observe.device", version: 1),
    .captureHilog: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
    .captureUIDump: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
    .captureTrace: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
    .installHAP: RuntimeOperationReference(id: "debug.hap", version: 1),
    .uninstallHAP: RuntimeOperationReference(id: "debug.hap", version: 1),
    .startApplication: RuntimeOperationReference(id: "debug.hap", version: 1),
    .stopApplication: RuntimeOperationReference(id: "debug.hap", version: 1),
    .deployNativeLibrary: RuntimeOperationReference(
      id: "deploy.native-library.app-owned", version: 1),
    .flash: RuntimeOperationReference(id: "flash.dayu200", version: 1),
  ]

  public static func upgrade(
    _ legacy: AgentDeviceOperationRequest
  ) throws -> RuntimeUpgradedRequest {
    guard legacy.executionMode == .execute else {
      throw RuntimeLegacyAdapterError.unsupportedExecutionMode(legacy.executionMode)
    }
    guard let operation = operationMap[legacy.operation.id] else {
      throw RuntimeLegacyAdapterError.unsupportedLegacyOperation(legacy.operation.id)
    }

    var deprecations = [
      "changeId is deprecated on runtime requests; kept only as provenance annotation",
      "taskId is deprecated on runtime requests; kept only as provenance annotation",
      "v1 operation \(legacy.operation.id.rawValue) mapped to \(operation.reference)",
    ]

    var provenance: [String: String] = [
      "legacyChangeId": legacy.changeID,
      "legacyTaskId": legacy.taskID,
      "legacyOperationId": legacy.operation.id.rawValue,
      "legacyProfileId": legacy.operation.profileID,
      "legacyConfigurationId": legacy.operation.configurationID,
      "legacySchemaVersion": AgentDeviceOperationRequest.schemaVersion,
    ]
    if let authorizationID = legacy.authorizationID {
      // A v1 standing-authorization id is not a runtime capability. The
      // upgrade records it but grants nothing; the caller must present a
      // RuntimeCapability issued for the v2 operation.
      provenance["legacyAuthorizationId"] = authorizationID
      deprecations.append(
        "authorizationId \(authorizationID) is not a runtime capability; "
          + "request denied at authorization time unless a CAP-RT capability is presented")
    }

    var inputs: [String: JSONValue] = [:]
    if !legacy.operation.artifactLeaseIDs.isEmpty {
      inputs["legacyArtifactLeaseIds"] = .array(
        legacy.operation.artifactLeaseIDs.map(JSONValue.string))
    }
    inputs["legacyConfigurationSha256"] = .string(legacy.operation.configurationSHA256)

    let outputs: [RuntimeRequestedOutput] = legacy.requestedOutputs.compactMap { output in
      switch output {
      case .rawArtifacts: return .rawArtifacts
      case .derivedArtifacts: return .derivedArtifacts
      case .analysisReport: return .analysisReport
      case .hardwareEvidence: return .hardwareEvidence
      }
    }

    let request: RuntimeOperationRequest
    do {
      request = try RuntimeOperationRequest(
        requestID: legacy.requestID,
        idempotencyKey: "legacy-\(legacy.requestID)",
        target: DurableTargetReference(targetID: legacy.durableTargetID),
        operation: operation,
        inputs: inputs,
        requestedOutputs: outputs.isEmpty ? [.derivedArtifacts] : outputs,
        authorization: nil,
        clientContext: RuntimeClientContext(
          clientName: "legacy-v1-adapter",
          provenance: provenance))
    } catch {
      throw RuntimeLegacyAdapterError.upgradeProducedInvalidRequest(String(describing: error))
    }
    return RuntimeUpgradedRequest(request: request, deprecations: deprecations)
  }
}
