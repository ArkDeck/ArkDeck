@testable import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Testing

struct RuntimeJobArchiveApplicationFacadeTests {
  private func job(_ state: String = "waitingForRecovery", unknown: Bool = false) -> RuntimeJobSummaryPresentation {
    .init(id: "job-archive", operationReference: unknown ? "flash.full-restore@1" : "capture.diagnostics@1", targetID: "target-one",
      state: state, waitingForHuman: false, outcomeUnknown: unknown, outstandingResidueCount: 0,
      timeline: [], sessionID: "session-job-archive", actualEffect: unknown ? "destructive" : "readOnly")
  }
  private func preview(_ state: String = "waitingForRecovery", mode: String = "archive", unknown: Bool = false) -> [String: Any] {
    ["jobId": "job-archive", "operation": unknown ? "flash.full-restore@1" : "capture.diagnostics@1", "targetId": "target-one",
     "sessionId": "session-job-archive", "state": state, "outcomeUnknown": unknown,
     "reviewSha256": String(repeating: "a", count: 64), "canArchive": true, "mode": mode,
     "retainedHazards": unknown ? ["runtimeCapabilityLineageRetained", "unresolved-destructive-intent:flash:original"] : [String](),
     "resourceReleaseAuthorized": !unknown && mode == "finishPublication",
     "blockers": [String](), "userConfirmationId": ["archive", "archiveWithHazards"].contains(mode) ? NSNull() : "original-user-decision",
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
    for member in ["outcomeUnknown", "canArchive", "blockers", "userConfirmationId", "lastConfirmedStepId", "retainedHazards", "resourceReleaseAuthorized"] {
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
  @Test func retainedRiskReviewAndPublicationKeepUnknownHazardsAndOriginalDecision() async throws {
    for (state, mode) in [("waitingForRecovery", "archiveWithHazards"), ("userAbandonRequested", "finishAudit"), ("interrupted", "finishPublication")] {
      let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: preview(state, mode: mode, unknown: true)))
      let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
      guard case .review(let review) = await provider.preview(job(state, unknown: true)) else { Issue.record("retained review refused"); continue }
      #expect(review.retainsRisks && !review.resourceReleaseAuthorized)
      #expect(review.retainedHazards.count == 2)
      #expect(await provider.archive(review) == .archived(sessionPublished: true))
      if mode != "archiveWithHazards" {
        #expect(await transport.parameters().last?["userConfirmationId"] == .string("original-user-decision"))
      }
      #expect(await transport.parameters().last?.keys.sorted() == ["expectedReviewSha256", "jobId", "userConfirmationId"])
      #expect(await transport.methods() == ["job.archive.preview", "job.archive"])
    }
  }
  @Test func retainedReviewCannotOfferReleaseOrLoseHazardsAndRepliesCannotSettleUnknown() async throws {
    let original = preview(mode: "archiveWithHazards", unknown: true)
    for drift: [String: Any] in [
      ["retainedHazards": [String]()], ["retainedHazards": ["duplicate", "duplicate"]],
      ["resourceReleaseAuthorized": true], ["mode": "archive"], ["outcomeUnknown": false],
    ] {
      let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: original.merging(drift) { _, value in value }))
      let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
      #expect(await provider.preview(job(unknown: true)) == .unavailable)
      #expect(await transport.methods() == ["job.archive.preview"])
    }
    for drift in ["clearUnknown", "releaseResources", "dropHazards"] {
      let transport = ArchiveTransport(preview: try JSONSerialization.data(withJSONObject: original), resultDrift: drift)
      let provider = RuntimeJobArchiveXPCProvider(request: { await transport.send($0, $1) })
      guard case .review(let review) = await provider.preview(job(unknown: true)) else { Issue.record("valid retained review refused"); continue }
      #expect(await provider.archive(review) == .unconfirmed)
      #expect(await transport.methods() == ["job.archive.preview", "job.archive"])
    }
  }
}

private actor ArchiveTransport {
  let preview: Data
  let loseReply: Bool
  let published: Bool
  let resultDrift: String?
  private var calls: [(String, [String: JSONValue])] = []
  init(preview: Data, loseReply: Bool = false, published: Bool = true, resultDrift: String? = nil) {
    self.preview = preview; self.loseReply = loseReply; self.published = published
    self.resultDrift = resultDrift
  }
  func send(_ method: String, _ params: [String: JSONValue]) -> RuntimeHistoryTransportResult {
    calls.append((method, params))
    if method == "job.archive.preview" {
      return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "result": JSONSerialization.jsonObject(with: preview)]))
    }
    guard !loseReply else { return .failure("lost after dispatch") }
    let confirmation: String
    if case .string(let value) = params["userConfirmationId"] { confirmation = value } else { confirmation = "missing" }
    let raw = try! JSONSerialization.jsonObject(with: preview) as! [String: Any]
    let unknown = raw["outcomeUnknown"] as? Bool ?? false
    var result: [String: Any] = [
      "jobId": "job-archive", "sessionId": "session-job-archive", "state": "interrupted", "outcomeUnknown": unknown,
      "retainedHazards": raw["retainedHazards"] as? [String] ?? [], "resourceReleaseAuthorized": !unknown,
      "sessionPublished": published, "userConfirmationId": confirmation,
      "publication": ["phase": published ? "catalogPublished" : "awaitingStorage",
        "manifestSha256": published ? String(repeating: "b", count: 64) as Any : NSNull() as Any,
        "failureCode": published ? NSNull() as Any : "storageUnavailable" as Any],
    ]
    if resultDrift == "clearUnknown" { result["outcomeUnknown"] = false }
    if resultDrift == "releaseResources" { result["resourceReleaseAuthorized"] = true }
    if resultDrift == "dropHazards" { result["retainedHazards"] = [String]() }
    return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]))
  }
  func methods() -> [String] { calls.map(\.0) }
  func parameters() -> [[String: JSONValue]] { calls.map(\.1) }
}
