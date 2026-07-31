// The bounded source-repair proposal carried by the harness
// (CHG-2026-055, TASK-HFA-003).
//
// A patch is data, never a command.  This type closes the model-facing
// surface before the workspace provider sees it: one UTF-8 unified diff,
// one exact digest, and an exact set of relative paths.  ProjectProfile and
// live-workspace checks stay in ArkDeckWorkflows because they require host
// facts; all syntax and size checks live here so malformed proposals cannot
// become durable dispatch intents in any composition.

import CryptoKit
import Foundation

public struct HarnessPatchLimits: Equatable, Sendable, Codable {
  public let maxPatchBytes: Int
  public let maxTouchedFiles: Int
  public let maxExpectedChangedSymbols: Int

  public init(
    maxPatchBytes: Int = 256 * 1024,
    maxTouchedFiles: Int = 32,
    maxExpectedChangedSymbols: Int = 256
  ) {
    self.maxPatchBytes = maxPatchBytes
    self.maxTouchedFiles = maxTouchedFiles
    self.maxExpectedChangedSymbols = maxExpectedChangedSymbols
  }

  public static let `default` = HarnessPatchLimits()
}

public enum HarnessPatchProposalError: Error, Equatable, Sendable {
  case missingField(String)
  case invalidField(String)
  case patchTooLarge(actual: Int, limit: Int)
  case tooManyFiles(actual: Int, limit: Int)
  case tooManySymbols(actual: Int, limit: Int)
  case digestMismatch
  case unsafePatch(String)
  case touchedFilesMismatch

  public var reasonCode: String {
    switch self {
    case .missingField(let field): return "patchMissingField:\(field)"
    case .invalidField(let field): return "patchInvalidField:\(field)"
    case .patchTooLarge(let actual, let limit): return "patchTooLarge:\(actual)>\(limit)"
    case .tooManyFiles(let actual, let limit): return "patchTooManyFiles:\(actual)>\(limit)"
    case .tooManySymbols(let actual, let limit): return "patchTooManySymbols:\(actual)>\(limit)"
    case .digestMismatch: return "patchDigestMismatch"
    case .unsafePatch(let reason): return "unsafePatch:\(reason)"
    case .touchedFilesMismatch: return "patchTouchedFilesMismatch"
    }
  }
}

public struct HarnessPatchProposal: Equatable, Sendable, Codable {
  public let baseWorkspaceRevision: String
  public let patchSHA256: String
  public let unifiedDiff: String
  public let touchedFiles: [String]
  public let expectedChangedSymbols: [String]

  enum CodingKeys: String, CodingKey {
    case baseWorkspaceRevision
    case patchSHA256 = "patchSha256"
    case unifiedDiff
    case touchedFiles
    case expectedChangedSymbols
  }

