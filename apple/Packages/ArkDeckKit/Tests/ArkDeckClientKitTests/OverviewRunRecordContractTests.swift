// What the Overview may conclude from a run record.
//
// Two judgements carry the page: which runs were one piece of work, and
// whether a finished run may be offered as "run it again". The dangerous
// failure is not an ugly list — it is an enabled button that promises a repeat
// the Runtime would refuse, or two unrelated runs presented as one line the
// operator can continue.

import ArkDeckCore
import Foundation
import Testing

@testable import ArkDeckClientKit

struct OverviewRunRecordContractTests {
  @Test func continuationCopiesTypedInputsAndThreadButCreatesNewRequestIdentity() throws {
    let job = DiagnosticSessionUIFixture.job
    let draft = try RuntimeWorkspaceContinuation.prepare(
      job: job, detail: DiagnosticSessionUIFixture.detail(),
      currentTargetID: job.targetID, currentBindingRevision: 3).get()
    let first = try draft.request(nonce: "first-request")
    let second = try draft.request(nonce: "second-request")
    #expect(first.inputs == ["durationSeconds": .integer(10), "captureHilog": .bool(true), "uiDump": .bool(false)])
    #expect(first.clientContext?.threadID == job.threadID)
    #expect(first.clientContext?.provenance?["arkdeck.continuedFromJob"] == job.id)
    #expect(first.requestID != second.requestID)
    #expect(first.idempotencyKey != second.idempotencyKey)
    #expect(first.authorization == nil)
    #expect(try !String(decoding: JSONEncoder().encode(first), as: UTF8.self).contains("campaignReservation"))
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    #expect(json["sessionId"] == nil, "a thread must not become a Runtime session identity")
  }

  @Test func continuationRefusesBindingAndTargetDrift() throws {
    let job = DiagnosticSessionUIFixture.job
    let detail = try DiagnosticSessionUIFixture.detail()
    for (target, binding) in [(job.targetID, Optional(4)), ("other-target", Optional(3)), (job.targetID, nil)] {
      let result = RuntimeWorkspaceContinuation.prepare(
        job: job, detail: detail, currentTargetID: target, currentBindingRevision: binding)
      guard case .failure(let failure) = result else {
        Issue.record("drift was accepted")
        return
      }
      #expect(failure.reason == "continuation_target_or_binding_changed")
    }
  }

