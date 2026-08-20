import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeIPC

/// `AFA-AC-3` and `AFA-AC-4` from the issuing side.
///
/// The adversarial matrix has two halves. ArkForge owns the refusals — a
/// tampered tag, a stale epoch, an expired permit, a non-single-use one, a
/// second consumption — and its own tests cover them
/// (`an_expired_permit_cannot_be_consumed_for_the_first_time`,
/// `a_consumed_permit_is_refused_rather_than_re_dispatched`,
/// `a_non_single_use_permit_is_refused`).
///
/// This file is the half that has to hold *before* any of those fire: an
/// authority that never signs the thing in the first place. A daemon refusing
/// a bad permit is the last line, not the first, and a system whose authority
/// leans on it has moved the decision to the wrong process.

/// A clock the test can move, safely shared with the authority's `@Sendable`
/// time source. The tests that use it are about what happens when time passes
/// *between* two requests, so the clock has to be movable from outside.
private final class MovableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64

  init(_ value: UInt64) { self.value = value }

  func set(_ next: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    value = next
  }

  var reader: @Sendable () -> UInt64 {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }
}

/// See the file comment above: this suite is the issuing half of the matrix.
final class ArkForgeExecutionAuthorityContractTests: XCTestCase {

  private let secret = ArkForgePairingSecret(
    secret: Array("adversarial-matrix-secret".utf8), epoch: ArkForgePairingEpoch(4))

  private func digest(_ text: String) -> [UInt8] {
    Array(SHA256Hex.string(of: Data(text.utf8)).utf8.prefix(0))
      + (0..<32).map { UInt8(truncatingIfNeeded: text.hashValue &+ $0) }
  }

  private func hexBytes(_ hex: String) -> [UInt8]? {
    guard hex.count == 64 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(32)
    var high: UInt8?
    for character in hex {
      guard let value = character.hexDigitValue else { return nil }
      if let first = high {
        bytes.append(first << 4 | UInt8(value))
        high = nil
      } else {
        high = UInt8(value)
      }
    }
    return high == nil && bytes.count == 32 ? bytes : nil
  }

  private let planDigest = [UInt8](repeating: 0x11, count: 32)
  private let deviceFacts = [UInt8](repeating: 0x22, count: 32)

  private func approvedPlan() -> ArkForgeExecutionAuthority.ApprovedPlan {
    ArkForgeExecutionAuthority.ApprovedPlan(
      jobID: "JOB-1", planID: "PLAN-1", planSHA256: planDigest,
      admittedDeviceFactsSHA256: deviceFacts,
      binding: ArkForgeAuthorityBinding(
        authorityNamespace: "arkdeck", bindingID: "TGT-1", bindingRevision: 2,
        stableIdentityDigest: [UInt8](repeating: 0x33, count: 32)),
      controllerSessionID: "SESSION-1")
  }

  /// A snapshot the daemon would send, with every field matching what the
  /// authority approved. Individual tests move exactly one fact.
  private func snapshot(
    jobID: String = "JOB-1", planID: String = "PLAN-1", planSHA256: [UInt8]? = nil,
    deviceFactsSHA256: [UInt8]? = nil, stepID: String = "STEP-WRITE",
    attemptID: String = "ATTEMPT-1", observedAtEpochMs: UInt64 = 1_000_000,
    lifetimeMs: UInt64 = 60_000
  ) -> ArkForgeStepAdmissionSnapshot {
    ArkForgeStepAdmissionSnapshot(
      jobID: jobID, planID: planID, planSHA256: planSHA256 ?? planDigest,
      stepID: stepID, attemptID: attemptID,
      publicStepSHA256: [UInt8](repeating: 0x44, count: 32),
      privateActionSHA256: [UInt8](repeating: 0x55, count: 32),
      effectSetSHA256: [UInt8](repeating: 0x66, count: 32),
      admittedDeviceFactsSHA256: deviceFactsSHA256 ?? deviceFacts,
      observedMode: "loader", observedAtEpochMs: observedAtEpochMs,
      snapshotLifetimeMs: lifetimeMs, requestID: "ADM-1")
  }

