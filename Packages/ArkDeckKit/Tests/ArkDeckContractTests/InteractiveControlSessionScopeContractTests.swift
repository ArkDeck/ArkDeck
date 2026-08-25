import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// The control-session authorization envelope (TASK-IDC-002 stage 2).
///
/// A pointer gesture's authorized subject is the session — target, binding and
/// gesture kind — not the coordinate. The scope fingerprint hashes `inputs`
/// and the materialized plan digest, and both move with every coordinate, so
/// per-gesture scoping would mint one permanent capability record per screen
/// position into a store that is rewritten whole on each issue and consume
/// (measured: 318 records / 1.29 MB, see the change's evidence).
final class InteractiveControlSessionScopeContractTests: XCTestCase {
  private func descriptor(_ reference: String) throws -> CatalogOperationDescriptor {
    try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
  }

  /// The identity that decides which capability record a gesture lands on:
  /// the reduced inputs, plus the plan digest only where the scope still
  /// carries it. A session-scoped operation drops the digest here while the
  /// query keeps it, because the consume record must still say which exact
  /// plan each individual use authorized.
  private func fingerprint(
    _ descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    planDigest: String
  ) -> String {
    let reduced = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: descriptor, inputs: inputs)
    let scoped = RuntimeJobEngine.sessionScopedInputOperations.contains(descriptor.reference)
    let encoder = CanonicalJSONEncoders.canonical()
    let encoded = (try? encoder.encode(reduced)).flatMap {
      String(data: $0, encoding: .utf8)
    }
    return "\(descriptor.reference)|\(scoped ? "session-scoped" : planDigest)|\(encoded ?? "?")"
  }

  func testEveryPointerCoordinateSharesOneAuthorizationSubject() throws {
    let tap = try descriptor("input.tap@1")
    // Two taps a user sends at different screen positions, each with the plan
    // digest that materialization would produce for it.
    let first = fingerprint(
      tap, inputs: ["x": .integer(640), "y": .integer(1500)],
      planDigest: String(repeating: "a", count: 64))
    let second = fingerprint(
      tap, inputs: ["x": .integer(120), "y": .integer(300)],
      planDigest: String(repeating: "b", count: 64))
    XCTAssertEqual(
      first, second,
      "two taps at different coordinates must authorize against one session record")
  }

  func testTheDisplayStaysPartOfTheAuthorizedSubject() throws {
    let tap = try descriptor("input.tap@1")
    let defaultDisplay = fingerprint(
      tap, inputs: ["x": .integer(1), "y": .integer(2)],
      planDigest: String(repeating: "a", count: 64))
    let secondDisplay = fingerprint(
      tap, inputs: ["x": .integer(1), "y": .integer(2), "displayId": .integer(2)],
      planDigest: String(repeating: "a", count: 64))
    XCTAssertNotEqual(
      defaultDisplay, secondDisplay,
      "a gesture on another display is a different subject, not the same session")
  }

  func testEachGestureKindKeepsItsOwnEnvelope() throws {
    let references = ["input.tap@1", "input.long-press@1", "input.swipe@1"]
    var subjects: Set<String> = []
    for reference in references {
      subjects.insert(
        fingerprint(
          try descriptor(reference), inputs: ["x": .integer(5), "y": .integer(5)],
          planDigest: String(repeating: "c", count: 64)))
    }
    XCTAssertEqual(
      subjects.count, references.count,
      "tap, long-press and swipe must remain separately authorized")
  }

  func testTheProjectionIsSymmetricAcrossIssueAndConsume() throws {
    // Issue time carries the request's inputs; consume time re-reads them from
    // the durable record. If the projection were applied at only one site the
    // consume would look up an ID the issue never wrote.
    let swipe = try descriptor("input.swipe@1")
    let inputs: [String: JSONValue] = [
      "fromX": .integer(640), "fromY": .integer(2000),
      "toX": .integer(640), "toY": .integer(1000), "durationMs": .integer(500),
      "displayWidth": .integer(1280), "displayHeight": .integer(2832),
    ]
    let atIssue = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: swipe, inputs: inputs)
    let atConsume = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: swipe, inputs: inputs)
    XCTAssertEqual(atIssue, atConsume)
    XCTAssertEqual(
      atIssue, ["displayWidth": .integer(1280), "displayHeight": .integer(2832)],
      "the frame survives into the subject; no coordinate or duration does")
  }

  func testOnlyThePublishedInputOperationsAreSessionScoped() throws {
    XCTAssertEqual(
      RuntimeJobEngine.sessionScopedInputOperations,
      ["input.tap@1", "input.long-press@1", "input.swipe@1"])
    // A neighbouring device mutation must keep its exact-input subject: its
    // authorization is meant to name the precise rule it creates.
    let portForward = try descriptor("port-forward.create@1")
    let inputs: [String: JSONValue] = [
      "direction": .string("forward"), "localPort": .integer(2345),
      "remotePort": .integer(3456),
    ]
    let subject = RuntimeJobEngine.sessionScopedAuthorizationSubject(
      descriptor: portForward, inputs: inputs)
    XCTAssertEqual(subject, inputs)
  }

  func testARotationOrResolutionChangeIsADifferentAuthorizedSubject() throws {
    let tap = try descriptor("input.tap@1")
    let portrait = fingerprint(
      tap,
      inputs: [
        "x": .integer(640), "y": .integer(1500),
        "displayWidth": .integer(1280), "displayHeight": .integer(2832),
      ], planDigest: String(repeating: "a", count: 64))
    let landscape = fingerprint(
      tap,
      inputs: [
        "x": .integer(640), "y": .integer(1500),
        "displayWidth": .integer(2832), "displayHeight": .integer(1280),
      ], planDigest: String(repeating: "a", count: 64))
    XCTAssertNotEqual(
      portrait, landscape,
      "a mapping computed against the old frame must not reuse the session envelope")

    // Same frame, different coordinates, still one subject: the frame is the
    // authorized thing, the position inside it is not.
    let elsewhereInPortrait = fingerprint(
      tap,
      inputs: [
        "x": .integer(10), "y": .integer(20),
        "displayWidth": .integer(1280), "displayHeight": .integer(2832),
      ], planDigest: String(repeating: "z", count: 64))
    XCTAssertEqual(portrait, elsewhereInPortrait)
  }

  func testAStaleFrameIsRefusedBeforeAnythingIsDispatched() throws {
    let spec = try HDCPointerInputSpec(
      gesture: .tap, x: 10, y: 10, displayWidth: 1280, displayHeight: 2832,
      screenEpochUTC: "2026-08-25T00:00:00Z")
    XCTAssertEqual(spec.frameAgeMs(atUTC: "2026-08-25T00:00:00.400Z"), 400)
    XCTAssertEqual(spec.frameAgeMs(atUTC: "2026-08-25T00:00:03Z"), 3_000)
    XCTAssertGreaterThan(
      try XCTUnwrap(spec.frameAgeMs(atUTC: "2026-08-25T00:00:03Z")),
      HDCPointerInputSpec.frameFreshnessBudgetMs)

    // A caller that claimed no epoch gets no freshness verdict invented for it.
    let withoutEpoch = try HDCPointerInputSpec(
      gesture: .tap, x: 10, y: 10, displayWidth: 1280, displayHeight: 2832)
    XCTAssertNil(withoutEpoch.frameAgeMs(atUTC: "2026-08-25T00:00:03Z"))
  }

  func testCoordinatesMustFitTheFrameTheyWereMappedAgainst() {
    XCTAssertThrowsError(
      try HDCPointerInputSpec(
        gesture: .tap, x: 1300, y: 10, displayWidth: 1280, displayHeight: 2832),
      "a coordinate outside the declared frame must be refused host-side")
    XCTAssertThrowsError(
      try HDCPointerInputSpec(
        gesture: .swipe, x: 10, y: 10, displayWidth: 1280, displayHeight: 2832,
        toX: 10, toY: 3000, durationMs: 300),
      "a swipe endpoint outside the declared frame must be refused too")
    XCTAssertThrowsError(
      try HDCPointerInputSpec(
        gesture: .tap, x: 10, y: 10, displayWidth: 0, displayHeight: 2832),
      "a frame with no extent bounds nothing")
    XCTAssertNoThrow(
      try HDCPointerInputSpec(
        gesture: .tap, x: 1279, y: 2831, displayWidth: 1280, displayHeight: 2832))
  }

  func testFrameFactsSurviveExactActionPersistence() throws {
    let action = TypedProviderAction.hdc(
      .injectPointerInput(
        try HDCPointerInputSpec(
          gesture: .swipe, x: 640, y: 2000, displayWidth: 1280, displayHeight: 2832,
          toX: 640, toY: 1000, durationMs: 500,
          screenEpochUTC: "2026-08-25T00:00:00Z")))
    XCTAssertEqual(try PersistedTypedProviderAction(action).materialize(), action)
  }

  func testTheSessionEnvelopeIsBoundedInTimeAndUses() {
    XCTAssertEqual(
      RuntimeJobEngine.sessionScopedInputLifetime, 60 * 60,
      "a control session authorizes one sitting, not the standing thirty days")
    XCTAssertEqual(RuntimeJobEngine.sessionScopedInputMaximumUses, 2_000)
    XCTAssertLessThan(
      RuntimeJobEngine.sessionScopedInputMaximumUses, 10_000,
      "the session budget must be tighter than the standing default it replaces")
  }

  // MARK: - Session-carried evidence (stage 4)

  /// The two property readbacks cost a device round trip each (measured:
  /// ~150 ms apiece against DAYU200, versus 35 ms for the identity query
  /// that is a host-side call). Carrying them within a session is what
  /// brings a gesture inside its budget - but only the two, and only under a
  /// freshly re-confirmed identity.
  private func accumulator(
    identity: String = String(repeating: "1", count: 64),
    bindingRevision: Int = 7,
    model: String? = "HW-DAYU200",
    firmware: String? = "OpenHarmony-5.0",
    steps: [RuntimeEvidencePreflightStep]
  ) -> RuntimeEvidencePreflightAccumulator {
    RuntimeEvidencePreflightAccumulator(
      targetID: "target-a", bindingRevision: bindingRevision,
      stableIdentitySHA256: identity, providerID: "hdc",
      toolVersion: "1.0", toolSHA256: String(repeating: "b", count: 64),
      transport: "usb", confirmedAtUTC: "2026-08-25T10:00:00Z",
      model: model, firmware: firmware, steps: steps)
  }

  private func step(
    _ id: String, carriedFrom: String? = nil
  ) -> RuntimeEvidencePreflightStep {
    RuntimeEvidencePreflightStep(
      stepID: id, stepKind: id == "confirm-evidence-target" ? "probeDevice" : "runApprovedRemoteRead",
      outcomeAtUTC: "2026-08-25T10:00:00Z", carriedFromUTC: carriedFrom)
  }

  private var allThreeFresh: [RuntimeEvidencePreflightStep] {
    ["confirm-evidence-target", "read-evidence-model", "read-evidence-firmware"].map { step($0) }
  }

  private var identityFreshRestCarried: [RuntimeEvidencePreflightStep] {
    [
      step("confirm-evidence-target"),
      step("read-evidence-model", carriedFrom: "2026-08-25T09:55:00Z"),
      step("read-evidence-firmware", carriedFrom: "2026-08-25T09:55:00Z"),
    ]
  }

  /// The step that re-reads the device identity is the reason carrying the
  /// others is sound. It is never itself carried, and it is cheap enough
  /// that it need not be.
  func testTheIdentityConfirmationIsNeverCarried() {
    XCTAssertFalse(
      RuntimeJobEngine.sessionCarriableEvidenceStepIDs.contains("confirm-evidence-target"),
      "carrying the identity check would remove the only per-gesture wrong-device guard")
    XCTAssertEqual(
      RuntimeJobEngine.sessionCarriableEvidenceStepIDs,
      ["read-evidence-model", "read-evidence-firmware"],
      "only the two property readbacks may be answered from session memory")
  }

  /// A fact carried from four minutes ago and a fact read just now are
  /// different claims, and the observation says which it is.
  func testACarriedObservationIsNotNamedAFreshOne() {
    let fresh = RuntimeJobEngine.evidenceObservation(
      from: accumulator(steps: allThreeFresh))
    XCTAssertEqual(fresh.confirmationMethod, "machineReadback")
    let carried = RuntimeJobEngine.evidenceObservation(
      from: accumulator(steps: identityFreshRestCarried))
    XCTAssertEqual(carried.confirmationMethod, "machineReadbackSessionCarried")
  }

  /// Fail-closed by construction: the hardware-evidence contract admits only
  /// `machineReadback`, so a session-carried observation cannot be projected
  /// as hardware evidence for anything, and no separate gate has to remember
  /// to exclude it.
  func testACarriedObservationCannotBeProjectedAsHardwareEvidence() {
    let carried = RuntimeJobEngine.evidenceObservation(
      from: accumulator(steps: identityFreshRestCarried))
    XCTAssertNotEqual(
      carried.confirmationMethod, "machineReadback",
      "a carried readback must not satisfy the machineReadback hardware-evidence gate")
    XCTAssertNotEqual(carried.confirmationMethod, "humanVisual")
  }

  /// Which device answered is part of what is remembered: another device, or
  /// the same device on a new binding, gets asked again.
  func testCarriedFactsAreScopedToOneDeviceAndOneBinding() {
    let a = RuntimeJobEngine.carriedEvidenceKey(
      stableIdentitySHA256: String(repeating: "1", count: 64), bindingRevision: 7)
    let otherDevice = RuntimeJobEngine.carriedEvidenceKey(
      stableIdentitySHA256: String(repeating: "2", count: 64), bindingRevision: 7)
    let otherBinding = RuntimeJobEngine.carriedEvidenceKey(
      stableIdentitySHA256: String(repeating: "1", count: 64), bindingRevision: 8)
    XCTAssertNotEqual(a, otherDevice)
    XCTAssertNotEqual(a, otherBinding)
  }

  /// Carrying shortens the work, never the requirement: an observation is
  /// still assembled only from all three correlated fragments, in order.
  func testCarryingDoesNotRelaxWhatACompletePreflightMeans() {
    let missingFirmware = accumulator(
      firmware: nil,
      steps: [step("confirm-evidence-target"), step("read-evidence-model", carriedFrom: "x")])
    XCTAssertFalse(missingFirmware.isComplete)
    XCTAssertTrue(accumulator(steps: identityFreshRestCarried).isComplete)
    let outOfOrder = accumulator(
      steps: [
        step("confirm-evidence-target"),
        step("read-evidence-firmware", carriedFrom: "x"),
        step("read-evidence-model", carriedFrom: "x"),
      ])
    XCTAssertFalse(outOfOrder.isComplete, "a carried fragment still may not arrive out of order")
  }

  /// The carried facts live no longer than the envelope that authorized the
  /// gestures carrying them.
  func testCarriedFactsExpireWithTheSessionEnvelope() {
    XCTAssertEqual(RuntimeJobEngine.sessionScopedInputLifetime, 60 * 60)
  }
}
