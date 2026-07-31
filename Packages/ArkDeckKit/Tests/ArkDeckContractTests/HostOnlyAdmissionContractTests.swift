// Host-only admission contract tests (CHG-2026-054, TASK-HTP-007).
//
// Registered acceptance: HTP-AC-20 (a host-only operation is admitted without
// touching the device surface), HTP-AC-21 (device-bound admission is unchanged
// and the new branch is unreachable for it), HTP-AC-22 (a host-only operation
// fails closed both ways, and its first consumer lowers to an exact argv).

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Records every facts lookup so a test can assert the device surface was not
/// touched at all - the property that matters, rather than "it happened to
/// work".
private final class FactsWitness: HDCObservationFactsPort, @unchecked Sendable {
  private let lock = NSLock()
  private var asked: [String] = []
  var facts: ProviderFacts?

  var askedTargets: [String] { lock.withLock { asked } }

  func currentFacts(targetID: String) async throws -> ProviderFacts {
    lock.withLock { asked.append(targetID) }
    guard let facts else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    return facts
  }
}

private struct RecordingDispatcher: RuntimeProcessDispatching {
  final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [TypedProcessPlan] = []
    var dispatched: [TypedProcessPlan] { lock.withLock { plans } }
    func append(_ plan: TypedProcessPlan) { lock.withLock { plans.append(plan) } }
  }

  let log: Log
  let stdout: Data
  let exitStatus: Int32

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    log.append(plan)
    return ProviderProcessReceipt(
      exitStatus: exitStatus, stdout: stdout, stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.01)
  }
}

