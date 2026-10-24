import ArkDeckCore
import Foundation

/// An independent readback document. A typed skip never becomes full-hash evidence.
public struct FlashVerificationDocument: Decodable, Sendable, Equatable {
  public struct Target: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { target }
    public let target: String
    public let rangeStart: UInt64
    public let rangeLength: UInt64
    public let expectedSHA256: String
    public let observedSHA256: String?
    public let outcome: String
    public let verificationStrength: String?
    public let reason: String?
    enum CodingKeys: String, CodingKey {
      case target, outcome, reason
      case rangeStart = "range_start", rangeLength = "range_length"
      case expectedSHA256 = "expected_sha256", observedSHA256 = "observed_sha256"
      case verificationStrength = "verification_strength"
    }
  }
  public let schema: String
  public let sourceJobID: String
  public let sourcePlanID: String
  public let sourcePlanSHA256: String
  public let exitCode: Int
  public let outcome: String
  public let verified: Int
  public let skipped: Int
  public let failed: Int
  public let targets: [Target]
  enum CodingKeys: String, CodingKey {
    case schema, outcome, verified, skipped, failed, targets
    case sourceJobID = "source_job_id", sourcePlanID = "source_plan_id"
    case sourcePlanSHA256 = "source_plan_sha256", exitCode = "exit_code"
  }

  var isValid: Bool {
    guard schema == "arkforge.flash-verification/v1", !sourceJobID.isEmpty,
      !sourcePlanID.isEmpty, SHA256Hex.isLowercaseSHA256(sourcePlanSHA256),
      !targets.isEmpty, Set(targets.map(\.target)).count == targets.count,
      verified == targets.filter({ $0.outcome == "verified" }).count,
      skipped == targets.filter({ $0.outcome == "typedSkip" }).count,
      failed == targets.filter({ $0.outcome == "failed" }).count,
      verified + skipped + failed == targets.count,
      exitCode == (failed > 0 ? 7 : skipped > 0 ? 9 : 0),
      outcome == (failed > 0 ? "failed" : skipped > 0 ? "partial" : "verified")
    else { return false }
    return targets.allSatisfy { row in
      guard row.rangeLength > 0, row.rangeLength <= 16 * 1024 * 1024 * 1024,
        row.rangeStart % 512 == 0,
        !row.rangeStart.addingReportingOverflow(row.rangeLength).overflow,
        SHA256Hex.isLowercaseSHA256(row.expectedSHA256),
        row.observedSHA256.map(SHA256Hex.isLowercaseSHA256) ?? true
      else { return false }
      switch row.outcome {
      case "verified": return row.observedSHA256 == row.expectedSHA256 && row.verificationStrength == "fullHash"
      case "typedSkip": return row.reason == "mounted-writable-after-boot" && row.verificationStrength == nil && row.observedSHA256 == nil
      case "failed": return row.reason?.isEmpty == false && row.verificationStrength == nil
      default: return false
      }
    }
  }
}

public struct FlashMaintenanceResult: Decodable, Sendable, Equatable {
  public let exitCode: Int
  public let outcome: String
  public let sourceJobID: String
  public let restorationJobID: String?
  public let reason: String?
  public let verification: FlashVerificationDocument?
  public let outcomeUnknown: Bool
  public let isRestoration: Bool

  enum CodingKeys: String, CodingKey {
    case schema, outcome, reason, verification
    case exitCode = "exit_code", sourceJobID = "source_job_id"
    case restorationJobID = "restoration_job_id", outcomeUnknown = "outcome_unknown"
  }
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    let schema = try fields.decode(String.self, forKey: .schema)
    exitCode = try fields.decode(Int.self, forKey: .exitCode)
    outcome = try fields.decode(String.self, forKey: .outcome)
    sourceJobID = try fields.decode(String.self, forKey: .sourceJobID)
    isRestoration = schema == "arkforge.boot-loop-restoration/v1"
    restorationJobID = try fields.decodeIfPresent(String.self, forKey: .restorationJobID)
    reason = try fields.decodeIfPresent(String.self, forKey: .reason)
    outcomeUnknown = try fields.decodeIfPresent(Bool.self, forKey: .outcomeUnknown) ?? false
    verification = isRestoration
      ? try fields.decodeIfPresent(FlashVerificationDocument.self, forKey: .verification)
      : try FlashVerificationDocument(from: decoder)
    let valid: Bool
    if isRestoration {
      if exitCode == 0, let verification, verification.isValid,
        let row = verification.targets.first
      {
        valid = outcome == "verified" && !outcomeUnknown && restorationJobID?.isEmpty == false
          && restorationJobID != sourceJobID && verification.sourceJobID == restorationJobID
          && verification.exitCode == 0 && verification.targets.count == 1
          && row.target == "ramdisk" && row.rangeStart == 121_634_816 && row.rangeLength == 4_194_304
          && row.expectedSHA256 == "bdd1f4eacbe545f5a553b529980bc487723d37554148058dd551c241abf86de4"
      } else {
        valid = exitCode == 1 && outcome == "stopped" && reason?.isEmpty == false && verification == nil
      }
    } else {
      valid = schema == "arkforge.flash-verification/v1" && verification?.isValid == true
    }
    guard valid else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid maintenance result"))
    }
  }
}
