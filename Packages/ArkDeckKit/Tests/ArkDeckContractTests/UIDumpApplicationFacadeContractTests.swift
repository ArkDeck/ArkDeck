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

  func testAdvancedDumpRequestPinsOnlyTypedComponentDetailInputs() throws {
    let target = UIDumpTargetPresentation(
      id: "target-a", bindingRevision: 7, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-22T00:00:00Z")
    let request = try ViewerCaptureRequestBuilder.advancedDumpRequest(
      target: target,
      selection: ViewerAdvancedDumpSelection(windowID: "60", componentID: "841"),
      nonce: "advanced")

    XCTAssertEqual(request.operation.reference, "capture.diagnostics@1")
    XCTAssertEqual(request.target.targetID, "target-a")
    XCTAssertEqual(request.target.expectedBindingRevision, 7)
    XCTAssertEqual(request.inputs["advancedDump"], .bool(true))
    XCTAssertEqual(request.inputs["windowId"], .string("60"))
    XCTAssertEqual(request.inputs["componentId"], .string("841"))
    XCTAssertEqual(request.inputs["captureHilog"], .bool(false))
    XCTAssertEqual(request.inputs["uiDump"], .bool(false))
    XCTAssertEqual(request.inputs["uiScreenshot"], .bool(false))
    XCTAssertEqual(request.inputs["uiComponentTree"], .bool(false))
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
      {"attributes":{"id":"1","type":"Page","bounds":"[0,0][720,1280]","hostWindowId":"60","hitTestBehavior":"HitTestMode.Transparent","unknown":"kept"},"children":[{"attributes":{"id":"42","type":"Toggle","text":"Wi-Fi","bounds":"[40,80][220,136]","clickable":true,"childOnly":"not-root"},"children":[]}]}
      """.utf8),
      rawDumpData: Data(#"{"windows":[{"id":"w1"}]}"#.utf8),
      identity: ViewerCaptureIdentity(jobID: "job-1", targetID: "target-a", bindingRevision: 7, capturedAtUTC: "2026-08-22T00:00:00Z"))

    XCTAssertTrue(capture.coordinatesAreVerified)
    let toggle = try XCTUnwrap(capture.nodes.first { $0.deviceID == "42" })
    XCTAssertEqual(toggle.identity, "device:42")
    XCTAssertEqual(toggle.parentIdentity, "device:1")
    XCTAssertEqual(capture.node(identity: "device:1")?.hitTestBehavior, "HitTestMode.Transparent")
    let rootRawFields = try XCTUnwrap(capture.formattedRawFields(for: "device:1"))
    XCTAssertTrue(rootRawFields.contains("unknown"))
    XCTAssertFalse(
      rootRawFields.contains("children"),
      "Raw dump must contain only the selected component, never its descendant tree")
    XCTAssertFalse(rootRawFields.contains("childOnly"))
    XCTAssertTrue(
      try XCTUnwrap(capture.formattedRawFields(for: "device:42")).contains("childOnly"),
      "provider-specific fields owned by the selected component must remain available")
    XCTAssertEqual(
      capture.advancedDumpSelection(for: "device:42"),
      ViewerAdvancedDumpSelection(windowID: "60", componentID: "42"),
      "Advanced Dump must use the selected component and its enclosing window, not raw fields")
    XCTAssertEqual(ViewerHitTesting.node(in: capture, x: 60, y: 100)?.deviceID, "42")
  }

  func testAdvancedDumpParserUsesCapturedKeyColonValueText() throws {
    let fields = try ViewerAdvancedDumpParser.parse(Data("""
      WaterFlow dump:
        accessibilityId : 841
        layoutConstraint: { minWidth: 0, maxWidth: 1280 }
        scrollable : true
      """.utf8))

    XCTAssertEqual(fields[0], ViewerDumpField(key: "WaterFlow dump", value: ""))
    XCTAssertEqual(fields[1], ViewerDumpField(key: "accessibilityId", value: "841"))
    XCTAssertEqual(
      fields[2],
      ViewerDumpField(key: "layoutConstraint", value: "{ minWidth: 0, maxWidth: 1280 }"))
    XCTAssertEqual(fields[3], ViewerDumpField(key: "scrollable", value: "true"))
  }

  func testAdvancedDumpParserRejectsSidecarNoticeInsteadOfFallingBackToRawFields() {
    XCTAssertThrowsError(
      try ViewerAdvancedDumpParser.parse(
        Data("Dump saved to /data/app/example/files/arkui-comp.dump\n".utf8))) { error in
      XCTAssertEqual(error as? ViewerCaptureFailure, .advancedDumpRequiresSidecar)
    }
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

  func testScreenshotMappingClipsProviderBoundsToTheCapturedDisplay() throws {
    let raw = try XCTUnwrap(ViewerBounds(x: -40, y: 1200, width: 800, height: 160))
    let visible = try XCTUnwrap(
      ViewerScreenshotMapping.visibleBounds(
        raw, screenshotWidth: 720, screenshotHeight: 1280))

    XCTAssertEqual(visible, ViewerBounds(x: 0, y: 1200, width: 720, height: 80))
  }

  func testScreenshotMappingAccumulatesClippingAncestorsForDrawingAndHitTesting() throws {
    let parent = viewerNode(
      identity: "parent", parent: nil, children: ["child"], type: "List",
      bounds: ViewerBounds(x: 0, y: 0, width: 100, height: 100), clipsChildren: true)
    let child = viewerNode(
      identity: "child", parent: "parent", children: [], type: "ListItem",
      bounds: ViewerBounds(x: 80, y: 80, width: 100, height: 100))
    let capture = ViewerCapture(
      screenshotData: png(width: 200, height: 200), screenshotWidth: 200, screenshotHeight: 200,
      roots: ["parent"], nodes: [parent, child], rawDumpDocument: nil,
      identity: ViewerCaptureIdentity(
        jobID: "job-clipping", targetID: "target-a", bindingRevision: 1,
        capturedAtUTC: "2026-08-22T00:00:00Z"),
      coordinatesAreVerified: true)

    XCTAssertEqual(
      ViewerScreenshotMapping.visibleBounds(of: child, in: capture),
      ViewerBounds(x: 80, y: 80, width: 20, height: 20))
    XCTAssertEqual(ViewerHitTesting.node(in: capture, x: 90, y: 90)?.identity, "child")
    XCTAssertNil(
      ViewerHitTesting.node(in: capture, x: 120, y: 120),
      "a child clipped out by the list cannot remain a screenshot hit target")
  }

  func testHitTestingSelectsFloatingNavigationAboveDeeperContent() {
    let full = ViewerBounds(x: 0, y: 0, width: 200, height: 200)
    let navigation = ViewerBounds(x: 10, y: 150, width: 180, height: 40)
    let root = viewerNode(
      identity: "root", parent: nil, children: ["content", "tabbar", "overlay"],
      bounds: full)
    let content = viewerNode(
      identity: "content", parent: "root", children: ["poster"], type: "List",
      bounds: full, zIndex: 0, depth: 1)
    let poster = viewerNode(
      identity: "poster", parent: "content", children: [], type: "Image",
      bounds: full, depth: 2)
    let tabbar = viewerNode(
      identity: "tabbar", parent: "root", children: ["item"], type: "TabBar",
      bounds: navigation, hitTestBehavior: "HitTestMode.Transparent", zIndex: 3, depth: 1)
    let item = viewerNode(
      identity: "item", parent: "tabbar", children: ["icon"], type: "Column",
      bounds: navigation, depth: 2)
    let icon = viewerNode(
      identity: "icon", parent: "item", children: [], type: "SymbolGlyph",
      bounds: ViewerBounds(x: 140, y: 155, width: 40, height: 30), depth: 3)
    let overlay = viewerNode(
      identity: "overlay", parent: "root", children: [], type: "Column",
      bounds: full, hitTestBehavior: "HitTestMode.Transparent", zIndex: 88, depth: 1)
    let capture = ViewerCapture(
      screenshotData: png(width: 200, height: 200), screenshotWidth: 200, screenshotHeight: 200,
      roots: ["root"], nodes: [root, content, poster, tabbar, item, icon, overlay],
      rawDumpDocument: nil,
      identity: ViewerCaptureIdentity(
        jobID: "job-floating-navigation", targetID: "target-a", bindingRevision: 1,
        capturedAtUTC: "2026-08-24T00:00:00Z"),
      coordinatesAreVerified: true)

    XCTAssertEqual(
      ViewerHitTesting.node(in: capture, rootIdentity: "root", x: 160, y: 170)?.identity,
      "icon",
      "the foreground TabBar branch must win over a much deeper poster branch")
  }

  func testDeepTreeIndentPreservesEveryLevelWithoutLosingReadableWidth() {
    let viewport = 760.0
    let indent = ViewerTreeLayoutPolicy.leadingIndent(
      depth: 50, maximumDepth: 50, viewportWidth: viewport)
    let previous = ViewerTreeLayoutPolicy.leadingIndent(
      depth: 49, maximumDepth: 50, viewportWidth: viewport)

    XCTAssertEqual(indent, 456, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(
      indent - previous, 8,
      "deep siblings must retain a perceivable hierarchy instead of sharing a clamped edge")
    XCTAssertGreaterThanOrEqual(
      viewport - indent, 300,
      "a real fifty-level dump must not place the selected row's label outside the pane")
    XCTAssertEqual(
      ViewerTreeLayoutPolicy.leadingIndent(
        depth: 2, maximumDepth: 8, viewportWidth: viewport),
      42)
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
    XCTAssertEqual(
      capture.searchMatches(rootIdentity: nil, query: "wi-fi").map(\.identity),
      ["target"],
      "the result counter must exclude ancestors shown only as tree context")
    XCTAssertEqual(capture.subtreeNodes(rootIdentity: "section").map(\.identity), ["section", "target"])
  }

  func testViewerSourceKeepsTreeTwoAxisScrollableAndCentersEveryReveal() throws {
    let source = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift"),
      encoding: .utf8)

    XCTAssertTrue(source.contains("ScrollView([.horizontal, .vertical])"))
    XCTAssertTrue(source.contains(".scrollIndicators(.visible, axes: [.horizontal, .vertical])"))
    XCTAssertTrue(source.contains(".scrollPosition($treeScrollPosition)"))
    XCTAssertTrue(source.contains("position.scrollTo(id: identity, anchor: .center)"))
    XCTAssertTrue(source.contains("treeScrollPosition.scrollTo(y: verticalOffset)"))
    XCTAssertTrue(source.contains("viewer.search.matchCount"))
    XCTAssertTrue(source.contains("viewer.search.previous"))
    XCTAssertTrue(source.contains("viewer.search.next"))
    XCTAssertFalse(
      source.contains("static let unavailable = \"Unavailable\""),
      "missing optional fields must be omitted instead of rendered as Unavailable")
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
    text: String? = nil,
    bounds: ViewerBounds? = nil,
    clipsChildren: Bool = false,
    hitTestBehavior: String? = nil,
    zIndex: Double? = nil,
    depth: Int = 0
  ) -> ViewerNode {
    ViewerNode(
      identity: identity,
      deviceID: identity,
      parentIdentity: parent,
      children: children,
      type: type,
      text: text,
      inspectorID: nil,
      bounds: bounds,
      visible: true,
      enabled: nil,
      clickable: nil,
      focusable: nil,
      focused: nil,
      clipsChildren: clipsChildren,
      hitTestBehavior: hitTestBehavior,
      zIndex: zIndex,
      depth: depth,
      rawFields: Data("{}".utf8))
  }

  private var repository: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
