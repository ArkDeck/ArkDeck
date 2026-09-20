import ArkDeckCore
import Foundation

public enum DiagnosticSessionOfflineInspectorError: Error, Equatable, Sendable {
  case invalid(String)
  case byteCountMismatch(String)
  case digestMismatch(String)
  case contentTooLarge(maximumBytes: Int)
  case sensitiveContentRequiresExplicitAccess

  public var reason: String {
    switch self {
    case .invalid(let reason): reason
    case .byteCountMismatch: "diagnostics_artifact_byte_count_mismatch"
    case .digestMismatch: "diagnostics_artifact_integrity_mismatch"
    case .contentTooLarge: "diagnostics_artifact_exceeds_preview_limit"
    case .sensitiveContentRequiresExplicitAccess:
      "diagnostics_sensitive_preview_requires_explicit_access"
    }
  }
}

/// Immutable Runtime metadata accepted by the local diagnostics parser.
/// Missing products carry no digest; published products always do.
public struct DiagnosticOfflineArtifactMetadata: Equatable, Sendable {
  public let artifactID: String
  public let name: String
  public let mediaType: String
  public let privacy: String
  public let status: String
  public let statusDetail: String?
  public let sourceOperation: String
  public let byteCount: Int
  public let sha256: String?

  public init(
    artifactID: String,
    name: String,
    mediaType: String,
    privacy: String,
    status: String,
    statusDetail: String? = nil,
    sourceOperation: String,
    byteCount: Int,
    sha256: String?
  ) throws {
    guard !artifactID.isEmpty, artifactID.utf8.count <= 512,
      !artifactID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !name.isEmpty, name.utf8.count <= 1_024,
      !mediaType.isEmpty, mediaType.utf8.count <= 256,
      ["standard", "sensitive"].contains(privacy),
      ["published", "missing", "truncated"].contains(status),
      !sourceOperation.isEmpty, sourceOperation.utf8.count <= 256,
      byteCount >= 0,
      byteCount <= DiagnosticSessionOfflineInspector.maximumSafeInteger,
      statusDetail.map({ $0.utf8.count <= 4_096 }) ?? true,
      status == "published"
        ? sha256.map(SHA256Hex.isLowercaseSHA256) == true
        : sha256 == nil
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_invalid_artifact_metadata")
    }
    self.artifactID = artifactID
    self.name = name
    self.mediaType = mediaType
    self.privacy = privacy
    self.status = status
    self.statusDetail = statusDetail
    self.sourceOperation = sourceOperation
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

/// Metadata-bound bytes. Construction fails before any parser sees content.
public struct DiagnosticOfflineArtifact: Sendable {
  public let metadata: DiagnosticOfflineArtifactMetadata
  public let data: Data

  public init(metadata: DiagnosticOfflineArtifactMetadata, data: Data) throws {
    guard metadata.status == "published", metadata.byteCount == data.count else {
      throw DiagnosticSessionOfflineInspectorError.byteCountMismatch(metadata.name)
    }
    guard metadata.sha256 == SHA256Hex.string(of: data) else {
      throw DiagnosticSessionOfflineInspectorError.digestMismatch(metadata.name)
    }
    self.metadata = metadata
    self.data = data
  }
}

public struct DiagnosticSessionOfflineInput: Sendable {
  public let jobID: String
  public let operationReference: String
  public let typedParameters: [String: JSONValue]?
  public let inventory: [DiagnosticOfflineArtifactMetadata]
  public let documents: [String: DiagnosticOfflineArtifact]

  public init(
    jobID: String,
    operationReference: String,
    typedParameters: [String: JSONValue]?,
    inventory: [DiagnosticOfflineArtifactMetadata],
    documents: [String: DiagnosticOfflineArtifact]
  ) {
    self.jobID = jobID
    self.operationReference = operationReference
    self.typedParameters = typedParameters
    self.inventory = inventory
    self.documents = documents
  }
}

public struct DiagnosticSessionOfflineProvenance: Equatable, Sendable {
  public let kind: String
  public let parser: String
  public let parserVersion: String
  public let sources: [DiagnosticOfflineArtifactMetadata]
}

public struct DiagnosticSessionOfflineInspection: Sendable, Equatable {
  public static let schemaVersion = "arkdeck.diagnostics-inspection/1"

