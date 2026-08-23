import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// The shapes a real ArkUI dump actually has, as opposed to the shape the
/// parser was first written against.
///
/// Both cases here were found by capturing a device rather than by reading the
/// schema: on hardware every node's `id` is empty and the tree arrives inside
/// a document envelope. A parser that only handles the tidy shape produces a
/// tree of "#—" rows hanging off an "Unknown" root.
final class ViewerRealDumpShapeTests: XCTestCase {

  // MARK: - Identity

  func testNodeIdentityComesFromAccessibilityIdWhenIdIsEmpty() throws {
    // Exactly the device shape: `id` present but empty, `accessibilityId` real.
    let tree: [String: Any] = [
      "attributes": ["type": "root", "id": "", "accessibilityId": "6", "bounds": "[0,0][720,1280]"],
      "children": [
        [
          "attributes": [
            "type": "Text", "id": "", "accessibilityId": "115",
            "bounds": "[330,269][414,294]", "text": "unlock",
          ],
          "children": [],
        ]
      ],
    ]
    let capture = try parse(tree)

    XCTAssertEqual(capture.nodes.count, 2)
    XCTAssertEqual(capture.nodes.map(\.deviceID), ["6", "115"])
    XCTAssertEqual(
      capture.nodes.map(\.identity), ["device:6", "device:115"],
      "a node with a real accessibility id must not fall back to a synthesized path identity")
  }

  func testADeveloperIdStillWinsWhenNoAccessibilityIdExists() throws {
    let tree: [String: Any] = [
      "attributes": ["type": "Column", "id": "wifi_switch", "bounds": "[0,0][10,10]"],
      "children": [],
    ]
    let capture = try parse(tree)
    XCTAssertEqual(capture.nodes.first?.deviceID, "wifi_switch")
  }

  func testASynthesizedIdentityIsNeverPresentedAsADeviceIdentifier() throws {
    let tree: [String: Any] = [
      "attributes": ["type": "Column", "bounds": "[0,0][10,10]"],
      "children": [],
    ]
    let capture = try parse(tree)
    let node = try XCTUnwrap(capture.nodes.first)
    XCTAssertNil(node.deviceID, "a node the device did not identify must not borrow an id")
    XCTAssertTrue(node.identity.hasPrefix("path:"))
  }

  // MARK: - Where the tree starts

  func testTheDocumentEnvelopeIsNotPresentedAsAComponent() throws {
    // The device wraps its tree in an object whose attributes are all empty.
    let tree: [String: Any] = [
      "attributes": [
        "type": "", "id": "", "accessibilityId": "", "bounds": "[0,0][720,1280]",
      ],
      "children": [
        [
          "attributes": ["type": "root", "accessibilityId": "6", "bounds": "[0,0][720,1280]"],
          "children": [
            [
              "attributes": ["type": "Flex", "accessibilityId": "59", "bounds": "[0,0][720,1280]"],
              "children": [],
            ]
          ],
        ]
      ],
    ]
    let capture = try parse(tree)

    XCTAssertEqual(capture.nodes.count, 2, "the envelope is the document, not a node")
    XCTAssertEqual(capture.nodes.first?.type, "root", "the tree must begin at the root component")
    XCTAssertEqual(capture.roots, ["device:6"])
    XCTAssertEqual(capture.nodes.first?.depth, 0, "the root must sit at depth zero")
    XCTAssertFalse(
      capture.nodes.contains { $0.type == "Unknown" },
      "no typeless envelope may survive into the tree")
  }

  func testAWrapperThatNamesItselfIsKept() throws {
    // Narrowness matters: a single-child container that has a type is a real
    // component, and unwrapping it would delete a node the device published.
    let tree: [String: Any] = [
      "attributes": ["type": "Stack", "accessibilityId": "1", "bounds": "[0,0][720,1280]"],
      "children": [
        [
          "attributes": ["type": "root", "accessibilityId": "6", "bounds": "[0,0][720,1280]"],
          "children": [],
        ]
      ],
    ]
    let capture = try parse(tree)
    XCTAssertEqual(capture.nodes.count, 2)
    XCTAssertEqual(capture.nodes.first?.type, "Stack")
  }

