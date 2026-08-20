import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeDebugInvocationContractTests: XCTestCase {
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) { self.value = value }
    func now() -> String { lock.withLock { value } }
    func set(_ value: String) { lock.withLock { self.value = value } }
  }

  private actor ScriptedDriver: RuntimeDebugAttemptDriving {
    private var outcomes: [RuntimeDebugExecutionOutcome]
    private let permitStateDirectory: URL?
    private var executedRequests: [RuntimeOperationRequest] = []
    private var prepareCount = 0

    init(
      outcomes: [RuntimeDebugExecutionOutcome],
      permitStateDirectory: URL? = nil
    ) {
      self.outcomes = outcomes
      self.permitStateDirectory = permitStateDirectory
    }

    func prepare(_ requestData: Data) async throws -> RuntimePlanOnlyPreview {
      let request = try RuntimeOperationCodec.decodeRequest(requestData)
      prepareCount += 1
      return RuntimePlanOnlyPreview(
        executionMode: "planOnly",
        operationReference: request.operation.reference,
        targetID: request.target.targetID,
        bindingRevision: request.target.expectedBindingRevision,
        stableIdentitySHA256: String(repeating: "c", count: 64),
        providerID: "rockchip",
        catalogDigest: String(repeating: "d", count: 64),
        requestFingerprintSHA256: String(repeating: "e", count: 64),
        materializedPlanDigest: String(repeating: "f", count: 64),
        inputs: request.inputs,
        steps: [
          RuntimePlanOnlyStep(
            stepID: "step-preview", kind: "test",
            effect: request.operation.id == "flash.dayu200"
              ? WorkflowEffect.destructive.rawValue : WorkflowEffect.readOnly.rawValue,
            cancellation: "atSafeBoundary", binding: "exactTarget", isOptional: false)
        ],
        effectiveEffect: request.operation.id == "flash.dayu200"
          ? WorkflowEffect.destructive.rawValue : WorkflowEffect.readOnly.rawValue,
        authorizationPolicy: request.operation.id == "flash.dayu200"
          ? RuntimeOperationAuthorizationPolicy.runtimeCapability.rawValue
          : RuntimeOperationAuthorizationPolicy.defaultReadOnly.rawValue,
        providerAdmissionBlocker: nil,
        jobAdmitted: false, dispatchDisposition: "notDispatched")
    }

    func execute(_ requestData: Data) async -> RuntimeDebugDriverResult {
      do {
        let request = try RuntimeOperationCodec.decodeRequest(requestData)
        if let permitStateDirectory {
          _ = try RuntimeDebugAttemptPermitStore.loadExact(
            stateDirectory: permitStateDirectory, request: request,
            nowUTC: "2026-08-09T00:00:00Z")
        }
        executedRequests.append(request)
        let outcome = outcomes.isEmpty ? .failedKnown : outcomes.removeFirst()
        return RuntimeDebugDriverResult(
          jobID: outcome == .refused ? nil : "job-fake-\(executedRequests.count)",
          outcome: outcome, detail: "mechanical contract fake")
      } catch {
        return RuntimeDebugDriverResult(jobID: nil, outcome: .refused, detail: "\(error)")
      }
    }

    func requests() -> [RuntimeOperationRequest] { executedRequests }
    func preparations() -> Int { prepareCount }
  }

  private let observeAction = Data(
    #"{"schemaVersion":"1.0.0","action":"observePinnedRequest"}"#.utf8)
  private let executeAction = Data(
    #"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#.utf8)

  private func seedRequest() throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "debug-seed",
      idempotencyKey: "debug-seed-request",
      target: DurableTargetReference(
        targetID: "dayu200-selected", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200", version: nil),
      inputs: [
        "imageBundleLease": .string("artifact-lease-immutable"),
        "profileReference": .string("dayu200-rk3568@1"),
      ])
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private func provenance(_ ordinal: Int = 1) throws -> RuntimeDebugCandidateProvenance {
    try RuntimeDebugCandidateProvenance(
      sourceSHA256: String(format: "%064x", ordinal),
      buildSHA256: String(format: "%064x", ordinal + 100))
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "runtime-debug-invocation-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  func testNovelCandidateRevisionContinuesWithoutARepairKindOrMergeBoundary() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(
      outcomes: [.safeToReflash, .succeeded], permitStateDirectory: root)
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let seed = try seedRequest()
    let started = try await controller.start(seedRequestData: encode(seed))

    let observed = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: observeAction,
      provenance: provenance())
    XCTAssertEqual(observed.destructiveEpochsUsed, 0)
    XCTAssertEqual(observed.evaluations.last?.candidateAction, "observePinnedRequest")

    let first = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: executeAction,
      provenance: provenance())
    XCTAssertEqual(first.state, "active")
    XCTAssertEqual(first.evaluations.last?.disposition, "nextCandidateAllowed")

    let completed = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: executeAction,
      provenance: provenance(2))
    XCTAssertEqual(completed.state, "succeeded")
    XCTAssertEqual(completed.destructiveEpochsUsed, 2)

    let requests = await driver.requests()
    XCTAssertEqual(requests.count, 2)
    for request in requests {
      XCTAssertEqual(request.target, seed.target)
      XCTAssertEqual(request.operation, seed.operation)
      XCTAssertEqual(request.inputs, seed.inputs)
      XCTAssertNil(request.authorization)
      XCTAssertNil(request.campaignReservation)
      XCTAssertNil(request.clientContext)
    }
    XCTAssertNotEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
    XCTAssertThrowsError(
      try RuntimeDebugAttemptPermitStore.loadExact(
        stateDirectory: root, request: requests[1],
        nowUTC: "2026-08-09T00:10:00Z"),
      "a terminal invocation cannot be resubmitted outside its budget ledger")

    let reopened = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:10:00Z" })
    let reopenedStatus = try await reopened.status(invocationID: started.invocationID)
    XCTAssertEqual(reopenedStatus, completed)
  }

  func testBrokerRejectsOrdinaryDebugSeedsAndNamesThePublishedJobSurface() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.succeeded], permitStateDirectory: root)
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let seed = try RuntimeOperationRequest(
      requestID: "observe-seed",
      idempotencyKey: "observe-seed-request",
      target: DurableTargetReference(
        targetID: "dayu200-selected", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "observe.device", version: 1))
    do {
      _ = try await controller.start(seedRequestData: encode(seed))
      XCTFail("ordinary read-only debugging belongs to the published job surface")
    } catch let error as RuntimeDebugInvocationError {
      guard case .invalidSeedRequest(let detail) = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertTrue(detail.contains("ordinary Agent debugging"))
      XCTAssertTrue(detail.contains("published job surface"))
    }
    let preparationCount = await driver.preparations()
    let dispatchedRequests = await driver.requests()
    XCTAssertEqual(preparationCount, 1)
    XCTAssertTrue(dispatchedRequests.isEmpty)
  }

  func testCandidateCannotInjectAuthorityTargetPlanArgvTimingOrAlternative() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.succeeded])
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))

    for forbidden in [
      "target", "plan", "argv", "capability", "outcome", "timing", "alternativeId",
    ] {
      let candidate =
        "{\"schemaVersion\":\"1.0.0\",\"action\":\"executePinnedRequest\","
        + "\"\(forbidden)\":\"forged\"}"
      do {
        _ = try await controller.evaluate(
          invocationID: started.invocationID,
          actionData: Data(candidate.utf8), provenance: provenance())
        XCTFail("\(forbidden) must fail closed")
      } catch let error as RuntimeDebugInvocationError {
        guard case .invalidCandidate = error else {
          return XCTFail("unexpected error \(error)")
        }
      }
    }
    let rejectedRequests = await driver.requests()
    XCTAssertTrue(rejectedRequests.isEmpty)
  }

  func testKnownPostEffectFailureBlocksEveryLaterCandidate() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.failedKnown, .succeeded])
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))
    let blocked = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: executeAction,
      provenance: provenance())
    XCTAssertEqual(blocked.state, "blocked")

    do {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        actionData: executeAction,
        provenance: provenance(2))
      XCTFail("known post-effect failure must block continuation")
    } catch let error as RuntimeDebugInvocationError {
      XCTAssertEqual(error, .invocationNotActive("blocked"))
    }
    let blockedRequests = await driver.requests()
    XCTAssertEqual(blockedRequests.count, 1)
  }

  func testSixteenDestructiveEpochBudgetIsEnforcedAcrossArbitraryBuilds() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: Array(repeating: .safeToReflash, count: 17))
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))

    for ordinal in 1...16 {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        actionData: executeAction, provenance: provenance(ordinal))
    }
    do {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        actionData: executeAction, provenance: provenance(17))
      XCTFail("seventeenth destructive epoch must be refused")
    } catch let error as RuntimeDebugInvocationError {
      XCTAssertEqual(error, .epochBudgetExhausted)
    }
    let boundedRequests = await driver.requests()
    XCTAssertEqual(boundedRequests.count, 16)
  }

  func testRuntimePermitPinsExactRequestWithoutCandidateTuning() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = try seedRequest()
    let actionSHA = String(repeating: "a", count: 64)
    try RuntimeDebugAttemptPermitStore.persist(
      stateDirectory: root, invocationID: "debug-test",
      request: request, candidateActionSHA256: actionSHA)

    let admitted = try RuntimeOperationRequest(
      requestID: request.requestID,
      idempotencyKey: request.idempotencyKey,
      target: request.target,
      operation: request.operation,
      inputs: request.inputs,
      requestedOutputs: request.requestedOutputs,
      authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-DEBUG-TEST"))
    XCTAssertEqual(
      try RuntimeDebugAttemptPermitStore.loadExact(
        stateDirectory: root, request: admitted)?.candidateActionSHA256,
      actionSHA)

    let drifted = try RuntimeOperationRequest(
      requestID: request.requestID,
      idempotencyKey: request.idempotencyKey,
      target: request.target,
      operation: request.operation,
      inputs: request.inputs.merging(["forged": .bool(true)]) { _, new in new },
      requestedOutputs: request.requestedOutputs,
      authorization: admitted.authorization)
    XCTAssertThrowsError(
      try RuntimeDebugAttemptPermitStore.loadExact(
        stateDirectory: root, request: drifted))
  }

  func testUnknownOutcomeCanOnlyReachProtectedRuntimeAsANewCandidate() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.outcomeUnknown, .succeeded])
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))
    let unknown = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: executeAction,
      provenance: provenance())
    XCTAssertEqual(
      unknown.evaluations.last?.disposition, "awaitingRuntimeRecoveryProof")

    let recovered = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: executeAction,
      provenance: provenance())
    XCTAssertEqual(recovered.state, "succeeded")
    let requests = await driver.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertNotEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
  }

  func testRefusalBeforeDispatchIsFreeAndDoesNotCloseTheInvocation() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.refused, .succeeded])
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))

    let refused = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: executeAction, provenance: provenance())
    XCTAssertEqual(refused.state, "active")
    XCTAssertEqual(refused.destructiveEpochsUsed, 0)
    XCTAssertNil(refused.evaluations.last?.destructiveEpoch)

    let completed = try await controller.evaluate(
      invocationID: started.invocationID,
      actionData: executeAction, provenance: provenance(2))
    XCTAssertEqual(completed.state, "succeeded")
    XCTAssertEqual(completed.destructiveEpochsUsed, 1)
  }

  func testUnknownProblemVocabularyAndElapsedFourHoursDispatchZero() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.succeeded])
    let clock = Clock("2026-08-09T00:00:00Z")
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver, nowUTC: clock.now)
    let started = try await controller.start(seedRequestData: encode(seedRequest()))

    do {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        actionData: Data(
          #"{"schemaVersion":"1.0.0","action":"fixNewProblemType"}"#.utf8),
        provenance: provenance())
      XCTFail("problem vocabulary must not cross the effect broker")
    } catch let error as RuntimeDebugInvocationError {
      guard case .invalidCandidate = error else {
        return XCTFail("unexpected error \(error)")
      }
    }

    clock.set("2026-08-09T04:00:01Z")
    do {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        actionData: executeAction,
        provenance: provenance(2))
      XCTFail("elapsed four-hour budget must refuse evaluation")
    } catch let error as RuntimeDebugInvocationError {
      XCTAssertEqual(error, .invocationExpired)
    }
    let expiredRequests = await driver.requests()
    XCTAssertTrue(expiredRequests.isEmpty)
  }
}
