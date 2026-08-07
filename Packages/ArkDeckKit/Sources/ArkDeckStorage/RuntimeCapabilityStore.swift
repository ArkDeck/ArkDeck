// Durable Runtime Capability store (CHG-2026-046, T03).
//
// A capability is installed once as a bounded authorization envelope.
// Every use appends a hash-linked execution node. Device envelopes may admit
// a newly materialized plan while operation, effect, target, binding and typed
// inputs stay identical. A maintainer-issued E1 workspace standing grant may
// instead authorize different typed operations and inputs inside its bounded
// target, operation and input-constraint envelope. Every node still binds its
// exact query and plan digest. A different reservation may consume the next
// use only after the preceding node has a confirmed outcome. A pending,
// legacy-unverified or outcomeUnknown node therefore fails closed, while
// retrying the same reservation remains idempotent.
//
// All writes are atomic (temp + fsync + rename + directory sync) under an
// exclusive flock, so a crash between any two syscalls leaves either the
// old or the new document, never a torn one.

import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum RuntimeCapabilityStoreError: Error, Equatable, Sendable {
  case ioFailure(String)
  case storeCorrupted(String)
  case capabilityNotFound(String)
  case capabilityAlreadyInstalled(String)
  case reservationConflict(String)
  case lineageBlocked(String)
  case outcomeConflict(String)
  case denied(RuntimeCapabilityDenial)
}

public enum RuntimeCapabilityUseOutcome: String, Equatable, Sendable, Codable {
  /// The use was durably reserved but the owning Job has not reached a
  /// confirmed terminal outcome.
  case pending
  /// The owning Job reached a known terminal outcome. Success is not
  /// required; certainty is.
  case confirmed
  /// Complete provider outcome/readback proves no mutation occurred. This is
  /// the only failed terminal that may open the next bounded destructive use.
  case safeToReflash
  /// Dispatch may have happened and dedicated readback has not resolved it.
  case outcomeUnknown
  /// A v1 ledger entry had no outcome field. It remains queryable but can
  /// never authorize a later use.
  case legacyUnverified
}

public struct RuntimeCapabilityOutcomeRecord: Equatable, Sendable, Codable {
  public let jobID: String
  public let outcome: RuntimeCapabilityUseOutcome
  public let terminalState: String
  public let recordedAtUTC: String
  public let previousRecordSHA256: String
  public let recordSHA256: String
}

public struct RuntimeCapabilityLineageEntry: Equatable, Sendable, Codable {
  public let ordinal: Int
  public let reservationID: String
  public let jobID: String
  public let consumedAtUTC: String
  public let operationReference: String
  public let effect: String
  public let targetStableIdentitySHA256: String?
  public let bindingRevision: Int?
  public let materializedPlanDigest: String?
  public let authorizationScopeFingerprintSHA256: String?
  public let queryFingerprintSHA256: String
  public let remainingUsesAfter: Int
  public let previousLineageSHA256: String?
  public let receiptSHA256: String
  public let outcomeHistory: [RuntimeCapabilityOutcomeRecord]

  public var outcome: RuntimeCapabilityUseOutcome {
    outcomeHistory.last?.outcome ?? .pending
  }

  public var lineageTipSHA256: String {
    outcomeHistory.last?.recordSHA256 ?? receiptSHA256
  }
}

public struct RuntimeCapabilityStatus: Equatable, Sendable, Codable {
  public let capability: RuntimeCapability
  public let remainingUses: Int
  public let consumptionCount: Int
  public let lineageAllowsNewExecution: Bool
  public let lineageBlocker: String?
  public let lineage: [RuntimeCapabilityLineageEntry]
}

public struct RuntimeCapabilityConsumptionReceipt: Equatable, Sendable, Codable {
  public let capabilityID: String
  public let ordinal: Int
  public let reservationID: String
  public let jobID: String
  public let consumedAtUTC: String
  public let operationReference: String
  public let queryFingerprintSHA256: String
  public let remainingUsesAfter: Int
  public let previousLineageSHA256: String?
  public let receiptSHA256: String
}

private struct StoredOutcomeRecord: Equatable, Codable {
  let jobID: String
  let outcome: RuntimeCapabilityUseOutcome
  let terminalState: String
  let recordedAtUTC: String
  let previousRecordSHA256: String
  let recordSHA256: String
}

