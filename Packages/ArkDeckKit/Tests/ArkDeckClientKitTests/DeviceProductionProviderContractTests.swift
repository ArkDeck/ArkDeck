import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

/// Current wire fixtures exercise the real App provider, without device dispatch.
final class DeviceProductionProviderContractTests: XCTestCase {
  private let jobID = "job-device-current"
  private let target = DeviceTargetPresentation(id: "TGT-fixture", bindingRevision: 1, displayName: "Fixture")
  private let revision = "11111111-1111-4111-8111-111111111111"

  private actor Replies {
    var responses: [(String, Data)]
    var calls: [(String, [String: JSONValue])] = []
    init(_ responses: [(String, Data)]) { self.responses = responses }
    func send(_ method: String, _ params: [String: JSONValue]) throws -> Data {
      calls.append((method, params))
      guard !responses.isEmpty, responses[0].0 == method else {
        throw AgentExecutionControlFailure("recordUnreadable", "unexpected fixture call: \(method)")
      }
      return responses.removeFirst().1
    }
  }

  private func envelope(_ result: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "fixture", "ok": true, "result": result])
  }

  private func runReplies(unknown: Bool = false, pagedTimeline: Bool = false) throws -> [(String, Data)] {
    var detail = try XCTUnwrap(JSONSerialization.jsonObject(with: currentJobDetailResponse([
      "jobId": jobID, "state": unknown ? "interrupted" : "succeeded",
      "outcomeUnknown": unknown, "waitingForHuman": false, "outstandingResidueCount": 0,
      "finishedAtUtc": "2026-09-05T00:00:00Z", "timeline": [],
    ])) as? [String: Any])
    if pagedTimeline {
      var result = try XCTUnwrap(detail["result"] as? [String: Any])
      result["timeline"] = ["kind": "snapshotPages", "method": "job.timeline", "jobId": jobID]
      detail["result"] = result
    }
    return [
      ("job.submit", try envelope(["schemaVersion": "arkdeck.job-acceptance/1", "jobId": jobID,
        "deduplicated": false, "phase": "accepted", "newDispatchCount": 0])),
      ("job.run", try envelope(["schemaVersion": "arkdeck.job-status/1", "jobId": jobID,
        "state": unknown ? "interrupted" : "succeeded"])),
      ("job.show", try JSONSerialization.data(withJSONObject: detail)),
    ]
  }

  private func artifactRow(_ id: String, _ name: String, _ bytes: Data) -> [String: Any] {
    ["jobId": jobID, "artifactId": id, "name": name, "mediaType": "application/octet-stream",
      "privacy": "standard", "byteCount": bytes.count, "sha256": SHA256Hex.string(of: bytes),
      "status": "published", "createdAtUtc": "2026-09-05T00:00:00Z",
      "sourceOperation": "capture.diagnostics@1", "redactionApplied": false]
  }

  private func page(_ rows: [[String: Any]], more: Bool = false) throws -> Data {
    var response = try XCTUnwrap(JSONSerialization.jsonObject(with: currentArtifactPageResponse(rows)) as? [String: Any])
    var result = try XCTUnwrap(response["result"] as? [String: Any])
    result["hasMore"] = more
    result["nextCursor"] = more ? revision + ".next" : NSNull()
    response["result"] = result
    return try JSONSerialization.data(withJSONObject: response)
  }

  private func range(_ id: String, _ bytes: Data, replacing: [String: Any] = [:]) throws -> Data {
    var result: [String: Any] = [
      "artifactId": id, "artifactDigest": SHA256Hex.string(of: bytes), "offset": 0,
      "nextOffset": bytes.count, "totalByteCount": bytes.count, "eof": true,
      "byteCount": bytes.count, "base64": bytes.base64EncodedString(),
    ]
    result.merge(replacing) { _, new in new }
    return try envelope(result)
  }

  func testRecordingReadsAllArtifactPagesAndBothVerifiedProducts() async throws {
    let frame = Data([1, 2, 3])
    let archive = TarFixture.archive(entries: [("0001.png", frame), ("0002.png", frame)])
    let timings = Data(#"{"frameDurationsSeconds":[0.4,0.7],"framesMissing":1}"#.utf8)
    let replies = Replies(try runReplies() + [
      ("artifact.list", page([artifactRow("ART-a", "frames.tar", archive)], more: true)),
      ("artifact.list", page([artifactRow("ART-b", "sequence.json", timings)])),
      ("artifact.read", range("ART-a", archive)),
      ("artifact.read", range("ART-b", timings)),
    ])
    let provider = DeviceProductionProvider { try await replies.send($0, $1) }
    guard case .captured(let recording) = await provider.recordScreen(frameCount: 2, target: target) else {
      return XCTFail("the current paged recording resources must be readable")
    }
    XCTAssertEqual(recording.frames.map(\.bytes), [frame, frame])
    XCTAssertEqual(recording.frameDurationsSeconds, [0.4, 0.7])
    XCTAssertEqual(recording.framesMissing, 1)
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.submit", "job.run", "job.show", "artifact.list", "artifact.list", "artifact.read", "artifact.read"])
    XCTAssertEqual(calls[4].1["cursor"], .string(revision + ".next"))
    for call in calls.suffix(4) {
      XCTAssertEqual(call.1["owner"], .object(["kind": .string("job"), "id": .string(jobID)]))
      XCTAssertNil(call.1["jobId"])
    }
    guard case .string(let wire)? = calls[0].1["requestJson"] else { return XCTFail("missing typed request") }
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: Data(wire.utf8))
    XCTAssertEqual(request.target.targetID, target.id)
    XCTAssertEqual(request.operation.id, "capture.screen-sequence")
  }

  func testGestureReadsItsVerifiedSummaryFromCurrentTimelinePages() async throws {
    let fragment: [String: Any] = ["entryIndex": "0", "partIndex": "0",
      "text": #"verified inject-pointer-input ["frame", "gesture"]"#, "lastPart": true]
    let replies = Replies(try runReplies(pagedTimeline: true) + [
      ("job.timeline", envelope([
        "schemaVersion": "arkdeck.cli.page/1", "pageKind": "snapshot", "order": "entryIndexAscPartIndexAsc",
        "items": [fragment], "snapshotRevision": revision, "hasMore": false, "nextCursor": NSNull(),
      ])),
    ])
    let provider = DeviceProductionProvider { try await replies.send($0, $1) }
    guard case .confirmed(let summary) = await provider.send(
      DeviceGestureRequest(gesture: .tap, x: 1, y: 2, frameWidth: 100, frameHeight: 200), to: target) else {
      return XCTFail("the verified timeline must drive the gesture summary")
    }
    XCTAssertEqual(summary["verifiedFacts"], "frame, gesture")
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.submit", "job.run", "job.show", "job.timeline"])
    XCTAssertEqual(calls.last?.1["jobId"], .string(jobID))
  }

  func testUnknownGestureDoesNotResubmitOrRunAgain() async throws {
    let replies = Replies(try runReplies(unknown: true))
    let provider = DeviceProductionProvider { try await replies.send($0, $1) }
    guard case .unknown = await provider.send(
      DeviceGestureRequest(gesture: .tap, x: 1, y: 2, frameWidth: 100, frameHeight: 200), to: target) else {
      return XCTFail("an unknown gesture must remain unknown")
    }
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.submit", "job.run", "job.show"])
  }

  private func historicalStatus(_ changes: [String: Any] = [:]) -> [String: Any] {
    var status: [String: Any] = [
      "jobId": jobID, "targetId": target.id, "operation": "capture.diagnostics@1",
      "state": "succeeded", "waitingForHuman": false, "outcomeUnknown": false,
      "outstandingResidueCount": 0, "finishedAtUtc": "2026-09-05T00:00:00Z",
    ]
    status.merge(changes) { _, value in value }
    return status
  }

  func testHistoricalScreenReadsCurrentDetailAndVerifiedArtifactWithoutDispatch() async throws {
    let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
      0, 0, 0, 64, 0, 0, 0, 32])
    let replies = Replies([
      ("job.show", try currentJobDetailResponse(historicalStatus())),
      ("artifact.list", try page([artifactRow("ART-screen", "screenshot.png", bytes)])),
      ("artifact.read", try range("ART-screen", bytes)),
    ])
    let provider = DeviceProductionProvider { try await replies.send($0, $1) }
    guard case .captured(let frame) = await provider.loadHistoricalScreen(jobID: jobID, targetID: target.id) else {
      return XCTFail("a confirmed current Job and verified screenshot must reopen")
    }
    XCTAssertEqual(frame.imageData, bytes)
    XCTAssertEqual(frame.width, 64)
    XCTAssertEqual(frame.height, 32)
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.show", "artifact.list", "artifact.read"])
  }

  func testHistoricalUnknownIdentityDriftAndUnreadableJobNeverReadArtifactsOrDispatch() async throws {
    for changes: [String: Any] in [
      ["jobId": "foreign"], ["targetId": "foreign"], ["operation": "other@1"],
      ["state": "failed"], ["waitingForHuman": true], ["outcomeUnknown": true],
      ["outstandingResidueCount": 1],
    ] {
      let replies = Replies([("job.show", try currentJobDetailResponse(historicalStatus(changes)))])
      let provider = DeviceProductionProvider { try await replies.send($0, $1) }
      guard case .failed = await provider.loadHistoricalScreen(jobID: jobID, targetID: target.id) else {
        return XCTFail("unconfirmed history must not be rendered as a capture")
      }
      let calls = await replies.calls
      XCTAssertEqual(calls.map(\.0), ["job.show"])
    }
    let replies = Replies([])
    let provider = DeviceProductionProvider { try await replies.send($0, $1) }
    guard case .failed = await provider.loadHistoricalScreen(jobID: jobID, targetID: target.id) else {
      return XCTFail("unreadable Job must remain unavailable")
    }
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.show"])
  }

  func testScreenshotRejectsForeignOwnerChangedRangeIdentityAndCorruptBytes() async throws {
    let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
      0, 0, 0, 64, 0, 0, 0, 32])
    for replacement: [String: Any] in [
      ["artifactId": "ART-foreign"], ["artifactDigest": String(repeating: "f", count: 64)],
      ["totalByteCount": bytes.count + 1, "eof": false], ["offset": 1],
      ["base64": Data(repeating: 0, count: bytes.count).base64EncodedString()],
    ] {
      let replies = Replies(try runReplies() + [
        ("artifact.list", page([artifactRow("ART-screen", "screenshot.png", bytes)])),
        ("artifact.read", range("ART-screen", bytes, replacing: replacement)),
      ])
      let provider = DeviceProductionProvider { try await replies.send($0, $1) }
      guard case .failed = await provider.captureScreen(target: target) else {
        return XCTFail("a malformed or corrupt range cannot supply an aiming frame")
      }
      let calls = await replies.calls
      XCTAssertEqual(calls.map(\.0), ["job.submit", "job.run", "job.show", "artifact.list", "artifact.read"])
    }
    var foreign = artifactRow("ART-screen", "screenshot.png", bytes)
    foreign["jobId"] = "job-foreign"
    let replies = Replies(try runReplies() + [("artifact.list", page([foreign]))])
    let provider = DeviceProductionProvider { try await replies.send($0, $1) }
    guard case .failed = await provider.captureScreen(target: target) else {
      return XCTFail("a foreign inventory must fail before reading bytes")
    }
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.submit", "job.run", "job.show", "artifact.list"])
  }
}