  public init(
    baseWorkspaceRevision: String,
    patchSHA256: String,
    unifiedDiff: String,
    touchedFiles: [String],
    expectedChangedSymbols: [String],
    limits: HarnessPatchLimits = .default
  ) throws {
    let patchBytes = Data(unifiedDiff.utf8)
    guard Self.isSHA256(baseWorkspaceRevision) else {
      throw HarnessPatchProposalError.invalidField("baseWorkspaceRevision")
    }
    guard Self.isSHA256(patchSHA256) else {
      throw HarnessPatchProposalError.invalidField("patchSha256")
    }
    guard !patchBytes.isEmpty, !unifiedDiff.contains("\0") else {
      throw HarnessPatchProposalError.invalidField("unifiedDiff")
    }
    guard patchBytes.count <= limits.maxPatchBytes else {
      throw HarnessPatchProposalError.patchTooLarge(
        actual: patchBytes.count, limit: limits.maxPatchBytes)
    }
    guard !touchedFiles.isEmpty, touchedFiles.count <= limits.maxTouchedFiles else {
      throw HarnessPatchProposalError.tooManyFiles(
        actual: touchedFiles.count, limit: limits.maxTouchedFiles)
    }
    guard expectedChangedSymbols.count <= limits.maxExpectedChangedSymbols else {
      throw HarnessPatchProposalError.tooManySymbols(
        actual: expectedChangedSymbols.count, limit: limits.maxExpectedChangedSymbols)
    }
    guard Set(touchedFiles).count == touchedFiles.count,
      touchedFiles.allSatisfy(Self.isSafeRelativePath)
    else {
      throw HarnessPatchProposalError.invalidField("touchedFiles")
    }
    guard expectedChangedSymbols.allSatisfy({ symbol in
      !symbol.isEmpty && symbol.utf8.count <= 256 && !symbol.contains("\0")
        && !symbol.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }) else {
      throw HarnessPatchProposalError.invalidField("expectedChangedSymbols")
    }
    let actualDigest = SHA256.hash(data: patchBytes)
      .map { String(format: "%02x", $0) }.joined()
    guard actualDigest == patchSHA256 else {
      throw HarnessPatchProposalError.digestMismatch
    }
    let parsedPaths = try Self.paths(in: unifiedDiff)
    guard Set(parsedPaths) == Set(touchedFiles) else {
      throw HarnessPatchProposalError.touchedFilesMismatch
    }
    self.baseWorkspaceRevision = baseWorkspaceRevision
    self.patchSHA256 = patchSHA256
    self.unifiedDiff = unifiedDiff
    self.touchedFiles = touchedFiles.sorted()
    self.expectedChangedSymbols = expectedChangedSymbols
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      baseWorkspaceRevision: container.decode(String.self, forKey: .baseWorkspaceRevision),
      patchSHA256: container.decode(String.self, forKey: .patchSHA256),
      unifiedDiff: container.decode(String.self, forKey: .unifiedDiff),
      touchedFiles: container.decode([String].self, forKey: .touchedFiles),
      expectedChangedSymbols: container.decode(
        [String].self, forKey: .expectedChangedSymbols))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(baseWorkspaceRevision, forKey: .baseWorkspaceRevision)
    try container.encode(patchSHA256, forKey: .patchSHA256)
    try container.encode(unifiedDiff, forKey: .unifiedDiff)
    try container.encode(touchedFiles, forKey: .touchedFiles)
    try container.encode(expectedChangedSymbols, forKey: .expectedChangedSymbols)
  }

  public static func parse(
    _ fields: [String: JSONValue], limits: HarnessPatchLimits = .default
  ) throws -> HarnessPatchProposal {
    func string(_ key: String) throws -> String {
      guard case .string(let value)? = fields[key] else {
        throw HarnessPatchProposalError.missingField(key)
      }
      return value
    }
    func strings(_ key: String) throws -> [String] {
      guard case .array(let values)? = fields[key] else {
        throw HarnessPatchProposalError.missingField(key)
      }
      return try values.map { value in
        guard case .string(let text) = value else {
          throw HarnessPatchProposalError.invalidField(key)
        }
        return text
      }
    }
    return try HarnessPatchProposal(
      baseWorkspaceRevision: string("baseWorkspaceRevision"),
      patchSHA256: string("patchSha256"),
      unifiedDiff: string("unifiedDiff"),
      touchedFiles: strings("touchedFiles"),
      expectedChangedSymbols: strings("expectedChangedSymbols"),
      limits: limits)
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
      !path.contains(where: { "*?[]".contains($0) }),
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      return false
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      && path != ".git" && !path.hasPrefix(".git/") && !path.contains("/.git/")
  }

  private static func paths(in diff: String) throws -> [String] {
    var found = Set<String>()
    var sectionPath: String?
    var readingHeaders = false
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.hasPrefix("GIT binary patch") || line.hasPrefix("Binary files ")
        || line.hasPrefix("rename from ") || line.hasPrefix("rename to ")
        || line.hasPrefix("copy from ") || line.hasPrefix("copy to ")
      {
        throw HarnessPatchProposalError.unsafePatch("binaryRenameOrCopy")
      }
      if line.hasPrefix("diff --git ") {
        let parts = line.split(separator: " ")
        guard parts.count == 4,
          let old = normalized(String(parts[2]), prefix: "a/"),
          let new = normalized(String(parts[3]), prefix: "b/"),
          old == new
        else {
          throw HarnessPatchProposalError.unsafePatch("diffHeaderPath")
        }
        sectionPath = old
        readingHeaders = true
        found.insert(new)
      } else if line.hasPrefix("@@ ") {
        readingHeaders = false
      } else if readingHeaders && (line.hasPrefix("--- ") || line.hasPrefix("+++ ")) {
        guard let sectionPath else {
          throw HarnessPatchProposalError.unsafePatch("unifiedHeaderWithoutDiffHeader")
        }
        let raw = String(line.dropFirst(4)).split(separator: "\t").first.map(String.init) ?? ""
        if raw != "/dev/null" {
          let prefix = line.hasPrefix("--- ") ? "a/" : "b/"
          guard let path = normalized(raw, prefix: prefix), path == sectionPath else {
            throw HarnessPatchProposalError.unsafePatch("unifiedHeaderPath")
          }
        }
      }
    }
    guard sectionPath != nil, !found.isEmpty else {
      throw HarnessPatchProposalError.unsafePatch("missingFileHeader")
    }
    return found.sorted()
  }

  private static func normalized(_ raw: String, prefix: String) -> String? {
    guard raw.hasPrefix(prefix) else { return nil }
    let value = String(raw.dropFirst(prefix.count))
    return isSafeRelativePath(value) ? value : nil
  }
}

/// Durable, evidence-derived progress for one source repair.  It is encoded
/// inside `observedState`, whose reducer already restricts writers to job
/// observation/evaluation paths.
public struct HarnessRepairAttempt: Equatable, Sendable {
  public static let observedStateKey = "repairAttempt"

