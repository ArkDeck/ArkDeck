import Foundation
import XCTest

@testable import ArkDeckCore

final class JobStateMachineTests: XCTestCase {
  // TEST-AC-JOB-001-01 / stateMachineProperty
  func testTEST_AC_JOB_001_01_PlannedIsDistinctFromHardwareSuccess() throws {
    var machine = JobStateMachine(mode: .planOnly)

    try machine.handle(.startPreflight)
    try machine.handle(.preflightPassed)
    try machine.handle(.workflowCompleted)
    try machine.handle(.finalizationCompleted)

    XCTAssertEqual(machine.state, .planned)
    XCTAssertNotEqual(machine.state, .succeeded)
  }

  // TEST-AC-JOB-001-02 / stateMachineProperty
  func testTEST_AC_JOB_001_02_AllTerminalStatesRejectReentryAndNewSteps() throws {
    for terminalMachine in try makeTerminalMachines() {
      var machine = terminalMachine
      let terminalState = machine.state

      XCTAssertNil(machine.activeStep, "\(terminalState.rawValue) retained an active step")
      XCTAssertThrowsError(try machine.handle(.preflightPassed))
      XCTAssertEqual(machine.state, terminalState)
      XCTAssertEqual(machine.invariantViolations.last?.kind, .illegalTransition)

      let step = try makeHostStep(id: "terminal-dispatch")
      XCTAssertThrowsError(try machine.authorizeDispatch(of: step))
      XCTAssertEqual(machine.state, terminalState)
      XCTAssertEqual(machine.invariantViolations.last?.kind, .terminalStepDispatch)
    }
  }

  func testTerminalStatesHaveNoDestinationsForEitherMode() {
    let terminalStates: Set<JobState> = [.planned, .succeeded, .failed, .cancelled, .interrupted]
    XCTAssertEqual(Set(JobState.allCases.filter(\.isTerminal)), terminalStates)

    for mode in JobExecutionMode.allCases {
      for terminalState in terminalStates {
        XCTAssertTrue(JobStateMachine.allowedDestinations(from: terminalState, mode: mode).isEmpty)
        for candidate in JobState.allCases {
          XCTAssertFalse(
            JobStateMachine.isAllowedTransition(from: terminalState, to: candidate, mode: mode)
          )
        }
      }
    }
  }

  func testJobStatesExactlyMatchTheLockedJournalContract() throws {
    let contract = try loadContract(named: "journal-event.schema.json")
    let definitions = try XCTUnwrap(contract["$defs"] as? [String: Any])
    let stateDefinition = try XCTUnwrap(definitions["jobState"] as? [String: Any])
    let contractStates = try XCTUnwrap(stateDefinition["enum"] as? [String])

    XCTAssertEqual(JobState.allCases.map(\.rawValue), contractStates)
  }

  func testCoreTransitionGraphUnionExactlyMatchesTheLockedJournalContract() throws {
    let contractPairs = try loadContractTransitionPairs()
    let swiftPairs = Set(
      JobExecutionMode.allCases.flatMap { mode in
        JobState.allCases.flatMap { from in
          JobStateMachine.allowedDestinations(from: from, mode: mode).map { to in
            StateTransitionPair(from: from, to: to)
          }
        }
      })

    XCTAssertEqual(swiftPairs, contractPairs)
  }

  func testResumeMarkerDestinationSetsIncludeBothApprovedSafetyExits() {
    XCTAssertEqual(
      JobStateMachine.allowedDestinations(
        from: .resumeAtConfirmedSafeBoundary,
        mode: .execute
      ),
      [.running, .finalizing, .waitingForRecovery]
    )
    XCTAssertEqual(
      JobStateMachine.allowedDestinations(
        from: .resumeAtConfirmedSafeBoundary,
        mode: .planOnly
      ),
      [.planning, .finalizing, .waitingForRecovery]
    )
  }

  func testJournalContractContainsBothApprovedResumeMarkerPairsAndOldReaderRejectsThem() throws {
    let contractPairs = try loadContractTransitionPairs()
    let newPairs: Set<StateTransitionPair> = [
      .init(from: .resumeAtConfirmedSafeBoundary, to: .finalizing),
      .init(from: .resumeAtConfirmedSafeBoundary, to: .waitingForRecovery),
    ]

    XCTAssertTrue(newPairs.isSubset(of: contractPairs))
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
      XCTAssertEqual(decoded, fixture)
      XCTAssertTrue(
        contractPairs.contains(.init(from: decoded.payload.from, to: decoded.payload.to))
      )
    }

