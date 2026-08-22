import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class UIDumpApplicationFacadeContractTests: XCTestCase {
  func testViewerRequestPinsTargetAndEnablesOnlyPublishedCaptureInputs() throws {
    let target = UIDumpTargetPresentation(
      id: "target-a", bindingRevision: 7, toolVersion: "3.2.0f", adoptedAtUTC: "2026-08-22T00:00:00Z")
    let request = try ViewerCaptureRequestBuilder.request(target: target, nonce: "test")

    XCTAssertEqual(request.operation.reference, "capture.diagnostics@1")
    XCTAssertEqual(request.target.targetID, "target-a")
    XCTAssertEqual(request.target.expectedBindingRevision, 7)
    XCTAssertEqual(request.inputs["durationSeconds"], .integer(1))
    XCTAssertEqual(request.inputs["captureHilog"], .bool(false))
    XCTAssertEqual(request.inputs["hilogFilters"], .array([]))
    XCTAssertEqual(request.inputs["uiDump"], .bool(true))
    XCTAssertEqual(request.inputs["crashLogs"], .bool(false))
    XCTAssertEqual(request.inputs["uiScreenshot"], .bool(true))
    XCTAssertEqual(request.inputs["uiComponentTree"], .bool(true))
    XCTAssertEqual(request.inputs["redactionProfile"], .string("standard"))
  }

  func testViewerOnlyTreatsFreshConnectedCandidateAsCaptureReady() {
    let connected = DeviceCandidatePresentation(
      connectKey: "usb-a", state: "Connected", adoptedTargetID: "target-a", bindingRevision: 7)
    let offline = DeviceCandidatePresentation(
      connectKey: "usb-b", state: "Offline", adoptedTargetID: "target-b", bindingRevision: 8)
    let stale = DeviceCandidatePresentation(
      connectKey: "usb-c", state: "Connected", adoptedTargetID: "target-c", bindingRevision: 9,
      stateObservationHealth: .stale)

    XCTAssertEqual(UIDumpWorkspaceResponseDecoding.targetConnection(for: connected), .connected)
    XCTAssertFalse(UIDumpWorkspaceResponseDecoding.targetConnection(for: offline).isCaptureReady)
    XCTAssertFalse(UIDumpWorkspaceResponseDecoding.targetConnection(for: stale).isCaptureReady)
    XCTAssertEqual(
      UIDumpWorkspaceResponseDecoding.targetConnection(for: stale).failureReason,
      "HDC reported Connected, but that observation is stale")
  }

  func testParserRetainsRawFieldsAndUsesDeviceIdentityWhenUnique() throws {
    let capture = try ViewerCaptureParser.parse(
      screenshotData: png(width: 720, height: 1280),
      treeData: Data("""
      {"attributes":{"id":"1","type":"Page","bounds":"[0,0][720,1280]","unknown":"kept"},"children":[{"attributes":{"id":"42","type":"Toggle","text":"Wi-Fi","bounds":"[40,80][220,136]","clickable":true},"children":[]}]}
      """.utf8),
      rawDumpData: Data(#"{"windows":[{"id":"w1"}]}"#.utf8),
      identity: ViewerCaptureIdentity(jobID: "job-1", targetID: "target-a", bindingRevision: 7, capturedAtUTC: "2026-08-22T00:00:00Z"))

    XCTAssertTrue(capture.coordinatesAreVerified)
    let toggle = try XCTUnwrap(capture.nodes.first { $0.deviceID == "42" })
    XCTAssertEqual(toggle.identity, "device:42")
    XCTAssertEqual(toggle.parentIdentity, "device:1")
    XCTAssertTrue(try XCTUnwrap(capture.formattedRawFields(for: "device:1")).contains("unknown"))
    XCTAssertEqual(ViewerHitTesting.node(in: capture, x: 60, y: 100)?.deviceID, "42")
  }

  func testParserFallsBackToStablePathForDuplicateDeviceIDsAndDisablesUnprovenCoordinates() throws {
    let capture = try ViewerCaptureParser.parse(
      screenshotData: png(width: 720, height: 1280),
      treeData: Data("""
      {"attributes":{"id":"same","type":"Page","bounds":"[0,0][700,1280]"},"children":[{"attributes":{"id":"same","type":"Text"},"children":[]}]}
      """.utf8),
      rawDumpData: nil,
      identity: ViewerCaptureIdentity(jobID: "job-1", targetID: "target-a", bindingRevision: 7, capturedAtUTC: "2026-08-22T00:00:00Z"))

    XCTAssertFalse(capture.coordinatesAreVerified)
    XCTAssertEqual(capture.nodes.map(\.identity), ["path:0", "path:0.0"])
    XCTAssertNil(ViewerHitTesting.node(in: capture, x: 1, y: 1))
  }

  func testVisibleTreeProjectionIsLinearAndCycleSafe() {
    let root = viewerNode(identity: "root", parent: nil, children: ["section"])
    let section = viewerNode(
      identity: "section", parent: "root", children: ["target"], type: "Stack")
    // Provider data should not contain a cycle, but a malformed capture must
    // still leave Viewer responsive rather than recursively repainting forever.
    let target = viewerNode(
      identity: "target", parent: "section", children: ["section"], type: "Text", text: "Wi-Fi")
    let capture = ViewerCapture(
      screenshotData: png(width: 720, height: 1280),
      screenshotWidth: 720,
      screenshotHeight: 1280,
      roots: ["root"],
      nodes: [root, section, target],
      rawDumpDocument: nil,
      identity: ViewerCaptureIdentity(
        jobID: "job-cycle", targetID: "target-a", bindingRevision: 1,
        capturedAtUTC: "2026-08-22T00:00:00Z"),
      coordinatesAreVerified: true)

    XCTAssertEqual(
      capture.visibleTreeNodes(
        rootIdentity: nil, query: "", expandedNodeIdentities: ["root", "section", "target"])
        .map(\.identity),
      ["root", "section", "target"])
    XCTAssertEqual(
      capture.visibleTreeNodes(rootIdentity: nil, query: "wi-fi", expandedNodeIdentities: [])
        .map(\.identity),
      ["root", "section", "target"])
    XCTAssertEqual(capture.subtreeNodes(rootIdentity: "section").map(\.identity), ["section", "target"])
  }

  func testParserRetainsOpaqueOptionalRawDumpWithoutRejectingVerifiedTree() throws {
    let rawDump = Data("Window #0: opaque provider inventory\\n".utf8)
    let capture = try ViewerCaptureParser.parse(
      screenshotData: png(width: 720, height: 1280),
      treeData: Data("""
      {"attributes":{"id":"1","type":"Page","bounds":"[0,0][720,1280]"},"children":[]}
      """.utf8),
      rawDumpData: rawDump,
      identity: ViewerCaptureIdentity(jobID: "job-opaque", targetID: "target-a", bindingRevision: 7, capturedAtUTC: "2026-08-22T00:00:00Z"))

    XCTAssertEqual(capture.rawDumpDocument, rawDump)
    XCTAssertTrue(capture.coordinatesAreVerified)
  }

  func testProductionFacadeContainsNoFixtureOrRawCommandFallback() throws {
    let source = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/UIDumpApplicationFacade.swift"),
      encoding: .utf8)
    XCTAssertTrue(source.contains("method: \"job.submit\""))
    XCTAssertTrue(source.contains("method: \"artifact.read\""))
    XCTAssertTrue(source.contains("allowSensitive\": .bool(true)"))
    XCTAssertFalse(source.contains("FixtureApplicationProvider"))
    XCTAssertFalse(source.contains("hidumper"))
    XCTAssertFalse(source.contains("candidateArguments"))
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

  private func viewerNode(
    identity: String,
    parent: String?,
    children: [String],
    type: String = "Page",
    text: String? = nil
  ) -> ViewerNode {
    ViewerNode(
      identity: identity,
      deviceID: identity,
      parentIdentity: parent,
      children: children,
      type: type,
      text: text,
      inspectorID: nil,
      bounds: nil,
      visible: true,
      enabled: nil,
      clickable: nil,
      focusable: nil,
      zIndex: nil,
      depth: 0,
      rawFields: Data("{}".utf8))
  }

  private var repository: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
