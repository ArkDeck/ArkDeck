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

  private func response(_ result: Any) throws -> RuntimeHistoryTransportResult {
    .success(
      try JSONSerialization.data(
        withJSONObject: ["ok": true, "id": "history-contract", "result": result]))
  }

  // A complete answer is the only thing that produces an available history.
  func testACompleteJobListBecomesAvailableHistory() {
    let presentation = decode(
      """
      {"ok":true,"id":"x","result":[
        {"jobId":"job-1","operation":"observe.devices@1","targetId":"t-1",
         "state":"succeeded","waitingForHuman":false,"outcomeUnknown":false,
         "outstandingResidueCount":0,"timeline":["queued","running","succeeded"],
         "executionMode":"execute","sessionId":"session-job-1","actualEffect":"readOnly",
         "createdAtUtc":"2026-08-06T07:00:00Z",
         "startedAtUtc":"2026-08-06T07:00:01Z",
         "finishedAtUtc":"2026-08-06T07:00:02Z"}]}
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
    XCTAssertEqual(job?.executionMode, "execute")
    XCTAssertEqual(job?.sessionID, "session-job-1")
    XCTAssertEqual(job?.actualEffect, "readOnly")
    XCTAssertEqual(job?.createdAtUTC, "2026-08-06T07:00:00Z")
    XCTAssertEqual(job?.startedAtUTC, "2026-08-06T07:00:01Z")
    XCTAssertEqual(job?.finishedAtUTC, "2026-08-06T07:00:02Z")
  }

  func testAnOlderJobListDoesNotInventNewHistoryFacts() throws {
    let presentation = decode(
      """
      {"ok":true,"id":"x","result":[
        {"jobId":"job-old","operation":"observe.device@1","targetId":"t-1",
         "state":"succeeded","waitingForHuman":false,"outcomeUnknown":false,
         "outstandingResidueCount":0,"timeline":["succeeded"]}]}
      """)

    let job = try XCTUnwrap(presentation.jobs.first)
    XCTAssertNil(job.executionMode)
    XCTAssertNil(job.sessionID)
    XCTAssertNil(job.actualEffect)
    XCTAssertNil(job.createdAtUTC)
    XCTAssertNil(job.startedAtUTC)
    XCTAssertNil(job.finishedAtUTC)
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
    XCTAssertTrue(
      reason?.contains("malformedFrame") == true, "the code must survive: \(reason ?? "")")
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

  func testCompleteEvidenceAndArtifactMetadataBecomeReadOnlyDetail() throws {
    let evidence = try response([
      "jobId": "job-1",
      "operationReference": "observe.device@1",
      "catalogDigest": String(repeating: "a", count: 64),
      "bindingRevision": 7,
      "providerId": "openharmony-hdc",
      "actualEffect": "readOnly",
      "executionMode": "execute",
      "terminalState": "succeeded",
      "startedAtUtc": "2026-08-06T07:00:01Z",
      "finishedAtUtc": "2026-08-06T07:00:02Z",
      "parameters": ["includeToolFacts": true, "limit": 2],
      "actualStepKinds": ["readDeviceFacts"],
      "authority": ["kind": "defaultReadOnlyPolicy", "reference": "policy@1"],
      "observation": [
        "model": "DAYU200", "firmware": "OpenHarmony", "transport": "usb",
        "bindingRevision": 8,
      ],
      "blockers": [],
    ])
    let artifacts = try response([
      [
        "artifactId": "artifact-1",
        "jobId": "job-1",
        "name": "device-facts.json",
        "mediaType": "application/json",
        "byteCount": 128,
        "sha256": String(repeating: "b", count: 64),
        "privacy": "sensitive",
        "status": "published",
        "statusDetail": NSNull(),
        "sourceOperation": "observe.device@1",
        "createdAtUtc": "2026-08-06T07:00:02Z",
        "redactionApplied": true,
      ]
    ])

    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-1",
      operationReference: "observe.device@1",
      evidenceResponse: evidence,
      artifactResponse: artifacts)

    XCTAssertEqual(detail.evidenceAvailability, .available)
    XCTAssertEqual(detail.evidence?.providerID, "openharmony-hdc")
    XCTAssertEqual(detail.evidence?.parameters.map(\.name), ["includeToolFacts", "limit"])
    XCTAssertEqual(detail.evidence?.parameters.map(\.value), ["true", "2"])
    XCTAssertTrue(detail.evidence?.parametersWereReported == true)
    XCTAssertEqual(detail.evidence?.observedBindingRevision, 8)
    XCTAssertEqual(detail.artifactAvailability, .available)
    XCTAssertEqual(detail.artifacts.count, 1)
    XCTAssertEqual(detail.artifacts.first?.role, "raw")
    XCTAssertEqual(detail.artifacts.first?.byteCount, 128)
  }

  func testEvidenceForAnotherJobOrOperationIsUnavailable() throws {
    let evidence = try response([
      "jobId": "job-other",
      "operationReference": "observe.device@1",
      "catalogDigest": String(repeating: "a", count: 64),
      "providerId": "openharmony-hdc",
      "executionMode": "execute",
      "terminalState": "succeeded",
    ])

    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-selected",
      operationReference: "observe.device@1",
      evidenceResponse: evidence,
      artifactResponse: try response([]))

    guard case .unavailable(let reason) = detail.evidenceAvailability else {
      return XCTFail("mismatched evidence must not become available")
    }
    XCTAssertTrue(reason.contains("did not match"))
    XCTAssertNil(detail.evidence)
  }

  func testOneMalformedArtifactFailsTheSectionWithoutPartialRows() throws {
    let artifacts = try response([
      [
        "artifactId": "artifact-complete",
        "jobId": "job-1",
        "name": "device-facts.json",
        "mediaType": "application/json",
        "byteCount": 128,
        "sha256": String(repeating: "b", count: 64),
        "privacy": "sensitive",
        "status": "published",
        "sourceOperation": "observe.device@1",
        "createdAtUtc": "2026-08-06T07:00:02Z",
        "redactionApplied": true,
      ],
      ["artifactId": "artifact-incomplete", "jobId": "job-1"],
    ])

    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: "job-1",
      operationReference: "observe.device@1",
      evidenceResponse: .failure("not relevant"),
      artifactResponse: artifacts)

    guard case .unavailable(let reason) = detail.artifactAvailability else {
      return XCTFail("incomplete metadata must fail the complete Artifact section")
    }
    XCTAssertTrue(reason.contains("incomplete"))
    XCTAssertTrue(detail.artifacts.isEmpty, "no partial Artifact row may survive")
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

    let detailProtocolBody = try XCTUnwrap(
      source.range(of: "public protocol RuntimeJobDetailApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    XCTAssertEqual(
      detailProtocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 2,
      "the App-facing Runtime detail surface must expose only detail and bounded export")
    XCTAssertTrue(detailProtocolBody.contains("func loadJobDetail("))
    XCTAssertTrue(detailProtocolBody.contains("func exportArtifact("))

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
    XCTAssertTrue(source.contains("request(method: \"job.list\")"))
    XCTAssertTrue(source.contains("method: \"job.evidence\""))
    XCTAssertTrue(source.contains("method: \"artifact.list\""))
    XCTAssertTrue(source.contains("method: \"artifact.read\""))
  }
}
