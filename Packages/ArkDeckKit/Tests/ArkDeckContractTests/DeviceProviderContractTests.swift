import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class DeviceProviderContractTests: XCTestCase {
  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64),
        serverFacts: ["endpoint": "127.0.0.1:8710"],
        deviceIdentitySHA256: String(repeating: "b", count: 64),
        deviceMode: "hdc", buildFingerprint: "fixture-build",
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private struct RockchipFactsPort: RockchipRuntimeFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "rockchip", toolVersion: "rkdeveloptool ver 1.32",
        toolSHA256: String(repeating: "c", count: 64),
        serverFacts: [
          TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey:
            TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied,
          TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey:
            "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
          TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey: "42",
        ],
        targetID: targetID, bindingRevision: 1,
        deviceIdentitySHA256:
          "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
        executionConnectKey: "150100424a544e4600",
        deviceMode: "hdc", buildFingerprint: nil,
        profileID: "dayu200", collectedAtUTC: "2026-07-30T00:00:00Z")
    }
  }

  private var hdc: HDCObservationProviderAdapter {
    HDCObservationProviderAdapter(factsPort: FactsPort())
  }

  private var context: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-1", stepID: "step-1", targetID: "TGT-1", bindingRevision: 1,
      connectKey: "150100424a544e4600",
      expectedIdentitySHA256:
        "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-29T00:00:00Z")
  }

  func testRegistryHoldsBothProviders() {
    let registry = DeviceProviderRegistry(providers: [
      hdc, RockchipFlashProviderAdapter(factsPort: RockchipFactsPort()),
    ])
    XCTAssertEqual(registry.registeredProviderIDs, ["hdc", "rockchip"])
    XCTAssertNotNil(registry.provider(id: "hdc"))
    XCTAssertNotNil(registry.provider(id: "rockchip"))
    XCTAssertNil(registry.provider(id: "adb"))
  }

  func testRockchipExecutionAdmissionRequiresCrossModeBindingFact() async throws {
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let provider = RockchipFlashProviderAdapter(
      factsPort: RockchipFactsPort(), availability: .available)
    let ready = try await provider.resolveFacts(targetID: "TGT-1")
    XCTAssertNil(provider.executionAdmissionBlocker(for: operation, facts: ready))

    let missingPostflightRoute = ProviderFacts(
      providerID: ready.providerID, toolVersion: ready.toolVersion,
      toolSHA256: ready.toolSHA256,
      serverFacts: [
        TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey:
          TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied
      ], targetID: ready.targetID, bindingRevision: ready.bindingRevision,
      deviceIdentitySHA256: ready.deviceIdentitySHA256,
      executionConnectKey: ready.executionConnectKey,
      deviceMode: ready.deviceMode, buildFingerprint: ready.buildFingerprint,
      profileID: ready.profileID, collectedAtUTC: ready.collectedAtUTC)
    XCTAssertEqual(
      provider.executionAdmissionBlocker(
        for: operation, facts: missingPostflightRoute),
      "flash.postFlashHDCBindingUnprepared: target TGT-1 has no trusted HDC identity "
        + "and USB topology for postflight")

    let unprepared = ProviderFacts(
      providerID: ready.providerID, toolVersion: ready.toolVersion,
      toolSHA256: ready.toolSHA256,
      serverFacts: [
        TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey:
          TargetStoreRockchipRuntimeFactsPort.crossModeBindingUnprepared
      ], targetID: ready.targetID, bindingRevision: ready.bindingRevision,
      deviceIdentitySHA256: ready.deviceIdentitySHA256,
      executionConnectKey: ready.executionConnectKey,
      deviceMode: ready.deviceMode, buildFingerprint: ready.buildFingerprint,
      profileID: ready.profileID, collectedAtUTC: ready.collectedAtUTC)
    XCTAssertEqual(
      provider.executionAdmissionBlocker(for: operation, facts: unprepared),
      "flash.crossModeBindingUnprepared: target TGT-1 is not covered by the durable "
        + "DAYU200 cross-mode binding")
  }

  func testHDCActionMappingIsClosedAndFailClosed() throws {
    let observe = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "observe.device@1"))
    let probeTool = observe.steps.first { $0.kind == .probeHostTool }!
    XCTAssertEqual(
      try hdc.action(for: probeTool, operation: observe, inputs: [:]), .hdc(.observeTool))
    let probeDevice = observe.steps.first { $0.kind == .probeDevice }!
    if case .hdc(.observeDevice) = try hdc.action(for: probeDevice, operation: observe, inputs: [:])
    {
    } else {
      XCTFail("probeDevice must map to observeDevice")
    }
    // T13 (CHG-2026-049) implemented the mutation family, so the failure
    // mode moved rather than disappeared: an install without its declared
    // inputs is still refused, never guessed at.
    let debug = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    let install = debug.steps.first { $0.kind == .installPackage }!
    XCTAssertThrowsError(try hdc.action(for: install, operation: debug, inputs: [:])) { error in
      guard case DeviceProviderError.unsupportedAction(let detail) = error else {
        return XCTFail("expected unsupportedAction, got \(error)")
      }
      XCTAssertTrue(detail.contains("bundleName"), detail)
    }
    // A kind with no registered action at all still fails closed.
    let flash = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let flashStep = flash.steps.first { $0.kind == .flashPartition }!
    XCTAssertThrowsError(try hdc.action(for: flashStep, operation: flash, inputs: [:])) { error in
      guard case DeviceProviderError.unsupportedStepKind = error else {
        return XCTFail("expected unsupportedStepKind, got \(error)")
      }
    }
  }

  func testVerifyIsSemanticNeverExitCode() throws {
    // Exit 0 with unparseable stdout must NOT verify.
    let garbage = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("something else entirely".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    let outcome = try hdc.verify(receipt: garbage, action: .hdc(.observeTool), context: context)
    guard case .unknown = outcome else {
      return XCTFail("exit 0 + garbage must be unknown, got \(outcome)")
    }
    // A parsed registered version verifies.
    let good = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .verified(let summary) = try hdc.verify(
      receipt: good, action: .hdc(.observeTool), context: context)
    else {
      return XCTFail("registered version must verify")
    }
    XCTAssertEqual(summary["toolVersion"], "3.2.0f")
    // Unregistered version: unsupported, fail closed.
    let unknownVersion = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("Ver: 9.9.9x\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .unsupported = try hdc.verify(
      receipt: unknownVersion, action: .hdc(.observeTool), context: context)
    else {
      return XCTFail("unregistered version must be unsupported")
    }
  }

  func testInstallSurfacesBoundedPackageManagerRejectionButStillRequiresReadbackForSuccess()
    throws
  {
    let artifactID = "ART-0123456789abcdef0123456789abcdef"
    let staged = try hdc.mintStagedArtifact(
      jobID: "job-1", stepID: "send-hap",
      artifactLeaseID: "lease-v1:job-input:\(artifactID)",
      expectedSHA256: String(repeating: "c", count: 64))
    let bundle = try HDCBundleReference(bundleName: "com.example.demo")
    let action = TypedProviderAction.hdc(.installPackage(staged, bundle: bundle))

    let rejected = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("error: install failed: incompatible api".utf8),
      stderr: Data(), stdoutTruncated: false, durationSeconds: 0.1)
    guard case .failed(let code, let detail) = try hdc.verify(
      receipt: rejected, action: action, context: context)
    else {
      return XCTFail("package-manager rejection must fail before readback")
    }
    XCTAssertEqual(code, "installRejected")
    XCTAssertTrue(detail.contains("outBytes=39"), detail)
    XCTAssertTrue(detail.contains("outHex=6572726f723a"), detail)
    XCTAssertFalse(detail.contains("incompatible api"), detail)

    let unauthorized = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data(
        "error: failed to install bundle.\ncode:9568423\n"
          .appending("error: the device is unauthorized\n").utf8),
      stderr: Data(), stdoutTruncated: false, durationSeconds: 0.1)
    guard case .failed(let authorizationCode, let authorizationDetail) = try hdc.verify(
      receipt: unauthorized, action: action, context: context)
    else {
      return XCTFail("the registered device authorization rejection must be named")
    }
    XCTAssertEqual(authorizationCode, "deviceUDIDUnauthorized")
    XCTAssertEqual(
      authorizationDetail,
      "package signing profile does not authorize the connected device (bm code 9568423)")

    let accepted = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("install bundle successfully.".utf8),
      stderr: Data(), stdoutTruncated: false, durationSeconds: 0.1)
    guard case .unknown = try hdc.verify(
      receipt: accepted, action: action, context: context)
    else {
      return XCTFail("package-manager success still requires package readback")
    }

    let legacyEmpty = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .unknown = try hdc.verify(
      receipt: legacyEmpty, action: action, context: context)
    else {
      return XCTFail("registered empty-output shape must remain unknown")
    }
  }

  func testObserveServerUsesItsOwnShapeNotTheVersionShape() throws {
    // The `-v` output must NOT verify a server check: that conflation is
    // exactly what reached hardware and produced outcomeUnknown.
    let versionShape = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .unknown = try hdc.verify(
      receipt: versionShape, action: .hdc(.observeServer), context: context)
    else {
      return XCTFail("the -v shape must not satisfy a server check")
    }
    let serverShape = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
      stderr: Data(), stdoutTruncated: false, durationSeconds: 0.1)
    guard case .verified(let summary) = try hdc.verify(
      receipt: serverShape, action: .hdc(.observeServer), context: context)
    else {
      return XCTFail("the real checkserver shape must verify")
    }
    XCTAssertEqual(summary["clientVersion"], "3.2.0f")
    XCTAssertEqual(summary["serverVersion"], "3.2.0f")

    // Client/server disagreement is a named failure, never success.
    let mismatch = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0d\n".utf8),
      stderr: Data(), stdoutTruncated: false, durationSeconds: 0.1)
    guard case .failed(let code, _) = try hdc.verify(
      receipt: mismatch, action: .hdc(.observeServer), context: context)
    else {
      return XCTFail("a version mismatch must fail, not pass")
    }
    XCTAssertEqual(code, "serverVersionMismatch")
  }

  func testRockchipVerifyRequiresDurableRecordReference() throws {
    let rockchip = RockchipFlashProviderAdapter(factsPort: RockchipFactsPort())
    let action = TypedProviderAction.rockchip(
      .enterLoader(connectKey: "150100424a544e4600"))
    let withoutRecord = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false, durationSeconds: 1)
    guard case .unknown = try rockchip.verify(
      receipt: withoutRecord, action: action, context: context)
    else {
      return XCTFail("flash without a durable manifest reference can never verify")
    }
    let withRecord = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false, durationSeconds: 1,
      hostManagedRecordID: "manifest-1",
      hostManagedSummary: ["firmware": "OpenHarmony-7.0.0.37"])
    guard case .verified(let summary) = try rockchip.verify(
      receipt: withRecord, action: action, context: context)
    else {
      return XCTFail("host-managed record must verify")
    }
    XCTAssertEqual(summary["recordId"], "manifest-1")
    XCTAssertEqual(summary["firmware"], "OpenHarmony-7.0.0.37")
  }

  func testReconcileSemantics() async throws {
    let reference = ProviderDurableIntentReference(
      jobID: "job-1", stepID: "s", intentEventID: "i", action: .hdc(.observeTool))
    let outcome = try await hdc.reconcile(intent: reference, context: context)
    XCTAssertEqual(outcome, .confirmedNotExecuted, "read-only re-observation is always safe")

    let rockchip = RockchipFlashProviderAdapter(factsPort: RockchipFactsPort())
    let flashIntent = ProviderDurableIntentReference(
      jobID: "job-1", stepID: "s", intentEventID: "i",
      action: .rockchip(.flashPartitions(flashBundle)))
    let flashOutcome = try await rockchip.reconcile(intent: flashIntent, context: context)
    guard case .stillUnknown = flashOutcome else {
      return XCTFail("destructive reconcile without host evidence must stay unknown")
    }
  }

  func testLoweredPlansCarryNoRawCommandSurface() throws {
    let plan = try hdc.lower(action: .hdc(.observeTool), context: context)
    guard case .process(_, let summary, let timeout) = plan.kind else {
      return XCTFail("observation lowers to a process plan")
    }
    XCTAssertEqual(summary, ["-v"])
    XCTAssertNotNil(timeout)
    // Mismatched provider/action pairs fail closed.
    XCTAssertThrowsError(
      try hdc.lower(
        action: .rockchip(.enterLoader(connectKey: "150100424a544e4600")),
        context: context))
  }

  func testRockchipMaterializesEveryPublishedRuntimeStepWithoutLegacyAuthorization() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let provider = RockchipFlashProviderAdapter(
      factsPort: RockchipFactsPort(), availability: .available)
    let inputs: [String: JSONValue] = [
      "deviceProfile": .string("dayu200"),
      "imageBundleLease": .string("lease:flash-artifact"),
      "partitionPlan": .array(
        RockchipFlashProfile.dayu200.mappedPartitions.map {
          .string($0.partitionName)
        }),
      "postFlashVerification": .string("full"),
    ]
    let engineSteps = Set([
      "verify-image-bundle", "hash-images", "confirm-flash-intent", "finalize-session",
    ])
    for step in descriptor.steps where !engineSteps.contains(step.stepID) {
      let stepContext = ProviderExecutionContext(
        jobID: flashContext.jobID,
        stepID: step.stepID,
        targetID: flashContext.targetID,
        bindingRevision: flashContext.bindingRevision,
        connectKey: flashContext.connectKey,
        expectedIdentitySHA256: flashContext.expectedIdentitySHA256,
        toolVersion: flashContext.toolVersion,
        toolSHA256: flashContext.toolSHA256,
        serverFacts: flashContext.serverFacts,
        nowUTC: flashContext.nowUTC,
        resolvedInputArtifact: flashContext.resolvedInputArtifact,
        // The version the resolved bundle declares is a fact the Runtime reads
        // when it resolves the lease, and post-flash verification is
        // materialized against it. Supplying it here is what lets every step
        // materialize without touching a file — which is the property this
        // test exists to hold.
        expectedRuntimeBuildVersion: "OpenHarmony-7.0.0.36")
      let action = try provider.action(
        for: step, operation: descriptor, inputs: inputs, context: stepContext)
      XCTAssertEqual(action.effect, step.effect, step.stepID)
      let plan = try provider.lower(action: action, context: stepContext)
      XCTAssertEqual(plan.action, action, step.stepID)
      XCTAssertEqual(
        try PersistedTypedProviderAction(action).materialize(), action,
        "\(step.stepID) did not survive exact-action persistence")
      _ = try RuntimeJobEngine.journalStep(
        for: step, jobID: flashContext.jobID, inputs: inputs, action: action,
        resolvedInputArtifact: flashContext.resolvedInputArtifact)
      guard case .hostManaged(let runtimeDescriptor) = plan.kind else {
        return XCTFail("\(step.stepID) did not produce a host-managed typed plan")
      }
      if ["flash-partitions", "verify-flash-readback"].contains(step.stepID) {
        XCTAssertFalse(
          runtimeDescriptor.identifier.contains(".v1"), runtimeDescriptor.identifier)
      } else if ["wait-for-hdc", "rebind-and-verify-build"].contains(step.stepID) {
        XCTAssertTrue(
          runtimeDescriptor.identifier.hasSuffix(".v2"), runtimeDescriptor.identifier)
      } else {
        XCTAssertTrue(
          runtimeDescriptor.identifier.hasSuffix(".v1")
            || runtimeDescriptor.identifier.contains(".v1:"), runtimeDescriptor.identifier)
      }
      XCTAssertEqual(runtimeDescriptor.jobID, stepContext.jobID)
      XCTAssertEqual(runtimeDescriptor.stepID, step.stepID)
      XCTAssertEqual(runtimeDescriptor.targetID, stepContext.targetID)
      XCTAssertEqual(runtimeDescriptor.bindingRevision, stepContext.bindingRevision)
      XCTAssertEqual(runtimeDescriptor.connectKey, stepContext.connectKey)
      XCTAssertEqual(
        runtimeDescriptor.expectedIdentitySHA256,
        stepContext.expectedIdentitySHA256)
      XCTAssertEqual(runtimeDescriptor.providerExecutableSHA256, stepContext.toolSHA256)
      XCTAssertEqual(runtimeDescriptor.actionSHA256.count, 64)
    }
  }

  func testRockchipRejectsPartitionDriftBeforeAuthorization() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let provider = RockchipFlashProviderAdapter(
      factsPort: RockchipFactsPort(), availability: .available)
    let flashStep = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "flash-partitions" })
    XCTAssertThrowsError(
      try provider.action(
        for: flashStep, operation: descriptor,
        inputs: [
          "deviceProfile": .string("dayu200"),
          "partitionPlan": .array([.string("userdata")]),
        ],
        context: flashContext))
  }

  func testRockchipRecoveryRejectsNonCanonicalArtifactPath() throws {
    let persisted = try PersistedTypedProviderAction(
      .rockchip(.flashPartitions(flashBundle)))
    let encoded = try JSONEncoder().encode(persisted)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var arguments = try XCTUnwrap(object["arguments"] as? [String: Any])
    arguments["artifactPath"] = "/private/tmp/nested/../images.tar.gz"
    object["arguments"] = arguments
    let tampered = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(
      PersistedTypedProviderAction.self, from: tampered)

    XCTAssertThrowsError(try decoded.materialize())
  }

  private var flashBundle: RockchipRuntimeFlashBundle {
    RockchipRuntimeFlashBundle(
      artifactLeaseID: "lease:flash-artifact",
      artifactID: "flash-artifact",
      fileURL: URL(fileURLWithPath: "/private/tmp/images.tar.gz"),
      sha256: RockchipFlashProfile.dayu200.archiveSHA256,
      byteCount: Int(RockchipFlashProfile.dayu200.archiveSizeBytes),
      partitionNames: RockchipFlashProfile.dayu200.mappedPartitions.map(\.partitionName))
  }

  private var flashContext: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-flash", stepID: "flash", targetID: "TGT-1", bindingRevision: 1,
      connectKey: "150100424a544e4600",
      expectedIdentitySHA256:
        "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
      toolVersion: "rkdeveloptool ver 1.32",
      toolSHA256: String(repeating: "c", count: 64),
      serverFacts: [
        TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey:
          "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
        TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey: "42",
      ],
      nowUTC: "2026-07-30T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "flash-artifact",
        fileURL: URL(fileURLWithPath: "/private/tmp/images.tar.gz"),
        sha256: RockchipFlashProfile.dayu200.archiveSHA256,
        byteCount: Int(RockchipFlashProfile.dayu200.archiveSizeBytes)))
  }

  func testEvidencePropertyReadsUseExactDescriptorBoundTarget() throws {
    let model = try hdc.lower(
      action: .hdc(.queryProperty(.productModel)), context: context)
    let firmware = try hdc.lower(
      action: .hdc(.queryProperty(.fullBuildVersion)), context: context)
    guard case .process(_, let modelArgv, _) = model.kind,
      case .process(_, let firmwareArgv, _) = firmware.kind
    else {
      return XCTFail("property reads must lower to descriptor-bound process plans")
    }
    XCTAssertEqual(
      modelArgv,
      ["-t", "150100424a544e4600", "shell", "param", "get", "const.product.model"])
    XCTAssertEqual(
      firmwareArgv,
      ["-t", "150100424a544e4600", "shell", "param", "get", "const.ohos.fullname"])
    let missingTarget = ProviderExecutionContext(
      jobID: "job-1", stepID: "read-evidence-model", targetID: "TGT-1",
      bindingRevision: 1, nowUTC: "2026-07-29T00:00:00Z")
    XCTAssertThrowsError(
      try hdc.lower(action: .hdc(.queryProperty(.productModel)), context: missingTarget))
  }

  // MARK: - D2: stop/uninstall are judged by their readback

  private func mutationReceipt(
    mutation: String, mutationExit: Int32, probe: String, probeExit: Int32
  ) -> ProviderProcessReceipt {
    func sub(_ stdout: String, exit: Int32) -> ProviderSubprocessReceipt {
      ProviderSubprocessReceipt(
        exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    }
    return ProviderProcessReceipt(
      exitStatus: probeExit, stdout: Data(), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.02,
      subprocesses: [sub(mutation, exit: mutationExit), sub(probe, exit: probeExit)])
  }

  /// The exact "exit 0 but nothing happened" shape D2 was filed for: `aa
  /// force-stop` reports success while the process is still there.
  func testCleanForceStopWithALiveProcessCannotVerify() throws {
    let ability = try HDCAbilityReference(
      bundle: try HDCBundleReference(bundleName: "com.example.demo"),
      abilityName: "EntryAbility")
    let outcome = try hdc.verify(
      receipt: mutationReceipt(
        mutation: "force-stop ok", mutationExit: 0, probe: "3421\n", probeExit: 0),
      action: .hdc(.stopAbility(ability)), context: context)
    guard case .failed(let code, _) = outcome else {
      return XCTFail("a surviving process must fail the stop, got \(outcome)")
    }
    XCTAssertEqual(code, "stopIneffective")
  }

  /// And the converse: a non-zero force-stop whose process is gone is a
  /// success, because the exit status was never the evidence.
  func testStopVerifiesOnAnAbsentProcessEvenWhenForceStopReportsFailure() throws {
    let ability = try HDCAbilityReference(
      bundle: try HDCBundleReference(bundleName: "com.example.demo"),
      abilityName: "EntryAbility")
    let outcome = try hdc.verify(
      receipt: mutationReceipt(
        mutation: "error: no such ability", mutationExit: 1, probe: "", probeExit: 1),
      action: .hdc(.stopAbility(ability)), context: context)
    guard case .verified(let summary) = outcome else {
      return XCTFail("an absent process is a stopped process, got \(outcome)")
    }
    XCTAssertEqual(summary["stopped"], "com.example.demo")
  }

  /// Only unreadable output is ambiguous. Empty output is absence and a pid
  /// list is presence — the exit status decides nothing, because `hdc shell`
  /// reports the client's status and the device window measured exit 0 for
  /// every `pidof` shape including "not found".
  func testOnlyUnreadableStopProbeOutputStaysUnknown() throws {
    let ability = try HDCAbilityReference(
      bundle: try HDCBundleReference(bundleName: "com.example.demo"),
      abilityName: "EntryAbility")
    for (probe, exit) in [("error 404\n", Int32(0)), ("pid 3421\n", Int32(0))] {
      let outcome = try hdc.verify(
        receipt: mutationReceipt(
          mutation: "", mutationExit: 0, probe: probe, probeExit: exit),
        action: .hdc(.stopAbility(ability)), context: context)
      guard case .unknown = outcome else {
        return XCTFail("probe \(probe.debugDescription)/\(exit) gave \(outcome)")
      }
    }
  }

  /// The exact shape the real device returns after a successful stop —
  /// exit 0 with no output. The first implementation demanded exit 1 here,
  /// which `hdc shell` never produces, so every real stop went `.unknown`
  /// and blocked the target's automatic-E1 lineage (2026-07-31 window,
  /// `job-5e666e27…`).
  func testStopProbeMatchesTheDeviceShapeForAStoppedProcess() throws {
    let ability = try HDCAbilityReference(
      bundle: try HDCBundleReference(bundleName: "com.example.demo"),
      abilityName: "EntryAbility")
    let outcome = try hdc.verify(
      receipt: mutationReceipt(mutation: "", mutationExit: 0, probe: "", probeExit: 0),
      action: .hdc(.stopAbility(ability)), context: context)
    guard case .verified(let summary) = outcome else {
      return XCTFail("exit 0 with no pid is a stopped process, got \(outcome)")
    }
    XCTAssertEqual(summary["stopped"], "com.example.demo")

    // And the running shape the same device returns, through the same probe.
    let running = try hdc.verify(
      receipt: mutationReceipt(mutation: "", mutationExit: 0, probe: "443\n", probeExit: 0),
      action: .hdc(.stopAbility(ability)), context: context)
    guard case .failed(let code, _) = running else {
      return XCTFail("a live pid must fail the stop, got \(running)")
    }
    XCTAssertEqual(code, "stopIneffective")
  }

  /// `bm uninstall` answers `uninstall missing installed bundle` on a clean
  /// exit when the bundle was never there. The dump decides instead.
  func testCleanUninstallWithASurvivingPackageCannotVerify() throws {
    let bundle = try HDCBundleReference(bundleName: "com.example.demo")
    let outcome = try hdc.verify(
      receipt: mutationReceipt(
        mutation: "uninstall missing installed bundle", mutationExit: 0,
        probe: "bundleName: com.example.demo\n", probeExit: 0),
      action: .hdc(.uninstallPackage(bundle)), context: context)
    guard case .failed(let code, _) = outcome else {
      return XCTFail("a surviving package must fail the uninstall, got \(outcome)")
    }
    XCTAssertEqual(code, "uninstallIneffective")
  }

  func testUninstallVerifiesOnlyWhenTheDumpNoLongerNamesTheBundle() throws {
    let bundle = try HDCBundleReference(bundleName: "com.example.demo")
    guard case .verified = try hdc.verify(
      receipt: mutationReceipt(
        mutation: "uninstall bundle successfully", mutationExit: 0,
        probe: "", probeExit: 0),
      action: .hdc(.uninstallPackage(bundle)), context: context)
    else {
      return XCTFail("an absent bundle is an uninstalled bundle")
    }
    // A neighbouring bundle name must not read as this one surviving.
    guard case .verified = try hdc.verify(
      receipt: mutationReceipt(
        mutation: "", mutationExit: 0,
        probe: "bundleName: com.example.demo.helper\n", probeExit: 0),
      action: .hdc(.uninstallPackage(bundle)), context: context)
    else {
      return XCTFail("a longer neighbouring bundle name is not this bundle")
    }
    guard case .unknown = try hdc.verify(
      receipt: mutationReceipt(
        mutation: "", mutationExit: 0, probe: "", probeExit: 1),
      action: .hdc(.uninstallPackage(bundle)), context: context)
    else {
      return XCTFail("an unreadable dump is not proof of removal")
    }
  }

  /// Neither verdict may be reached from a bare single-process receipt: a
  /// mutation with no readback leg has produced no evidence at all.
  func testStopAndUninstallWithoutTheirReadbackLegStayUnknown() throws {
    let bundle = try HDCBundleReference(bundleName: "com.example.demo")
    let ability = try HDCAbilityReference(bundle: bundle, abilityName: "EntryAbility")
    let bare = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.01)
    for action in [
      TypedProviderAction.hdc(.stopAbility(ability)),
      TypedProviderAction.hdc(.uninstallPackage(bundle)),
    ] {
      guard case .unknown = try hdc.verify(receipt: bare, action: action, context: context)
      else {
        return XCTFail("\(action) must not verify without its readback")
      }
    }
  }

  func testEveryDeviceScopedHDCPlanUsesDescriptorBoundTarget() throws {
    let artifactID = "ART-0123456789abcdef0123456789abcdef"
    let artifact = ProviderResolvedInputArtifact(
      artifactID: artifactID,
      fileURL: URL(fileURLWithPath: "/private/tmp/input.hap"),
      sha256: String(repeating: "c", count: 64),
      byteCount: 128)
    let boundContext = ProviderExecutionContext(
      jobID: "job-1", stepID: "device-step", targetID: "TGT-1",
      bindingRevision: 1, connectKey: "150100424a544e4600",
      expectedIdentitySHA256: String(repeating: "b", count: 64),
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-29T00:00:00Z", resolvedInputArtifact: artifact)
    let missingBinding = ProviderExecutionContext(
      jobID: "job-1", stepID: "device-step", targetID: "TGT-1",
      bindingRevision: 1, nowUTC: "2026-07-29T00:00:00Z",
      resolvedInputArtifact: artifact)
    let ownedPath = try hdc.mintOwnedRemotePath(jobID: "job-1", stepID: "device-step")
    let ownedArtifact = HDCOwnedRemoteArtifact(
      path: ownedPath, expectedSHA256: nil, maximumBytes: 1024)
    let staged = try hdc.mintStagedArtifact(
      jobID: "job-1", stepID: "send-hap",
      artifactLeaseID: "lease-v1:job-input:\(artifactID)",
      expectedSHA256: artifact.sha256)
    let bundle = try HDCBundleReference(bundleName: "com.example.demo")
    let ability = try HDCAbilityReference(bundle: bundle, abilityName: "EntryAbility")
    let applicationLiveness = try HDCApplicationLivenessRequest(
      bundle: bundle, abilityName: "EntryAbility",
      expectedDeployedArtifactDigest: String(repeating: "d", count: 64))
    let port = try HDCPortForwardSpec(localPort: 2345, remotePort: 3456)
    let actions: [TypedProviderAction] = [
      .hdc(.queryProperty(.productModel)),
      .hdc(.observeStorage(try HDCStoragePreflightRequest(requiredBytes: 1024))),
      .hdc(.captureHilog(try HDCHilogCaptureRequest(durationSeconds: 1))),
      // windowList is the only scope with a published honest lowering
      // (CHG-2026-053); componentTree's fail-closed path is pinned in
      // DeviceProviderArgvContractTests.
      .hdc(.captureUIDump(try HDCUIDumpRequest(scope: .windowList))),
      .hdc(
        .captureTrace(
          try HDCTraceCaptureRequest(durationSeconds: 1, categories: ["ohos"]),
          into: ownedPath)),
      .hdc(.receiveOwnedArtifact(ownedArtifact)),
      .hdc(.cleanupOwnedRemotePath(ownedPath)),
      .hdc(.sendArtifactToStaging(staged)),
      .hdc(.installPackage(staged, bundle: bundle)),
      .hdc(.queryPackageReadback(bundle)),
      .hdc(.startAbility(ability)),
      .hdc(.verifyProcessState(bundle)),
      .hdc(.observeApplicationLiveness(applicationLiveness)),
      .hdc(.stopAbility(ability)),
      .hdc(.uninstallPackage(bundle)),
      .hdc(.createPortForward(port)),
      .hdc(.removePortForward(port)),
      .hdc(.readPackagePresence(bundle)),
      .hdc(.readProcessPresence(bundle)),
      .hdc(.readOwnedPathPresence(ownedPath)),
      .hdc(.readPortForwardPresence(port)),
    ]

    for action in actions {
      let plan = try hdc.lower(action: action, context: boundContext)
      // A readback-carrying action lowers to a sequence; every invocation in
      // it reaches the device, so every one of them must be target-bound.
      let invocations: [[String]]
      switch plan.kind {
      case .process(_, let argv, _):
        invocations = [argv]
      case .processSequence(_, let sequence):
        invocations = sequence.map(\.arguments)
      case .hostManaged:
        return XCTFail("\(action) must lower to a process plan")
      }
      for argv in invocations {
        XCTAssertEqual(
          Array(argv.prefix(2)), ["-t", "150100424a544e4600"],
          "\(action) must not depend on HDC's default device")
      }
      XCTAssertThrowsError(
        try hdc.lower(action: action, context: missingBinding),
        "\(action) must fail before process launch when no descriptor-bound connect key exists")
    }
  }

  func testExactTargetConfirmationRejectsZeroMultipleAndUnknownRows() throws {
    func receipt(_ rows: String) -> ProviderProcessReceipt {
      ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(rows.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.1)
    }
    let action = TypedProviderAction.hdc(.observeDevice(connectKey: "resolved-by-binding"))
    guard case .verified(let summary) = try hdc.verify(
      receipt: receipt("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"),
      action: action, context: context)
    else {
      return XCTFail("the one exact registered target row must verify")
    }
    XCTAssertEqual(summary["transport"], "usb")
    XCTAssertEqual(
      summary["deviceIdentitySHA256"],
      "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1")
    XCTAssertNil(summary["connectKeys"], "runtime target confirmation must not expose raw keys")

    guard case .failed(let zeroCode, _) = try hdc.verify(
      receipt: receipt("different\t\tUSB\tConnected\tlocalhost\n"),
      action: action, context: context)
    else { return XCTFail("zero exact matches must fail") }
    XCTAssertEqual(zeroCode, "targetConfirmationMismatch")

    let duplicate =
      "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
      + "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
    guard case .failed(let duplicateCode, _) = try hdc.verify(
      receipt: receipt(duplicate), action: action, context: context)
    else { return XCTFail("multiple exact matches must fail") }
    XCTAssertEqual(duplicateCode, "targetConfirmationMismatch")

    guard case .unknown = try hdc.verify(
      receipt: receipt("150100424a544e4600\t\tBLUETOOTH\tConnected\tlocalhost\n"),
      action: action, context: context)
    else { return XCTFail("an unregistered transport row must fail closed") }
  }

  func testHDCIdentityIsDerivedFromTheConnectKeyNotTheCampaignIdentity() throws {
    // The facts port and confirm-evidence-target must share one derivation:
    // the connect key. After a Loader-mode flash the target store's
    // `stablePhysicalIdentitySHA256` advances to the Loader-mode (campaign)
    // identity while the connect key stays normal-mode — publishing that
    // campaign identity on the HDC facts made every device-bound operation
    // fail `targetIdentityMismatch` from binding revision 2 onward
    // (GJ-1 re-run, 2026-08-05).
    XCTAssertEqual(
      HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: "150100424A544E4600"),
      "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
      "derivation is case-insensitive over the connect key")
    // The production DAYU200 anchor: the adopted target ID prefix is this
    // exact derivation of its normal-mode connect key.
    XCTAssertTrue(
      HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: "150100424a544434520325874bbf4900"
      ).hasPrefix("958780b2ffb7"))

    func receipt(_ rows: String) -> ProviderProcessReceipt {
      ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(rows.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.1)
    }
    let action = TypedProviderAction.hdc(.observeDevice(connectKey: "resolved-by-binding"))
    let campaignIdentityContext = ProviderExecutionContext(
      jobID: "job-1", stepID: "step-1", targetID: "TGT-1", bindingRevision: 1,
      connectKey: "150100424a544e4600",
      expectedIdentitySHA256: String(repeating: "a", count: 64),
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-29T00:00:00Z")
    guard case .failed(let code, _) = try hdc.verify(
      receipt: receipt("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"),
      action: action, context: campaignIdentityContext)
    else {
      return XCTFail("an expected identity that is not the connect-key derivation must fail")
    }
    XCTAssertEqual(code, "targetIdentityMismatch")
  }
}

