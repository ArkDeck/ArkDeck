public enum JobExecutionMode: String, CaseIterable, Codable, Sendable {
  case execute
  case planOnly
}

public enum JobState: String, CaseIterable, Codable, Sendable {
  case queued
  case preflight
  case running
  case waitingForDevice
  case awaitingRebindConfirmation
  case planning
  case cancelRequested
  case cancellingAtSafeBoundary
  case waitingForRecovery
  case reconciling
  case resumeAtConfirmedSafeBoundary
  case userAbandonRequested
  case finalizing
  case planned
  case succeeded
  case failed
  case cancelled
  case interrupted

  public var isTerminal: Bool {
    switch self {
    case .planned, .succeeded, .failed, .cancelled, .interrupted:
      true
    default:
      false
    }
  }
}

public enum WorkflowFailureClassification: String, CaseIterable, Codable, Sendable {
  case preflight
  case process
  case semantic
  case storage
  case cancellation
  case recovery
  case compensation
  case invariant
}

public struct WorkflowFailure: Error, Equatable, Sendable, Codable {
  public let classification: WorkflowFailureClassification
  public let code: String
  public let summary: String

  public init(classification: WorkflowFailureClassification, code: String, summary: String) {
    self.classification = classification
    self.code = code
    self.summary = summary
  }
}

public struct RecoveryResumeEvidence: Equatable, Sendable {
  public let restartSafe: Bool
  public let safeBoundaryConfirmed: Bool
  public let outcomeConfirmed: Bool
  public let bindingConfirmed: Bool

  public init(
    restartSafe: Bool,
    safeBoundaryConfirmed: Bool,
    outcomeConfirmed: Bool,
    bindingConfirmed: Bool
  ) {
    self.restartSafe = restartSafe
    self.safeBoundaryConfirmed = safeBoundaryConfirmed
    self.outcomeConfirmed = outcomeConfirmed
    self.bindingConfirmed = bindingConfirmed
  }

  public var permitsResume: Bool {
    restartSafe && safeBoundaryConfirmed && outcomeConfirmed && bindingConfirmed
  }
}

public enum RecoveryDecision: Equatable, Sendable {
  case resume(RecoveryResumeEvidence)
  case confirmedFailure(WorkflowFailure)
  case remainsUncertain
}

public enum LaunchRecoveryFinding: Equatable, Sendable {
  case requiresReconciliation
  case missingDestructiveOutcome
}

public enum JobEvent: Equatable, Sendable {
  case startPreflight
  case preflightPassed
  case waitForDevice
  case deviceAvailable
  case requireRebindConfirmation
  case rebindNotConfirmed
  case workflowCompleted
  case confirmedFailure(WorkflowFailure)
  case externalOutcomeOrIdentityUnknown
  case cancellationRequested(activeStepId: String?)
  case cancellationAcknowledged
  case safeBoundaryReached
  case recoveryRequested
  case recoveryEvaluated(RecoveryDecision)
  case resumeConfirmed
  case abandonmentRequested
  case abandonmentPersisted
  case abandonmentAuditFailed
  case finalizationCompleted
}

public enum JobStateMachineDirective: String, Hashable, Sendable {
  case persistStateTransition
  case persistCancellationRequest
  case persistCancellationOutcomeAndSafeBoundary
  case waitForProviderSafeBoundary
  case mustNotForceTerminateCurrentProcess
  case dispatchNoUnknownStep
  case preserveOutcomeUnknown
  case releaseResourcesAfterTerminalPersistence
}

public struct JobStateTransition: Equatable, Sendable {
  public let from: JobState
  public let to: JobState

  public init(from: JobState, to: JobState) {
    self.from = from
    self.to = to
  }
}

public struct JobStateMachineOutcome: Equatable, Sendable {
  public let transition: JobStateTransition
  public let directives: Set<JobStateMachineDirective>

  public init(transition: JobStateTransition, directives: Set<JobStateMachineDirective>) {
    self.transition = transition
    self.directives = directives
  }
}

