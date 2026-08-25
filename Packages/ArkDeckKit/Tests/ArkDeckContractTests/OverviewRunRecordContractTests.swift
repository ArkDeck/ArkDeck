// What the Overview may conclude from a run record.
//
// Two judgements carry the page: which runs were one piece of work, and
// whether a finished run may be offered as "run it again". The dangerous
// failure is not an ugly list — it is an enabled button that promises a repeat
// the Runtime would refuse, or two unrelated runs presented as one line the
// operator can continue.

import ArkDeckCore
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class OverviewRunRecordContractTests: XCTestCase {
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
  func testRunsGroupByThreadAndUngroupedRunsStayOnTheirOwn() {
    let threads = OverviewRunRecordProjection.threads(
      from: [
        job("job-1", thread: "t-aaa", finishedAt: stamp(1)),
        job("job-2", thread: "t-aaa", finishedAt: stamp(3)),
        job("job-3", thread: "t-bbb", finishedAt: stamp(2)),
        job("job-4", thread: nil, finishedAt: stamp(4)),
        job("job-5", thread: nil, finishedAt: stamp(5)),
      ],
      limit: 10)

    XCTAssertEqual(threads.map(\.threadID), [nil, nil, "t-aaa", "t-bbb"])
    XCTAssertEqual(
      threads.first(where: { $0.threadID == "t-aaa" })?.runs.map(\.id), ["job-1", "job-2"],
      "runs inside a line read oldest first, the way the work happened")
    XCTAssertEqual(
      threads.filter { $0.threadID == nil }.map { $0.runs.map(\.id) }, [["job-5"], ["job-4"]],
      "two runs that recorded no thread are two lines, not one shared line")
  }

  /// A line that still needs a person is the reason to open the page, so it is
  /// pinned above more recent but settled work.
  func testALineNeedingAPersonIsPinnedAboveMoreRecentSettledWork() {
    for needing in [
      job("job-old", thread: "t-old", outcomeUnknown: true, finishedAt: stamp(1)),
      job("job-old", thread: "t-old", waitingForHuman: true, finishedAt: stamp(1)),
      job("job-old", thread: "t-old", residue: 2, finishedAt: stamp(1)),
    ] {
      let threads = OverviewRunRecordProjection.threads(
        from: [needing, job("job-new", thread: "t-new", finishedAt: stamp(9))],
        limit: 10)
      XCTAssertEqual(threads.map(\.threadID), ["t-old", "t-new"])
      XCTAssertEqual(threads.map(\.needsAttention), [true, false])
    }
  }

  /// Runtime having established the current epoch settles a historical
  /// unknown: it stays in the record, but it stops paging the operator.
  func testAResolvedHistoricalUnknownStopsPinningTheLine() {
    let threads = OverviewRunRecordProjection.threads(
      from: [
        job(
          "job-old", thread: "t-old", outcomeUnknown: true, finishedAt: stamp(1),
          supersededBy: "epoch-1"),
        job("job-new", thread: "t-new", finishedAt: stamp(9)),
      ],
      limit: 10)
    XCTAssertEqual(threads.map(\.threadID), ["t-new", "t-old"])
    XCTAssertEqual(threads.map(\.needsAttention), [false, false])
  }

  /// Truncation is by whole lines. A line shown with some of its runs missing
  /// would misstate what happened.
  func testTruncationDropsWholeLinesAndKeepsThePinnedOne() {
    let jobs = (1...6).flatMap { index in
      [
        job("job-\(index)-a", thread: "t-\(index)", finishedAt: stamp(index * 2)),
        job("job-\(index)-b", thread: "t-\(index)", finishedAt: stamp(index * 2 + 1)),
      ]
    } + [job("job-attention", thread: "t-att", outcomeUnknown: true, finishedAt: stamp(0))]

    let threads = OverviewRunRecordProjection.threads(from: jobs, limit: 3)
    XCTAssertEqual(threads.count, 3)
    XCTAssertEqual(threads.first?.threadID, "t-att")
    for thread in threads where thread.threadID != "t-att" {
      XCTAssertEqual(thread.runs.count, 2, "a truncated line would misstate the work")
    }
  }

  func testALineReportsEveryOperationItRanInFirstSeenOrder() {
    let threads = OverviewRunRecordProjection.threads(
      from: [
        job("job-1", thread: "t-aaa", operation: "capture.diagnostics@1", finishedAt: stamp(1)),
        job("job-2", thread: "t-aaa", operation: "debug.hap@1", finishedAt: stamp(2)),
        job("job-3", thread: "t-aaa", operation: "capture.diagnostics@1", finishedAt: stamp(3)),
      ],
      limit: 10)
    XCTAssertEqual(
      threads.first?.operationReferences, ["capture.diagnostics@1", "debug.hap@1"])
  }

  // MARK: - Resuming

  /// Every refusal has to name itself. A page that greys a button without
  /// saying why is the same page that invites a support question.
  func testEveryRefusalToRepeatARunNamesItself() {
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", state: "running"), parametersWereReported: true),
      .notTerminal)
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: nil), parametersWereReported: true),
      .effectUnknown)
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: "deviceMutation"), parametersWereReported: true),
      .requiresAuthorization(effect: "deviceMutation"))
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: "destructive"), parametersWereReported: true),
      .requiresAuthorization(effect: "destructive"))
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1"), parametersWereReported: false),
      .parametersNotReported)
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1"), parametersWereReported: nil),
      .detailNotLoaded,
      "an unread run must not be optimistically offered as repeatable")
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1"), parametersWereReported: true),
      .resumable)
  }

  /// An unknown outcome is refused before the effect grade is even consulted:
  /// what the device received was never established, so no repeat and no claim
  /// about its grade would be truthful.
  func testAnUnknownOutcomeIsNeverReplayedWhateverElseIsRecorded() {
    for effect in ["readOnly", "hostOnly", "deviceMutation", "destructive", nil] {
      XCTAssertEqual(
        OverviewRunRecordProjection.resumeDisposition(
          for: job(
            "job-1", state: "interrupted", effect: effect, outcomeUnknown: true),
          parametersWereReported: true),
        .neverReplayed,
        "effect \(effect ?? "nil") must not buy a replay of an unknown outcome")
    }
  }

  /// Read-only is the only grade the page repeats on its own. Anything else
  /// goes back through the workspace's gate, so a new grade added upstream
  /// fails closed here instead of being silently repeatable.
  func testOnlyNonMutatingGradesAreRepeatedWithoutTheWorkspaceGate() {
    XCTAssertEqual(OverviewRunRecordProjection.repeatableEffects, ["readOnly", "hostOnly"])
    XCTAssertEqual(
      OverviewRunRecordProjection.resumeDisposition(
        for: job("job-1", effect: "somethingNewUpstream"), parametersWereReported: true),
      .requiresAuthorization(effect: "somethingNewUpstream"))
  }
}

