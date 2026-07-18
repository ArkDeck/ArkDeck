import ArkDeckCore
import ArkDeckProcess
import ArkDeckRuntime
import ArkDeckStorage
import ArkDeckWorkflows
import Foundation
import XCTest

@testable import ArkDeckOpenHarmony

/// Package-boundary contract tests. The tables below restate the dependency
/// contract from Package.swift and the app target; the tests enforce it by
/// scanning `import` statements in the source tree, so an undeclared
/// cross-module or UI-framework import fails here even if Package.swift is
/// edited to permit it.
final class ArkDeckContractTests: XCTestCase {
  private static let uiFrameworks: Set<String> = ["SwiftUI", "AppKit", "UIKit", "Cocoa"]

  private static let declaredPackageDependencies: [String: Set<String>] = [
    "ArkDeckCore": [],
    "ArkDeckProcess": ["ArkDeckCore"],
    "ArkDeckRuntime": ["ArkDeckCore"],
    "ArkDeckOpenHarmony": ["ArkDeckCore", "ArkDeckProcess"],
    "ArkDeckWorkflows": ["ArkDeckCore", "ArkDeckOpenHarmony", "ArkDeckStorage"],
    "ArkDeckStorage": ["ArkDeckCore"],
  ]

  func testPackageModulesRemainIndependentlyAddressable() {
    XCTAssertEqual(
      [
        ArkDeckCoreModule.identifier,
        ArkDeckProcessModule.identifier,
        ArkDeckRuntimeModule.identifier,
        ArkDeckOpenHarmonyModule.identifier,
        ArkDeckWorkflowsModule.identifier,
        ArkDeckStorageModule.identifier,
      ],
      [
        "ArkDeckCore",
        "ArkDeckProcess",
        "ArkDeckRuntime",
        "ArkDeckOpenHarmony",
        "ArkDeckWorkflows",
        "ArkDeckStorage",
      ]
    )
  }

  func testPackageTargetsImportOnlyDeclaredArkDeckModules() throws {
    for (target, allowed) in Self.declaredPackageDependencies.sorted(by: { $0.key < $1.key }) {
      for (file, modules) in try importsByFile(
        under: packageRoot.appending(path: "Sources/\(target)"))
      {
        for module in modules where module.hasPrefix("ArkDeck") && module != target {
          XCTAssertTrue(
            allowed.contains(module),
            "\(target) imports \(module), which Package.swift does not declare (\(file))"
          )
        }
      }
    }
  }

  func testPackageTargetsDoNotImportUIFrameworks() throws {
    for target in Self.declaredPackageDependencies.keys.sorted() {
      for (file, modules) in try importsByFile(
        under: packageRoot.appending(path: "Sources/\(target)"))
      {
        for module in modules where Self.uiFrameworks.contains(module) {
          XCTFail("\(target) imports UI framework \(module) (\(file))")
        }
      }
    }
  }

  func testAppTargetImportsOnlyCoreAndWorkflowsFromArkDeckKit() throws {
    let allowed = Set(["ArkDeckCore", "ArkDeckWorkflows"])
    for (file, modules) in try importsByFile(under: repoRoot.appending(path: "ArkDeckApp")) {
      for module in modules where module.hasPrefix("ArkDeck") {
        XCTAssertTrue(
          allowed.contains(module),
          "app shell imports \(module), which is outside the Core/Workflows boundary (\(file))"
        )
      }
    }
  }

  // MARK: - Source scanning

