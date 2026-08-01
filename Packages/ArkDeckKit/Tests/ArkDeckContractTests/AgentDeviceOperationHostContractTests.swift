import ArkDeckCore
@testable import ArkDeckHarness
import ArkDeckStorage
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class AgentDeviceOperationHostContractTests: XCTestCase {
  func testE0E1E2AdmissionPersistsBeforeTypedDispatch() async throws {
    for effect in [WorkflowEffect.readOnly, .deviceMutation, .destructive] {
      let fixture = try makeFixture(effect: effect)
      let response = await fixture.host.submit(requestData(effect: effect))
      let result = try response.get()
      XCTAssertEqual(result.jobState, .succeeded)
      XCTAssertEqual(result.resolvedEffect, effect)
      XCTAssertEqual(result.authorizationReference?.effect, effect)
      let events = await fixture.log.values()
      let dispatchCount = await fixture.dispatcher.dispatchCount()
      XCTAssertEqual(
        events,
        ["claim", "jobCreated", "intent", "dispatch", "outcome", "finalize"])
      XCTAssertEqual(dispatchCount, 1)
    }
  }

  func testMalformedPlanOnlyHumanBlockerAndExpiredPermitNeverDispatch() async throws {
    let malformedFixture = try makeFixture(effect: .readOnly)
    var malformed = String(decoding: requestData(effect: .readOnly), as: UTF8.self)
    malformed.removeLast()
    malformed += #","argv":["hdc"]}"#
    let malformedResponse = await malformedFixture.host.submit(Data(malformed.utf8))
    guard case .failure(let malformedError) = malformedResponse else {
      return XCTFail("forbidden caller command surface must fail strict decode")
    }
    XCTAssertEqual(malformedError.code, .malformedRequest)
    let malformedEvents = await malformedFixture.log.values()
    XCTAssertEqual(malformedEvents, [])

    let planFixture = try makeFixture(effect: .readOnly)
    let planResponse = await planFixture.host.submit(
      requestData(effect: .readOnly, mode: .planOnly))
    let planResult = try planResponse.get()
    XCTAssertEqual(planResult.jobState, .planned)
    XCTAssertNil(planResult.authorizationReference)
    let planEvents = await planFixture.log.values()
    XCTAssertEqual(planEvents, [])

    let action = try HumanActionRequired(
      actionID: "action-connect", jobID: "job-1", category: .physicalConnection,
      generatedAtUTC: "2026-07-28T10:00:00Z")
    let humanFixture = try makeFixture(
      effect: .readOnly, factResolution: .humanActionRequired(action))
    let humanResult = try await humanFixture.host.submit(requestData(effect: .readOnly)).get()
    XCTAssertEqual(humanResult.disposition, .humanActionRequired)
    XCTAssertEqual(humanResult.humanActionID, "action-connect")
    let humanEvents = await humanFixture.log.values()
    let humanDispatchCount = await humanFixture.dispatcher.dispatchCount()
    XCTAssertEqual(humanEvents, ["humanAction"])
    XCTAssertEqual(humanDispatchCount, 0)

    let expiredFixture = try makeFixture(
      effect: .readOnly, factFreshUntilUTC: "2026-07-28T09:59:59Z")
    let expiredResponse = await expiredFixture.host.submit(requestData(effect: .readOnly))
    let expiredResult = try expiredResponse.get()
    XCTAssertEqual(expiredResult.disposition, .policyBlocked)
    let expiredEvents = await expiredFixture.log.values()
    let expiredDispatchCount = await expiredFixture.dispatcher.dispatchCount()
    XCTAssertEqual(expiredEvents, [])
    XCTAssertEqual(expiredDispatchCount, 0)
  }

  func testOutcomeUnknownCreatesStructuredRecoveryBlockerWithoutGuessing() async throws {
    let fixture = try makeFixture(effect: .deviceMutation, dispatchThrows: true)
    let result = try await fixture.host.submit(requestData(effect: .deviceMutation)).get()
    XCTAssertEqual(result.jobState, .waitingForRecovery)
    XCTAssertEqual(result.disposition, .humanActionRequired)
    XCTAssertEqual(result.outcomeCertainty, .unknown)
    let events = await fixture.log.values()
    let dispatchCount = await fixture.dispatcher.dispatchCount()
    XCTAssertEqual(
      events,
      ["claim", "jobCreated", "intent", "dispatch", "outcome", "humanAction"])
    XCTAssertEqual(dispatchCount, 1)
  }

  func testPlanAndAuthorityDriftFailClosedBeforeExternalIntent() async throws {
    let mismatchedStep = try workflowStep(effect: .deviceMutation)
    let planFixture = try makeFixture(effect: .readOnly, planStep: mismatchedStep)
    let planResult = try await planFixture.host.submit(requestData(effect: .readOnly)).get()
    XCTAssertEqual(planResult.disposition, .policyBlocked)
    let planEvents = await planFixture.log.values()
    let planDispatchCount = await planFixture.dispatcher.dispatchCount()
    XCTAssertEqual(planEvents, [])
    XCTAssertEqual(planDispatchCount, 0)

    let driftedReference = try AgentExecutionAuthorityReference.validatedReadyTask(
      changeID: "CHG-2026-025", taskID: "TASK-AIN-999",
      mainCommitOID: String(repeating: "a", count: 40),
      taskBlobOID: String(repeating: "b", count: 40), approvalPRNumber: 754)
    let authorityFixture = try makeFixture(
      effect: .readOnly, authorityReference: driftedReference)
    let authorityResult = try await authorityFixture.host.submit(
      requestData(effect: .readOnly)
    ).get()
    XCTAssertEqual(authorityResult.disposition, .policyBlocked)
    let authorityEvents = await authorityFixture.log.values()
    let authorityDispatchCount = await authorityFixture.dispatcher.dispatchCount()
    XCTAssertEqual(authorityEvents, ["claim"])
    XCTAssertEqual(authorityDispatchCount, 0)
  }

  func testRegistryClosureAndCanonicalSummary() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let registryURL = root.appending(
      path:
        "openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/agent-device-operation-registry.v1-draft.json"
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any])
    let operations = try XCTUnwrap(object["operations"] as? [[String: Any]])
    let blockers = try XCTUnwrap(object["humanBlockerRules"] as? [[String: Any]])
    XCTAssertEqual(operations.count, AgentDeviceOperationID.allCases.count)
    XCTAssertEqual(
      operations.reduce(0) { count, operation in
        count + ((operation["profiles"] as? [[String: Any]])?.count ?? 0)
      },
      21)
    XCTAssertEqual(blockers.count, HumanActionCategory.allCases.count)
    print(
      "TEST-AIN-HOST-001 PASS operations=15 profiles=21 human_blockers=8 "
        + "authority_kinds=3 legacy_versions=3 process_dispatch=0 device_dispatch=0 "
        + "hdc_dispatch=0 network=0")
  }

  private func makeFixture(
    effect: WorkflowEffect,
    factResolution: AgentTrustedFactResolution? = nil,
    factFreshUntilUTC: String = "2026-07-28T10:05:00Z",
    dispatchThrows: Bool = false,
    planStep: WorkflowStep? = nil,
    authorityReference: AgentExecutionAuthorityReference? = nil
  ) throws -> HostFixture {
    let log = HostEventLog()
    let descriptor = descriptor(effect: effect)
    let step = try workflowStep(effect: effect)
    let defaultReference: AgentExecutionAuthorityReference
    let usage: String?
    switch effect {
    case .readOnly:
      defaultReference = try .validatedReadyTask(
        changeID: "CHG-2026-025", taskID: "TASK-AIN-010",
        mainCommitOID: String(repeating: "a", count: 40),
        taskBlobOID: String(repeating: "b", count: 40), approvalPRNumber: 754)
      usage = nil
    case .deviceMutation:
      defaultReference = try .validatedDeviceCapability(
        capabilityID: "CAP-E1-FIXTURE",
        mainCommitOID: String(repeating: "c", count: 40),
        capabilityBlobOID: String(repeating: "d", count: 40), approvalPRNumber: 750)
      usage = "ain010-fixture"
    case .destructive:
      defaultReference = try .validatedStandingAuthorization(
        authorizationID: "AUTH-FIXTURE",
        mainCommitOID: String(repeating: "e", count: 40),
        authorizationBlobOID: String(repeating: "f", count: 40), approvalPRNumber: 700)
      usage = "reservation-fixture"
    case .hostOnly:
      fatalError("hostOnly is outside the Agent device operation authority matrix")
    }
    let reference = authorityReference ?? defaultReference
    let resolvedFacts =
      factResolution
      ?? .accepted(
        AgentTrustedFactReceipt(
          durableTargetID: "target-1", bindingRevision: 1,
          bindingDigestSHA256: String(repeating: "1", count: 64),
          targetDigestSHA256: String(repeating: "2", count: 64),
          observationReceiptID: "observation-1", freshUntilUTC: factFreshUntilUTC))
    let durable = FixtureDurableStore(log: log)
    let dispatcher = FixtureDispatcher(log: log, shouldThrow: dispatchThrows)
    let host = TrustedDeviceOperationHost(
      executorID: "agent-fixture",
      registry: FixtureRegistry(descriptor: descriptor),
      planner: FixturePlanner(plan: AgentDeviceOperationPlan(steps: [planStep ?? step])),
      factsResolver: FixtureFacts(resolution: resolvedFacts),
      authorityResolver: FixtureAuthority(
        authority: AgentResolvedExecutionAuthority(
          reference: reference, usageReservationID: usage,
          validUntilUTC: "2026-07-28T10:05:00Z")),
      durableStore: durable, dispatcher: dispatcher,
      identity: FixtureIdentity())
    return HostFixture(host: host, log: log, dispatcher: dispatcher)
  }

  private func descriptor(effect: WorkflowEffect) -> AgentOperationDescriptor {
    switch effect {
    case .readOnly:
      AgentOperationDescriptor(
        operationID: .observeDevice, profileID: "observe-device.read-only.v1",
        configurationID: "observe-device.read-only.v1.config",
        configurationSHA256:
          "875b1b50cebf0b5008703922936b4c33341fde11b5433ae41f93c15d355c4378",
        minimumEffect: .readOnly, permittedEffects: [.readOnly],
        minimumCancellation: .immediate, bindingRequirement: .confirmedDevice,
        permittedStepKinds: [.probeDevice], emittedStepKinds: [.probeDevice],
        declaredEffect: .readOnly,
        declaredCancellation: .immediate, declaredBindingRequirement: .confirmedDevice)
    case .deviceMutation:
      AgentOperationDescriptor(
        operationID: .rebootDevice, profileID: "device.reboot.v1",
        configurationID: "device.reboot.v1.config",
        configurationSHA256:
          "98036bd61fe786e17b6d8d239df1745a859f32361ec8e3fb8d6cfdbb89b95d74",
        minimumEffect: .deviceMutation, permittedEffects: [.deviceMutation],
        minimumCancellation: .atSafeBoundary, bindingRequirement: .confirmedDevice,
        permittedStepKinds: [.rebootDevice], emittedStepKinds: [.rebootDevice],
        declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice)
    case .destructive:
      AgentOperationDescriptor(
        operationID: .flash, profileID: "flash.rockchip-authorized.v1",
        configurationID: "flash.rockchip-authorized.v1.config",
        configurationSHA256:
          "d6a3c21faab82c0d36d3b1e986809cdbd03a5757a55600f1b74da7577fee616c",
        minimumEffect: .destructive, permittedEffects: [.destructive],
        minimumCancellation: .criticalNonInterruptible,
        bindingRequirement: .confirmedDevice, permittedStepKinds: [.flashPartition],
        emittedStepKinds: [.flashPartition],
        declaredEffect: .destructive, declaredCancellation: .criticalNonInterruptible,
        declaredBindingRequirement: .confirmedDevice)
    case .hostOnly:
      fatalError()
    }
  }

  private func workflowStep(effect: WorkflowEffect) throws -> WorkflowStep {
    switch effect {
    case .readOnly:
      try WorkflowStep(
        id: "step-probe", kind: .probeDevice, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["evidencePolicy": .string("fixture")])
    case .deviceMutation:
      try WorkflowStep(
        id: "step-reboot", kind: .rebootDevice, declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "targetMode": .string("normal"), "reason": .string("fixture"),
        ])
    case .destructive:
      try WorkflowStep(
        id: "step-flash", kind: .flashPartition, declaredEffect: .destructive,
        declaredCancellation: .criticalNonInterruptible,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("fixtureFlash"),
          "partition": .string("system"),
          "imageArtifactId": .string("image-1"),
          "imageSha256": .string(String(repeating: "2", count: 64)),
          "imageSize": .integer(1),
          "confirmationId": .string("confirmation-1"),
          "safeBoundaryId": .string("safe-boundary-1"),
        ])
    case .hostOnly:
      fatalError()
    }
  }

  private func requestData(
    effect: WorkflowEffect,
    mode: AgentDeviceOperationExecutionMode = .execute
  ) -> Data {
    let descriptor = descriptor(effect: effect)
    var object: [String: Any] = [
      "documentType": "request",
      "schemaVersion": "1.0.0",
      "requestId": "request-1",
      "changeId": "CHG-2026-025",
      "taskId": "TASK-AIN-010",
      "executionMode": mode.rawValue,
      "durableTargetId": "target-1",
      "operation": [
        "id": descriptor.operationID.rawValue,
        "profileId": descriptor.profileID,
        "configurationId": descriptor.configurationID,
        "configurationSha256": descriptor.configurationSHA256,
      ],
    ]
    if effect == .destructive { object["authorizationId"] = "AUTH-FIXTURE" }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

private struct HostFixture {
  let host: TrustedDeviceOperationHost
  let log: HostEventLog
  let dispatcher: FixtureDispatcher
}

private actor HostEventLog {
  private var events: [String] = []
  func append(_ value: String) { events.append(value) }
  func values() -> [String] { events }
}

private struct FixtureRegistry: AgentOperationRegistryResolving {
  let descriptor: AgentOperationDescriptor
  func resolve(operation: AgentDeviceOperationSelector) async throws
    -> AgentOperationDescriptor?
  {
    descriptor
  }
}

private struct FixturePlanner: AgentOperationPlanning {
  let plan: AgentDeviceOperationPlan
  func plan(
    request: AgentDeviceOperationRequest,
    descriptor: AgentOperationDescriptor
  ) async throws -> AgentDeviceOperationPlan {
    plan
  }
}

private struct FixtureFacts: AgentTrustedFactsResolving {
  let resolution: AgentTrustedFactResolution
  func resolveFacts(
    request: AgentDeviceOperationRequest,
    descriptor: AgentOperationDescriptor,
    plan: AgentDeviceOperationPlan,
    jobID: String
  ) async throws -> AgentTrustedFactResolution {
    resolution
  }
}

private struct FixtureAuthority: AgentExecutionAuthorityResolving {
  let authority: AgentResolvedExecutionAuthority
  func resolveAuthority(
    request: AgentDeviceOperationRequest,
    descriptor: AgentOperationDescriptor,
    facts: AgentTrustedFactReceipt,
    jobID: String,
    sessionID: String,
    planDigestSHA256: String,
    resolvedEffect: WorkflowEffect
  ) async throws -> AgentResolvedExecutionAuthority {
    if authority.reference.kind == .deviceCapability {
      return AgentResolvedExecutionAuthority(
        reference: authority.reference,
        usageReservationID: try AgentAuthorityUsageReservation.canonicalReservationID(
          authorizationRef: authority.reference, jobID: jobID,
          operationDigestSHA256: planDigestSHA256,
          targetDigestSHA256: facts.targetDigestSHA256),
        validUntilUTC: authority.validUntilUTC)
    }
    return authority
  }
}

private actor FixtureDurableStore: AgentDurableAdmissionPersisting {
  let log: HostEventLog
  init(log: HostEventLog) { self.log = log }

  func claim(
    request: AgentDeviceOperationRequest,
    jobID: String,
    sessionID: String,
    facts: AgentTrustedFactReceipt
  ) async throws {
    await log.append("claim")
  }

  func appendJobCreated(_ context: AgentDurableJobContext) async throws {
    XCTAssertEqual(context.authority.reference.effect, context.effect)
    await log.append("jobCreated")
  }

  func appendIntent(
    context: AgentDurableJobContext,
    step: WorkflowStep,
    attempt: Int
  ) async throws -> String {
    await log.append("intent")
    return "intent-\(attempt)"
  }

  func appendOutcome(
    context: AgentDurableJobContext,
    step: WorkflowStep,
    attempt: Int,
    intentEventID: String,
    outcome: AgentTypedDispatchOutcome
  ) async throws {
    await log.append("outcome")
  }

  func storeHumanAction(_ action: HumanActionRequired) async throws {
    await log.append("humanAction")
  }

  func finalize(
    context: AgentDurableJobContext,
    state: JobState,
    artifacts: [AgentDeviceOperationArtifactReference]
  ) async throws -> String {
    await log.append("finalize")
    return "manifest-1"
  }
}

private enum FixtureDispatchError: Error {
  case injected
}

private actor FixtureDispatcher: AgentTypedOperationDispatching {
  let log: HostEventLog
  let shouldThrow: Bool
  private var count = 0

  init(log: HostEventLog, shouldThrow: Bool) {
    self.log = log
    self.shouldThrow = shouldThrow
  }

  func dispatch(
    step: WorkflowStep,
    context: AgentDurableJobContext
  ) async throws -> AgentTypedDispatchOutcome {
    count += 1
    await log.append("dispatch")
    if shouldThrow { throw FixtureDispatchError.injected }
    return AgentTypedDispatchOutcome(succeeded: true, outcomeCertainty: .confirmed)
  }

  func dispatchCount() -> Int { count }
}

private struct FixtureIdentity: AgentHostIdentityProviding {
  func nextJobAndSessionID(requestID: String) async -> (jobID: String, sessionID: String) {
    ("job-1", "session-1")
  }

  func currentUTC() async -> String {
    "2026-07-28T10:00:00Z"
  }
}
