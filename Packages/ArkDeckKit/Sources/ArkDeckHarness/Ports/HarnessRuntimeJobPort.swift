// The harness's only door into execution (CHG-2026-054, TASK-HTP-001).
//
// The harness never dispatches anything itself: it submits a typed runtime
// operation request and then observes the job the engine owns. That is the
// whole port. Keeping it this narrow is what stops a control plane from
// growing a second execution path around the safety kernel - there is no
// method here that could carry an argv, a remote path or a device command.
//
// `startRun` deliberately does not await completion. The engine owns the
// job lifecycle and persists its own state; the harness looks again on the
// next wake. A coordinator that awaited a full run would hold its actor
// for the length of a device operation and make `task.status` block behind
// it.

import ArkDeckCore
import Foundation

public struct HarnessJobAcceptance: Equatable, Sendable {
  public let jobID: String
  /// True when the engine recognised the idempotency key and returned the
  /// existing job. Recovery depends on this: same key in, same job out,
  /// one side effect total.
  public let deduplicated: Bool

  public init(jobID: String, deduplicated: Bool) {
    self.jobID = jobID
    self.deduplicated = deduplicated
  }
}

public struct HarnessJobObservation: Equatable, Sendable {
  public let jobID: String
  public let state: String
  public let isTerminal: Bool
  public let succeeded: Bool
  public let outcomeUnknown: Bool
  public let waitingForHuman: Bool
  /// Runtime's admitted effect, carried only so the harness can distinguish
  /// a mechanically recoverable read from an unresolved mutation. A missing
  /// or unknown value stays fail-closed and is never auto-reconciled.
  public let actualEffect: WorkflowEffect?
  public let timeline: [String]

  public init(
    jobID: String,
    state: String,
    isTerminal: Bool,
    succeeded: Bool,
    outcomeUnknown: Bool,
    waitingForHuman: Bool,
    actualEffect: WorkflowEffect? = nil,
    timeline: [String]
  ) {
    self.jobID = jobID
    self.state = state
    self.isTerminal = isTerminal
    self.succeeded = succeeded
    self.outcomeUnknown = outcomeUnknown
    self.waitingForHuman = waitingForHuman
    self.actualEffect = actualEffect
    self.timeline = timeline
  }
}

public enum HarnessJobPortError: Error, Equatable, Sendable {
  case rejected(String)
  case unknownJob(String)
  case transportFailure(String)
}

public protocol HarnessRuntimeJobPort: Sendable {
  /// Submit a fully typed v2 request. The harness passes bytes it built
  /// from the decision and the durable intent; the engine remains the
  /// validator and the admission authority.
  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance
  /// Ask the engine to execute an accepted job. Returns as soon as
  /// execution has been handed over.
  func startRun(jobID: String) async throws
  func observe(jobID: String) async throws -> HarnessJobObservation
  /// Ask Runtime to settle an existing durable unknown intent. Runtime owns
  /// the exact typed action and may perform only its registered reconciliation
  /// readback; this surface cannot redispatch or replace the original action.
  func reconcile(jobID: String) async throws -> HarnessJobObservation
  /// Forward a cancel request to the engine. The engine decides where the
  /// safe boundary is; the harness only asks and then waits for a terminal
  /// observation.
  func requestCancel(jobID: String) async throws
}

public extension HarnessRuntimeJobPort {
  func reconcile(jobID: String) async throws -> HarnessJobObservation {
    throw HarnessJobPortError.rejected("job reconciliation is unavailable for \(jobID)")
  }
}
