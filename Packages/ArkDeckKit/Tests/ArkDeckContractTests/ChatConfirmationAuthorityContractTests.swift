import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class ChatConfirmationAuthorityContractTests: XCTestCase {
  private static let serial = "chat-fixture-serial"
  private static let sessionID = "session-chat"
  private static let jobID = "job-chat"
  private static let targetID = "target-chat"
  private static let topology = "42"
  private static let timestamp = "2026-08-01T12:00:00Z"

  private struct Fixture {
    let service: ChatConfirmationAdmissionService
    let assertion: RockchipChatConfirmationAssertion
    let ledger: AgentAuthorityUsageLedger
    let request: RockchipAuthorizationFactRequest
    let clock: FixedAdmissionClock
    let root: URL
  }

  func testExactChatConfirmationIsTypedDurableOneShotAndNeverRefunded() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let admission = try await fixture.service.admit(
      assertion: fixture.assertion, facts: fixture.request)
    XCTAssertEqual(admission.authorizationReference.kind, .chatConfirmation)
    XCTAssertEqual(admission.authorizationReference.effect, .destructive)
    XCTAssertNil(admission.authorizationReference.legacyStandingAuthorizationReference)
    XCTAssertEqual(admission.usageReservation.maximumUses, 1)
    XCTAssertEqual(try fixture.ledger.load().reservations.count, 1)

    let consumed = try admission.consume(at: fixture.clock.now())
    XCTAssertEqual(consumed.authorizationReference, admission.authorizationReference)
    XCTAssertThrowsError(try admission.consume(at: fixture.clock.now())) { error in
      XCTAssertEqual(error as? ChatConfirmationAdmissionError, .alreadyConsumed)
    }

    let terminal = try AgentAuthorityUsageTerminal(
      status: .outcomeUnknown, closedAt: Self.timestamp,
      externalIntentEventIDs: ["intent-chat-1"])
    _ = try fixture.ledger.close(
      reservationID: admission.usageReservation.reservationID, terminal: terminal)
    do {
      _ = try await fixture.service.admit(
        assertion: fixture.assertion, facts: fixture.request)
      XCTFail("outcomeUnknown must not refund or replay a chat confirmation")
    } catch let error as ChatConfirmationAdmissionError {
      XCTAssertEqual(error, .alreadyConsumed)
    }
  }

  func testDigestTargetBindingDriftAndMalformedShapeFailBeforeReservation() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(
      try RockchipChatConfirmationAssertion(
        confirmationDigestSHA256: "short",
        planDigestSHA256: fixture.assertion.planDigestSHA256,
        archiveDigestSHA256: fixture.assertion.archiveDigestSHA256,
        stepSetDigestSHA256: fixture.assertion.stepSetDigestSHA256,
        targetDigestSHA256: fixture.assertion.targetDigestSHA256,
        bindingRevision: 1))

    let drifts: [RockchipChatConfirmationAssertion] = try [
      assertion(from: fixture.assertion, plan: String(repeating: "1", count: 64)),
      assertion(from: fixture.assertion, archive: String(repeating: "2", count: 64)),
      assertion(from: fixture.assertion, stepSet: String(repeating: "3", count: 64)),
      assertion(from: fixture.assertion, target: String(repeating: "4", count: 64)),
      assertion(from: fixture.assertion, bindingRevision: 2),
    ]
    for drift in drifts {
      do {
        _ = try await fixture.service.admit(assertion: drift, facts: fixture.request)
        XCTFail("every asserted digest and binding field must be exact")
      } catch {
        // The exact typed error differs by which fact is rejected; every path is pre-reservation.
      }
      XCTAssertTrue(try fixture.ledger.load().reservations.isEmpty)
    }
  }

  func testConcurrentReuseHasOneWinnerAndCrashAfterReplaceStaysConsumed() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    async let first = try? fixture.service.admit(
      assertion: fixture.assertion, facts: fixture.request)
    async let second = try? fixture.service.admit(
      assertion: fixture.assertion, facts: fixture.request)
    let winners = await [first, second].compactMap { $0 }
    XCTAssertEqual(winners.count, 1)
    XCTAssertEqual(try fixture.ledger.load().reservations.count, 1)

    let crashRoot = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-chat-crash-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: crashRoot) }
    let fault = ChatOneShotFault(.afterReplace)
    let crashing = try makeFixture(
      root: crashRoot,
      faultInjector: AuthorizationUsageLedgerFaultInjector { try fault.check($0) })
    do {
      _ = try await crashing.service.admit(
        assertion: crashing.assertion, facts: crashing.request)
      XCTFail("post-replace crash must surface")
    } catch {}
    XCTAssertEqual(try crashing.ledger.load().reservations.count, 1)
    let recovered = try makeFixture(root: crashRoot)
    do {
      _ = try await recovered.service.admit(
        assertion: recovered.assertion, facts: recovered.request)
      XCTFail("a crash-consumed chat confirmation must never replay")
    } catch let error as ChatConfirmationAdmissionError {
      XCTAssertEqual(error, .alreadyConsumed)
    }
  }

  private func makeFixture(
    root: URL? = nil,
    faultInjector: AuthorizationUsageLedgerFaultInjector = .none
  ) throws -> Fixture {
    let plan = try RockchipRockUSBFlashProvider().makePlan(
      mode: .execute, archiveValidation: .valid)
    let serialDigest = Self.sha256(Self.serial)
    let targetDigest = Self.sha256(
      [
        RockchipFlashProfile.targetDeviceModel, serialDigest, "1", Self.topology,
        String(RockchipProbeEvidence.rockUSBVendorID),
        String(RockchipProbeEvidence.dayu200LoaderProductID),
      ].joined(separator: "|"))
    let binding = try CurrentDeviceBinding(
      revision: 1, connectKey: Self.topology, transport: .usb,
      identitySnapshot: try DeviceIdentitySnapshot(attributes: [
        "serial": .string(Self.serial), "usbTopology": .string(Self.topology),
      ]),
      evidence: ["fake-chat-binding"], confirmedBy: .corePolicy,
      channelProtection: .unverifiedAssumeUnprotected)
    let durable = try DurableCurrentDeviceBinding(
      reference: DeviceBindingReference(targetID: Self.targetID, revision: 1),
      binding: binding)
    let executableIdentity = ProcessExecutableIdentityReceipt(
      authorizedPath: "/opt/arkdeck/rkdeveloptool", inodeLaunchPath: "/.vol/1/2",
      device: 1, inode: 2, fileSize: 4096, mode: 0o100755,
      sha256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256)
    let clock = FixedAdmissionClock(
      reading: RockchipTrustedClockReading(
        monotonicNanoseconds: 200, auditTimestamp: Self.timestamp))
    let collector = RockchipAuthorizationFactCollector(
      planPort: FixedPlanFactPort(plan: plan),
      bindingPort: FixedBindingFactPort(value: RockchipTrustedDurableBindingFact(
        sessionID: Self.sessionID, jobID: Self.jobID, targetID: Self.targetID,
        receipt: durable)),
      toolDevicePort: FixedToolFactPort(value: RockchipTrustedToolDeviceFact(
        sessionID: Self.sessionID, jobID: Self.jobID, targetID: Self.targetID,
        observationSequence: 1, observedAtMonotonicNanoseconds: 100,
        profileIdentifier: RockchipDiscoveryIntegrationProfile.pinnedProduction.identifier,
        observation: RockchipDeviceObservation(
          deviceNumber: 1, usbVendorID: RockchipProbeEvidence.rockUSBVendorID,
          usbProductID: RockchipProbeEvidence.dayu200LoaderProductID,
          locationID: 42, mode: .loader), executableIdentity: executableIdentity)),
      prerequisitePort: FixedPrerequisiteFactPort(value: RockchipTrustedPrerequisiteFact(
        sessionID: Self.sessionID, jobID: Self.jobID, targetID: Self.targetID,
        observations: [
          RockchipPrerequisiteObservation(identifier: .loader, status: .satisfied),
          RockchipPrerequisiteObservation(identifier: .recoveryPath, status: .satisfied),
          RockchipPrerequisiteObservation(identifier: .unlocked, status: .satisfied),
        ])),
      identityReadbackPort: FixedReadbackFactPort(value: RockchipTrustedIdentityReadbackFact(
        sessionID: Self.sessionID, jobID: Self.jobID, targetID: Self.targetID,
        observationSequence: 1, observedAtMonotonicNanoseconds: 150,
        deadlineMonotonicNanoseconds: 30_000_000_150,
        observedAtTimestamp: Self.timestamp, serialDigestSHA256: serialDigest,
        usbVendorID: RockchipProbeEvidence.rockUSBVendorID,
        usbProductID: RockchipProbeEvidence.dayu200LoaderProductID,
        usbTopology: Self.topology)), clock: clock)
    let ledgerRoot = root ?? FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-chat-\(UUID().uuidString)", directoryHint: .isDirectory)
    let ledger = try AgentAuthorityUsageLedger(
      root: ledgerRoot, faultInjector: faultInjector)
    let service = ChatConfirmationAdmissionService(
      factCollector: collector, usageLedger: ledger, clock: clock,
      bindingSerialDigestSHA256: serialDigest, bindingRevision: 1)
    let assertion = try RockchipChatConfirmationAssertion(
      confirmationDigestSHA256: String(repeating: "c", count: 64),
      planDigestSHA256: plan.planDigestSHA256,
      archiveDigestSHA256: plan.archiveSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      targetDigestSHA256: targetDigest, bindingRevision: 1)
    return Fixture(
      service: service, assertion: assertion, ledger: ledger,
      request: RockchipAuthorizationFactRequest(
        archiveURL: URL(fileURLWithPath: "/tmp/chat-images.tar.gz"),
        sessionID: Self.sessionID, jobID: Self.jobID, targetID: Self.targetID,
        targetLocationSelector: Self.topology),
      clock: clock, root: ledgerRoot)
  }

  private func assertion(
    from value: RockchipChatConfirmationAssertion,
    plan: String? = nil,
    archive: String? = nil,
    stepSet: String? = nil,
    target: String? = nil,
    bindingRevision: Int? = nil
  ) throws -> RockchipChatConfirmationAssertion {
    try RockchipChatConfirmationAssertion(
      confirmationDigestSHA256: value.confirmationDigestSHA256,
      planDigestSHA256: plan ?? value.planDigestSHA256,
      archiveDigestSHA256: archive ?? value.archiveDigestSHA256,
      stepSetDigestSHA256: stepSet ?? value.stepSetDigestSHA256,
      targetDigestSHA256: target ?? value.targetDigestSHA256,
      bindingRevision: bindingRevision ?? value.bindingRevision)
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

private final class ChatOneShotFault: @unchecked Sendable {
  private let lock = NSLock()
  private let point: AuthorizationUsageLedgerFaultPoint
  private var fired = false

  init(_ point: AuthorizationUsageLedgerFaultPoint) { self.point = point }

  func check(_ candidate: AuthorizationUsageLedgerFaultPoint) throws {
    lock.lock()
    defer { lock.unlock() }
    guard candidate == point, !fired else { return }
    fired = true
    throw ChatInjectedCrash.afterReplace
  }
}

private enum ChatInjectedCrash: Error { case afterReplace }
