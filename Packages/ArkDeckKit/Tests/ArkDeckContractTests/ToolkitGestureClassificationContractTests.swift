import CoreGraphics
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// What a pointer sequence becomes (IDC-AC-8: "长按（≥500 ms, <6 pt）产出
/// long-press 而非 tap，tap 锚定 down 点").
///
/// These two clauses had no test until now. The rule lived in a view model,
/// where the App target has nowhere to exercise it from - so "a long press is
/// not downgraded to a tap" was a claim in a comment. Both are cheap to get
/// wrong in a way nobody would notice: a downgraded long press still reaches
/// the device and still reports success, and a gesture anchored at the release
/// lands a few points from where somebody aimed.
final class ToolkitGestureClassificationContractTests: XCTestCase {
  private let frame = ToolkitScreenFrame(
    imageData: Data(), width: 720, height: 1280,
    capturedAtUTC: "2026-08-26T00:00:00Z", jobID: "job-1")
  private let rendered = CGSize(width: 360, height: 640)

  private func classify(
    from start: CGPoint, to end: CGPoint, heldFor: TimeInterval
  ) -> ToolkitGestureRequest {
    ToolkitGestureClassification.classify(
      start: start, end: end,
      travelled: hypot(end.x - start.x, end.y - start.y), heldFor: heldFor,
      rendered: rendered, frame: frame)
  }

  // MARK: - A long press is not a tap

  func testAHoldAtLeastHalfASecondIsALongPress() {
    let request = classify(
      from: CGPoint(x: 100, y: 200), to: CGPoint(x: 100, y: 200), heldFor: 0.5)
    XCTAssertEqual(request.gesture, .longPress)
  }

  /// The boundary in both directions, so a rule that had drifted by a
  /// millisecond would show.
  func testTheHoldBoundaryIsExactlyWhereTheDesignPutIt() {
    XCTAssertEqual(
      classify(from: .zero, to: .zero, heldFor: 0.499).gesture, .tap,
      "just under half a second is still a tap")
    XCTAssertEqual(
      classify(from: .zero, to: .zero, heldFor: 0.5).gesture, .longPress,
      "half a second is deliberate; reporting it as a tap discards what "
        + "somebody meant, and the tap still succeeds so nothing would say so")
  }

  /// A hold that wobbled is still a hold. Under the travel threshold the
  /// movement is a hand, not an intention.
  func testAHoldThatWobbledIsStillALongPress() {
    let request = classify(
      from: CGPoint(x: 100, y: 200), to: CGPoint(x: 103, y: 203), heldFor: 0.8)
    XCTAssertEqual(request.gesture, .longPress)
  }

  /// Past the travel threshold it is a drag, however long it was held - a
  /// long press that moved across the screen is not what anybody asked for.
  func testTravelWinsOverHoldTime() {
    XCTAssertEqual(
      classify(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 10), heldFor: 3).gesture,
      .swipe)
  }

  // MARK: - Anchored where the press began

  /// Every gesture starts where the finger went down, never where it came up.
  func testEveryGestureIsAnchoredAtTheDownPoint() {
    let down = CGPoint(x: 90, y: 160)
    // 90/360 of 720 = 180; 160/640 of 1280 = 320.
    for (label, request) in [
      ("tap", classify(from: down, to: down, heldFor: 0.1)),
      ("long press", classify(from: down, to: CGPoint(x: 92, y: 162), heldFor: 0.9)),
      ("swipe", classify(from: down, to: CGPoint(x: 300, y: 500), heldFor: 0.3)),
    ] {
      XCTAssertEqual(request.x, 180, label)
      XCTAssertEqual(request.y, 320, label)
    }
  }

  /// A few points of drift while clicking must not move the landing point.
  func testDriftWhileClickingDoesNotMoveTheLanding() {
    let steady = classify(from: CGPoint(x: 90, y: 160), to: CGPoint(x: 90, y: 160), heldFor: 0.1)
    let drifted = classify(from: CGPoint(x: 90, y: 160), to: CGPoint(x: 94, y: 163), heldFor: 0.1)
    XCTAssertEqual(drifted.gesture, .tap)
    XCTAssertEqual(drifted.x, steady.x)
    XCTAssertEqual(drifted.y, steady.y)
  }

  // MARK: - What reaches the device

  /// The frame the gesture was computed from travels with it, so the runtime
  /// can refuse one computed against a screen that has since changed size.
  func testTheFrameItWasComputedFromTravelsWithIt() {
    let request = classify(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10), heldFor: 0.1)
    XCTAssertEqual(request.frameWidth, 720)
    XCTAssertEqual(request.frameHeight, 1280)
  }

  /// A press at the very edge maps inside the picture. The device refuses a
  /// coordinate off the panel, and one clamped here is still where the person
  /// pressed.
  func testAPressAtTheEdgeStaysInsideTheDevicePicture() {
    let request = classify(
      from: CGPoint(x: 360, y: 640), to: CGPoint(x: 360, y: 640), heldFor: 0.1)
    XCTAssertEqual(request.x, 719)
    XCTAssertEqual(request.y, 1279)
  }

  /// Durations are clamped into the operation's published range rather than
  /// invented: a gesture the device would refuse never leaves here.
  func testDurationsStayInsideTheirPublishedRange() {
    let brief = classify(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 10), heldFor: 0.01)
    XCTAssertEqual(brief.durationMs, ToolkitGestureClassification.swipeDurationBoundsMs.lower)
    let endless = classify(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 10), heldFor: 30)
    XCTAssertEqual(endless.durationMs, ToolkitGestureClassification.swipeDurationBoundsMs.upper)
    let held = classify(from: .zero, to: .zero, heldFor: 0.6)
    XCTAssertEqual(held.durationMs, 600)
    let veryLongHold = classify(from: .zero, to: .zero, heldFor: 30)
    XCTAssertEqual(
      veryLongHold.durationMs, ToolkitGestureClassification.longPressDurationBoundsMs.upper)
  }

  /// Every classification produces a request the catalog would accept.
  func testEveryClassificationIsSubmittable() throws {
    let target = ToolkitTargetPresentation(
      id: "TGT-1", bindingRevision: 1, displayName: "DAYU200")
    for request in [
      classify(from: .zero, to: .zero, heldFor: 0.1),
      classify(from: .zero, to: .zero, heldFor: 0.9),
      classify(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 200), heldFor: 0.3),
    ] {
      XCTAssertNoThrow(
        try ToolkitDeviceControlFacade.gestureRequest(request, target: target, nonce: "n"),
        "\(request.gesture) must be submittable as it stands")
    }
  }
}