  private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // ArkDeckContractTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // package root
  }

  private var repoRoot: URL {
    packageRoot
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repo root
  }

  private func importsByFile(under directory: URL) throws -> [(file: String, modules: [String])] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil)
    else {
      XCTFail("expected a source directory at \(directory.path)")
      return []
    }
    var results: [(file: String, modules: [String])] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let source = try String(contentsOf: url, encoding: .utf8)
      results.append((file: url.lastPathComponent, modules: importedModules(in: source)))
    }
    XCTAssertFalse(results.isEmpty, "no Swift sources found under \(directory.path)")
    return results
  }

  /// Matches plain, attributed (`@testable`, `@preconcurrency`, …),
  /// access-level and declaration-kind imports, capturing the top-level
  /// module name.
  private func importedModules(in source: String) -> [String] {
    let pattern =
      #/^(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?([A-Za-z_]\w*)/#
    return source.split(whereSeparator: \.isNewline).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let match = try? pattern.firstMatch(in: trimmed) else { return nil }
      return String(match.output.1)
    }
  }
}

final class ProcessAndHDCContractTests: XCTestCase {
  func testExternalFirstDiscoveryAndJobSnapshotRemainStable() throws {
    let printf = URL(fileURLWithPath: "/usr/bin/printf")
    let report = HDCExternalFirstDiscovery.discover(
      HDCDiscoveryRequest(
        userConfiguredPaths: [printf],
        devecoSDKPaths: [printf, URL(fileURLWithPath: "/usr/bin/yes")],
        openHarmonySDKPaths: [try XCTUnwrap(URL(string: "relative/hdc"))]
      )
    )

    XCTAssertEqual(report.candidates.map(\.path.path), ["/usr/bin/printf", "/usr/bin/yes"])
    XCTAssertEqual(report.candidates.map(\.source), [.userConfigured, .devecoSDK])
    XCTAssertTrue(
      report.issues.contains(.pathMustBeAbsolute(path: "relative/hdc", source: .openHarmonySDK)))

    let details = HDCProbeDetails(
      platformTrust: .unknown(reason: "not inspected in this prototype"),
      clientVersion: .known("5.0.0"),
      serverVersion: .known("5.0.0"),
      daemonVersion: .known("5.0.0"),
      serverGeneration: .known(7)
    )
    let snapshot = HDCJobToolchainSnapshot(
      candidate: try XCTUnwrap(report.candidates.first), endpoint: "127.0.0.1:8710",
      details: details)

    XCTAssertEqual(snapshot.path, printf)
    XCTAssertEqual(snapshot.source, .userConfigured)
    XCTAssertEqual(snapshot.serverGeneration, .known(7))
    XCTAssertEqual(snapshot.clientVersion, .known("5.0.0"))
    XCTAssertEqual(snapshot.endpoint, "127.0.0.1:8710")
    XCTAssertEqual(snapshot.platformTrust, .unknown(reason: "not inspected in this prototype"))
  }

  func testSemanticParserRejectsExitZeroFailureFixtureAndStreamsLargeFixture() throws {
    var failureParser = HDCSemanticOutputParser()
    failureParser.consume(ProcessOutputChunk(stream: .stdout, bytes: HDCFixtures.exitZeroFailure))
    XCTAssertEqual(failureParser.finish(exitCode: 0), .failure(.unauthorized))

    var parser = HDCSemanticOutputParser()
    for _ in 0..<HDCFixtures.largeOutputRepeatCount {
      parser.consume(ProcessOutputChunk(stream: .stdout, bytes: HDCFixtures.largeOutputChunk))
    }
    parser.consume(ProcessOutputChunk(stream: .stderr, bytes: HDCFixtures.largeOutputFailureTail))
    XCTAssertGreaterThan(
      HDCFixtures.largeOutputChunk.count * HDCFixtures.largeOutputRepeatCount, 1_000_000)
    XCTAssertEqual(parser.finish(exitCode: 0), .failure(.offline))

    var unknownParser = HDCSemanticOutputParser()
    unknownParser.consume(
      ProcessOutputChunk(stream: .stdout, bytes: Data("unrecognised output".utf8)))
    XCTAssertEqual(unknownParser.finish(exitCode: 0), .unknownOutput)
  }