  private func authority(
    nowEpochMs: UInt64 = 1_000_100
  ) -> ArkForgeExecutionAuthority {
    ArkForgeExecutionAuthority(
      plan: approvedPlan(), secret: secret, now: { nowEpochMs })
  }

  // MARK: - The happy path, so the refusals below mean something

  func testAMatchingAdmissionIsSignedOnce() async {
    let authority = authority()
    guard case .sign(let permit) = await authority.admit(snapshot()) else {
      return XCTFail("a matching admission must be signed")
    }
    XCTAssertEqual(permit.permitID, "PERMIT-JOB-1-STEP-WRITE-ATTEMPT-1")
    XCTAssertEqual(permit.pairingEpoch, ArkForgePairingEpoch(4))
    XCTAssertFalse(permit.integrityTag.isEmpty)
    let count = await authority.issuedCount
    XCTAssertEqual(count, 1)
  }

  func testLoaderControlReceiptExtendsTheExactLoaderAdmissionLineage() async throws {
    let topology = "17956864"
    let topologyHex = try XCTUnwrap(
      ArkForgeObservationSelection.topologyDigest(usbTopology: topology))
    let topologyDigest = try XCTUnwrap(hexBytes(topologyHex))
    let authority = authority()

    // The managed-control receipt publishes `Loader`, while ArkForge's live
    // admission publishes `rockusb-loader`. They are the same measured mode
    // lineage and must share one canonical key. This exact case reached a real
    // DAYU200 Loader on 2026-08-20 and was then refused before STEP-002 because
    // the authority had stored the capitalized spelling as a different mode.
    await authority.recordManagedControlFacts([
      "mode": "Loader", "usbTopology": topology,
    ])

    func rawSnapshot(admittedDigest: [UInt8]) -> ArkForgeStepAdmissionSnapshot {
      ArkForgeStepAdmissionSnapshot(
        jobID: "JOB-1", planID: "PLAN-1", planSHA256: planDigest,
        stepID: "STEP-002", attemptID: "ATTEMPT-2",
        publicStepSHA256: [UInt8](repeating: 0x44, count: 32),
        privateActionSHA256: [UInt8](repeating: 0x55, count: 32),
        effectSetSHA256: [UInt8](repeating: 0x66, count: 32),
        admittedDeviceFactsSHA256: admittedDigest, observedMode: "rockusb-loader",
        observedAtEpochMs: 1_000_000, snapshotLifetimeMs: 60_000,
        requestID: "ADM-LOADER", topologySHA256: topologyDigest,
        descriptorSHA256: [UInt8](repeating: 0x77, count: 32),
        serialSHA256: [UInt8](repeating: 0x88, count: 32),
        serialEvidenceKind: "descriptor", identityStrength: "serialAndTopology",
        transportSessionSHA256: [UInt8](repeating: 0x99, count: 32))
    }

    let unsigned = rawSnapshot(admittedDigest: [UInt8](repeating: 0, count: 32))
    let admission = rawSnapshot(
      admittedDigest: ArkForgeExecutionAuthority.deviceFactsDigest(unsigned))
    guard case .sign = await authority.admit(admission) else {
      return XCTFail("the accepted Loader receipt must authorize the exact Loader admission")
    }
  }

