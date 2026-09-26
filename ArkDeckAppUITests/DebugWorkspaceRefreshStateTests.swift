import XCTest

final class DebugWorkspaceRefreshStateTests: XCTestCase {
  func testReturningToDebugProbesTheSelectedSecondDevice() throws {
    var state = DebugWorkspaceRefreshState()
    let initial = try XCTUnwrap(state.begin())
    XCTAssertNil(initial.targetID)
    XCTAssertTrue(state.finish(initial))
    state.select("B")
    let selected = try XCTUnwrap(state.begin())
    XCTAssertEqual(selected.targetID, "B")
    XCTAssertTrue(state.finish(selected))
    // Shell navigation calls refresh without a target; the view need not emit
    // another selection change when it returns with B already selected.
    let returned = try XCTUnwrap(state.begin())
    XCTAssertEqual(returned.targetID, "B")
    XCTAssertEqual(DebugWorkspaceRefreshState.reconciledTarget(
      "B", targets: ["A", "B"], hasLoaded: true, loadFailed: false), "B")
  }

  func testRestoredSelectionSurvivesInitialAndFailedTargetReads() {
    XCTAssertEqual(DebugWorkspaceRefreshState.reconciledTarget(
      "B", targets: [], hasLoaded: false, loadFailed: false), "B")
    XCTAssertEqual(DebugWorkspaceRefreshState.reconciledTarget(
      "B", targets: [], hasLoaded: true, loadFailed: true), "B")
    XCTAssertNil(DebugWorkspaceRefreshState.reconciledTarget(
      "B", targets: [], hasLoaded: true, loadFailed: false))
  }

  func testSelectingBWhileARefreshesRejectsTheLateAResult() throws {
    var state = DebugWorkspaceRefreshState()
    state.select("A")
    let old = try XCTUnwrap(state.begin())
    state.select("B")
    let current = try XCTUnwrap(state.begin())
    XCTAssertEqual(current.targetID, "B")
    XCTAssertFalse(state.finish(old))
    XCTAssertEqual(state.inFlight, current)
    XCTAssertNil(state.begin(), "duplicate refreshes of the same target coalesce")
    XCTAssertTrue(state.finish(current))
    let completion = try XCTUnwrap(state.begin(fallbackTargetID: "A"))
    XCTAssertEqual(completion.targetID, "B", "a prior operation cannot retarget the visible probe")
  }
}
