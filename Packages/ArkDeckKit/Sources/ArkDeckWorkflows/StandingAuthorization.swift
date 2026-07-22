import ArkDeckCore
import ArkDeckStorage
import Foundation

// TASK-AIN-003 (CHG-2026-025). REQ-FLASH-015 standing-authorization path: the machine-
// verifiable carrier that lets an autonomous agent execute the destructive flash surface
// unattended. Authorization only ever comes from a maintainer-merged PR; this file parses
// and compares. A missing, expired, exhausted or mismatching authorization fails closed —
// there is no downgrade to "warn and continue".

// MARK: - Parse errors

public enum RockchipStandingAuthorizationParseError: Error, Equatable, Sendable {
  case invalidJSON(String)
  case unsupportedSchemaVersion(String)
  case emptyField(String)
  case invalidDigest(field: String)
  case negativeValue(field: String)
}

// MARK: - Authorization document

public struct RockchipStandingAuthorizationTarget: Codable, Equatable, Sendable {
  public let model: String
  /// SHA-256 digest of the device serial. Raw serial bytes never enter the repository
  /// (RF-001/RF-002 redaction precedent), so the authorization pins the digest.
  public let serialSHA256: String
  /// The durable binding revision the maintainer approved. Dispatch requires the current
  /// durable revision to equal this value exactly (POL-TARGET-001).
  public let bindingRevision: Int
}

/// The maintainer-approved execution plan pin set. Every field is compared verbatim
/// against the plan and environment before the first real device step; the carrier
/// (merged PR) is the authorization audit trail.
public struct RockchipStandingAuthorization: Codable, Equatable, Sendable {
  public static let supportedSchemaVersion = "1.0.0"

  public let schemaVersion: String
  public let authorizationId: String
  public let approvedBy: String
  /// Merged-PR carrier reference, e.g. "PR #N <path>@<blob-oid>".
  public let carrier: String
  public let target: RockchipStandingAuthorizationTarget
  public let firmwareArchiveSHA256: String
  public let transport: String
  public let toolchainFingerprint: String
  public let providerIdentity: String
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let recoveryPath: String
  /// ISO-8601 timestamp; the authorization is invalid at or after this instant.
  public let validUntil: String
  /// 0 = unlimited runs inside the validity window; otherwise a hard run-count ceiling.
  public let maxRuns: Int

  public var authorizationRef: String { "\(authorizationId) (\(carrier))" }

  /// Strict parse of the JSON carrier: unknown schema versions, empty identity fields,
  /// malformed digests and negative counters are rejected at the boundary so the
  /// comparison stage only ever sees a well-formed document.
  public static func parse(_ data: Data) throws -> RockchipStandingAuthorization {
    let decoded: RockchipStandingAuthorization
    do {
      decoded = try JSONDecoder().decode(RockchipStandingAuthorization.self, from: data)
    } catch {
      throw RockchipStandingAuthorizationParseError.invalidJSON(String(describing: error))
    }
    guard decoded.schemaVersion == supportedSchemaVersion else {
      throw RockchipStandingAuthorizationParseError.unsupportedSchemaVersion(
        decoded.schemaVersion)
    }
    for (field, value) in [
      ("authorizationId", decoded.authorizationId),
      ("approvedBy", decoded.approvedBy),
      ("carrier", decoded.carrier),
      ("target.model", decoded.target.model),
      ("transport", decoded.transport),
      ("toolchainFingerprint", decoded.toolchainFingerprint),
      ("providerIdentity", decoded.providerIdentity),
      ("recoveryPath", decoded.recoveryPath),
      ("validUntil", decoded.validUntil),
    ] where value.trimmingCharacters(in: .whitespaces).isEmpty {
      throw RockchipStandingAuthorizationParseError.emptyField(field)
    }
    guard decoded.maxRuns >= 0 else {
      throw RockchipStandingAuthorizationParseError.negativeValue(field: "maxRuns")
    }
    guard decoded.target.bindingRevision >= 0 else {
      throw RockchipStandingAuthorizationParseError.negativeValue(
        field: "target.bindingRevision")
    }
    return RockchipStandingAuthorization(
      schemaVersion: decoded.schemaVersion,
      authorizationId: decoded.authorizationId,
      approvedBy: decoded.approvedBy,
      carrier: decoded.carrier,
      target: RockchipStandingAuthorizationTarget(
        model: decoded.target.model,
        serialSHA256: try normalizedDigest(decoded.target.serialSHA256, field: "target.serialSHA256"),
        bindingRevision: decoded.target.bindingRevision),
      firmwareArchiveSHA256: try normalizedDigest(
        decoded.firmwareArchiveSHA256, field: "firmwareArchiveSHA256"),
      transport: decoded.transport,
      toolchainFingerprint: decoded.toolchainFingerprint,
      providerIdentity: decoded.providerIdentity,
      planDigestSHA256: try normalizedDigest(decoded.planDigestSHA256, field: "planDigestSHA256"),
      stepSetDigestSHA256: try normalizedDigest(
        decoded.stepSetDigestSHA256, field: "stepSetDigestSHA256"),
      recoveryPath: decoded.recoveryPath,
      validUntil: decoded.validUntil,
      maxRuns: decoded.maxRuns)
  }