  public let schemaVersion: String
  public let jobID: String
  public let operationReference: String
  public let provenance: DiagnosticSessionOfflineProvenance
  public let reading: DiagnosticSessionReading
  public let ringHeldAnchor: Bool?
  public let inventory: [DiagnosticOfflineArtifactMetadata]
}

public struct DiagnosticArtifactOfflinePreview: Sendable, Equatable {
  public static let schemaVersion = "arkdeck.diagnostics-preview/1"

  public let schemaVersion: String
  public let provenance: DiagnosticSessionOfflineProvenance
  public let text: String
  public let replacedInvalidUTF8: Bool
  public let wasClipped: Bool
}

/// The App and CLI share this deterministic, device-free parser. It owns the
/// accepted document roles, bounds, integrity checks and output versions.
public struct DiagnosticSessionOfflineInspector: Sendable {
  public static let parserID = "arkdeck.diagnostics-session-parser"
  public static let parserVersion = "1.0.0"
  public static let operationReference = "capture.diagnostics@1"
  public static let indexArtifactName = "artifact-index.json"
  public static let summaryArtifactName = "capture-summary.json"
  public static let markersArtifactName = "markers.json"
  public static let inventoryMaximumCount = 64_000
  public static let maximumSafeInteger = 9_007_199_254_740_991
  public static let documentMaximumBytes = 1 * 1_024 * 1_024
  public static let previewMaximumBytes = 2 * 1_024 * 1_024
  public static let previewMaximumCharacters = 120_000

  public init() {}