  func testAPlanMaterializedWhileAlreadyInLoaderSeedsItsInitialModeLineage() async throws {
    let topology = "17956864"
    let topologyHex = try XCTUnwrap(
      ArkForgeObservationSelection.topologyDigest(usbTopology: topology))
    let topologyDigest = try XCTUnwrap(hexBytes(topologyHex))
    let loaderPlan = ArkForgeExecutionAuthority.ApprovedPlan(
      jobID: "JOB-1", planID: "PLAN-1", planSHA256: planDigest,
      admittedDeviceFactsSHA256: deviceFacts,
      binding: ArkForgeAuthorityBinding(
        authorityNamespace: "arkdeck", bindingID: "TGT-1", bindingRevision: 2,
        stableIdentityDigest: [UInt8](repeating: 0x33, count: 32)),
      controllerSessionID: "SESSION-1", usbTopology: topology)
    let authority = ArkForgeExecutionAuthority(
      plan: loaderPlan, secret: secret, now: { 1_000_100 })
    await authority.recordMaterializedObservationMode("rockusb-loader")

    func rawSnapshot(admittedDigest: [UInt8]) -> ArkForgeStepAdmissionSnapshot {
      ArkForgeStepAdmissionSnapshot(
        jobID: "JOB-1", planID: "PLAN-1", planSHA256: planDigest,
        stepID: "STEP-001", attemptID: "ATTEMPT-1",
        publicStepSHA256: [UInt8](repeating: 0x44, count: 32),
        privateActionSHA256: [UInt8](repeating: 0x55, count: 32),
        effectSetSHA256: [UInt8](repeating: 0x66, count: 32),
        admittedDeviceFactsSHA256: admittedDigest, observedMode: "rockusb-loader",
        observedAtEpochMs: 1_000_000, snapshotLifetimeMs: 60_000,
        requestID: "ADM-LOADER-START", topologySHA256: topologyDigest,
        descriptorSHA256: [UInt8](repeating: 0x77, count: 32),
        serialSHA256: [UInt8](repeating: 0x88, count: 32),
        serialEvidenceKind: "descriptor", identityStrength: "serialAndTopology",
        transportSessionSHA256: [UInt8](repeating: 0x99, count: 32))
    }

    let unsigned = rawSnapshot(admittedDigest: [UInt8](repeating: 0, count: 32))
    let admission = rawSnapshot(
      admittedDigest: ArkForgeExecutionAuthority.deviceFactsDigest(unsigned))
    guard case .sign = await authority.admit(admission) else {
      return XCTFail("the sealed initial Loader observation must authorize STEP-001")
    }
  }

  func testEveryPermitIsSingleUseAndTimeBounded() async {
    // Not configurable, and asserted rather than assumed: ArkForge refuses a
    // non-single-use permit outright, and an unbounded one is a standing
    // authorization to write.
    let authority = ArkForgeExecutionAuthority(
      plan: approvedPlan(), secret: secret, now: { 1_000_100 })
    guard case .sign(let signed) = await authority.admit(snapshot()) else {
      return XCTFail("expected a signature")
    }
    let body = String(decoding: signed.signingBody, as: UTF8.self)
    XCTAssertTrue(body.contains("singleUse"))
    // The CBOR encodes `true` as the simple value 0xf5 immediately after the
    // key, so a permit that said `false` would carry 0xf4 there.
    let bytes = Array(signed.signingBody)
    let key = Array("singleUse".utf8)
    let at = (0..<(bytes.count - key.count)).first { index in
      Array(bytes[index..<(index + key.count)]) == key
    }
    let marker = try? XCTUnwrap(at)
    XCTAssertEqual(bytes[(marker ?? 0) + key.count], 0xf5, "singleUse must encode as true")
  }

  // MARK: - The matrix: seven ways an admission must not be signed

  func testAnAdmissionForAnotherJobIsRefused() async {
    guard case .refuse(let why) = await authority().admit(snapshot(jobID: "JOB-2")) else {
      return XCTFail("a foreign job must not be signed")
    }
    XCTAssertEqual(why, .unknownJob(asked: "JOB-2", approved: "JOB-1"))
  }