    let oldReaderPairs = contractPairs.subtracting(newPairs)
    for pair in newPairs {
      XCTAssertFalse(oldReaderPairs.contains(pair))
    }
  }

  func testExecutionModesRejectEachOthersExclusiveStates() {
    let executeExclusiveStates: Set<JobState> = [
      .running, .waitingForDevice, .awaitingRebindConfirmation,
    ]

    for from in JobState.allCases {
      let planDestinations = JobStateMachine.allowedDestinations(from: from, mode: .planOnly)
      XCTAssertTrue(
        planDestinations.isDisjoint(with: executeExclusiveStates),
        "planOnly accepted execute-only destination from \(from.rawValue)"
      )
      XCTAssertFalse(
        JobStateMachine.allowedDestinations(from: from, mode: .execute).contains(.planning),
        "execute accepted planning from \(from.rawValue)"
      )
    }
    for executeOnlyState in executeExclusiveStates {
      XCTAssertTrue(
        JobStateMachine.allowedDestinations(from: executeOnlyState, mode: .planOnly).isEmpty
      )
    }
    XCTAssertTrue(
      JobStateMachine.allowedDestinations(from: .planning, mode: .execute).isEmpty
    )
  }

  func testNormalResumeConfirmationSelectsOnlyTheModeCorrectExecutionPhase() throws {
    for mode in JobExecutionMode.allCases {
      var machine = try makeResumeMarkerMachine(mode: mode)
      let outcome = try machine.handle(.resumeConfirmed)
      XCTAssertEqual(
        outcome.transition,
        .init(
          from: .resumeAtConfirmedSafeBoundary,
          to: mode == .execute ? .running : .planning
        )
      )
    }
  }

  func testModeExclusiveIllegalEdgeRecordsInvariantViolation() throws {
    var planOnly = JobStateMachine(mode: .planOnly)
    try planOnly.handle(.startPreflight)
    try planOnly.handle(.preflightPassed)

    XCTAssertThrowsError(try planOnly.handle(.waitForDevice))
    XCTAssertEqual(planOnly.state, .planning)
    XCTAssertEqual(planOnly.invariantViolations.last?.kind, .illegalTransition)
    XCTAssertEqual(planOnly.invariantViolations.last?.attemptedState, .waitingForDevice)
  }

  func testSuccessFinalizationCannotUseTheConfirmedFailureEdge() throws {
    var execute = JobStateMachine(mode: .execute)
    try execute.handle(.startPreflight)
    XCTAssertThrowsError(try execute.handle(.workflowCompleted))
    XCTAssertEqual(execute.state, .preflight)

    var planOnly = JobStateMachine(mode: .planOnly)
    XCTAssertThrowsError(try planOnly.handle(.workflowCompleted))
    XCTAssertEqual(planOnly.state, .queued)
  }

  func testFinalizationRequiresMatchingFinalizeStepCompletionBeforeTerminal() throws {
    let finalizingMachines: [(machine: JobStateMachine, expectedTerminal: JobState)] = [
      (try makeFinalizingMachine(mode: .execute), .succeeded),
      (try makeFinalizingMachine(mode: .planOnly), .planned),
      (try makeFailedFinalizingMachine(), .failed),
    ]

    for (index, candidate) in finalizingMachines.enumerated() {
      var machine = candidate.machine
      let finalizeStep = try makeFinalizeStep(id: "finalize-\(index)")
      _ = try machine.authorizeDispatch(of: finalizeStep)

      XCTAssertThrowsError(try machine.handle(.finalizationCompleted))
      XCTAssertEqual(machine.state, .finalizing)
      XCTAssertEqual(machine.activeStep?.id, finalizeStep.id)
      XCTAssertEqual(machine.invariantViolations.last?.kind, .activeStepStillRunning)

      XCTAssertThrowsError(try machine.completeAuthorizedStep(id: "wrong-finalize-step"))
      XCTAssertEqual(machine.state, .finalizing)
      XCTAssertEqual(machine.activeStep?.id, finalizeStep.id)
      XCTAssertEqual(machine.invariantViolations.last?.kind, .activeStepMismatch)

      XCTAssertThrowsError(try machine.handle(.finalizationCompleted))
      XCTAssertEqual(machine.state, .finalizing)
      XCTAssertEqual(machine.activeStep?.id, finalizeStep.id)

      try machine.completeAuthorizedStep(id: finalizeStep.id)
      XCTAssertNil(machine.activeStep)
      try machine.handle(.finalizationCompleted)
      XCTAssertEqual(machine.state, candidate.expectedTerminal)
      XCTAssertNil(machine.activeStep)
    }
  }

  func testNonFinalizeStepIsNotSilentlyClearedToReachATerminalState() throws {
    var machine = try makeRunningMachine()
    let step = try makeHostStep(id: "running-step")
    _ = try machine.authorizeDispatch(of: step)

    XCTAssertThrowsError(try machine.handle(.workflowCompleted))
    XCTAssertEqual(machine.state, .running)
    XCTAssertEqual(machine.activeStep?.id, step.id)
    XCTAssertEqual(machine.invariantViolations.last?.kind, .activeStepStillRunning)
  }

  // TEST-AC-JOB-001-03 / recoveryFaultInjection
  func testTEST_AC_JOB_001_03_MissingDestructiveOutcomeCanOnlyWaitForRecovery() throws {
    var machine = try JobStateMachine(
      mode: .execute,
      recoveringFrom: .running,
      finding: .missingDestructiveOutcome
    )

    XCTAssertEqual(machine.state, .waitingForRecovery)
    XCTAssertThrowsError(try machine.handle(.resumeConfirmed))
    XCTAssertEqual(machine.state, .waitingForRecovery)
    do {
      _ = try machine.authorizeDispatch(of: makeFlashStep())
      XCTFail("outcomeUnknown recovery state authorized destructive dispatch")
    } catch {
      XCTAssertEqual(machine.invariantViolations.last?.kind, .dispatchNotAllowedInState)
    }
  }

  func testRecoveryStatesRejectNormalWorkflowDispatch() throws {
    let flash = try makeFlashStep()

    var waiting = try makeWaitingForRecoveryMachine()
    XCTAssertThrowsError(try waiting.authorizeDispatch(of: flash))
    XCTAssertEqual(waiting.invariantViolations.last?.kind, .dispatchNotAllowedInState)

    var reconciling = try makeWaitingForRecoveryMachine()
    try reconciling.handle(.recoveryRequested)
    XCTAssertThrowsError(try reconciling.authorizeDispatch(of: flash))
    XCTAssertEqual(reconciling.invariantViolations.last?.kind, .dispatchNotAllowedInState)

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
    XCTAssertEqual(resuming.state, .resumeAtConfirmedSafeBoundary)
    XCTAssertThrowsError(try resuming.authorizeDispatch(of: flash))
    XCTAssertEqual(resuming.invariantViolations.last?.kind, .dispatchNotAllowedInState)
  }

  // TEST-AC-JOB-001-04 / stateMachineProperty
  func testTEST_AC_JOB_001_04_ConfirmedPreflightFailureFinalizesAsFailed() throws {
    var machine = JobStateMachine(mode: .execute)
    let failure = WorkflowFailure(
      classification: .preflight,
      code: "device-unavailable",
      summary: "confirmed before external effects"
    )

    try machine.handle(.startPreflight)
    let finalizing = try machine.handle(.confirmedFailure(failure))
    XCTAssertEqual(finalizing.transition, .init(from: .preflight, to: .finalizing))
    XCTAssertEqual(machine.originalFailure, failure)

    try machine.handle(.finalizationCompleted)
    XCTAssertEqual(machine.state, .failed)
    XCTAssertTrue(machine.state.isTerminal)
  }

  // TEST-AC-JOB-001-05 / recoveryFaultInjection
  func testTEST_AC_JOB_001_05_RecoveryRequiresEveryResumePrecondition() throws {
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
      XCTAssertEqual(rejectedMachine.state, .waitingForRecovery)
      XCTAssertTrue(rejectedResume.directives.contains(.dispatchNoUnknownStep))
      XCTAssertThrowsError(try rejectedMachine.authorizeDispatch(of: makeFlashStep()))
      XCTAssertEqual(rejectedMachine.invariantViolations.last?.kind, .dispatchNotAllowedInState)
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
    XCTAssertEqual(machine.state, .resumeAtConfirmedSafeBoundary)
    try machine.handle(.resumeConfirmed)
    XCTAssertEqual(machine.state, .running)

  }

  // TEST-AC-JOB-001-07 / recoveryDecisionJournalStateMachineContract
  func testTEST_AC_JOB_001_07_ResumeMarkerUsesBinaryConfirmedOrUnknownDecision() throws {
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
        XCTAssertEqual(
          decision.transition,
          .init(from: .resumeAtConfirmedSafeBoundary, to: vector.expectedDestination)
        )
        XCTAssertTrue(
          contractPairs.contains(
            .init(from: .resumeAtConfirmedSafeBoundary, to: vector.expectedDestination)
          )
        )

        if vector.expectedDestination == .finalizing {
          XCTAssertEqual(machine.originalFailure, failure)
          let terminal = try machine.handle(.finalizationCompleted)
          XCTAssertEqual(
            [decision.transition, terminal.transition],
            [
              .init(from: .resumeAtConfirmedSafeBoundary, to: .finalizing),
              .init(from: .finalizing, to: .failed),
            ]
          )
          XCTAssertEqual(machine.state, .failed)
        } else {
          XCTAssertEqual(machine.state, .waitingForRecovery)
          XCTAssertNil(
            machine.originalFailure,
            "unknown evidence must not become confirmed failure"
          )
          XCTAssertTrue(decision.directives.contains(.dispatchNoUnknownStep))
          XCTAssertTrue(decision.directives.contains(.preserveOutcomeUnknown))
        }

      }
    }
  }

  func testResumeMarkerSemanticValidatorRejectsMismatchedEvidenceAndPair() throws {
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
        XCTAssertThrowsError(
          try machine.handle(
            .resumeMarkerEvaluated(
              evidence: evidence,
              requestedDestination: requestedDestination
            ))
        )
        XCTAssertEqual(machine.state, .resumeAtConfirmedSafeBoundary)
        XCTAssertEqual(machine.invariantViolations.last?.kind, .resumeMarkerEvidenceMismatch)
        XCTAssertEqual(machine.invariantViolations.last?.attemptedState, requestedDestination)
      }

      var legacyFailureEvent = try makeResumeMarkerMachine(mode: mode)
      XCTAssertThrowsError(try legacyFailureEvent.handle(.confirmedFailure(failure)))
      XCTAssertEqual(
        legacyFailureEvent.invariantViolations.last?.kind,
        .resumeMarkerEvidenceMismatch
      )

      var legacyUnknownEvent = try makeResumeMarkerMachine(mode: mode)
      XCTAssertThrowsError(try legacyUnknownEvent.handle(.externalOutcomeOrIdentityUnknown))
      XCTAssertEqual(
        legacyUnknownEvent.invariantViolations.last?.kind,
        .resumeMarkerEvidenceMismatch
      )
    }
  }

  // TEST-AC-JOB-001-06 / cancellationContract
  func testTEST_AC_JOB_001_06_NormalCancellationUsesTheSafeBoundaryPath() throws {
    var machine = try makeRunningMachine()
    let step = try makeHostStep(id: "hash-for-cancellation")
    _ = try machine.authorizeDispatch(of: step)
    XCTAssertEqual(machine.activeStep?.cancellation, .immediate)

    for invalidStepId in [nil, "different-step"] as [String?] {
      XCTAssertThrowsError(
        try machine.handle(.cancellationRequested(activeStepId: invalidStepId)))
      XCTAssertEqual(machine.state, .running)
      XCTAssertEqual(machine.activeStep?.id, step.id)
      XCTAssertEqual(machine.invariantViolations.last?.kind, .activeStepMismatch)
    }

    let requested = try machine.handle(.cancellationRequested(activeStepId: step.id))
    XCTAssertEqual(machine.state, .cancelRequested)
    XCTAssertTrue(requested.directives.contains(.persistCancellationRequest))

    try machine.handle(.cancellationAcknowledged)
    XCTAssertEqual(machine.state, .cancellingAtSafeBoundary)
    let cancelled = try machine.handle(.safeBoundaryReached)
    XCTAssertTrue(cancelled.directives.contains(.persistCancellationOutcomeAndSafeBoundary))
    XCTAssertEqual(machine.state, .cancelled)
    XCTAssertNil(machine.activeStep)
  }

  // TEST-AC-JOB-003-01 / criticalCancellationContract
  func testTEST_AC_JOB_003_01_CriticalCancellationNeverForceTerminatesCurrentProcess() throws {
    var machine = try makeRunningMachine()
    let flash = try makeFlashStep()
    _ = try machine.authorizeDispatch(of: flash)
    XCTAssertEqual(machine.activeStep?.cancellation, .criticalNonInterruptible)

    let requested = try machine.handle(
      .cancellationRequested(activeStepId: flash.id)
    )

    XCTAssertEqual(machine.state, .cancelRequested)
    XCTAssertTrue(requested.directives.contains(.persistCancellationRequest))
    XCTAssertTrue(requested.directives.contains(.waitForProviderSafeBoundary))
    XCTAssertTrue(requested.directives.contains(.mustNotForceTerminateCurrentProcess))

    try machine.handle(.cancellationAcknowledged)
    XCTAssertEqual(machine.state, .cancellingAtSafeBoundary)
  }

  func testCriticalCancellationCannotUseMissingOrMismatchedStepIdentity() throws {
    let flash = try makeFlashStep()
    for invalidStepId in [nil, "different-step"] as [String?] {
      var machine = try makeRunningMachine()
      _ = try machine.authorizeDispatch(of: flash)

      XCTAssertThrowsError(try machine.handle(.cancellationRequested(activeStepId: invalidStepId)))
      XCTAssertEqual(machine.state, .running)
      XCTAssertEqual(machine.activeStep?.id, flash.id)
      XCTAssertEqual(machine.invariantViolations.last?.kind, .activeStepMismatch)
    }
  }

  // TEST-AC-JOB-004-01 / compensationFaultInjection
  func testTEST_AC_JOB_004_01_CompensationFailureDoesNotReplaceCaptureFailure() throws {
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
    XCTAssertEqual(plan.map(\.descriptor.id), ["stop-capture", "restore-parameter"])

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

    XCTAssertEqual(report.originalFailure, captureFailure)
    XCTAssertEqual(report.compensationFailures, [restoreFailure])
    XCTAssertTrue(report.needsAttention)
  }

  func testCompensationTriggersApplyToExactlyTheirDeclaredTerminalPaths() throws {
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

    XCTAssertEqual(
      CompensationPlanner.plan(completedStepsInExecutionOrder: completed, terminalPath: .success)
        .map(\.descriptor.id),
      ["any", "success"])
    XCTAssertEqual(
      CompensationPlanner.plan(completedStepsInExecutionOrder: completed, terminalPath: .failure)
        .map(\.descriptor.id),
      ["any", "failure"])
    XCTAssertEqual(
      CompensationPlanner.plan(completedStepsInExecutionOrder: completed, terminalPath: .cancel)
        .map(\.descriptor.id),
      ["any", "cancel"])
  }

  func testPlanOnlyRejectsMutationDispatchWithoutChangingState() throws {
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

    XCTAssertEqual(mutation.effect, .deviceMutation)
    XCTAssertThrowsError(try machine.authorizeDispatch(of: mutation))
    XCTAssertEqual(machine.state, .planning)
    XCTAssertEqual(machine.invariantViolations.last?.kind, .planOnlyMutationDispatch)
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
    XCTAssertEqual(machine.state, .resumeAtConfirmedSafeBoundary)
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
        XCTFail("\(context) authorized \(step.effect.rawValue) step at resume marker")
      } catch {
        XCTAssertEqual(
          machine.invariantViolations.last?.kind,
          .dispatchNotAllowedInState,
          context
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
    XCTAssertThrowsError(try WorkflowStepDecoder.decodeCoreOrProviderStep(unknownKind)) { error in
      XCTAssertEqual(
        error as? WorkflowStepValidationError,
        .unsupportedKind(rawKind: "provider.rawCommand", assumedEffect: .destructive),
        context
      )
    }
  }

  private func makeWaitingForRecoveryMachine() throws -> JobStateMachine {
    var machine = try makeRunningMachine()
    let outcome = try machine.handle(.externalOutcomeOrIdentityUnknown)
    XCTAssertTrue(outcome.directives.contains(.preserveOutcomeUnknown))
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
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appending(path: "openspec/contracts/\(name)"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func loadContractTransitionPairs() throws -> Set<StateTransitionPair> {
    let contract = try loadContract(named: "journal-event.schema.json")
    let definitions = try XCTUnwrap(contract["$defs"] as? [String: Any])
    let pairDefinition = try XCTUnwrap(definitions["stateTransitionPair"] as? [String: Any])
    let alternatives = try XCTUnwrap(pairDefinition["oneOf"] as? [[String: Any]])

    var pairs: Set<StateTransitionPair> = []
    for alternative in alternatives {
      let properties = try XCTUnwrap(alternative["properties"] as? [String: Any])
      let fromDefinition = try XCTUnwrap(properties["from"] as? [String: Any])
      let toDefinition = try XCTUnwrap(properties["to"] as? [String: Any])
      let fromRawValue = try XCTUnwrap(fromDefinition["const"] as? String)
      let toRawValues = try XCTUnwrap(toDefinition["enum"] as? [String])
      let from = try XCTUnwrap(JobState(rawValue: fromRawValue))

      for toRawValue in toRawValues {
        pairs.insert(
          StateTransitionPair(
            from: from,
            to: try XCTUnwrap(JobState(rawValue: toRawValue))
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