  public func inspect(
    _ input: DiagnosticSessionOfflineInput
  ) throws -> DiagnosticSessionOfflineInspection {
    guard input.operationReference == Self.operationReference,
      !input.jobID.isEmpty, input.jobID.utf8.count <= 512
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_unsupported_operation")
    }
    guard Set(input.inventory.map(\.artifactID)).count == input.inventory.count,
      Set(input.inventory.map(\.name)).count == input.inventory.count,
      input.inventory.count <= Self.inventoryMaximumCount,
      input.inventory.allSatisfy({ $0.sourceOperation == input.operationReference })
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_ambiguous_artifact_inventory")
    }
    let acceptedDocuments = Set([
      Self.indexArtifactName,
      Self.summaryArtifactName,
      Self.markersArtifactName,
    ])
    guard Set(input.documents.keys).isSubset(of: acceptedDocuments),
      input.documents.allSatisfy({ name, artifact in
        name == artifact.metadata.name
          && input.inventory.contains(artifact.metadata)
      })
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_unexpected_session_document")
    }

    let indexData = try document(Self.indexArtifactName, input: input).data
    let summaryData = try document(Self.summaryArtifactName, input: input).data
    let index = try decodeIndex(indexData)
    let summary = try decodeIndex(summaryData)
    guard index.jobId == input.jobID, summary.jobId == input.jobID,
      index.operation == input.operationReference,
      summary.operation == input.operationReference,
      index.artifacts == summary.artifacts,
      let missingRequired = summary.missingRequired,
      Set(missingRequired).count == missingRequired.count,
      Set(missingRequired)
        == Set(
          summary.artifacts.filter {
            $0.value.required && $0.value.status != "published"
          }.keys),
      summary.completeness == (missingRequired.isEmpty ? "complete" : "incomplete")
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_index_summary_mismatch")
    }

    for (name, item) in index.artifacts {
      guard ["published", "missing", "truncated"].contains(item.status) else {
        throw DiagnosticSessionOfflineInspectorError.invalid(
          "diagnostics_unknown_artifact_status")
      }
      if item.status == "published" {
        guard let metadata = input.inventory.first(where: { $0.name == name }),
          metadata.status == "published",
          item.artifactId == metadata.artifactID,
          item.byteCount == metadata.byteCount,
          item.sha256 == metadata.sha256
        else {
          throw DiagnosticSessionOfflineInspectorError.invalid(
            "diagnostics_index_metadata_mismatch")
        }
      } else if input.inventory.contains(where: {
        $0.name == name && $0.status == "published"
      }) {
        throw DiagnosticSessionOfflineInspectorError.invalid(
          "diagnostics_index_metadata_mismatch")
      }
    }

    var missing: [DiagnosticSessionReading.MissingProduct] = []
    if let inputs = input.typedParameters {
      var requested = try Self.requestedProducts(inputs)
      if requested.contains("screenshot.png"),
        input.inventory.contains(where: {
          $0.name == "screenshot.jpeg" && $0.status == "published"
        })
      {
        requested.remove("screenshot.png")
        requested.insert("screenshot.jpeg")
      }
      for name in requested.union(missingRequired).sorted() {
        guard
          input.inventory.contains(where: {
            $0.name == name && $0.status == "published"
          })
        else {
          missing.append(
            .init(
              name: name,
              reason: index.artifacts[name]?.detail
                ?? index.artifacts[name]?.status
                ?? "not published"))
          continue
        }
      }
    } else {
      missing.append(
        .init(
          name: "parameters",
          reason: "typed capture inputs were not reported"))
    }

    var marks: [DiagnosticSessionReading.Mark] = []
    var notDerived: [String] = []
    var ringHeldAnchor: Bool?
    if input.inventory.contains(where: {
      $0.name == Self.markersArtifactName && $0.status == "published"
    }) {
      let markerData = try document(Self.markersArtifactName, input: input).data
      let markerDocument = try MarkerDocument.decode(markerData, jobID: input.jobID)
      let reading = DiagnosticSessionReading.make(markersDocument: markerDocument)
      marks = reading.marks
      notDerived = reading.notDerived
      if let coverage = markerDocument["coverage"] as? [String: Any],
        let value = coverage["ringHeldAnchor"] as? Bool
      {
        ringHeldAnchor = value
      }
    } else {
      missing.append(
        .init(
          name: Self.markersArtifactName,
          reason: "marker document was not published"))
    }

    let sources = input.documents.values.map(\.metadata).sorted {
      if $0.name != $1.name { return $0.name < $1.name }
      return $0.artifactID < $1.artifactID
    }
    let provenance = DiagnosticSessionOfflineProvenance(
      kind: "offlineDerived",
      parser: Self.parserID,
      parserVersion: Self.parserVersion,
      sources: sources)
    let reading = DiagnosticSessionReading(
      jobID: input.jobID,
      alignment: .cannotAlign(
        reason: "capture artifacts contain no host-to-device calibration"),
      marks: marks,
      missingProducts: missing,
      notDerived: notDerived)
    return DiagnosticSessionOfflineInspection(
      schemaVersion: DiagnosticSessionOfflineInspection.schemaVersion,
      jobID: input.jobID,
      operationReference: input.operationReference,
      provenance: provenance,
      reading: reading,
      ringHeldAnchor: ringHeldAnchor,
      inventory: input.inventory.sorted {
        if $0.name != $1.name { return $0.name < $1.name }
        return $0.artifactID < $1.artifactID
      })
  }

  public func preview(
    _ artifact: DiagnosticOfflineArtifact,
    maximumCharacters: Int = DiagnosticSessionOfflineInspector.previewMaximumCharacters,
    contentAccessExplicit: Bool
  ) throws -> DiagnosticArtifactOfflinePreview {
    let metadata = artifact.metadata
    guard metadata.sourceOperation == Self.operationReference,
      metadata.mediaType == "text/plain" || metadata.mediaType == "application/json"
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_artifact_is_not_previewable_text")
    }
    guard artifact.data.count <= Self.previewMaximumBytes else {
      throw DiagnosticSessionOfflineInspectorError.contentTooLarge(
        maximumBytes: Self.previewMaximumBytes)
    }
    guard metadata.privacy != "sensitive" || contentAccessExplicit else {
      throw DiagnosticSessionOfflineInspectorError.sensitiveContentRequiresExplicitAccess
    }
    guard
      let text = DiagnosticArtifactTextPreview(
        bytes: artifact.data,
        mediaType: metadata.mediaType,
        maximumCharacters: maximumCharacters)
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_invalid_structured_text")
    }
    return DiagnosticArtifactOfflinePreview(
      schemaVersion: DiagnosticArtifactOfflinePreview.schemaVersion,
      provenance: DiagnosticSessionOfflineProvenance(
        kind: "offlineDerived",
        parser: Self.parserID,
        parserVersion: Self.parserVersion,
        sources: [metadata]),
      text: text.text,
      replacedInvalidUTF8: text.replacedInvalidUTF8,
      wasClipped: text.wasClipped)
  }

  private func document(
    _ name: String,
    input: DiagnosticSessionOfflineInput
  ) throws -> DiagnosticOfflineArtifact {
    guard let artifact = input.documents[name],
      artifact.metadata.name == name,
      artifact.metadata.mediaType == "application/json",
      artifact.metadata.privacy == "standard",
      artifact.metadata.status == "published",
      artifact.data.count > 0,
      artifact.data.count <= Self.documentMaximumBytes,
      input.inventory.contains(artifact.metadata)
    else {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_missing_or_unreadable_\(name)")
    }
    return artifact
  }

  private func decodeIndex(_ data: Data) throws -> Index {
    do {
      return try JSONDecoder().decode(Index.self, from: data)
    } catch {
      throw DiagnosticSessionOfflineInspectorError.invalid(
        "diagnostics_unreadable_session_document")
    }
  }

  private static func requestedProducts(
    _ inputs: [String: JSONValue]
  ) throws -> Set<String> {
    func enabled(_ name: String, default value: Bool = false) throws -> Bool {
      guard let reported = inputs[name] else { return value }
      guard case .bool(let flag) = reported else {
        throw DiagnosticSessionOfflineInspectorError.invalid(
          "diagnostics_invalid_capture_parameters")
      }
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
          throw DiagnosticSessionOfflineInspectorError.invalid(
            "diagnostics_invalid_capture_parameters")
        }
        imageType = type
      } else {
        imageType = "png"
      }
      names.insert("screenshot.\(imageType)")
    }
    if try enabled("crashLogs") { names.insert("crash-index.txt") }
    for (field, product) in [
      ("crashLogName", "crash-log.txt"),
      ("bundleName", "application-liveness.json"),
    ] {
      if let value = inputs[field] {
        guard case .string(let text) = value, !text.isEmpty else {
          throw DiagnosticSessionOfflineInspectorError.invalid(
            "diagnostics_invalid_capture_parameters")
        }
        names.insert(product)
      }
    }
    if let value = inputs["traceCategories"] {
      guard case .array(let tags) = value,
        tags.allSatisfy({
          if case .string(let text) = $0 { return !text.isEmpty }
          return false
        })
      else {
        throw DiagnosticSessionOfflineInspectorError.invalid(
          "diagnostics_invalid_capture_parameters")
      }
      if !tags.isEmpty { names.insert("trace.htrace") }
    }
    return names
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
    let byteCount: Int?
    let sha256: String?
    let detail: String?
  }

  private enum MarkerDocument {
    static func decode(_ data: Data, jobID: String) throws -> [String: Any] {
      guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        document["documentType"] as? String == "arkdeck-diagnostic-markers",
        document["schemaVersion"] as? String == "1.0.0",
        document["jobId"] as? String == jobID,
        let markers = document["markers"] as? [[String: Any]],
        markers.count <= 1_024,
        let notDerived = document["notDerived"] as? [[String: Any]],
        notDerived.allSatisfy({
          $0["kind"] is String && $0["reason"] is String
        })
      else {
        throw DiagnosticSessionOfflineInspectorError.invalid(
          "diagnostics_invalid_markers_document")
      }
      for marker in markers {
        switch marker["kind"] as? String {
        case "manual":
          guard let instant = marker["atHostUTC"] as? String,
            ISO8601Timestamps.parse(instant) != nil
          else {
            throw DiagnosticSessionOfflineInspectorError.invalid(
              "diagnostics_invalid_marker_timestamp")
          }
        case "auto":
          guard let trigger = marker["trigger"] as? String, !trigger.isEmpty else {
            throw DiagnosticSessionOfflineInspectorError.invalid(
              "diagnostics_invalid_automatic_marker")
          }
          if let instant = marker["atHostUTC"] {
            guard let instant = instant as? String,
              ISO8601Timestamps.parse(instant) != nil
            else {
              throw DiagnosticSessionOfflineInspectorError.invalid(
                "diagnostics_invalid_marker_timestamp")
            }
          }
        default:
          throw DiagnosticSessionOfflineInspectorError.invalid(
            "diagnostics_unknown_marker_kind")
        }
      }
      return document
    }
  }
}
