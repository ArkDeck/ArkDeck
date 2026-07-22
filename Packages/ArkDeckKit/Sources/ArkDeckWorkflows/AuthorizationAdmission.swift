import ArkDeckStorage
import CryptoKit
import Foundation

// TASK-AIN-006 (CHG-2026-025): ordered grant -> trusted facts -> durable usage admission.
// This layer cannot append a workflow intent or dispatch a process/device command.

struct AuthorizationAdmissionRequest: Sendable, Equatable {
  let authorizationID: String
  let facts: RockchipAuthorizationFactRequest
}

enum AuthorizationAdmissionError: Error, Sendable, Equatable {
  case provenance(AuthorizationProvenanceError)
  case facts(RockchipAuthorizationFactError)
  case usage(AuthorizationUsageLedgerError)
  case readbackExpired
  case reservationAlreadyTerminal
  case reservationRaceDidNotConverge
  case capabilityAlreadyConsumed
  case authorizationExpiredAtConsumption
}

struct RockchipConsumedAuthorizationAdmission: Sendable, Equatable {
  let authorizationReference: AuthorizationReference
  let usageReservation: AuthorizationUsageReservation
  let facts: RockchipTrustedAuthorizationFacts
}

/// Package-owned, one-shot admission token for TASK-AIN-007. It is a reference type so copying a
/// value cannot duplicate its consume state. It is non-Codable and has no initializer outside the
/// ArkDeckWorkflows module.
final class RockchipAuthorizedAgentAdmission: @unchecked Sendable {
  let authorizationReference: AuthorizationReference
  let usageReservation: AuthorizationUsageReservation
  let facts: RockchipTrustedAuthorizationFacts

  private let lock = NSLock()
  private var consumed = false

  fileprivate init(
    grant: VerifiedAuthorizationGrant,
    usageReservation: AuthorizationUsageReservation,
    facts: RockchipTrustedAuthorizationFacts
  ) {
    authorizationReference = grant.authorizationReference
    self.usageReservation = usageReservation
    self.facts = facts
  }

  /// AIN-007 must call this immediately before its first real Step. Expiry consumes the token and
  /// fails closed; it cannot be refreshed from journal data or a caller timestamp.
  func consume(at current: RockchipTrustedClockReading) throws
    -> RockchipConsumedAuthorizationAdmission
  {
    lock.lock()
    defer { lock.unlock() }
    guard !consumed else { throw AuthorizationAdmissionError.capabilityAlreadyConsumed }
    consumed = true
    guard RockchipStandingAuthorization.isCanonicalTimestamp(current.auditTimestamp),
      let now = RockchipStandingAuthorization.parseTimestamp(current.auditTimestamp),
      let validUntil = RockchipStandingAuthorization.parseTimestamp(facts.authorizationValidUntil),
      now < validUntil
    else { throw AuthorizationAdmissionError.authorizationExpiredAtConsumption }
    guard current.monotonicNanoseconds < facts.readbackDeadlineMonotonicNanoseconds else {
      throw AuthorizationAdmissionError.readbackExpired
    }
    return RockchipConsumedAuthorizationAdmission(
      authorizationReference: authorizationReference,
      usageReservation: usageReservation,
      facts: facts)
  }
}

