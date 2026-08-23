import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// What Viewer costs as a device tree grows.
///
/// These assert on the *shape* of the cost curve, not on wall-clock budgets.
/// A budget like "20k nodes in under 200 ms" passes on an idle machine and
/// fails under load without anything having regressed — this repository has
/// already paid for that lesson once. Growth ratios are load-normalised: both
/// halves of the ratio run on the same busy machine, so only an algorithmic
/// change can move them.
///
/// Absolute timings are recorded too, but as reported context rather than as
/// pass/fail gates.
final class ViewerScalePerformanceTests: XCTestCase {
  /// 4× the nodes may cost noticeably more than 4× the time — allocation and
  /// cache effects are real — but nothing here may be quadratic. At 4× data a
  /// quadratic step costs ~16×; the ceiling sits well below that and well
  /// above any honest linear result.
  private let quadraticCeiling = 9.0

  private let small = 5_000
  private let large = 20_000

  // MARK: - Building a capture

  func testCaptureConstructionGrowsAboutLinearlyWithNodeCount() {
    let smallNodes = ViewerUIFixture.syntheticTree(count: small)
    let largeNodes = ViewerUIFixture.syntheticTree(count: large)
    XCTAssertEqual(smallNodes.count, small)
    XCTAssertEqual(largeNodes.count, large)

    let ratio = growth(
      small: { _ = capture(smallNodes) },
      large: { _ = capture(largeNodes) })
    XCTAssertLessThan(
      ratio, quadraticCeiling,
      "building a capture's node index must not be quadratic in node count")
  }

  // MARK: - The tree's own row set

  func testFullyExpandedTreeRowsGrowAboutLinearly() {
    let smallCapture = capture(ViewerUIFixture.syntheticTree(count: small))
    let largeCapture = capture(ViewerUIFixture.syntheticTree(count: large))
    let smallExpanded = expandedIdentities(smallCapture)
    let largeExpanded = expandedIdentities(largeCapture)

    // Everything expanded is the worst case the UI can ask for, and it is what
    // a fresh capture actually does.
    XCTAssertEqual(
      smallCapture.visibleTreeNodes(
        rootIdentity: nil, query: "", expandedNodeIdentities: smallExpanded
      ).count, small)

    let ratio = growth(
      small: {
        _ = smallCapture.visibleTreeNodes(
          rootIdentity: nil, query: "", expandedNodeIdentities: smallExpanded)
      },
      large: {
        _ = largeCapture.visibleTreeNodes(
          rootIdentity: nil, query: "", expandedNodeIdentities: largeExpanded)
      })
    XCTAssertLessThan(
      ratio, quadraticCeiling, "expanding the whole tree must not be quadratic")
  }

  func testSearchGrowsAboutLinearly() {
    let smallCapture = capture(ViewerUIFixture.syntheticTree(count: small))
    let largeCapture = capture(ViewerUIFixture.syntheticTree(count: large))

    // A query that matches a broad slice: matching almost nothing would hide
    // the ancestor-walk that search does for every hit.
    XCTAssertFalse(
      smallCapture.visibleTreeNodes(
        rootIdentity: nil, query: "Text", expandedNodeIdentities: []
      ).isEmpty, "the fixture must contain Text nodes for this to measure anything")

    let ratio = growth(
      small: {
        _ = smallCapture.visibleTreeNodes(
          rootIdentity: nil, query: "Text", expandedNodeIdentities: [])
      },
      large: {
        _ = largeCapture.visibleTreeNodes(
          rootIdentity: nil, query: "Text", expandedNodeIdentities: [])
      })
    XCTAssertLessThan(ratio, quadraticCeiling, "search must not be quadratic")
  }

  // MARK: - Screenshot hit testing