  func testSemanticParserFindsFailureInLargeChunkBeforeTrailingSuccess() {
    var parser = HDCSemanticOutputParser()
    let bytes = Data(
      ("[Fail] E000003 Unauthorized" + String(repeating: "x", count: 300) + "[Success]").utf8)
    parser.consume(ProcessOutputChunk(stream: .stdout, bytes: bytes))

    XCTAssertEqual(parser.finish(exitCode: 0), .failure(.unauthorized))
  }

  func testSemanticParserRecognisesASCIIMarkerSplitAcrossChunks() {
    var parser = HDCSemanticOutputParser()
    parser.consume(ProcessOutputChunk(stream: .stdout, bytes: Data("prefix [Fa".utf8)))
    parser.consume(ProcessOutputChunk(stream: .stderr, bytes: Data("il] suffix".utf8)))

    XCTAssertEqual(parser.finish(exitCode: 0), .failure(.explicitFailureMarker))
  }

}

private actor RecordingHDCServerLifecycleExecutor: HDCServerLifecycleExecutor {
  private let result: HDCServerLifecycleExecutionOutcome
  private var recordedSteps: [HDCServerLifecycleStep] = []

  init(result: HDCServerLifecycleExecutionOutcome) {
    self.result = result
  }

  func execute(
    _ step: HDCServerLifecycleStep,
    lease _: HDCServerLifecycleDispatchLease
  ) async -> HDCServerLifecycleExecutorResult {
    recordedSteps.append(step)
    return HDCServerLifecycleExecutorResult(outcome: result)
  }

  func steps() -> [HDCServerLifecycleStep] { recordedSteps }
}

/// Reproduces updates from a real asynchronous audit sink: while the
/// supervisor is suspended durably recording intent, the audit actor calls
/// back into the supervisor to change the critical gate or server generation.
private actor IntentMutatingHDCServerLifecycleAuditStore: HDCServerLifecycleAuditStore {
  private enum Error: Swift.Error {
    case unexpectedTerminalReconciliation
  }

  enum Mutation: Sendable {
    case critical(recipient: HDCServerRecipient, state: HDCServerCriticalState)
    case replacement(HDCExistingServerObservation)
  }

  private let mutation: Mutation
  private var supervisor: HDCServerSupervisor?
  private var didMutate = false
  private var entries: [HDCServerLifecycleAuditEvent] = []

  init(mutation: Mutation) {
    self.mutation = mutation
  }

  func attach(to supervisor: HDCServerSupervisor) {
    self.supervisor = supervisor
  }

  func append(_ event: HDCServerLifecycleAuditEvent) async throws {
    entries.append(event)
    guard case .intent = event, !didMutate, let supervisor else { return }
    didMutate = true
    switch mutation {
    case .critical(let recipient, let state):
      await supervisor.updateCriticalState(state, for: recipient)
    case .replacement(let observation):
      await supervisor.observeExistingServer(
        observation, reason: "audit-store probe replaced server")
    }
  }

  nonisolated func appendTerminalReconciliation(_: HDCServerLifecycleReconciliation) throws {
    throw Error.unexpectedTerminalReconciliation
  }

  func events() -> [HDCServerLifecycleAuditEvent] { entries }
}