  func testATypelessEnvelopeWithSiblingsIsKept() throws {
    // Two children means the envelope carries structure of its own.
    let tree: [String: Any] = [
      "attributes": ["type": "", "bounds": "[0,0][720,1280]"],
      "children": [
        ["attributes": ["type": "root", "accessibilityId": "6"], "children": []],
        ["attributes": ["type": "root", "accessibilityId": "7"], "children": []],
      ],
    ]
    let capture = try parse(tree)
    XCTAssertEqual(capture.nodes.count, 3)
    XCTAssertEqual(capture.nodes.first?.type, "Unknown")
  }

  // MARK: - The shared device observation drives routing

  private func target(_ id: String) -> UIDumpTargetPresentation {
    UIDumpTargetPresentation(
      id: id, bindingRevision: 4, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-07-31T02:43:19Z", connection: .connected)
  }

  private func candidate(
    target id: String?, state: String,
    health: DeviceCandidatePresentation.StateObservationHealth = .current
  ) -> DeviceCandidatePresentation {
    DeviceCandidatePresentation(
      connectKey: "key-\(id ?? "none")", state: state, adoptedTargetID: id,
      bindingRevision: id == nil ? nil : 4,
      stateObservedAtUTC: "2026-08-23T00:00:00Z", stateObservationHealth: health)
  }

  func testATargetTheObservationNoLongerSeesStopsBeingCaptureReady() {
    // An unplugged device leaves the candidate list. That absence is the
    // whole signal, and it has to reach the picker without a re-read.
    let rejoined = UIDumpApplicationFacade.rejoin(
      targets: [target("TGT-a")],
      with: DeviceListPresentation(availability: .available, candidates: []))
    XCTAssertEqual(rejoined.count, 1, "the adopted target itself does not disappear")
    XCTAssertFalse(rejoined[0].isCaptureReady, "a device that is gone cannot be captured")
    XCTAssertNotNil(rejoined[0].connection.failureReason, "the picker must be able to say why")
  }

  func testAStaleObservationIsNotTreatedAsAConnectedRoute() {
    let rejoined = UIDumpApplicationFacade.rejoin(
      targets: [target("TGT-a")],
      with: DeviceListPresentation(
        availability: .available,
        candidates: [candidate(target: "TGT-a", state: "Connected", health: .stale)]))
    XCTAssertFalse(
      rejoined[0].isCaptureReady,
      "a stale observation says what was true once, not what is true now")
  }

  func testAnUnobservedStateNeverDowngradesATarget() {
    // Not yet measured is not measured-unavailable. Reporting the first poll
    // as an outage would flap every picker on launch.
    let rejoined = UIDumpApplicationFacade.rejoin(
      targets: [target("TGT-a")], with: .loading)
    XCTAssertTrue(
      rejoined[0].isCaptureReady,
      "an observation that has not arrived must not overwrite a known route")
  }

  func testAConnectedObservationRestoresTheRoute() {
    let offline = UIDumpTargetPresentation(
      id: "TGT-a", bindingRevision: 4, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-07-31T02:43:19Z",
      connection: .unavailable(reason: "HDC reported Offline"))
    let rejoined = UIDumpApplicationFacade.rejoin(
      targets: [offline],
      with: DeviceListPresentation(
        availability: .available,
        candidates: [candidate(target: "TGT-a", state: "Connected")]))
    XCTAssertTrue(rejoined[0].isCaptureReady, "a device that comes back must come back")
  }

  // MARK: - Helpers

  private func parse(_ tree: [String: Any]) throws -> ViewerCapture {
    try ViewerCaptureParser.parse(
      screenshotData: Self.png,
      treeData: try JSONSerialization.data(withJSONObject: tree),
      rawDumpData: nil,
      identity: ViewerCaptureIdentity(
        jobID: "job-shape", targetID: "target-shape", bindingRevision: 1,
        capturedAtUTC: "2026-08-23T00:00:00Z"))
  }

  /// A 720×1280 PNG header. The parser only reads the IHDR dimensions, and a
  /// real image would say nothing extra about the shapes under test.
  private static let png: Data = {
    var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    bytes += [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
    bytes += [0, 0, 0x02, 0xD0]  // 720
    bytes += [0, 0, 0x05, 0x00]  // 1280
    bytes += [8, 6, 0, 0, 0]
    return Data(bytes)
  }()
}
