import ArkDeckStorage
import CryptoKit
import Foundation

/// Closed caller assertion relayed by the supervised interactive Agent after the user confirms
/// the exact plan. It deliberately contains no executable, argv, shell, Git OID, PR number or
/// standing-authorization identity. Conversation provenance is not cryptographically attestable;
/// CHG-2026-025 r7 explicitly trusts the interactive Agent to relay a real confirmation digest.
public struct RockchipChatConfirmationAssertion: Sendable, Equatable {
  public let confirmationDigestSHA256: String
  public let planDigestSHA256: String
  public let archiveDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let targetDigestSHA256: String
  public let bindingRevision: Int

  public init(
    confirmationDigestSHA256: String,
    planDigestSHA256: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    targetDigestSHA256: String,
    bindingRevision: Int
  ) throws {
    guard
      [
        confirmationDigestSHA256, planDigestSHA256, archiveDigestSHA256,
        stepSetDigestSHA256, targetDigestSHA256,
      ].allSatisfy(Self.isCanonicalSHA256), bindingRevision > 0
    else {
      throw RockchipFlashExecutionError.invalidRequest("chatConfirmation")
    }
    self.confirmationDigestSHA256 = confirmationDigestSHA256
    self.planDigestSHA256 = planDigestSHA256
    self.archiveDigestSHA256 = archiveDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.targetDigestSHA256 = targetDigestSHA256
    self.bindingRevision = bindingRevision
  }

  private static func isCanonicalSHA256(_ value: String) -> Bool {
    value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }
}

enum ChatConfirmationAdmissionError: Error, Sendable, Equatable {
  case bindingRevisionMismatch
  case planMismatch(String)
  case facts(RockchipAuthorizationFactError)
  case readbackExpired
  case alreadyConsumed
  case usage(AuthorizationUsageLedgerError)
}

struct RockchipConsumedChatConfirmationAdmission: Sendable, Equatable {
  let authorizationReference: AgentExecutionAuthorityReference
  let usageReservation: AgentAuthorityUsageReservation
  let facts: RockchipTrustedAuthorizationFacts
}

/// Invocation-scoped, non-Codable token. The durable reservation is made during admission and is
/// never refunded; this local consume gate additionally prevents two dispatches in one process.
final class RockchipChatConfirmedAdmission: @unchecked Sendable {
  let authorizationReference: AgentExecutionAuthorityReference
  let usageReservation: AgentAuthorityUsageReservation
  let facts: RockchipTrustedAuthorizationFacts

  private let lock = NSLock()
  private var consumed = false

  fileprivate init(
    authorizationReference: AgentExecutionAuthorityReference,
    usageReservation: AgentAuthorityUsageReservation,
    facts: RockchipTrustedAuthorizationFacts
  ) {
    self.authorizationReference = authorizationReference
    self.usageReservation = usageReservation
    self.facts = facts
  }

  func consume(at current: RockchipTrustedClockReading) throws
    -> RockchipConsumedChatConfirmationAdmission
  {
    lock.lock()
    defer { lock.unlock() }
    guard !consumed else { throw ChatConfirmationAdmissionError.alreadyConsumed }
    consumed = true
    guard current.monotonicNanoseconds < facts.readbackDeadlineMonotonicNanoseconds else {
      throw ChatConfirmationAdmissionError.readbackExpired
    }
    return RockchipConsumedChatConfirmationAdmission(
      authorizationReference: authorizationReference,
      usageReservation: usageReservation,
      facts: facts)
  }
}