  @Test func continuationRefusesMutationOldMarkerTimesAndMalformedTypedInputs() throws {
    let job = DiagnosticSessionUIFixture.job
    let cases: [[String: Any]] = [
      ["durationSeconds": 10, "uiScreenshot": true],
      ["durationSeconds": 10, "traceCategories": ["ace"]],
      ["durationSeconds": 10, "markers": ["2026-08-27T08:00:00Z#old"]],
      ["durationSeconds": "10"], ["durationSeconds": 601],
      ["durationSeconds": 10, "artifactLease": "old-lease"],
    ]
    func response(_ result: Any) throws -> RuntimeHistoryTransportResult {
      .success(try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]))
    }
    for inputs in cases {
      let detail = RuntimeJobDetailResponseDecoding.presentation(
        jobID: job.id, operationReference: job.operationReference,
        statusResponse: .success(try currentJobDetailResponse([
          "jobId": job.id, "operation": job.operationReference, "targetId": job.targetID,
          "sessionId": job.sessionID!, "timeline": [],
        ])),
        evidenceResponse: try response([
          "jobId": job.id, "operationReference": job.operationReference,
          "catalogDigest": String(repeating: "a", count: 64), "providerId": "hdc",
          "executionMode": "execute", "terminalState": "succeeded", "actualEffect": "readOnly",
          "bindingRevision": 3, "parameters": inputs,
        ]), artifactResponse: .success(try currentArtifactPageResponse([])))
      let result = RuntimeWorkspaceContinuation.prepare(
        job: job, detail: detail, currentTargetID: job.targetID, currentBindingRevision: 3)
      guard case .failure = result else {
        Issue.record("accepted unsafe or invalid draft: \(inputs)")
        return
      }
    }
  }

  private func continuationResponse(_ value: Any) throws -> RuntimeHistoryTransportResult {
    .success(try JSONSerialization.data(withJSONObject: ["ok": true, "result": value]))
  }

  private func continuationSourceStatus() -> [String: Any] {
    let job = DiagnosticSessionUIFixture.job
    return [
      "jobId": job.id, "operation": job.operationReference, "targetId": job.targetID,
      "sessionId": job.sessionID!, "state": job.state, "outcomeUnknown": false,
    ]
  }

  private func continuationDraft() throws -> RuntimeWorkspaceContinuation {
    try RuntimeWorkspaceContinuation.prepare(
      job: DiagnosticSessionUIFixture.job, detail: DiagnosticSessionUIFixture.detail(),
      currentTargetID: DiagnosticSessionUIFixture.job.targetID, currentBindingRevision: 3).get()
  }

  @Test func continuationFreshChecksPrecedeSubmissionAndRunIsOneShot() async throws {
    let source = DiagnosticSessionUIFixture.job
    let transport = OverviewRPCScenario([
      ("target.list", try continuationResponse([["targetId": source.targetID, "bindingRevision": 3]])),
      ("job.show", .success(try currentJobDetailResponse(continuationSourceStatus()))),
      ("job.submit", try continuationResponse(["jobId": "job-new", "deduplicated": false])),
      ("job.run", try continuationResponse(["jobId": "job-new", "state": "succeeded"])),
      ("job.show", .success(try currentJobDetailResponse([
        "jobId": "job-new", "operation": source.operationReference, "targetId": source.targetID,
        "state": "succeeded", "outcomeUnknown": false,
      ]))),
    ])
    let provider = RuntimeContinuationXPCProvider(
      reader: RuntimeJobDetailApplicationFacade.make(arguments: ["--ui-test-runtime-history"]),
      request: { await transport.request($0, $1) })
    let submission = await provider.submit(try continuationDraft())
    #expect(try submission.get() == "job-new")
    let first = await provider.run(jobID: "job-new")
    #expect(try first.get() == "succeeded")
    guard case .failure = await provider.run(jobID: "job-new") else {
      Issue.record("run was dispatched twice")
      return
    }
    let calls = await transport.recordedCalls()
    #expect(calls.map(\.0) == ["target.list", "job.show", "job.submit", "job.run", "job.show"])
    guard case .string(let requestJSON)? = calls[2].1["requestJson"] else {
      Issue.record("missing typed request")
      return
    }
    let json = try #require(JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any])
    #expect(json["sessionId"] == nil)
    #expect(json["authorization"] == nil)
    #expect(json["campaignReservation"] == nil)
    #expect(calls[3].1 == ["jobId": .string("job-new")])
  }

  @Test func continuationFreshBindingDriftAndForeignRunReadNoNewJob() async throws {
    let transport = OverviewRPCScenario([
      ("target.list", try continuationResponse([["targetId": DiagnosticSessionUIFixture.job.targetID, "bindingRevision": 4]])),
      ("job.show", .success(try currentJobDetailResponse(continuationSourceStatus()))),
    ])
    let provider = RuntimeContinuationXPCProvider(
      reader: RuntimeJobDetailApplicationFacade.make(arguments: ["--ui-test-runtime-history"]),
      request: { await transport.request($0, $1) })
    guard case .failure = await provider.run(jobID: DiagnosticSessionUIFixture.job.id) else {
      Issue.record("historical Job reached run")
      return
    }
    let initial = await transport.recordedCalls()
    #expect(initial.isEmpty)
    guard case .failure = await provider.submit(try continuationDraft()) else {
      Issue.record("binding drift reached submit")
      return
    }
    let calls = await transport.recordedCalls()
    #expect(calls.map(\.0) == ["target.list", "job.show"])
  }

  @Test func continuationRejectsDeduplicationAndDoesNotRetryUnknownRunOutcome() async throws {
    let source = DiagnosticSessionUIFixture.job
    for deduplicated in [true, false] {
      var answers: [(String, RuntimeHistoryTransportResult)] = [
        ("target.list", try continuationResponse([["targetId": source.targetID, "bindingRevision": 3]])),
        ("job.show", .success(try currentJobDetailResponse(continuationSourceStatus()))),
        ("job.submit", try continuationResponse(["jobId": "job-new", "deduplicated": deduplicated])),
      ]
      if !deduplicated {
        answers.append(("job.run", try continuationResponse(["jobId": "job-new", "state": "waitingForRecovery"])))
        answers.append(("job.show", .success(try currentJobDetailResponse([
          "jobId": "job-new", "operation": source.operationReference, "targetId": source.targetID,
          "state": "waitingForRecovery", "outcomeUnknown": true,
        ]))))
      }
      let transport = OverviewRPCScenario(answers)
      let provider = RuntimeContinuationXPCProvider(
        reader: RuntimeJobDetailApplicationFacade.make(arguments: ["--ui-test-runtime-history"]),
        request: { await transport.request($0, $1) })
      let result = await provider.submit(try continuationDraft())
      if deduplicated {
        guard case .failure = result else {
          Issue.record("deduplicated Job became a new continuation")
          return
        }
      } else {
        #expect(try result.get() == "job-new")
      }
      for _ in 0..<2 {
        guard case .failure = await provider.run(jobID: "job-new") else {
          Issue.record("unknown result was retried")
          return
        }
      }
      let calls = await transport.recordedCalls()
      #expect(calls.filter { $0.0 == "job.run" }.count == (deduplicated ? 0 : 1))
    }
  }

  @Test func continuationDisconnectAfterRunAcknowledgementCannotReplay() async throws {
    let source = DiagnosticSessionUIFixture.job
    let transport = OverviewRPCScenario([
      ("target.list", try continuationResponse([["targetId": source.targetID, "bindingRevision": 3]])),
      ("job.show", .success(try currentJobDetailResponse(continuationSourceStatus()))),
      ("job.submit", try continuationResponse(["jobId": "job-new", "deduplicated": false])),
      ("job.run", try continuationResponse(["jobId": "job-new", "state": "succeeded"])),
      ("job.show", .failure("connection interrupted")),
    ])
    let provider = RuntimeContinuationXPCProvider(
      reader: RuntimeJobDetailApplicationFacade.make(arguments: ["--ui-test-runtime-history"]),
      request: { await transport.request($0, $1) })
    let accepted = await provider.submit(try continuationDraft())
    #expect(try accepted.get() == "job-new")
    for _ in 0..<2 {
      guard case .failure = await provider.run(jobID: "job-new") else {
        Issue.record("a run acknowledgement cannot prove terminal success after disconnect")
        return
      }
    }
    let calls = await transport.recordedCalls()
    #expect(calls.map(\.0) == ["target.list", "job.show", "job.submit", "job.run", "job.show"])
  }

  private func job(
    _ id: String,
    thread: String? = nil,
    target: String = "target-1",
    operation: String = "capture.diagnostics@1",
    state: String = "succeeded",
    effect: String? = "readOnly",
    outcomeUnknown: Bool = false,
    waitingForHuman: Bool = false,
    residue: Int = 0,
    finishedAt: String? = nil,
    supersededBy: String? = nil
  ) -> RuntimeJobSummaryPresentation {
    RuntimeJobSummaryPresentation(
      id: id,
      operationReference: operation,
      targetID: target,
      state: state,
      waitingForHuman: waitingForHuman,
      outcomeUnknown: outcomeUnknown,
      outstandingResidueCount: residue,
      timeline: [],
      threadID: thread,
      actualEffect: effect,
      createdAtUTC: finishedAt,
      startedAtUTC: finishedAt,
      finishedAtUTC: finishedAt,
      supersededByRecoveryEpochID: supersededBy)
  }

  private func stamp(_ minute: Int) -> String {
    String(format: "2026-08-25T10:%02d:00.000Z", minute)
  }

  // MARK: - Grouping

  /// The whole point of a line is that consecutive work reads as one thing and
  /// unrelated work does not.
  @Test func runsGroupByThreadAndUngroupedRunsStayOnTheirOwn() {
    let threads = OverviewRunRecordProjection.threads(
      from: [
        job("job-1", thread: "t-aaa", finishedAt: stamp(1)),
        job("job-2", thread: "t-aaa", finishedAt: stamp(3)),
        job("job-3", thread: "t-bbb", finishedAt: stamp(2)),
        job("job-4", thread: nil, finishedAt: stamp(4)),
        job("job-5", thread: nil, finishedAt: stamp(5)),
      ],
      limit: 10)

    #expect(threads.map(\.threadID) == [nil, nil, "t-aaa", "t-bbb"])
    #expect(
      threads.first(where: { $0.threadID == "t-aaa" })?.runs.map(\.id) == ["job-1", "job-2"],
      "runs inside a line read oldest first, the way the work happened")
    #expect(
      threads.filter { $0.threadID == nil }.map { $0.runs.map(\.id) } == [["job-5"], ["job-4"]],
      "two runs that recorded no thread are two lines, not one shared line")
  }

  /// A line that still needs a person is the reason to open the page, so it is
  /// pinned above more recent but settled work.
  @Test func aLineNeedingAPersonIsPinnedAboveMoreRecentSettledWork() {
    for needing in [
      job("job-old", thread: "t-old", outcomeUnknown: true, finishedAt: stamp(1)),
      job("job-old", thread: "t-old", waitingForHuman: true, finishedAt: stamp(1)),
      job("job-old", thread: "t-old", residue: 2, finishedAt: stamp(1)),
    ] {
      let threads = OverviewRunRecordProjection.threads(
        from: [needing, job("job-new", thread: "t-new", finishedAt: stamp(9))],
        limit: 10)
      #expect(threads.map(\.threadID) == ["t-old", "t-new"])
      #expect(threads.map(\.needsAttention) == [true, false])
    }
  }

  /// Runtime having established the current epoch settles a historical
  /// unknown: it stays in the record, but it stops paging the operator.
  @Test func aResolvedHistoricalUnknownStopsPinningTheLine() {
    let threads = OverviewRunRecordProjection.threads(
      from: [
        job(
          "job-old", thread: "t-old", outcomeUnknown: true, finishedAt: stamp(1),
          supersededBy: "epoch-1"),
        job("job-new", thread: "t-new", finishedAt: stamp(9)),
      ],
      limit: 10)
    #expect(threads.map(\.threadID) == ["t-new", "t-old"])
    #expect(threads.map(\.needsAttention) == [false, false])
  }

  /// Truncation is by whole lines. A line shown with some of its runs missing
  /// would misstate what happened.
  @Test func truncationDropsWholeLinesAndKeepsThePinnedOne() {
    let jobs = (1...6).flatMap { index in
      [
        job("job-\(index)-a", thread: "t-\(index)", finishedAt: stamp(index * 2)),
        job("job-\(index)-b", thread: "t-\(index)", finishedAt: stamp(index * 2 + 1)),
      ]
    } + [job("job-attention", thread: "t-att", outcomeUnknown: true, finishedAt: stamp(0))]

    let threads = OverviewRunRecordProjection.threads(from: jobs, limit: 3)
    #expect(threads.count == 3)
    #expect(threads.first?.threadID == "t-att")
    for thread in threads where thread.threadID != "t-att" {
      #expect(thread.runs.count == 2, "a truncated line would misstate the work")
    }
  }

  @Test func aLineReportsEveryOperationItRanInFirstSeenOrder() {
    let threads = OverviewRunRecordProjection.threads(
      from: [
        job("job-1", thread: "t-aaa", operation: "capture.diagnostics@1", finishedAt: stamp(1)),
        job("job-2", thread: "t-aaa", operation: "debug.hap@1", finishedAt: stamp(2)),
        job("job-3", thread: "t-aaa", operation: "capture.diagnostics@1", finishedAt: stamp(3)),
      ],
      limit: 10)
    #expect(
      threads.first?.operationReferences == ["capture.diagnostics@1", "debug.hap@1"])
  }

  @Test func overviewShowsOneFeaturedRunAndAtMostThreeMore() throws {
    let thread = try #require(
      OverviewRunRecordProjection.threads(
        from: (1...7).map {
          job("job-\($0)", thread: "t-aaa", finishedAt: stamp($0))
        },
        limit: 1
      ).first)
    let featured = try #require(OverviewRunRecordProjection.featuredRun(in: thread))
    #expect(featured.id == "job-7")
    #expect(
      OverviewRunRecordProjection.additionalRuns(in: thread, excluding: featured).map(\.id)
        == ["job-6", "job-5", "job-4"])
  }

  @Test func anUnresolvedRunRemainsFeaturedEvenWhenTheLineContinued() throws {
    let thread = try #require(
      OverviewRunRecordProjection.threads(
        from: [
          job(
            "job-attention", thread: "t-aaa", outcomeUnknown: true,
            finishedAt: stamp(1)),
          job("job-later", thread: "t-aaa", finishedAt: stamp(2)),
        ],
        limit: 1
      ).first)
    #expect(
      OverviewRunRecordProjection.featuredRun(in: thread)?.id == "job-attention")
  }

  // MARK: - Resuming

  /// Every refusal has to name itself. A page that greys a button without
  /// saying why is the same page that invites a support question.
  @Test func everyRefusalToRepeatARunNamesItself() {
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", state: "running"), parametersWereReported: true)
        == .notTerminal)
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: nil), parametersWereReported: true)
        == .effectUnknown)
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: "deviceMutation"), parametersWereReported: true)
        == .requiresAuthorization(effect: "deviceMutation"))
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: "destructive"), parametersWereReported: true)
        == .requiresAuthorization(effect: "destructive"))
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1"), parametersWereReported: false)
        == .parametersNotReported)
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1"), parametersWereReported: nil)
        == .detailNotLoaded,
      "an unread run must not be optimistically offered as repeatable")
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1"), parametersWereReported: true)
        == .resumable)
  }

  /// An unknown outcome is refused before the effect grade is even consulted:
  /// what the device received was never established, so no repeat and no claim
  /// about its grade would be truthful.
  @Test func anUnknownOutcomeIsNeverReplayedWhateverElseIsRecorded() {
    for effect in ["readOnly", "hostOnly", "deviceMutation", "destructive", nil] {
      #expect(
        OverviewRunRecordProjection.resumeDisposition(
          for: job(
            "job-1", state: "interrupted", effect: effect, outcomeUnknown: true),
          parametersWereReported: true)
          == .neverReplayed,
        "effect \(effect ?? "nil") must not buy a replay of an unknown outcome")
    }
  }

  /// Read-only is the only grade the page repeats on its own. Anything else
  /// goes back through the workspace's gate, so a new grade added upstream
  /// fails closed here instead of being silently repeatable.
  @Test func onlyNonMutatingGradesAreRepeatedWithoutTheWorkspaceGate() {
    #expect(OverviewRunRecordProjection.repeatableEffects == ["readOnly", "hostOnly"])
    #expect(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: "somethingNewUpstream"), parametersWereReported: true)
        == .requiresAuthorization(effect: "somethingNewUpstream"))
  }
}