final class HostOnlyAdmissionContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-host-only-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private var inspectSource: CatalogOperationDescriptor {
    RuntimeOperationCatalog.descriptor(reference: "workspace.inspect-source@1")!
  }

  private func workspaceProvider(
    projects: [String: String] = ["demo-app": "/tmp/demo-app"],
    tool: WorkspaceInspectorTool? = WorkspaceInspectorTool(
      executablePath: "/usr/bin/grep", executableSHA256: String(repeating: "a", count: 64))
  ) -> WorkspaceProvider {
    WorkspaceProvider(registry: WorkspaceProjectRegistry(roots: projects), tool: tool)
  }

  private func makeEngine(
    witness: FactsWitness,
    dispatcherLog: RecordingDispatcher.Log = .init(),
    workspaceTool: WorkspaceInspectorTool? = WorkspaceInspectorTool(
      executablePath: "/usr/bin/grep", executableSHA256: String(repeating: "a", count: 64)),
    stdout: Data = Data("Sources/Foo.swift:12: WaterFlowPattern\n".utf8),
    exitStatus: Int32 = 0,
    artifactStore: RuntimeArtifactStore? = nil
  ) throws -> RuntimeJobEngine {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let providers = DeviceProviderRegistry(providers: [
      HDCObservationProviderAdapter(factsPort: witness),
      workspaceProvider(tool: workspaceTool),
    ])
    return try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
      providers: providers,
      dispatcher: RecordingDispatcher(
        log: dispatcherLog, stdout: stdout, exitStatus: exitStatus),
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })
  }

  private func request(
    operation: String = "workspace.inspect-source@1",
    targetID: String = "demo-app",
    bindingRevision: Int? = nil,
    inputs: [String: JSONValue] = [
      "projectRef": .string("demo-app"),
      "symbol": .string("WaterFlowPattern"),
      "fileScope": .string("*.swift"),
    ]
  ) throws -> Data {
    let parts = operation.split(separator: "@")
    let request = try RuntimeOperationRequest(
      requestID: "req-\(UUID().uuidString.prefix(8).lowercased())",
      idempotencyKey: "idem-\(UUID().uuidString.lowercased())",
      target: DurableTargetReference(
        targetID: targetID, expectedBindingRevision: bindingRevision),
      operation: RuntimeOperationReference(
        id: String(parts[0]), version: Int(parts[1])!),
      inputs: inputs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(request)
  }

  // MARK: - HTP-AC-20

  func testTheCatalogPublishesAHostOnlyOperation() {
    let descriptor = inspectSource
    XCTAssertEqual(descriptor.binding, .none)
    XCTAssertEqual(descriptor.provider, .workspace)
    XCTAssertEqual(descriptor.concurrencyKey, .hostExclusive)
    XCTAssertEqual(descriptor.minimumEffect, .hostOnly)
    XCTAssertEqual(descriptor.permittedEffects, [.hostOnly])
    XCTAssertEqual(descriptor.authorization[.hostOnly], .defaultReadOnly)
    XCTAssertTrue(descriptor.steps.allSatisfy { $0.binding == .none && $0.effect == .hostOnly })
  }

  func testHostOnlyAdmissionNeverTouchesTheDeviceSurface() async throws {
    let witness = FactsWitness()  // no facts at all: nothing is adopted
    let log = RecordingDispatcher.Log()
    let engine = try makeEngine(witness: witness, dispatcherLog: log)

    let acceptance = try await engine.submit(try request())
    XCTAssertFalse(acceptance.deduplicated)
    XCTAssertEqual(
      witness.askedTargets, [],
      "a host-only operation must not resolve device facts: there is no device")

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", "timeline: \(status.timeline)")
    XCTAssertEqual(witness.askedTargets, [], "still no device lookup during dispatch")
    XCTAssertEqual(log.dispatched.count, 1)

    // The evidence carries no binding revision, because there is none to carry.
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertNil(evidence.bindingRevision)
    XCTAssertEqual(evidence.providerID, "workspace")
    XCTAssertEqual(evidence.actualEffect, "hostOnly")
  }

  func testTheInspectionArtifactHoldsTheRealBytesAndNoDeviceBinding() async throws {
    let store = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let bytes = Data("Sources/WaterFlow.cpp:2:WaterFlowPattern_RecoverBack\n".utf8)
    let engine = try makeEngine(
      witness: FactsWitness(), stdout: bytes, artifactStore: store)
    let acceptance = try await engine.submit(try request())
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", "timeline: \(status.timeline)")

    let stored = try await store.list(jobID: acceptance.jobID)
    let inspection = try XCTUnwrap(stored.first { $0.name == "source-inspection.txt" })
    XCTAssertEqual(inspection.byteCount, bytes.count)
    let published = try await store.read(
      jobID: acceptance.jobID, artifactID: inspection.artifactID)
    XCTAssertEqual(
      published, bytes,
      "the inspection is its stdout: publishing a summary would hand the evaluator a "
        + "description of evidence instead of evidence")
    // The binding snapshot names the host scope and nothing else: no revision,
    // no device identity to claim.
    XCTAssertNil(inspection.bindingSnapshot.bindingRevision)
    XCTAssertNil(inspection.bindingSnapshot.stableIdentitySHA256)
    XCTAssertEqual(inspection.bindingSnapshot.targetID, "demo-app")

    let omitted = try await engine.intentionallyOmittedArtifactNames(jobID: acceptance.jobID)
    XCTAssertFalse(
      omitted.contains("source-inspection.txt"),
      "a required artifact must be published, not recorded as intentionally absent")
    let verified = try await store.verifiedEvidenceArtifacts(
      jobID: acceptance.jobID, intentionallyOmittedNames: omitted)
    XCTAssertEqual(verified.map(\.sha256), [inspection.sha256])
  }

  func testAHostOnlyRequestMayNotPinABindingRevision() async throws {
    let engine = try makeEngine(witness: FactsWitness())
    do {
      _ = try await engine.submit(try request(bindingRevision: 7))
      XCTFail("a host-only operation has no binding to pin")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(_, let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("must not pin a binding revision"), detail)
    }
  }

  func testReconcilingAHostOnlyJobNeverReachesADeviceReadback() async throws {
    // A finished host-only job has nothing to reconcile, and the point is what
    // does *not* happen: no provider is asked for facts it would have to
    // invent. If the recovery body is ever reached for such a job, the engine
    // refuses it by reference rather than synthesising an observation.
    let witness = FactsWitness()
    let engine = try makeEngine(witness: witness)
    let acceptance = try await engine.submit(try request())
    _ = try await engine.run(jobID: acceptance.jobID)
    do {
      let status = try await engine.reconcile(jobID: acceptance.jobID)
      XCTAssertFalse(status.outcomeUnknown)
    } catch let error as RuntimeJobEngineError {
      guard case .jobNotRunnable(let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("host-only"), detail)
    }
    XCTAssertEqual(
      witness.askedTargets, [], "reconcile must not resolve device facts for a host-only job")
  }

  func testDraftingACapabilityForAHostOnlyOperationIsRefused() async throws {
    let engine = try makeEngine(witness: FactsWitness())
    do {
      _ = try await engine.draftCapability(
        try request(), issuedAtUTC: "2026-07-31T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        issuerReference: "https://example.invalid/pr/1")
      XCTFail("a host-only operation is gated by the default read-only policy")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(_, let detail) = error else { return XCTFail("\(error)") }
      // Refused earlier and more precisely than the host-only guard would:
      // drafting is limited to E1 device mutations. The guard inside
      // `draftCapability` remains the backstop if that ever widens.
      XCTAssertTrue(
        detail.contains("deviceMutation") || detail.contains("host-only"), detail)
    }
  }

  // MARK: - HTP-AC-21: the device path is unchanged

  func testDeviceBoundAdmissionStillRequiresCompleteFacts() async throws {
    // No facts: the device operation is refused exactly as before, before any
    // authorization is prepared.
    let witness = FactsWitness()
    let engine = try makeEngine(witness: witness)
    do {
      _ = try await engine.submit(
        try request(
          operation: "observe.device@1", targetID: "TGT-1", bindingRevision: 7, inputs: [:]))
      XCTFail("a device-bound operation without facts must be refused")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(_, let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("target facts cannot materialize"), detail)
    }
    XCTAssertEqual(witness.askedTargets, ["TGT-1"], "the device path still resolves facts")
  }

  func testDeviceBoundAdmissionStillRequiresAPinnedBindingRevision() async throws {
    let witness = FactsWitness()
    witness.facts = ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "b", count: 64), serverFacts: [:],
      targetID: "TGT-1", bindingRevision: 7,
      deviceIdentitySHA256: String(repeating: "c", count: 64),
      executionConnectKey: "150100424a544e4600", deviceMode: nil, buildFingerprint: nil,
      profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-31T00:00:00Z")
    let engine = try makeEngine(witness: witness)
    do {
      // Facts exist, but the request pins no binding revision: still refused,
      // because host-only is the *only* thing the new branch relaxed.
      _ = try await engine.submit(
        try request(operation: "observe.device@1", targetID: "TGT-1", inputs: [:]))
      XCTFail("a device-bound request without an expected binding revision must be refused")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(_, let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("target facts cannot materialize"), detail)
    }
  }

  func testEveryDeviceBoundOperationStillDeclaresConfirmedBinding() {
    for descriptor in RuntimeOperationCatalog.operations where descriptor.provider != .workspace {
      XCTAssertEqual(
        descriptor.binding, .confirmedDevice,
        "\(descriptor.reference) must keep its device binding")
    }
    // Only the explicitly published workspace family may reach the host-only
    // branch; every other operation remains device-bound.
    XCTAssertEqual(
      RuntimeOperationCatalog.operations.filter { $0.binding == .none }.map(\.reference),
      [
        "workspace.apply-patch@1",
        "workspace.build-openharmony@1",
        "workspace.inspect-source@1",
        "workspace.revert-patch@1",
        "workspace.run-tests@1",
        "workspace.symbolize-crash@1",
      ])
  }

  // MARK: - HTP-AC-22: fail closed both ways, and the first consumer

  func testAHostOnlyDescriptorWithADeviceStepIsRefused() {
    let deviceStep = CatalogStepDescriptor(
      stepID: "sneak-device-read", kind: .probeDevice, effect: .readOnly,
      cancellation: .immediate, binding: .confirmedDevice, isOptional: false,
      compensation: .none)
    let smuggled = Self.descriptor(inspectSource, steps: [deviceStep])
    XCTAssertThrowsError(try RuntimeJobEngine.validateHostOnlyDescriptor(smuggled)) { error in
      guard case .rejected(_, let detail) = error as? RuntimeJobEngineError else {
        return XCTFail("\(error)")
      }
      XCTAssertTrue(detail.contains("requires a device binding"), detail)
    }

    let mutatingStep = CatalogStepDescriptor(
      stepID: "sneak-host-mutation", kind: .postprocessArtifact, effect: .deviceMutation,
      cancellation: .atSafeBoundary, binding: .none, isOptional: false, compensation: .none)
    let elevated = Self.descriptor(inspectSource, steps: [mutatingStep])
    XCTAssertThrowsError(try RuntimeJobEngine.validateHostOnlyDescriptor(elevated)) { error in
      guard case .rejected(_, let detail) = error as? RuntimeJobEngineError else {
        return XCTFail("\(error)")
      }
      XCTAssertTrue(detail.contains("declares effect deviceMutation"), detail)
    }

    let widened = Self.descriptor(
      inspectSource, permittedEffects: [.hostOnly, .deviceMutation])
    XCTAssertThrowsError(try RuntimeJobEngine.validateHostOnlyDescriptor(widened)) { error in
      guard case .rejected(_, let detail) = error as? RuntimeJobEngineError else {
        return XCTFail("\(error)")
      }
      XCTAssertTrue(detail.contains("permits an effect above hostOnly"), detail)
    }

    XCTAssertNoThrow(try RuntimeJobEngine.validateHostOnlyDescriptor(inspectSource))
  }

  func testInspectSourceLowersToAnExactArgv() throws {
    let provider = workspaceProvider()
    let step = inspectSource.steps[0]
    let action = try provider.action(
      for: step, operation: inspectSource,
      inputs: [
        "projectRef": .string("demo-app"),
        "symbol": .string("WaterFlowPattern"),
        "fileScope": .string("*.cpp"),
      ])
    let plan = try provider.lower(
      action: action,
      context: ProviderExecutionContext(
        jobID: "JOB-1", stepID: step.stepID, targetID: "demo-app", bindingRevision: nil,
        nowUTC: "2026-07-31T00:00:00Z"))
    guard case .process(let executableSHA256, let argv, let timeout) = plan.kind else {
      return XCTFail("a host-only inspection must lower to a single process plan")
    }
    XCTAssertEqual(
      argv,
      ["-r", "-n", "--include", "*.cpp", "--", "WaterFlowPattern", "/tmp/demo-app"],
      "the dispatcher spawns exactly this array")
    XCTAssertEqual(executableSHA256, String(repeating: "a", count: 64))
    XCTAssertEqual(timeout, 120)
  }

  func testTheProviderRefusesPathsUnknownProjectsAndDeviceFacts() async throws {
    let provider = workspaceProvider()
    let step = inspectSource.steps[0]

    for scope in ["../etc", "sub/dir/*.c", "-rf", "*.c;rm"] {
      XCTAssertThrowsError(
        try provider.action(
          for: step, operation: inspectSource,
          inputs: [
            "projectRef": .string("demo-app"), "symbol": .string("x"),
            "fileScope": .string(scope),
          ]),
        "\(scope) is a path or an option, not a glob")
    }

    XCTAssertThrowsError(
      try provider.action(
        for: step, operation: inspectSource,
        inputs: [
          "projectRef": .string("not-registered"), "symbol": .string("x"),
          "fileScope": .string("*.c"),
        ])
    ) { error in
      XCTAssertEqual(error as? WorkspaceProviderError, .unknownProject("not-registered"))
    }

    do {
      _ = try await provider.resolveFacts(targetID: "demo-app")
      XCTFail("a host-only provider must not invent device facts")
    } catch {
      XCTAssertTrue("\(error)".contains("host-only"), "\(error)")
    }
  }

  func testUnconfiguredInspectorReportsUnavailableAndAdmitsNothing() async throws {
    let noTool = workspaceProvider(tool: nil)
    guard case .unavailable(let reason) = noTool.runtimeAvailability(for: inspectSource) else {
      return XCTFail("an unconfigured inspector must report unavailable")
    }
    XCTAssertEqual(reason, "no_workspace_inspector_configured")

    let noProject = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(),
      tool: WorkspaceInspectorTool(
        executablePath: "/usr/bin/grep", executableSHA256: String(repeating: "a", count: 64)))
    guard case .unavailable(let projectReason) =
      noProject.runtimeAvailability(for: inspectSource)
    else {
      return XCTFail("no registered project must report unavailable")
    }
    XCTAssertEqual(projectReason, "no_workspace_project_registered")

    // And admission refuses before anything is materialized or consumed.
    let engine = try makeEngine(witness: FactsWitness(), workspaceTool: nil)
    do {
      _ = try await engine.submit(try request())
      XCTFail("an unavailable operation must not be admitted")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(_, let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("no_workspace_inspector_configured"), detail)
    }
  }

  func testNoMatchesIsAnObservationNotAFailure() async throws {
    // grep exits 1 when it finds nothing. "Zero occurrences" is a real result
    // the evaluator needs; treating it as a failure would hide it.
    let engine = try makeEngine(
      witness: FactsWitness(), stdout: Data(), exitStatus: 1)
    let acceptance = try await engine.submit(try request())
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", "timeline: \(status.timeline)")
    XCTAssertFalse(status.outcomeUnknown)
  }

  func testTheJournalRecordsWhatWasInspectedWithoutTheHostPath() throws {
    let provider = workspaceProvider()
    let action = try provider.action(
      for: inspectSource.steps[0], operation: inspectSource,
      inputs: [
        "projectRef": .string("demo-app"),
        "symbol": .string("WaterFlowPattern"),
        "fileScope": .string("*.swift"),
      ])
    let identity = try PersistedTypedProviderAction(action)
    XCTAssertEqual(identity.kind, "workspace.inspectSource")
    XCTAssertEqual(identity.arguments["projectRef"], JSONValue.string("demo-app"))
    XCTAssertEqual(identity.arguments["fileScope"], JSONValue.string("*.swift"))
    XCTAssertNil(
      identity.arguments["projectRoot"],
      "the resolved host path is private to this machine and must not be journalled")
  }

  private static func descriptor(
    _ base: CatalogOperationDescriptor,
    steps: [CatalogStepDescriptor]? = nil,
    permittedEffects: [WorkflowEffect]? = nil
  ) -> CatalogOperationDescriptor {
    CatalogOperationDescriptor(
      id: base.id,
      version: base.version,
      title: base.title,
      provider: base.provider,
      minimumEffect: base.minimumEffect,
      permittedEffects: permittedEffects ?? base.permittedEffects,
      authorization: base.authorization,
      defaultPolicyIssuanceEnabled: base.defaultPolicyIssuanceEnabled,
      binding: base.binding,
      concurrencyKey: base.concurrencyKey,
      inputs: base.inputs,
      outputs: base.outputs,
      steps: steps ?? base.steps,
      timeoutSeconds: base.timeoutSeconds,
      outputByteBudget: base.outputByteBudget,
      preflightAttempts: base.preflightAttempts,
      artifacts: base.artifacts,
      profiles: base.profiles)
  }
}
