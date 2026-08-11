// The thing that makes one submit converge (CHG-2026-054, TASK-HTP-006).
//
// Before this file the harness had every part of a bounded debug loop except
// something to turn the crank. `task.submit` persisted a task and returned;
// `task.reconcile` advanced it by one step. Measured on host: twenty seconds
// after a submit the task was still `created / initializing / round 0` with
// zero events. "One submit converges automatically" was therefore not true of
// the product - it was true of whoever kept typing `task reconcile`.
//
// Three properties are deliberate:
//
//   * it is on for every submitted task. The task's typed policy and budgets
//     are the authority boundary; asking an operator to turn the loop after
//     accepting that bounded submission creates an unrelated merge/run
//     boundary. An operator can still disable the scheduler explicitly for
//     maintenance, and model egress remains a separate project privacy
//     choice (TASK-HTP-004);
//   * one reconcile per drivable task per wake, never a loop-until-terminal
//     inner spin. The coordinator's "at most one effectful job per wake"
//     invariant (HTP-AC-1) stays the unit of progress, and one task cannot
//     starve another;
//   * `created`, `running` and non-user waiting tasks are driven. An active
//     Runtime Job and a temporarily unavailable device must be observed to
//     make progress. `humanRequired` and `waiting + USER_SUSPENDED` are not
//     drivable: a person must resolve either one.
//
// It adds no authority. Every step still goes through the coordinator, which
// still goes through the policy guard and the engine; the ticker cannot widen
// an effect, mint a capability or judge a criterion.

import ArkDeckCore
import Foundation

/// What the ticker needs from the control plane. Narrow on purpose: it can
/// ask which tasks are drivable and it can ask for one step. It has no way
/// to submit, cancel or resolve anything.
public protocol HarnessAutoDriveTarget: Sendable {
  func drivableTaskIDs() async throws -> [String]
  func reconcile(_ htaskID: String) async throws -> HarnessReconcileOutcome
}

extension HarnessTaskCoordinator: HarnessAutoDriveTarget {
  /// Freshly derived every wake: a task that reached a terminal state, was
  /// paused, or is waiting on a person drops out without the ticker keeping
  /// any state of its own.
  public func drivableTaskIDs() async throws -> [String] {
    try await list()
      .filter {
        $0.lifecycle == .created || $0.lifecycle == .running
          || ($0.lifecycle == .waiting && $0.waitReason != .userSuspended)
      }
      .map(\.htaskID)
  }
}

public struct HarnessAutoDriveReport: Equatable, Sendable {
  public let wakes: Int
  public let reconciles: Int
  public let dispatchedJobIDs: [String]
  /// Tasks whose scheduler call crossed the repeated-failure alert threshold
  /// and had not recovered by the end of this run. They are never dropped:
  /// the task's own durable budgets and terminal state remain the stop rule.
  public let degradedTaskIDs: [String]

  public init(
    wakes: Int, reconciles: Int, dispatchedJobIDs: [String], degradedTaskIDs: [String]
  ) {
    self.wakes = wakes
    self.reconciles = reconciles
    self.dispatchedJobIDs = dispatchedJobIDs
    self.degradedTaskIDs = degradedTaskIDs
  }
}

public struct HarnessAutoDriveTicker: Sendable {
  /// Optional environment override. A missing value uses the product default;
  /// `off` or `0` explicitly disables scheduling for maintenance. Malformed
  /// values fail closed instead of silently selecting another cadence.
  public static let intervalEnvironmentKey = "ARKDECK_HARNESS_AUTODRIVE_SECONDS"
  public static let defaultIntervalSeconds = 1
  public static let minimumIntervalSeconds = 1
  public static let maximumIntervalSeconds = 3600
  /// Consecutive throwing reconciles before the scheduler emits a degraded
  /// alert. It keeps driving: an in-memory scheduler exception is not a new
  /// authority boundary and cannot replace the task's durable budgets.
  public static let maximumConsecutiveFailures = 3

  private let target: any HarnessAutoDriveTarget
  private let intervalSeconds: Int
  private let sleep: @Sendable (Int) async throws -> Void
  private let log: @Sendable (String) -> Void

  public init(
    target: any HarnessAutoDriveTarget,
    intervalSeconds: Int,
    sleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
      try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    },
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.target = target
    self.intervalSeconds = intervalSeconds
    self.sleep = sleep
    self.log = log
  }

  /// Effective interval, or `nil` only when explicitly disabled or malformed.
  /// Out-of-range values are off rather than clamped: a run that asked for a
  /// cadence the product will not honour should say so, not silently get one.
  public static func configuredIntervalSeconds(
    _ environment: [String: String]
  ) -> Int? {
    guard let configured = environment[intervalEnvironmentKey] else {
      return defaultIntervalSeconds
    }
    let raw = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw == "0" || raw.caseInsensitiveCompare("off") == .orderedSame {
      return nil
    }
    guard !raw.isEmpty,
      let seconds = Int(raw),
      seconds >= minimumIntervalSeconds,
      seconds <= maximumIntervalSeconds
    else { return nil }
    return seconds
  }

  /// Runs until cancelled, or until `maximumWakes` wakes have happened.
  /// `maximumWakes` exists for tests and for a bounded window run; the daemon
  /// passes `nil` and cancels the surrounding task on shutdown.
  @discardableResult
  public func run(maximumWakes: Int? = nil) async -> HarnessAutoDriveReport {
    var wakes = 0
    var reconciles = 0
    var dispatched: [String] = []
    var failures: [String: Int] = [:]
    var degraded: Set<String> = []

    while !Task.isCancelled, maximumWakes.map({ wakes < $0 }) ?? true {
      wakes += 1
      let drivable: [String]
      do {
        drivable = try await target.drivableTaskIDs()
      } catch {
        // Listing failed: the store is unreadable this instant. Waiting is
        // the only safe move - inventing a task list would be worse.
        log("harness auto-drive could not list tasks: \(error)")
        if (try? await sleep(intervalSeconds)) == nil { break }
        continue
      }
      for htaskID in drivable {
        if Task.isCancelled { break }
        do {
          let outcome = try await target.reconcile(htaskID)
          reconciles += 1
          failures[htaskID] = 0
          degraded.remove(htaskID)
          if let jobID = outcome.dispatchedJobID {
            dispatched.append(jobID)
            log(
              "harness auto-drive \(htaskID): dispatched \(jobID) "
                + "(\(outcome.reasonCode))")
          } else if outcome.snapshot.lifecycle.isTerminal {
            log(
              "harness auto-drive \(htaskID): \(outcome.snapshot.lifecycle.rawValue) "
                + "(\(outcome.reasonCode))")
          }
        } catch {
          let count = (failures[htaskID] ?? 0) + 1
          failures[htaskID] = count
          log("harness auto-drive \(htaskID) failed (\(count)): \(error)")
          if count == Self.maximumConsecutiveFailures {
            degraded.insert(htaskID)
            log(
              "harness auto-drive marked \(htaskID) degraded after "
                + "\(count) consecutive failures; continuing within task budgets")
          }
        }
      }
      if Task.isCancelled { break }
      if (try? await sleep(intervalSeconds)) == nil { break }
    }
    return HarnessAutoDriveReport(
      wakes: wakes, reconciles: reconciles, dispatchedJobIDs: dispatched,
      degradedTaskIDs: degraded.sorted())
  }
}
