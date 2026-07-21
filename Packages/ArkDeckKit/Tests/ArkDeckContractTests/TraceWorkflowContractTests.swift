import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

// TASK-TR-002 host-only contract tests. Every fixture below is an in-memory synthetic
// observation; these tests dispatch no device command and claim no adapter provenance.

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
    let availability = TraceParameterPolicy.availability(
      for: parameterName,
      snapshot: .missing)
    XCTAssertFalse(availability.temporaryRestoreAvailable)
    XCTAssertTrue(availability.persistentChangeAvailable)
    XCTAssertTrue(availability.persistentChangeRequiresExplicitConfirmation)

    let temporary = TraceParameterMutationRequest(
      name: parameterName,
      value: "true",
      mode: .temporaryRestore)
    XCTAssertThrowsError(
      try TraceParameterPolicy.authorize(temporary, snapshot: .missing)
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
      try TraceParameterPolicy.authorize(persistent, snapshot: .missing)
    ) { error in
      XCTAssertEqual(error as? TraceParameterPolicyError, .persistentConfirmationRequired)
    }
    let authorized = try TraceParameterPolicy.authorize(
      persistent,
      snapshot: .missing,
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
    let authorization = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"))
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

    let parameter = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"))
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
    try tracker.begin(partialRelativePath: "artifacts/raw/trace.partial")
    try tracker.recordInterruption()

    XCTAssertEqual(
      tracker.hostArtifactState,
      .partial(relativePath: "artifacts/raw/trace.partial"))
    XCTAssertEqual(tracker.ownedRemoteState, .ownedPresent)
    XCTAssertEqual(tracker.diagnosticCodes, ["trace-receive-interrupted"])
    XCTAssertThrowsError(
      try tracker.makeCleanupStep(
        remotePath: "/data/local/tmp/arkdeck/job-1/raw.trace",
        ownershipEvidenceID: "job-1")
    ) { error in
      XCTAssertEqual(error as? TraceReceiveTrackerError, .cleanupNotEligible)
    }
    print(
      "TEST-AC-TRACE-006-01 PASS host_state=partial owned_remote=retained "
        + "early_cleanup=false real_device=0")
  }

  // TEST-AC-TRACE-008-01 progressContract
  func testTEST_AC_TRACE_008_01_UnknownTotalIsIndeterminateWithElapsedAndNoPercentage() {
    let report = TraceProgressReport.make(
      stage: .capture,
      completedBytes: 9_999,
      total: .unknown,
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

  func testTypedPlanUsesCatalogStepsIsolationValidationCleanupAndRestoreOrdering() throws {
    let capabilities = TraceAdapterCapabilities(
      supportedTags: ["sched"],
      reliableByteTotalAvailable: false,
      supportsTypedStop: true)
    let snapshotPlan = try TraceParameterSnapshotPlanBuilder.makePlan(
      parameterNames: [parameterName])
    XCTAssertEqual(snapshotPlan.steps.map(\.kind), [.snapshotParameter])
    let parameterAuthorization = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"))
    let setupPlan = try TraceParameterSetupPlanBuilder.makePlan(
      mutations: [parameterAuthorization])
    XCTAssertEqual(
      setupPlan.steps.map(\.kind),
      [.requestConfirmation, .setParameter])
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
    XCTAssertEqual(plan.hostPartialRelativePath, "artifacts/raw/trace-raw.partial")
    XCTAssertEqual(
      plan.steps.map(\.kind),
      [
        .captureRemoteFile, .receiveFile, .verifyArtifact, .hashFile, .postprocessArtifact,
        .cleanupOwnedRemotePath, .restoreParameter,
      ])
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
    XCTAssertLessThan(
      try XCTUnwrap(plan.steps.firstIndex { $0.kind == .verifyArtifact }),
      try XCTUnwrap(plan.steps.firstIndex { $0.kind == .cleanupOwnedRemotePath }))
    XCTAssertEqual(
      try TraceRebootPlanBuilder.makePlan().steps.map(\.kind),
      [.rebootDevice, .waitForDisconnect, .waitForReconnect])
  }

  func testCaptureGateRejectsMissingParameterVerification() throws {
    let expected = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"))
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
    let authorization = try TraceParameterPolicy.authorize(
      TraceParameterMutationRequest(
        name: parameterName,
        value: "true",
        mode: .temporaryRestore),
      snapshot: .value("false"))
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

  func testVerifiedReceivePublishesAtomicallyBeforeCleanupBecomesEligible() throws {
    var tracker = TraceReceiveTracker()
    try tracker.begin(partialRelativePath: "artifacts/raw/trace.partial")
    let hash = String(repeating: "a", count: 64)
    XCTAssertTrue(
      try tracker.verifyAndAtomicallyPublish(
        finalRelativePath: "artifacts/raw/trace.raw",
        validation: TraceReceiveValidation(
          byteCount: 128,
          formatRecognized: true,
          checksumMatches: true,
          sha256: hash)))
    XCTAssertEqual(
      tracker.hostArtifactState,
      .published(relativePath: "artifacts/raw/trace.raw", sha256: hash))
    XCTAssertEqual(tracker.ownedRemoteState, .cleanupEligible)
    XCTAssertNoThrow(
      try tracker.makeCleanupStep(
        remotePath: "/data/local/tmp/arkdeck/job-1/raw.trace",
        ownershipEvidenceID: "job-1"))
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

  private func candidate(id: String, key: String) throws -> DeviceRebindCandidate {
    try DeviceRebindCandidate(
      candidateID: id,
      connectKey: key,
      transport: .usb,
      identitySnapshot: DeviceIdentitySnapshot(attributes: [
        "serial": .string("SYNTHETIC-SERIAL"),
        "mode": .string("normal"),
      ]),
      evidence: ["synthetic contract fixture"],
      usbEvidence: USBRebindEvidence(
        serialMatches: true,
        daemonFingerprintMatches: true,
        topologyMatches: true,
        expectedModeMatches: true,
        modelBuildMatches: true))
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
}