final class HDCCompatibilityProfileTests: XCTestCase {
  private let profile = HDCCompatibilityProfile.openHarmony320Family

  func testWhitespaceAndDiagnosticNoiseDoNotChangeParsing() {
    let clean = Data("Ver: 3.2.0f\n".utf8)
    let noisy = Data("[I] server starting\n\n   Ver: 3.2.0f   \n[W] something benign\n".utf8)
    let parsedClean = HDCObservationSemanticParser.parseClientVersion(
      stdout: clean, profile: profile, truncated: false)
    let parsedNoisy = HDCObservationSemanticParser.parseClientVersion(
      stdout: noisy, profile: profile, truncated: false)
    XCTAssertEqual(parsedClean, parsedNoisy)
    XCTAssertEqual(parsedClean, .parsed(HDCParsedClientVersion(version: "3.2.0f")))
  }

  func testBothRegisteredVersionsParse() {
    for version in ["3.2.0d", "3.2.0f"] {
      let outcome = HDCObservationSemanticParser.parseClientVersion(
        stdout: Data("Ver: \(version)\n".utf8), profile: profile, truncated: false)
      XCTAssertEqual(outcome, .parsed(HDCParsedClientVersion(version: version)))
    }
  }

  func testExplicitOutcomesForDegenerateInputs() {
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data("Ver: 1.0.0a\n".utf8), profile: profile, truncated: false),
      .unsupportedVersion("1.0.0a"))
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data(), profile: profile, truncated: false),
      .empty)
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data("Ver: 3.2.0f\n".utf8), profile: profile, truncated: true),
      .truncated)
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data([0xFF, 0xFE, 0x00]), profile: profile, truncated: false),
      .invalidEncoding)
    if case .malformed = HDCObservationSemanticParser.parseClientVersion(
      stdout: Data("Ver: 3.2.0f\nVer: 3.2.0d\n".utf8), profile: profile, truncated: false)
    {
    } else {
      XCTFail("two Ver: lines must be malformed")
    }
  }

  /// Regression for the first device window: `hdc checkserver` answers
  /// `Client version:Ver: X, server version:Ver: Y`, which the `-v` parser
  /// read as zero "Ver:" lines and turned into outcomeUnknown on real
  /// hardware. These are the exact shapes the fixture and the device emit.
  func testServerCheckParsing() {
    let healthy = HDCObservationSemanticParser.parseServerCheck(
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
      profile: profile, truncated: false)
    XCTAssertEqual(
      healthy,
      .parsed(HDCParsedServerCheck(clientVersion: "3.2.0f", serverVersion: "3.2.0f")))
    if case .parsed(let check) = healthy { XCTAssertTrue(check.versionsAgree) }

    // Both registered versions, and the disagreement the probe exists for.
    let mismatch = HDCObservationSemanticParser.parseServerCheck(
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0d\n".utf8),
      profile: profile, truncated: false)
    guard case .parsed(let mismatched) = mismatch else {
      return XCTFail("a version disagreement still parses, then fails semantically")
    }
    XCTAssertFalse(mismatched.versionsAgree)

    // An unregistered version on either side is unsupported, not a pass.
    XCTAssertEqual(
      HDCObservationSemanticParser.parseServerCheck(
        stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 9.9.9z\n".utf8),
        profile: profile, truncated: false),
      .unsupportedVersion("9.9.9z"))

    // Degenerate shapes stay explicit.
    XCTAssertEqual(
      HDCObservationSemanticParser.parseServerCheck(
        stdout: Data(), profile: profile, truncated: false),
      .empty)
    XCTAssertEqual(
      HDCObservationSemanticParser.parseServerCheck(
        stdout: Data("Ver: 3.2.0f\n".utf8), profile: profile, truncated: false),
      .malformed(reason: "no client/server version line in checkserver output"))
    if case .malformed(let reason) = HDCObservationSemanticParser.parseServerCheck(
      stdout: Data("[Fail] Offline after transfer\n".utf8), profile: profile, truncated: false)
    {
      XCTAssertTrue(reason.contains("Offline"), "a device-side failure must be legible: \(reason)")
    } else {
      XCTFail("a [Fail] line must surface as a named malformed outcome")
    }
  }

  func testTargetListParsing() {
    XCTAssertEqual(
      HDCObservationSemanticParser.parseTargetList(
        stdout: Data("[Empty]\n".utf8), profile: profile, toolVersion: "3.2.0f",
        truncated: false),
      .parsed(HDCParsedTargetList(targets: [])))
    let listed = HDCObservationSemanticParser.parseTargetList(
      stdout: Data("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n".utf8), profile: profile,
      toolVersion: "3.2.0f", truncated: false)
    guard case .parsed(let list) = listed, list.targets.count == 1 else {
      return XCTFail("one target line must parse, got \(listed)")
    }
    XCTAssertEqual(list.targets[0].state, "Connected")
    XCTAssertEqual(list.targets[0].transport, "usb")
    if case .malformed = HDCObservationSemanticParser.parseTargetList(
      stdout: Data("150100424a544e4600\tConnected\n".utf8), profile: profile,
      toolVersion: "3.2.0f", truncated: false)
    {
    } else {
      XCTFail("the legacy two-column guess must no longer parse")
    }
    XCTAssertEqual(
      HDCObservationSemanticParser.parseTargetList(
        stdout: Data("[Empty]\n".utf8), profile: profile, toolVersion: "9.9.9z",
        truncated: false),
      .unsupportedVersion("9.9.9z"))
  }
}
