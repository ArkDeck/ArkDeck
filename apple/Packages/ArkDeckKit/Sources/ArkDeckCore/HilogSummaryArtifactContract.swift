import Foundation

/// Statistics over the default HiLog line header, not a device-health verdict.
/// Log bodies, tags, process IDs and timestamps never enter the derived result.
package struct HilogSummaryAnalysis: Codable, Equatable, Sendable {
  package enum Coverage: String, Codable, Sendable {
    case complete, partial, unrecognized, empty
  }

  package let schemaVersion: String
  package let analyzerRef: String
  package let analyzerVersion: String
  package let scope: String
  package let redaction: String
  package let sourceSHA256: String
  package let sourceByteCount: Int
  package let headerCoverage: Coverage
  package let lineCount: Int
  package let blankLineCount: Int
  package let unrecognizedLineCount: Int
  package let levelCounts: [String: Int]

  package func canonicalData() throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(self)
  }

  package init(
    schemaVersion: String,
    analyzerRef: String,
    analyzerVersion: String,
    scope: String,
    redaction: String,
    sourceSHA256: String,
    sourceByteCount: Int,
    headerCoverage: Coverage,
    lineCount: Int,
    blankLineCount: Int,
    unrecognizedLineCount: Int,
    levelCounts: [String: Int]
  ) {
    self.schemaVersion = schemaVersion
    self.analyzerRef = analyzerRef
    self.analyzerVersion = analyzerVersion
    self.scope = scope
    self.redaction = redaction
    self.sourceSHA256 = sourceSHA256
    self.sourceByteCount = sourceByteCount
    self.headerCoverage = headerCoverage
    self.lineCount = lineCount
    self.blankLineCount = blankLineCount
    self.unrecognizedLineCount = unrecognizedLineCount
    self.levelCounts = levelCounts
  }
}

package struct HilogSummaryDerivedArtifact: Codable, Equatable, Sendable {
  package let sourceArtifactID: String
  package let analyzerExecutableSHA256: String
  package let analyzerOutputSHA256: String
  package let analyzerOutputByteCount: Int
  package let result: HilogSummaryAnalysis

  package init(
    sourceArtifactID: String,
    analyzerExecutableSHA256: String,
    analyzerOutputSHA256: String,
    analyzerOutputByteCount: Int,
    result: HilogSummaryAnalysis
  ) {
    self.sourceArtifactID = sourceArtifactID
    self.analyzerExecutableSHA256 = analyzerExecutableSHA256
    self.analyzerOutputSHA256 = analyzerOutputSHA256
    self.analyzerOutputByteCount = analyzerOutputByteCount
    self.result = result
  }
}

/// Pure artifact format and integrity rules shared by the producer and reader.
/// This contract contains no process, provider or admission behavior.
package enum HilogSummaryArtifactContract {
  package static let analyzerRef = "hilog-summary@1"
  package static let analyzerVersion = "1.0.0"
  package static let maximumInputBytes = 512 * 1024 * 1024
  package static let maximumOutputBytes = 8 * 1024
  /// Shared by dispatch and the read-only App projection. The latter checks
  /// recorded provenance, not the current contents of the raw source Artifact.
  package static func validateReport(
    _ bytes: Data, sourceSHA256: String, sourceByteCount: Int
  ) -> Bool {
    guard bytes.count <= maximumOutputBytes,
      let result = try? JSONDecoder().decode(HilogSummaryAnalysis.self, from: bytes),
      (try? result.canonicalData()) == bytes,
      result.schemaVersion == "1.0.0",
      result.analyzerRef == analyzerRef,
      result.analyzerVersion == analyzerVersion,
      result.scope == "default-hilog-header-lines",
      result.redaction == "content-and-identifiers-omitted",
      result.sourceSHA256 == sourceSHA256,
      result.sourceByteCount == sourceByteCount,
      result.sourceByteCount > 0, result.sourceByteCount <= maximumInputBytes,
      result.lineCount >= 1, result.lineCount <= result.sourceByteCount,
      result.blankLineCount >= 0, result.blankLineCount <= result.lineCount,
      result.unrecognizedLineCount >= 0, result.unrecognizedLineCount <= result.lineCount,
      Set(result.levelCounts.keys) == ["D", "I", "W", "E", "F"],
      result.levelCounts.values.allSatisfy({ $0 >= 0 && $0 <= result.lineCount })
    else { return false }
    let recognized = result.levelCounts.values.reduce(0, +)
    return recognized + result.blankLineCount + result.unrecognizedLineCount == result.lineCount
      && result.headerCoverage
        == coverage(
          lines: result.lineCount, blanks: result.blankLineCount,
          unknown: result.unrecognizedLineCount)
  }

  package static func coverage(
    lines: Int, blanks: Int, unknown: Int
  ) -> HilogSummaryAnalysis.Coverage {
    if lines == blanks { return .empty }
    if unknown == lines - blanks { return .unrecognized }
    return unknown == 0 ? .complete : .partial
  }
}
