import ArkDeckCore
import Foundation

/// A verified summary Artifact and its recorded provenance. No source log,
/// transport, operation execution or device-health verdict is exposed here.
public struct DiagnosticHilogSummaryPresentation: Sendable, Equatable {
  public let jobID: String
  public let sourceJobID: String
  public let sourceArtifactID: String
  public let sourceSHA256: String
  public let sourceByteCount: Int
  public let analyzerExecutableSHA256: String
  public let analyzerOutputSHA256: String
  public let headerCoverage: String
  public let lineCount: Int
  public let blankLineCount: Int
  public let unrecognizedLineCount: Int
  public let levelCounts: [String: Int]
  public let artifact: RuntimeArtifactPresentation

  /// The reader that fills this stays in Workflows, because it verifies the
  /// Artifact with the analyzer provider's own validator. Its memberwise
  /// initializer is internal, so it gets a package one.
  package init(
    jobID: String,
    sourceJobID: String,
    sourceArtifactID: String,
    sourceSHA256: String,
    sourceByteCount: Int,
    analyzerExecutableSHA256: String,
    analyzerOutputSHA256: String,
    headerCoverage: String,
    lineCount: Int,
    blankLineCount: Int,
    unrecognizedLineCount: Int,
    levelCounts: [String: Int],
    artifact: RuntimeArtifactPresentation
  ) {
    self.jobID = jobID
    self.sourceJobID = sourceJobID
    self.sourceArtifactID = sourceArtifactID
    self.sourceSHA256 = sourceSHA256
    self.sourceByteCount = sourceByteCount
    self.analyzerExecutableSHA256 = analyzerExecutableSHA256
    self.analyzerOutputSHA256 = analyzerOutputSHA256
    self.headerCoverage = headerCoverage
    self.lineCount = lineCount
    self.blankLineCount = blankLineCount
    self.unrecognizedLineCount = unrecognizedLineCount
    self.levelCounts = levelCounts
    self.artifact = artifact
  }
}

public enum DiagnosticHilogSummaryLoadResult: Sendable, Equatable {
  case loaded(DiagnosticHilogSummaryPresentation)
  case unavailable(String)
}