  private static func normalizedDigest(_ value: String, field: String) throws -> String {
    let normalized = value.lowercased()
    guard normalized.count == 64,
      normalized.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    else {
      throw RockchipStandingAuthorizationParseError.invalidDigest(field: field)
    }
    return normalized
  }
}

// MARK: - Execution context (injected facts, never guessed)

/// Pre-dispatch identity readback from the physical target (machine counterpart of the
/// human physical-target confirmation). Produced by actually querying the device.
public struct RockchipDeviceIdentityReadback: Codable, Equatable, Sendable {
  public let serialDigestSHA256: String
  public let usbVendorID: UInt16
  public let usbProductID: UInt16
  public let readAtTimestamp: String

  public init(
    serialDigestSHA256: String, usbVendorID: UInt16, usbProductID: UInt16,
    readAtTimestamp: String
  ) {
    self.serialDigestSHA256 = serialDigestSHA256.lowercased()
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.readAtTimestamp = readAtTimestamp
  }
}

/// Everything the validator needs that is not in the authorization itself. All values are
/// injected by the caller from durable sources (journal, evidence ledger, device probe);
/// the validator never reads clocks or devices on its own.
public struct RockchipStandingAuthorizationContext: Equatable, Sendable {
  public let currentTimestamp: String
  /// Completed unattended runs already recorded against this authorization.
  public let priorRunCount: Int
  /// The current durable binding revision for the target device.
  public let durableBindingRevision: Int
  public let identityReadback: RockchipDeviceIdentityReadback?

  public init(
    currentTimestamp: String, priorRunCount: Int, durableBindingRevision: Int,
    identityReadback: RockchipDeviceIdentityReadback?
  ) {
    self.currentTimestamp = currentTimestamp
    self.priorRunCount = priorRunCount
    self.durableBindingRevision = durableBindingRevision
    self.identityReadback = identityReadback
  }
}

// MARK: - Validation

public enum RockchipStandingAuthorizationVerdict: Equatable, Sendable {
  case expiredOrExhausted(reason: String)
  case mismatch(fields: [String])
  case readbackMissingOrMismatch(fields: [String])
  case valid(authorizationRef: String)
}

