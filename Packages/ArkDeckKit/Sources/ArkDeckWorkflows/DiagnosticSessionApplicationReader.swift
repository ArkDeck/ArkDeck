import ArkDeckCore
import Foundation

/// Display-only decoding after Artifact integrity has been checked. Real
/// HiLog buffers can contain invalid UTF-8; replacing those sequences must
/// be disclosed, and must never repair structured evidence or stored bytes.
public struct DiagnosticArtifactTextPreview: Sendable, Equatable {
  public let text: String
  public let replacedInvalidUTF8: Bool
  public let wasClipped: Bool

  public init?(bytes: Data, mediaType: String, maximumCharacters: Int = 120_000) {
    guard bytes.count <= 2 * 1_024 * 1_024,
      (1...120_000).contains(maximumCharacters),
      mediaType == "text/plain" || mediaType == "application/json"
    else { return nil }
    let strict = String(data: bytes, encoding: .utf8)
    guard strict != nil || mediaType == "text/plain" else { return nil }
    let decoded = strict ?? String(decoding: bytes, as: UTF8.self)
    replacedInvalidUTF8 = strict == nil
    wasClipped = decoded.count > maximumCharacters
    text = String(decoded.prefix(maximumCharacters))
  }
}

/// The published bounded capture can be read without a connected device.
/// Correlation and bytes come from one exact Job; viewing it grants no runtime
/// authority and never substitutes the currently attached target.
public struct DiagnosticSessionPresentation: Sendable, Equatable {
  public let reading: DiagnosticSessionReading
  public let artifacts: [RuntimeArtifactPresentation]
  public let timeline: [String]
  public let ringHeldAnchor: Bool?
}

public enum DiagnosticSessionLoadResult: Sendable, Equatable {
  case loaded(DiagnosticSessionPresentation)
  case unavailable(String)
}

public struct DiagnosticSessionApplicationReader: Sendable {
  private let provider: any RuntimeJobDetailApplicationProviding
  private static let documentLimit = 1_024 * 1_024

  public init(provider: any RuntimeJobDetailApplicationProviding) {
    self.provider = provider
  }

