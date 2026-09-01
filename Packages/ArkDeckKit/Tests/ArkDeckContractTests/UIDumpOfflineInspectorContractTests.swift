import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class UIDumpOfflineInspectorContractTests: XCTestCase {
  func testInspectionBindsVersionParserSourcesAndHitTest() throws {
    let inspection = try UIDumpOfflineInspector().inspect(input(verifiedCoordinates: true))

    XCTAssertEqual(inspection.schemaVersion, "arkdeck.ui-dump-inspection/1")
    XCTAssertEqual(inspection.provenance.kind, "offlineDerived")
    XCTAssertEqual(inspection.provenance.parser, UIDumpOfflineInspector.parserID)
    XCTAssertEqual(
      inspection.provenance.parserVersion,
      UIDumpOfflineInspector.parserVersion)
    XCTAssertEqual(
      inspection.provenance.sources.map(\.name),
      ["screenshot.png", "ui-dump.json", "ui-tree.json"])
    XCTAssertEqual(inspection.provenance.observedFromUTC, "2026-09-01T01:00:00Z")
    XCTAssertEqual(inspection.provenance.observedToUTC, "2026-09-01T01:00:02Z")
    XCTAssertTrue(inspection.capture.coordinatesAreVerified)

    let hit = try UIDumpOfflineInspector().hitTest(inspection, x: 20, y: 20)
    XCTAssertEqual(hit.schemaVersion, "arkdeck.ui-dump-hit-test/1")
    XCTAssertEqual(hit.provenance, inspection.provenance)
    XCTAssertEqual(hit.node?.deviceID, "button")
  }

  func testArtifactBytesMustMatchPublishedSizeAndDigestBeforeParsing() throws {
    let data = Data("bytes".utf8)
    let wrongSize = try source(
      id: "A-size", name: "ui-tree.json", mediaType: "application/json",
      data: data, byteCount: data.count + 1)
    XCTAssertThrowsError(try UIDumpOfflineArtifact(source: wrongSize, data: data)) { error in
      XCTAssertEqual(
        error as? UIDumpOfflineInspectorError,
        .sourceByteCountMismatch("ui-tree.json"))
    }

    let wrongDigest = try UIDumpOfflineSource(
      artifactID: "A-digest", name: "ui-tree.json", mediaType: "application/json",
      sha256: String(repeating: "0", count: 64), byteCount: data.count)
    XCTAssertThrowsError(try UIDumpOfflineArtifact(source: wrongDigest, data: data)) { error in
      XCTAssertEqual(
        error as? UIDumpOfflineInspectorError,
        .sourceDigestMismatch("ui-tree.json"))
    }
  }

  func testTheOwnerEnforcesOneFixedCaptureBudgetBeforeParsing() throws {
    let bounded = UIDumpOfflineInspector(testMaximumCaptureBytes: 32)
    XCTAssertThrowsError(try bounded.inspect(input(verifiedCoordinates: true))) { error in
      XCTAssertEqual(
        error as? UIDumpOfflineInspectorError,
        .captureTooLarge(maximumBytes: 32))
    }
    XCTAssertEqual(UIDumpOfflineInspector.maximumCaptureBytes, 64 * 1_024 * 1_024)
  }

  func testArtifactRolesAndIdentitiesAreExact() throws {
    let valid = try input(verifiedCoordinates: true)
    let wrongScreenshot = try artifact(
      id: "A-other-screen", name: "alternate.png",
      mediaType: UIDumpOfflineInspector.screenshotMediaType,
      data: valid.screenshot.data)
    XCTAssertThrowsError(
      try UIDumpOfflineInspector().inspect(
        UIDumpOfflineCaptureInput(
          identity: valid.identity, screenshot: wrongScreenshot, tree: valid.tree,
          rawDump: valid.rawDump))
    ) { error in
      XCTAssertEqual(error as? UIDumpOfflineInspectorError, .invalidSource("alternate.png"))
    }

    let duplicateIdentityTree = try artifact(
      id: valid.screenshot.source.artifactID,
      name: UIDumpOfflineInspector.treeArtifactName,
      mediaType: UIDumpOfflineInspector.treeMediaType,
      data: valid.tree.data)
    XCTAssertThrowsError(
      try UIDumpOfflineInspector().inspect(
        UIDumpOfflineCaptureInput(
          identity: valid.identity, screenshot: valid.screenshot, tree: duplicateIdentityTree,
          rawDump: valid.rawDump))
    ) { error in
      XCTAssertEqual(
        error as? UIDumpOfflineInspectorError,
        .invalidSource("duplicateArtifactId"))
    }
  }

  func testHitTestRefusesUnverifiedCoordinatesWhileInspectionRemainsReadable() throws {
    let inspection = try UIDumpOfflineInspector().inspect(input(verifiedCoordinates: false))
    XCTAssertFalse(inspection.capture.coordinatesAreVerified)
    XCTAssertFalse(inspection.capture.nodes.isEmpty)
    XCTAssertThrowsError(
      try UIDumpOfflineInspector().hitTest(inspection, x: 20, y: 20)
    ) { error in
      XCTAssertEqual(error as? UIDumpOfflineInspectorError, .coordinatesUnverified)
    }
  }

  func testAppAndCLIUseTheTypedOwnerInsteadOfCallingTheParserDirectly() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let app = try String(
      contentsOf: root.appending(
        path: "Sources/ArkDeckWorkflows/UIDumpApplicationFacade.swift"),
      encoding: .utf8)
    let cli = try String(
      contentsOf: root.appending(
        path: "Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift"),
      encoding: .utf8)
    XCTAssertTrue(app.contains("UIDumpOfflineInspector().inspect"))
    XCTAssertTrue(cli.contains("UIDumpOfflineInspector()"))
    XCTAssertFalse(app.contains("try ViewerCaptureParser.parse("))
    XCTAssertFalse(cli.contains("ViewerCaptureParser.parse("))
  }

  func testPublishedJSONSchemaPinsTheOwnerVersionsAndClosedSourceRoles() throws {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appending(path: "Contracts/cli-ui-dump-offline.schema.json"))
    let schema = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
    let inspection = try XCTUnwrap(definitions["inspection"] as? [String: Any])
    let inspectionProperties = try XCTUnwrap(
      inspection["properties"] as? [String: Any])
    XCTAssertEqual(
      (inspectionProperties["schemaVersion"] as? [String: Any])?["const"] as? String,
      UIDumpOfflineInspection.schemaVersion)
    let hitTest = try XCTUnwrap(definitions["hitTest"] as? [String: Any])
    let hitTestProperties = try XCTUnwrap(hitTest["properties"] as? [String: Any])
    XCTAssertEqual(
      (hitTestProperties["schemaVersion"] as? [String: Any])?["const"] as? String,
      UIDumpOfflineHitTest.schemaVersion)
    let provenance = try XCTUnwrap(definitions["provenance"] as? [String: Any])
    let provenanceProperties = try XCTUnwrap(provenance["properties"] as? [String: Any])
    XCTAssertEqual(
      (provenanceProperties["parser"] as? [String: Any])?["const"] as? String,
      UIDumpOfflineInspector.parserID)
    XCTAssertEqual(
      (provenanceProperties["parserVersion"] as? [String: Any])?["const"] as? String,
      UIDumpOfflineInspector.parserVersion)
    let source = try XCTUnwrap(definitions["source"] as? [String: Any])
    let sourceProperties = try XCTUnwrap(source["properties"] as? [String: Any])
    XCTAssertEqual(
      Set((sourceProperties["name"] as? [String: Any])?["enum"] as? [String] ?? []),
      Set([
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