/// What the Overview may conclude from a capability probe.
///
/// The failure this guards is the one the page exists to stop making: reading
/// "the probe did not answer" as "the device cannot do this".
final class OverviewActionProjectionContractTests: XCTestCase {
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

  func testAProbeThatDidNotAnswerIsNotProbedAndNeverUnavailable() {
    let actions = OverviewActionProjection.actions(
      from: matrix([
        ("hidumper", .unknown, "probeFailed"),
        ("hitrace", .available, "captureEligible · tags × 11"),
        ("rockusb-flash", .unavailable, "Runtime reported unavailable"),
      ]))
    let byKind = Dictionary(uniqueKeysWithValues: actions.map { ($0.kind, $0) })

    XCTAssertEqual(byKind[.uiDump]?.availability, .notProbed(reason: "probeFailed"))
    XCTAssertEqual(byKind[.trace]?.availability, .available)
    XCTAssertEqual(
      byKind[.flash]?.availability, .unavailable(reason: "Runtime reported unavailable"),
      "a stated unavailability is the one thing that may read as unavailable")
    XCTAssertEqual(byKind[.uiDump]?.availability.opensWorkspace, false)
    XCTAssertEqual(byKind[.trace]?.availability.opensWorkspace, true)
  }

  /// Capabilities nothing probes yet must say exactly that, rather than
  /// borrowing another row's verdict or disappearing from the row.
  func testCapabilitiesWithNoPublishedProbeSaySoInsteadOfVanishing() {
    let actions = OverviewActionProjection.actions(from: matrix([]))
    XCTAssertEqual(actions.map(\.kind), OverviewActionProjection.order)
    for action in actions {
      guard case .notProbed = action.availability else {
        return XCTFail("\(action.kind) must read as not probed with an empty matrix")
      }
    }
  }

