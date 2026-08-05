// Revoked-capability contract tests (CHG-2026-025, TASK-AIN-019).
//
// Found in the GJ-5 real-device window. Revoking a `debug.hap` envelope did
// not stop the harness from naming it: the port that selects an installed
// grant tested uses, lineage, expiry, ceiling and operation scope — every
// field a revoked grant still satisfies — so the request carried a dead
// capability, the engine refused it correctly, and the harness rewrote that
// refusal as `submissionRejected:authorizationRequired`. The task then
// stopped for a human whose only stated problem was "authorization", which
// cost four rounds of misdiagnosis to trace back to a revocation.
//
// Two contracts follow from that, and they are independent — either one
// alone still leaves an operator guessing:
//
//   1. A revoked grant is never selected. The port answers "no capability",
//      the guard refuses before dispatch, and nothing is submitted.
//   2. When the runtime does refuse a named grant, the reason it decided
//      survives into the task record. `revoked`, `expired` and `exhausted`
//      need three different maintainer actions and must not share one code.
//
// No device is touched here: every test is port-level or fake-driven, and
// device dispatch is 0.

import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Rejects every submit with one fixed runtime message, which is exactly the
/// surface the coordinator classifies.
private final class RejectingJobPort: HarnessRuntimeJobPort, @unchecked Sendable {
  private let lock = NSLock()
  private let message: String
  private var submitted: [String] = []

  init(message: String) {
    self.message = message
  }

  var submittedOperations: [String] { lock.withLock { submitted } }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    lock.withLock { submitted.append(request.operation.reference) }
    throw HarnessJobPortError.rejected(message)
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    throw HarnessJobPortError.unknownJob(jobID)
  }

  func requestCancel(jobID: String) async throws {}
}

final class HarnessCapabilityRevocationContractTests: XCTestCase {
  private var rootURL: URL!
  private static let deviceIdentity = String(repeating: "a", count: 64)
  private static let now = "2026-07-31T00:00:00Z"

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-capability-revocation-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: - Fixtures

  private func makePort() throws -> (RuntimeCapabilityStore, RuntimeCapabilityStoreHarnessPort) {
    let store = try RuntimeCapabilityStore(
      directoryURL: rootURL.appendingPathComponent("capabilities", isDirectory: true))
    return (store, RuntimeCapabilityStoreHarnessPort(store: store, nowUTC: { Self.now }))
  }