public enum JobInvariantViolationKind: String, Codable, Sendable {
  case illegalTransition
  case terminalStepDispatch
  case planOnlyMutationDispatch
  case dispatchNotAllowedInState
  case activeStepAlreadyAuthorized
  case activeStepMismatch
  case activeStepStillRunning
  case invalidRecoverySource
}

public struct JobInvariantViolation: Equatable, Sendable {
  public let kind: JobInvariantViolationKind
  public let state: JobState
  public let attemptedState: JobState?
  public let detail: String

  public init(
    kind: JobInvariantViolationKind,
    state: JobState,
    attemptedState: JobState?,
    detail: String
  ) {
    self.kind = kind
    self.state = state
    self.attemptedState = attemptedState
    self.detail = detail
  }
}

public enum JobStateMachineError: Error, Equatable, Sendable {
  case invariantViolation(JobInvariantViolation)
}

public enum WorkflowStepDispatchAuthorization: Equatable, Sendable {
  case permitted
}

public struct AuthorizedWorkflowStep: Equatable, Sendable {
  public let id: String
  public let kind: WorkflowStepKind
  public let effect: WorkflowEffect
  public let cancellation: WorkflowCancellationPolicy

  fileprivate init(step: WorkflowStep) {
    self.id = step.id
    self.kind = step.kind
    self.effect = step.effect
    self.cancellation = step.cancellation
  }
}

public struct JobStateMachine: Sendable {
  public let mode: JobExecutionMode
  public private(set) var state: JobState
  public private(set) var invariantViolations: [JobInvariantViolation]
  public private(set) var originalFailure: WorkflowFailure?
  public private(set) var activeStep: AuthorizedWorkflowStep?

  private var pendingFinalization: PendingFinalization?

  public init(mode: JobExecutionMode) {
    self.mode = mode
    self.state = .queued
    self.invariantViolations = []
    self.originalFailure = nil
    self.activeStep = nil
    self.pendingFinalization = nil
  }

  public init(
    mode: JobExecutionMode,
    recoveringFrom previousState: JobState,
    finding: LaunchRecoveryFinding
  ) throws {
    guard !previousState.isTerminal else {
      let violation = JobInvariantViolation(
        kind: .invalidRecoverySource,
        state: previousState,
        attemptedState: nil,
        detail: "terminal jobs cannot enter launch recovery"
      )
      throw JobStateMachineError.invariantViolation(violation)
    }
    self.mode = mode
    self.state = finding == .missingDestructiveOutcome ? .waitingForRecovery : .reconciling
    self.invariantViolations = []
    self.originalFailure = nil
    self.activeStep = nil
    self.pendingFinalization = nil
  }

