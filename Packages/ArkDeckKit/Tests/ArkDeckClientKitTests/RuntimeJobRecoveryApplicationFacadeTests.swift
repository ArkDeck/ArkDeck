@testable import ArkDeckClientKit
@testable import ArkDeckCore
import Foundation
import Testing

struct RuntimeJobRecoveryApplicationFacadeTests {
  private func job(_ state: String = "waitingForRecovery", unknown: Bool = true) -> RuntimeJobSummaryPresentation {
    .init(id: "job-recovery", operationReference: "capture.diagnostics@1", targetID: "target-one",
      state: state, waitingForHuman: false, outcomeUnknown: unknown, outstandingResidueCount: 0,
      timeline: [], sessionID: "session-job-recovery", actualEffect: "readOnly")
  }
  private func status(_ state: String, unknown: Bool) -> [String: Any] {
    ["jobId": "job-recovery", "operation": "capture.diagnostics@1", "targetId": "target-one",
     "sessionId": "session-job-recovery", "state": state, "outcomeUnknown": unknown,
     "waitingForHuman": false]
  }
  private func answer(_ result: Any) throws -> RuntimeHistoryTransportResult {
    .success(try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]))
  }
  private func detail(_ status: [String: Any]) throws -> RuntimeHistoryTransportResult {
    var row = status
    row["schemaVersion"] = "arkdeck.job-status/1"
    return try answer(["schemaVersion": "arkdeck.job/1", "job": row,
                       "timeline": ["kind": "inline", "entries": []]])
  }

  @Test func reconcileKeepsUnknownAndNeverRunsTheOriginalAction() async throws {
    let transport = RecoveryScenario([
      ("job.show", try detail(status("waitingForRecovery", unknown: true))),
      ("job.reconcile", try answer(status("waitingForRecovery", unknown: true))),
    ])
    let provider = RuntimeJobRecoveryXPCProvider(request: { await transport.send($0, $1) })
    #expect(await provider.perform(.reconcile, for: job()) == .observed(state: "waitingForRecovery", outcomeUnknown: true))
    #expect(await transport.methods() == ["job.show", "job.reconcile"])
  }

  @Test func resumeRequiresFreshConfirmedBoundaryAndDoesNotResubmit() async throws {
    let transport = RecoveryScenario([
      ("job.show", try detail(status("resumeAtConfirmedSafeBoundary", unknown: false))),
      ("job.run", try answer(status("succeeded", unknown: false))),
    ])
    let provider = RuntimeJobRecoveryXPCProvider(request: { await transport.send($0, $1) })
    #expect(await provider.perform(.resumeSafeBoundary, for: job("resumeAtConfirmedSafeBoundary", unknown: false))
      == .observed(state: "succeeded", outcomeUnknown: false))
    #expect(await transport.methods() == ["job.show", "job.run"])
    #expect(await transport.allParams() == [["jobId": .string("job-recovery")], ["jobId": .string("job-recovery")]])
  }

  @Test func unknownTerminalAndOtherStatesCannotResume() async {
    let transport = RecoveryScenario([])
    let provider = RuntimeJobRecoveryXPCProvider(request: { await transport.send($0, $1) })
    for item in [job(), job("resumeAtConfirmedSafeBoundary"), job("succeeded", unknown: false), job("running", unknown: false)] {
      guard case .refused = await provider.perform(.resumeSafeBoundary, for: item) else {
        Issue.record("non-confirmed boundary dispatched"); return
      }
    }
    #expect(await transport.methods().isEmpty)
  }

  @Test func identityStateOrRecoveryEpochDriftSendsNoAction() async throws {
    for drift: [String: Any] in [
      ["jobId": "other"], ["operation": "flash.full-restore@1"], ["targetId": "other"],
      ["sessionId": "other"], ["state": "running"], ["outcomeUnknown": true],
      ["waitingForHuman": true], ["supersededByRecoveryEpochId": "epoch-one"],
      ["resolvedByTargetAliasResolutionId": "alias-one"],
    ] {
      var fresh = status("resumeAtConfirmedSafeBoundary", unknown: false)
      fresh.merge(drift) { _, new in new }
      let transport = RecoveryScenario([("job.show", try detail(fresh))])
      let provider = RuntimeJobRecoveryXPCProvider(request: { await transport.send($0, $1) })
      guard case .refused = await provider.perform(.resumeSafeBoundary, for: job("resumeAtConfirmedSafeBoundary", unknown: false)) else {
        Issue.record("fresh drift dispatched: \(drift)"); return
      }
      #expect(await transport.methods() == ["job.show"])
    }
  }

  @Test func loaderRebindUsesOnlyTheJobsExactTargetAndNeverRunsFlash() async throws {
    let flash = RuntimeJobSummaryPresentation(id: "job-recovery", operationReference: "flash.full-restore@1",
      targetID: "target-one", state: "waitingForRecovery", waitingForHuman: false, outcomeUnknown: true,
      outstandingResidueCount: 0, timeline: [], sessionID: "session-job-recovery", actualEffect: "destructive")
    var fresh = status("waitingForRecovery", unknown: true)
    fresh["operation"] = "flash.full-restore@1"
    let target = FlashTargetPresentation(id: "target-one", bindingRevision: 2, toolVersion: "fixture", adoptedAtUTC: "fixture")
    for targets in [[target], [], [target, target], [FlashTargetPresentation(id: "other", bindingRevision: 2, toolVersion: "fixture", adoptedAtUTC: "fixture")]] {
      let transport = RecoveryScenario([("job.show", try detail(fresh))])
      let calls = LoaderCalls()
      let provider = RuntimeJobRecoveryXPCProvider(request: { await transport.send($0, $1) },
        loaderWorkspace: { .init(availability: .available, targets: targets) },
        bindLoader: { await calls.bind($0) })
      let result = await provider.perform(.rebindLoader, for: flash)
      if targets == [target] {
        #expect(result == .rebound(bindingRevision: 2))
        #expect(await calls.targets() == [target])
      } else {
        guard case .refused = result else { Issue.record("ambiguous or missing exact target was bound"); return }
        #expect(await calls.targets().isEmpty)
      }
      #expect(await transport.methods() == ["job.show"])
    }
  }

  @Test func nonFlashJobCannotRebindALoader() async {
    let transport = RecoveryScenario([])
    let provider = RuntimeJobRecoveryXPCProvider(request: { await transport.send($0, $1) },
      loaderWorkspace: { Issue.record("unexpected Loader enumeration"); return .loading },
      bindLoader: { _ in Issue.record("unexpected Loader binding"); return .failed("unexpected") })
    guard case .refused = await provider.perform(.rebindLoader, for: job()) else {
      Issue.record("non Flash accepted"); return
    }
    #expect(await transport.methods().isEmpty)
  }

  @Test func lostOrMismatchedReplyNeverRetries() async throws {
    for response in [RuntimeHistoryTransportResult.failure("lost"), try answer(status("succeeded", unknown: false).merging(["jobId": "other"]) { _, new in new })] {
      let transport = RecoveryScenario([("job.show", try detail(status("waitingForRecovery", unknown: true))), ("job.reconcile", response)])
      let provider = RuntimeJobRecoveryXPCProvider(request: { await transport.send($0, $1) })
      #expect(await provider.perform(.reconcile, for: job()) == .unconfirmed)
      #expect(await transport.methods() == ["job.show", "job.reconcile"])
    }
  }
}

private actor RecoveryScenario {
  private var replies: [(String, RuntimeHistoryTransportResult)]
  private var calls: [(String, [String: JSONValue])] = []
  init(_ replies: [(String, RuntimeHistoryTransportResult)]) { self.replies = replies }
  func send(_ method: String, _ params: [String: JSONValue]) -> RuntimeHistoryTransportResult {
    calls.append((method, params))
    guard !replies.isEmpty else { Issue.record("unexpected request \(method)"); return .failure("unexpected") }
    let response = replies.removeFirst()
    #expect(response.0 == method)
    return response.1
  }
  func methods() -> [String] { calls.map(\.0) }
  func allParams() -> [[String: JSONValue]] { calls.map(\.1) }
}

private actor LoaderCalls {
  private var values: [FlashTargetPresentation] = []
  func bind(_ target: FlashTargetPresentation) -> FlashLoaderBindingResult {
    values.append(target)
    return .bound(target)
  }
  func targets() -> [FlashTargetPresentation] { values }
}
