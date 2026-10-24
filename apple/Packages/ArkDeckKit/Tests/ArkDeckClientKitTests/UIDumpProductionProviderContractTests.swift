import ArkDeckCore
import Foundation
import Testing

@testable import ArkDeckClientKit

/// Exercises the production Viewer provider with current wire replies. These
/// are client contract checks, not signed IPC or real-device acceptance.
struct UIDumpProductionProviderContractTests {
  private let target = UIDumpTargetPresentation(
    id: "target-viewer", bindingRevision: 7, toolVersion: "fixture", adoptedAtUTC: "",
    connection: .connected)

  private actor Replies {
    var responses: [(String, RuntimeXPCRequestTransport.ResultValue)]
    var calls: [String] = []
    init(_ responses: [(String, RuntimeXPCRequestTransport.ResultValue)]) {
      self.responses = responses
    }
    func send(_ method: String, _ params: [String: JSONValue]?) -> RuntimeXPCRequestTransport.ResultValue {
      calls.append(method)
      guard !responses.isEmpty, responses[0].0 == method else {
        return .failure(.refused("unexpected test request: \(method)"))
      }
      return responses.removeFirst().1
    }
  }

  private func envelope(_ result: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "fixture", "ok": true, "result": result])
  }

  private func detail(unknown: Bool = false, targetID: String = "target-viewer") throws -> Data {
    try currentJobDetailResponse([
      "jobId": "job-viewer", "operation": "capture.diagnostics@1", "targetId": targetID,
      "state": "succeeded", "outcomeUnknown": unknown, "waitingForHuman": false,
      "outstandingResidueCount": 0, "finishedAtUtc": "2026-09-22T00:00:00Z", "timeline": [],
    ])
  }

  @Test func captureReadsCurrentJobDetailAfterCompactRunAndRefusesUnknown() async throws {
    let replies = Replies([
      ("job.submit", .success(try envelope(["jobId": "job-viewer"]))),
      ("job.run", .success(try envelope(["jobId": "job-viewer", "state": "succeeded"]))),
      ("job.show", .success(try detail(unknown: true))),
    ])
    let provider = UIDumpProductionApplicationProvider(send: { await replies.send($0, $1) })
    guard case .failed(let reason) = await provider.recapture(target: target) else {
      Issue.record("unknown capture must not publish artifacts")
      return
    }
    #expect(reason.contains("safe terminal result"), "\(reason)")
    let calls = await replies.calls
    #expect(calls == ["job.submit", "job.run", "job.show"])
  }

  @Test func runTimeoutDoesNotReplayOrReadArtifacts() async throws {
    let replies = Replies([
      ("job.submit", .success(try envelope(["jobId": "job-viewer"]))),
      ("job.run", .failure(.timedOut)),
    ])
    let provider = UIDumpProductionApplicationProvider(send: { await replies.send($0, $1) })
    guard case .failed(let reason) = await provider.recapture(target: target) else {
      Issue.record("timeout must remain unconfirmed")
      return
    }
    #expect(reason.contains("may already have been accepted"), "\(reason)")
    let calls = await replies.calls
    #expect(calls == ["job.submit", "job.run"])
  }

  @Test func historicalCaptureUsesReadOnlyDetailAndRejectsWrongTarget() async throws {
    let replies = Replies([("job.show", .success(try detail(targetID: "another-target")))])
    let provider = UIDumpProductionApplicationProvider(send: { await replies.send($0, $1) })
    guard case .failed(let reason) = await provider.loadHistoricalCapture(
      jobID: "job-viewer", targetID: target.id, bindingRevision: 7)
    else { Issue.record("cross-target history must be rejected"); return }
    #expect(reason.contains("terminal Viewer Job facts"), "\(reason)")
    let calls = await replies.calls
    #expect(calls == ["job.show"])
  }

  @Test func advancedDumpUsesDetailAndStopsOnDisconnectWithoutRetry() async throws {
    let replies = Replies([
      ("job.submit", .success(try envelope(["jobId": "job-viewer"]))),
      ("job.run", .success(try envelope(["jobId": "job-viewer", "state": "succeeded"]))),
      ("job.show", .failure(.unavailable("connection interrupted"))),
    ])
    let provider = UIDumpProductionApplicationProvider(send: { await replies.send($0, $1) })
    guard case .failed(let reason) = await provider.advancedDump(
      target: target, selection: ViewerAdvancedDumpSelection(windowID: "60", componentID: "841"))
    else { Issue.record("disconnected detail must not publish a capture"); return }
    #expect(reason.contains("connection interrupted"), "\(reason)")
    let calls = await replies.calls
    #expect(calls == ["job.submit", "job.run", "job.show"])
  }

  @Test func advancedDumpReadsVerifiedArtifactAfterCurrentDetail() async throws {
    let bytes = Data("accessibilityId : 841\nscrollable : true".utf8)
    let digest = SHA256Hex.string(of: bytes)
    let artifact = try currentArtifactPageResponse([[
      "jobId": "job-viewer", "artifactId": "ART-viewer", "name": "advanced-dump.txt",
      "mediaType": "text/plain", "privacy": "sensitive", "byteCount": bytes.count,
      "sha256": digest, "status": "published", "createdAtUtc": "2026-09-22T00:00:00Z",
      "sourceOperation": "capture.diagnostics@1", "redactionApplied": false,
    ]])
    let chunk = try envelope([
      "artifactId": "ART-viewer", "artifactDigest": digest, "offset": 0,
      "nextOffset": bytes.count, "totalByteCount": bytes.count, "eof": true,
      "byteCount": bytes.count, "base64": bytes.base64EncodedString(),
    ])
    let replies = Replies([
      ("job.submit", .success(try envelope(["jobId": "job-viewer"]))),
      ("job.run", .success(try envelope(["jobId": "job-viewer", "state": "succeeded"]))),
      ("job.show", .success(try detail())),
      ("artifact.list", .success(artifact)),
      ("artifact.read", .success(chunk)),
    ])
    let provider = UIDumpProductionApplicationProvider(send: { await replies.send($0, $1) })
    let result = await provider.advancedDump(
      target: target, selection: ViewerAdvancedDumpSelection(windowID: "60", componentID: "841"))
    guard case .captured(let fields) = result else {
      Issue.record("current detail and verified artifact must render: \(result)")
      return
    }
    #expect(fields == [ViewerDumpField(key: "accessibilityId", value: "841"),
      ViewerDumpField(key: "scrollable", value: "true")])
    let calls = await replies.calls
    #expect(calls == ["job.submit", "job.run", "job.show", "artifact.list", "artifact.read"])
  }
}
