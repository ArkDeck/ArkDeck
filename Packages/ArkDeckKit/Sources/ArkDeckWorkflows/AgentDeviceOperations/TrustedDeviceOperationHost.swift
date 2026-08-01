import ArkDeckCore
import ArkDeckHarness
import ArkDeckStorage
import CryptoKit
import Foundation

package struct AgentOperationDescriptor: Equatable, Sendable {
  package let operationID: AgentDeviceOperationID
  package let profileID: String
  package let configurationID: String
  package let configurationSHA256: String
  package let minimumEffect: WorkflowEffect
  package let permittedEffects: Set<WorkflowEffect>
  package let minimumCancellation: WorkflowCancellationPolicy
  package let bindingRequirement: WorkflowBindingRequirement
  package let permittedStepKinds: Set<WorkflowStepKind>
  package let emittedStepKinds: [WorkflowStepKind]
  package let declaredEffect: WorkflowEffect
  package let declaredCancellation: WorkflowCancellationPolicy
  package let declaredBindingRequirement: WorkflowBindingRequirement

  package init(
    operationID: AgentDeviceOperationID,
    profileID: String,
    configurationID: String,
    configurationSHA256: String,
    minimumEffect: WorkflowEffect,
    permittedEffects: Set<WorkflowEffect>,
    minimumCancellation: WorkflowCancellationPolicy,
    bindingRequirement: WorkflowBindingRequirement,
    permittedStepKinds: Set<WorkflowStepKind>,
    emittedStepKinds: [WorkflowStepKind],
    declaredEffect: WorkflowEffect,
    declaredCancellation: WorkflowCancellationPolicy,
    declaredBindingRequirement: WorkflowBindingRequirement
  ) {
    self.operationID = operationID
    self.profileID = profileID
    self.configurationID = configurationID
    self.configurationSHA256 = configurationSHA256
    self.minimumEffect = minimumEffect
    self.permittedEffects = permittedEffects
    self.minimumCancellation = minimumCancellation
    self.bindingRequirement = bindingRequirement
    self.permittedStepKinds = permittedStepKinds
    self.emittedStepKinds = emittedStepKinds
    self.declaredEffect = declaredEffect
    self.declaredCancellation = declaredCancellation
    self.declaredBindingRequirement = declaredBindingRequirement
  }
}

package struct AgentDeviceOperationPlan: Equatable, Sendable {
  package let steps: [WorkflowStep]

  package init(steps: [WorkflowStep]) {
    self.steps = steps
  }
}

package struct AgentTrustedFactReceipt: Equatable, Sendable {
  package let durableTargetID: String
  package let bindingRevision: Int
  package let bindingDigestSHA256: String
  package let targetDigestSHA256: String
  package let observationReceiptID: String
  package let freshUntilUTC: String

  package init(
    durableTargetID: String,
    bindingRevision: Int,
    bindingDigestSHA256: String,
    targetDigestSHA256: String,
    observationReceiptID: String,
    freshUntilUTC: String
  ) {
    self.durableTargetID = durableTargetID
    self.bindingRevision = bindingRevision
    self.bindingDigestSHA256 = bindingDigestSHA256
    self.targetDigestSHA256 = targetDigestSHA256
    self.observationReceiptID = observationReceiptID
    self.freshUntilUTC = freshUntilUTC
  }
}

package struct AgentResolvedExecutionAuthority: Equatable, Sendable {
  package let reference: AgentExecutionAuthorityReference
  package let usageReservationID: String?
  package let validUntilUTC: String

  package init(
    reference: AgentExecutionAuthorityReference,
    usageReservationID: String?,
    validUntilUTC: String
  ) {
    self.reference = reference
    self.usageReservationID = usageReservationID
    self.validUntilUTC = validUntilUTC
  }
}

package struct AgentTypedDispatchOutcome: Equatable, Sendable {
  package let succeeded: Bool
  package let outcomeCertainty: AgentDeviceOperationOutcomeCertainty
  package let artifacts: [AgentDeviceOperationArtifactReference]

  package init(
    succeeded: Bool,
    outcomeCertainty: AgentDeviceOperationOutcomeCertainty,
    artifacts: [AgentDeviceOperationArtifactReference] = []
  ) {
    self.succeeded = succeeded
    self.outcomeCertainty = outcomeCertainty
    self.artifacts = artifacts
  }
}

