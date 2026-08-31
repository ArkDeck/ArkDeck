import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Exercises the production cache dependencies without launching the App or
/// contacting a daemon. These fixture records prove presentation only.
final class HistoryFilterDependenciesTests: XCTestCase {
  private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

  func testLoadingReplacingAndClearingLegacyDetailsInvalidatesTheCategory() throws {
    let job = summary()
    let initial = dependencies(jobs: [job])
    let viewer = dependencies(jobs: [job], details: [job.id: try detail(parameters: ["uiComponentTree": true])])
    let trace = dependencies(jobs: [job], details: [job.id: try detail(parameters: ["traceCategories": ["ace"]])])
    let cleared = dependencies(jobs: [job])

    XCTAssertNil(initial.workspaceKindsByJobID[job.id])
    XCTAssertEqual(viewer.workspaceKindsByJobID[job.id], .viewer)
    XCTAssertEqual(trace.workspaceKindsByJobID[job.id], .trace)
    XCTAssertNotEqual(initial, viewer, "a loaded detail must invalidate the summary-only result")
    XCTAssertNotEqual(viewer, trace, "replacement under the same dictionary key must invalidate too")
    XCTAssertNotEqual(trace, cleared, "refresh clearing details must not retain their category")
    XCTAssertEqual(initial, cleared)
  }

  func testExplicitSummaryKindWinsAndUnrelatedDetailsDoNotInvalidate() throws {
    let job = summary(workspaceKind: .debug)
    let initial = dependencies(jobs: [job])
    let withDetail = dependencies(jobs: [job], details: [job.id: try detail(parameters: ["uiComponentTree": true])])
    XCTAssertEqual(withDetail.workspaceKindsByJobID[job.id], .debug)
    XCTAssertEqual(initial, withDetail, "irrelevant detail content is not a filtering dependency")

    let legacy = summary()
    let wrongJob = try detail(jobID: "another-job", parameters: ["uiComponentTree": true])
    XCTAssertNil(dependencies(jobs: [legacy], details: [legacy.id: wrongJob]).workspaceKindsByJobID[legacy.id])
  }

  func testAnIdenticalRefreshStillReevaluatesTheRelativeTimeWindow() {
    let job = summary(date: referenceDate.addingTimeInterval(-3_599))
    let before = dependencies(jobs: [job])
    let refreshed = dependencies(jobs: [job], date: referenceDate.addingTimeInterval(2))

    XCTAssertNotEqual(before, refreshed, "an equal job.list does not mean an equal time-window result")
    XCTAssertTrue(before.includes(job.activityDate, within: 3_600))
    XCTAssertFalse(refreshed.includes(job.activityDate, within: 3_600))
  }

  func testTheClockWakesJustAfterTheEarliestInclusiveBoundary() throws {
    let first = summary(date: referenceDate.addingTimeInterval(-3_600))
    let second = summary(id: "second", date: referenceDate.addingTimeInterval(-3_590))
    let missing = summary(id: "missing")
    let input = dependencies(jobs: [first, second, missing])
    let deadline = try XCTUnwrap(input.nextExpirationDate(in: [first, second, missing], within: 3_600))

    XCTAssertTrue(input.includes(first.activityDate, within: 3_600), "the lower bound remains inclusive")
    XCTAssertEqual(deadline.timeIntervalSince(referenceDate), 0.001, accuracy: 0.000_001)
    let afterDeadline = dependencies(jobs: [first, second, missing], date: deadline)
    XCTAssertFalse(afterDeadline.includes(first.activityDate, within: 3_600))
    XCTAssertTrue(afterDeadline.includes(second.activityDate, within: 3_600))
    XCTAssertEqual(
      try XCTUnwrap(afterDeadline.nextExpirationDate(in: [first, second, missing], within: 3_600))
        .timeIntervalSince(referenceDate),
      10.001, accuracy: 0.000_001)
  }

  func testAnyTimeAndExpiredRowsNeedNoClockWake() {
    let old = summary(date: referenceDate.addingTimeInterval(-7_200))
    let input = dependencies(jobs: [old])
    XCTAssertTrue(input.includes(nil, within: nil))
    XCTAssertFalse(input.includes(nil, within: 3_600))
    XCTAssertNil(input.nextExpirationDate(in: [old], within: nil))
    XCTAssertNil(input.nextExpirationDate(in: [old], within: 3_600))
  }

  private func dependencies(
    jobs: [RuntimeJobSummaryPresentation],
    details: [String: RuntimeJobDetailPresentation] = [:],
    date: Date? = nil
  ) -> HistoryFilterDependencies {
    HistoryFilterDependencies(jobs: jobs, detailsByJobID: details, referenceDate: date ?? referenceDate)
  }

  private func summary(
    id: String = "legacy-capture", date: Date? = nil, workspaceKind: RuntimeWorkspaceKind? = nil
  ) -> RuntimeJobSummaryPresentation {
    RuntimeJobSummaryPresentation(
      id: id, operationReference: "capture.diagnostics@1", targetID: "fixture-target",
      state: "succeeded", waitingForHuman: false, outcomeUnknown: false,
      outstandingResidueCount: 0, timeline: [], workspaceKind: workspaceKind,
      finishedAtUTC: date?.formatted(.iso8601))
  }

  private func detail(
    jobID: String = "legacy-capture", parameters: [String: Any]
  ) throws -> RuntimeJobDetailPresentation {
    let evidence: [String: Any] = [
      "jobId": jobID, "operationReference": "capture.diagnostics@1",
      "catalogDigest": String(repeating: "a", count: 64), "bindingRevision": 1,
      "providerId": "fixture", "executionMode": "simulated", "terminalState": "succeeded",
      "parameters": parameters,
    ]
    return RuntimeJobDetailResponseDecoding.presentation(
      jobID: jobID, operationReference: "capture.diagnostics@1",
      evidenceResponse: .success(try JSONSerialization.data(withJSONObject: ["ok": true, "result": evidence])),
      artifactResponse: .success(try JSONSerialization.data(withJSONObject: ["ok": true, "result": []])))
  }
}