  private func grant(
    id: String,
    operationID: String = "debug.hap",
    expiresAtUTC: String = "2026-12-31T00:00:00Z",
    exactBindingRevision: Int? = nil,
    inputConstraints: [String: RuntimeCapabilityInputConstraint] = [:]
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: id,
      targetScope: .stablePhysicalIdentity(sha256: Self.deviceIdentity),
      operationScope: [.init(operationID: operationID, version: 1)],
      effectCeiling: .deviceMutation,
      inputConstraints: inputConstraints,
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: expiresAtUTC,
      maximumUses: 5,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#992 revocation contract"),
      exactBindingRevision: exactBindingRevision)
  }

  /// The runtime's rejection message for a capability refusal, composed the
  /// way `RuntimeJobEngine.preauthorize` composes it.
  private func runtimeRejection(_ error: RuntimeCapabilityStoreError) -> String {
    "capability denied \(RuntimeJobEngine.capabilityDenialMarker)"
      + "\(RuntimeJobEngine.denialCode(of: error))]: \(error)"
  }

  private func denial(_ reason: RuntimeCapabilityDenialReason, _ detail: String) -> String {
    runtimeRejection(.denied(RuntimeCapabilityDenial(reason: reason, detail: detail)))
  }

  private func makeStack(
    jobs: RejectingJobPort
  ) throws -> (HarnessTaskCoordinator, HarnessTaskSubmission) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { Self.now })
    let submission = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "No WaterFlow SIGABRT", desiredState: [:]),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 0),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
    return (coordinator, submission)
  }

  // MARK: - 1. A revoked grant is never selected

  func testARevokedGrantIsNeverNamedForDispatch() async throws {
    let (store, port) = try makePort()
    try await store.install(try grant(id: "CAP-RT-REVOKE-001"))

    // Before revocation the grant is the one a request would name.
    var named = await port.standingCapabilityID(
      operationReference: "debug.hap@1", targetID: "TGT-1",
        expectedBindingRevision: nil, inputs: [:])
    XCTAssertEqual(named, "CAP-RT-REVOKE-001")
    var held = await port.hasStandingCapability(
      operationReference: "debug.hap@1", targetID: "TGT-1")
    XCTAssertTrue(held)

    try await store.revoke(
      capabilityID: "CAP-RT-REVOKE-001", atUTC: Self.now,
      reason: "maintainer withdrew the debug envelope")

    // Revocation leaves uses, lineage, ceiling, scope and expiry untouched,
    // so every other condition the port tests still passes. Only an explicit
    // revocation check can refuse it.
    let inspected = try await store.inspect(capabilityID: "CAP-RT-REVOKE-001")
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(status.remainingUses, 5)
    XCTAssertTrue(status.lineageAllowsNewExecution)
    XCTAssertGreaterThan(status.capability.expiresAtUTC, Self.now)

    named = await port.standingCapabilityID(
      operationReference: "debug.hap@1", targetID: "TGT-1",
        expectedBindingRevision: nil, inputs: [:])
    XCTAssertNil(named, "a revoked grant must never be named into a request")
    held = await port.hasStandingCapability(
      operationReference: "debug.hap@1", targetID: "TGT-1")
    XCTAssertFalse(held, "the guard must refuse before dispatch, not after")
  }

  func testARevokedGrantDoesNotHideAStillValidOne() async throws {
    let (store, port) = try makePort()
    // The revoked one sorts first (earlier expiry), so a filter that aborted
    // the scan instead of skipping the entry would report no capability.
    try await store.install(
      try grant(id: "CAP-RT-REVOKE-EARLY", expiresAtUTC: "2026-09-01T00:00:00Z"))
    try await store.install(
      try grant(id: "CAP-RT-REVOKE-LATE", expiresAtUTC: "2026-12-31T00:00:00Z"))
    try await store.revoke(
      capabilityID: "CAP-RT-REVOKE-EARLY", atUTC: Self.now, reason: "superseded")

    let named = await port.standingCapabilityID(
      operationReference: "debug.hap@1", targetID: "TGT-1",
        expectedBindingRevision: nil, inputs: [:])
    XCTAssertEqual(named, "CAP-RT-REVOKE-LATE")
    let held = await port.hasStandingCapability(
      operationReference: "debug.hap@1", targetID: "TGT-1")
    XCTAssertTrue(held)
  }

  /// The guard asks "is there one?" and the dispatcher then asks "which one?".
  /// The defect this file exists for is what happens when those two answers
  /// disagree, so they may never be computed by two independent scans.
  func testBothPortQuestionsAlwaysAgree() async throws {
    let (store, port) = try makePort()

    func assertAgreement(_ label: String) async {
      let named = await port.standingCapabilityID(
        operationReference: "debug.hap@1", targetID: "TGT-1",
        expectedBindingRevision: nil, inputs: [:])
      let held = await port.hasStandingCapability(
        operationReference: "debug.hap@1", targetID: "TGT-1")
      XCTAssertEqual(held, named != nil, "\(label): the two answers diverged")
    }

    await assertAgreement("empty store")

    try await store.install(try grant(id: "CAP-RT-AGREE-ACTIVE"))
    await assertAgreement("one active grant")

    try await store.revoke(
      capabilityID: "CAP-RT-AGREE-ACTIVE", atUTC: Self.now, reason: "withdrawn")
    await assertAgreement("only a revoked grant")

    try await store.install(
      try grant(id: "CAP-RT-AGREE-EXPIRED", expiresAtUTC: "2026-07-15T00:00:00Z"))
    await assertAgreement("revoked plus expired")

    try await store.install(
      try grant(id: "CAP-RT-AGREE-OTHER", operationID: "flash.dayu200"))
    await assertAgreement("plus a grant for another operation")
  }

  // MARK: - 1b. A grant this side can already prove unusable is never named

  /// Found in the GJ-3/GJ-5 window of 2026-08-05, and the same shape as the
  /// revocation defect above: every grant the device had accumulated before
  /// the GJ-4 reflash is pinned to binding revision 1, stays installed,
  /// unexpired and unrevoked, and sorts earliest. The port named one, the
  /// engine refused it as `authorizationTargetScopeMismatch`, and the task
  /// stopped for a human — while the very same request naming *no* grant is
  /// issued a correct revision-2 envelope by default policy. One stale grant
  /// therefore bricked every harness task on the rebound device.
  func testAGrantPinnedToAnotherBindingRevisionIsNeverNamed() async throws {
    let (store, port) = try makePort()
    try await store.install(
      try grant(
        id: "CAP-RT-REV1-EARLY", expiresAtUTC: "2026-09-01T00:00:00Z",
        exactBindingRevision: 1))
    try await store.install(
      try grant(
        id: "CAP-RT-REV2-LATE", expiresAtUTC: "2026-12-31T00:00:00Z",
        exactBindingRevision: 2))

    let named = await port.standingCapabilityID(
      operationReference: "debug.hap@1", targetID: "TGT-1",
      expectedBindingRevision: 2, inputs: [:])
    XCTAssertEqual(
      named, "CAP-RT-REV2-LATE",
      "the stale revision-1 grant sorts first and must be skipped, not named")

    // With no grant for this revision the answer is "none", which lets the
    // runtime's default policy issue the right envelope. Naming a grant that
    // provably cannot authorize is strictly worse than naming nothing.
    let none = await port.standingCapabilityID(
      operationReference: "debug.hap@1", targetID: "TGT-1",
      expectedBindingRevision: 3, inputs: [:])
    XCTAssertNil(none)
  }

  func testAGrantWhoseInputConstraintsTheRequestViolatesIsNeverNamed() async throws {
    let (store, port) = try makePort()
    try await store.install(
      try grant(
        id: "CAP-RT-OLD-LEASE", expiresAtUTC: "2026-09-01T00:00:00Z",
        inputConstraints: ["bundleName": .exactString("com.example.previous")]))
    try await store.install(
      try grant(
        id: "CAP-RT-THIS-LEASE", expiresAtUTC: "2026-12-31T00:00:00Z",
        inputConstraints: ["bundleName": .exactString("com.example.waterflowdemo")]))

    let inputs: [String: JSONValue] = ["bundleName": .string("com.example.waterflowdemo")]
    let named = await port.standingCapabilityID(
      operationReference: "debug.hap@1", targetID: "TGT-1",
      expectedBindingRevision: nil, inputs: inputs)
    XCTAssertEqual(named, "CAP-RT-THIS-LEASE")

    // A constrained input the request does not carry at all is a violation,
    // not a wildcard.
    let absent = await port.standingCapabilityID(
      operationReference: "debug.hap@1", targetID: "TGT-1",
      expectedBindingRevision: nil, inputs: [:])
    XCTAssertNil(absent)
  }

  /// An unpinned grant is unchanged by any of this: the pins are refusals,
  /// never a new requirement to carry one.
  func testAnUnpinnedGrantIsStillNamedForAnyRevision() async throws {
    let (store, port) = try makePort()
    try await store.install(try grant(id: "CAP-RT-UNPINNED"))
    for revision in [nil, 1, 2, 7] as [Int?] {
      let named = await port.standingCapabilityID(
        operationReference: "debug.hap@1", targetID: "TGT-1",
        expectedBindingRevision: revision, inputs: [:])
      XCTAssertEqual(named, "CAP-RT-UNPINNED", "revision \(String(describing: revision))")
    }
  }

  // MARK: - 2. The runtime's reason survives into the task record

  func testRevokedExpiredAndExhaustedDoNotCollapseIntoOneCode() {
    let codes = [
      HarnessTaskCoordinator.semanticCode(
        from: denial(.revoked, "revoked at 2026-07-30T00:00:00Z: withdrawn")),
      HarnessTaskCoordinator.semanticCode(
        from: denial(.expired, "expired at 2026-07-30T00:00:00Z")),
      HarnessTaskCoordinator.semanticCode(
        from: denial(.exhausted, "maximumUses 5 consumed")),
    ]
    XCTAssertEqual(
      codes, ["authorizationRevoked", "authorizationExpired", "authorizationExhausted"])
    XCTAssertEqual(
      Set(codes).count, 3,
      "three refusals needing three different maintainer actions must not share a code")
    XCTAssertTrue(
      codes.allSatisfy { $0.hasPrefix("authorization") },
      "the family prefix is what keeps these on the approval path")
  }

  func testEveryRuntimeDenialReasonKeepsItsOwnCode() {
    // Reasons the capability layer can decide with, each of which used to
    // arrive as the single generic code.
    let expected: [(RuntimeCapabilityDenialReason, String)] = [
      (.revoked, "authorizationRevoked"),
      (.expired, "authorizationExpired"),
      (.notYetValid, "authorizationNotYetValid"),
      (.exhausted, "authorizationExhausted"),
      (.targetScopeMismatch, "authorizationTargetScopeMismatch"),
      (.operationScopeMismatch, "authorizationOperationScopeMismatch"),
      (.effectAboveCeiling, "authorizationEffectAboveCeiling"),
      (.planDigestRequired, "authorizationPlanDigestRequired"),
      (.planDigestMismatch, "authorizationPlanDigestMismatch"),
      (.inputConstraintViolated, "authorizationInputConstraintViolated"),
      (.targetIdentityRequired, "authorizationTargetIdentityRequired"),
    ]
    for (reason, code) in expected {
      XCTAssertEqual(
        HarnessTaskCoordinator.semanticCode(from: denial(reason, "detail")), code,
        "\(reason.rawValue) lost its identity")
    }
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(
        from: runtimeRejection(.lineageBlocked("previous use 1 is pending"))),
      "authorizationLineageBlocked")
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(
        from: runtimeRejection(.capabilityNotFound("CAP-RT-GONE"))),
      "authorizationCapabilityNotFound")
  }

  func testARevokedRejectionReachesTheTaskRecordAsARevocation() async throws {
    let jobs = RejectingJobPort(
      message: denial(.revoked, "revoked at 2026-07-30T00:00:00Z: withdrawn"))
    let (coordinator, submission) = try makeStack(jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    let expected = "submissionRejected:authorizationRevoked:\(DebugCrashTaskHandler.observeDevice)"
    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, expected)
    XCTAssertEqual(outcome.snapshot.result?.reasonCode, expected)

    // Still an authorization block: a revoked grant is an approval problem,
    // not an unavailable environment.
    let actions = try await coordinator.humanActions(task.htaskID)
    let action = try XCTUnwrap(actions.last)
    XCTAssertEqual(action.block, .authorizationApproval)
    XCTAssertEqual(action.reasonCode, expected)
    XCTAssertEqual(jobs.submittedOperations.count, 1, "one refused submit, no retry storm")
  }

  func testAGenericAuthorizationRejectionKeepsItsExistingCode() async throws {
    // Runtime refusals that name no capability decision are unchanged: this
    // is the message the mutation path emits when no grant was supplied.
    let jobs = RejectingJobPort(
      message: "authorizationRequired: mutation has no runtime capability reference")
    let (coordinator, submission) = try makeStack(jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    let expected = "submissionRejected:authorizationRequired:\(DebugCrashTaskHandler.observeDevice)"
    XCTAssertEqual(outcome.reasonCode, expected)
    let actions = try await coordinator.humanActions(task.htaskID)
    let action = try XCTUnwrap(actions.last)
    XCTAssertEqual(action.block, .authorizationApproval)
  }

  func testProseInTheDenialSlotNeverReachesAFingerprint() {
    // A fingerprint that varied with prose would split one recurring failure
    // into a new failure every wake, and failure memory would never converge.
    let prose = [
      "capability denied [denial:revoked at 2026-07-30 by the maintainer]: x",
      "capability denied [denial:]: x",
      "capability denied [denial:with-a-hyphen]: x",
      "capability denied [denial:\(String(repeating: "z", count: 64))]: x",
    ]
    for message in prose {
      XCTAssertEqual(
        HarnessTaskCoordinator.semanticCode(from: message), "authorizationRequired",
        "unvetted token entered the fingerprint: \(message)")
    }
    // An unterminated marker is not a denial token at all, and falls through
    // to the ordinary prose heuristics.
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(from: "capability denied [denial:revoked"),
      "authorizationRequired")
  }

  func testUnrelatedRejectionsAreUnaffectedByTheDenialLookup() {
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(
        from: "observe.device@1 is runtime unavailable: provider_not_registered"),
      "operationUnavailable")
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(from: "TGT-1 has not been adopted"),
      "targetNotAdopted")
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(from: "expectedBindingRevision 7 is stale"),
      "bindingMismatch")
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(from: "request too large"), "rejected")
  }

  /// Found in the GJ-5 window, and the same shape of mistake as the one this
  /// file opens with: the engine refused a *stale workspace revision*, and the
  /// harness reported an authorization block. Nothing was wrong with any
  /// grant, so the maintainer it stopped for had nothing to approve.
  ///
  /// The cause was a prose heuristic — the engine's own preflight message says
  /// it failed "before authorization", and the word alone was enough. The
  /// engine states a typed code in the same error, so that code decides.
  func testTheEngineSTypedRejectionCodeOutranksTheProse() {
    // Built from the engine's own error, exactly as the production adapter
    // stringifies it, so a change to that interpolation fails here.
    let conflict =
      "typed plan preflight failed before authorization: "
      + "unsupportedAction(\"workspace.revisionConflict:084dddd2b862!=1c0352994e4a\")"
    let preflight = "\(RuntimeJobEngineError.rejected(.invalidInput, conflict))"
    XCTAssertTrue(preflight.contains("authorization"), preflight)
    XCTAssertEqual(HarnessTaskCoordinator.semanticCode(from: preflight), "invalidInput")

    // A real authorization refusal keeps its family, because the runtime's own
    // spelling of the code is what the approval path tests for.
    let denial = "effect deviceMutation requires an explicit runtime capability"
    let refusal = "\(RuntimeJobEngineError.rejected(.authorizationRequired, denial))"
    XCTAssertEqual(HarnessTaskCoordinator.semanticCode(from: refusal), "authorizationRequired")
    XCTAssertTrue(HarnessTaskCoordinator.semanticCode(from: refusal).hasPrefix("authorization"))

    // Every published code survives the round trip, so a code added later is
    // reported as itself rather than as whatever word its message happens to
    // contain.
    for code in RuntimeOperationErrorCode.allCases {
      XCTAssertEqual(
        HarnessTaskCoordinator.semanticCode(
          from: "\(RuntimeJobEngineError.rejected(code, "detail"))"),
        code.rawValue)
    }
  }

  /// The runtime and harness planes are deliberately decoupled and cannot
  /// share a constant, so the marker is written twice. This is what keeps the
  /// two copies from drifting apart in silence.
  func testTheRuntimeAndHarnessAgreeOnTheDenialMarker() {
    XCTAssertEqual(
      RuntimeJobEngine.capabilityDenialMarker,
      HarnessTaskCoordinator.capabilityDenialMarker)
    XCTAssertEqual(
      RuntimeJobEngine.denialCode(
        of: .denied(RuntimeCapabilityDenial(reason: .revoked, detail: "revoked at x: y"))),
      RuntimeCapabilityDenialReason.revoked.rawValue)
    // A store fault is not a verdict on the grant, so it stays unnamed and
    // classifies as the generic family code rather than inventing a reason.
    XCTAssertEqual(
      HarnessTaskCoordinator.semanticCode(
        from: runtimeRejection(.ioFailure("cannot read capability store"))),
      "authorizationUnclassified")
  }
}