actor ChatConfirmationAdmissionService {
  private let factCollector: any RockchipAuthorizationFactCollecting
  private let usageLedger: AgentAuthorityUsageLedger
  private let clock: any RockchipAdmissionClock
  private let bindingSerialDigestSHA256: String
  private let bindingRevision: Int

  init(
    factCollector: any RockchipAuthorizationFactCollecting,
    usageLedger: AgentAuthorityUsageLedger,
    clock: any RockchipAdmissionClock,
    bindingSerialDigestSHA256: String,
    bindingRevision: Int
  ) {
    self.factCollector = factCollector
    self.usageLedger = usageLedger
    self.clock = clock
    self.bindingSerialDigestSHA256 = bindingSerialDigestSHA256
    self.bindingRevision = bindingRevision
  }

  func admit(
    assertion: RockchipChatConfirmationAssertion,
    facts request: RockchipAuthorizationFactRequest
  ) async throws -> RockchipChatConfirmedAdmission {
    guard assertion.bindingRevision == bindingRevision else {
      throw ChatConfirmationAdmissionError.bindingRevisionMismatch
    }
    let admittedAt = clock.now()
    guard let admittedDate = RockchipStandingAuthorization.parseTimestamp(admittedAt.auditTimestamp)
    else { throw ChatConfirmationAdmissionError.readbackExpired }
    let validUntil = ISO8601DateFormatter().string(from: admittedDate.addingTimeInterval(30))
    let expectation = RockchipAuthorizationFactExpectation(
      targetModel: RockchipFlashProfile.targetDeviceModel,
      serialDigestSHA256: bindingSerialDigestSHA256,
      bindingRevision: bindingRevision,
      firmwareArchiveSHA256: assertion.archiveDigestSHA256,
      transport: "usb",
      toolchainFingerprint: RockchipFlashProfile.pinnedToolchainFingerprint,
      providerIdentity: RockchipRockUSBFlashProvider.providerIdentity,
      planDigestSHA256: assertion.planDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      validUntil: validUntil)

    let facts: RockchipTrustedAuthorizationFacts
    do {
      facts = try await factCollector.collect(request: request, expectation: expectation)
    } catch let error as RockchipAuthorizationFactError {
      throw ChatConfirmationAdmissionError.facts(error)
    } catch {
      throw ChatConfirmationAdmissionError.facts(.factPortFailed(name: "unknown"))
    }
    guard facts.plan.planDigestSHA256 == assertion.planDigestSHA256 else {
      throw ChatConfirmationAdmissionError.planMismatch("planDigestSHA256")
    }
    guard facts.plan.archiveSHA256 == assertion.archiveDigestSHA256 else {
      throw ChatConfirmationAdmissionError.planMismatch("archiveDigestSHA256")
    }
    guard facts.plan.stepSetDigestSHA256 == assertion.stepSetDigestSHA256 else {
      throw ChatConfirmationAdmissionError.planMismatch("stepSetDigestSHA256")
    }
    guard facts.targetDigestSHA256 == assertion.targetDigestSHA256 else {
      throw ChatConfirmationAdmissionError.planMismatch("targetDigestSHA256")
    }

    let beforeReservation = clock.now()
    guard beforeReservation.monotonicNanoseconds < facts.readbackDeadlineMonotonicNanoseconds,
      let reservationDate = RockchipStandingAuthorization.parseTimestamp(
        beforeReservation.auditTimestamp)
    else { throw ChatConfirmationAdmissionError.readbackExpired }
    let reference = try AgentExecutionAuthorityReference.validatedChatConfirmation(
      confirmationDigestSHA256: assertion.confirmationDigestSHA256,
      planDigestSHA256: assertion.planDigestSHA256,
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      targetDigestSHA256: assertion.targetDigestSHA256,
      confirmedAt: beforeReservation.auditTimestamp)
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: reference, jobID: request.jobID,
      operationDigestSHA256: assertion.planDigestSHA256,
      targetDigestSHA256: assertion.targetDigestSHA256)
    let reservation = try AgentAuthorityUsageReservation(
      reservationID: reservationID, authorizationRef: reference,
      ordinal: 1, maximumUses: 1, maximumConcurrentJobs: 1,
      jobID: request.jobID,
      operationDigestSHA256: assertion.planDigestSHA256,
      targetDigestSHA256: assertion.targetDigestSHA256,
      reservedAt: beforeReservation.auditTimestamp,
      forwardLeaseExpiresAt: ISO8601DateFormatter().string(
        from: reservationDate.addingTimeInterval(30)),
      compensationLeaseExpiresAt: ISO8601DateFormatter().string(
        from: reservationDate.addingTimeInterval(120)))
    do {
      _ = try usageLedger.reserve(reservation)
    } catch let error as AuthorizationUsageLedgerError {
      if case .usageLimitExceeded = error {
        throw ChatConfirmationAdmissionError.alreadyConsumed
      }
      throw ChatConfirmationAdmissionError.usage(error)
    }
    return RockchipChatConfirmedAdmission(
      authorizationReference: reference, usageReservation: reservation, facts: facts)
  }
}