public enum RockchipStandingAuthorizationValidator {
  /// REQ-FLASH-015 gate sequence for the unattended path: validity window and run count
  /// first, then the verbatim field-by-field comparison, then the device identity
  /// readback. Every branch that is not a full match returns a blocking verdict.
  public static func validate(
    authorization: RockchipStandingAuthorization,
    plan: RockchipFlashPlan,
    binding: RockchipRealDeviceBinding,
    context: RockchipStandingAuthorizationContext
  ) -> RockchipStandingAuthorizationVerdict {
    // 1. Validity window and run ceiling (fail closed on anything unparseable).
    let formatter = ISO8601DateFormatter()
    guard let now = formatter.date(from: context.currentTimestamp) else {
      return .expiredOrExhausted(reason: "unparseableCurrentTimestamp")
    }
    guard let validUntil = formatter.date(from: authorization.validUntil) else {
      return .expiredOrExhausted(reason: "unparseableValidUntil")
    }
    guard now < validUntil else {
      return .expiredOrExhausted(reason: "expired(validUntil=\(authorization.validUntil))")
    }
    guard context.priorRunCount >= 0 else {
      return .expiredOrExhausted(reason: "negativePriorRunCount")
    }
    if authorization.maxRuns > 0 && context.priorRunCount >= authorization.maxRuns {
      return .expiredOrExhausted(
        reason: "runsExhausted(\(context.priorRunCount)/\(authorization.maxRuns))")
    }

    // 2. Verbatim pin comparison against the plan and pinned environment.
    var mismatchedFields: [String] = []
    if authorization.target.model != RockchipFlashProfile.targetDeviceModel {
      mismatchedFields.append("targetModel")
    }
    if authorization.target.bindingRevision != context.durableBindingRevision {
      mismatchedFields.append("targetBindingRevision")
    }
    if authorization.firmwareArchiveSHA256 != plan.archiveSHA256.lowercased() {
      mismatchedFields.append("firmwareArchiveSha256")
    }
    if authorization.transport != "usb" {
      mismatchedFields.append("transport")
    }
    if authorization.toolchainFingerprint != RockchipFlashProfile.pinnedToolchainFingerprint {
      mismatchedFields.append("toolchainFingerprint")
    }
    if authorization.providerIdentity != RockchipRockUSBFlashProvider.providerIdentity {
      mismatchedFields.append("providerIdentity")
    }
    if authorization.planDigestSHA256 != plan.planDigestSHA256.lowercased() {
      mismatchedFields.append("planDigestSha256")
    }
    if authorization.stepSetDigestSHA256 != plan.stepSetDigestSHA256.lowercased() {
      mismatchedFields.append("stepSetDigestSha256")
    }
    guard mismatchedFields.isEmpty else {
      return .mismatch(fields: mismatchedFields)
    }

    // 3. Device identity readback (machine physical-target confirmation).
    guard let readback = context.identityReadback else {
      return .readbackMissingOrMismatch(fields: ["identityReadbackMissing"])
    }
    var readbackMismatches: [String] = []
    if readback.serialDigestSHA256 != authorization.target.serialSHA256 {
      readbackMismatches.append("serialDigestSha256")
    }
    if readback.usbVendorID != binding.usbVendorID
      || readback.usbProductID != binding.usbProductID
    {
      readbackMismatches.append("usbIdentity")
    }
    guard readbackMismatches.isEmpty else {
      return .readbackMissingOrMismatch(fields: readbackMismatches)
    }

    return .valid(authorizationRef: authorization.authorizationRef)
  }
}

// MARK: - Durable intent (POL-WORKFLOW-001: intent before side effect)

/// The durable record written before any authorized unattended dispatch. It binds the
/// run to the authorization carrier so the journal alone answers "who allowed this".
public struct RockchipUnattendedExecutionIntent: Codable, Equatable, Sendable {
  public let intentID: String
  public let authorizationRef: String
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let targetSerialDigestSHA256: String
  public let timestamp: String

  public static func make(
    authorization: RockchipStandingAuthorization,
    plan: RockchipFlashPlan,
    timestamp: String
  ) -> RockchipUnattendedExecutionIntent {
    let identity = RockchipRockUSBFlashProvider.sha256Hex(
      Data(
        "unattended-flash|\(authorization.authorizationRef)|\(plan.planDigestSHA256)|\(timestamp)"
          .utf8))
    return RockchipUnattendedExecutionIntent(
      intentID: "unattended-flash-intent-\(identity.prefix(16))",
      authorizationRef: authorization.authorizationRef,
      planDigestSHA256: plan.planDigestSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      targetSerialDigestSHA256: authorization.target.serialSHA256,
      timestamp: timestamp)
  }

  /// Durable form: callers persist this through the session audit store before the first
  /// real device step; the matching outcome record is written by the executing run.
  public func auditRecord(sessionID: String, jobID: String) throws -> SessionAuditRecord {
    try SessionAuditRecord(
      recordID: intentID,
      auditID: "rockusb-unattended-flash",
      correlationID: "rockusb-flash-run",
      sessionID: sessionID,
      jobID: jobID,
      category: .intent,
      timestamp: timestamp,
      details: [
        "kind": .string("unattendedFlashIntent"),
        "authorizationRef": .string(authorizationRef),
        "planDigestSha256": .string(planDigestSHA256),
        "stepSetDigestSha256": .string(stepSetDigestSHA256),
        "targetSerialDigestSha256": .string(targetSerialDigestSHA256),
      ])
  }
}