actor AuthorizationAdmissionService {
  private let resolver: MaintainerMergedAuthorizationResolver
  private let factCollector: RockchipAuthorizationFactCollector
  private let usageLedger: AuthorizationUsageLedger
  private let clock: any RockchipAdmissionClock

  init(
    resolver: MaintainerMergedAuthorizationResolver,
    factCollector: RockchipAuthorizationFactCollector,
    usageLedger: AuthorizationUsageLedger,
    clock: any RockchipAdmissionClock
  ) {
    self.resolver = resolver
    self.factCollector = factCollector
    self.usageLedger = usageLedger
    self.clock = clock
  }

  func admit(_ request: AuthorizationAdmissionRequest) async throws
    -> RockchipAuthorizedAgentAdmission
  {
    let grant: VerifiedAuthorizationGrant
    do { grant = try await resolver.resolve(authorizationID: request.authorizationID) } catch let
      error as AuthorizationProvenanceError
    {
      throw AuthorizationAdmissionError.provenance(error)
    } catch {
      throw AuthorizationAdmissionError.provenance(.sourceUnavailable)
    }

    let facts: RockchipTrustedAuthorizationFacts
    do { facts = try await factCollector.collect(request: request.facts, grant: grant) } catch let
      error as RockchipAuthorizationFactError
    {
      throw AuthorizationAdmissionError.facts(error)
    } catch {
      throw AuthorizationAdmissionError.facts(.factPortFailed(name: "unknown"))
    }

    let beforeReservation = clock.now()
    guard beforeReservation.monotonicNanoseconds < facts.readbackDeadlineMonotonicNanoseconds else {
      throw AuthorizationAdmissionError.readbackExpired
    }
    let reservation: AuthorizationUsageReservation
    do {
      reservation = try reserveUsage(
        grant: grant, facts: facts, jobID: request.facts.jobID,
        reservedAt: beforeReservation.auditTimestamp)
    } catch let error as AuthorizationAdmissionError {
      throw error
    } catch let error as AuthorizationUsageLedgerError {
      throw AuthorizationAdmissionError.usage(error)
    } catch {
      throw AuthorizationAdmissionError.usage(.invalidRecord("unknown usage failure"))
    }
    return RockchipAuthorizedAgentAdmission(
      grant: grant, usageReservation: reservation, facts: facts)
  }

  private func reserveUsage(
    grant: VerifiedAuthorizationGrant,
    facts: RockchipTrustedAuthorizationFacts,
    jobID: String,
    reservedAt: String
  ) throws -> AuthorizationUsageReservation {
    let reservationID = Self.reservationID(
      reference: grant.authorizationReference, jobID: jobID,
      planDigestSHA256: facts.plan.planDigestSHA256,
      targetDigestSHA256: facts.targetDigestSHA256)

    for _ in 0..<8 {
      let document = try usageLedger.load()
      if let existing = document.reservations.first(where: {
        $0.reservationID == reservationID
      }) {
        guard existing.terminal == nil else {
          throw AuthorizationAdmissionError.reservationAlreadyTerminal
        }
        guard existing.authorizationRef == grant.authorizationReference,
          existing.maxRuns == grant.authorization.maxRuns,
          existing.jobID == jobID,
          existing.planDigestSHA256 == facts.plan.planDigestSHA256,
          existing.targetDigestSHA256 == facts.targetDigestSHA256
        else {
          throw AuthorizationUsageLedgerError.reservationConflict(
            "deterministic reservation fields drifted")
        }
        return try usageLedger.reserve(existing)
      }

      let sameAuthorization = document.reservations.filter {
        $0.authorizationRef.authorizationID == grant.authorizationReference.authorizationID
      }
      let nextOrdinal = (sameAuthorization.map(\.ordinal).max() ?? 0) + 1
      let candidate = try AuthorizationUsageReservation(
        reservationID: reservationID,
        authorizationRef: grant.authorizationReference,
        ordinal: nextOrdinal,
        maxRuns: grant.authorization.maxRuns,
        jobID: jobID,
        planDigestSHA256: facts.plan.planDigestSHA256,
        targetDigestSHA256: facts.targetDigestSHA256,
        reservedAt: reservedAt)
      do {
        return try usageLedger.reserve(candidate)
      } catch AuthorizationUsageLedgerError.reservationConflict {
        // Another admission won between load and reserve. Reload and either return the exact
        // idempotent reservation or calculate the next ordinal. No facts are recollected and no
        // reservation is refunded.
        continue
      }
    }
    throw AuthorizationAdmissionError.reservationRaceDidNotConverge
  }

  private static func reservationID(
    reference: AuthorizationReference,
    jobID: String,
    planDigestSHA256: String,
    targetDigestSHA256: String
  ) -> String {
    let canonical = [
      reference.authorizationID, reference.mainCommitOID,
      reference.authorizationBlobOID, String(reference.approvalPRNumber), jobID,
      planDigestSHA256, targetDigestSHA256,
    ].joined(separator: "|")
    let digest = SHA256.hash(data: Data(canonical.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return "ain006-\(digest.prefix(32))"
  }
}
