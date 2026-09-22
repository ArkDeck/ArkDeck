import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

/// Client-only readers consume immutable Runtime projections and retain all
/// source, privacy and integrity refusals without importing the analyzer.
final class DiagnosticHilogSummaryReaderContractTests: XCTestCase {
  func testHilogSummaryReaderReusesProviderAcrossRepeatedReadsOfEveryCoverageState() async throws {
    for variant in ["complete", "partial", "unrecognized", "empty"] {
      let detail = try DiagnosticHilogSummaryUIFixture.detail(variant)
      let context = try XCTUnwrap(RuntimeHistoryWorkspaceContext(
        job: DiagnosticHilogSummaryUIFixture.job(variant), detail: detail))
      let bytes = try DiagnosticHilogSummaryUIFixture.document(variant)
      let provider = SessionArtifactProvider(
        detail: detail, documents: ["hilog-summary.json": bytes], expectedMaximumBytes: 16 * 1024)
      let reader = DiagnosticHilogSummaryReader(provider: provider)
      var first: DiagnosticHilogSummaryPresentation?
      for _ in 0..<3 {
        guard case .loaded(let summary) = await reader.load(context) else {
          return XCTFail("unable to read \(variant)")
        }
        XCTAssertEqual(summary.headerCoverage, variant)
        XCTAssertEqual(summary.jobID, context.jobID)
        XCTAssertEqual(summary.sourceArtifactID, "fixture-hilog-source-\(variant)")
        XCTAssertEqual(summary.sourceJobID, "job-fixture-hilog-source-\(variant)")
        XCTAssertEqual(summary.levelCounts.values.reduce(0, +) + summary.blankLineCount
          + summary.unrecognizedLineCount, summary.lineCount)
        if let first { XCTAssertEqual(summary, first) } else { first = summary }
      }
      let reads = await provider.readNames()
      XCTAssertEqual(reads, Array(repeating: "hilog-summary.json", count: 3),
        "only bounded standard-privacy summary bytes may be read, never raw source logs")
    }
  }

  func testHilogSummaryReaderRejectsTamperingForeignSourcesAndMalformedReports() async throws {
    for defect in ["bytes", "source", "extra", "counts", "version", "outputHash"] {
      let original = try DiagnosticHilogSummaryUIFixture.document("complete")
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var report = try XCTUnwrap(object["result"] as? [String: Any])
      if defect == "source" { object["sourceArtifactID"] = "foreign-artifact" }
      if defect == "extra" { object["rawContent"] = "must-not-display" }
      if defect == "counts" { report["lineCount"] = 1 }
      if defect == "version" { report["analyzerVersion"] = "2.0.0" }
      if defect == "counts" || defect == "version" {
        let changed = try JSONDecoder().decode(HilogSummaryAnalysis.self,
          from: JSONSerialization.data(withJSONObject: report))
        let canonical = try changed.canonicalData()
        object["result"] = report
        object["analyzerOutputSHA256"] = SHA256Hex.string(of: canonical)
        object["analyzerOutputByteCount"] = canonical.count
      }
      if defect == "outputHash" { object["analyzerOutputSHA256"] = String(repeating: "0", count: 64) }
      let modified = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      let detail = try DiagnosticHilogSummaryUIFixture.detail("complete", document: modified)
      let context = try XCTUnwrap(RuntimeHistoryWorkspaceContext(
        job: DiagnosticHilogSummaryUIFixture.job("complete"), detail: detail))
      let provider = SessionArtifactProvider(
        detail: detail, documents: ["hilog-summary.json": defect == "bytes" ? Data("{}".utf8) : modified],
        expectedMaximumBytes: 16 * 1024)
      let result = await DiagnosticHilogSummaryReader(provider: provider).load(context)
      XCTAssertEqual(result, .unavailable("diagnostics_hilog_summary_integrity_mismatch"), defect)
    }
  }

  func testHilogSummaryReaderRefusesFreshIdentityMismatchBeforeReadingBytes() async throws {
    let detail = try DiagnosticHilogSummaryUIFixture.detail("complete")
    let context = try XCTUnwrap(RuntimeHistoryWorkspaceContext(
      job: DiagnosticHilogSummaryUIFixture.job("complete"), detail: detail))
    let provider = SessionArtifactProvider(
      detail: try DiagnosticHilogSummaryUIFixture.detail("partial"), documents: [:],
      expectedMaximumBytes: 16 * 1024)
    let result = await DiagnosticHilogSummaryReader(provider: provider).load(context)
    XCTAssertEqual(result, .unavailable("diagnostics_hilog_summary_correlation_mismatch"))
    let reads = await provider.readNames()
    XCTAssertTrue(reads.isEmpty)
  }

