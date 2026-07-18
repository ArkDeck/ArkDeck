import ArkDeckCore
import ArkDeckStorage
import Foundation

enum SessionStorageFixtures {
  static let timestamp = "2026-07-17T08:00:00Z"
  static let scopeHash = String(repeating: "a", count: 64)

  static func manifest(
    sessionID: String = "session-1",
    jobID: String = "job-1",
    status: String = "succeeded",
    executionMode: String = "simulated",
    executionAuthority: String = "standardAgent",
    coreSpecBaseline: String = "CORE-2.0.0",
    timestamp: String = SessionStorageFixtures.timestamp,
    sessionDisposition: String = "finalized",
    steps: [JSONValue] = [],
    parameters: [JSONValue] = [],
    compensations: [JSONValue] = [],
    artifacts: [ArtifactRecord] = [],
    confirmations: [JSONValue]? = nil,
    failureCode: String = "storage.enospc",
    failureSummary: String = "Artifact receive stopped before publication",
    warnings: [String]? = nil,
    realConnectKey: String = "fixture-device",
    realIdentitySnapshot: JSONValue = .object(["serial": .string("fixture-serial")]),
    recovery: JSONValue = .null
  ) throws -> Data {
    let simulated = executionMode == "simulated"
    let failure: JSONValue =
      status == "failed"
      ? .object([
        "stage": .string("artifactReceive"),
        "code": .string(failureCode),
        "summary": .string(failureSummary),
      ]) : .null
    let artifactValues = try artifacts.map { record in
      try JSONDecoder().decode(
        JSONValue.self,
        from: JSONEncoder().encode(record))
    }
    let confirmationValues = confirmations ?? []
    let root: JSONValue = .object([
      "schemaVersion": .string("1.0.0"),
      "appVersion": .string("1.0.0-test"),
      "coreSpecBaseline": .string(coreSpecBaseline),
      "platformProfile": .string("macos-1.0.0"),
      "sessionId": .string(sessionID),
      "jobId": .string(jobID),
      "status": .string(status),
      "executionMode": .string(executionMode),
      "executionAuthority": .string(executionAuthority),
      "outcomeCertainty": .string("confirmed"),
      "sessionDisposition": .string(sessionDisposition),
      "createdAt": .string(timestamp),
      "completedAt": .string(timestamp),
      "archivedAt": sessionDisposition == "archived" ? .string(timestamp) : .null,
      "originalTarget": simulated
        ? .object([
          "kind": .string("synthetic"),
          "connectKey": .null,
          "transport": .string("synthetic"),
          "identitySnapshot": .object(["fixture": .string("storage-contract")]),
        ])
        : .object([
          "kind": .string("real"),
          "connectKey": .string(realConnectKey),
          "transport": .string("usb"),
          "identitySnapshot": realIdentitySnapshot,
        ]),
      "bindingHistory": .array([
        .object([
          "revision": .integer(1),
          "connectKey": simulated ? .null : .string(realConnectKey),
          "transport": .string(simulated ? "synthetic" : "usb"),
          "identitySnapshot": simulated
            ? .object(["fixture": .string("storage-contract")])
            : realIdentitySnapshot,
          "evidence": .array([.string("fixture-binding")]),
          "confirmedBy": .string(simulated ? "simulation" : "user"),
          "channelProtection": .string(
            simulated ? "notApplicable" : "encryptedVerified"),
        ])
      ]),
      "toolchain": simulated
        ? .object(["kind": .string("none")])
        : .object([
          "kind": .string("hdc"),
          "source": .string("fixture"),
          "path": .string("/fixture/hdc"),
          "sha256": .string(String(repeating: "c", count: 64)),
          "clientVersion": .string("fixture-client"),
          "serverVersion": .string("fixture-server"),
          "daemonVersion": .null,
          "endpoint": .string("fixture-endpoint"),
          "serverGeneration": .integer(1),
          "serverOwnership": .string("external"),
        ]),
      "workflow": simulated
        ? .object([
          "kind": .string("storageContract"),
          "profileVersion": .string("1.0.0"),
          "providerIdentity": .string("fixture-provider"),
          "fixtureIdentity": .string("session-storage-fixture-1"),
          "scenarioIdentity": .string("session-storage-scenario-1"),
        ])
        : .object([
          "kind": .string("storageContract"),
          "profileVersion": .string("1.0.0"),
          "providerIdentity": .string("fixture-provider"),
        ]),
      "steps": .array(steps),
      "parameters": .array(parameters),
      "compensations": .array(compensations),
      "confirmations": .array(confirmationValues),
      "artifacts": .array(artifactValues),
      "warnings": .array(
        (warnings ?? (status == "failed" ? ["partial Artifact retained"] : [])).map {
          .string($0)
        }),
      "failure": failure,
      "recovery": recovery,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(root)
  }

  static func serverLifecycleConfirmation() -> JSONValue {
    .object([
      "confirmationId": .string("confirmation-lifecycle-1"),
      "kind": .string("serverLifecycle"),
      "scopeHash": .string(scopeHash),
      "decision": .string("accepted"),
      "actor": .string("user"),
      "decidedAt": .string(timestamp),
      "relatedStepIds": .array([.string("step-lifecycle-1")]),
    ])
  }
}
