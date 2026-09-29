import Foundation
import Testing

@testable import ArkDeckCore

struct JobStateMachineTests {
  // TEST-AC-JOB-001-01 / stateMachineProperty
  @Test func TEST_AC_JOB_001_01_PlannedIsDistinctFromHardwareSuccess() throws {
    var machine = JobStateMachine(mode: .planOnly)

    try machine.handle(.startPreflight)
    try machine.handle(.preflightPassed)
    try machine.handle(.workflowCompleted)
    try machine.handle(.finalizationCompleted)

    #expect(machine.state == .planned)
    #expect(machine.state != .succeeded)
  }

  // TEST-AC-JOB-001-02 / stateMachineProperty
  @Test func TEST_AC_JOB_001_02_AllTerminalStatesRejectReentryAndNewSteps() throws {
    for terminalMachine in try makeTerminalMachines() {
      var machine = terminalMachine
      let terminalState = machine.state

      #expect(machine.activeStep == nil, "\(terminalState.rawValue) retained an active step")
      #expect(throws: (any Error).self) { try machine.handle(.preflightPassed) }
      #expect(machine.state == terminalState)
      #expect(machine.invariantViolations.last?.kind == .illegalTransition)

      let step = try makeHostStep(id: "terminal-dispatch")
      #expect(throws: (any Error).self) { try machine.authorizeDispatch(of: step) }
      #expect(machine.state == terminalState)
      #expect(machine.invariantViolations.last?.kind == .terminalStepDispatch)
    }
  }

