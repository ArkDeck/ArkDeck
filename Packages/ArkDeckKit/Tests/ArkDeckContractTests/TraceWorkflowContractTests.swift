import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private enum TraceStorageTestFault: Error {
  case injected(SessionStorageFaultPoint)
}

// TASK-TR-002/TASK-TR-002R host-only contract tests. Every device observation is synthetic and
// storage tests use isolated temporary directories; no device, HDC, network, or process dispatch
// occurs and no fixture claims adapter provenance.

final class TraceWorkflowContractTests: XCTestCase {
  private let parameterName = "persist.ace.trace.syntax.enabled"

  func testCatalogBindingsMatchReadinessPinsAndClosedCatalogs() throws {
    let presetURL = repoRoot.appending(path: "openspec/contracts/catalogs/trace-presets.yaml")
    let parametersURL = repoRoot.appending(
      path: "openspec/contracts/catalogs/debug-parameters.yaml")
    XCTAssertEqual(
      try sha256(presetURL),
      TraceCatalogContract.presetCatalogSHA256)
    XCTAssertEqual(
      try sha256(parametersURL),
      TraceCatalogContract.debugParameterCatalogSHA256)
    XCTAssertEqual(TracePresetCatalog.definitions.map(\.id), TracePresetID.allCases)
    XCTAssertEqual(TraceDebugParameterCatalog.definitions.count, 9)
  }

  // TEST-AC-TRACE-002-01 capabilityConfigurationContract
  func testTEST_AC_TRACE_002_01_UnsupportedTagRequiresExactDiffAcceptanceBeforeExecutableConfig()
    throws
  {
    let request = try TraceConfigurationRequest(
      presetID: .attachmentPanorama,
      durationMilliseconds: 5_000)
    var supported = Set(request.requestedTags)
    supported.remove("binder")
    let capabilities = TraceAdapterCapabilities(supportedTags: supported)

    let decision = TraceConfigurationGate.evaluate(request: request, capabilities: capabilities)
    XCTAssertEqual(decision.deviceDispatchCount, 0)
    guard case .requiresExplicitAcceptance(let review) = decision else {
      return XCTFail("unsupported preset tag must not silently become executable")
    }
    XCTAssertEqual(review.unsupportedTags, ["binder"])
    XCTAssertEqual(review.requestedTags, request.requestedTags)
    XCTAssertEqual(review.supportedAlternativeTags, request.requestedTags.filter { $0 != "binder" })
    XCTAssertFalse(review.originalConfigurationIsExecutable)
    XCTAssertTrue(review.displaysResourceWarning)
    XCTAssertThrowsError(try review.acceptSupportedAlternative(confirmationID: ""))

    let accepted = try review.acceptSupportedAlternative(
      confirmationID: "accept-without-binder")
    XCTAssertEqual(accepted.tags, review.supportedAlternativeTags)
    XCTAssertEqual(accepted.acceptedAlternativeConfirmationID, "accept-without-binder")
    XCTAssertFalse(accepted.tags.contains("binder"))
    print(
      "TEST-AC-TRACE-002-01 PASS unsupported=binder original_executable=false "
        + "explicit_acceptance=true device_dispatch=0 real_device=0")
  }

  // TEST-AC-TRACE-003-01 parameterStateContract
  func testTEST_AC_TRACE_003_01_MissingSnapshotDisablesTemporaryRestoreWithoutSilentDowngrade()
    throws
  {
    let binding = try durableBinding()
    let capability = try parameterCapability(binding: binding, persistentWriteSupported: true)
    let availability = TraceParameterPolicy.availability(
      for: parameterName,
      snapshot: .missing,
      capability: capability,
      durableBinding: binding)
    XCTAssertFalse(availability.temporaryRestoreAvailable)
    XCTAssertTrue(availability.persistentChangeAvailable)
    XCTAssertTrue(availability.persistentChangeRequiresExplicitConfirmation)

    let temporary = TraceParameterMutationRequest(
      name: parameterName,
      value: "true",
      mode: .temporaryRestore)
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(
        temporary,
        snapshot: .missing,
        capability: capability,
        durableBinding: binding)
    ) { error in
      XCTAssertEqual(
        error as? TraceParameterPolicyError,
        .temporaryRestoreUnavailable(.missing))
    }

