import Foundation
import Testing

@testable import ArkDeckCore
@testable import ArkDeckClientKit

struct DiagnosticSessionOfflineInspectorContractTests {
  @Test func inspectionBindsDocumentsAndReportsCompleteness() throws {
    let input = try fixture()
    let inspection =
      try DiagnosticSessionOfflineInspector().inspect(input)

    #expect(
      inspection.schemaVersion
        == "arkdeck.diagnostics-inspection/1")
    #expect(inspection.jobID == "job-diagnostics")
    #expect(
      inspection.operationReference
        == "capture.diagnostics@1")
    #expect(
      inspection.provenance.kind
        == "offlineDerived")
    #expect(
      inspection.provenance.parser
        == DiagnosticSessionOfflineInspector.parserID)
    #expect(
      inspection.provenance.sources.map(\.name)
        == [
          "artifact-index.json",
          "capture-summary.json",
          "markers.json",
        ])
    #expect(!inspection.reading.isPartial)
    #expect(
      inspection.reading.marks.first?.label
        == "stutter")
    #expect(
      inspection.reading.notDerived
        == ["frameDeadline"])
    #expect(inspection.ringHeldAnchor == true)
    guard
      case .cannotAlign(let reason) =
        inspection.reading.alignment
    else {
      Issue.record("inspection must not invent clock alignment")
      return
    }
    #expect(!reason.isEmpty)
  }

  @Test func metadataBytesAndIndexMustBindExactly() throws {
    let input = try fixture()
    let marker = try #require(input.documents["markers.json"])
    let wrongDigest = try DiagnosticOfflineArtifactMetadata(
      artifactID: marker.metadata.artifactID,
      name: marker.metadata.name,
      mediaType: marker.metadata.mediaType,
      privacy: marker.metadata.privacy,
      status: marker.metadata.status,
      sourceOperation: marker.metadata.sourceOperation,
      byteCount: marker.metadata.byteCount,
      sha256: String(repeating: "0", count: 64))
    #expect(
      throws: DiagnosticSessionOfflineInspectorError
        .digestMismatch("markers.json")
    ) {
      try DiagnosticOfflineArtifact(
        metadata: wrongDigest,
        data: marker.data)
    }

    let duplicate = DiagnosticSessionOfflineInput(
      jobID: input.jobID,
      operationReference: input.operationReference,
      typedParameters: input.typedParameters,
      inventory: input.inventory + [input.inventory[0]],
      documents: input.documents)
    #expect(
      throws: DiagnosticSessionOfflineInspectorError
        .invalid("diagnostics_ambiguous_artifact_inventory")
    ) {
      try DiagnosticSessionOfflineInspector().inspect(duplicate)
    }

    var documents = input.documents
    documents["unexpected.json"] = marker
    let unexpected = DiagnosticSessionOfflineInput(
      jobID: input.jobID,
      operationReference: input.operationReference,
      typedParameters: input.typedParameters,
      inventory: input.inventory,
      documents: documents)
    #expect(
      throws: DiagnosticSessionOfflineInspectorError
        .invalid("diagnostics_unexpected_session_document")
    ) {
      try DiagnosticSessionOfflineInspector().inspect(unexpected)
    }
  }

  @Test func sensitiveTextPreviewRequiresExplicitAccessAndDisclosesRepair()
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
    #expect(
      throws: DiagnosticSessionOfflineInspectorError
        .sensitiveContentRequiresExplicitAccess
    ) {
      try DiagnosticSessionOfflineInspector().preview(
        artifact,
        contentAccessExplicit: false)
    }

    let preview =
      try DiagnosticSessionOfflineInspector().preview(
        artifact,
        maximumCharacters: 2,
        contentAccessExplicit: true)
    #expect(
      preview.schemaVersion
        == "arkdeck.diagnostics-preview/1")
    #expect(preview.text == "a\u{FFFD}")
    #expect(preview.replacedInvalidUTF8)
    #expect(preview.wasClipped)
    #expect(
      preview.provenance.sources.map(\.artifactID)
        == ["artifact-hilog"])
  }

  @Test func structuredPreviewRejectsInvalidUTF8() throws {
    let bytes = Data([0x7B, 0xFF, 0x7D])
    let metadata = try self.metadata(
      id: "artifact-json",
      name: "bad.json",
      mediaType: "application/json",
      privacy: "standard",
      data: bytes)
    #expect(
      throws: DiagnosticSessionOfflineInspectorError
        .invalid("diagnostics_invalid_structured_text")
    ) {
      try DiagnosticSessionOfflineInspector().preview(
        DiagnosticOfflineArtifact(
          metadata: metadata,
          data: bytes),
        contentAccessExplicit: false)
    }
  }

  @Test func theAppCallsTheSharedOwner() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let app = try String(
      contentsOf: root.appending(
        path:
          "Sources/ArkDeckClientKit/DiagnosticSessionApplicationReader.swift"),
      encoding: .utf8)
    #expect(
      app.contains("DiagnosticSessionOfflineInspector().inspect"))
  }

  @Test func publishedSchemaPinsOutputAndParserVersions() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appending(
        path: "Contracts/cli-diagnostics-offline.schema.json"))
    let schema = try #require(
      JSONSerialization.jsonObject(with: data)
        as? [String: Any])
    let definitions = try #require(
      schema["$defs"] as? [String: Any])
    let inspection = try #require(
      definitions["inspection"] as? [String: Any])
    let inspectionProperties = try #require(
      inspection["properties"] as? [String: Any])
    #expect(
      (inspectionProperties["schemaVersion"]
        as? [String: Any])?["const"] as? String
        == DiagnosticSessionOfflineInspection.schemaVersion)
    let preview = try #require(
      definitions["preview"] as? [String: Any])
    let previewProperties = try #require(
      preview["properties"] as? [String: Any])
    #expect(
      (previewProperties["schemaVersion"]
        as? [String: Any])?["const"] as? String
        == DiagnosticArtifactOfflinePreview.schemaVersion)
    let provenance = try #require(
      definitions["provenance"] as? [String: Any])
    let provenanceProperties = try #require(
      provenance["properties"] as? [String: Any])
    #expect(
      (provenanceProperties["parser"]
        as? [String: Any])?["const"] as? String
        == DiagnosticSessionOfflineInspector.parserID)
    #expect(
      (provenanceProperties["parserVersion"]
        as? [String: Any])?["const"] as? String
        == DiagnosticSessionOfflineInspector.parserVersion)
  }

  @Test func runtimeProducedInteractiveSessionReadsWithoutPhantomUIDumpAndPinsItsTrace() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../rust/tests/fixtures/diagnostic-session/interactive.json").standardizedFileURL
    let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    #expect(fixture["fixtureOnly"] as? Bool == true)
    let rows = try #require(fixture["inventory"] as? [[String: Any]])
    let inventory = try rows.map { row in
      try DiagnosticOfflineArtifactMetadata(
        artifactID: row["artifactId"] as! String, name: row["name"] as! String,
        mediaType: row["mediaType"] as! String, privacy: row["privacy"] as! String,
        status: row["status"] as! String, sourceOperation: row["sourceOperation"] as! String,
        byteCount: row["byteCount"] as! Int, sha256: row["artifactDigest"] as? String)
    }
    let text = try #require(fixture["documents"] as? [String: String])
    var documents: [String: DiagnosticOfflineArtifact] = [:]
    for name in ["artifact-index.json", "capture-summary.json", "markers.json"] {
      documents[name] = try DiagnosticOfflineArtifact(
        metadata: #require(inventory.first { $0.name == name }), data: Data(try #require(text[name]).utf8))
    }
    let parameters = try JSONDecoder().decode([String: JSONValue].self,
      from: JSONSerialization.data(withJSONObject: try #require(fixture["typedParameters"])))
    let input = DiagnosticSessionOfflineInput(
      jobID: fixture["jobId"] as! String, operationReference: DiagnosticCaptureFacade.operationReference,
      typedParameters: parameters, inventory: inventory, documents: documents)
    let inspection = try DiagnosticSessionOfflineInspector().inspect(input)
    #expect(!inspection.reading.isPartial)
    #expect(inspection.reading.missingProducts.isEmpty)
    #expect(inspection.reading.marks.count == 1)
    #expect(inspection.operationReference == DiagnosticCaptureFacade.operationReference)
    #expect(inspection.reading.clockObservation?.status == .unvalidated)
    let raw = try #require(inventory.first { $0.name == "trace.htrace" })
    let trace = RuntimeArtifactPresentation(
      id: raw.artifactID, name: raw.name, role: "raw", mediaType: raw.mediaType,
      byteCount: Int64(raw.byteCount), sha256: try #require(raw.sha256), privacy: raw.privacy,
      status: raw.status, statusDetail: nil, sourceOperation: raw.sourceOperation,
      createdAtUTC: "2026-09-14T00:00:00Z", redactionApplied: false)
    #expect(TracePublishedArtifactPolicy.selectRawTrace(
      from: [trace], operationReference: input.operationReference) == trace)
    #expect(TracePublishedArtifactPolicy.selectRawTrace(from: [trace]) == nil)
    #expect(inspection.provenance.sources.allSatisfy { $0.sourceOperation == DiagnosticCaptureFacade.operationReference })
    guard case .cannotAlign = inspection.reading.alignment else {
      Issue.record("interactive host markers do not establish device clock alignment"); return
    }
    let crossOperation = DiagnosticSessionOfflineInput(
      jobID: input.jobID, operationReference: "capture.diagnostics@1", typedParameters: parameters,
      inventory: inventory, documents: documents)
    #expect(throws: DiagnosticSessionOfflineInspectorError.invalid("diagnostics_ambiguous_artifact_inventory")) {
      try DiagnosticSessionOfflineInspector().inspect(crossOperation)
    }
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
