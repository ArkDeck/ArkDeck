import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime

final class CLIWorkspaceContinuationContractTests: XCTestCase {
  private let sourceJobID = "job-source-continuation"
  private let targetID = "target-continuation"
  private let identity = String(repeating: "b", count: 64)

  private func session(_ command: String = "workspace.continuation.inspect") -> CLIRuntimeSession {
    var arguments = ["--output", "json", "--socket", "/tmp/arkdeck-continuation-no-daemon"]
    return RuntimeCLI.runtimeSession(&arguments, command: command)
  }

  private func request(
    operation: String = "observe.device",
    target: String? = nil,
    binding: Int? = 3,
    inputs: [String: JSONValue] = [:],
    authorization: RuntimeCapabilityReference? = nil,
    thread: String? = "thread-continuation"
  ) throws -> RuntimeOperationRequest {
    var provenance = ["fixture": "continuation"]
    if let thread { provenance[RuntimeClientContext.threadProvenanceKey] = thread }
    return try RuntimeOperationRequest(
      requestID: "source-request-001",
      idempotencyKey: "source-request-001",
      target: DurableTargetReference(
        targetID: target ?? targetID, expectedBindingRevision: binding),
      operation: RuntimeOperationReference(id: operation, version: 1),
      inputs: inputs,
      authorization: authorization,
      clientContext: RuntimeClientContext(clientName: "source-client", provenance: provenance))
  }

