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
        steps: [], jobAdmitted: false, dispatchDisposition: "notDispatched")
    }

    func execute(_ requestData: Data) async -> RuntimeDebugDriverResult {
      do {
        let request = try RuntimeOperationCodec.decodeRequest(requestData)
        if let permitStateDirectory {
          _ = try RuntimeDebugAttemptTuningStore.loadExact(
            stateDirectory: permitStateDirectory, request: request,
            nowUTC: "2026-08-09T00:00:00Z")
        }
        executedRequests.append(request)
        let outcome = outcomes.isEmpty ? .failedKnown : outcomes.removeFirst()
        return RuntimeDebugDriverResult(
          jobID: "job-fake-\(executedRequests.count)", outcome: outcome,
          detail: "mechanical contract fake")
      } catch {
        return RuntimeDebugDriverResult(jobID: nil, outcome: .refused, detail: "\(error)")
      }
    }

    func requests() -> [RuntimeOperationRequest] { executedRequests }
    func preparations() -> Int { prepareCount }
  }

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

  private func provenance() throws -> RuntimeDebugCandidateProvenance {
    try RuntimeDebugCandidateProvenance(
      sourceSHA256: String(repeating: "a", count: 64),
      buildSHA256: String(repeating: "b", count: 64))
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("runtime-debug-invocation-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  func testOneInvocationContinuesAcrossSafeFailureWithoutMergeBoundary() async throws {
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
      candidateData: Data(
        #"{"schemaVersion":"1.0.0","kind":"requestPublishedObservation","observationId":"freshPlan"}"#.utf8),
      provenance: provenance())
    XCTAssertEqual(observed.destructiveEpochsUsed, 0)
    let preparationCount = await driver.preparations()
    XCTAssertEqual(preparationCount, 2)

    let first = try await controller.evaluate(
      invocationID: started.invocationID,
      candidateData: Data(
        #"{"schemaVersion":"1.0.0","kind":"usePublishedDefaults"}"#.utf8),
      provenance: provenance())
    XCTAssertEqual(first.state, "active")
    XCTAssertEqual(first.evaluations.last?.disposition, "nextCandidateAllowed")

    let completed = try await controller.evaluate(
      invocationID: started.invocationID,
      candidateData: Data(
        #"{"schemaVersion":"1.0.0","kind":"selectPublishedAlternative","alternativeId":"extendedPostflight"}"#.utf8),
      provenance: provenance())
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
      try RuntimeDebugAttemptTuningStore.loadExact(
        stateDirectory: root, request: requests[1],
        nowUTC: "2026-08-09T00:10:00Z"),
      "a terminal invocation cannot be resubmitted outside its budget ledger")

    let reopened = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:10:00Z" })
    let reopenedStatus = try await reopened.status(invocationID: started.invocationID)
    XCTAssertEqual(reopenedStatus, completed)
  }

  func testCandidateCannotInjectAuthorityTargetPlanOrArgv() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.succeeded])
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))

    for forbidden in ["target", "plan", "argv", "capability", "outcome"] {
      let candidate =
        "{\"schemaVersion\":\"1.0.0\",\"kind\":\"usePublishedDefaults\","
        + "\"\(forbidden)\":\"forged\"}"
      do {
        _ = try await controller.evaluate(
          invocationID: started.invocationID,
          candidateData: Data(candidate.utf8), provenance: provenance())
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

  func testOnlySafeToReflashOrUnknownRecoveryCanReachAnotherEpoch() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.failedKnown, .succeeded])
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))
    let blocked = try await controller.evaluate(
      invocationID: started.invocationID,
      candidateData: Data(
        #"{"schemaVersion":"1.0.0","kind":"usePublishedDefaults"}"#.utf8),
      provenance: provenance())
    XCTAssertEqual(blocked.state, "blocked")

    do {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        candidateData: Data(
          #"{"schemaVersion":"1.0.0","kind":"selectPublishedAlternative","alternativeId":"balancedDefaults"}"#.utf8),
        provenance: provenance())
      XCTFail("known unsafe failure must block continuation")
    } catch let error as RuntimeDebugInvocationError {
      XCTAssertEqual(error, .invocationNotActive("blocked"))
    }
    let blockedRequests = await driver.requests()
    XCTAssertEqual(blockedRequests.count, 1)
  }

  func testSixteenDestructiveEpochBudgetIsEnforced() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(
      outcomes: Array(repeating: .safeToReflash, count: 17))
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))

    for value in 15..<31 {
      let candidate =
        "{\"schemaVersion\":\"1.0.0\",\"kind\":\"boundedTiming\","
        + "\"parameter\":\"loaderDiscoveryTimeoutSeconds\",\"value\":\(value)}"
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        candidateData: Data(candidate.utf8), provenance: provenance())
    }
    do {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        candidateData: Data(
          #"{"schemaVersion":"1.0.0","kind":"selectPublishedAlternative","alternativeId":"fastLoaderDetection"}"#.utf8),
        provenance: provenance())
      XCTFail("seventeenth destructive epoch must be refused")
    } catch let error as RuntimeDebugInvocationError {
      XCTAssertEqual(error, .epochBudgetExhausted)
    }
    let boundedRequests = await driver.requests()
    XCTAssertEqual(boundedRequests.count, 16)
  }

  func testRuntimeMintedCapabilityKeepsExactDebugTuningButInputDriftFailsClosed() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = try seedRequest()
    let tuning = try AgentAuthorityCampaignExecutionTuning(
      loaderDiscoveryTimeoutSeconds: 60,
      loaderPollIntervalMilliseconds: 250,
      hdcCommandTimeoutSeconds: 20,
      readOnlyCommandTimeoutSeconds: 15)
    try RuntimeDebugAttemptTuningStore.persist(
      stateDirectory: root, invocationID: "debug-test",
      request: request, decisionSHA256: String(repeating: "a", count: 64),
      tuning: tuning)

    let admitted = try RuntimeOperationRequest(
      requestID: request.requestID,
      idempotencyKey: request.idempotencyKey,
      target: request.target,
      operation: request.operation,
      inputs: request.inputs,
      requestedOutputs: request.requestedOutputs,
      authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-DEBUG-TEST"))
    XCTAssertEqual(
      try RuntimeDebugAttemptTuningStore.loadExact(
        stateDirectory: root, request: admitted)?.tuning,
      tuning)

    let drifted = try RuntimeOperationRequest(
      requestID: request.requestID,
      idempotencyKey: request.idempotencyKey,
      target: request.target,
      operation: request.operation,
      inputs: request.inputs.merging(["forged": .bool(true)]) { _, new in new },
      requestedOutputs: request.requestedOutputs,
      authorization: admitted.authorization)
    XCTAssertThrowsError(
      try RuntimeDebugAttemptTuningStore.loadExact(
        stateDirectory: root, request: drifted))
  }

  func testUnknownOutcomeCanOnlyProceedAsANewRuntimeProvenRecoveryAttempt() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = ScriptedDriver(outcomes: [.outcomeUnknown, .succeeded])
    let controller = try RuntimeDebugInvocationController(
      stateDirectory: root, driver: driver,
      nowUTC: { "2026-08-09T00:00:00Z" })
    let started = try await controller.start(seedRequestData: encode(seedRequest()))
    let unknown = try await controller.evaluate(
      invocationID: started.invocationID,
      candidateData: Data(
        #"{"schemaVersion":"1.0.0","kind":"usePublishedDefaults"}"#.utf8),
      provenance: provenance())
    XCTAssertEqual(
      unknown.evaluations.last?.disposition, "awaitingRuntimeRecoveryProof")

    let recovered = try await controller.evaluate(
      invocationID: started.invocationID,
      candidateData: Data(
        #"{"schemaVersion":"1.0.0","kind":"selectPublishedAlternative","alternativeId":"patientModeTransition"}"#.utf8),
      provenance: provenance())
    XCTAssertEqual(recovered.state, "succeeded")
    let requests = await driver.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertNotEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
  }

  func testElapsedFourHoursAndEnvelopeMissDispatchZero() async throws {
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
        candidateData: Data(
          #"{"schemaVersion":"1.0.0","kind":"selectPublishedAlternative","alternativeId":"newExternalCommand"}"#.utf8),
        provenance: provenance())
      XCTFail("an envelope miss must stop with repairSurfaceInsufficient")
    } catch let error as RuntimeDebugInvocationError {
      XCTAssertEqual(error, .repairSurfaceInsufficient("newExternalCommand"))
    }

    clock.set("2026-08-09T04:00:01Z")
    do {
      _ = try await controller.evaluate(
        invocationID: started.invocationID,
        candidateData: Data(
          #"{"schemaVersion":"1.0.0","kind":"usePublishedDefaults"}"#.utf8),
        provenance: provenance())
      XCTFail("elapsed four-hour budget must refuse evaluation")
    } catch let error as RuntimeDebugInvocationError {
      XCTAssertEqual(error, .invocationExpired)
    }
    let requests = await driver.requests()
    XCTAssertTrue(requests.isEmpty)
  }
}
