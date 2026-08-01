// Production RuntimeJobEngine adapter for ArkDeckHarness.

import ArkDeckCore
import ArkDeckHarness
import Foundation

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