  public func load(_ context: RuntimeHistoryWorkspaceContext) async -> DiagnosticSessionLoadResult {
    guard context.operationReference == "capture.diagnostics@1" else {
      return .unavailable("diagnostics_unsupported_operation")
    }
    let detail = await provider.loadJobDetail(
      jobID: context.jobID, operationReference: context.operationReference)
    guard detail.jobID == context.jobID,
      let correlation = detail.correlation,
      correlation.jobID == context.jobID,
      correlation.operationReference == context.operationReference,
      correlation.targetID == context.targetID,
      correlation.sessionID == context.sessionID,
      detail.artifactAvailability == .available
    else { return .unavailable("diagnostics_job_correlation_unavailable") }
    let artifacts = detail.artifacts
    guard Set(artifacts.map(\.id)).count == artifacts.count,
      Set(artifacts.map(\.name)).count == artifacts.count,
      artifacts.allSatisfy({ $0.sourceOperation == context.operationReference })
    else { return .unavailable("diagnostics_ambiguous_artifact_inventory") }

    do {
      let indexData = try await document("artifact-index.json", in: artifacts, jobID: context.jobID)
      let summaryData = try await document("capture-summary.json", in: artifacts, jobID: context.jobID)
      let index = try JSONDecoder().decode(Index.self, from: indexData)
      let summary = try JSONDecoder().decode(Index.self, from: summaryData)
      guard index.jobId == context.jobID, summary.jobId == context.jobID,
        index.operation == context.operationReference, summary.operation == context.operationReference,
        index.artifacts == summary.artifacts,
        let missingRequired = summary.missingRequired,
        Set(missingRequired).count == missingRequired.count,
        Set(missingRequired) == Set(summary.artifacts.filter {
          $0.value.required && $0.value.status != "published"
        }.keys),
        summary.completeness == (missingRequired.isEmpty ? "complete" : "incomplete")
      else { throw Failure("diagnostics_index_summary_mismatch") }
      for (name, item) in index.artifacts {
        guard ["published", "missing", "truncated"].contains(item.status) else {
          throw Failure("diagnostics_unknown_artifact_status")
        }
        if item.status == "published" {
          guard let metadata = artifacts.first(where: { $0.name == name }),
            metadata.status == "published", item.artifactId == metadata.id,
            item.byteCount == metadata.byteCount, item.sha256 == metadata.sha256
          else { throw Failure("diagnostics_index_metadata_mismatch") }
        } else if artifacts.contains(where: { $0.name == name && $0.status == "published" }) {
          throw Failure("diagnostics_index_metadata_mismatch")
        }
      }

      var missing: [DiagnosticSessionReading.MissingProduct] = []
      if let inputs = detail.evidence?.typedParameters {
        var requested = try Self.requestedProducts(inputs)
        // The published capture may provide PNG or JPEG. A published JPEG
        // satisfies the screenshot channel, but never a separately reported
        // required PNG entry in the Runtime index.
        if requested.contains("screenshot.png"),
          artifacts.contains(where: { $0.name == "screenshot.jpeg" && $0.status == "published" })
        {
          requested.remove("screenshot.png")
          requested.insert("screenshot.jpeg")
        }
        for name in requested.union(missingRequired).sorted() {
          guard artifacts.contains(where: { $0.name == name && $0.status == "published" }) else {
            missing.append(.init(
              name: name,
              reason: index.artifacts[name]?.detail ?? index.artifacts[name]?.status ?? "not published"))
            continue
          }
        }
      } else {
        missing.append(.init(name: "parameters", reason: "typed capture inputs were not reported"))
      }

      var marks: [DiagnosticSessionReading.Mark] = []
      var notDerived: [String] = []
      var ringHeldAnchor: Bool?
      if artifacts.contains(where: { $0.name == "markers.json" && $0.status == "published" }) {
        let markerData = try await document("markers.json", in: artifacts, jobID: context.jobID)
        let document = try MarkerDocument.decode(markerData, jobID: context.jobID)
        let reading = DiagnosticSessionReading.make(markersDocument: document)
        marks = reading.marks
        notDerived = reading.notDerived
        // This is a Runtime-published coverage fact, not clock calibration.
        if let coverage = document["coverage"] as? [String: Any],
          let value = coverage["ringHeldAnchor"] as? Bool
        { ringHeldAnchor = value }
      } else {
        missing.append(.init(name: "markers.json", reason: "marker document was not published"))
      }
      return .loaded(DiagnosticSessionPresentation(
        reading: DiagnosticSessionReading(
          jobID: context.jobID,
          alignment: .cannotAlign(reason: "capture artifacts contain no host-to-device calibration"),
          marks: marks, missingProducts: missing, notDerived: notDerived),
        artifacts: artifacts, timeline: detail.timeline, ringHeldAnchor: ringHeldAnchor))
    } catch let failure as Failure {
      return .unavailable(failure.reason)
    } catch {
      return .unavailable("diagnostics_unreadable_session_document")
    }
  }

  private func document(
    _ name: String, in artifacts: [RuntimeArtifactPresentation], jobID: String
  ) async throws -> Data {
    guard let artifact = artifacts.first(where: { $0.name == name }),
      artifact.status == "published", artifact.role == "derived",
      artifact.privacy == "standard", artifact.mediaType == "application/json",
      artifact.byteCount > 0, artifact.byteCount <= Int64(Self.documentLimit)
    else { throw Failure("diagnostics_missing_or_unreadable_\(name)") }
    switch await provider.readArtifact(
      jobID: jobID, artifact: artifact, maximumBytes: Self.documentLimit, allowSensitive: false)
    {
    case .loaded(let bytes):
      guard bytes.count == artifact.byteCount, SHA256Hex.string(of: bytes) == artifact.sha256 else {
        throw Failure("diagnostics_artifact_integrity_mismatch")
      }
      return bytes
    case .failed(let reason): throw Failure(reason)
    }
  }