  func testAPlanDigestThisAuthorityDidNotApproveIsRefused() async {
    // The centre of the whole design: the authority signs *its* plan, not the
    // one the daemon happens to present. Echoing the snapshot back would make
    // this check impossible.
    let other = [UInt8](repeating: 0xEE, count: 32)
    guard case .refuse(let why) = await authority().admit(snapshot(planSHA256: other))
    else { return XCTFail("a foreign plan digest must not be signed") }
    XCTAssertEqual(why, .planMismatch)

    // Same digest but a different plan id is equally not the approved plan.
    guard case .refuse(let idWhy) = await authority().admit(snapshot(planID: "PLAN-2"))
    else { return XCTFail("a foreign plan id must not be signed") }
    XCTAssertEqual(idWhy, .planMismatch)
  }

  func testDeviceFactsFromAnotherBindingAreRefused() async {
    // The device under the daemon is not the device that was authorized. This
    // is the check that stops a permit for board A authorizing a write to
    // board B.
    let other = [UInt8](repeating: 0xDD, count: 32)
    guard case .refuse(let why) = await authority().admit(snapshot(deviceFactsSHA256: other))
    else { return XCTFail("foreign device facts must not be signed") }
    XCTAssertEqual(why, .deviceFactsMismatch)
  }

  func testAnExpiredSnapshotIsRefused() async {
    // Signing a stale snapshot authorizes a write against facts that have
    // expired — the device may have moved since it was read.
    let authority = authority(nowEpochMs: 1_060_001)
    guard case .refuse(let why) = await authority.admit(snapshot(lifetimeMs: 60_000)) else {
      return XCTFail("an expired snapshot must not be signed")
    }
    guard case .snapshotExpired = why else {
      return XCTFail("expected an expiry refusal, got \(why)")
    }

    // Exactly at the boundary is still fresh — the lifetime is inclusive, and
    // an off-by-one here would refuse healthy admissions.
    let atBoundary = ArkForgeExecutionAuthority(
      plan: approvedPlan(), secret: secret, now: { 1_060_000 })
    guard case .sign = await atBoundary.admit(snapshot(lifetimeMs: 60_000)) else {
      return XCTFail("the last millisecond of a snapshot's life is still valid")
    }
  }

  func testASnapshotFromTheFutureIsRefusedRatherThanTreatedAsFresh() async {
    // A clock that disagrees is not freshness. Subtracting an observation time
    // that is ahead of `now` would underflow into an enormous age, or — worse
    // in a signed world — read as brand new.
    let authority = authority(nowEpochMs: 999_999)
    guard case .refuse(let why) = await authority.admit(snapshot(observedAtEpochMs: 1_000_000))
    else { return XCTFail("a future snapshot must not be signed") }
    guard case .snapshotFromTheFuture = why else {
      return XCTFail("expected a future-clock refusal, got \(why)")
    }
  }

  func testAnAdmissionWithNoStepIdentityIsRefused() async {
    for snapshot in [snapshot(stepID: ""), snapshot(attemptID: "")] {
      guard case .refuse(let why) = await authority().admit(snapshot) else {
        return XCTFail("an admission without step identity must not be signed")
      }
      XCTAssertEqual(why, .missingStepIdentity)
    }
  }

  func testNoRefusalEverProducesAPermit() async {
    // The property behind "零派发": every refusal path must leave the ledger
    // empty. A refusal that still recorded a permit would leave bytes that
    // could be replayed later as though they had been authorized.
    let cases: [ArkForgeStepAdmissionSnapshot] = [
      snapshot(jobID: "JOB-2"),
      snapshot(planID: "PLAN-2"),
      snapshot(planSHA256: [UInt8](repeating: 0xEE, count: 32)),
      snapshot(deviceFactsSHA256: [UInt8](repeating: 0xDD, count: 32)),
      snapshot(stepID: ""),
      snapshot(attemptID: ""),
      snapshot(observedAtEpochMs: 1),  // long expired
    ]
    let authority = authority()
    for admission in cases {
      guard case .refuse = await authority.admit(admission) else {
        return XCTFail("\(admission.stepID)/\(admission.jobID) must be refused")
      }
    }
    let issued = await authority.issuedCount
    XCTAssertEqual(issued, 0, "a refused admission must leave no permit behind")
  }

