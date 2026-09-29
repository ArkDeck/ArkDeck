@testable import ArkDeckClientKit
import CryptoKit
import Foundation
import Testing

struct UIDumpOfflineInspectorContractTests {
  @Test func inspectionBindsVersionParserSourcesAndHitTest() throws {
    let inspection = try UIDumpOfflineInspector().inspect(input(verifiedCoordinates: true))

    #expect(inspection.schemaVersion == "arkdeck.ui-dump-inspection/1")
    #expect(inspection.provenance.kind == "offlineDerived")
    #expect(inspection.provenance.parser == UIDumpOfflineInspector.parserID)
    #expect(
      inspection.provenance.parserVersion
        == UIDumpOfflineInspector.parserVersion)
    #expect(
      inspection.provenance.sources.map(\.name)
        == ["screenshot.png", "ui-dump.json", "ui-tree.json"])
    #expect(inspection.provenance.observedFromUTC == "2026-09-01T01:00:00Z")
    #expect(inspection.provenance.observedToUTC == "2026-09-01T01:00:02Z")
    #expect(inspection.capture.coordinatesAreVerified)

    let hit = try UIDumpOfflineInspector().hitTest(inspection, x: 20, y: 20)
    #expect(hit.schemaVersion == "arkdeck.ui-dump-hit-test/1")
    #expect(hit.provenance == inspection.provenance)
    #expect(hit.node?.deviceID == "button")
  }

  @Test func artifactBytesMustMatchPublishedSizeAndDigestBeforeParsing() throws {
    let data = Data("bytes".utf8)
    let wrongSize = try source(
      id: "A-size", name: "ui-tree.json", mediaType: "application/json",
      data: data, byteCount: data.count + 1)
    #expect(throws: UIDumpOfflineInspectorError.sourceByteCountMismatch("ui-tree.json")) {
      try UIDumpOfflineArtifact(source: wrongSize, data: data)
    }

    let wrongDigest = try UIDumpOfflineSource(
      artifactID: "A-digest", name: "ui-tree.json", mediaType: "application/json",
      sha256: String(repeating: "0", count: 64), byteCount: data.count)
    #expect(throws: UIDumpOfflineInspectorError.sourceDigestMismatch("ui-tree.json")) {
      try UIDumpOfflineArtifact(source: wrongDigest, data: data)
    }
  }

  @Test func theOwnerEnforcesOneFixedCaptureBudgetBeforeParsing() throws {
    let bounded = UIDumpOfflineInspector(testMaximumCaptureBytes: 32)
    #expect(throws: UIDumpOfflineInspectorError.captureTooLarge(maximumBytes: 32)) {
      try bounded.inspect(input(verifiedCoordinates: true))
    }
    #expect(UIDumpOfflineInspector.maximumCaptureBytes == 64 * 1_024 * 1_024)
  }

  @Test func artifactRolesAndIdentitiesAreExact() throws {
    let valid = try input(verifiedCoordinates: true)
    let wrongScreenshot = try artifact(
      id: "A-other-screen", name: "alternate.png",
      mediaType: UIDumpOfflineInspector.screenshotMediaType,
      data: valid.screenshot.data)
    #expect(throws: UIDumpOfflineInspectorError.invalidSource("alternate.png")) {
      try UIDumpOfflineInspector().inspect(
        UIDumpOfflineCaptureInput(
          identity: valid.identity, screenshot: wrongScreenshot, tree: valid.tree,
          rawDump: valid.rawDump))
    }

    let duplicateIdentityTree = try artifact(
      id: valid.screenshot.source.artifactID,
      name: UIDumpOfflineInspector.treeArtifactName,
      mediaType: UIDumpOfflineInspector.treeMediaType,
      data: valid.tree.data)
    #expect(throws: UIDumpOfflineInspectorError.invalidSource("duplicateArtifactId")) {
      try UIDumpOfflineInspector().inspect(
        UIDumpOfflineCaptureInput(
          identity: valid.identity, screenshot: valid.screenshot, tree: duplicateIdentityTree,
          rawDump: valid.rawDump))
    }
  }

  @Test func hitTestRefusesUnverifiedCoordinatesWhileInspectionRemainsReadable() throws {
    let inspection = try UIDumpOfflineInspector().inspect(input(verifiedCoordinates: false))
    #expect(!inspection.capture.coordinatesAreVerified)
    #expect(!inspection.capture.nodes.isEmpty)
    #expect(throws: UIDumpOfflineInspectorError.coordinatesUnverified) {
      try UIDumpOfflineInspector().hitTest(inspection, x: 20, y: 20)
    }
  }

  @Test func theAppUsesTheTypedOwnerInsteadOfCallingTheParserDirectly() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let app = try String(
      contentsOf: root.appending(
        path: "Sources/ArkDeckClientKit/UIDumpApplicationFacade.swift"),
      encoding: .utf8)
    #expect(app.contains("UIDumpOfflineInspector().inspect"))
    #expect(!app.contains("try ViewerCaptureParser.parse("))
  }

  @Test func publishedJSONSchemaPinsTheOwnerVersionsAndClosedSourceRoles() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appending(path: "Contracts/cli-ui-dump-offline.schema.json"))
    let schema = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let definitions = try #require(schema["$defs"] as? [String: Any])
    let inspection = try #require(definitions["inspection"] as? [String: Any])
    let inspectionProperties = try #require(
      inspection["properties"] as? [String: Any])
    #expect(
      (inspectionProperties["schemaVersion"] as? [String: Any])?["const"] as? String
        == UIDumpOfflineInspection.schemaVersion)
    let hitTest = try #require(definitions["hitTest"] as? [String: Any])
    let hitTestProperties = try #require(hitTest["properties"] as? [String: Any])
    #expect(
      (hitTestProperties["schemaVersion"] as? [String: Any])?["const"] as? String
        == UIDumpOfflineHitTest.schemaVersion)
    let provenance = try #require(definitions["provenance"] as? [String: Any])
    let provenanceProperties = try #require(provenance["properties"] as? [String: Any])
    #expect(
      (provenanceProperties["parser"] as? [String: Any])?["const"] as? String
        == UIDumpOfflineInspector.parserID)
    #expect(
      (provenanceProperties["parserVersion"] as? [String: Any])?["const"] as? String
        == UIDumpOfflineInspector.parserVersion)
    let source = try #require(definitions["source"] as? [String: Any])
    let sourceProperties = try #require(source["properties"] as? [String: Any])
    #expect(
      Set((sourceProperties["name"] as? [String: Any])?["enum"] as? [String] ?? [])
        == Set([
          UIDumpOfflineInspector.screenshotArtifactName,
          UIDumpOfflineInspector.treeArtifactName,
          UIDumpOfflineInspector.rawDumpArtifactName,
        ]))
  }

  private func input(verifiedCoordinates: Bool) throws -> UIDumpOfflineCaptureInput {
    let screenshot = png(width: 100, height: 100)
    let rootBounds = verifiedCoordinates ? "[0,0][100,100]" : "[0,0][50,50]"
    let tree = Data(
      """
      {"attributes":{"id":"root","type":"Page","bounds":"\(rootBounds)","hitTestBehavior":"HitTestMode.Transparent"},"children":[{"attributes":{"id":"button","type":"Button","bounds":"[10,10][30,30]","clickable":true},"children":[]}]}
      """.utf8)
    let rawDump = Data(#"{"window":"main"}"#.utf8)
    return UIDumpOfflineCaptureInput(
      identity: ViewerCaptureIdentity(
        jobID: "job-1", targetID: "target-1", bindingRevision: 3,
        capturedAtUTC: "2026-09-01T01:00:02Z"),
      screenshot: try artifact(
        id: "A-screen", name: UIDumpOfflineInspector.screenshotArtifactName,
        mediaType: UIDumpOfflineInspector.screenshotMediaType, data: screenshot),
      tree: try artifact(
        id: "A-tree", name: UIDumpOfflineInspector.treeArtifactName,
        mediaType: UIDumpOfflineInspector.treeMediaType, data: tree),
      rawDump: try artifact(
        id: "A-raw", name: UIDumpOfflineInspector.rawDumpArtifactName,
        mediaType: UIDumpOfflineInspector.rawDumpMediaType, data: rawDump),
      observedFromUTC: "2026-09-01T01:00:00Z",
      observedToUTC: "2026-09-01T01:00:02Z")
  }

  private func artifact(
    id: String,
    name: String,
    mediaType: String,
    data: Data
  ) throws -> UIDumpOfflineArtifact {
    try UIDumpOfflineArtifact(
      source: source(id: id, name: name, mediaType: mediaType, data: data),
      data: data)
  }

  private func source(
    id: String,
    name: String,
    mediaType: String,
    data: Data,
    byteCount: Int? = nil
  ) throws -> UIDumpOfflineSource {
    try UIDumpOfflineSource(
      artifactID: id,
      name: name,
      mediaType: mediaType,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteCount: byteCount ?? data.count)
  }

  private func png(width: Int, height: Int) -> Data {
    var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
    for value in [width, height] {
      bytes.append(UInt8((value >> 24) & 0xff))
      bytes.append(UInt8((value >> 16) & 0xff))
      bytes.append(UInt8((value >> 8) & 0xff))
      bytes.append(UInt8(value & 0xff))
    }
    return Data(bytes)
  }
}