final class HDCServerSupervisorContractTests: XCTestCase {
  func testGenerationChangeBroadcastsOneHostWideEventToAllAffectedRecipients() async throws {
    let audit = InMemoryHDCServerLifecycleAuditStore()
    let supervisor = HDCServerSupervisor(auditStore: audit)
    await supervisor.register(HDCServerFixtures.deviceA)
    await supervisor.register(HDCServerFixtures.deviceB)
    await supervisor.register(HDCServerFixtures.job)
    await supervisor.register(HDCServerFixtures.isolatedDevice)

    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 4), reason: "initial attach")
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 5), reason: "health probe detected replacement")

    let deviceAEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.deviceA)
    let deviceBEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.deviceB)
    let jobEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.job)
    let isolatedEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.isolatedDevice)

    XCTAssertEqual(deviceAEvents, deviceBEvents)
    XCTAssertEqual(deviceAEvents, jobEvents)
    XCTAssertTrue(isolatedEvents.isEmpty)
    XCTAssertEqual(deviceAEvents.count, 1)
    guard case .generationChanged(let event) = try XCTUnwrap(deviceAEvents.first) else {
      return XCTFail("the shared endpoint must publish a server event, not a device fault")
    }
    XCTAssertEqual(event.endpoint, HDCServerFixtures.sharedEndpoint)
    XCTAssertEqual(event.previousGeneration, 4)
    XCTAssertEqual(event.currentGeneration, 5)
    XCTAssertEqual(event.ownership, .external)
    XCTAssertEqual(event.reason, "health probe detected replacement")
  }

  func testHealthFailureBroadcastsOneHostWideEventToAllAffectedRecipients() async throws {
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    await supervisor.register(HDCServerFixtures.deviceA)
    await supervisor.register(HDCServerFixtures.deviceB)
    await supervisor.register(HDCServerFixtures.job)
    await supervisor.register(HDCServerFixtures.isolatedDevice)
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 4), reason: "initial attach")
    await supervisor.observeExistingServer(
      HDCServerFixtures.unavailableExternalServer(generation: 4), reason: "health probe failed")

    let deviceAEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.deviceA)
    let deviceBEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.deviceB)
    let jobEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.job)
    let isolatedEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.isolatedDevice)
    XCTAssertEqual(deviceAEvents, deviceBEvents)
    XCTAssertEqual(deviceAEvents, jobEvents)
    XCTAssertTrue(isolatedEvents.isEmpty)
    guard case .healthChanged(let event) = try XCTUnwrap(deviceAEvents.first) else {
      return XCTFail("a shared server health failure must not be reported as a device fault")
    }
    XCTAssertEqual(event.endpoint, HDCServerFixtures.sharedEndpoint)
    XCTAssertEqual(event.generation, 4)
    XCTAssertEqual(event.previousHealth, .healthy)
    XCTAssertEqual(event.currentHealth, .unavailable)
    XCTAssertEqual(event.reason, "health probe failed")
  }

  func testExternalAndUnknownAutomaticFailuresLeaveNoLifecycleAuditAndDoNotRewriteState() async {
    for observation in [
      HDCServerFixtures.externalServer(generation: 3),
      HDCServerFixtures.unknownServer(generation: 3),
    ] {
      let audit = InMemoryHDCServerLifecycleAuditStore()
      let supervisor = HDCServerSupervisor(auditStore: audit)
      await supervisor.observeExistingServer(observation, reason: "fixture attach")
      let stateBefore = await supervisor.state(for: HDCServerFixtures.sharedEndpoint)
      await supervisor.recordAutomaticDiagnosticFailure(
        endpoint: HDCServerFixtures.sharedEndpoint,
        reason: "authorization rejected"
      )

      let stateAfter = await supervisor.state(for: HDCServerFixtures.sharedEndpoint)
      let auditEvents = await audit.events()
      XCTAssertEqual(stateAfter, stateBefore)
      XCTAssertFalse(
        auditEvents.contains { event in
          if case .intent = event { return true }
          if case .outcome = event { return true }
          return false
        }
      )
    }
  }

  func testManagedStartUsesItsDedicatedAbsentEndpointPrecondition() async {
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let result = await supervisor.createImpactPreview(
      action: .startManaged,
      endpoint: HDCServerFixtures.sharedEndpoint
    )
    XCTAssertEqual(result, .blocked(.startManagedRequiresAbsentEndpointPrecondition))
  }

  func testManagedOwnershipRequiresAbsentEndpointAndVerifiedPidToolAndEndpointEvidence()
    async throws
  {
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let firstAuthorizationValue = await supervisor.authorizeManagedStart(
      at: HDCServerFixtures.sharedEndpoint)
    let firstAuthorization = try XCTUnwrap(firstAuthorizationValue)
    let mismatchedEvidence = HDCManagedServerLaunchEvidence(
      endpoint: HDCServerFixtures.isolatedEndpoint,
      pid: 910,
      toolPath: URL(fileURLWithPath: "/usr/bin/printf"),
      arguments: [],
      generation: 1,
      version: .known("5.0.0")
    )

    let mismatchedStartAccepted = await supervisor.recordManagedStart(
      authorization: firstAuthorization, evidence: mismatchedEvidence)
    XCTAssertFalse(mismatchedStartAccepted)
    let unverifiedState = await supervisor.state(for: HDCServerFixtures.sharedEndpoint)
    XCTAssertNil(unverifiedState)

    let secondAuthorizationValue = await supervisor.authorizeManagedStart(
      at: HDCServerFixtures.sharedEndpoint)
    let secondAuthorization = try XCTUnwrap(secondAuthorizationValue)
    let fabricatedEvidence = HDCManagedServerLaunchEvidence(
      endpoint: HDCServerFixtures.sharedEndpoint,
      pid: 910,
      toolPath: URL(fileURLWithPath: "/usr/bin/printf"),
      arguments: ["-s", HDCServerFixtures.sharedEndpoint.rawValue, "server"],
      generation: 1,
      version: .known("5.0.0")
    )
    let fabricatedStartAccepted = await supervisor.recordManagedStart(
      authorization: secondAuthorization, evidence: fabricatedEvidence)
    XCTAssertFalse(
      fabricatedStartAccepted,
      "field-shaped PID/path/argv/endpoint values are not live process ownership evidence")
    let stateAfterFabricatedEvidence = await supervisor.state(
      for: HDCServerFixtures.sharedEndpoint)
    XCTAssertNil(stateAfterFabricatedEvidence)
  }

  func testCriticalJobBlocksConfirmedRestartAndNamesSafeBoundary() async throws {
    let audit = InMemoryHDCServerLifecycleAuditStore()
    let supervisor = HDCServerSupervisor(auditStore: audit)
    let executor = RecordingHDCServerLifecycleExecutor(result: .succeeded(resultingGeneration: 9))
    await supervisor.register(HDCServerFixtures.deviceA)
    await supervisor.register(HDCServerFixtures.deviceB)
    await supervisor.register(HDCServerFixtures.job)
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 8), reason: "fixture attach")
    await supervisor.setOtherClientDetection(
      .detected(["DevEco IDE"]), for: HDCServerFixtures.sharedEndpoint)

    let preview = try readyPreview(
      await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: HDCServerFixtures.sharedEndpoint)
    )
    let confirmation = try acceptedConfirmation(await supervisor.confirm(preview.id))
    await supervisor.updateCriticalState(
      .criticalNonInterruptible(
        stepID: "flash-system", safeBoundaryAction: "wait for flash checkpoint"),
      for: HDCServerFixtures.job
    )

    let result = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    guard case .blocked(.criticalJobs(let blockers)) = result else {
      return XCTFail("a critical shared Job must block lifecycle dispatch")
    }
    XCTAssertEqual(
      blockers,
      [
        HDCServerCriticalJob(
          jobID: "job-flash-a", stepID: "flash-system",
          safeBoundaryAction: "wait for flash checkpoint")
      ]
    )
    let dispatchedSteps = await executor.steps()
    XCTAssertTrue(dispatchedSteps.isEmpty)
    let auditEvents = await audit.events()
    XCTAssertEqual(auditEvents.count, 2, "blocked dispatch must not write lifecycle intent/outcome")
  }

  func testCriticalGateIsRecheckedAfterIntentPersistenceBeforeExecutorDispatch() async throws {
    let audit = IntentMutatingHDCServerLifecycleAuditStore(
      mutation: .critical(
        recipient: HDCServerFixtures.job,
        state: .criticalNonInterruptible(
          stepID: "flash-system", safeBoundaryAction: "wait for flash checkpoint")
      )
    )
    let supervisor = HDCServerSupervisor(auditStore: audit)
    await audit.attach(to: supervisor)
    let executor = RecordingHDCServerLifecycleExecutor(result: .succeeded(resultingGeneration: 10))
    await supervisor.register(HDCServerFixtures.job)
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 9), reason: "fixture attach")
    let preview = try readyPreview(
      await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: HDCServerFixtures.sharedEndpoint)
    )
    let confirmation = try acceptedConfirmation(await supervisor.confirm(preview.id))

    let result = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    guard case .blocked(.criticalJobs(let blockers)) = result else {
      return XCTFail("a critical state set while intent is persisted must still block dispatch")
    }
    XCTAssertEqual(
      blockers,
      [
        HDCServerCriticalJob(
          jobID: "job-flash-a", stepID: "flash-system",
          safeBoundaryAction: "wait for flash checkpoint")
      ]
    )
    let dispatchedSteps = await executor.steps()
    XCTAssertTrue(dispatchedSteps.isEmpty)
    let auditEvents = await audit.events()
    guard case .intent(let intent) = auditEvents.dropFirst(2).first,
      case .outcome(let outcomeStepID, let outcomeAuditID, let outcome) = auditEvents.last
    else {
      return XCTFail("a post-intent block must persist both intent and failed outcome")
    }
    XCTAssertEqual(outcomeStepID, intent.id)
    XCTAssertEqual(outcomeAuditID, intent.auditID)
    XCTAssertEqual(outcome, .failed(reason: "blocked after intent persistence"))
  }

  func testGenerationIsRecheckedAfterIntentPersistenceBeforeExecutorDispatch() async throws {
    let audit = IntentMutatingHDCServerLifecycleAuditStore(
      mutation: .replacement(HDCServerFixtures.externalServer(generation: 12))
    )
    let supervisor = HDCServerSupervisor(auditStore: audit)
    await audit.attach(to: supervisor)
    let executor = RecordingHDCServerLifecycleExecutor(result: .succeeded(resultingGeneration: 12))
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 11), reason: "fixture attach")
    let preview = try readyPreview(
      await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: HDCServerFixtures.sharedEndpoint)
    )
    let confirmation = try acceptedConfirmation(await supervisor.confirm(preview.id))

    let result = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    guard case .blocked(.confirmationStale(let replacementPreview)) = result else {
      return XCTFail(
        "generation drift during intent persistence must block dispatch and require a new preview")
    }
    XCTAssertEqual(replacementPreview.snapshot.generation, 12)
    let dispatchedSteps = await executor.steps()
    XCTAssertTrue(dispatchedSteps.isEmpty)
    let auditEvents = await audit.events()
    guard case .intent(let intent) = auditEvents.dropFirst(2).first,
      case .outcome(let outcomeStepID, let outcomeAuditID, let outcome) = auditEvents.last
    else {
      return XCTFail("generation drift after intent must close the audit with a failed outcome")
    }
    XCTAssertEqual(outcomeStepID, intent.id)
    XCTAssertEqual(outcomeAuditID, intent.auditID)
    XCTAssertEqual(outcome, .failed(reason: "blocked after intent persistence"))
  }

  func testConfirmedExternalRestartUsesTypedStepAuditsAndBroadcastsTheSameOutcome() async throws {
    let audit = InMemoryHDCServerLifecycleAuditStore()
    let supervisor = HDCServerSupervisor(auditStore: audit)
    let executor = RecordingHDCServerLifecycleExecutor(result: .succeeded(resultingGeneration: 21))
    await supervisor.register(HDCServerFixtures.deviceA)
    await supervisor.register(HDCServerFixtures.deviceB)
    await supervisor.register(HDCServerFixtures.job)
    await supervisor.register(HDCServerFixtures.isolatedDevice)
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 20), reason: "fixture attach")
    await supervisor.setOtherClientDetection(
      .detected(["DevEco IDE", "terminal hdc"]), for: HDCServerFixtures.sharedEndpoint)

    let preview = try readyPreview(
      await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: HDCServerFixtures.sharedEndpoint)
    )
    XCTAssertEqual(preview.snapshot.endpoint, HDCServerFixtures.sharedEndpoint)
    XCTAssertEqual(preview.snapshot.generation, 20)
    XCTAssertEqual(preview.snapshot.ownership, .external)
    XCTAssertEqual(preview.snapshot.affectedDeviceCoordinators, ["device-a", "device-b"])
    XCTAssertEqual(preview.snapshot.affectedJobs, ["job-flash-a"])
    XCTAssertEqual(
      preview.snapshot.otherClientDetection, .detected(["DevEco IDE", "terminal hdc"]))
    XCTAssertEqual(
      preview.snapshot.expectedInterruption, "HDC requests using this endpoint will be interrupted."
    )
    XCTAssertEqual(
      preview.snapshot.recoveryPath,
      "Re-probe the shared endpoint and reconcile every affected Job.")

    let confirmation = try acceptedConfirmation(await supervisor.confirm(preview.id))
    let result = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    XCTAssertEqual(result, .completed(.succeeded(resultingGeneration: 21)))

    let steps = await executor.steps()
    let step = try XCTUnwrap(steps.first)
    XCTAssertEqual(steps.count, 1)
    XCTAssertEqual(step.action, .restartConfirmedGeneration)
    XCTAssertEqual(step.endpoint, HDCServerFixtures.sharedEndpoint)
    XCTAssertEqual(step.expectedGeneration, 20)
    XCTAssertEqual(step.expectedOwnership, .external)
    XCTAssertEqual(step.impactSnapshotHash, preview.snapshot.scopeHash)
    XCTAssertEqual(step.confirmationID, confirmation.id)
    XCTAssertEqual(step.auditID, confirmation.auditID)

    let stateValue = await supervisor.state(for: HDCServerFixtures.sharedEndpoint)
    let state = try XCTUnwrap(stateValue)
    XCTAssertEqual(state.generation, 21)
    XCTAssertEqual(state.ownership, .external, "manual confirmation must not transfer ownership")

    let deviceAEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.deviceA)
    let deviceBEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.deviceB)
    let jobEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.job)
    let isolatedEvents = await supervisor.takeDeliveredEvents(for: HDCServerFixtures.isolatedDevice)
    XCTAssertEqual(deviceAEvents, deviceBEvents)
    XCTAssertEqual(deviceAEvents, jobEvents)
    XCTAssertTrue(isolatedEvents.isEmpty)
    guard case .lifecycleOutcome(let broadcast) = try XCTUnwrap(deviceAEvents.first) else {
      return XCTFail("affected recipients must receive the lifecycle result")
    }
    XCTAssertEqual(broadcast.stepID, step.id)
    XCTAssertEqual(broadcast.auditID, step.auditID)
    XCTAssertEqual(broadcast.outcome, .succeeded(resultingGeneration: 21))
    XCTAssertFalse(broadcast.requiresReconcile)

    let auditEvents = await audit.events()
    XCTAssertEqual(auditEvents.count, 5)
    guard case .impactPreview(let auditedPreview) = auditEvents[0],
      case .confirmation(let auditedConfirmation) = auditEvents[1],
      case .intent(let auditedStep) = auditEvents[2],
      case .outcome(let outcomeStepID, let outcomeAuditID, let outcome) = auditEvents[3],
      case .reconciliation(let reconciliation) = auditEvents[4]
    else {
      return XCTFail(
        "preview, confirmation, intent, outcome, and terminal reconciliation must be appended in order"
      )
    }
    XCTAssertEqual(auditedPreview, preview)
    XCTAssertEqual(auditedConfirmation, confirmation)
    XCTAssertEqual(auditedStep, step)
    XCTAssertEqual(outcomeStepID, step.id)
    XCTAssertEqual(outcomeAuditID, step.auditID)
    XCTAssertEqual(outcome, .succeeded(resultingGeneration: 21))
    XCTAssertEqual(reconciliation.stepID, step.id)
    XCTAssertEqual(reconciliation.auditID, step.auditID)
    XCTAssertEqual(reconciliation.expectedScopeHash, preview.snapshot.scopeHash)
    XCTAssertEqual(reconciliation.historicalOutcome, .succeeded(resultingGeneration: 21))
    XCTAssertEqual(reconciliation.outwardOutcome, .succeeded(resultingGeneration: 21))
    XCTAssertEqual(reconciliation.observedScope.scopeHash, preview.snapshot.scopeHash)
    XCTAssertEqual(reconciliation.observedScope.generation, 20)
    XCTAssertEqual(reconciliation.observedScope.ownership, .external)
    XCTAssertFalse(reconciliation.requiresReconcile)
  }

  func testGenerationDriftInvalidatesConfirmationAndCreatesANewPreviewWithoutDispatch() async throws
  {
    let audit = InMemoryHDCServerLifecycleAuditStore()
    let supervisor = HDCServerSupervisor(auditStore: audit)
    let executor = RecordingHDCServerLifecycleExecutor(result: .succeeded(resultingGeneration: 2))
    await supervisor.register(HDCServerFixtures.deviceA)
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 1), reason: "fixture attach")

    let preview = try readyPreview(
      await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: HDCServerFixtures.sharedEndpoint)
    )
    let confirmation = try acceptedConfirmation(await supervisor.confirm(preview.id))
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 2), reason: "server replacement")

    let result = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    guard case .blocked(.confirmationStale(let replacementPreview)) = result else {
      return XCTFail("a generation change must force a fresh preview and confirmation")
    }
    XCTAssertEqual(replacementPreview.snapshot.generation, 2)
    XCTAssertEqual(replacementPreview.snapshot.action, .restartConfirmedGeneration)
    XCTAssertNotEqual(replacementPreview.snapshot.scopeHash, preview.snapshot.scopeHash)
    let steps = await executor.steps()
    XCTAssertTrue(steps.isEmpty)
  }

  func testConfirmationPermitsOnlyOneLifecycleDispatchAttempt() async throws {
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let executor = RecordingHDCServerLifecycleExecutor(
      result: .failed(reason: "server refused restart"))
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 7), reason: "fixture attach")
    let preview = try readyPreview(
      await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: HDCServerFixtures.sharedEndpoint)
    )
    let confirmation = try acceptedConfirmation(await supervisor.confirm(preview.id))

    let firstResult = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    let secondResult = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    XCTAssertEqual(firstResult, .completed(.failed(reason: "server refused restart")))
    XCTAssertEqual(secondResult, .blocked(.confirmationNotFound))
    let steps = await executor.steps()
    XCTAssertEqual(steps.count, 1)
  }

  func testUnreliableImpactStateFailsClosedBeforePreviewOrDispatch() async {
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    await supervisor.observeExistingServer(
      HDCServerFixtures.externalServer(generation: 6), reason: "fixture attach")
    await supervisor.setImpactReliability(false, for: HDCServerFixtures.sharedEndpoint)

    let result = await supervisor.createImpactPreview(
      action: .restartConfirmedGeneration,
      endpoint: HDCServerFixtures.sharedEndpoint
    )
    XCTAssertEqual(result, .blocked(.impactCannotBeReliablyDetermined))
  }

  private func readyPreview(
    _ result: HDCServerImpactPreviewResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> HDCServerLifecycleImpactPreview {
    guard case .ready(let preview) = result else {
      XCTFail("expected an impact preview, got \(result)", file: file, line: line)
      throw PreviewExpectationError.notReady
    }
    return preview
  }

  private func acceptedConfirmation(
    _ result: HDCServerConfirmationResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> HDCServerLifecycleConfirmation {
    guard case .accepted(let confirmation) = result else {
      XCTFail("expected a confirmation, got \(result)", file: file, line: line)
      throw PreviewExpectationError.notConfirmed
    }
    return confirmation
  }
}

private enum PreviewExpectationError: Error {
  case notReady
  case notConfirmed
}