  // MARK: - AFA-AC-4: retransmission replays, never re-derives

  func testTheSameAdmissionTwiceReplaysTheSameBytes() async {
    // Not "produces an equivalent permit" — the identical bytes. Two byte
    // sequences claiming to be one permit is exactly the ambiguity the
    // integrity tag exists to remove.
    let clock = MovableClock(1_000_100)
    let authority = ArkForgeExecutionAuthority(
      plan: approvedPlan(), secret: secret, now: clock.reader)

    guard case .sign(let first) = await authority.admit(snapshot()) else {
      return XCTFail("expected a signature")
    }
    // Time moves between the two requests. A re-derived permit would carry a
    // different `issuedAt`, and therefore different bytes and a different tag,
    // which is precisely the failure this guards.
    clock.set(1_030_000)
    guard case .sign(let second) = await authority.admit(snapshot()) else {
      return XCTFail("a retransmission must still be answered")
    }

    XCTAssertEqual(first.signingBody, second.signingBody, "the bytes must be replayed")
    XCTAssertEqual(first.integrityTag, second.integrityTag)
    let issued = await authority.issuedCount
    XCTAssertEqual(issued, 1, "one admission is one permit, however many times it is asked")
  }

  func testARetransmissionIsAnsweredEvenAfterTheSnapshotWouldHaveExpired() async {
    // The authorization already happened; the snapshot's freshness governed
    // whether to *make* that decision, not whether to repeat its answer.
    // Refusing here would strand a daemon that legitimately lost the reply.
    let clock = MovableClock(1_000_100)
    let authority = ArkForgeExecutionAuthority(
      plan: approvedPlan(), secret: secret, now: clock.reader)
    guard case .sign(let first) = await authority.admit(snapshot()) else {
      return XCTFail("expected a signature")
    }
    clock.set(9_999_999)  // far past the snapshot's lifetime
    guard case .sign(let replay) = await authority.admit(snapshot()) else {
      return XCTFail("a retransmission must replay rather than expire")
    }
    XCTAssertEqual(first.signingBody, replay.signingBody)
  }

  func testADifferentAttemptIsADifferentPermit() async {
    // Retry semantics: a second attempt at the same step is a new
    // authorization, not a replay of the first. Collapsing them would let one
    // permit cover two dispatches.
    let authority = authority()
    guard case .sign(let first) = await authority.admit(snapshot(attemptID: "ATTEMPT-1")),
      case .sign(let second) = await authority.admit(snapshot(attemptID: "ATTEMPT-2"))
    else { return XCTFail("both attempts must be answered") }

    XCTAssertNotEqual(first.permitID, second.permitID)
    XCTAssertNotEqual(first.signingBody, second.signingBody)
    let issued = await authority.issuedCount
    XCTAssertEqual(issued, 2)
  }

  func testTheEpochTravelsBesideTheBytesRatherThanInsideThem() async {
    // A rotated epoch voids unconsumed permits, but it is not part of what was
    // signed: ArkForge checks it before it checks the tag. Two authorities
    // differing only in epoch must produce identical bodies.
    let planFacts = approvedPlan()
    let a = ArkForgeExecutionAuthority(
      plan: planFacts,
      secret: ArkForgePairingSecret(secret: Array("s".utf8), epoch: ArkForgePairingEpoch(1)),
      now: { 1_000_100 })
    let b = ArkForgeExecutionAuthority(
      plan: planFacts,
      secret: ArkForgePairingSecret(secret: Array("s".utf8), epoch: ArkForgePairingEpoch(2)),
      now: { 1_000_100 })
    guard case .sign(let first) = await a.admit(snapshot()),
      case .sign(let second) = await b.admit(snapshot())
    else { return XCTFail("both must sign") }

    XCTAssertEqual(first.signingBody, second.signingBody)
    XCTAssertEqual(first.integrityTag, second.integrityTag, "same secret, same tag")
    XCTAssertNotEqual(first.pairingEpoch, second.pairingEpoch)
  }
}