  public let proposal: HarnessPatchProposal
  public let patchAttemptRef: String?
  public let patchRevision: String?
  public let buildSourceRevision: String?
  public let buildOutputDigest: String?
  public let buildOutputArtifactLease: String?
  public let testsPassed: Bool
  public let deployedDigest: String?
  public let rollbackRequired: Bool
  public let reverted: Bool

  public init(
    proposal: HarnessPatchProposal,
    patchAttemptRef: String? = nil,
    patchRevision: String? = nil,
    buildSourceRevision: String? = nil,
    buildOutputDigest: String? = nil,
    buildOutputArtifactLease: String? = nil,
    testsPassed: Bool = false,
    deployedDigest: String? = nil,
    rollbackRequired: Bool = false,
    reverted: Bool = false
  ) {
    self.proposal = proposal
    self.patchAttemptRef = patchAttemptRef
    self.patchRevision = patchRevision
    self.buildSourceRevision = buildSourceRevision
    self.buildOutputDigest = buildOutputDigest
    self.buildOutputArtifactLease = buildOutputArtifactLease
    self.testsPassed = testsPassed
    self.deployedDigest = deployedDigest
    self.rollbackRequired = rollbackRequired
    self.reverted = reverted
  }

  public var json: JSONValue {
    var values: [String: JSONValue] = [
      "baseWorkspaceRevision": .string(proposal.baseWorkspaceRevision),
      "patchSha256": .string(proposal.patchSHA256),
      "unifiedDiff": .string(proposal.unifiedDiff),
      "touchedFiles": .array(proposal.touchedFiles.map(JSONValue.string)),
      "expectedChangedSymbols": .array(proposal.expectedChangedSymbols.map(JSONValue.string)),
      "testsPassed": .bool(testsPassed),
      "rollbackRequired": .bool(rollbackRequired),
      "reverted": .bool(reverted),
    ]
    if let patchAttemptRef { values["patchAttemptRef"] = .string(patchAttemptRef) }
    if let patchRevision { values["patchRevision"] = .string(patchRevision) }
    if let buildSourceRevision { values["buildSourceRevision"] = .string(buildSourceRevision) }
    if let buildOutputDigest { values["buildOutputDigest"] = .string(buildOutputDigest) }
    if let buildOutputArtifactLease {
      values["buildOutputArtifactLease"] = .string(buildOutputArtifactLease)
    }
    if let deployedDigest { values["deployedDigest"] = .string(deployedDigest) }
    return .object(values)
  }

  public init?(json: JSONValue) {
    guard case .object(let fields) = json,
      let proposal = try? HarnessPatchProposal.parse(fields)
    else { return nil }
    func string(_ key: String) -> String? {
      guard case .string(let value)? = fields[key] else { return nil }
      return value
    }
    func boolean(_ key: String) -> Bool {
      guard case .bool(let value)? = fields[key] else { return false }
      return value
    }
    self.init(
      proposal: proposal,
      patchAttemptRef: string("patchAttemptRef"),
      patchRevision: string("patchRevision"),
      buildSourceRevision: string("buildSourceRevision"),
      buildOutputDigest: string("buildOutputDigest"),
      buildOutputArtifactLease: string("buildOutputArtifactLease"),
      testsPassed: boolean("testsPassed"),
      deployedDigest: string("deployedDigest"),
      rollbackRequired: boolean("rollbackRequired"),
      reverted: boolean("reverted"))
  }

  public func updating(
    patchAttemptRef: String? = nil,
    patchRevision: String? = nil,
    buildSourceRevision: String? = nil,
    buildOutputDigest: String? = nil,
    buildOutputArtifactLease: String? = nil,
    testsPassed: Bool? = nil,
    deployedDigest: String? = nil,
    rollbackRequired: Bool? = nil,
    reverted: Bool? = nil
  ) -> HarnessRepairAttempt {
    HarnessRepairAttempt(
      proposal: proposal,
      patchAttemptRef: patchAttemptRef ?? self.patchAttemptRef,
      patchRevision: patchRevision ?? self.patchRevision,
      buildSourceRevision: buildSourceRevision ?? self.buildSourceRevision,
      buildOutputDigest: buildOutputDigest ?? self.buildOutputDigest,
      buildOutputArtifactLease: buildOutputArtifactLease ?? self.buildOutputArtifactLease,
      testsPassed: testsPassed ?? self.testsPassed,
      deployedDigest: deployedDigest ?? self.deployedDigest,
      rollbackRequired: rollbackRequired ?? self.rollbackRequired,
      reverted: reverted ?? self.reverted)
  }
}

extension HarnessTaskSnapshot {
  public var repairAttempt: HarnessRepairAttempt? {
    observedState[HarnessRepairAttempt.observedStateKey].flatMap(HarnessRepairAttempt.init(json:))
  }
}
