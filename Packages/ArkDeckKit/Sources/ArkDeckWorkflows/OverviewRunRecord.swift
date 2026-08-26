// The Overview's run record: what ran, and what can be continued.
//
// Kept out of the view so the two judgements that matter are testable on their
// own: which runs belong to one line of work, and whether a finished run may
// be offered as "run it again". Both are conservative by construction — an
// unknown outcome, an unrecorded effect grade or unreported inputs each end in
// a refusal that names itself, never in a silently enabled button.

import ArkDeckCore
import Foundation

/// One line of work: the runs a workspace filed under the same thread, oldest
/// first. A run that recorded no thread is its own single-run line rather than
/// being folded in with unrelated work.
public struct OverviewRunThread: Identifiable, Sendable, Equatable {
  public let id: String
  /// Nil for a run recorded before workspaces declared a thread. The UI must
  /// show these as ungrouped rather than inventing a line for them.
  public let threadID: String?
  public let targetID: String
  /// Every distinct operation this line ran, in first-seen order. A line is
  /// usually one operation, but nothing guarantees it.
  public let operationReferences: [String]
  public let runs: [RuntimeJobSummaryPresentation]
  /// Some run on this line still needs a person: an unknown outcome, a wait on
  /// a human, or outstanding device residue.
  public let needsAttention: Bool
  public let firstActivityUTC: String?
  public let lastActivityUTC: String?

  var sortKey: Date? { runs.compactMap(\.activityDate).max() }
}

/// Whether a finished run may be offered as "run it again", and when not, why.
public enum OverviewRunResumeDisposition: Sendable, Equatable {
  /// Terminal, read-only, and its typed inputs were reported: the workspace
  /// can be opened with exactly those parameters.
  case resumable
  /// Terminal, but its effect grade means continuing re-enters the workspace's
  /// own authorization gate instead of repeating a prefilled request.
  case requiresAuthorization(effect: String)
  /// The external effect is unknown. ArkDeck never replays an unknown intent;
  /// the only path forward is the recovery flow.
  case neverReplayed
  /// Still running. There is no finished run to repeat yet.
  case notTerminal
  /// Runtime recorded no effect grade for this run, so nothing about repeating
  /// it can be promised.
  case effectUnknown
  /// The run did not report its typed inputs, so "the same parameters" cannot
  /// be offered without inventing them.
  case parametersNotReported
  /// The run's evidence has not been read yet.
  case detailNotLoaded

  public var isResumable: Bool { self == .resumable }
}

public enum OverviewRunRecordProjection {
  /// Effect grades a workspace may repeat without re-entering an authorization
  /// gate. Anything outside this set is graded up, never down.
  static let repeatableEffects: Set<String> = ["readOnly", "hostOnly"]

  /// Groups runs into lines, most recently active first, with lines that need
  /// a person pinned above the rest.
  ///
  /// `limit` bounds what the Overview shows; the full archive stays in
  /// History. Truncation is by whole lines so a line is never shown with some
  /// of its runs missing.
  public static func threads(
    from jobs: [RuntimeJobSummaryPresentation],
    limit: Int = 4
  ) -> [OverviewRunThread] {
    var order: [String] = []
    var grouped: [String: [RuntimeJobSummaryPresentation]] = [:]
    for job in jobs {
      let key = job.threadID.map { "thread:\($0)" } ?? "run:\(job.id)"
      if grouped[key] == nil {
        grouped[key] = []
        order.append(key)
      }
      grouped[key]?.append(job)
    }

    let threads: [OverviewRunThread] = order.compactMap { key in
      guard let members = grouped[key], let first = members.first else { return nil }
      let runs = members.sorted { left, right in
        switch (left.activityDate, right.activityDate) {
        case (let l?, let r?) where l != r: return l < r
        default: return false
        }
      }
      var references: [String] = []
      for run in runs where !references.contains(run.operationReference) {
        references.append(run.operationReference)
      }
      let stamps = runs.compactMap { $0.createdAtUTC ?? $0.startedAtUTC ?? $0.finishedAtUTC }
      return OverviewRunThread(
        id: key,
        threadID: first.threadID,
        targetID: first.targetID,
        operationReferences: references,
        runs: runs,
        needsAttention: runs.contains {
          $0.needsAttention || $0.outstandingResidueCount > 0
        },
        firstActivityUTC: stamps.first,
        lastActivityUTC: runs.compactMap(\.finishedAtUTC).last ?? stamps.last)
    }

    let ranked = threads.enumerated().sorted { left, right in
      if left.element.needsAttention != right.element.needsAttention {
        return left.element.needsAttention
      }
      switch (left.element.sortKey, right.element.sortKey) {
      case (let l?, let r?) where l != r: return l > r
      case (nil, _?): return false
      case (_?, nil): return true
      default: return left.offset < right.offset
      }
    }.map(\.element)

    return limit >= 0 ? Array(ranked.prefix(limit)) : ranked
  }

  /// The one run Overview shows without another click. A still-unresolved run
  /// takes precedence over the latest settled run; otherwise this is simply
  /// the most recent run in the line.
  public static func featuredRun(
    in thread: OverviewRunThread
  ) -> RuntimeJobSummaryPresentation? {
    thread.runs.reversed().first(where: {
      $0.needsAttention || $0.outstandingResidueCount > 0
    }) ?? thread.runs.last
  }

  /// Bounded context revealed by the line's disclosure, newest first. History
  /// owns everything older than this window.
  public static func additionalRuns(
    in thread: OverviewRunThread,
    excluding featured: RuntimeJobSummaryPresentation,
    limit: Int = 3
  ) -> [RuntimeJobSummaryPresentation] {
    guard limit > 0 else { return [] }
    return Array(
      thread.runs.filter { $0.id != featured.id }.suffix(limit).reversed())
  }

  /// Whether this run may be offered as "run it again".
  ///
  /// `parametersWereReported` is nil until the run's evidence has been read;
  /// the answer is then `detailNotLoaded` rather than an optimistic yes.
  public static func resumeDisposition(
    for job: RuntimeJobSummaryPresentation,
    parametersWereReported: Bool?
  ) -> OverviewRunResumeDisposition {
    // An unknown outcome is refused before anything else is considered. What
    // the device actually received is not established, so neither a repeat nor
    // a claim about the effect grade would be truthful.
    if job.outcomeUnknown, !job.hasEstablishedCurrentEpoch { return .neverReplayed }
    guard let state = JobState(rawValue: job.state), state.isTerminal else {
      return .notTerminal
    }
    guard let effect = job.actualEffect, !effect.isEmpty else { return .effectUnknown }
    guard repeatableEffects.contains(effect) else {
      return .requiresAuthorization(effect: effect)
    }
    guard let parametersWereReported else { return .detailNotLoaded }
    guard parametersWereReported else { return .parametersNotReported }
    return .resumable
  }
}
