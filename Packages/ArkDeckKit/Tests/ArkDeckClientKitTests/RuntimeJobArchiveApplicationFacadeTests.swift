@testable import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Testing

struct RuntimeJobArchiveApplicationFacadeTests {
  private func job(_ state: String = "waitingForRecovery") -> RuntimeJobSummaryPresentation {
    .init(id: "job-archive", operationReference: "capture.diagnostics@1", targetID: "target-one",
      state: state, waitingForHuman: false, outcomeUnknown: false, outstandingResidueCount: 0,
      timeline: [], sessionID: "session-job-archive", actualEffect: "readOnly")
  }
  private func preview(_ state: String = "waitingForRecovery", mode: String = "archive") -> [String: Any] {
    ["jobId": "job-archive", "operation": "capture.diagnostics@1", "targetId": "target-one",
     "sessionId": "session-job-archive", "state": state, "outcomeUnknown": false,
     "reviewSha256": String(repeating: "a", count: 64), "canArchive": true, "mode": mode,
     "blockers": [String](), "userConfirmationId": mode == "archive" ? NSNull() : "original-user-decision",
     "lastConfirmedStepId": NSNull()]
  }
  @Test func reviewAndExplicitApplyKeepExactJobAndHashWithoutRequestingAuthority() async throws {
    let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: preview()))
    let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
    guard case .review(let review) = await provider.preview(job()) else { Issue.record("valid preview refused"); return }
    #expect(await transport.methods() == ["job.archive.preview"])
    #expect(await provider.archive(review) == .archived(sessionPublished: true))
    let params = try #require(await transport.parameters().last)
    #expect(params.keys.sorted() == ["expectedReviewSha256", "jobId", "userConfirmationId"])
    #expect(params["expectedReviewSha256"] == .string(review.reviewSHA256))
    #expect(params["jobId"] == .string(job().id))
    #expect(await transport.methods() == ["job.archive.preview", "job.archive"])
  }
  @Test func missingOrContradictoryProofAndIdentityDriftCannotBecomeAnArchiveReview() async throws {
    for drift: [String: Any] in [
      ["jobId": "other"], ["targetId": "other"], ["sessionId": "other"], ["operation": "other"],
      ["state": "running"], ["outcomeUnknown": true], ["canArchive": false], ["blockers": ["outcomeNotConfirmed"]],
      ["reviewSha256": "bad"], ["mode": "finishAudit"], ["lastConfirmedStepId": 1],
    ] {
      let raw = preview().merging(drift) { _, new in new }
      let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: raw))
      let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
      #expect(await provider.preview(job()) == .unavailable)
      #expect(await transport.methods() == ["job.archive.preview"])
    }
    for member in ["outcomeUnknown", "canArchive", "blockers", "userConfirmationId", "lastConfirmedStepId"] {
      var raw = preview(); raw.removeValue(forKey: member)
      let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: raw))
      let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
      #expect(await provider.preview(job()) == .unavailable)
    }
  }
  @Test func blockedPreviewIsVisibleAndCannotDispatch() async throws {
    var raw = preview(); raw["canArchive"] = false; raw["mode"] = "unavailable"
    raw["blockers"] = ["managedProcessOrCompensationProofUnavailable"]
    let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: raw))
    let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
    guard case .review(let review) = await provider.preview(job()) else { Issue.record("blocked preview hidden"); return }
    #expect(await provider.archive(review) == .refused)
    #expect(await transport.methods() == ["job.archive.preview"])
  }
  @Test func continuingPublicationKeepsOriginalDecisionAndLostReplyIsNotRetried() async throws {
    for loseReply in [false, true] {
      let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: preview("interrupted", mode: "finishPublication")),
        loseReply: loseReply, published: false)
      let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
      guard case .review(let review) = await provider.preview(job("interrupted")) else { Issue.record("resume preview refused"); return }
      #expect(await provider.archive(review) == (loseReply ? .unconfirmed : .archived(sessionPublished: false)))
      #expect(await transport.parameters().last?["userConfirmationId"] == .string("original-user-decision"))
      #expect(await transport.methods() == ["job.archive.preview", "job.archive"])
    }
  }
}

private actor ArchiveTransport {
  let preview: Data
  let loseReply: Bool
  let published: Bool
  private var calls: [(String, [String: JSONValue])] = []
  init(preview: Data, loseReply: Bool = false, published: Bool = true) {
    self.preview = preview; self.loseReply = loseReply; self.published = published
  }
  func send(_ method: String, _ params: [String: JSONValue]) -> RuntimeHistoryTransportResult {
    calls.append((method, params))
    if method == "job.archive.preview" {
      return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "result": JSONSerialization.jsonObject(with: preview)]))
    }
    guard !loseReply else { return .failure("lost after dispatch") }
    let confirmation: String
    if case .string(let value) = params["userConfirmationId"] { confirmation = value } else { confirmation = "missing" }
    return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "result": [
      "jobId": "job-archive", "sessionId": "session-job-archive", "state": "interrupted", "outcomeUnknown": false,
      "sessionPublished": published, "userConfirmationId": confirmation,
      "publication": ["phase": published ? "catalogPublished" : "awaitingStorage",
        "manifestSha256": published ? String(repeating: "b", count: 64) as Any : NSNull() as Any,
        "failureCode": published ? NSNull() as Any : "storageUnavailable" as Any],
    ]]))
  }
  func methods() -> [String] { calls.map(\.0) }
  func parameters() -> [[String: JSONValue]] { calls.map(\.1) }
}
