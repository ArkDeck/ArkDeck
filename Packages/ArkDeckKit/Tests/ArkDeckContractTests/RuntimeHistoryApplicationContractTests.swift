// What the App is allowed to conclude from a daemon answer.
//
// The dangerous failure for a read-only history surface is not a crash, it is
// a confident wrong reading: showing an empty, calm history when the truth is
// "could not read it", or folding an unknown outcome into a terminal state.
// These pin against exactly that.

import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RuntimeHistoryApplicationContractTests: XCTestCase {
  private func decode(_ json: String) -> RuntimeHistoryPresentation {
    RuntimeHistoryResponseDecoding.presentation(from: Data(json.utf8))
  }

  private func reason(_ presentation: RuntimeHistoryPresentation) -> String? {
    guard case .unavailable(let reason) = presentation.availability else { return nil }
    return reason
  }

  // A complete answer is the only thing that produces an available history.
  func testACompleteJobListBecomesAvailableHistory() {
    let presentation = decode(
      """
      {"ok":true,"id":"x","result":[
        {"jobId":"job-1","operation":"observe.devices@1","targetId":"t-1",
         "state":"succeeded","waitingForHuman":false,"outcomeUnknown":false,
         "outstandingResidueCount":0,"timeline":["queued","running","succeeded"]}]}
      """)

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.jobs.count, 1)
    let job = try? XCTUnwrap(presentation.jobs.first)
    XCTAssertEqual(job?.id, "job-1")
    XCTAssertEqual(job?.operationReference, "observe.devices@1")
    XCTAssertEqual(job?.targetID, "t-1")
    XCTAssertEqual(job?.state, "succeeded")
    XCTAssertEqual(job?.timeline, ["queued", "running", "succeeded"])
    XCTAssertEqual(job?.needsAttention, false)
  }

  // The load-bearing distinction: a daemon that answered "no jobs" and a
  // daemon that could not be read must never produce the same presentation.
  func testAnEmptyHistoryIsNotTheSameAsAnUnreadableOne() {
    let empty = decode(#"{"ok":true,"id":"x","result":[]}"#)
    XCTAssertEqual(empty.availability, .available)
    XCTAssertTrue(empty.jobs.isEmpty)

    for unreadable in [
      "",
      "not json",
      "[]",
      #"{"ok":true,"id":"x"}"#,
      #"{"ok":false,"id":"x"}"#,
      #"{"id":"x","result":[]}"#,
      #"{"ok":true,"id":"x","result":"nope"}"#,
    ] {
      let presentation = decode(unreadable)
      XCTAssertNotEqual(
        presentation.availability, .available,
        "an unreadable answer must never present as available history: \(unreadable)")
      XCTAssertTrue(
        presentation.jobs.isEmpty,
        "an unavailable history must carry no jobs: \(unreadable)")
    }
  }

  // A daemon error is surfaced with its own code and message rather than
  // flattened into a generic failure the user cannot act on.
  func testADaemonErrorKeepsItsCodeAndMessage() {
    let presentation = decode(
      #"{"ok":false,"id":"x","error":{"code":"malformedFrame","message":"undecodable request frame"}}"#
    )
    let reason = reason(presentation)
    XCTAssertNotNil(reason)
    XCTAssertTrue(reason?.contains("malformedFrame") == true, "the code must survive: \(reason ?? "")")
    XCTAssertTrue(
      reason?.contains("undecodable request frame") == true,
      "the daemon's own message must survive: \(reason ?? "")")
  }

  // A job missing an identifying fact fails the whole read rather than being
  // silently dropped: a history that quietly omits rows is worse than one
  // that says it could not be read.
  func testAJobMissingAnIdentifyingFactFailsTheWholeRead() {
    for missing in ["jobId", "operation", "targetId", "state"] {
      var entry: [String: Any] = [
        "jobId": "job-1", "operation": "observe.devices@1", "targetId": "t-1",
        "state": "succeeded",
      ]
      entry.removeValue(forKey: missing)
      let data = try? JSONSerialization.data(
        withJSONObject: ["ok": true, "id": "x", "result": [entry]])
      let presentation = RuntimeHistoryResponseDecoding.presentation(from: data ?? Data())

      XCTAssertNotEqual(
        presentation.availability, .available,
        "a job without \(missing) must not yield an available history")
      XCTAssertTrue(presentation.jobs.isEmpty, "no partial row may survive a missing \(missing)")
    }
  }

  // An unknown outcome and a waiting job are never presentable as settled.
  func testUnknownOutcomeAndHumanWaitBothRaiseNeedsAttention() {
    let presentation = decode(
      """
      {"ok":true,"id":"x","result":[
        {"jobId":"job-unknown","operation":"flash.dayu200@1","targetId":"t-1",
         "state":"interrupted","waitingForHuman":false,"outcomeUnknown":true,
         "outstandingResidueCount":2,"timeline":["queued","running","interrupted"]},
        {"jobId":"job-waiting","operation":"flash.dayu200@1","targetId":"t-2",
         "state":"running","waitingForHuman":true,"outcomeUnknown":false,
         "outstandingResidueCount":0,"timeline":["queued","running"]},
        {"jobId":"job-settled","operation":"observe.devices@1","targetId":"t-3",
         "state":"succeeded","waitingForHuman":false,"outcomeUnknown":false,
         "outstandingResidueCount":0,"timeline":["succeeded"]}]}
      """)

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(presentation.jobs.map(\.needsAttention), [true, true, false])
    XCTAssertEqual(presentation.jobs.first?.outstandingResidueCount, 2)
  }

  // The App-facing surface has exactly one method, and it reads. If a
  // mutating method is ever added here it stops being a surface the sandboxed
  // GUI may hold, so the absence is pinned rather than assumed.
  func testTheApplicationSurfaceExposesNoMutation() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(
          path: "Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift"),
      encoding: .utf8)

    let protocolBody = try XCTUnwrap(
      source.range(of: "public protocol RuntimeHistoryApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 1,
      "the App-facing Runtime surface must expose exactly one call")
    XCTAssertTrue(protocolBody.contains("func refreshHistory()"))

    // Only the read-only method may be named anywhere in this file: a
    // mutating method name appearing here would mean the App can compose a
    // frame the daemon's allowlist is the only thing refusing.
    for mutating in [
      "job.submit", "job.run", "job.cancel", "job.reconcile", "job.plan",
      "target.adopt", "artifact.import", "artifact.export",
    ] {
      XCTAssertFalse(
        source.contains("\"\(mutating)"),
        "the App-facing facade must not be able to name \(mutating)")
    }
    XCTAssertTrue(source.contains("\"method\": \"job.list\""))
  }
}