  /// Defaults are the published capture.diagnostics@1 defaults. Unselected
  /// optional channels appear as "missing" in the index but are not partial
  /// capture failures. Never derive this selection from display strings.
  private static func requestedProducts(_ inputs: [String: JSONValue]) throws -> Set<String> {
    func enabled(_ name: String, default value: Bool = false) throws -> Bool {
      guard let reported = inputs[name] else { return value }
      guard case .bool(let flag) = reported else { throw Failure("diagnostics_invalid_capture_parameters") }
      return flag
    }
    var names: Set<String> = []
    if try enabled("captureHilog", default: true) { names.insert("hilog.txt") }
    if try enabled("uiDump", default: true) { names.insert("ui-dump.json") }
    if try enabled("advancedDump") { names.insert("advanced-dump.txt") }
    if try enabled("uiComponentTree") { names.insert("ui-tree.json") }
    if try enabled("uiScreenshot") {
      let imageType: String
      if let value = inputs["screenshotImageType"] {
        guard case .string(let type) = value, ["png", "jpeg"].contains(type) else {
          throw Failure("diagnostics_invalid_capture_parameters")
        }
        imageType = type
      } else { imageType = "png" }
      names.insert("screenshot.\(imageType)")
    }
    if try enabled("crashLogs") { names.insert("crash-index.txt") }
    for (field, product) in [("crashLogName", "crash-log.txt"), ("bundleName", "application-liveness.json")] {
      if let value = inputs[field] {
        guard case .string(let text) = value, !text.isEmpty else { throw Failure("diagnostics_invalid_capture_parameters") }
        names.insert(product)
      }
    }
    if let value = inputs["traceCategories"] {
      guard case .array(let tags) = value, tags.allSatisfy({
        if case .string(let text) = $0 { return !text.isEmpty }
        return false
      }) else { throw Failure("diagnostics_invalid_capture_parameters") }
      if !tags.isEmpty { names.insert("trace.htrace") }
    }
    return names
  }

  private struct Failure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }

  private struct Index: Decodable {
    let jobId: String
    let operation: String
    let artifacts: [String: Product]
    let completeness: String?
    let missingRequired: [String]?
  }

  private struct Product: Decodable, Equatable {
    let status: String
    let required: Bool
    let artifactId: String?
    let byteCount: Int64?
    let sha256: String?
    let detail: String?
  }

  private enum MarkerDocument {
    static func decode(_ data: Data, jobID: String) throws -> [String: Any] {
      guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        document["documentType"] as? String == "arkdeck-diagnostic-markers",
        document["schemaVersion"] as? String == "1.0.0",
        document["jobId"] as? String == jobID,
        let markers = document["markers"] as? [[String: Any]], markers.count <= 1_024,
        let notDerived = document["notDerived"] as? [[String: Any]],
        notDerived.allSatisfy({ $0["kind"] is String && $0["reason"] is String })
      else { throw Failure("diagnostics_invalid_markers_document") }
      for marker in markers {
        switch marker["kind"] as? String {
        case "manual":
          guard let instant = marker["atHostUTC"] as? String,
            ISO8601Timestamps.parse(instant) != nil
          else { throw Failure("diagnostics_invalid_marker_timestamp") }
        case "auto":
          guard let trigger = marker["trigger"] as? String, !trigger.isEmpty else {
            throw Failure("diagnostics_invalid_automatic_marker")
          }
          // Published step/crash markers may have no timestamp. Showing no
          // time is correct; Job completion time is not an event timestamp.
          if let instant = marker["atHostUTC"] {
            guard let instant = instant as? String, ISO8601Timestamps.parse(instant) != nil else {
              throw Failure("diagnostics_invalid_marker_timestamp")
            }
          }
        default: throw Failure("diagnostics_unknown_marker_kind")
        }
      }
      return document
    }
  }
}