  func testHilogSummaryReaderRejectsUnsafeMetadataBeforeReadingBytes() async throws {
    let original = try DiagnosticHilogSummaryUIFixture.detail("complete")
    let artifact = try XCTUnwrap(original.artifacts.first)
    let context = try XCTUnwrap(RuntimeHistoryWorkspaceContext(
      job: DiagnosticHilogSummaryUIFixture.job("complete"), detail: original))
    for defect in ["sensitive", "unpublished", "oversize", "rawRole", "foreignOperation", "duplicate"] {
      let changed = RuntimeArtifactPresentation(
        id: artifact.id, name: artifact.name, role: defect == "rawRole" ? "raw" : artifact.role,
        mediaType: artifact.mediaType, byteCount: defect == "oversize" ? 16 * 1024 + 1 : artifact.byteCount,
        sha256: artifact.sha256, privacy: defect == "sensitive" ? "sensitive" : artifact.privacy,
        status: defect == "unpublished" ? "missing" : artifact.status, statusDetail: artifact.statusDetail,
        sourceOperation: defect == "foreignOperation" ? "analyzer.extract-crash-signature@1" : artifact.sourceOperation,
        createdAtUTC: artifact.createdAtUTC, redactionApplied: artifact.redactionApplied)
      let detail = RuntimeJobDetailPresentation(
        jobID: original.jobID, timelineAvailability: original.timelineAvailability, timeline: original.timeline,
        evidenceAvailability: original.evidenceAvailability, evidence: original.evidence,
        artifactAvailability: .available, artifacts: defect == "duplicate" ? [changed, changed] : [changed],
        correlationAvailability: original.correlationAvailability, correlation: original.correlation)
      let provider = SessionArtifactProvider(detail: detail, documents: [:], expectedMaximumBytes: 16 * 1024)
      let result = await DiagnosticHilogSummaryReader(provider: provider).load(context)
      XCTAssertEqual(result, .unavailable("diagnostics_hilog_summary_artifact_unavailable"), defect)
      let reads = await provider.readNames()
      XCTAssertTrue(reads.isEmpty, defect)
    }
  }

  func testReadFailureRemainsUnavailable() async throws {
    let detail = try DiagnosticHilogSummaryUIFixture.detail("complete")
    let context = try XCTUnwrap(RuntimeHistoryWorkspaceContext(
      job: DiagnosticHilogSummaryUIFixture.job("complete"), detail: detail))
    let provider = SessionArtifactProvider(detail: detail, documents: [:], expectedMaximumBytes: 16 * 1024)
    let result = await DiagnosticHilogSummaryReader(provider: provider).load(context)
    XCTAssertEqual(result, .unavailable("diagnostics_hilog_summary_read_failed"))
    let reads = await provider.readNames()
    XCTAssertEqual(reads, ["hilog-summary.json"])
  }
}

private actor SessionArtifactProvider: RuntimeJobDetailApplicationProviding {
  let detail: RuntimeJobDetailPresentation
  let documents: [String: Data]
  let expectedMaximumBytes: Int
  private var reads: [String] = []
  init(detail: RuntimeJobDetailPresentation, documents: [String: Data], expectedMaximumBytes: Int = 1_024 * 1_024) {
    self.detail = detail
    self.documents = documents
    self.expectedMaximumBytes = expectedMaximumBytes
  }
  func readNames() -> [String] { reads }
  func loadJobDetail(jobID: String, operationReference: String) -> RuntimeJobDetailPresentation { detail }
  func exportArtifact(jobID: String, artifact: RuntimeArtifactPresentation, destinationURL: URL, allowSensitive: Bool)
    -> RuntimeArtifactExportResult { .failed("no export in reader tests") }
  func readArtifact(jobID: String, artifact: RuntimeArtifactPresentation, maximumBytes: Int, allowSensitive: Bool)
    -> RuntimeArtifactReadResult {
    reads.append(artifact.name)
    guard !allowSensitive, maximumBytes == expectedMaximumBytes, let data = documents[artifact.name] else {
      return .failed("unexpected artifact read")
    }
    return .loaded(data)
  }
}