package struct AgentDurableJobContext: Equatable, Sendable {
  package let requestID: String
  package let jobID: String
  package let sessionID: String
  package let effect: WorkflowEffect
  package let planDigestSHA256: String
  package let facts: AgentTrustedFactReceipt
  package let authority: AgentResolvedExecutionAuthority
}

package enum AgentTrustedFactResolution: Sendable {
  case accepted(AgentTrustedFactReceipt)
  case humanActionRequired(HumanActionRequired)
  case policyBlocked(code: String)
}

package protocol AgentOperationRegistryResolving: Sendable {
  func resolve(
    operation: AgentDeviceOperationSelector
  ) async throws -> AgentOperationDescriptor?
}

package protocol AgentOperationPlanning: Sendable {
  func plan(
    request: AgentDeviceOperationRequest,
    descriptor: AgentOperationDescriptor
  ) async throws -> AgentDeviceOperationPlan
}

package protocol AgentTrustedFactsResolving: Sendable {
  func resolveFacts(
    request: AgentDeviceOperationRequest,
    descriptor: AgentOperationDescriptor,
    plan: AgentDeviceOperationPlan,
    jobID: String
  ) async throws -> AgentTrustedFactResolution
}

package protocol AgentExecutionAuthorityResolving: Sendable {
  func resolveAuthority(
    request: AgentDeviceOperationRequest,
    descriptor: AgentOperationDescriptor,
    facts: AgentTrustedFactReceipt,
    jobID: String,
    sessionID: String,
    planDigestSHA256: String,
    resolvedEffect: WorkflowEffect
  ) async throws -> AgentResolvedExecutionAuthority
}

package protocol AgentDurableAdmissionPersisting: Sendable {
  func claim(
    request: AgentDeviceOperationRequest,
    jobID: String,
    sessionID: String,
    facts: AgentTrustedFactReceipt
  ) async throws
  func appendJobCreated(_ context: AgentDurableJobContext) async throws
  func appendIntent(
    context: AgentDurableJobContext,
    step: WorkflowStep,
    attempt: Int
  ) async throws -> String
  func appendOutcome(
    context: AgentDurableJobContext,
    step: WorkflowStep,
    attempt: Int,
    intentEventID: String,
    outcome: AgentTypedDispatchOutcome
  ) async throws
  func storeHumanAction(_ action: HumanActionRequired) async throws
  func finalize(
    context: AgentDurableJobContext,
    state: JobState,
    artifacts: [AgentDeviceOperationArtifactReference]
  ) async throws -> String
}

package protocol AgentTypedOperationDispatching: Sendable {
  func dispatch(
    step: WorkflowStep,
    context: AgentDurableJobContext
  ) async throws -> AgentTypedDispatchOutcome
}

package protocol AgentHostIdentityProviding: Sendable {
  func nextJobAndSessionID(requestID: String) async -> (jobID: String, sessionID: String)
  func currentUTC() async -> String
}

