import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class DiagnosticSessionOfflineInspectorContractTests:
  XCTestCase
{
  func testInspectionBindsDocumentsAndReportsCompleteness() throws {
    let input = try fixture()
    let inspection =
      try DiagnosticSessionOfflineInspector().inspect(input)

    XCTAssertEqual(
      inspection.schemaVersion,
      "arkdeck.diagnostics-inspection/1")
    XCTAssertEqual(inspection.jobID, "job-diagnostics")
    XCTAssertEqual(
      inspection.operationReference,
      "capture.diagnostics@1")
    XCTAssertEqual(
      inspection.provenance.kind,
      "offlineDerived")
    XCTAssertEqual(
      inspection.provenance.parser,
      DiagnosticSessionOfflineInspector.parserID)
    XCTAssertEqual(
      inspection.provenance.sources.map(\.name),
      [
        "artifact-index.json",
        "capture-summary.json",
        "markers.json",
      ])
    XCTAssertFalse(inspection.reading.isPartial)
    XCTAssertEqual(
      inspection.reading.marks.first?.label,
      "stutter")
    XCTAssertEqual(
      inspection.reading.notDerived,
      ["frameDeadline"])
    XCTAssertEqual(inspection.ringHeldAnchor, true)
    guard
      case .cannotAlign(let reason) =
        inspection.reading.alignment
    else {
      return XCTFail("inspection must not invent clock alignment")
    }
    XCTAssertFalse(reason.isEmpty)
  }

  func testMetadataBytesAndIndexMustBindExactly() throws {
    let input = try fixture()
    let marker = try XCTUnwrap(input.documents["markers.json"])
    let wrongDigest = try DiagnosticOfflineArtifactMetadata(
      artifactID: marker.metadata.artifactID,
      name: marker.metadata.name,
      mediaType: marker.metadata.mediaType,
      privacy: marker.metadata.privacy,
      status: marker.metadata.status,
      sourceOperation: marker.metadata.sourceOperation,
      byteCount: marker.metadata.byteCount,
      sha256: String(repeating: "0", count: 64))
    XCTAssertThrowsError(
      try DiagnosticOfflineArtifact(
        metadata: wrongDigest,
        data: marker.data)
    ) { error in
      XCTAssertEqual(
        error as? DiagnosticSessionOfflineInspectorError,
        .digestMismatch("markers.json"))
    }

    let duplicate = DiagnosticSessionOfflineInput(
      jobID: input.jobID,
      operationReference: input.operationReference,
      typedParameters: input.typedParameters,
      inventory: input.inventory + [input.inventory[0]],
      documents: input.documents)
    XCTAssertThrowsError(
      try DiagnosticSessionOfflineInspector().inspect(duplicate)
    ) { error in
      XCTAssertEqual(
        error as? DiagnosticSessionOfflineInspectorError,
        .invalid("diagnostics_ambiguous_artifact_inventory"))
    }

    var documents = input.documents
    documents["unexpected.json"] = marker
    let unexpected = DiagnosticSessionOfflineInput(
      jobID: input.jobID,
      operationReference: input.operationReference,
      typedParameters: input.typedParameters,
      inventory: input.inventory,
      documents: documents)
    XCTAssertThrowsError(
      try DiagnosticSessionOfflineInspector().inspect(unexpected)
    ) { error in
      XCTAssertEqual(
        error as? DiagnosticSessionOfflineInspectorError,
        .invalid("diagnostics_unexpected_session_document"))
    }
  }

  func testSensitiveTextPreviewRequiresExplicitAccessAndDisclosesRepair()
    throws
  {
    let bytes = Data([0x61, 0xFF, 0x62])
    let metadata = try self.metadata(
      id: "artifact-hilog",
      name: "hilog.txt",
      mediaType: "text/plain",
      privacy: "sensitive",
      data: bytes)
    let artifact = try DiagnosticOfflineArtifact(
      metadata: metadata,
      data: bytes)
    XCTAssertThrowsError(
      try DiagnosticSessionOfflineInspector().preview(
        artifact,
        contentAccessExplicit: false)
    ) { error in
      XCTAssertEqual(
        error as? DiagnosticSessionOfflineInspectorError,
        .sensitiveContentRequiresExplicitAccess)
    }

    let preview =
      try DiagnosticSessionOfflineInspector().preview(
        artifact,
        maximumCharacters: 2,
        contentAccessExplicit: true)
    XCTAssertEqual(
      preview.schemaVersion,
      "arkdeck.diagnostics-preview/1")
    XCTAssertEqual(preview.text, "a\u{FFFD}")
    XCTAssertTrue(preview.replacedInvalidUTF8)
    XCTAssertTrue(preview.wasClipped)
    XCTAssertEqual(
      preview.provenance.sources.map(\.artifactID),
      ["artifact-hilog"])
  }

  func testStructuredPreviewRejectsInvalidUTF8() throws {
    let bytes = Data([0x7B, 0xFF, 0x7D])
    let metadata = try self.metadata(
      id: "artifact-json",
      name: "bad.json",
      mediaType: "application/json",
      privacy: "standard",
      data: bytes)
    XCTAssertThrowsError(
      try DiagnosticSessionOfflineInspector().preview(
        DiagnosticOfflineArtifact(
          metadata: metadata,
          data: bytes),
        contentAccessExplicit: false)
    ) { error in
      XCTAssertEqual(
        error as? DiagnosticSessionOfflineInspectorError,
        .invalid("diagnostics_invalid_structured_text"))
    }
  }

  func testAppAndCLICallTheSharedOwner() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let app = try String(
      contentsOf: root.appending(
        path:
          "Sources/ArkDeckWorkflows/DiagnosticSessionApplicationReader.swift"),
      encoding: .utf8)
    let cli = try String(
      contentsOf: root.appending(
        path: "Sources/ArkDeckCLI/CLIDiagnosticsResources.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      app.contains("DiagnosticSessionOfflineInspector().inspect"))
    XCTAssertTrue(
      cli.contains("DiagnosticSessionOfflineInspector().inspect"))
    XCTAssertFalse(
      cli.contains("DiagnosticSessionApplicationReader"))
  }

  func testPublishedSchemaPinsOutputAndParserVersions() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appending(
        path: "Contracts/cli-diagnostics-offline.schema.json"))
    let schema = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data)
        as? [String: Any])
    let definitions = try XCTUnwrap(
      schema["$defs"] as? [String: Any])
    let inspection = try XCTUnwrap(
      definitions["inspection"] as? [String: Any])
    let inspectionProperties = try XCTUnwrap(
      inspection["properties"] as? [String: Any])
    XCTAssertEqual(
      (inspectionProperties["schemaVersion"]
        as? [String: Any])?["const"] as? String,
      DiagnosticSessionOfflineInspection.schemaVersion)
    let preview = try XCTUnwrap(
      definitions["preview"] as? [String: Any])
    let previewProperties = try XCTUnwrap(
      preview["properties"] as? [String: Any])
    XCTAssertEqual(
      (previewProperties["schemaVersion"]
        as? [String: Any])?["const"] as? String,
      DiagnosticArtifactOfflinePreview.schemaVersion)
    let provenance = try XCTUnwrap(
      definitions["provenance"] as? [String: Any])
    let provenanceProperties = try XCTUnwrap(
      provenance["properties"] as? [String: Any])
    XCTAssertEqual(
      (provenanceProperties["parser"]
        as? [String: Any])?["const"] as? String,
      DiagnosticSessionOfflineInspector.parserID)
    XCTAssertEqual(
      (provenanceProperties["parserVersion"]
        as? [String: Any])?["const"] as? String,
      DiagnosticSessionOfflineInspector.parserVersion)
  }

  private func fixture() throws
    -> DiagnosticSessionOfflineInput
  {
    let jobID = "job-diagnostics"
    let operation =
      DiagnosticSessionOfflineInspector.operationReference
    let hilog = Data("line one\nline two\n".utf8)
    let hilogMetadata = try metadata(
      id: "artifact-hilog",
      name: "hilog.txt",
      mediaType: "text/plain",
      privacy: "sensitive",
      data: hilog)
    let products: [String: Any] = [
      "hilog.txt": [
        "status": "published",
        "required": true,
        "artifactId": hilogMetadata.artifactID,
        "byteCount": hilogMetadata.byteCount,
        "sha256": hilogMetadata.sha256!,
      ]
    ]
    let index: [String: Any] = [
      "jobId": jobID,
      "operation": operation,
      "artifacts": products,
    ]
    let summary: [String: Any] = [
      "jobId": jobID,
      "operation": operation,
      "artifacts": products,
      "completeness": "complete",
      "missingRequired": [String](),
    ]
    let markers: [String: Any] = [
      "documentType": "arkdeck-diagnostic-markers",
      "schemaVersion": "1.0.0",
      "jobId": jobID,
      "markers": [
        [
          "kind": "manual",
          "atHostUTC": "2026-09-01T00:00:00Z",
          "label": "stutter",
        ]
      ],
      "notDerived": [
        [
          "kind": "frameDeadline",
          "reason": "not requested",
        ]
      ],
      "coverage": ["ringHeldAnchor": true],
    ]
    var inventory = [hilogMetadata]
    var documents: [String: DiagnosticOfflineArtifact] = [:]
    for (name, object) in [
      ("artifact-index.json", index),
      ("capture-summary.json", summary),
      ("markers.json", markers),
    ] {
      let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys])
      let metadata = try self.metadata(
        id: "artifact-\(name)",
        name: name,
        mediaType: "application/json",
        privacy: "standard",
        data: data)
      inventory.append(metadata)
      documents[name] = try DiagnosticOfflineArtifact(
        metadata: metadata,
        data: data)
    }
    return DiagnosticSessionOfflineInput(
      jobID: jobID,
      operationReference: operation,
      typedParameters: [
        "captureHilog": .bool(true),
        "uiDump": .bool(false),
        "traceCategories": .array([]),
      ],
      inventory: inventory,
      documents: documents)
  }

  private func metadata(
    id: String,
    name: String,
    mediaType: String,
    privacy: String,
    data: Data
  ) throws -> DiagnosticOfflineArtifactMetadata {
    try DiagnosticOfflineArtifactMetadata(
      artifactID: id,
      name: name,
      mediaType: mediaType,
      privacy: privacy,
      status: "published",
      sourceOperation:
        DiagnosticSessionOfflineInspector.operationReference,
      byteCount: data.count,
      sha256: SHA256Hex.string(of: data))
  }
}