  @Test func terminalStatesHaveNoDestinationsForEitherMode() {
    let terminalStates: Set<JobState> = [
      .planned, .succeeded, .recovered, .failed, .cancelled, .interrupted,
    ]
    #expect(Set(JobState.allCases.filter(\.isTerminal)) == terminalStates)

    for mode in JobExecutionMode.allCases {
      for terminalState in terminalStates {
        #expect(JobStateMachine.allowedDestinations(from: terminalState, mode: mode).isEmpty)
        for candidate in JobState.allCases {
          #expect(
            !JobStateMachine.isAllowedTransition(from: terminalState, to: candidate, mode: mode)
          )
        }
      }
    }
  }

  @Test func jobStatesVersionTheRecoveryExtensionWithoutMutatingTheLockedJournalContract() throws {
    let contract = try loadContract(named: "journal-event.schema.json")
    let definitions = try #require(contract["$defs"] as? [String: Any])
    let stateDefinition = try #require(definitions["jobState"] as? [String: Any])
    let contractStates = try #require(stateDefinition["enum"] as? [String])

    #expect(JobState.schemaVersion == "1.0.0")
    #expect(Set(JobState.allCases.map(\.rawValue)) == Set(contractStates))
  }

  @Test func currentJournalContainsTheCompleteRuntimeTransitionGraph() throws {
    let contractPairs = try loadContractTransitionPairs()
    let swiftPairs = Set(
      JobExecutionMode.allCases.flatMap { mode in
        JobState.allCases.flatMap { from in
          JobStateMachine.allowedDestinations(from: from, mode: mode).map { to in
            StateTransitionPair(from: from, to: to)
          }
        }
      })

    #expect(swiftPairs == contractPairs)
  }

  @Test func resumeMarkerDestinationSetsIncludeBothApprovedSafetyExits() {
    #expect(
      JobStateMachine.allowedDestinations(
        from: .resumeAtConfirmedSafeBoundary,
        mode: .execute
      ) == [.running, .finalizing, .waitingForRecovery]
    )
    #expect(
      JobStateMachine.allowedDestinations(
        from: .resumeAtConfirmedSafeBoundary,
        mode: .planOnly
      ) == [.planning, .finalizing, .waitingForRecovery]
    )
  }

  // TEST-AC-JOB-001-05 / autonomousCompleteOverwriteRecoveryContract
  @Test func TEST_AC_JOB_001_05_CompleteProofUsesDistinctRecoveryAndTerminalState() throws {
    var machine = try makeWaitingForRecoveryMachine()
    try machine.handle(.completeOverwriteRecoveryStarted)
    #expect(machine.state == .recoveringByCompleteOverwrite)

    try machine.handle(.workflowCompleted)
    #expect(machine.state == .finalizing)
    try machine.handle(.finalizationCompleted)
    #expect(machine.state == .recovered)
    #expect(machine.state != .succeeded)
  }

  @Test func planOnlyCannotEnterTheCompleteOverwriteRecoveryBranch() throws {
    #expect(
      !JobStateMachine.isAllowedTransition(
        from: .waitingForRecovery, to: .recoveringByCompleteOverwrite, mode: .planOnly))
    #expect(
      !JobStateMachine.isAllowedTransition(
        from: .reconciling, to: .recoveringByCompleteOverwrite, mode: .planOnly))
  }

  @Test func journalContractContainsBothApprovedResumeMarkerPairsAndOldReaderRejectsThem() throws {
    let contractPairs = try loadContractTransitionPairs()
    let newPairs: Set<StateTransitionPair> = [
      .init(from: .resumeAtConfirmedSafeBoundary, to: .finalizing),
      .init(from: .resumeAtConfirmedSafeBoundary, to: .waitingForRecovery),
    ]

    #expect(newPairs.isSubset(of: contractPairs))
    for (index, pair) in newPairs.sorted(by: { $0.to.rawValue < $1.to.rawValue }).enumerated() {
      let fixture = JournalStateTransitionFixture(
        schemaVersion: "1.0.0",
        eventId: "marker-transition-\(index)",
        sequence: index,
        sessionId: "session-c4",
        jobId: "job-c4",
        timestamp: "2026-07-15T15:53:38Z",
        kind: "stateTransition",
        payload: .init(
          from: pair.from,
          to: pair.to,
          reason: "TASK-C4-001 contract fixture",
          triggerEventId: nil
        )
      )
      let decoded = try JSONDecoder().decode(
        JournalStateTransitionFixture.self,
        from: JSONEncoder().encode(fixture)
      )
      #expect(decoded == fixture)
      #expect(
        contractPairs.contains(.init(from: decoded.payload.from, to: decoded.payload.to))
      )
    }

    let oldReaderPairs = contractPairs.subtracting(newPairs)
    for pair in newPairs {
      #expect(!oldReaderPairs.contains(pair))
    }
  }

  @Test func executionModesRejectEachOthersExclusiveStates() {
    let executeExclusiveStates: Set<JobState> = [
      .running, .waitingForDevice, .awaitingRebindConfirmation,
    ]

    for from in JobState.allCases {
      let planDestinations = JobStateMachine.allowedDestinations(from: from, mode: .planOnly)
      #expect(
        planDestinations.isDisjoint(with: executeExclusiveStates),
        "planOnly accepted execute-only destination from \(from.rawValue)"
      )
      #expect(
        !JobStateMachine.allowedDestinations(from: from, mode: .execute).contains(.planning),
        "execute accepted planning from \(from.rawValue)"
      )
    }
    for executeOnlyState in executeExclusiveStates {
      #expect(
        JobStateMachine.allowedDestinations(from: executeOnlyState, mode: .planOnly).isEmpty
      )
    }
    #expect(
      JobStateMachine.allowedDestinations(from: .planning, mode: .execute).isEmpty
    )
  }

  @Test func normalResumeConfirmationSelectsOnlyTheModeCorrectExecutionPhase() throws {
    for mode in JobExecutionMode.allCases {
      var machine = try makeResumeMarkerMachine(mode: mode)
      let outcome = try machine.handle(.resumeConfirmed)
      #expect(
        outcome.transition
          == .init(
            from: .resumeAtConfirmedSafeBoundary,
            to: mode == .execute ? .running : .planning
          )
      )
    }
  }

  @Test func modeExclusiveIllegalEdgeRecordsInvariantViolation() throws {
    var planOnly = JobStateMachine(mode: .planOnly)
    try planOnly.handle(.startPreflight)
    try planOnly.handle(.preflightPassed)

    #expect(throws: (any Error).self) { try planOnly.handle(.waitForDevice) }
    #expect(planOnly.state == .planning)
    #expect(planOnly.invariantViolations.last?.kind == .illegalTransition)
    #expect(planOnly.invariantViolations.last?.attemptedState == .waitingForDevice)
  }

  @Test func successFinalizationCannotUseTheConfirmedFailureEdge() throws {
    var execute = JobStateMachine(mode: .execute)
    try execute.handle(.startPreflight)
    #expect(throws: (any Error).self) { try execute.handle(.workflowCompleted) }
    #expect(execute.state == .preflight)

    var planOnly = JobStateMachine(mode: .planOnly)
    #expect(throws: (any Error).self) { try planOnly.handle(.workflowCompleted) }
    #expect(planOnly.state == .queued)
  }

  @Test func failureCompensationHasASeparateFinalizationLaneAndRetainsOriginalFailure() throws {
    let compensation = try CompensationDescriptor(
      id: "compensation-uninstall", kind: .uninstallPackage,
      declaredEffect: .deviceMutation, declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .confirmedDevice, trigger: .onFailure,
      arguments: ["packageName": .string("com.example.demo")], argumentsHash: String(repeating: "a", count: 64))
    let source = try WorkflowStep(
      id: "install", kind: .installPackage,
      declaredEffect: .deviceMutation, declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .confirmedDevice,
      arguments: ["packageArtifactId": .string("fixture-hap"), "packageName": .string("com.example.demo"),
        "replacePolicy": .string("allow")], compensationDescriptors: [compensation])
    var machine = try makeFailedFinalizingMachine()
    let original = machine.originalFailure
    #expect(throws: (any Error).self) { try machine.authorizeDispatch(of: source) }
    #expect(throws: (any Error).self) {
      try machine.authorizeCompensation(compensation, declaredBy: source, sourceSucceeded: false)
    }
    _ = try machine.authorizeCompensation(compensation, declaredBy: source, sourceSucceeded: true)
    #expect(throws: (any Error).self) { try machine.handle(.finalizationCompleted) }
    try machine.handle(.externalOutcomeOrIdentityUnknown)
    #expect(machine.state == .waitingForRecovery)
    #expect(machine.originalFailure == original)
    try machine.handle(.recoveryRequested)
    let compensationFailure = WorkflowFailure(
      classification: .compensation, code: "stop-failed", summary: "compensation failed")
    try machine.handle(.recoveryEvaluated(.confirmedFailure(compensationFailure)))
    #expect(machine.state == .finalizing)
    #expect(machine.originalFailure == original)
    try machine.handle(.finalizationCompleted)
    #expect(machine.state == .failed)
    #expect(throws: (any Error).self) {
      try machine.authorizeCompensation(compensation, declaredBy: source, sourceSucceeded: true)
    }
    var successfulFinalization = try makeFinalizingMachine(mode: .execute)
    #expect(throws: (any Error).self) {
      try successfulFinalization.authorizeCompensation(
        compensation, declaredBy: source, sourceSucceeded: true)
    }
    var planOnly = try makeFinalizingMachine(mode: .planOnly)
    #expect(throws: (any Error).self) {
      try planOnly.authorizeCompensation(compensation, declaredBy: source, sourceSucceeded: true)
    }
    #expect(!JobStateMachine.isAllowedTransition(from: .finalizing, to: .waitingForRecovery, mode: .planOnly))
    #expect(JobStateMachine.isAllowedTransition(from: .finalizing, to: .waitingForRecovery, mode: .execute))
  }

  @Test func finalizationRequiresMatchingFinalizeStepCompletionBeforeTerminal() throws {
    let finalizingMachines: [(machine: JobStateMachine, expectedTerminal: JobState)] = [
      (try makeFinalizingMachine(mode: .execute), .succeeded),
      (try makeFinalizingMachine(mode: .planOnly), .planned),
      (try makeFailedFinalizingMachine(), .failed),
    ]

    for (index, candidate) in finalizingMachines.enumerated() {
      var machine = candidate.machine
      let finalizeStep = try makeFinalizeStep(id: "finalize-\(index)")
      _ = try machine.authorizeDispatch(of: finalizeStep)

      #expect(throws: (any Error).self) { try machine.handle(.finalizationCompleted) }
      #expect(machine.state == .finalizing)
      #expect(machine.activeStep?.id == finalizeStep.id)
      #expect(machine.invariantViolations.last?.kind == .activeStepStillRunning)

      #expect(throws: (any Error).self) {
        try machine.completeAuthorizedStep(id: "wrong-finalize-step")
      }
      #expect(machine.state == .finalizing)
      #expect(machine.activeStep?.id == finalizeStep.id)
      #expect(machine.invariantViolations.last?.kind == .activeStepMismatch)

      #expect(throws: (any Error).self) { try machine.handle(.finalizationCompleted) }
      #expect(machine.state == .finalizing)
      #expect(machine.activeStep?.id == finalizeStep.id)

      try machine.completeAuthorizedStep(id: finalizeStep.id)
      #expect(machine.activeStep == nil)
      try machine.handle(.finalizationCompleted)
      #expect(machine.state == candidate.expectedTerminal)
      #expect(machine.activeStep == nil)
    }
  }

  @Test func nonFinalizeStepIsNotSilentlyClearedToReachATerminalState() throws {
    var machine = try makeRunningMachine()
    let step = try makeHostStep(id: "running-step")
    _ = try machine.authorizeDispatch(of: step)

    #expect(throws: (any Error).self) { try machine.handle(.workflowCompleted) }
    #expect(machine.state == .running)
    #expect(machine.activeStep?.id == step.id)
    #expect(machine.invariantViolations.last?.kind == .activeStepStillRunning)
  }

  // TEST-AC-JOB-001-03 / recoveryFaultInjection
  @Test func TEST_AC_JOB_001_03_MissingDestructiveOutcomeStartsWaitingWithoutReplay() throws {
    var machine = try JobStateMachine(
      mode: .execute,
      recoveringFrom: .running,
      finding: .missingDestructiveOutcome
    )

    #expect(machine.state == .waitingForRecovery)
    #expect(throws: (any Error).self) { try machine.handle(.resumeConfirmed) }
    #expect(machine.state == .waitingForRecovery)
    do {
      _ = try machine.authorizeDispatch(of: makeFlashStep())
      Issue.record("outcomeUnknown recovery state authorized destructive dispatch")
    } catch {
      #expect(machine.invariantViolations.last?.kind == .dispatchNotAllowedInState)
    }
  }

  @Test func recoveryStatesRejectNormalWorkflowDispatch() throws {
    let flash = try makeFlashStep()

    var waiting = try makeWaitingForRecoveryMachine()
    #expect(throws: (any Error).self) { try waiting.authorizeDispatch(of: flash) }
    #expect(waiting.invariantViolations.last?.kind == .dispatchNotAllowedInState)

    var reconciling = try makeWaitingForRecoveryMachine()
    try reconciling.handle(.recoveryRequested)
    #expect(throws: (any Error).self) { try reconciling.authorizeDispatch(of: flash) }
    #expect(reconciling.invariantViolations.last?.kind == .dispatchNotAllowedInState)

    var resuming = try makeWaitingForRecoveryMachine()
    try resuming.handle(.recoveryRequested)
    try resuming.handle(
      .recoveryEvaluated(
        .resume(
          .init(
            restartSafe: true,
            safeBoundaryConfirmed: true,
            outcomeConfirmed: true,
            bindingConfirmed: true
          ))))
    #expect(resuming.state == .resumeAtConfirmedSafeBoundary)
    #expect(throws: (any Error).self) { try resuming.authorizeDispatch(of: flash) }
    #expect(resuming.invariantViolations.last?.kind == .dispatchNotAllowedInState)
  }

  // TEST-AC-JOB-001-04 / stateMachineProperty
  @Test func TEST_AC_JOB_001_04_ConfirmedPreflightFailureFinalizesAsFailed() throws {
    var machine = JobStateMachine(mode: .execute)
    let failure = WorkflowFailure(
      classification: .preflight,
      code: "device-unavailable",
      summary: "confirmed before external effects"
    )

    try machine.handle(.startPreflight)
    let finalizing = try machine.handle(.confirmedFailure(failure))
    #expect(finalizing.transition == .init(from: .preflight, to: .finalizing))
    #expect(machine.originalFailure == failure)

    try machine.handle(.finalizationCompleted)
    #expect(machine.state == .failed)
    #expect(machine.state.isTerminal)
  }

  @Test func legacyResumeRecoveryRequiresEveryResumePrecondition() throws {
    let incompleteEvidenceVectors = [
      RecoveryResumeEvidence(
        restartSafe: false, safeBoundaryConfirmed: true, outcomeConfirmed: true,
        bindingConfirmed: true),
      RecoveryResumeEvidence(
        restartSafe: true, safeBoundaryConfirmed: false, outcomeConfirmed: true,
        bindingConfirmed: true),
      RecoveryResumeEvidence(
        restartSafe: true, safeBoundaryConfirmed: true, outcomeConfirmed: false,
        bindingConfirmed: true),
      RecoveryResumeEvidence(
        restartSafe: true, safeBoundaryConfirmed: true, outcomeConfirmed: true,
        bindingConfirmed: false),
    ]
    for incompleteEvidence in incompleteEvidenceVectors {
      var rejectedMachine = try makeWaitingForRecoveryMachine()
      try rejectedMachine.handle(.recoveryRequested)
      let rejectedResume = try rejectedMachine.handle(
        .recoveryEvaluated(.resume(incompleteEvidence)))
      #expect(rejectedMachine.state == .waitingForRecovery)
      #expect(rejectedResume.directives.contains(.dispatchNoUnknownStep))
      #expect(throws: (any Error).self) {
        try rejectedMachine.authorizeDispatch(of: makeFlashStep())
      }
      #expect(rejectedMachine.invariantViolations.last?.kind == .dispatchNotAllowedInState)
    }

    var machine = try makeWaitingForRecoveryMachine()
    try machine.handle(.recoveryRequested)
    let completeEvidence = RecoveryResumeEvidence(
      restartSafe: true,
      safeBoundaryConfirmed: true,
      outcomeConfirmed: true,
      bindingConfirmed: true
    )
    try machine.handle(.recoveryEvaluated(.resume(completeEvidence)))
    #expect(machine.state == .resumeAtConfirmedSafeBoundary)
    try machine.handle(.resumeConfirmed)
    #expect(machine.state == .running)
  }

  // TEST-AC-JOB-001-07 / recoveryDecisionJournalStateMachineContract
  @Test func TEST_AC_JOB_001_07_ResumeMarkerUsesBinaryConfirmedOrUnknownDecision() throws {
    let failure = WorkflowFailure(
      classification: .recovery,
      code: "confirmed-recovery-failure",
      summary: "failure and all external effects are confirmed"
    )
    let vectors: [ResumeMarkerDecisionVector] = [
      .init(
        name: "confirmed",
        evidence: .init(
          deviceIdentity: .confirmed,
          externalEffectOutcomes: .allConfirmed,
          detectedFailure: failure
        ),
        expectedDestination: .finalizing
      ),
      .init(
        name: "unknown identity",
        evidence: .init(
          deviceIdentity: .unknown,
          externalEffectOutcomes: .allConfirmed,
          detectedFailure: failure
        ),
        expectedDestination: .waitingForRecovery
      ),
      .init(
        name: "unknown outcome",
        evidence: .init(
          deviceIdentity: .confirmed,
          externalEffectOutcomes: .containsUnknown,
          detectedFailure: failure
        ),
        expectedDestination: .waitingForRecovery
      ),
    ]

    let contractPairs = try loadContractTransitionPairs()
    for mode in JobExecutionMode.allCases {
      for vector in vectors {
        var machine = try makeResumeMarkerMachine(mode: mode)
        try assertResumeMarkerRejectsOrdinaryDispatch(
          machine: &machine,
          context: "\(mode.rawValue) / \(vector.name)"
        )

        let decision = try machine.handle(
          .resumeMarkerEvaluated(
            evidence: vector.evidence,
            requestedDestination: vector.expectedDestination
          ))
        #expect(
          decision.transition
            == .init(from: .resumeAtConfirmedSafeBoundary, to: vector.expectedDestination)
        )
        #expect(
          contractPairs.contains(
            .init(from: .resumeAtConfirmedSafeBoundary, to: vector.expectedDestination)
          )
        )

        if vector.expectedDestination == .finalizing {
          #expect(machine.originalFailure == failure)
          let terminal = try machine.handle(.finalizationCompleted)
          #expect(
            [decision.transition, terminal.transition]
              == [
                .init(from: .resumeAtConfirmedSafeBoundary, to: .finalizing),
                .init(from: .finalizing, to: .failed),
              ]
          )
          #expect(machine.state == .failed)
        } else {
          #expect(machine.state == .waitingForRecovery)
          #expect(
            machine.originalFailure == nil,
            "unknown evidence must not become confirmed failure"
          )
          #expect(decision.directives.contains(.dispatchNoUnknownStep))
          #expect(decision.directives.contains(.preserveOutcomeUnknown))
        }

      }
    }
  }

  @Test func resumeMarkerSemanticValidatorRejectsMismatchedEvidenceAndPair() throws {
    let failure = WorkflowFailure(
      classification: .recovery,
      code: "marker-mismatch",
      summary: "semantic mismatch fixture"
    )

    for mode in JobExecutionMode.allCases {
      let executionPhase: JobState = mode == .execute ? .running : .planning
      let mismatches: [(ResumeMarkerDecisionEvidence, JobState)] = [
        (
          .init(
            deviceIdentity: .confirmed,
            externalEffectOutcomes: .allConfirmed,
            detectedFailure: failure
          ),
          .waitingForRecovery
        ),
        (
          .init(
            deviceIdentity: .unknown,
            externalEffectOutcomes: .allConfirmed,
            detectedFailure: failure
          ),
          .finalizing
        ),
        (
          .init(
            deviceIdentity: .confirmed,
            externalEffectOutcomes: .containsUnknown,
            detectedFailure: failure
          ),
          .finalizing
        ),
        (
          .init(
            deviceIdentity: .confirmed,
            externalEffectOutcomes: .allConfirmed,
            detectedFailure: failure
          ),
          executionPhase
        ),
      ]

      for (evidence, requestedDestination) in mismatches {
        var machine = try makeResumeMarkerMachine(mode: mode)
        #expect(throws: (any Error).self) {
          try machine.handle(
            .resumeMarkerEvaluated(
              evidence: evidence,
              requestedDestination: requestedDestination
            ))
        }
        #expect(machine.state == .resumeAtConfirmedSafeBoundary)
        #expect(machine.invariantViolations.last?.kind == .resumeMarkerEvidenceMismatch)
        #expect(machine.invariantViolations.last?.attemptedState == requestedDestination)
      }

      var legacyFailureEvent = try makeResumeMarkerMachine(mode: mode)
      #expect(throws: (any Error).self) {
        try legacyFailureEvent.handle(.confirmedFailure(failure))
      }
      #expect(
        legacyFailureEvent.invariantViolations.last?.kind
          == .resumeMarkerEvidenceMismatch
      )

      var legacyUnknownEvent = try makeResumeMarkerMachine(mode: mode)
      #expect(throws: (any Error).self) {
        try legacyUnknownEvent.handle(.externalOutcomeOrIdentityUnknown)
      }
      #expect(
        legacyUnknownEvent.invariantViolations.last?.kind
          == .resumeMarkerEvidenceMismatch
      )
    }
  }

  // TEST-AC-JOB-001-06 / cancellationContract
  @Test func TEST_AC_JOB_001_06_NormalCancellationUsesTheSafeBoundaryPath() throws {
    var machine = try makeRunningMachine()
    let step = try makeHostStep(id: "hash-for-cancellation")
    _ = try machine.authorizeDispatch(of: step)
    #expect(machine.activeStep?.cancellation == .immediate)

    for invalidStepId in [nil, "different-step"] as [String?] {
      #expect(throws: (any Error).self) {
        try machine.handle(.cancellationRequested(activeStepId: invalidStepId))
      }
      #expect(machine.state == .running)
      #expect(machine.activeStep?.id == step.id)
      #expect(machine.invariantViolations.last?.kind == .activeStepMismatch)
    }

    let requested = try machine.handle(.cancellationRequested(activeStepId: step.id))
    #expect(machine.state == .cancelRequested)
    #expect(requested.directives.contains(.persistCancellationRequest))

    try machine.handle(.cancellationAcknowledged)
    #expect(machine.state == .cancellingAtSafeBoundary)
    let cancelled = try machine.handle(.safeBoundaryReached)
    #expect(cancelled.directives.contains(.persistCancellationOutcomeAndSafeBoundary))
    #expect(machine.state == .cancelled)
    #expect(machine.activeStep == nil)
  }

  // TEST-AC-JOB-003-01 / criticalCancellationContract
  @Test func TEST_AC_JOB_003_01_CriticalCancellationNeverForceTerminatesCurrentProcess() throws {
    var machine = try makeRunningMachine()
    let flash = try makeFlashStep()
    _ = try machine.authorizeDispatch(of: flash)
    #expect(machine.activeStep?.cancellation == .criticalNonInterruptible)

    let requested = try machine.handle(
      .cancellationRequested(activeStepId: flash.id)
    )

    #expect(machine.state == .cancelRequested)
    #expect(requested.directives.contains(.persistCancellationRequest))
    #expect(requested.directives.contains(.waitForProviderSafeBoundary))
    #expect(requested.directives.contains(.mustNotForceTerminateCurrentProcess))

    try machine.handle(.cancellationAcknowledged)
    #expect(machine.state == .cancellingAtSafeBoundary)
  }

  @Test func criticalCancellationCannotUseMissingOrMismatchedStepIdentity() throws {
    let flash = try makeFlashStep()
    for invalidStepId in [nil, "different-step"] as [String?] {
      var machine = try makeRunningMachine()
      _ = try machine.authorizeDispatch(of: flash)

      #expect(throws: (any Error).self) {
        try machine.handle(.cancellationRequested(activeStepId: invalidStepId))
      }
      #expect(machine.state == .running)
      #expect(machine.activeStep?.id == flash.id)
      #expect(machine.invariantViolations.last?.kind == .activeStepMismatch)
    }
  }

  // TEST-AC-JOB-004-01 / compensationFaultInjection
  @Test func TEST_AC_JOB_004_01_CompensationFailureDoesNotReplaceCaptureFailure() throws {
    let stopCapture = try makeCompensation(
      id: "stop-capture",
      kind: .stopRemoteCapture,
      trigger: .onFailure,
      arguments: ["captureStepId": .string("capture"), "stopPolicy": .string("graceful")]
    )
    let restoreParameter = try makeCompensation(
      id: "restore-parameter",
      kind: .restoreParameter,
      trigger: .onAnyTerminal,
      arguments: [
        "name": .string("persist.arkui.trace"),
        "snapshotStepId": .string("snapshot"),
        "restorePolicy": .string("restoreKnownValue"),
      ]
    )
    let plan = CompensationPlanner.plan(
      completedStepsInExecutionOrder: [
        .init(sourceStepId: "snapshot", descriptors: [restoreParameter]),
        .init(sourceStepId: "capture", descriptors: [stopCapture]),
      ],
      terminalPath: .failure
    )
    #expect(plan.map(\.descriptor.id) == ["stop-capture", "restore-parameter"])

    let captureFailure = WorkflowFailure(
      classification: .semantic,
      code: "trace-capture-failed",
      summary: "capture adapter reported failure"
    )
    let restoreFailure = WorkflowFailure(
      classification: .compensation,
      code: "parameter-restore-failed",
      summary: "restore readback did not match"
    )
    let report = JobFinalizationReport(
      originalFailure: captureFailure,
      compensationRecords: [
        .init(plannedCompensation: plan[0], outcome: .succeeded),
        .init(plannedCompensation: plan[1], outcome: .failed(restoreFailure)),
      ]
    )

    #expect(report.originalFailure == captureFailure)
    #expect(report.compensationFailures == [restoreFailure])
    #expect(report.needsAttention)
  }

  @Test func compensationTriggersApplyToExactlyTheirDeclaredTerminalPaths() throws {
    let success = try makeCompensation(
      id: "success", kind: .stopApplication, trigger: .onSuccess,
      arguments: ["bundleName": .string("bundle"), "abilityName": .string("ability")])
    let failure = try makeCompensation(
      id: "failure", kind: .stopApplication, trigger: .onFailure,
      arguments: ["bundleName": .string("bundle"), "abilityName": .string("ability")])
    let cancel = try makeCompensation(
      id: "cancel", kind: .stopApplication, trigger: .onCancel,
      arguments: ["bundleName": .string("bundle"), "abilityName": .string("ability")])
    let any = try makeCompensation(
      id: "any", kind: .stopApplication, trigger: .onAnyTerminal,
      arguments: ["bundleName": .string("bundle"), "abilityName": .string("ability")])
    let completed = [
      CompletedStepCompensations(
        sourceStepId: "application", descriptors: [success, failure, cancel, any])
    ]

    #expect(
      CompensationPlanner.plan(completedStepsInExecutionOrder: completed, terminalPath: .success)
        .map(\.descriptor.id)
        == ["any", "success"])
    #expect(
      CompensationPlanner.plan(completedStepsInExecutionOrder: completed, terminalPath: .failure)
        .map(\.descriptor.id)
        == ["any", "failure"])
    #expect(
      CompensationPlanner.plan(completedStepsInExecutionOrder: completed, terminalPath: .cancel)
        .map(\.descriptor.id)
        == ["any", "cancel"])
  }

  @Test func planOnlyRejectsMutationDispatchWithoutChangingState() throws {
    var machine = JobStateMachine(mode: .planOnly)
    try machine.handle(.startPreflight)
    try machine.handle(.preflightPassed)
    let mutation = try WorkflowStep(
      id: "set-parameter",
      kind: .setParameter,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      arguments: [
        "name": .string("persist.example"),
        "value": .string("1"),
        "readbackPolicy": .string("required"),
      ]
    )

    #expect(mutation.effect == .deviceMutation)
    #expect(throws: (any Error).self) { try machine.authorizeDispatch(of: mutation) }
    #expect(machine.state == .planning)
    #expect(machine.invariantViolations.last?.kind == .planOnlyMutationDispatch)
  }

  private func makeRunningMachine() throws -> JobStateMachine {
    var machine = JobStateMachine(mode: .execute)
    try machine.handle(.startPreflight)
    try machine.handle(.preflightPassed)
    return machine
  }

  private func makeResumeMarkerMachine(mode: JobExecutionMode) throws -> JobStateMachine {
    var machine = try JobStateMachine(
      mode: mode,
      recoveringFrom: mode == .execute ? .running : .planning,
      finding: .requiresReconciliation
    )
    try machine.handle(
      .recoveryEvaluated(
        .resume(
          .init(
            restartSafe: true,
            safeBoundaryConfirmed: true,
            outcomeConfirmed: true,
            bindingConfirmed: true
          ))))
    #expect(machine.state == .resumeAtConfirmedSafeBoundary)
    return machine
  }

  private func assertResumeMarkerRejectsOrdinaryDispatch(
    machine: inout JobStateMachine,
    context: String
  ) throws {
    let ordinarySteps = try [
      makeHostStep(id: "marker-host"),
      makeReadOnlyStep(),
      makeMutationStep(),
      makeFlashStep(),
    ]
    for step in ordinarySteps {
      do {
        _ = try machine.authorizeDispatch(of: step)
        Issue.record("\(context) authorized \(step.effect.rawValue) step at resume marker")
      } catch {
        #expect(
          machine.invariantViolations.last?.kind
            == .dispatchNotAllowedInState,
          "\(context)"
        )
      }
    }

    let unknownKind = Data(
      #"""
      {
        "id": "unknown",
        "kind": "provider.rawCommand",
        "effect": "hostOnly",
        "cancellation": "immediate",
        "bindingRequirement": "none",
        "arguments": {},
        "compensationDescriptors": []
      }
      """#.utf8
    )
    #expect(
      throws: WorkflowStepValidationError.unsupportedKind(
        rawKind: "provider.rawCommand", assumedEffect: .destructive),
      "\(context)"
    ) {
      try WorkflowStepDecoder.decodeCoreOrProviderStep(unknownKind)
    }
  }

  private func makeWaitingForRecoveryMachine() throws -> JobStateMachine {
    var machine = try makeRunningMachine()
    let outcome = try machine.handle(.externalOutcomeOrIdentityUnknown)
    #expect(outcome.directives.contains(.preserveOutcomeUnknown))
    return machine
  }

  private func makeFinalizingMachine(mode: JobExecutionMode) throws -> JobStateMachine {
    var machine = JobStateMachine(mode: mode)
    try machine.handle(.startPreflight)
    try machine.handle(.preflightPassed)
    try machine.handle(.workflowCompleted)
    return machine
  }

  private func makeFailedFinalizingMachine() throws -> JobStateMachine {
    var machine = JobStateMachine(mode: .execute)
    try machine.handle(.startPreflight)
    try machine.handle(
      .confirmedFailure(
        .init(
          classification: .preflight,
          code: "confirmed-finalization-failure",
          summary: "confirmed failure before finalization"
        )))
    return machine
  }

  private func makeTerminalMachines() throws -> [JobStateMachine] {
    var planned = JobStateMachine(mode: .planOnly)
    try planned.handle(.startPreflight)
    try planned.handle(.preflightPassed)
    try planned.handle(.workflowCompleted)
    try planned.handle(.finalizationCompleted)

    var succeeded = try makeRunningMachine()
    try succeeded.handle(.workflowCompleted)
    try succeeded.handle(.finalizationCompleted)

    var failed = JobStateMachine(mode: .execute)
    try failed.handle(.startPreflight)
    try failed.handle(
      .confirmedFailure(
        .init(
          classification: .preflight,
          code: "confirmed",
          summary: "confirmed failure"
        )))
    try failed.handle(.finalizationCompleted)

    var cancelled = JobStateMachine(mode: .execute)
    try cancelled.handle(.cancellationRequested(activeStepId: nil))
    try cancelled.handle(.cancellationAcknowledged)
    try cancelled.handle(.safeBoundaryReached)

    var interrupted = try makeWaitingForRecoveryMachine()
    try interrupted.handle(.abandonmentRequested)
    try interrupted.handle(.abandonmentPersisted)

    return [planned, succeeded, failed, cancelled, interrupted]
  }

  private func makeHostStep(id: String) throws -> WorkflowStep {
    try WorkflowStep(
      id: id,
      kind: .hashFile,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      arguments: ["artifactId": .string("artifact")]
    )
  }

  private func makeFinalizeStep(id: String) throws -> WorkflowStep {
    try WorkflowStep(
      id: id,
      kind: .finalizeSession,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      arguments: [
        "sessionId": .string("session-001"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ]
    )
  }

  private func makeReadOnlyStep() throws -> WorkflowStep {
    try WorkflowStep(
      id: "marker-read-only",
      kind: .captureRemoteStdout,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "catalogId": .string("arkui-ui-dump"),
        "actionId": .string("nodeSummary"),
        "parameters": .object([:]),
        "artifactId": .string("marker-artifact"),
      ]
    )
  }

  private func makeMutationStep() throws -> WorkflowStep {
    try WorkflowStep(
      id: "marker-mutation",
      kind: .setParameter,
      declaredEffect: .deviceMutation,
      declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "name": .string("persist.arkdeck.marker"),
        "value": .string("1"),
        "readbackPolicy": .string("required"),
      ]
    )
  }

  private func makeFlashStep() throws -> WorkflowStep {
    try WorkflowStep(
      id: "flash-system",
      kind: .flashPartition,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      arguments: [
        "providerOperationId": .string("flash.partition"),
        "partition": .string("system"),
        "imageArtifactId": .string("system-image"),
        "imageSha256": .string(String(repeating: "a", count: 64)),
        "imageSize": .integer(4096),
        "confirmationId": .string("confirm-flash"),
        "safeBoundaryId": .string("partition-boundary"),
      ]
    )
  }

  private func makeCompensation(
    id: String,
    kind: WorkflowStepKind,
    trigger: CompensationTrigger,
    arguments: [String: JSONValue]
  ) throws -> CompensationDescriptor {
    try CompensationDescriptor(
      id: id,
      kind: kind,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      trigger: trigger,
      arguments: arguments,
      argumentsHash: String(repeating: "a", count: 64)
    )
  }

  private func loadContract(named name: String) throws -> [String: Any] {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appending(path: "openspec/contracts/\(name)"))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func loadContractTransitionPairs() throws -> Set<StateTransitionPair> {
    let contract = try loadContract(named: "journal-event.schema.json")
    let definitions = try #require(contract["$defs"] as? [String: Any])
    let pairDefinition = try #require(definitions["stateTransitionPair"] as? [String: Any])
    let alternatives = try #require(pairDefinition["oneOf"] as? [[String: Any]])

    var pairs: Set<StateTransitionPair> = []
    for alternative in alternatives {
      let properties = try #require(alternative["properties"] as? [String: Any])
      let fromDefinition = try #require(properties["from"] as? [String: Any])
      let toDefinition = try #require(properties["to"] as? [String: Any])
      let fromRawValue = try #require(fromDefinition["const"] as? String)
      let toRawValues = try #require(toDefinition["enum"] as? [String])
      let from = try #require(JobState(rawValue: fromRawValue))

      for toRawValue in toRawValues {
        pairs.insert(
          StateTransitionPair(
            from: from,
            to: try #require(JobState(rawValue: toRawValue))
          ))
      }
    }
    return pairs
  }

  private struct StateTransitionPair: Hashable, Codable {
    let from: JobState
    let to: JobState
  }

  private struct JournalStateTransitionFixture: Codable, Equatable {
    let schemaVersion: String
    let eventId: String
    let sequence: Int
    let sessionId: String
    let jobId: String
    let timestamp: String
    let kind: String
    let payload: JournalStateTransitionPayload
  }

  private struct JournalStateTransitionPayload: Codable, Equatable {
    let from: JobState
    let to: JobState
    let reason: String
    let triggerEventId: String?
  }

  private struct ResumeMarkerDecisionVector {
    let name: String
    let evidence: ResumeMarkerDecisionEvidence
    let expectedDestination: JobState
  }
}