  @discardableResult
  public mutating func handle(_ event: JobEvent) throws -> JobStateMachineOutcome {
    switch event {
    case .startPreflight:
      return try transition(to: .preflight)
    case .preflightPassed:
      return try transition(to: mode == .execute ? .running : .planning)
    case .waitForDevice:
      return try transition(to: .waitingForDevice)
    case .deviceAvailable:
      return try transition(to: .running)
    case .requireRebindConfirmation:
      return try transition(to: .awaitingRebindConfirmation)
    case .rebindNotConfirmed:
      return try transition(to: .waitingForDevice)
    case .workflowCompleted:
      guard
        (mode == .execute && state == .running)
          || (mode == .planOnly && state == .planning)
      else {
        try rejectTransition(
          to: .finalizing,
          detail: "workflow completion is valid only from running or planning"
        )
      }
      if let activeStep {
        try rejectDispatch(
          kind: .activeStepStillRunning,
          detail: "workflow cannot complete while step \(activeStep.id) remains active"
        )
      }
      let outcome = try transition(to: .finalizing)
      pendingFinalization = .success
      return outcome
    case .confirmedFailure(let failure):
      let outcome = try transition(to: .finalizing)
      activeStep = nil
      originalFailure = failure
      pendingFinalization = .failure
      return outcome
    case .externalOutcomeOrIdentityUnknown:
      return try transition(
        to: .waitingForRecovery,
        additionalDirectives: [.dispatchNoUnknownStep, .preserveOutcomeUnknown]
      )
    case .cancellationRequested(let requestedStepId):
      let activeStepPolicy = try cancellationPolicy(for: requestedStepId)
      var directives: Set<JobStateMachineDirective> = [.persistCancellationRequest]
      if activeStepPolicy != .immediate {
        directives.insert(.waitForProviderSafeBoundary)
      }
      if activeStepPolicy == .criticalNonInterruptible {
        directives.insert(.mustNotForceTerminateCurrentProcess)
      }
      return try transition(to: .cancelRequested, additionalDirectives: directives)
    case .cancellationAcknowledged:
      return try transition(to: .cancellingAtSafeBoundary)
    case .safeBoundaryReached:
      return try transition(
        to: .cancelled,
        additionalDirectives: [.persistCancellationOutcomeAndSafeBoundary],
        completesActiveStepAtSafeBoundary: true
      )
    case .recoveryRequested:
      return try transition(to: .reconciling)
    case .recoveryEvaluated(let decision):
      switch decision {
      case .resume(let evidence) where evidence.permitsResume:
        let outcome = try transition(to: .resumeAtConfirmedSafeBoundary)
        activeStep = nil
        return outcome
      case .resume, .remainsUncertain:
        return try transition(
          to: .waitingForRecovery,
          additionalDirectives: [.dispatchNoUnknownStep, .preserveOutcomeUnknown]
        )
      case .confirmedFailure(let failure):
        let outcome = try transition(to: .finalizing)
        activeStep = nil
        originalFailure = failure
        pendingFinalization = .failure
        return outcome
      }
    case .resumeConfirmed:
      return try transition(to: mode == .execute ? .running : .planning)
    case .abandonmentRequested:
      return try transition(to: .userAbandonRequested)
    case .abandonmentPersisted:
      return try transition(
        to: .interrupted,
        additionalDirectives: [.releaseResourcesAfterTerminalPersistence]
      )
    case .abandonmentAuditFailed:
      return try transition(to: .waitingForRecovery)
    case .finalizationCompleted:
      guard let pendingFinalization else {
        try rejectTransition(
          to: mode == .execute ? .succeeded : .planned,
          detail: "finalization completion requires a recorded success or failure disposition"
        )
      }
      if let activeStep {
        try rejectDispatch(
          kind: .activeStepStillRunning,
          detail:
            "finalization cannot complete while step \(activeStep.id) remains active; complete the matching step first"
        )
      }
      switch (mode, pendingFinalization) {
      case (.execute, .success):
        return try transition(to: .succeeded)
      case (.planOnly, .success):
        return try transition(to: .planned)
      case (_, .failure):
        return try transition(to: .failed)
      }
    }
  }

  public mutating func authorizeDispatch(
    of step: WorkflowStep
  ) throws -> WorkflowStepDispatchAuthorization {
    if state.isTerminal {
      try rejectDispatch(
        kind: .terminalStepDispatch,
        detail: "terminal state \(state.rawValue) rejects workflow step \(step.id)"
      )
    }
    guard normalDispatchPhasePermits(step) else {
      try rejectDispatch(
        kind: .dispatchNotAllowedInState,
        detail: "\(mode.rawValue) state \(state.rawValue) rejects normal workflow step \(step.id)"
      )
    }
    if mode == .planOnly && step.effect >= .deviceMutation {
      try rejectDispatch(
        kind: .planOnlyMutationDispatch,
        detail: "plan-only job rejects \(step.effect.rawValue) step \(step.id)"
      )
    }
    if let activeStep {
      try rejectDispatch(
        kind: .activeStepAlreadyAuthorized,
        detail: "step \(activeStep.id) must finish before authorizing step \(step.id)"
      )
    }
    activeStep = AuthorizedWorkflowStep(step: step)
    return .permitted
  }

  public mutating func completeAuthorizedStep(id: String) throws {
    guard activeStep?.id == id else {
      try rejectDispatch(
        kind: .activeStepMismatch,
        detail: "step completion \(id) does not match active step \(activeStep?.id ?? "none")"
      )
    }
    activeStep = nil
  }