  /// A matrix that failed wholesale hands its own reason to every entry rather
  /// than letting the page invent one.
  func testAFailedMatrixHandsItsOwnReasonToEveryEntry() {
    let actions = OverviewActionProjection.actions(
      from: matrix([], failure: "No adopted target is available"))
    for action in actions {
      XCTAssertEqual(
        action.availability, .notProbed(reason: "No adopted target is available"))
    }
  }

  /// The effect grade is a property of the operation, not of how the probe
  /// went, so it is stated whether or not the entry can be used.
  func testTheEffectGradeIsStatedEvenWhenTheEntryCannotBeUsed() {
    let actions = OverviewActionProjection.actions(from: matrix([]))
    let grades = Dictionary(uniqueKeysWithValues: actions.map { ($0.kind, $0.effect) })
    XCTAssertEqual(grades[.uiDump], "readOnly")
    XCTAssertEqual(grades[.trace], "readOnly")
    XCTAssertEqual(grades[.debugHAP], "deviceMutation")
    XCTAssertEqual(grades[.flash], "destructive")
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: actions.map { ($0.kind, $0.operationReference) })[.flash],
      ArkForgeFlashOperation.canonicalReference)
    XCTAssertEqual(grades[.toolkit], "deviceMutation")
  }
}

/// Which workspace a finished run belongs to.
///
/// Viewer, Trace and the Toolkit all submit `capture.diagnostics@1`. Opening
/// the wrong one would prefill a different request than the one being
/// repeated, so an unsettled case has to end in nil rather than a guess.
final class OverviewWorkspaceKindContractTests: XCTestCase {
  private func parameters(_ pairs: [(String, String)]) -> [RuntimeJobParameterPresentation] {
    pairs.map { RuntimeJobParameterPresentation(name: $0.0, value: $0.1) }
  }

  func testAnOperationWithOneOwnerResolvesFromTheReferenceAlone() {
    XCTAssertEqual(
      OverviewActionProjection.workspaceKind(forOperation: "debug.hap@1", parameters: []),
      .debugHAP)
    for reference in [
      ArkForgeFlashOperation.canonicalReference,
      // A durable record written before the rename still resolves.
      "flash.dayu200@1",
    ] {
      XCTAssertEqual(
        OverviewActionProjection.workspaceKind(forOperation: reference, parameters: []),
        .flash, "flash identity must go through the canonical policy: \(reference)")
    }
    for gesture in ["input.tap@1", "input.long-press@1", "input.swipe@1"] {
      XCTAssertEqual(
        OverviewActionProjection.workspaceKind(forOperation: gesture, parameters: []), .toolkit)
    }
  }

  func testASharedOperationResolvesFromTheInputsItReported() {
    XCTAssertEqual(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("uiComponentTree", "true"), ("uiScreenshot", "true")])),
      .uiDump)
    XCTAssertEqual(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("advancedDump", "true")])),
      .uiDump)
    XCTAssertEqual(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("traceCategories", "ark · ui"), ("uiDump", "false")])),
      .trace)
    XCTAssertEqual(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("uiScreenshot", "true"), ("durationSeconds", "1")])),
      .toolkit)
  }

  /// The important half: silence, not a guess.
  func testAnUnsettledOrUnknownOperationResolvesToNothing() {
    XCTAssertNil(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1", parameters: []),
      "reported nothing that identifies a workspace")
    XCTAssertNil(
      OverviewActionProjection.workspaceKind(
        forOperation: "capture.diagnostics@1",
        parameters: parameters([("traceCategories", "[]")])),
      "an empty category list does not make it a Trace capture")
    XCTAssertNil(
      OverviewActionProjection.workspaceKind(
        forOperation: "observe.device@1", parameters: []),
      "no workspace submits this one")
  }
}