/// What the Overview may conclude from a capability probe.
///
/// The failure this guards is the one the page exists to stop making: reading
/// "the probe did not answer" as "the device cannot do this".
struct OverviewActionProjectionContractTests {
  private func matrix(
    _ items: [(String, OverviewCapabilityState, String)],
    failure: String? = nil
  ) -> OverviewCapabilityMatrixPresentation {
    OverviewCapabilityMatrixPresentation(
      targetID: "target-1",
      bindingRevision: 4,
      items: items.map {
        OverviewCapabilityItemPresentation(id: $0.0, name: $0.0, state: $0.1, evidence: $0.2)
      },
      failure: failure)
  }

  @Test func aProbeThatDidNotAnswerIsNotProbedAndNeverUnavailable() {
    let actions = OverviewActionProjection.actions(
      from: matrix([
        ("hidumper", .unknown, "probeFailed"),
        ("hitrace", .available, "captureEligible · tags × 11"),
        ("rockusb-flash", .unavailable, "Runtime reported unavailable"),
      ]))
    let byKind = Dictionary(uniqueKeysWithValues: actions.map { ($0.kind, $0) })

    #expect(byKind[.uiDump]?.availability == .notProbed(reason: "probeFailed"))
    #expect(byKind[.trace]?.availability == .available)
    #expect(
      byKind[.flash]?.availability == .unavailable(reason: "Runtime reported unavailable"),
      "a stated unavailability is the one thing that may read as unavailable")
    #expect(byKind[.uiDump]?.availability.opensWorkspace == false)
    #expect(byKind[.trace]?.availability.opensWorkspace == true)
  }

  /// Capabilities nothing probes yet must say exactly that, rather than
  /// borrowing another row's verdict or disappearing from the row.
  @Test func capabilitiesWithNoPublishedProbeSaySoInsteadOfVanishing() {
    let actions = OverviewActionProjection.actions(from: matrix([]))
    #expect(actions.map(\.kind) == OverviewActionProjection.order)
    for action in actions {
      guard case .notProbed = action.availability else {
        Issue.record("\(action.kind) must read as not probed with an empty matrix")
        return
      }
    }
  }

  /// A matrix that failed wholesale hands its own reason to every entry rather
  /// than letting the page invent one.
  @Test func aFailedMatrixHandsItsOwnReasonToEveryEntry() {
    let actions = OverviewActionProjection.actions(
      from: matrix([], failure: "No adopted target is available"))
    for action in actions {
      #expect(
        action.availability == .notProbed(reason: "No adopted target is available"))
    }
  }

  /// The effect grade is a property of the operation, not of how the probe
  /// went, so it is stated whether or not the entry can be used.
  @Test func theEffectGradeIsStatedEvenWhenTheEntryCannotBeUsed() {
    let actions = OverviewActionProjection.actions(from: matrix([]))
    let grades = Dictionary(uniqueKeysWithValues: actions.map { ($0.kind, $0.effect) })
    #expect(grades[.uiDump] == "readOnly")
    #expect(grades[.trace] == "readOnly")
    #expect(grades[.debugHAP] == "deviceMutation")
    #expect(grades[.flash] == "destructive")
    #expect(
      Dictionary(uniqueKeysWithValues: actions.map { ($0.kind, $0.operationReference) })[.flash]
        == ArkForgeFlashOperation.canonicalReference)
    #expect(grades[.device] == "deviceMutation")
  }
}