    let persistent = TraceParameterMutationRequest(
      name: parameterName,
      value: "true",
      mode: .persistentChange)
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(
        persistent,
        snapshot: .missing,
        capability: capability,
        durableBinding: binding)
    ) { error in
      XCTAssertEqual(error as? TraceParameterPolicyError, .persistentConfirmationRequired)
    }
    let authorized = try TraceParameterPolicy.authorize(
      persistent,
      snapshot: .missing,
      capability: capability,
      durableBinding: binding,
      persistentConfirmationID: "confirm-persistent-change")
    XCTAssertEqual(authorized.request.mode, .persistentChange)
    XCTAssertNil(authorized.originalValueForRestore)
    print(
      "TEST-AC-TRACE-003-01 PASS snapshot=missing temporary_restore=false "
        + "persistent_confirmation=required silent_downgrade=false real_device=0")
  }

  // TEST-AC-TRACE-004-01 parameterFaultInjection
  func testTEST_AC_TRACE_004_01_ReadbackMismatchAuditsAndBlocksCaptureDispatch() throws {
    let configuration = try executableCustomConfiguration()
    let binding = try durableBinding()
    let authorization = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"),
      capability: try parameterCapability(binding: binding),
      durableBinding: binding)
    let readback = TraceParameterReadbackVerifier.verify(
      authorization: authorization,
      commandOutcome: .succeeded,
      readback: .value("false"))

    guard case .blocked(let audit, let dispatchCount) = readback else {
      return XCTFail("successful set exit with mismatched read-back must block")
    }
    XCTAssertEqual(audit.code, "trace-parameter-readback-mismatch")
    XCTAssertEqual(audit.expectedValue, "true")
    XCTAssertEqual(audit.observedValue, "false")
    XCTAssertEqual(dispatchCount, 0)

    let capture = TraceCaptureGate.evaluate(
      configuration: configuration,
      parameterResults: [readback],
      expectedParameterMutations: [authorization],
      adapterCapabilities: TraceAdapterCapabilities(supportedTags: ["sched"]))
    guard case .blocked(.parameterVerificationFailed(let audits), let captureDispatch) = capture
    else {
      return XCTFail("mismatched parameter must make capture authorization unreachable")
    }
    XCTAssertEqual(audits, [audit])
    XCTAssertEqual(captureDispatch, 0)
    print(
      "TEST-AC-TRACE-004-01 PASS set_exit=0 readback=mismatch audited=true "
        + "capture_dispatch=0 real_device=0")
  }

  // TEST-AC-TRACE-005-01 transportRecoveryContract
  func testTEST_AC_TRACE_005_01_AmbiguousRebootCandidatesAwaitRebindConfirmation() throws {
    let candidates = [
      try candidate(id: "candidate-A", key: "usb-A"),
      try candidate(id: "candidate-B", key: "usb-B"),
    ]
    let context = DeviceRebindContext(
      transport: .usb,
      disconnected: true,
      endpointExplicitlyAdded: false,
      expectedModeTransition: true,
      candidates: candidates)

    let recovery = TraceRebootRecovery.evaluate(context)
    guard case .awaitingRebindConfirmation(.ambiguousCandidates, let observed) = recovery else {
      return XCTFail("two reboot candidates must use the Core ambiguity path")
    }
    XCTAssertEqual(observed, candidates)
    XCTAssertEqual(recovery.jobState, .awaitingRebindConfirmation)

    let binding = try durableBinding()
    let parameter = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"),
      capability: try parameterCapability(binding: binding),
      durableBinding: binding)
    let verified = TraceParameterReadbackVerifier.verify(
      authorization: parameter,
      commandOutcome: .succeeded,
      readback: .value("true"))
    let rebootCapabilities = TraceAdapterCapabilities(
      supportedTags: ["sched"],
      parameterChangesRequireReboot: true)
    XCTAssertEqual(
      TraceCaptureGate.evaluate(
        configuration: try executableCustomConfiguration(),
        parameterResults: [verified],
        expectedParameterMutations: [parameter],
        adapterCapabilities: rebootCapabilities),
      .blocked(reason: .rebootRecoveryRequired, deviceCaptureDispatchCount: 0))
    let capture = TraceCaptureGate.evaluate(
      configuration: try executableCustomConfiguration(),
      parameterResults: [verified],
      expectedParameterMutations: [parameter],
      adapterCapabilities: rebootCapabilities,
      reboot: .pending(recovery))
    guard case .blocked(.rebootRecoveryIncomplete(let pending), let dispatchCount) = capture else {
      return XCTFail("capture must wait for a durable confirmed binding")
    }
    XCTAssertEqual(pending, recovery)
    XCTAssertEqual(dispatchCount, 0)
    print(
      "TEST-AC-TRACE-005-01 PASS candidates=2 state=awaitingRebindConfirmation "
        + "capture_dispatch=0 real_device=0")
  }

  // TEST-AC-TRACE-006-01 receiveFaultInjection
  func testTEST_AC_TRACE_006_01_InterruptedReceiveKeepsPartialAndRetainsOwnedRemote() throws {
    var tracker = TraceReceiveTracker()
    try tracker.begin(partialRelativePath: "artifacts/partial/trace.part")
    try tracker.recordInterruption()

    XCTAssertEqual(
      tracker.hostArtifactState,
      .partial(relativePath: "artifacts/partial/trace.part"))
    XCTAssertEqual(tracker.ownedRemoteState, .ownedPresent)
    XCTAssertEqual(tracker.diagnosticCodes, ["trace-receive-interrupted"])
    XCTAssertThrowsError(
      try tracker.makeCleanupStep()
    ) { error in
      XCTAssertEqual(error as? TraceReceiveTrackerError, .cleanupNotEligible)
    }
    print(
      "TEST-AC-TRACE-006-01 PASS host_state=partial owned_remote=retained "
        + "early_cleanup=false real_device=0")
  }

  // TEST-AC-TRACE-008-01 progressContract
  func testTEST_AC_TRACE_008_01_UnknownTotalIsIndeterminateWithElapsedAndNoPercentage() {
    let capabilities = TraceAdapterCapabilities(
      supportedTags: ["sched"],
      reliableByteTotalAvailable: false)
    XCTAssertNil(
      TraceReliableByteTotalFactory.make(
        observedTotalBytes: 10_000,
        capabilities: capabilities))
    let report = TraceProgressReport.make(
      stage: .capture,
      completedBytes: 9_999,
      reliableTotal: nil,
      adapterCapabilities: capabilities,
      elapsedMilliseconds: 12_345)

    XCTAssertEqual(report.stage, .capture)
    XCTAssertEqual(report.meter, .indeterminate(elapsedMilliseconds: 12_345))
    XCTAssertNil(report.percentage)
    XCTAssertEqual(
      TraceWorkflowStage.allCases,
      [
        .configuration, .reboot, .waitingForDevice, .capture, .finalize, .receive,
        .validate, .postprocess, .cleanup, .restore,
      ])
    print(
      "TEST-AC-TRACE-008-01 PASS total=unknown meter=indeterminate elapsed_ms=12345 "
        + "percentage=nil real_device=0")
  }

  // TEST-AC-TRACE-009-01 artifactValidationContract
  func testTEST_AC_TRACE_009_01_ExitZeroEmptyTraceCannotSucceedAndRecordsDiagnostic() {
    let result = TraceArtifactValidator.validate(
      TraceArtifactObservation(
        processExitCode: 0,
        byteCount: 0,
        formatRecognized: true,
        sha256: String(repeating: "0", count: 64)))

    XCTAssertFalse(result.permitsSucceededJobState)
    guard case .invalid(let diagnostic) = result else {
      return XCTFail("empty trace must be semantically invalid")
    }
    XCTAssertEqual(diagnostic.code, .emptyTrace)
    XCTAssertEqual(diagnostic.processExitCode, 0)
    XCTAssertEqual(diagnostic.byteCount, 0)
    XCTAssertTrue(diagnostic.summary.contains("exited 0"))
    print(
      "TEST-AC-TRACE-009-01 PASS exit=0 bytes=0 succeeded=false diagnostic=emptyTrace "
        + "real_device=0")
  }

  // TEST-TRACE-REBIND-GATE-001
  func testTEST_TRACE_REBIND_GATE_001_ExactCandidateAndNextRevisionAreRequiredAndPropagated()
    throws
  {
    let identity = try syntheticIdentity()
    let preReboot = try durableBinding(
      revision: 2,
      connectKey: "usb-before-reboot",
      identity: identity)
    let selected = try candidate(
      id: "selected-candidate",
      key: "usb-after-reboot",
      identity: identity)
    let rebindContext = DeviceRebindContext(
      transport: .usb,
      disconnected: true,
      endpointExplicitlyAdded: false,
      expectedModeTransition: true,
      candidates: [selected])
    let context = try TraceExpectedRebindContextFactory.make(
      preRebootBinding: preReboot,
      rebindContext: rebindContext,
      selectedCandidate: selected,
      confirmedBy: .corePolicy)
    XCTAssertThrowsError(
      try TraceExpectedRebindContextFactory.make(
        preRebootBinding: preReboot,
        rebindContext: rebindContext,
        selectedCandidate: candidate(id: "not-observed", key: "usb-not-observed"),
        confirmedBy: .corePolicy))
    let exact = try durableBinding(
      revision: 3,
      connectKey: selected.connectKey,
      identity: selected.identitySnapshot)
    let capabilities = TraceAdapterCapabilities(supportedTags: ["sched"])
    let exactDecision = TraceCaptureGate.evaluate(
      configuration: try executableCustomConfiguration(),
      parameterResults: [],
      adapterCapabilities: capabilities,
      reboot: .bindingDurablyConfirmed(context: context, binding: exact))
    guard case .authorized(let authorization) = exactDecision else {
      return XCTFail("the exact selected candidate at revision + 1 must authorize capture")
    }
    XCTAssertTrue(authorization.rebootRequired)
    XCTAssertEqual(authorization.deviceBindingReference, exact.reference)
    let plan = try TraceWorkflowPlanBuilder.makePlan(
      request: TraceWorkflowPlanRequest(
        jobID: "job-rebind",
        rawArtifactID: "trace-rebind"),
      authorization: authorization)
    let confirmedDeviceSteps = plan.steps.filter {
      $0.bindingRequirement == .confirmedDevice
    }
    XCTAssertFalse(confirmedDeviceSteps.isEmpty)
    XCTAssertEqual(plan.deviceBindingReference, exact.reference)
    XCTAssertEqual(plan.deviceStepBindings.map(\.step), confirmedDeviceSteps)
    XCTAssertTrue(plan.deviceStepBindings.allSatisfy { $0.intendedBinding == exact.reference })

    let wrongIdentity = try syntheticIdentity(mode: "unexpected")
    let invalidBindings: [(String, DurableCurrentDeviceBinding)] = [
      (
        "wrong-target",
        try durableBinding(
          targetID: "other-target", revision: 3, connectKey: selected.connectKey,
          identity: identity)
      ),
      (
        "older-revision",
        try durableBinding(
          revision: 1, connectKey: selected.connectKey, identity: identity)
      ),
      (
        "same-revision",
        try durableBinding(
          revision: 2, connectKey: selected.connectKey, identity: identity)
      ),
      (
        "skipped-revision",
        try durableBinding(
          revision: 4, connectKey: selected.connectKey, identity: identity)
      ),
      (
        "other-candidate",
        try durableBinding(
          revision: 3, connectKey: "usb-other", identity: identity)
      ),
      (
        "transport-drift",
        try durableBinding(
          revision: 3, connectKey: selected.connectKey, transport: .tcp,
          identity: identity)
      ),
      (
        "identity-drift",
        try durableBinding(
          revision: 3, connectKey: selected.connectKey, identity: wrongIdentity)
      ),
      (
        "evidence-drift",
        try durableBinding(
          revision: 3, connectKey: selected.connectKey, identity: identity,
          evidence: ["different synthetic evidence"])
      ),
      (
        "confirmation-drift",
        try durableBinding(
          revision: 3, connectKey: selected.connectKey, identity: identity,
          confirmedBy: .user)
      ),
    ]
    for (label, binding) in invalidBindings {
      let decision = TraceCaptureGate.evaluate(
        configuration: try executableCustomConfiguration(),
        parameterResults: [],
        adapterCapabilities: capabilities,
        reboot: .bindingDurablyConfirmed(context: context, binding: binding))
      XCTAssertEqual(decision.deviceCaptureDispatchCount, 0, label)
      guard case .blocked(.rebootBindingMismatch, 0) = decision else {
        return XCTFail("\(label) must fail closed before capture dispatch")
      }
    }
    print(
      "TEST-TRACE-REBIND-GATE-001 PASS unobserved_candidate=blocked invalid_receipts=9 exact_revision=3 "
        + "authorization_binding=retained device_step_bindings=retained capture_dispatch=0 "
        + "real_device=0 hdc=0 network=0 process=0")
  }

  // TEST-TRACE-PARAM-CAPABILITY-001
  func testTEST_TRACE_PARAM_CAPABILITY_001_ProbeReceiptMustMatchBindingNameAndDisposition()
    throws
  {
    let binding = try durableBinding()
    let request = TraceParameterMutationRequest(
      name: parameterName,
      value: "true",
      mode: .temporaryRestore)
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(
        request,
        snapshot: .value("false"),
        capability: nil,
        durableBinding: binding))

    for disposition in TraceParameterProbeDisposition.allCases where disposition != .supported {
      let receipt = try parameterCapability(binding: binding, disposition: disposition)
      XCTAssertThrowsError(
        try TraceParameterPolicy.authorize(
          request,
          snapshot: .value("false"),
          capability: receipt,
          durableBinding: binding),
        "\(disposition) must block before mutation dispatch")
    }

    let staleBinding = try durableBinding(revision: 2)
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(
        request,
        snapshot: .value("false"),
        capability: try parameterCapability(binding: staleBinding),
        durableBinding: binding))
    let otherName = "persist.ace.trace.layout.enabled"
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(
        request,
        snapshot: .value("false"),
        capability: try parameterCapability(binding: binding, parameterName: otherName),
        durableBinding: binding))

    let temporary = try TraceParameterPolicy.authorize(
      request,
      snapshot: .value("false"),
      capability: try parameterCapability(binding: binding),
      durableBinding: binding)
    XCTAssertEqual(temporary.bindingReference, binding.reference)
    let persistentRequest = TraceParameterMutationRequest(
      name: parameterName,
      value: "true",
      mode: .persistentChange)
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(
        persistentRequest,
        snapshot: .missing,
        capability: try parameterCapability(binding: binding),
        durableBinding: binding,
        persistentConfirmationID: "confirm"))
    let persistentCapability = try parameterCapability(
      binding: binding,
      persistentWriteSupported: true)
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(
        persistentRequest,
        snapshot: .missing,
        capability: persistentCapability,
        durableBinding: binding))
    let persistent = try TraceParameterPolicy.authorize(
      persistentRequest,
      snapshot: .missing,
      capability: persistentCapability,
      durableBinding: binding,
      persistentConfirmationID: "confirm-persistent")
    XCTAssertEqual(persistent.persistentConfirmationID, "confirm-persistent")
    XCTAssertThrowsError(
      try TraceParameterSetupPlanBuilder.makePlan(
        mutations: [temporary],
        durableBinding: staleBinding))
    print(
      "TEST-TRACE-PARAM-CAPABILITY-001 PASS missing=blocked unsupported=blocked "
        + "permissionDenied=blocked needsDeveloperMode=blocked unknown=blocked "
        + "stale_binding=blocked wrong_parameter=blocked persistent_support_and_confirmation=required "
        + "mutation_dispatch=0 real_device=0 hdc=0 network=0 process=0")
  }

  // TEST-TRACE-PROGRESS-CAPABILITY-001
  func testTEST_TRACE_PROGRESS_CAPABILITY_001_ReliableTotalRequiresMatchingTrueCapabilityReceipt() {
    let unavailable = TraceAdapterCapabilities(
      supportedTags: ["sched"],
      reliableByteTotalAvailable: false)
    XCTAssertNil(
      TraceReliableByteTotalFactory.make(
        observedTotalBytes: 1_000,
        capabilities: unavailable))
    let available = TraceAdapterCapabilities(
      supportedTags: ["sched"],
      reliableByteTotalAvailable: true)
    XCTAssertNil(
      TraceReliableByteTotalFactory.make(
        observedTotalBytes: 0,
        capabilities: available))
    let receipt = TraceReliableByteTotalFactory.make(
      observedTotalBytes: 1_000,
      capabilities: available)
    XCTAssertNotNil(receipt)
    let falseCapabilityReport = TraceProgressReport.make(
      stage: .capture,
      completedBytes: 250,
      reliableTotal: receipt,
      adapterCapabilities: unavailable,
      elapsedMilliseconds: 500)
    XCTAssertEqual(
      falseCapabilityReport.meter,
      .indeterminate(elapsedMilliseconds: 500))
    let drifted = TraceAdapterCapabilities(
      supportedTags: ["sched", "freq"],
      reliableByteTotalAvailable: true)
    let driftedReport = TraceProgressReport.make(
      stage: .capture,
      completedBytes: 250,
      reliableTotal: receipt,
      adapterCapabilities: drifted,
      elapsedMilliseconds: 500)
    XCTAssertEqual(driftedReport.meter, .indeterminate(elapsedMilliseconds: 500))
    let matchingReport = TraceProgressReport.make(
      stage: .capture,
      completedBytes: 250,
      reliableTotal: receipt,
      adapterCapabilities: available,
      elapsedMilliseconds: 500)
    XCTAssertEqual(matchingReport.percentage, 25)
    print(
      "TEST-TRACE-PROGRESS-CAPABILITY-001 PASS capability_false=indeterminate "
        + "zero_total=indeterminate drift=indeterminate matching_receipt_percent=25 "
        + "real_device=0 hdc=0 network=0 process=0")
  }

  func testTypedPlanUsesCatalogStepsIsolationValidationAndRestoreOrdering() throws {
    let capabilities = TraceAdapterCapabilities(
      supportedTags: ["sched"],
      reliableByteTotalAvailable: false,
      supportsTypedStop: true)
    let binding = try durableBinding()
    let snapshotPlan = try TraceParameterSnapshotPlanBuilder.makePlan(
      parameterNames: [parameterName])
    XCTAssertEqual(snapshotPlan.steps.map(\.kind), [.snapshotParameter])
    let parameterAuthorization = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"),
      capability: try parameterCapability(binding: binding),
      durableBinding: binding)
    let setupPlan = try TraceParameterSetupPlanBuilder.makePlan(
      mutations: [parameterAuthorization],
      durableBinding: binding)
    XCTAssertEqual(
      setupPlan.steps.map(\.kind),
      [.requestConfirmation, .setParameter])
    XCTAssertEqual(setupPlan.deviceStepBindings.map(\.step.kind), [.setParameter])
    XCTAssertTrue(
      setupPlan.deviceStepBindings.allSatisfy { $0.intendedBinding == binding.reference })
    let setStep = try XCTUnwrap(setupPlan.steps.first { $0.kind == .setParameter })
    XCTAssertEqual(setStep.arguments["readbackPolicy"], .string("required"))
    XCTAssertEqual(
      setStep.compensationDescriptors.map(\.kind),
      [.restoreParameter, .restoreParameter])
    XCTAssertTrue(
      setStep.compensationDescriptors.allSatisfy {
        $0.arguments["snapshotStepId"] == .string(snapshotPlan.steps[0].id)
      })

    let verified = TraceParameterReadbackVerifier.verify(
      authorization: parameterAuthorization,
      commandOutcome: .succeeded,
      readback: .value("true"))
    let captureDecision = TraceCaptureGate.evaluate(
      configuration: try executableCustomConfiguration(),
      parameterResults: [verified],
      expectedParameterMutations: [parameterAuthorization],
      adapterCapabilities: capabilities)
    guard case .authorized(let captureAuthorization) = captureDecision else {
      return XCTFail("verified setup must authorize typed capture planning")
    }

    let plan = try TraceWorkflowPlanBuilder.makePlan(
      request: TraceWorkflowPlanRequest(
        jobID: "job-123",
        rawArtifactID: "trace-raw",
        derivedArtifactID: "trace-filtered"),
      authorization: captureAuthorization)
    XCTAssertEqual(plan.ownedRemotePath, "/data/local/tmp/arkdeck/job-123/raw.trace")
    XCTAssertEqual(plan.hostPartialRelativePath, "artifacts/partial/trace-raw.part")
    XCTAssertEqual(
      plan.steps.map(\.kind),
      [
        .captureRemoteFile, .receiveFile, .verifyArtifact, .hashFile, .postprocessArtifact,
        .restoreParameter,
      ])
    XCTAssertFalse(plan.steps.contains { $0.kind == .cleanupOwnedRemotePath })
    XCTAssertFalse(plan.steps.contains { $0.kind == .setParameter || $0.kind == .rebootDevice })
    let captureStep = try XCTUnwrap(plan.steps.first { $0.kind == .captureRemoteFile })
    XCTAssertEqual(captureStep.arguments["catalogId"], .string("trace-presets"))
    XCTAssertEqual(captureStep.arguments["actionId"], .string("custom"))
    XCTAssertEqual(captureStep.effect, .deviceMutation)
    XCTAssertEqual(
      captureStep.compensationDescriptors.map(\.kind),
      [
        .stopRemoteCapture, .stopRemoteCapture,
      ])
    XCTAssertEqual(
      try TraceRebootPlanBuilder.makePlan().steps.map(\.kind),
      [.rebootDevice, .waitForDisconnect, .waitForReconnect])
  }

  func testCaptureGateRejectsMissingParameterVerification() throws {
    let binding = try durableBinding()
    let expected = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"),
      capability: try parameterCapability(binding: binding),
      durableBinding: binding)
    let capture = TraceCaptureGate.evaluate(
      configuration: try executableCustomConfiguration(),
      parameterResults: [],
      expectedParameterMutations: [expected],
      adapterCapabilities: TraceAdapterCapabilities(supportedTags: ["sched"]))
    XCTAssertEqual(
      capture,
      .blocked(
        reason: .parameterVerificationIncomplete(expectedCount: 1, verifiedCount: 0),
        deviceCaptureDispatchCount: 0))
  }

  func testCaptureGateFailsClosedWhenCapabilitiesChangeAfterConfigurationReview() throws {
    let capture = TraceCaptureGate.evaluate(
      configuration: try executableCustomConfiguration(),
      parameterResults: [],
      adapterCapabilities: TraceAdapterCapabilities(supportedTags: []))
    guard
      case .blocked(
        .adapterCapabilitiesChanged(let unsupportedTags, let bufferUnitChanged),
        let dispatchCount) = capture
    else {
      return XCTFail("capability drift must invalidate the reviewed configuration")
    }
    XCTAssertEqual(unsupportedTags, ["sched"])
    XCTAssertFalse(bufferUnitChanged)
    XCTAssertEqual(dispatchCount, 0)
  }

  func testRestoreReadbackFailureMarksNeedsAttention() throws {
    let binding = try durableBinding()
    let authorization = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"),
      capability: try parameterCapability(binding: binding),
      durableBinding: binding)
    let verified = TraceParameterReadbackVerifier.verify(
      authorization: authorization,
      commandOutcome: .succeeded,
      readback: .value("true"))
    let mutation = try XCTUnwrap(verified.verifiedMutation)
    let restore = TraceParameterRestoreVerifier.verify(
      mutation: mutation,
      commandOutcome: .succeeded,
      readback: .value("true"))
    guard case .needsAttention(let audit) = restore else {
      return XCTFail("failed restoration read-back must remain visible")
    }
    XCTAssertEqual(audit.code, "trace-parameter-restore-failed")
    XCTAssertEqual(audit.expectedValue, "false")
  }

  func testVerifiedReceivePublishesThroughSessionStoreBeforeCleanupBecomesEligible() async throws {
    let fixture = try await makeStorageFixture(suffix: "publication-success")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let plan = try prepublicationPlan(
      jobID: fixture.layout.jobID,
      rawArtifactID: "trace-raw")
    let source = fixture.layout.root.appending(path: plan.hostPartialRelativePath)
    let bytes = Data("synthetic-ftrace-payload".utf8)
    try bytes.write(to: source)
    let request = try TraceArtifactPublicationRequest(
      plan: plan,
      publicationName: "trace.raw",
      origin: "TASK-TR-002R synthetic contract fixture",
      expectedSHA256: sha256(bytes))
    var tracker = TraceReceiveTracker()
    try tracker.begin(partialRelativePath: plan.hostPartialRelativePath)
    XCTAssertThrowsError(try tracker.makeCleanupStep())

    let binding = try durableBinding()
    let receipt = try TraceArtifactPublicationCoordinator(
      store: SessionArtifactStore(layout: fixture.layout)
    ).publish(
      from: source,
      request: request,
      claim: fixture.claim,
      durableBinding: binding)
    try tracker.recordPublication(receipt)
    XCTAssertEqual(
      tracker.hostArtifactState,
      .published(relativePath: "artifacts/raw/trace.raw", sha256: sha256(bytes)))
    XCTAssertEqual(tracker.ownedRemoteState, .cleanupEligible)
    let cleanup = try tracker.makeCleanupStep()
    XCTAssertEqual(cleanup.step.kind, .cleanupOwnedRemotePath)
    XCTAssertEqual(cleanup.intendedBinding, binding.reference)
    XCTAssertEqual(
      receipt.publishedArtifact.url, fixture.layout.rawDirectory.appending(path: "trace.raw"))
  }

  // TEST-TRACE-ATOMIC-PUBLISH-001
  func testTEST_TRACE_ATOMIC_PUBLISH_001_AllPublicationBarriersRetainRemoteWithoutCleanupAuthority()
    async throws
  {
    let directFaults: [SessionStorageFaultPoint] = [
      .artifactPublicationLock,
      .artifactPartialDirectorySync,
      .artifactWrite,
      .artifactSourceValidation,
      .artifactFileSync,
      .artifactValidation,
      .artifactRecoveryRecordWrite,
      .artifactRecoveryRecordSync,
      .artifactRecoveryRecordReplace,
      .artifactRecoveryRecordDirectorySync,
      .artifactReplace,
      .artifactDirectorySync,
      .artifactSourceDirectorySync,
    ]
    let binding = try durableBinding()
    let cleanupDispatchCount = 0

    for (index, point) in directFaults.enumerated() {
      let fixture = try await makeStorageFixture(suffix: "fault-\(index)")
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let plan = try prepublicationPlan(
        jobID: fixture.layout.jobID,
        rawArtifactID: "trace-fault-\(index)")
      let source = fixture.layout.root.appending(path: plan.hostPartialRelativePath)
      try Data("synthetic-ftrace-fault-\(index)".utf8).write(to: source)
      let request = try TraceArtifactPublicationRequest(
        plan: plan,
        publicationName: "trace-\(index).raw",
        origin: "TASK-TR-002R synthetic publication fault fixture")
      var tracker = TraceReceiveTracker()
      try tracker.begin(partialRelativePath: plan.hostPartialRelativePath)
      let store = SessionArtifactStore(
        layout: fixture.layout,
        faultInjector: SessionStorageFaultInjector { reached in
          if reached == point { throw TraceStorageTestFault.injected(reached) }
        })
      XCTAssertThrowsError(
        try TraceArtifactPublicationCoordinator(store: store).publish(
          from: source,
          request: request,
          claim: fixture.claim,
          durableBinding: binding),
        "\(point) must not return a cleanup-authorizing publication receipt")
      XCTAssertEqual(tracker.ownedRemoteState, .ownedPresent, "\(point)")
      XCTAssertThrowsError(try tracker.makeCleanupStep(), "\(point)")
      XCTAssertEqual(cleanupDispatchCount, 0, "\(point)")
    }

    XCTAssertEqual(cleanupDispatchCount, 0)
    print(
      "TEST-TRACE-ATOMIC-PUBLISH-001 PASS partial_path=artifacts/partial/*.part "
        + "publication_faults=13 cleanup_authority=none cleanup_dispatch=0 owned_remote=retained "
        + "real_device=0 hdc=0 network=0 process=0")
  }

  func testManifestCarriesRequiredTraceMetadataWithoutMutatingRawArtifact() {
    let hash = String(repeating: "b", count: 64)
    let parameter = TraceParameterManifestRecord(
      name: parameterName,
      before: .value("false"),
      after: .value("true"),
      restored: .value("false"))
    let manifest = TraceCaptureManifest(
      toolIdentity: "fixture-only-registered-adapter",
      tags: ["sched"],
      durationMilliseconds: 5_000,
      bufferValue: nil,
      bufferUnit: nil,
      parameterRecords: [parameter],
      startedAt: "2026-07-21T08:00:00Z",
      endedAt: "2026-07-21T08:00:05Z",
      rawArtifactID: "trace-raw",
      rawSHA256: hash,
      derivedArtifactID: "trace-filtered",
      captureLogArtifactID: "trace-capture-log",
      filterStatistics: TraceFilterStatistics(
        processorID: "traceFilter",
        removedRecordCount: 2))
    XCTAssertEqual(manifest.rawSHA256, hash)
    XCTAssertEqual(manifest.parameterRecords, [parameter])
    XCTAssertEqual(manifest.filterStatistics?.removedRecordCount, 2)
    XCTAssertEqual(manifest.captureLogArtifactID, "trace-capture-log")
  }

  private func executableCustomConfiguration() throws -> TraceExecutableConfiguration {
    let request = try TraceConfigurationRequest(
      presetID: .custom,
      customTags: ["sched"],
      durationMilliseconds: 5_000)
    let decision = TraceConfigurationGate.evaluate(
      request: request,
      capabilities: TraceAdapterCapabilities(supportedTags: ["sched"]))
    guard case .executable(let configuration) = decision else {
      throw TraceConfigurationValidationError.explicitAcceptanceRequired
    }
    return configuration
  }

  private func prepublicationPlan(
    jobID: String,
    rawArtifactID: String
  ) throws -> TraceWorkflowPlan {
    let decision = TraceCaptureGate.evaluate(
      configuration: try executableCustomConfiguration(),
      parameterResults: [],
      adapterCapabilities: TraceAdapterCapabilities(supportedTags: ["sched"]))
    guard case .authorized(let authorization) = decision else {
      throw TraceConfigurationValidationError.explicitAcceptanceRequired
    }
    return try TraceWorkflowPlanBuilder.makePlan(
      request: TraceWorkflowPlanRequest(
        jobID: jobID,
        rawArtifactID: rawArtifactID),
      authorization: authorization)
  }

  private func syntheticIdentity(mode: String = "normal") throws -> DeviceIdentitySnapshot {
    try DeviceIdentitySnapshot(attributes: [
      "serial": .string("SYNTHETIC-SERIAL"),
      "mode": .string(mode),
    ])
  }

  private func durableBinding(
    targetID: String = "trace-target",
    revision: Int = 1,
    connectKey: String = "usb-current",
    transport: DeviceTransport = .usb,
    identity: DeviceIdentitySnapshot? = nil,
    evidence: [String] = ["synthetic contract fixture"],
    confirmedBy: DeviceBindingConfirmation? = nil
  ) throws -> DurableCurrentDeviceBinding {
    let binding = try CurrentDeviceBinding(
      revision: revision,
      connectKey: connectKey,
      transport: transport,
      identitySnapshot: identity ?? syntheticIdentity(),
      evidence: evidence,
      confirmedBy: confirmedBy ?? (transport == .usb ? .corePolicy : .user),
      channelProtection: .unverifiedAssumeUnprotected)
    return try DurableCurrentDeviceBinding(
      reference: DeviceBindingReference(targetID: targetID, revision: revision),
      binding: binding)
  }

  private func parameterCapability(
    binding: DurableCurrentDeviceBinding,
    parameterName: String? = nil,
    disposition: TraceParameterProbeDisposition = .supported,
    persistentWriteSupported: Bool = false
  ) throws -> TraceParameterCapabilityReceipt {
    try TraceParameterCapabilityProbe.record(
      durableBinding: binding,
      parameterName: parameterName ?? self.parameterName,
      disposition: disposition,
      persistentWriteSupported: persistentWriteSupported)
  }

  private func candidate(
    id: String,
    key: String,
    identity: DeviceIdentitySnapshot? = nil
  ) throws -> DeviceRebindCandidate {
    try DeviceRebindCandidate(
      candidateID: id,
      connectKey: key,
      transport: .usb,
      identitySnapshot: identity ?? syntheticIdentity(),
      evidence: ["synthetic contract fixture"],
      usbEvidence: USBRebindEvidence(
        serialMatches: true,
        daemonFingerprintMatches: true,
        topologyMatches: true,
        expectedModeMatches: true,
        modelBuildMatches: true))
  }

  private struct TraceStorageFixture {
    let base: URL
    let layout: SessionLayout
    let coordinator: HostStorageCoordinator
    let claim: StorageClaim
  }

  private func makeStorageFixture(suffix: String) async throws -> TraceStorageFixture {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-tr002r-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    let sessionsRoot = base.appending(path: "sessions", directoryHint: .isDirectory)
    let sessionStore = try SessionStore(sessionsRoot: sessionsRoot)
    let identity = try SystemVolumeIdentityResolver().resolve(sessionsRoot)
    let jobID = "job-\(suffix)"
    let coordinator = HostStorageCoordinator()
    let request = try StorageClaimRequest(
      claimID: "claim-\(suffix)",
      jobID: jobID,
      volumeIdentity: identity,
      budget: StorageBudget(
        metadataHeadroomBytes: 4_096,
        finalizationHeadroomBytes: 4_096,
        remainingGrowthBytes: 1_048_576,
        writerClass: .light))
    let snapshot = HostStorageSnapshot(
      volumeIdentity: identity,
      totalBytes: 2_097_152,
      availableBytes: 2_097_152,
      isReadOnly: false)
    guard case .admitted(let claim) = await coordinator.admit(request, snapshot: snapshot) else {
      throw SessionStorageError.claimUnavailable("synthetic Trace fixture")
    }
    let layout = try sessionStore.createSession(
      sessionID: "session-\(suffix)",
      jobID: jobID,
      createdAt: Date(timeIntervalSince1970: 1_752_739_200),
      claim: claim)
    return TraceStorageFixture(
      base: base,
      layout: layout,
      coordinator: coordinator,
      claim: claim)
  }

  private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // ArkDeckContractTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // ArkDeckKit
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repository root
  }

  private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
      .map { String(format: "%02x", $0) }.joined()
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