private struct StoredConsumption: Equatable, Codable {
  let ordinal: Int
  let reservationID: String
  let jobID: String
  let consumedAtUTC: String
  let operationReference: String
  let effect: String
  let targetStableIdentitySHA256: String?
  let bindingRevision: Int?
  let materializedPlanDigest: String?
  let authorizationScopeFingerprintSHA256: String?
  let queryFingerprintSHA256: String
  let remainingUsesAfter: Int
  let previousLineageSHA256: String?
  let receiptSHA256: String
  var outcomes: [StoredOutcomeRecord]

  var currentOutcome: RuntimeCapabilityUseOutcome {
    outcomes.last?.outcome ?? .pending
  }

  var lineageTipSHA256: String {
    outcomes.last?.recordSHA256 ?? receiptSHA256
  }
}

private struct StoredRecord: Equatable, Codable {
  var capability: RuntimeCapability
  var remainingUses: Int
  var consumptions: [StoredConsumption]
}

private struct StoreDocument: Equatable, Codable {
  static let currentSchemaVersion = "2.0.0"
  var schemaVersion: String
  var records: [StoredRecord]
}

private struct StoreVersionHeader: Decodable {
  let schemaVersion: String
}

private struct LegacyStoredConsumption: Decodable {
  let reservationID: String
  let consumedAtUTC: String
  let operationReference: String
  let queryFingerprintSHA256: String
  let remainingUsesAfter: Int
}

private struct LegacyStoredRecord: Decodable {
  let capability: RuntimeCapability
  let remainingUses: Int
  let consumptions: [LegacyStoredConsumption]
}

private struct LegacyStoreDocument: Decodable {
  let schemaVersion: String
  let records: [LegacyStoredRecord]
}

