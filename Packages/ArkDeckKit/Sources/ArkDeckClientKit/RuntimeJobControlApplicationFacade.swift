import ArkDeckCore
import Foundation

public enum RuntimeJobCancellationResult: Sendable, Equatable {
  case requested
  case refused(String)
}

/// Cancellation is deliberately separate from History's read-only facade.
/// There is no arbitrary method, request submission, replay, rebind or
/// capability administration on this surface.
public protocol RuntimeJobControlApplicationProviding: Sendable {
  func cancel(_ job: RuntimeJobSummaryPresentation) async -> RuntimeJobCancellationResult
}

public enum RuntimeJobControlApplicationFacade {
  public static func make(arguments: [String] = ProcessInfo.processInfo.arguments)
    -> any RuntimeJobControlApplicationProviding
  {
    if arguments.contains("--ui-test-runtime-history") { return Fixture() }
    return RuntimeJobControlXPCProvider()
  }

  public static func canCancel(_ job: RuntimeJobSummaryPresentation) -> Bool {
    guard !job.outcomeUnknown, let state = JobState(rawValue: job.state) else { return false }
    return !state.isTerminal
  }

  private struct Fixture: RuntimeJobControlApplicationProviding {
    func cancel(_ job: RuntimeJobSummaryPresentation) async -> RuntimeJobCancellationResult {
      // An isolated UI fixture never connects to Runtime or changes a record.
      .refused("fixture_cancellation_not_dispatched")
    }
  }
}

actor RuntimeJobControlXPCProvider: RuntimeJobControlApplicationProviding {
  private let request: @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult

  init(request: @escaping @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult = {
    switch await RuntimeXPCRequestTransport.request(method: $0, params: $1) {
    case .success(let bytes): return .success(bytes)
    case .failure(let failure): return .failure(failure.message)
    }
  }) {
    self.request = request
  }

  func cancel(_ job: RuntimeJobSummaryPresentation) async -> RuntimeJobCancellationResult {
    guard RuntimeJobControlApplicationFacade.canCancel(job) else {
      return .refused("job_cancel_requires_known_active_job")
    }
    guard let status = await result("job.status", jobID: job.id),
      status["jobId"] as? String == job.id,
      status["operation"] as? String == job.operationReference,
      status["targetId"] as? String == job.targetID,
      status["sessionId"] as? String == job.sessionID,
      status["outcomeUnknown"] as? Bool == false,
      let rawState = status["state"] as? String,
      let state = JobState(rawValue: rawState), !state.isTerminal
    else { return .refused("job_cancel_fresh_status_unavailable_or_changed") }
    guard let result = await result("job.cancel", jobID: job.id),
      result["cancelRequested"] as? Bool == true
    else { return .refused("job_cancel_request_not_confirmed") }
    // Request accepted is not cancelled: the Runtime may still be reaching
    // a safe boundary. Only a later status observation may report terminal.
    return .requested
  }

  private func result(_ method: String, jobID: String) async -> [String: Any]? {
    guard case .success(let bytes) = await request(method, ["jobId": .string(jobID)]),
      let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      envelope["ok"] as? Bool == true,
      envelope["error"] == nil || envelope["error"] is NSNull
    else { return nil }
    return envelope["result"] as? [String: Any]
  }
}