  private func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(
      JSONValue.self, from: CanonicalJSONEncoders.canonical().encode(value))
  }

  private func status(
    jobID: String,
    request: RuntimeOperationRequest,
    effect: WorkflowEffect,
    state: JobState = .succeeded,
    unknown: Bool = false,
    waitingForHuman: Bool = false,
    residue: Int64 = 0,
    superseded: String? = nil
  ) -> JSONValue {
    let nextAction: JSONValue
    if waitingForHuman {
      nextAction = .object([
        "kind": .string("humanAction"),
        "owner": .object(["kind": .string("job"), "id": .string(jobID)]),
        "resource": .object([
          "kind": .string("humanAction"), "id": .string("human-action-source"),
        ]),
        "reasonCode": .string("device.notObserved"),
        "resumeReference": .string("resume-source-action"),
        "expiresAt": .null,
      ])
    } else {
      nextAction = .object([
        "kind": .string(unknown ? "reconcile" : "readResult"),
        "owner": .object(["kind": .string("job"), "id": .string(jobID)]),
        "resource": .object(["kind": .string("job"), "id": .string(jobID)]),
        "reasonCode": .string(unknown ? "recovery.outcomeUnknown" : "job.resultAvailable"),
      ])
    }
    return .object([
      "schemaVersion": .string("arkdeck.job-status/1"),
      "jobId": .string(jobID),
      "operation": .string(request.operation.reference),
      "targetId": .string(request.target.targetID),
      "state": .string(state.rawValue),
      "outcome": .string(unknown ? "outcomeUnknown" : state.rawValue),
      "waitingForHuman": .bool(waitingForHuman),
      "outcomeUnknown": .bool(unknown),
      "outstandingResidueCount": .integer(residue),
      "executionMode": .string("execute"),
      "sessionId": .string("session-source"),
      "threadId": request.clientContext?.threadID.map(JSONValue.string) ?? .null,
      "workspaceKind": .null,
      "actualEffect": .string(effect.rawValue),
      "createdAtUtc": .string("2026-09-01T00:00:00Z"),
      "startedAtUtc": .string("2026-09-01T00:00:01Z"),
      "finishedAtUtc": .string("2026-09-01T00:00:02Z"),
      "supersededByRecoveryEpochId": superseded.map(JSONValue.string) ?? .null,
      "recoveryEpochId": .null,
      "resolvedByTargetAliasResolutionId": .null,
      "nextAction": nextAction,
      "failure": .null,
      "processProgress": .null,
    ])
  }

  private func show(
    jobID: String? = nil,
    request: RuntimeOperationRequest,
    effect: WorkflowEffect,
    catalogDigest: String = RuntimeOperationCatalog.catalogDigest,
    binding: Int? = 3,
    stableIdentity: String? = nil,
    state: JobState = .succeeded,
    unknown: Bool = false,
    waitingForHuman: Bool = false,
    residue: Int64 = 0,
    superseded: String? = nil
  ) throws -> JSONValue {
    let id = jobID ?? sourceJobID
    return .object([
      "schemaVersion": .string("arkdeck.job/1"),
      "job": status(
        jobID: id, request: request, effect: effect, state: state,
        unknown: unknown, waitingForHuman: waitingForHuman,
        residue: residue, superseded: superseded),
      "request": try json(request),
      "catalogDigest": .string(catalogDigest),
      "providerId": .string(effect == .hostOnly ? "workspace" : "hdc"),
      "materializedPlanDigest": .null,
      "materializedBindingRevision": binding.map { .integer(Int64($0)) } ?? .null,
      "materializedStableIdentitySha256":
        stableIdentity.map(JSONValue.string) ?? (binding == nil ? .null : .string(identity)),
      "actualStepKinds": .array([]),
      "timeline": .object(["kind": .string("inline"), "entries": .array([])]),
      "events": .object(["method": .string("job.events"), "jobId": .string(id)]),
      "evidence": .object(["method": .string("job.evidence"), "jobId": .string(id)]),
      "ringCoverage": .null,
      "screenSequence": .null,
    ])
  }

  private func health(
    _ digest: String = RuntimeOperationCatalog.catalogDigest,
    providers: [String] = ["hdc", "workspace"]
  ) -> JSONValue {
    .object([
      "status": .string("ok"),
      "protocolVersion": .string(ArkDeckControlProtocol.targetVersion),
      "supportedExactVersions": .array(
        ArkDeckControlProtocol.supportedExactVersions.map(JSONValue.string)),
      "publishedMethods": .array(
        ArkDeckControlProtocol.targetMethods.sorted().map(JSONValue.string)),
      "catalogDigest": .string(digest),
      "providers": .array(providers.map(JSONValue.string)),
    ])
  }

  private func target(revision: Int = 3, stableIdentity: String? = nil) -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.target/1"),
      "targetId": .string(targetID),
      "bindingRevision": .integer(Int64(revision)),
      "toolVersion": .string("3.2.0f"),
      "adoptedAtUtc": .string("2026-09-01T00:00:00Z"),
      "connectKey": .string("fixture-connect-key"),
      "stablePhysicalIdentitySha256": .string(stableIdentity ?? identity),
      "live": .null,
      "observedFacts": .null,
    ])
  }

  func testRegistryPublishesAllThreeStableContinuationLeaves() throws {
    for (verb, requiresIdentity) in [("inspect", false), ("submit", true), ("run", true)] {
      var argv = ["workspace", "continuation", verb, "--source-job", sourceJobID]
      if requiresIdentity { argv += ["--continuation-request-id", "continue-001"] }
      guard case .success(.dispatch(let path, let leaf, _)) = CLIArgumentParser.parse(argv) else {
        return XCTFail("continuation leaf did not parse: \(verb)")
      }
      XCTAssertEqual(path, ["workspace", "continuation", verb])
      XCTAssertEqual(leaf.canonicalCommand, "workspace.continuation.\(verb)")
      XCTAssertTrue(leaf.connectsToRuntime)
      XCTAssertNil(leaf.catalogOperation, "continuation reconstructs a request; it is not an operation")
    }
    guard case .failure(let missing) = CLIArgumentParser.parse([
      "workspace", "continuation", "run", "--source-job", sourceJobID,
    ]) else { return XCTFail("run accepted no stable identity") }
    XCTAssertEqual(missing.code, .invalidOption)
  }

  func testDeviceContinuationRechecksBindingAndBuildsAnAuthorityFreeFreshRequest() throws {
    let source = try request()
    let draft = try CLIWorkspaceContinuationDraft.prepare(
      sourceJobID: sourceJobID,
      jobShow: try show(request: source, effect: .readOnly),
      health: health(),
      targetShow: target(),
      session: session())
    XCTAssertEqual(draft.bindingRevision, 3)
    XCTAssertEqual(draft.stablePhysicalIdentitySHA256, identity)
    XCTAssertTrue(draft.requiresCurrentTarget)

    let fresh = try draft.request(
      continuationRequestID: "continue-001", session: session("workspace.continuation.submit"))
    XCTAssertEqual(fresh.requestID, "continue-001")
    XCTAssertEqual(fresh.idempotencyKey, "continue-001")
    XCTAssertEqual(fresh.operation, source.operation)
    XCTAssertEqual(fresh.target, source.target)
    XCTAssertEqual(fresh.inputs, source.inputs)
    XCTAssertEqual(fresh.clientContext?.threadID, "thread-continuation")
    XCTAssertEqual(fresh.clientContext?.provenance?["arkdeck.continuedFromJob"], sourceJobID)
    XCTAssertNil(fresh.authorization)
    XCTAssertNil(fresh.campaignReservation)
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: CanonicalJSONEncoders.canonical().encode(fresh))
        as? [String: Any])
    XCTAssertNil(document["sessionId"])
    XCTAssertNil(document["authorization"])
    XCTAssertNil(document["campaignReservation"])
  }

  func testHostOnlyContinuationNeedsNoDurableDeviceAndStillPinsTheCatalog() throws {
    let source = try request(
      operation: "workspace.inspect-git-status",
      target: "host-workspace",
      binding: nil,
      inputs: ["projectRef": .string("project-1")])
    let sourceShow = try show(
      request: source, effect: .hostOnly, binding: nil, stableIdentity: nil)
    XCTAssertFalse(
      try CLIWorkspaceContinuationDraft.sourceRequiresCurrentTarget(
        sourceShow, sourceJobID: sourceJobID, session: session()))
    let draft = try CLIWorkspaceContinuationDraft.prepare(
      sourceJobID: sourceJobID,
      jobShow: sourceShow,
      health: health(),
      targetShow: nil,
      session: session())
    XCTAssertEqual(draft.effectiveEffect, .hostOnly)
    XCTAssertNil(draft.bindingRevision)
    XCTAssertNil(draft.stablePhysicalIdentitySHA256)
  }

  func testUnsafeSourceFactsFailClosedBeforeAContinuationIdentityExists() throws {
    let readOnly = try request()
    let mutation = try request(
      operation: "workspace.build-openharmony",
      target: "host-workspace",
      binding: nil,
      inputs: [
        "projectRef": .string("project-1"),
        "buildPresetRef": .string("build-preset-1"),
      ])
    let authoritative = try request(
      authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-FIXTURE"))
    let cases: [(JSONValue, JSONValue, JSONValue?, CLIErrorCode)] = [
      (
        try show(request: readOnly, effect: .readOnly, unknown: true),
        health(), target(), .admissionDenied
      ),
      (
        try show(request: readOnly, effect: .readOnly, waitingForHuman: true),
        health(), target(), .admissionDenied
      ),
      (
        try show(request: readOnly, effect: .readOnly, residue: 1),
        health(), target(), .admissionDenied
      ),
      (
        try show(request: mutation, effect: .deviceMutation, binding: nil),
        health(), nil, .admissionDenied
      ),
      (
        try show(request: authoritative, effect: .readOnly),
        health(), target(), .admissionDenied
      ),
      (
        try show(request: readOnly, effect: .readOnly),
        health(String(repeating: "c", count: 64)), target(), .factsDrifted
      ),
      (
        try show(request: readOnly, effect: .readOnly),
        health(), target(revision: 4), .bindingRevisionStale
      ),
      (
        try show(request: readOnly, effect: .readOnly),
        health(providers: ["workspace"]), target(), .operationUnavailable
      ),
    ]
    for (jobShow, health, targetShow, code) in cases {
      XCTAssertThrowsError(
        try CLIWorkspaceContinuationDraft.prepare(
          sourceJobID: sourceJobID, jobShow: jobShow, health: health,
          targetShow: targetShow, session: session()))
      { error in
        XCTAssertEqual((error as? CLIRegistryError)?.code, code)
      }
    }
  }

  func testAcceptedJobMustContainTheExactFreshRequestAndMaterializedBinding() throws {
    let source = try request()
    let draft = try CLIWorkspaceContinuationDraft.prepare(
      sourceJobID: sourceJobID,
      jobShow: try show(request: source, effect: .readOnly),
      health: health(), targetShow: target(), session: session())
    let expected = try draft.request(
      continuationRequestID: "continue-001", session: session("workspace.continuation.submit"))
    let accepted = try show(
      jobID: "job-continuation-new", request: expected, effect: .readOnly)
    let job = try draft.validateAcceptedJob(
      accepted, jobID: "job-continuation-new", expectedRequest: expected,
      session: session("workspace.continuation.submit"))
    guard case .object(let status) = job else { return XCTFail("no accepted Job status") }
    XCTAssertEqual(status["jobId"], .string("job-continuation-new"))

    let conflicting = try draft.request(
      continuationRequestID: "continue-002", session: session("workspace.continuation.submit"))
    XCTAssertThrowsError(
      try draft.validateAcceptedJob(
        accepted, jobID: "job-continuation-new", expectedRequest: conflicting,
        session: session("workspace.continuation.submit")))
    { error in
      XCTAssertEqual((error as? CLIRegistryError)?.code, .idempotencyConflict)
    }
  }
}
