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
//   * it is off unless an operator turns it on. A daemon that dispatches
//     device operations on a timer is a different safety posture from one
//     that answers requests, so auto-drive is opt-in per run, exactly like
//     model egress (TASK-HTP-004);
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
        $0.status == .created || $0.status == .running
          || ($0.status == .waiting && $0.waitReason != .userSuspended)
      }
      .map(\.htaskID)
  }
}

public struct HarnessAutoDriveReport: Equatable, Sendable {
  public let wakes: Int
  public let reconciles: Int
  public let dispatchedJobIDs: [String]
  /// Tasks dropped because reconcile kept throwing. Recorded rather than
  /// retried forever: a task whose every step fails is a defect to look at,
  /// not a thing to spin on.
  public let abandonedTaskIDs: [String]

  public init(
    wakes: Int, reconciles: Int, dispatchedJobIDs: [String], abandonedTaskIDs: [String]
  ) {
    self.wakes = wakes
    self.reconciles = reconciles
    self.dispatchedJobIDs = dispatchedJobIDs
    self.abandonedTaskIDs = abandonedTaskIDs
  }
}

public struct HarnessAutoDriveTicker: Sendable {
  /// Environment variable an operator sets to turn auto-drive on, in whole
  /// seconds. Absent, unparsable or out of range means off - the daemon keeps
  /// its request/response behaviour and nothing is dispatched on a timer.
  public static let intervalEnvironmentKey = "ARKDECK_HARNESS_AUTODRIVE_SECONDS"
  public static let minimumIntervalSeconds = 1
  public static let maximumIntervalSeconds = 3600
  /// Consecutive throwing reconciles before a task is dropped from the
  /// driven set. Three, matching the harness's three-strike stance for
  /// repeated identical failures (TASK-HTP-003).
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

  /// Interval an operator configured, or `nil` for off. Out-of-range values
  /// are off rather than clamped: a run that asked for a cadence the product
  /// will not honour should say so, not silently get another one.
  public static func configuredIntervalSeconds(
    _ environment: [String: String]
  ) -> Int? {
    guard let raw = environment[intervalEnvironmentKey]?.trimmingCharacters(in: .whitespaces),
      !raw.isEmpty,
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
    var abandoned: Set<String> = []

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
      for htaskID in drivable where !abandoned.contains(htaskID) {
        if Task.isCancelled { break }
        do {
          let outcome = try await target.reconcile(htaskID)
          reconciles += 1
          failures[htaskID] = 0
          if let jobID = outcome.dispatchedJobID {
            dispatched.append(jobID)
            log(
              "harness auto-drive \(htaskID): dispatched \(jobID) "
                + "(\(outcome.reasonCode))")
          } else if outcome.snapshot.status.isTerminal {
            log(
              "harness auto-drive \(htaskID): \(outcome.snapshot.status.rawValue) "
                + "(\(outcome.reasonCode))")
          }
        } catch {
          let count = (failures[htaskID] ?? 0) + 1
          failures[htaskID] = count
          log("harness auto-drive \(htaskID) failed (\(count)): \(error)")
          if count >= Self.maximumConsecutiveFailures {
            abandoned.insert(htaskID)
            log(
              "harness auto-drive stopped driving \(htaskID) after "
                + "\(count) consecutive failures")
          }
        }
      }
      if Task.isCancelled { break }
      if (try? await sleep(intervalSeconds)) == nil { break }
    }
    return HarnessAutoDriveReport(
      wakes: wakes, reconciles: reconciles, dispatchedJobIDs: dispatched,
      abandonedTaskIDs: abandoned.sorted())
  }
}