/// Which workspace a finished run belongs to.
///
/// Viewer, Trace and the Device all submit `capture.diagnostics@1`. Opening
/// the wrong one would prefill a different request than the one being
/// repeated, so an unsettled case has to end in nil rather than a guess.
struct OverviewWorkspaceKindContractTests {
  private func parameters(_ pairs: [(String, String)]) -> [RuntimeJobParameterPresentation] {
    pairs.map { RuntimeJobParameterPresentation(name: $0.0, value: $0.1) }
  }

  @Test func anOperationWithOneOwnerResolvesFromTheReferenceAlone() {
    #expect(
      OverviewActionProjection.workspaceKind(forOperation: "debug.hap@1", parameters: [])
        == .debugHAP)
    for reference in [
      ArkForgeFlashOperation.canonicalReference,
      // A durable record written before the rename still resolves.
      "flash.dayu200@1",
    ] {
      #expect(
        OverviewActionProjection.workspaceKind(forOperation: reference, parameters: [])
          == .flash, "flash identity must go through the canonical policy: \(reference)")
    }
    for gesture in ["input.tap@1", "input.long-press@1", "input.swipe@1"] {
      #expect(
        OverviewActionProjection.workspaceKind(forOperation: gesture, parameters: []) == .device)
    }
  }

  @Test func aSharedOperationResolvesFromTheInputsItReported() {
    #expect(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("uiComponentTree", "true"), ("uiScreenshot", "true")]))
        == .uiDump)
    #expect(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("advancedDump", "true")]))
        == .uiDump)
    #expect(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("traceCategories", "ark · ui"), ("uiDump", "false")]))
        == .trace)
    #expect(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("uiScreenshot", "true"), ("durationSeconds", "1")]))
        == .device)
  }

  /// The important half: silence, not a guess.
  @Test func anUnsettledOrUnknownOperationResolvesToNothing() {
    #expect(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1", parameters: []) == nil,
      "reported nothing that identifies a workspace")
    #expect(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("traceCategories", "[]")])) == nil,
      "an empty category list does not make it a Trace capture")
    #expect(
      OverviewActionProjection.workspaceKind(
        forOperation: "observe.device@1", parameters: []) == nil,
      "no workspace submits this one")
  }
}

private actor OverviewRPCScenario {
  private var answers: [(String, RuntimeHistoryTransportResult)]
  private var calls: [(String, [String: JSONValue])] = []

  init(_ answers: [(String, RuntimeHistoryTransportResult)]) { self.answers = answers }

  func request(_ method: String, _ parameters: [String: JSONValue]) -> RuntimeHistoryTransportResult {
    calls.append((method, parameters))
    guard !answers.isEmpty, answers[0].0 == method else { return .failure("unexpected fixture RPC") }
    return answers.removeFirst().1
  }

  func recordedCalls() -> [(String, [String: JSONValue])] { calls }
}