  func testHitTestingGrowsAboutLinearlyAndAlwaysPicksTheDeepestNode() {
    let smallCapture = capture(ViewerUIFixture.syntheticTree(count: small))
    let largeCapture = capture(ViewerUIFixture.syntheticTree(count: large))

    // Correctness first: a measurement of the wrong answer is worthless.
    let point = (x: 40.0, y: 60.0)
    guard let hit = ViewerHitTesting.node(in: largeCapture, x: point.x, y: point.y) else {
      return XCTFail("a point inside the root must hit something")
    }
    let deeper = largeCapture.nodes.filter {
      $0.visible && ($0.bounds?.contains(x: point.x, y: point.y) ?? false)
    }.map(\.depth).max()
    XCTAssertEqual(hit.depth, deeper, "hit testing must return the deepest covering node")

    let ratio = growth(
      small: { _ = ViewerHitTesting.node(in: smallCapture, x: point.x, y: point.y) },
      large: { _ = ViewerHitTesting.node(in: largeCapture, x: point.x, y: point.y) })
    XCTAssertLessThan(ratio, quadraticCeiling, "hit testing must not be quadratic")
  }

  // MARK: - The overlay decision
  //
  // `screenshotNodes` is what the screenshot pane draws one overlay per. The
  // published brief wants each of those to be a real button; the shipped code
  // draws them non-interactive behind one coordinate target because "hundreds
  // of transparent native buttons made the screenshot appear unclickable".
  // Before that trade can be re-argued, the size of the set has to be known.

  func testOverlayNodeCountIsRecordedForTheHitTargetDecision() {
    for count in [1_000, small, large] {
      let capture = capture(ViewerUIFixture.syntheticTree(count: count))
      let drawable = capture.subtreeNodes(rootIdentity: nil).filter {
        $0.bounds != nil && $0.visible
      }
      // Not a budget — a recorded fact. AppKit gets one view per overlay if
      // these become buttons, so the number is the argument.
      print("[viewer-scale] nodes=\(count) drawableOverlays=\(drawable.count)")
      XCTAssertEqual(
        drawable.count, count,
        "the synthetic fixture gives every node valid bounds, so every node is drawable")
    }
  }

  // MARK: - Helpers

  private func capture(_ nodes: [ViewerNode]) -> ViewerCapture {
    ViewerCapture(
      screenshotData: Data(),
      screenshotWidth: ViewerUIFixture.screenWidth,
      screenshotHeight: ViewerUIFixture.screenHeight,
      roots: nodes.filter { $0.parentIdentity == nil }.map(\.identity),
      nodes: nodes,
      rawDumpDocument: nil,
      identity: ViewerCaptureIdentity(
        jobID: "job-scale", targetID: "target-scale", bindingRevision: 1,
        capturedAtUTC: "2026-08-22T00:00:00Z"),
      coordinatesAreVerified: true)
  }

  private func expandedIdentities(_ capture: ViewerCapture) -> Set<String> {
    Set(capture.nodes.filter { !$0.children.isEmpty }.map(\.identity))
  }

  /// Runs both sizes interleaved and returns `large / small` on the best run
  /// of each. Interleaving keeps a thermal or scheduling excursion from
  /// landing on only one side of the ratio; taking the minimum discards the
  /// samples that were preempted rather than slow.
  private func growth(
    small: () -> Void, large: () -> Void, rounds: Int = 5,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Double {
    small()
    large()  // warm both paths before any sample counts
    var smallBest = Double.infinity
    var largeBest = Double.infinity
    for _ in 0..<rounds {
      smallBest = Swift.min(smallBest, elapsed(small))
      largeBest = Swift.min(largeBest, elapsed(large))
    }
    guard smallBest > 0 else {
      XCTFail("the small case was too fast to time", file: file, line: line)
      return 0
    }
    let ratio = largeBest / smallBest
    print(
      "[viewer-scale] small=\(String(format: "%.3f", smallBest * 1000))ms "
        + "large=\(String(format: "%.3f", largeBest * 1000))ms "
        + "ratio=\(String(format: "%.2f", ratio))×")
    return ratio
  }

  private func elapsed(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