public actor RuntimeCapabilityStore {
  private let directoryURL: URL
  private let documentURL: URL
  private let lockURL: URL

  public init(directoryURL: URL) throws {
    self.directoryURL = directoryURL
    self.documentURL = directoryURL.appendingPathComponent("runtime-capabilities.json")
    self.lockURL = directoryURL.appendingPathComponent(".runtime-capabilities.lock")
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw RuntimeCapabilityStoreError.ioFailure(
        "cannot create capability store directory: \(error)")
    }
  }

  // MARK: - Public API

  public func install(_ capability: RuntimeCapability) throws {
    try withExclusiveLock {
      var document = try loadDocument()
      if let existing = document.records.first(where: {
        $0.capability.capabilityID == capability.capabilityID
      }) {
        if existing.capability == capability {
          return
        }
        throw RuntimeCapabilityStoreError.capabilityAlreadyInstalled(capability.capabilityID)
      }
      document.records.append(
        StoredRecord(
          capability: capability,
          remainingUses: capability.maximumUses,
          consumptions: []))
      try persist(document)
    }
  }

  public func list() throws -> [RuntimeCapabilityStatus] {
    try withExclusiveLock {
      try loadDocument().records.map(Self.status(of:))
    }
  }

  public func inspect(capabilityID: String) throws -> RuntimeCapabilityStatus? {
    try withExclusiveLock {
      try loadDocument().records
        .first { $0.capability.capabilityID == capabilityID }
        .map(Self.status(of:))
    }
  }

  /// Validates an execution against both the installed envelope and its
  /// durable lineage without reserving a use. Submit uses this after the
  /// complete typed plan materializes, so a scope or recovery blocker is
  /// reported before a Job can reach mutation dispatch.
  public func validateNewExecution(
    capabilityID: String,
    query: RuntimeCapabilityAuthorizationQuery,
    nowUTC: String
  ) throws {
    try withExclusiveLock {
      let document = try loadDocument()
      guard
        let record = document.records.first(where: {
          $0.capability.capabilityID == capabilityID
        })
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(capabilityID)
      }
      try Self.validateNewExecution(record: record, query: query, nowUTC: nowUTC)
    }
  }

  public func revoke(capabilityID: String, atUTC: String, reason: String) throws {
    try withExclusiveLock {
      var document = try loadDocument()
      guard
        let index = document.records.firstIndex(where: {
          $0.capability.capabilityID == capabilityID
        })
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(capabilityID)
      }
      if case .revoked = document.records[index].capability.revocation {
        return
      }
      let existing = document.records[index].capability
      do {
        document.records[index].capability = try RuntimeCapability(
          capabilityID: existing.capabilityID,
          targetScope: existing.targetScope,
          operationScope: existing.operationScope,
          effectCeiling: existing.effectCeiling,
          inputConstraints: existing.inputConstraints,
          exactInputs: existing.exactInputs,
          issuedAtUTC: existing.issuedAtUTC,
          expiresAtUTC: existing.expiresAtUTC,
          maximumUses: existing.maximumUses,
          issuer: existing.issuer,
          exactPlanDigest: existing.exactPlanDigest,
          exactBindingRevision: existing.exactBindingRevision,
          revocation: .revoked(atUTC: atUTC, reason: reason))
      } catch {
        throw RuntimeCapabilityStoreError.storeCorrupted(
          "revocation produced an invalid capability: \(error)")
      }
      try persist(document)
    }
  }

  /// Atomically reserves one use for an exact Job execution. A different
  /// reservation is refused until the previous lineage node is confirmed.
  public func consume(
    capabilityID: String,
    reservationID: String,
    jobID: String? = nil,
    query: RuntimeCapabilityAuthorizationQuery,
    nowUTC: String
  ) throws -> RuntimeCapabilityConsumptionReceipt {
    guard !reservationID.isEmpty, reservationID.count <= 128 else {
      throw RuntimeCapabilityStoreError.reservationConflict("malformed reservation ID")
    }
    let resolvedJobID = jobID ?? reservationID
    guard !resolvedJobID.isEmpty, resolvedJobID.count <= 160 else {
      throw RuntimeCapabilityStoreError.reservationConflict("malformed Job ID")
    }
    return try withExclusiveLock {
      var document = try loadDocument()
      guard
        let index = document.records.firstIndex(where: {
          $0.capability.capabilityID == capabilityID
        })
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(capabilityID)
      }
      let fingerprint = Self.fingerprint(of: query)
      if let existing = document.records[index].consumptions.first(where: {
        $0.reservationID == reservationID
      }) {
        guard existing.queryFingerprintSHA256 == fingerprint,
          existing.jobID == resolvedJobID
        else {
          throw RuntimeCapabilityStoreError.reservationConflict(
            "reservation retry fields drifted for \(reservationID)")
        }
        return Self.receipt(
          capabilityID: capabilityID, consumption: existing)
      }
      let record = document.records[index]
      try Self.validateNewExecution(record: record, query: query, nowUTC: nowUTC)
      let authorizationScopeFingerprint = Self.authorizationScopeFingerprint(of: query)
      let ordinal = record.consumptions.count + 1
      let remainingAfter = record.remainingUses - 1
      let previousLineageSHA256 = record.consumptions.last?.lineageTipSHA256
      let immutable = ReceiptMaterial(
        capabilityID: capabilityID,
        ordinal: ordinal,
        reservationID: reservationID,
        jobID: resolvedJobID,
        consumedAtUTC: nowUTC,
        operationReference: "\(query.operationID)@\(query.operationVersion)",
        effect: query.effect.rawValue,
        targetStableIdentitySHA256: query.targetStableIdentitySHA256,
        bindingRevision: query.targetBindingRevision,
        materializedPlanDigest: query.planDigest,
        authorizationScopeFingerprintSHA256: authorizationScopeFingerprint,
        queryFingerprintSHA256: fingerprint,
        remainingUsesAfter: remainingAfter,
        previousLineageSHA256: previousLineageSHA256)
      let consumption = StoredConsumption(
        ordinal: immutable.ordinal,
        reservationID: immutable.reservationID,
        jobID: immutable.jobID,
        consumedAtUTC: immutable.consumedAtUTC,
        operationReference: immutable.operationReference,
        effect: immutable.effect,
        targetStableIdentitySHA256: immutable.targetStableIdentitySHA256,
        bindingRevision: immutable.bindingRevision,
        materializedPlanDigest: immutable.materializedPlanDigest,
        authorizationScopeFingerprintSHA256:
          immutable.authorizationScopeFingerprintSHA256,
        queryFingerprintSHA256: immutable.queryFingerprintSHA256,
        remainingUsesAfter: immutable.remainingUsesAfter,
        previousLineageSHA256: immutable.previousLineageSHA256,
        receiptSHA256: Self.digest(immutable),
        outcomes: [])
      document.records[index].remainingUses = remainingAfter
      document.records[index].consumptions.append(consumption)
      try persist(document)
      return Self.receipt(
        capabilityID: capabilityID, consumption: consumption)
    }
  }

  /// Appends an outcome record for the owning Job. `outcomeUnknown` may
  /// later advance to `confirmed` after dedicated readback, but a confirmed
  /// record is immutable and no other transition can widen authority.
  public func recordOutcome(
    capabilityID: String,
    reservationID: String,
    jobID: String,
    outcome: RuntimeCapabilityUseOutcome,
    terminalState: String,
    atUTC: String
  ) throws {
    guard outcome == .confirmed || outcome == .safeToReflash || outcome == .outcomeUnknown else {
      throw RuntimeCapabilityStoreError.outcomeConflict(
        "only confirmed, safeToReflash or outcomeUnknown may be recorded")
    }
    guard !jobID.isEmpty, jobID.count <= 160 else {
      throw RuntimeCapabilityStoreError.outcomeConflict("malformed outcome Job ID")
    }
    guard !terminalState.isEmpty, terminalState.count <= 80 else {
      throw RuntimeCapabilityStoreError.outcomeConflict("malformed terminal state")
    }
    try withExclusiveLock {
      var document = try loadDocument()
      guard
        let recordIndex = document.records.firstIndex(where: {
          $0.capability.capabilityID == capabilityID
        })
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(capabilityID)
      }
      guard
        let useIndex = document.records[recordIndex].consumptions.firstIndex(where: {
          $0.reservationID == reservationID
        })
      else {
        throw RuntimeCapabilityStoreError.outcomeConflict(
          "reservation \(reservationID) has no durable consumption")
      }
      var use = document.records[recordIndex].consumptions[useIndex]
      let current = use.outcomes.last
      let jobOwnsUse =
        use.jobID == jobID
        || (current?.jobID == jobID && current?.outcome != .legacyUnverified)
        || current?.outcome == .legacyUnverified
      guard jobOwnsUse else {
        throw RuntimeCapabilityStoreError.outcomeConflict(
          "outcome Job \(jobID) does not own reservation \(reservationID)")
      }
      if let current {
        if current.outcome == outcome && current.terminalState == terminalState {
          return
        }
        let resolvesUnknown =
          current.outcome == .outcomeUnknown && outcome == .confirmed
        let resolvesLegacy = current.outcome == .legacyUnverified
        guard resolvesUnknown || resolvesLegacy else {
          throw RuntimeCapabilityStoreError.outcomeConflict(
            "cannot change \(current.outcome.rawValue) to \(outcome.rawValue)")
        }
      }
      let previous = use.lineageTipSHA256
      let material = OutcomeMaterial(
        capabilityID: capabilityID,
        ordinal: use.ordinal,
        reservationID: reservationID,
        jobID: jobID,
        outcome: outcome.rawValue,
        terminalState: terminalState,
        recordedAtUTC: atUTC,
        previousRecordSHA256: previous)
      use.outcomes.append(
        StoredOutcomeRecord(
          jobID: jobID,
          outcome: outcome,
          terminalState: terminalState,
          recordedAtUTC: atUTC,
          previousRecordSHA256: previous,
          recordSHA256: Self.digest(material)))
      document.records[recordIndex].consumptions[useIndex] = use
      try persist(document)
    }
  }

  // MARK: - Internals

  private struct ReceiptMaterial: Codable {
    let capabilityID: String
    let ordinal: Int
    let reservationID: String
    let jobID: String
    let consumedAtUTC: String
    let operationReference: String
    let effect: String
    let targetStableIdentitySHA256: String?
    let bindingRevision: Int?
    let materializedPlanDigest: String?
    let authorizationScopeFingerprintSHA256: String?
    let queryFingerprintSHA256: String
    let remainingUsesAfter: Int
    let previousLineageSHA256: String?
  }

  private struct OutcomeMaterial: Codable {
    let capabilityID: String
    let ordinal: Int
    let reservationID: String
    let jobID: String
    let outcome: String
    let terminalState: String
    let recordedAtUTC: String
    let previousRecordSHA256: String
  }

  private static func status(of record: StoredRecord) -> RuntimeCapabilityStatus {
    let lineage = record.consumptions.map(Self.lineageEntry)
    let blocker: String?
    if let unresolved = lineage.first(where: {
      $0.outcome != .confirmed && $0.outcome != .safeToReflash
    }) {
      blocker = "use \(unresolved.ordinal) is \(unresolved.outcome.rawValue)"
    } else if record.remainingUses == 0 {
      blocker = "maximumUses exhausted"
    } else {
      blocker = nil
    }
    return RuntimeCapabilityStatus(
      capability: record.capability,
      remainingUses: record.remainingUses,
      consumptionCount: record.consumptions.count,
      lineageAllowsNewExecution: blocker == nil,
      lineageBlocker: blocker,
      lineage: lineage)
  }

  private static func lineageEntry(_ use: StoredConsumption) -> RuntimeCapabilityLineageEntry {
    RuntimeCapabilityLineageEntry(
      ordinal: use.ordinal,
      reservationID: use.reservationID,
      jobID: use.jobID,
      consumedAtUTC: use.consumedAtUTC,
      operationReference: use.operationReference,
      effect: use.effect,
      targetStableIdentitySHA256: use.targetStableIdentitySHA256,
      bindingRevision: use.bindingRevision,
      materializedPlanDigest: use.materializedPlanDigest,
      authorizationScopeFingerprintSHA256: use.authorizationScopeFingerprintSHA256,
      queryFingerprintSHA256: use.queryFingerprintSHA256,
      remainingUsesAfter: use.remainingUsesAfter,
      previousLineageSHA256: use.previousLineageSHA256,
      receiptSHA256: use.receiptSHA256,
      outcomeHistory: use.outcomes.map {
        RuntimeCapabilityOutcomeRecord(
          jobID: $0.jobID,
          outcome: $0.outcome,
          terminalState: $0.terminalState,
          recordedAtUTC: $0.recordedAtUTC,
          previousRecordSHA256: $0.previousRecordSHA256,
          recordSHA256: $0.recordSHA256)
      })
  }

  private static func receipt(
    capabilityID: String, consumption: StoredConsumption
  ) -> RuntimeCapabilityConsumptionReceipt {
    RuntimeCapabilityConsumptionReceipt(
      capabilityID: capabilityID,
      ordinal: consumption.ordinal,
      reservationID: consumption.reservationID,
      jobID: consumption.jobID,
      consumedAtUTC: consumption.consumedAtUTC,
      operationReference: consumption.operationReference,
      queryFingerprintSHA256: consumption.queryFingerprintSHA256,
      remainingUsesAfter: consumption.remainingUsesAfter,
      previousLineageSHA256: consumption.previousLineageSHA256,
      receiptSHA256: consumption.receiptSHA256)
  }

  private static func fingerprint(
    of query: RuntimeCapabilityAuthorizationQuery
  ) -> String {
    fingerprint(of: query, includePlan: true)
  }

  private static func authorizationScopeFingerprint(
    of query: RuntimeCapabilityAuthorizationQuery
  ) -> String {
    fingerprint(of: query, includePlan: false)
  }

  private static func fingerprint(
    of query: RuntimeCapabilityAuthorizationQuery,
    includePlan: Bool
  ) -> String {
    var components: [String] = [
      "operation=\(query.operationID)@\(query.operationVersion)",
      "effect=\(query.effect.rawValue)",
      "target=\(query.targetStableIdentitySHA256 ?? "-")",
      "bindingRevision=\(query.targetBindingRevision.map(String.init) ?? "-")",
      // Identity and scopes, but deliberately **not** the revision. A second
      // use against a different tree, or with wider write scopes, must not
      // fingerprint like the first. The revision, by contrast, changes after
      // every legitimate mutation — putting it here would make a standing
      // grant single-use, which is the failure this task set out to avoid.
      // Two different patches are already distinguished by `inputs`.
      "workspace=\(query.workspaceIdentitySHA256 ?? "-")",
      "workspaceScopes=\(query.workspaceFileScopesDigest ?? "-")",
    ]
    if includePlan {
      components.append("plan=\(query.planDigest ?? "-")")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let inputs = try? encoder.encode(query.inputs),
      let text = String(data: inputs, encoding: .utf8)
    {
      components.append("inputs=\(text)")
    } else {
      components.append("inputs=unencodable")
    }
    return SHA256Digest.hex(of: Data(components.joined(separator: "\n").utf8))
  }

  private static func validateNewExecution(
    record: StoredRecord,
    query: RuntimeCapabilityAuthorizationQuery,
    nowUTC: String
  ) throws {
    // A consumption must name the subject it acts on. Until CHG-2026-055
    // TASK-HFA-009 r2 that could only be a device; a workspace mutation is
    // E1 without a device, so the ledger accepts either a device pair or a
    // workspace triple — and still nothing else. Absent both, the capability
    // would be spent against a subject the ledger cannot identify.
    let deviceSubject =
      query.targetStableIdentitySHA256.map(isLowercaseSHA256) == true
      && (query.targetBindingRevision ?? 0) > 0
    let workspaceSubject =
      query.workspaceIdentitySHA256.map(isLowercaseSHA256) == true
      && query.workspaceRevision.map(isLowercaseSHA256) == true
      && query.workspaceFileScopesDigest.map(isLowercaseSHA256) == true
    guard deviceSubject || workspaceSubject else {
      throw RuntimeCapabilityStoreError.denied(
        RuntimeCapabilityDenial(
          reason: .targetIdentityRequired,
          detail:
            "a device (stable identity + binding revision) or workspace "
            + "(identity + revision + scope digest) subject is required"))
    }
    guard let planDigest = query.planDigest, isLowercaseSHA256(planDigest) else {
      throw RuntimeCapabilityStoreError.denied(
        RuntimeCapabilityDenial(
          reason: .planDigestRequired,
          detail: "a complete materialized plan digest is required"))
    }
    if let unresolved = record.consumptions.first(where: {
      $0.currentOutcome != .confirmed && $0.currentOutcome != .safeToReflash
    }) {
      throw RuntimeCapabilityStoreError.lineageBlocked(
        "previous use \(unresolved.ordinal) is \(unresolved.currentOutcome.rawValue); "
          + "new mutation dispatch is forbidden")
    }
    if let first = record.consumptions.first,
      !permitsWorkspaceStandingMaterialization(record.capability)
    {
      if let expectedScope = first.authorizationScopeFingerprintSHA256 {
        guard expectedScope == authorizationScopeFingerprint(of: query) else {
          throw RuntimeCapabilityStoreError.lineageBlocked(
            "operation, effect, target, binding or typed inputs drifted from "
              + "authorization lineage use 1")
        }
      } else {
        // Pre-upgrade lineage nodes did not persist a plan-independent scope
        // fingerprint. Preserve their stricter exact-query behavior.
        guard first.queryFingerprintSHA256 == fingerprint(of: query) else {
          throw RuntimeCapabilityStoreError.lineageBlocked(
            "legacy authorization lineage scope cannot be proven unchanged")
        }
      }
    }
    if case .failure(let denial) = record.capability.authorizes(
      query, nowUTC: nowUTC, remainingUses: record.remainingUses)
    {
      throw RuntimeCapabilityStoreError.denied(denial)
    }
  }

  private static func permitsWorkspaceStandingMaterialization(
    _ capability: RuntimeCapability
  ) -> Bool {
    guard capability.effectCeiling == .deviceMutation,
      capability.issuer.kind == .maintainerMergedPR,
      case .workspaceIdentity(_, let expectedRevision, _) = capability.targetScope
    else {
      return false
    }
    return expectedRevision.isEmpty
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  private static func digest<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      preconditionFailure("internal capability lineage material must encode")
    }
    return SHA256Digest.hex(of: data)
  }

  private func loadDocument() throws -> StoreDocument {
    let data: Data
    do {
      data = try Data(contentsOf: documentURL)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    {
      return StoreDocument(schemaVersion: StoreDocument.currentSchemaVersion, records: [])
    } catch {
      throw RuntimeCapabilityStoreError.ioFailure("cannot read capability store: \(error)")
    }
    var validator = StrictJSONDuplicateValidator(data: data)
    do {
      try validator.validate()
    } catch {
      throw RuntimeCapabilityStoreError.storeCorrupted("duplicate or malformed JSON: \(error)")
    }
    let version: String
    do {
      version = try JSONDecoder().decode(StoreVersionHeader.self, from: data).schemaVersion
    } catch {
      throw RuntimeCapabilityStoreError.storeCorrupted(
        "store has no readable schema version: \(error)")
    }
    let document: StoreDocument
    do {
      switch version {
      case StoreDocument.currentSchemaVersion:
        document = try JSONDecoder().decode(StoreDocument.self, from: data)
      case "1.0.0":
        document = try Self.migrate(
          JSONDecoder().decode(LegacyStoreDocument.self, from: data))
      default:
        throw RuntimeCapabilityStoreError.storeCorrupted(
          "unsupported schema version \(version)")
      }
    } catch let error as RuntimeCapabilityStoreError {
      throw error
    } catch {
      throw RuntimeCapabilityStoreError.storeCorrupted("undecodable store document: \(error)")
    }
    try Self.validate(document)
    return document
  }

  private static func migrate(_ legacy: LegacyStoreDocument) -> StoreDocument {
    StoreDocument(
      schemaVersion: StoreDocument.currentSchemaVersion,
      records: legacy.records.map { legacyRecord in
        var previousTip: String?
        let consumptions = legacyRecord.consumptions.enumerated().map { offset, old in
          let ordinal = offset + 1
          let material = ReceiptMaterial(
            capabilityID: legacyRecord.capability.capabilityID,
            ordinal: ordinal,
            reservationID: old.reservationID,
            jobID: "legacy-\(old.reservationID)",
            consumedAtUTC: old.consumedAtUTC,
            operationReference: old.operationReference,
            effect: legacyRecord.capability.effectCeiling.rawValue,
            targetStableIdentitySHA256: {
              if case .stablePhysicalIdentity(let sha) = legacyRecord.capability.targetScope {
                return sha
              }
              return nil
            }(),
            bindingRevision: legacyRecord.capability.exactBindingRevision,
            materializedPlanDigest: legacyRecord.capability.exactPlanDigest,
            authorizationScopeFingerprintSHA256: nil,
            queryFingerprintSHA256: old.queryFingerprintSHA256,
            remainingUsesAfter: old.remainingUsesAfter,
            previousLineageSHA256: previousTip)
          let receiptSHA = digest(material)
          let outcomeMaterial = OutcomeMaterial(
            capabilityID: legacyRecord.capability.capabilityID,
            ordinal: ordinal,
            reservationID: old.reservationID,
            jobID: material.jobID,
            outcome: RuntimeCapabilityUseOutcome.legacyUnverified.rawValue,
            terminalState: "legacy-unverified",
            recordedAtUTC: old.consumedAtUTC,
            previousRecordSHA256: receiptSHA)
          let outcomeSHA = digest(outcomeMaterial)
          previousTip = outcomeSHA
          return StoredConsumption(
            ordinal: ordinal,
            reservationID: old.reservationID,
            jobID: material.jobID,
            consumedAtUTC: old.consumedAtUTC,
            operationReference: old.operationReference,
            effect: material.effect,
            targetStableIdentitySHA256: material.targetStableIdentitySHA256,
            bindingRevision: material.bindingRevision,
            materializedPlanDigest: material.materializedPlanDigest,
            authorizationScopeFingerprintSHA256: nil,
            queryFingerprintSHA256: old.queryFingerprintSHA256,
            remainingUsesAfter: old.remainingUsesAfter,
            previousLineageSHA256: material.previousLineageSHA256,
            receiptSHA256: receiptSHA,
            outcomes: [
              StoredOutcomeRecord(
                jobID: material.jobID,
                outcome: .legacyUnverified,
                terminalState: "legacy-unverified",
                recordedAtUTC: old.consumedAtUTC,
                previousRecordSHA256: receiptSHA,
                recordSHA256: outcomeSHA)
            ])
        }
        return StoredRecord(
          capability: legacyRecord.capability,
          remainingUses: legacyRecord.remainingUses,
          consumptions: consumptions)
      })
  }

  private static func validate(_ document: StoreDocument) throws {
    guard document.schemaVersion == StoreDocument.currentSchemaVersion else {
      throw RuntimeCapabilityStoreError.storeCorrupted(
        "unsupported schema version \(document.schemaVersion)")
    }
    for record in document.records {
      guard record.remainingUses >= 0,
        record.remainingUses <= record.capability.maximumUses,
        record.capability.maximumUses - record.remainingUses == record.consumptions.count
      else {
        throw RuntimeCapabilityStoreError.storeCorrupted(
          "inconsistent use accounting for \(record.capability.capabilityID)")
      }
      var expectedPrevious: String?
      var reservations = Set<String>()
      for (offset, use) in record.consumptions.enumerated() {
        let expectedOrdinal = offset + 1
        guard use.ordinal == expectedOrdinal,
          use.remainingUsesAfter == record.capability.maximumUses - expectedOrdinal,
          use.previousLineageSHA256 == expectedPrevious,
          reservations.insert(use.reservationID).inserted
        else {
          throw RuntimeCapabilityStoreError.storeCorrupted(
            "invalid lineage ordering for \(record.capability.capabilityID)")
        }
        let receiptMaterial = ReceiptMaterial(
          capabilityID: record.capability.capabilityID,
          ordinal: use.ordinal,
          reservationID: use.reservationID,
          jobID: use.jobID,
          consumedAtUTC: use.consumedAtUTC,
          operationReference: use.operationReference,
          effect: use.effect,
          targetStableIdentitySHA256: use.targetStableIdentitySHA256,
          bindingRevision: use.bindingRevision,
          materializedPlanDigest: use.materializedPlanDigest,
          authorizationScopeFingerprintSHA256: use.authorizationScopeFingerprintSHA256,
          queryFingerprintSHA256: use.queryFingerprintSHA256,
          remainingUsesAfter: use.remainingUsesAfter,
          previousLineageSHA256: use.previousLineageSHA256)
        guard digest(receiptMaterial) == use.receiptSHA256 else {
          throw RuntimeCapabilityStoreError.storeCorrupted(
            "invalid receipt digest for \(record.capability.capabilityID) use \(use.ordinal)")
        }
        var expectedOutcomePrevious = use.receiptSHA256
        var priorOutcome: RuntimeCapabilityUseOutcome = .pending
        for outcome in use.outcomes {
          let allowed =
            priorOutcome == .pending
            || (priorOutcome == .outcomeUnknown && outcome.outcome == .confirmed)
            || (priorOutcome == .legacyUnverified
              && (outcome.outcome == .confirmed || outcome.outcome == .outcomeUnknown))
          guard allowed,
            outcome.outcome != .pending,
            !outcome.jobID.isEmpty,
            outcome.jobID.count <= 160,
            outcome.previousRecordSHA256 == expectedOutcomePrevious
          else {
            throw RuntimeCapabilityStoreError.storeCorrupted(
              "invalid outcome transition for \(record.capability.capabilityID) use \(use.ordinal)")
          }
          let outcomeMaterial = OutcomeMaterial(
            capabilityID: record.capability.capabilityID,
            ordinal: use.ordinal,
            reservationID: use.reservationID,
            jobID: outcome.jobID,
            outcome: outcome.outcome.rawValue,
            terminalState: outcome.terminalState,
            recordedAtUTC: outcome.recordedAtUTC,
            previousRecordSHA256: outcome.previousRecordSHA256)
          guard digest(outcomeMaterial) == outcome.recordSHA256 else {
            throw RuntimeCapabilityStoreError.storeCorrupted(
              "invalid outcome digest for \(record.capability.capabilityID) use \(use.ordinal)")
          }
          priorOutcome = outcome.outcome
          expectedOutcomePrevious = outcome.recordSHA256
        }
        expectedPrevious = use.lineageTipSHA256
      }
    }
  }

  private func persist(_ document: StoreDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(document)
    } catch {
      throw RuntimeCapabilityStoreError.ioFailure("cannot encode capability store: \(error)")
    }
    let temporaryURL = directoryURL.appendingPathComponent(
      ".runtime-capabilities.tmp.\(getpid())")
    let fd = open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw RuntimeCapabilityStoreError.ioFailure("cannot open temp store file")
    }
    defer { close(fd) }
    let written = data.withUnsafeBytes { buffer -> Int in
      guard let base = buffer.baseAddress else { return 0 }
      var total = 0
      while total < buffer.count {
        let result = write(fd, base + total, buffer.count - total)
        if result <= 0 { return total }
        total += result
      }
      return total
    }
    guard written == data.count else {
      unlink(temporaryURL.path)
      throw RuntimeCapabilityStoreError.ioFailure("short write to temp store file")
    }
    guard fsync(fd) == 0 else {
      unlink(temporaryURL.path)
      throw RuntimeCapabilityStoreError.ioFailure("fsync of temp store file failed")
    }
    guard rename(temporaryURL.path, documentURL.path) == 0 else {
      unlink(temporaryURL.path)
      throw RuntimeCapabilityStoreError.ioFailure("atomic rename of store document failed")
    }
    let dirFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if dirFD >= 0 {
      _ = fsync(dirFD)
      close(dirFD)
    }
  }

  private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    let fd = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw RuntimeCapabilityStoreError.ioFailure("cannot open capability store lock")
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      throw RuntimeCapabilityStoreError.ioFailure("cannot acquire capability store lock")
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }
}

private enum SHA256Digest {
  static func hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