  private func normalDispatchPhasePermits(_ step: WorkflowStep) -> Bool {
    switch (mode, state) {
    case (.execute, .preflight):
      step.effect <= .readOnly
    case (.execute, .running), (.planOnly, .preflight), (.planOnly, .planning):
      true
    case (_, .finalizing):
      step.kind == .finalizeSession
    default:
      false
    }
  }

  private mutating func cancellationPolicy(for requestedStepId: String?) throws
    -> WorkflowCancellationPolicy
  {
    if let activeStep {
      guard requestedStepId == activeStep.id else {
        try rejectDispatch(
          kind: .activeStepMismatch,
          detail:
            "cancellation target \(requestedStepId ?? "none") does not match active step \(activeStep.id)"
        )
      }
      return activeStep.cancellation
    }
    if let requestedStepId {
      try rejectDispatch(
        kind: .activeStepMismatch,
        detail: "cancellation target \(requestedStepId) has no active authorized step"
      )
    }
    return .immediate
  }

  public static func isAllowedTransition(
    from: JobState,
    to: JobState,
    mode: JobExecutionMode
  ) -> Bool {
    allowedDestinations(from: from, mode: mode).contains(to)
  }

  public static func allowedDestinations(from state: JobState, mode: JobExecutionMode) -> Set<
    JobState
  > {
    switch (mode, state) {
    case (_, .queued):
      [.preflight, .cancelRequested, .finalizing]
    case (.execute, .preflight):
      [.running, .cancelRequested, .finalizing, .waitingForRecovery]
    case (.planOnly, .preflight):
      [.planning, .cancelRequested, .finalizing]
    case (.execute, .running):
      [.waitingForDevice, .cancelRequested, .finalizing, .waitingForRecovery]
    case (.execute, .waitingForDevice):
      [.running, .awaitingRebindConfirmation, .cancelRequested, .finalizing, .waitingForRecovery]
    case (.execute, .awaitingRebindConfirmation):
      [.waitingForDevice, .cancelRequested, .finalizing, .waitingForRecovery]
    case (.planOnly, .planning):
      [.cancelRequested, .finalizing]
    case (.execute, .cancelRequested):
      [.cancellingAtSafeBoundary, .finalizing, .waitingForRecovery]
    case (.planOnly, .cancelRequested):
      [.cancellingAtSafeBoundary]
    case (.execute, .cancellingAtSafeBoundary):
      [.cancelled, .finalizing, .waitingForRecovery]
    case (.planOnly, .cancellingAtSafeBoundary):
      [.cancelled]
    case (_, .waitingForRecovery):
      [.reconciling, .userAbandonRequested]
    case (_, .reconciling):
      [.resumeAtConfirmedSafeBoundary, .finalizing, .waitingForRecovery]
    case (.execute, .resumeAtConfirmedSafeBoundary):
      [.running]
    case (.planOnly, .resumeAtConfirmedSafeBoundary):
      [.planning]
    case (_, .userAbandonRequested):
      [.interrupted, .waitingForRecovery]
    case (.execute, .finalizing):
      [.succeeded, .failed]
    case (.planOnly, .finalizing):
      [.planned, .failed]
    case (_, .planned), (_, .succeeded), (_, .failed), (_, .cancelled), (_, .interrupted):
      []
    case (.planOnly, .running),
      (.planOnly, .waitingForDevice),
      (.planOnly, .awaitingRebindConfirmation),
      (.execute, .planning):
      []
    }
  }

  private mutating func transition(
    to newState: JobState,
    additionalDirectives: Set<JobStateMachineDirective> = [],
    completesActiveStepAtSafeBoundary: Bool = false
  ) throws -> JobStateMachineOutcome {
    guard Self.isAllowedTransition(from: state, to: newState, mode: mode) else {
      try rejectTransition(to: newState)
    }
    if newState.isTerminal && activeStep != nil && !completesActiveStepAtSafeBoundary {
      try rejectDispatch(
        kind: .activeStepStillRunning,
        detail: "terminal state \(newState.rawValue) requires the active step to be completed"
      )
    }
    let transition = JobStateTransition(from: state, to: newState)
    state = newState
    if completesActiveStepAtSafeBoundary {
      activeStep = nil
    }
    var directives = additionalDirectives
    directives.insert(.persistStateTransition)
    return JobStateMachineOutcome(transition: transition, directives: directives)
  }