public actor TrustedDeviceOperationHost {
  private let executor: AgentDeviceOperationExecutor
  private let registry: any AgentOperationRegistryResolving
  private let planner: any AgentOperationPlanning
  private let factsResolver: any AgentTrustedFactsResolving
  private let authorityResolver: any AgentExecutionAuthorityResolving
  private let durableStore: any AgentDurableAdmissionPersisting
  private let dispatcher: any AgentTypedOperationDispatching
  private let identity: any AgentHostIdentityProviding

  package init(
    executorID: String,
    registry: any AgentOperationRegistryResolving,
    planner: any AgentOperationPlanning,
    factsResolver: any AgentTrustedFactsResolving,
    authorityResolver: any AgentExecutionAuthorityResolving,
    durableStore: any AgentDurableAdmissionPersisting,
    dispatcher: any AgentTypedOperationDispatching,
    identity: any AgentHostIdentityProviding
  ) {
    executor = AgentDeviceOperationExecutor(id: executorID)
    self.registry = registry
    self.planner = planner
    self.factsResolver = factsResolver
    self.authorityResolver = authorityResolver
    self.durableStore = durableStore
    self.dispatcher = dispatcher
    self.identity = identity
  }

  public func submit(
    _ requestData: Data
  ) async -> Result<AgentDeviceOperationResult, AgentDeviceOperationSubmissionError> {
    let request: AgentDeviceOperationRequest
    do {
      request = try AgentDeviceOperationCodec.decodeRequest(requestData)
    } catch let error as AgentDeviceOperationSubmissionError {
      return .failure(error)
    } catch {
      return .failure(.malformed("$"))
    }

    let identifiers = await identity.nextJobAndSessionID(requestID: request.requestID)
    do {
      if let deadlineUTC = request.deadlineUTC,
        AgentDocumentValidation.date(await identity.currentUTC())
          > AgentDocumentValidation.date(deadlineUTC)
      {
        return .success(
          try policyBlockedResult(
            request: request, jobID: identifiers.jobID, effect: .destructive,
            code: "policy.requestDeadlineExpired"))
      }
      guard let descriptor = try await registry.resolve(operation: request.operation),
        descriptorMatchesRequest(descriptor, request.operation)
      else {
        return .success(
          try policyBlockedResult(
            request: request, jobID: identifiers.jobID, effect: .destructive,
            code: "policy.operationOrProfileUnsupported"))
      }
      let plan = try await planner.plan(request: request, descriptor: descriptor)
      let validation:
        (
          effect: WorkflowEffect,
          cancellation: WorkflowCancellationPolicy,
          binding: WorkflowBindingRequirement
        )
      do {
        validation = try validatePlan(plan, against: descriptor)
      } catch {
        return .success(
          try policyBlockedResult(
            request: request, jobID: identifiers.jobID, effect: .destructive,
            code: "policy.planDoesNotMatchRegistry"))
      }
      guard authoritySelectorIsValid(request: request, effect: validation.effect) else {
        return .success(
          try policyBlockedResult(
            request: request, jobID: identifiers.jobID, effect: validation.effect,
            code: "policy.authoritySelectorMismatch"))
      }

      if request.executionMode != .execute {
        return .success(
          try AgentDeviceOperationResult(
            requestID: request.requestID, jobID: identifiers.jobID,
            executionMode: request.executionMode, jobState: .planned, disposition: .terminal,
            resolvedEffect: validation.effect, outcomeCertainty: .notApplicable,
            executor: executor))
      }

      let factResolution = try await factsResolver.resolveFacts(
        request: request, descriptor: descriptor, plan: plan, jobID: identifiers.jobID)
      let facts: AgentTrustedFactReceipt
      switch factResolution {
      case .accepted(let acceptedFacts):
        guard acceptedFacts.durableTargetID == request.durableTargetID,
          acceptedFacts.bindingRevision > 0,
          factsAreFreshAndCanonical(
            acceptedFacts, currentUTC: await identity.currentUTC())
        else {
          return .success(
            try policyBlockedResult(
              request: request, jobID: identifiers.jobID, effect: validation.effect,
              code: "policy.trustedFactDrift"))
        }
        facts = acceptedFacts
      case .humanActionRequired(let action):
        let currentUTC = await identity.currentUTC()
        let actionIsUnexpired =
          action.expiresAtUTC.map {
            AgentDocumentValidation.date(currentUTC) < AgentDocumentValidation.date($0)
          } ?? true
        guard action.jobID == identifiers.jobID, action.status == .waiting,
          action.resolution == nil,
          AgentDocumentValidation.date(action.generatedAtUTC)
            <= AgentDocumentValidation.date(currentUTC),
          actionIsUnexpired
        else {
          return .failure(
            AgentDeviceOperationSubmissionError(
              code: .trustedServiceUnavailable, fieldPath: "$"))
        }
        try await durableStore.storeHumanAction(action)
        return .success(
          try humanActionResult(
            request: request, jobID: identifiers.jobID, effect: validation.effect,
            action: action))
      case .policyBlocked(let code):
        return .success(
          try policyBlockedResult(
            request: request, jobID: identifiers.jobID, effect: validation.effect, code: code))
      }

      try await durableStore.claim(
        request: request, jobID: identifiers.jobID, sessionID: identifiers.sessionID,
        facts: facts)
      let planDigest = try digest(plan.steps)
      let authority = try await authorityResolver.resolveAuthority(
        request: request, descriptor: descriptor, facts: facts,
        jobID: identifiers.jobID, sessionID: identifiers.sessionID,
        planDigestSHA256: planDigest, resolvedEffect: validation.effect)
      guard authority.reference.effect == validation.effect,
        AgentDocumentValidation.date(await identity.currentUTC())
          <= AgentDocumentValidation.date(authority.validUntilUTC),
        authorityMatchesRequest(
          authority, request: request, jobID: identifiers.jobID,
          planDigestSHA256: planDigest,
          targetDigestSHA256: facts.targetDigestSHA256)
      else {
        return .success(
          try policyBlockedResult(
            request: request, jobID: identifiers.jobID, effect: validation.effect,
            code: "policy.authorityKindMismatch"))
      }
      let context = AgentDurableJobContext(
        requestID: request.requestID, jobID: identifiers.jobID,
        sessionID: identifiers.sessionID, effect: validation.effect,
        planDigestSHA256: planDigest, facts: facts, authority: authority)
      try await durableStore.appendJobCreated(context)

      let permit = AgentExecutionPermit(
        requestID: request.requestID, jobID: identifiers.jobID,
        sessionID: identifiers.sessionID, planDigestSHA256: planDigest,
        durableTargetID: facts.durableTargetID, bindingRevision: facts.bindingRevision,
        bindingDigestSHA256: facts.bindingDigestSHA256,
        factFreshUntilUTC: facts.freshUntilUTC,
        authority: authority)

      var artifacts: [AgentDeviceOperationArtifactReference] = []
      var terminalSucceeded = true
      var permitConsumed = false
      for (offset, step) in plan.steps.enumerated() {
        if step.effect == .hostOnly {
          let outcome = try await dispatcher.dispatch(step: step, context: context)
          artifacts.append(contentsOf: outcome.artifacts)
          terminalSucceeded = terminalSucceeded && outcome.succeeded
          continue
        }
        if !permitConsumed {
          try permit.consume(
            requestID: request.requestID, jobID: identifiers.jobID,
            sessionID: identifiers.sessionID, planDigestSHA256: planDigest,
            durableTargetID: facts.durableTargetID, bindingRevision: facts.bindingRevision,
            bindingDigestSHA256: facts.bindingDigestSHA256,
            currentUTC: await identity.currentUTC())
          permitConsumed = true
        }
        let intentEventID = try await durableStore.appendIntent(
          context: context, step: step, attempt: offset + 1)
        let outcome: AgentTypedDispatchOutcome
        do {
          outcome = try await dispatcher.dispatch(step: step, context: context)
        } catch {
          let unknown = AgentTypedDispatchOutcome(
            succeeded: false, outcomeCertainty: .unknown)
          try await durableStore.appendOutcome(
            context: context, step: step, attempt: offset + 1,
            intentEventID: intentEventID, outcome: unknown)
          let action = try HumanActionRequired(
            actionID: "human-\(identifiers.jobID)", jobID: identifiers.jobID,
            stepID: step.id, category: .outcomeUnknownDecision,
            generatedAtUTC: await identity.currentUTC())
          try await durableStore.storeHumanAction(action)
          return .success(
            try humanActionResult(
              request: request, jobID: identifiers.jobID, effect: validation.effect,
              action: action, authority: authority.reference, state: .waitingForRecovery))
        }
        try await durableStore.appendOutcome(
          context: context, step: step, attempt: offset + 1,
          intentEventID: intentEventID, outcome: outcome)
        artifacts.append(contentsOf: outcome.artifacts)
        terminalSucceeded =
          terminalSucceeded && outcome.succeeded
          && outcome.outcomeCertainty == .confirmed
      }

      let state: JobState = terminalSucceeded ? .succeeded : .failed
      let manifestID = try await durableStore.finalize(
        context: context, state: state, artifacts: artifacts)
      return .success(
        try AgentDeviceOperationResult(
          requestID: request.requestID, jobID: identifiers.jobID,
          executionMode: request.executionMode, jobState: state, disposition: .terminal,
          resolvedEffect: validation.effect, outcomeCertainty: .confirmed,
          executor: executor, manifestID: manifestID,
          authorizationReference: authority.reference, artifacts: artifacts))
    } catch let error as AgentDeviceOperationSubmissionError {
      return .failure(error)
    } catch {
      return .failure(
        AgentDeviceOperationSubmissionError(
          code: .durableAdmissionFailed, fieldPath: "$"))
    }
  }

  private func descriptorMatchesRequest(
    _ descriptor: AgentOperationDescriptor,
    _ operation: AgentDeviceOperationSelector
  ) -> Bool {
    descriptor.operationID == operation.id
      && descriptor.profileID == operation.profileID
      && descriptor.configurationID == operation.configurationID
      && descriptor.configurationSHA256 == operation.configurationSHA256
  }

  private func validatePlan(
    _ plan: AgentDeviceOperationPlan,
    against descriptor: AgentOperationDescriptor
  ) throws -> (
    effect: WorkflowEffect,
    cancellation: WorkflowCancellationPolicy,
    binding: WorkflowBindingRequirement
  ) {
    guard !plan.steps.isEmpty,
      Set(plan.steps.map(\.id)).count == plan.steps.count,
      plan.steps.contains(where: { $0.effect >= .readOnly }),
      plan.steps.map(\.kind) == descriptor.emittedStepKinds,
      descriptor.permittedEffects.contains(descriptor.declaredEffect),
      descriptor.declaredCancellation >= descriptor.minimumCancellation,
      descriptor.declaredBindingRequirement >= descriptor.bindingRequirement
    else { throw AgentDeviceOperationSubmissionError.malformed("$.operation") }
    for step in plan.steps {
      guard descriptor.permittedStepKinds.contains(step.kind) else {
        throw AgentDeviceOperationSubmissionError.malformed("$.operation")
      }
    }
    let effect = plan.steps.reduce(
      max(descriptor.minimumEffect, descriptor.declaredEffect)
    ) { max($0, $1.effect) }
    let cancellation = plan.steps.reduce(
      max(descriptor.minimumCancellation, descriptor.declaredCancellation)
    ) { max($0, $1.cancellation) }
    let binding = plan.steps.reduce(
      max(descriptor.bindingRequirement, descriptor.declaredBindingRequirement)
    ) { max($0, $1.bindingRequirement) }
    guard descriptor.permittedEffects.contains(effect) else {
      throw AgentDeviceOperationSubmissionError.malformed("$.operation")
    }
    return (effect, cancellation, binding)
  }

  private func authoritySelectorIsValid(
    request: AgentDeviceOperationRequest,
    effect: WorkflowEffect
  ) -> Bool {
    switch effect {
    case .hostOnly, .readOnly, .deviceMutation:
      request.authorizationID == nil
    case .destructive:
      request.authorizationID != nil
    }
  }

  private func factsAreFreshAndCanonical(
    _ facts: AgentTrustedFactReceipt,
    currentUTC: String
  ) -> Bool {
    do {
      try AgentDocumentValidation.sha256(
        facts.bindingDigestSHA256, path: "$.trusted.bindingDigest")
      try AgentDocumentValidation.sha256(
        facts.targetDigestSHA256, path: "$.trusted.targetDigest")
      try AgentDocumentValidation.identifier(
        facts.observationReceiptID, path: "$.trusted.observationReceiptId")
      try AgentDocumentValidation.timestamp(
        facts.freshUntilUTC, path: "$.trusted.freshUntilUtc")
      try AgentDocumentValidation.timestamp(currentUTC, path: "$.trusted.currentUtc")
      return AgentDocumentValidation.date(currentUTC)
        <= AgentDocumentValidation.date(facts.freshUntilUTC)
    } catch {
      return false
    }
  }

  private func authorityMatchesRequest(
    _ authority: AgentResolvedExecutionAuthority,
    request: AgentDeviceOperationRequest,
    jobID: String,
    planDigestSHA256: String,
    targetDigestSHA256: String
  ) -> Bool {
    switch authority.reference.kind {
    case .readyTask:
      guard authority.usageReservationID == nil,
        case .readyTask(let changeID, let taskID, _, _, _) = authority.reference
      else { return false }
      return changeID == request.changeID && taskID == request.taskID
    case .deviceCapability:
      guard let usageReservationID = authority.usageReservationID,
        request.authorizationID == nil,
        let expected = try? AgentAuthorityUsageReservation.canonicalReservationID(
          authorizationRef: authority.reference, jobID: jobID,
          operationDigestSHA256: planDigestSHA256,
          targetDigestSHA256: targetDigestSHA256)
      else { return false }
      return usageReservationID == expected
    case .standingAuthorization:
      return authority.usageReservationID != nil
        && request.authorizationID == authority.reference.sourceIdentifier
    case .chatConfirmation:
      // Chat E2 is invocation-scoped to the Rockchip Flash product host and is never reusable by
      // the generic Agent Device Operation plane.
      return false
    }
  }

  private func digest(_ steps: [WorkflowStep]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(steps)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func policyBlockedResult(
    request: AgentDeviceOperationRequest,
    jobID: String,
    effect: WorkflowEffect,
    code: String
  ) throws -> AgentDeviceOperationResult {
    try AgentDeviceOperationResult(
      requestID: request.requestID, jobID: jobID, executionMode: request.executionMode,
      jobState: .queued, disposition: .policyBlocked, resolvedEffect: effect,
      outcomeCertainty: .notApplicable, executor: executor, blockerCode: nil)
  }

  private func humanActionResult(
    request: AgentDeviceOperationRequest,
    jobID: String,
    effect: WorkflowEffect,
    action: HumanActionRequired,
    authority: AgentExecutionAuthorityReference? = nil,
    state: JobState = .waitingForDevice
  ) throws -> AgentDeviceOperationResult {
    try AgentDeviceOperationResult(
      requestID: request.requestID, jobID: jobID, executionMode: request.executionMode,
      jobState: state, disposition: .humanActionRequired, resolvedEffect: effect,
      outcomeCertainty: state == .waitingForRecovery ? .unknown : .notApplicable,
      executor: executor, humanActionID: action.actionID, blockerCode: action.reasonCode,
      authorizationReference: authority)
  }
}

package final class AgentExecutionPermit: @unchecked Sendable {
  private let lock = NSLock()
  private var consumed = false
  private let requestID: String
  private let jobID: String
  private let sessionID: String
  private let planDigestSHA256: String
  private let durableTargetID: String
  private let bindingRevision: Int
  private let bindingDigestSHA256: String
  private let factFreshUntilUTC: String
  private let authority: AgentResolvedExecutionAuthority

  fileprivate init(
    requestID: String,
    jobID: String,
    sessionID: String,
    planDigestSHA256: String,
    durableTargetID: String,
    bindingRevision: Int,
    bindingDigestSHA256: String,
    factFreshUntilUTC: String,
    authority: AgentResolvedExecutionAuthority
  ) {
    self.requestID = requestID
    self.jobID = jobID
    self.sessionID = sessionID
    self.planDigestSHA256 = planDigestSHA256
    self.durableTargetID = durableTargetID
    self.bindingRevision = bindingRevision
    self.bindingDigestSHA256 = bindingDigestSHA256
    self.factFreshUntilUTC = factFreshUntilUTC
    self.authority = authority
  }

  package func consume(
    requestID: String,
    jobID: String,
    sessionID: String,
    planDigestSHA256: String,
    durableTargetID: String,
    bindingRevision: Int,
    bindingDigestSHA256: String,
    currentUTC: String
  ) throws {
    try lock.withLock {
      guard !consumed,
        self.requestID == requestID, self.jobID == jobID, self.sessionID == sessionID,
        self.planDigestSHA256 == planDigestSHA256,
        self.durableTargetID == durableTargetID,
        self.bindingRevision == bindingRevision,
        self.bindingDigestSHA256 == bindingDigestSHA256,
        AgentDocumentValidation.date(currentUTC)
          <= AgentDocumentValidation.date(factFreshUntilUTC),
        AgentDocumentValidation.date(currentUTC)
          <= AgentDocumentValidation.date(authority.validUntilUTC)
      else {
        throw AgentDeviceOperationSubmissionError(
          code: .trustedServiceUnavailable, fieldPath: "$")
      }
      consumed = true
    }
  }
}
