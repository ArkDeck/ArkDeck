import ArkDeckCore
import Foundation

public enum RuntimeJobRecoveryAction: Sendable, Equatable {
  case reconcile
  case resumeSafeBoundary
  case rebindLoader
}

public enum RuntimeJobRecoveryResult: Sendable, Equatable {
  /// A Runtime observation, never a claim that an unknown original effect was replayed.
  case observed(state: String, outcomeUnknown: Bool)
  case rebound(bindingRevision: Int)
  case refused(String)
  /// The request may have reached Runtime. Refresh its record; never resend automatically.
  case unconfirmed
}

public protocol RuntimeJobRecoveryApplicationProviding: Sendable {
  func perform(_ action: RuntimeJobRecoveryAction, for job: RuntimeJobSummaryPresentation)
    async -> RuntimeJobRecoveryResult
}

public enum RuntimeJobRecoveryApplicationFacade {
  public static func make(arguments: [String] = ProcessInfo.processInfo.arguments)
    -> any RuntimeJobRecoveryApplicationProviding
  {
    if arguments.contains("--ui-test-runtime-history") { return Fixture() }
    return RuntimeJobRecoveryXPCProvider()
  }

  public static func action(for job: RuntimeJobSummaryPresentation) -> RuntimeJobRecoveryAction? {
    guard !job.hasEstablishedCurrentEpoch else { return nil }
    if job.state == "waitingForRecovery" { return .reconcile }
    if job.state == "resumeAtConfirmedSafeBoundary", !job.outcomeUnknown, !job.waitingForHuman {
      return .resumeSafeBoundary
    }
    return nil
  }

  public static func canRebindLoader(_ job: RuntimeJobSummaryPresentation) -> Bool {
    job.operationReference == "flash.full-restore@1" && job.state == "waitingForRecovery"
      && !job.hasEstablishedCurrentEpoch
  }

  private struct Fixture: RuntimeJobRecoveryApplicationProviding {
    func perform(_ action: RuntimeJobRecoveryAction, for job: RuntimeJobSummaryPresentation)
      async -> RuntimeJobRecoveryResult
    {
      .refused("fixture_recovery_not_dispatched")
    }
  }
}

actor RuntimeJobRecoveryXPCProvider: RuntimeJobRecoveryApplicationProviding {
  private let request: @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult
  private let loaderWorkspace: @Sendable () async -> FlashWorkspacePresentation
  private let bindLoader: @Sendable (FlashTargetPresentation) async -> FlashLoaderBindingResult
  private var inFlight = Set<String>()

  init(request: @escaping @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult = {
    switch await RuntimeXPCRequestTransport.request(method: $0, params: $1) {
    case .success(let bytes): return .success(bytes)
    case .failure(let failure): return .failure(failure.message)
    }
  }, loaderWorkspace: @escaping @Sendable () async -> FlashWorkspacePresentation = {
    await FlashApplicationFacade.make().refreshWorkspace()
  }, bindLoader: @escaping @Sendable (FlashTargetPresentation) async -> FlashLoaderBindingResult = {
    await FlashApplicationFacade.make().bindCurrentLoader(target: $0)
  }) {
    self.request = request
    self.loaderWorkspace = loaderWorkspace
    self.bindLoader = bindLoader
  }

  func perform(_ action: RuntimeJobRecoveryAction, for job: RuntimeJobSummaryPresentation)
    async -> RuntimeJobRecoveryResult
  {
    let eligible = action == .rebindLoader
      ? RuntimeJobRecoveryApplicationFacade.canRebindLoader(job)
      : RuntimeJobRecoveryApplicationFacade.action(for: job) == action
    guard eligible,
      inFlight.insert(job.id).inserted else { return .refused("job_recovery_action_unavailable") }
    defer { inFlight.remove(job.id) }
    guard let fresh = try? await RuntimeAppReadResources.statusPresentation(jobID: job.id, send: { [request] method, params in
      switch await request(method, params) {
      case .success(let bytes): return bytes
      case .failure(let reason): throw AgentExecutionControlFailure("runtimeUnavailable", reason)
      }
    }), matches(fresh, job), fresh["state"] as? String == job.state,
      fresh["outcomeUnknown"] as? Bool == job.outcomeUnknown,
      fresh["supersededByRecoveryEpochId"] == nil || fresh["supersededByRecoveryEpochId"] is NSNull,
      fresh["resolvedByTargetAliasResolutionId"] == nil || fresh["resolvedByTargetAliasResolutionId"] is NSNull
    else { return .refused("job_recovery_fresh_status_unavailable_or_changed") }
    if action == .resumeSafeBoundary, fresh["waitingForHuman"] as? Bool != false {
      return .refused("job_recovery_safe_boundary_changed")
    }
    if action == .rebindLoader {
      let workspace = await loaderWorkspace()
      let matching = workspace.targets.filter { $0.id == job.targetID }
      guard workspace.targetLoadFailure == nil, matching.count == 1,
        let target = matching.first else { return .refused("job_recovery_exact_loader_target_unavailable") }
      // Runtime proves this target's Loader identity and pending Job association. This
      // request never submits a new Flash, resumes a Job, or clears an unknown outcome.
      switch await bindLoader(target) {
      case .bound(let bound):
        guard bound.id == target.id,
          bound.bindingRevision == target.bindingRevision || bound.bindingRevision == target.bindingRevision + 1
        else { return .unconfirmed }
        return .rebound(bindingRevision: bound.bindingRevision)
      case .failed: return .unconfirmed
      }
    }
    let method = action == .reconcile ? "job.reconcile" : "job.run"
    guard case .success(let bytes) = await request(method, ["jobId": .string(job.id)]),
      let value = try? RuntimeAppReadResources.result(bytes),
      let data = try? CanonicalJSONEncoders.canonical().encode(value),
      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      matches(result, job), let state = result["state"] as? String,
      JobState(rawValue: state) != nil, let unknown = result["outcomeUnknown"] as? Bool
    else { return .unconfirmed }
    return .observed(state: state, outcomeUnknown: unknown)
  }

  private func matches(_ status: [String: Any], _ job: RuntimeJobSummaryPresentation) -> Bool {
    status["jobId"] as? String == job.id
      && status["operation"] as? String == job.operationReference
      && status["targetId"] as? String == job.targetID
      && status["sessionId"] as? String == job.sessionID
      && job.sessionID != nil
  }
}
