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
}

public enum DiagnosticHilogSummaryLoadResult: Sendable, Equatable {
  case loaded(DiagnosticHilogSummaryPresentation)
  case unavailable(String)
}

public struct DiagnosticHilogSummaryReader: Sendable {
  private let provider: any RuntimeJobDetailApplicationProviding
  private static let maximumBytes = 16 * 1024

  public init(provider: any RuntimeJobDetailApplicationProviding) {
    self.provider = provider
  }

  public func load(_ context: RuntimeHistoryWorkspaceContext) async -> DiagnosticHilogSummaryLoadResult {
    guard context.operationReference == "analyzer.summarize-hilog@1",
      context.state == "succeeded", context.executionMode == "execute"
    else { return .unavailable("diagnostics_hilog_summary_not_completed") }
    let detail = await provider.loadJobDetail(
      jobID: context.jobID, operationReference: context.operationReference)
    guard detail.jobID == context.jobID, detail.correlationAvailability == .available,
      let correlation = detail.correlation,
      correlation.jobID == context.jobID, correlation.operationReference == context.operationReference,
      correlation.targetID == context.targetID, correlation.sessionID == context.sessionID,
      detail.evidenceAvailability == .available, let evidence = detail.evidence,
      evidence.terminalState == "succeeded", evidence.executionMode == "execute",
      evidence.actualEffect == "hostOnly", evidence.providerID == "analyzer",
      evidence.bindingRevision == nil,
      case .string(let lease)? = evidence.typedParameters?["sourceArtifactRef"]
    else { return .unavailable("diagnostics_hilog_summary_correlation_mismatch") }
    let parts = lease.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts[0] == "lease-v1",
      Self.isIdentifier(parts[1]), Self.isIdentifier(parts[2])
    else { return .unavailable("diagnostics_hilog_summary_source_unavailable") }

    guard detail.artifactAvailability == .available,
      Set(detail.artifacts.map(\.id)).count == detail.artifacts.count,
      Set(detail.artifacts.map(\.name)).count == detail.artifacts.count,
      let artifact = detail.artifacts.first(where: { $0.name == "hilog-summary.json" }),
      artifact.sourceOperation == context.operationReference,
      artifact.status == "published", artifact.role == "derived",
      artifact.privacy == "standard", artifact.mediaType == "application/json",
      artifact.byteCount > 0, artifact.byteCount <= Self.maximumBytes,
      Self.isDigest(artifact.sha256),
      correlation.artifacts.contains(where: {
        $0.id == artifact.id && $0.name == artifact.name && $0.role == artifact.role && $0.sha256 == artifact.sha256
      })
    else { return .unavailable("diagnostics_hilog_summary_artifact_unavailable") }

    let bytes: Data
    switch await provider.readArtifact(
      jobID: context.jobID, artifact: artifact, maximumBytes: Self.maximumBytes, allowSensitive: false)
    {
    case .loaded(let data): bytes = data
    case .failed: return .unavailable("diagnostics_hilog_summary_read_failed")
    }
    guard bytes.count == artifact.byteCount, SHA256Hex.string(of: bytes) == artifact.sha256,
      let document = try? JSONDecoder().decode(HilogSummaryDerivedArtifact.self, from: bytes),
      (try? CanonicalJSONEncoders.canonical().encode(document)) == bytes,
      document.sourceArtifactID == parts[2],
      Self.isDigest(document.result.sourceSHA256),
      Self.isDigest(document.analyzerExecutableSHA256),
      Self.isDigest(document.analyzerOutputSHA256),
      let report = try? document.result.canonicalData(),
      report.count == document.analyzerOutputByteCount,
      SHA256Hex.string(of: report) == document.analyzerOutputSHA256,
      HilogSummaryDerivedAnalyzer.validateReport(
        report, sourceSHA256: document.result.sourceSHA256,
        sourceByteCount: document.result.sourceByteCount)
    else { return .unavailable("diagnostics_hilog_summary_integrity_mismatch") }

    return .loaded(DiagnosticHilogSummaryPresentation(
      jobID: context.jobID, sourceJobID: parts[1], sourceArtifactID: document.sourceArtifactID,
      sourceSHA256: document.result.sourceSHA256, sourceByteCount: document.result.sourceByteCount,
      analyzerExecutableSHA256: document.analyzerExecutableSHA256,
      analyzerOutputSHA256: document.analyzerOutputSHA256,
      headerCoverage: document.result.headerCoverage.rawValue,
      lineCount: document.result.lineCount, blankLineCount: document.result.blankLineCount,
      unrecognizedLineCount: document.result.unrecognizedLineCount,
      levelCounts: document.result.levelCounts, artifact: artifact))
  }

  private static func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 200 && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || $0 == 45 || $0 == 46 || $0 == 95
    }
  }

  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
