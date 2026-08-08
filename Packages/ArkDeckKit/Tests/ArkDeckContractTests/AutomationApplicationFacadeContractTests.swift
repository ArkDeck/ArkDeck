import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class AutomationApplicationFacadeContractTests: XCTestCase {
  func testTaskListDecodesOnlyCompleteTypedRuntimeFacts() throws {
    let data = try response([
      [
        "htaskId": "HTASK-42",
        "type": "debugCrash",
        "lifecycle": "running",
        "stage": "collecting",
        "waitReason": NSNull(),
        "targetId": "target-dayu200",
        "goal": "Converge on a verified crash repair",
        "activeRound": 2,
        "activeJobId": "job-42",
        "cancelRequested": false,
        "version": 7,
        "createdAtUtc": "2026-08-08T08:00:00Z",
        "updatedAtUtc": "2026-08-08T08:02:00Z",
        "allowedOperations": ["capture.diagnostics@1"],
      ]
    ])

    let presentation = AutomationResponseDecoding.list(.success(data))
    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.tasks.count, 1)
    XCTAssertEqual(presentation.tasks[0].id, "HTASK-42")
    XCTAssertEqual(presentation.tasks[0].activeJobID, "job-42")
    XCTAssertFalse(presentation.tasks[0].isTerminal)
  }

  func testMalformedTaskFailsTheWholeListClosed() throws {
    let data = try response([["htaskId": "HTASK-without-runtime-facts"]])
    let presentation = AutomationResponseDecoding.list(.success(data))
    guard case .unavailable(let reason) = presentation.availability else {
      return XCTFail("incomplete task facts must not render")
    }
    XCTAssertTrue(reason.contains("incomplete"))
    XCTAssertTrue(presentation.tasks.isEmpty)
  }

  func testReconcileResponseMustReturnTheSameTask() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "id": "test", "ok": true,
      "result": [
        "action": "dispatched",
        "reasonCode": "nextStage",
        "task": taskObject(id: "HTASK-42"),
      ],
    ])
    let result = AutomationResponseDecoding.action(
      .success(data), action: .reconcile, taskID: "HTASK-42")
    guard case .completed(let task) = result else {
      return XCTFail("matching task must decode")
    }
    XCTAssertEqual(task.id, "HTASK-42")

    guard case .failed = AutomationResponseDecoding.action(
      .success(data), action: .reconcile, taskID: "HTASK-other")
    else { return XCTFail("a different task must fail closed") }
  }

  func testApplicationSurfaceCannotCreateOrWidenATask() throws {
    XCTAssertEqual(
      Set([
        AutomationTaskAction.reconcile.rawValue,
        AutomationTaskAction.pause.rawValue,
        AutomationTaskAction.cancel.rawValue,
      ]),
      Set(["reconcile", "pause", "cancel"]))

    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/AutomationApplicationFacade.swift"),
      encoding: .utf8)

    XCTAssertTrue(source.contains("\"task.list\""))
    XCTAssertTrue(source.contains("method: \"task.\\(action.rawValue)\""))
    for forbidden in [
      "task.submit", "task.resume", "task.proposePatch", "task.promotion",
      "task.workspaceGC", "capability.install", "authorization",
    ] {
      XCTAssertFalse(source.contains("\"\(forbidden)\""), forbidden)
    }
  }

  private func response(_ value: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "test", "ok": true, "result": value])
  }

  private func taskObject(id: String) -> [String: Any] {
    [
      "htaskId": id,
      "type": "debugCrash",
      "lifecycle": "running",
      "stage": "collecting",
      "waitReason": NSNull(),
      "targetId": "target-dayu200",
      "goal": "Converge",
      "activeRound": 2,
      "activeJobId": NSNull(),
      "cancelRequested": false,
      "version": 7,
      "createdAtUtc": "2026-08-08T08:00:00Z",
      "updatedAtUtc": "2026-08-08T08:02:00Z",
      "allowedOperations": ["capture.diagnostics@1"],
    ]
  }
}