  private mutating func rejectTransition(
    to newState: JobState,
    detail: String? = nil
  ) throws -> Never {
    let violation = JobInvariantViolation(
      kind: .illegalTransition,
      state: state,
      attemptedState: newState,
      detail: detail
        ?? "\(mode.rawValue) transition \(state.rawValue) -> \(newState.rawValue) is not in the Core graph"
    )
    invariantViolations.append(violation)
    throw JobStateMachineError.invariantViolation(violation)
  }

  private mutating func rejectDispatch(
    kind: JobInvariantViolationKind,
    detail: String
  ) throws -> Never {
    let violation = JobInvariantViolation(
      kind: kind,
      state: state,
      attemptedState: nil,
      detail: detail
    )
    invariantViolations.append(violation)
    throw JobStateMachineError.invariantViolation(violation)
  }

  private enum PendingFinalization: Sendable {
    case success
    case failure
  }
}

public enum CompensationTerminalPath: String, CaseIterable, Codable, Sendable {
  case success
  case failure
  case cancel
}

public struct CompletedStepCompensations: Equatable, Sendable {
  public let sourceStepId: String
  public let descriptors: [CompensationDescriptor]

  public init(sourceStepId: String, descriptors: [CompensationDescriptor]) {
    self.sourceStepId = sourceStepId
    self.descriptors = descriptors
  }
}

public struct PlannedCompensation: Equatable, Sendable {
  public let sourceStepId: String
  public let descriptor: CompensationDescriptor

  public init(sourceStepId: String, descriptor: CompensationDescriptor) {
    self.sourceStepId = sourceStepId
    self.descriptor = descriptor
  }
}

public enum CompensationPlanner {
  public static func plan(
    completedStepsInExecutionOrder: [CompletedStepCompensations],
    terminalPath: CompensationTerminalPath
  ) -> [PlannedCompensation] {
    completedStepsInExecutionOrder.reversed().flatMap { completedStep in
      completedStep.descriptors.reversed().compactMap { descriptor in
        guard applies(descriptor.trigger, to: terminalPath) else { return nil }
        return PlannedCompensation(
          sourceStepId: completedStep.sourceStepId,
          descriptor: descriptor
        )
      }
    }
  }

  private static func applies(
    _ trigger: CompensationTrigger,
    to terminalPath: CompensationTerminalPath
  ) -> Bool {
    switch (trigger, terminalPath) {
    case (.onAnyTerminal, _), (.onSuccess, .success), (.onFailure, .failure), (.onCancel, .cancel):
      true
    default:
      false
    }
  }
}

public enum CompensationOutcome: Equatable, Sendable {
  case succeeded
  case failed(WorkflowFailure)
}

public struct CompensationExecutionRecord: Equatable, Sendable {
  public let plannedCompensation: PlannedCompensation
  public let outcome: CompensationOutcome

  public init(plannedCompensation: PlannedCompensation, outcome: CompensationOutcome) {
    self.plannedCompensation = plannedCompensation
    self.outcome = outcome
  }
}

public struct JobFinalizationReport: Equatable, Sendable {
  public let originalFailure: WorkflowFailure?
  public let compensationRecords: [CompensationExecutionRecord]

  public init(
    originalFailure: WorkflowFailure?,
    compensationRecords: [CompensationExecutionRecord]
  ) {
    self.originalFailure = originalFailure
    self.compensationRecords = compensationRecords
  }

  public var compensationFailures: [WorkflowFailure] {
    compensationRecords.compactMap { record in
      guard case .failed(let failure) = record.outcome else { return nil }
      return failure
    }
  }

  public var needsAttention: Bool {
    !compensationFailures.isEmpty
  }
}
