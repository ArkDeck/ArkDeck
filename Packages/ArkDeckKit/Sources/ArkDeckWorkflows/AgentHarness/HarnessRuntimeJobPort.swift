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
  public let timeline: [String]

  public init(
    jobID: String,
    state: String,
    isTerminal: Bool,
    succeeded: Bool,
    outcomeUnknown: Bool,
    waitingForHuman: Bool,
    timeline: [String]
  ) {
    self.jobID = jobID
    self.state = state
    self.isTerminal = isTerminal
    self.succeeded = succeeded
    self.outcomeUnknown = outcomeUnknown
    self.waitingForHuman = waitingForHuman
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
  /// Forward a cancel request to the engine. The engine decides where the
  /// safe boundary is; the harness only asks and then waits for a terminal
  /// observation.
  func requestCancel(jobID: String) async throws
}

/// Production adapter over the existing engine.
public struct RuntimeJobEngineHarnessPort: HarnessRuntimeJobPort {
  private let engine: RuntimeJobEngine

  public init(engine: RuntimeJobEngine) {
    self.engine = engine
  }

  public func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    do {
      let acceptance = try await engine.submit(requestJSON)
      return HarnessJobAcceptance(
        jobID: acceptance.jobID, deduplicated: acceptance.deduplicated)
    } catch let error as RuntimeJobEngineError {
      throw HarnessJobPortError.rejected("\(error)")
    } catch {
      throw HarnessJobPortError.transportFailure("\(error)")
    }
  }

  public func startRun(jobID: String) async throws {
    let engine = self.engine
    // Detached on purpose: the engine, not the harness, owns how long a
    // job takes. A failure inside `run` is not lost - it lands in the
    // job's persisted state and the harness reads it on the next wake.
    Task.detached { _ = try? await engine.run(jobID: jobID) }
  }

  public func observe(jobID: String) async throws -> HarnessJobObservation {
    do {
      let status = try await engine.status(jobID: jobID)
      return Self.observation(from: status)
    } catch {
      throw HarnessJobPortError.unknownJob(jobID)
    }
  }

  public func requestCancel(jobID: String) async throws {
    do {
      try await engine.requestCancel(jobID: jobID)
    } catch {
      throw HarnessJobPortError.unknownJob(jobID)
    }
  }

  static func observation(from status: RuntimeJobStatus) -> HarnessJobObservation {
    let state = JobState(rawValue: status.state)
    return HarnessJobObservation(
      jobID: status.jobID,
      state: status.state,
      // An unrecognised state is treated as non-terminal: the harness
      // waits and looks again rather than deciding on a state it cannot
      // classify.
      isTerminal: state?.isTerminal ?? false,
      succeeded: state == .succeeded,
      outcomeUnknown: status.outcomeUnknown,
      waitingForHuman: status.waitingForHuman,
      timeline: status.timeline)
  }
}
