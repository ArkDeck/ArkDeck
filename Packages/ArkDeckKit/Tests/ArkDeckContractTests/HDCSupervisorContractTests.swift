import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class HDCSupervisorContractTests: XCTestCase {
  // TEST-AC-HDC-004-01 / endpointIsolationContract
  func testTEST_AC_HDC_004_01_ExplicitEndpointOnlyOverlaysTheArkDeckChildEnvironment() async throws
  {
    let before = ProcessInfo.processInfo.environment["OHOS_HDC_SERVER_PORT"]
    let selection = try HDCServerEndpointSelector.select(
      explicitEndpoint: "127.0.0.1:19710", inheritedEnvironment: ["OHOS_HDC_SERVER_PORT": "8710"])
    XCTAssertEqual(selection.source, .explicit)
    XCTAssertEqual(selection.endpoint, HDCServerEndpoint("127.0.0.1:19710"))
    XCTAssertEqual(selection.childEnvironment, ["OHOS_HDC_SERVER_PORT": "19710"])

    let result = try await HDCProcessCommandRunner().execute(
      HDCProcessCommand(
        toolchain: fixtureCandidate(), endpoint: selection, arguments: ["endpoint"], timeout: 2))
    XCTAssertEqual(result.execution.termination, .exited(0))
    XCTAssertEqual(
      String(decoding: result.execution.stdout.data, as: UTF8.self), "endpoint-port=19710\n")
    XCTAssertEqual(ProcessInfo.processInfo.environment["OHOS_HDC_SERVER_PORT"], before)
  }

  func testExplicitNonLoopbackEndpointIsPassedToTheRegisteredCheckserverCommand() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m1-006-explicit-host-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invocationLog = root.appending(path: "invocations.log")
    let selection = try HDCServerEndpointSelector.select(
      explicitEndpoint: "hdc.example.invalid:19711")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path])

    let result = await processSupervisor.observeExistingServer(
      endpoint: selection, toolchain: fixtureCandidate())

    XCTAssertEqual(result.classification, .healthy(serverVersion: "3.2.0d"))
    XCTAssertEqual(
      try String(contentsOf: invocationLog, encoding: .utf8),
      "-s\u{1F}hdc.example.invalid:19711\u{1F}checkserver\n")
    let observedState = await supervisor.state(for: selection.endpoint)
    XCTAssertEqual(observedState?.endpoint, HDCServerEndpoint("hdc.example.invalid:19711"))
  }

  // TEST-AC-HDC-001-01 / toolchainLaunchIdentityRecheck
  func testReplacedCandidatePathIsRejectedBeforeAnyChildLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m1-006-toolchain-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appending(path: "hdc")
    let invocationLog = root.appending(path: "invocations.log")
    try FileManager.default.copyItem(at: fixtureExecutable(), to: executable)

    let discovered = try XCTUnwrap(
      HDCExternalFirstDiscovery.discover(
        HDCDiscoveryRequest(userConfiguredPaths: [executable])
      ).candidates.first)
    try Data("replacement that must not execute\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: executable.path)

    do {
      _ = try await HDCProcessCommandRunner().execute(
        HDCProcessCommand(
          toolchain: discovered,
          endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18718"),
          arguments: ["checkserver"],
          additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path]))
      XCTFail("a candidate replaced at the same path must not be launched")
    } catch let error as ProcessExecutionError {
      guard case .executableHashMismatch(let expected, let actual) = error else {
        return XCTFail("unexpected identity-bound launch error: \(error)")
      }
      XCTAssertEqual(expected, discovered.sha256)
      XCTAssertNotEqual(actual, discovered.sha256)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: invocationLog.path),
      "a pre-launch toolchain identity mismatch must keep child invocation count at zero")
  }

  func testSecurityScopedBookmarkReopensConfiguredExecutableAndCarriesLaunchCapability()
    throws
  {
    let suiteName = "ArkDeck.HDC.BookmarkTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m1-006-bookmark-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appending(path: "hdc")
    try FileManager.default.copyItem(at: fixtureExecutable(), to: executable)

    defaults.set(
      [executable.path],
      forKey: HDCApplicationDiagnosticsConfiguration.userConfiguredPathsPreferenceKey)
    let legacyPathRequest = HDCApplicationDiagnosticsConfiguration.discoveryRequest(
      userDefaults: defaults, arguments: [], environment: [:])
    XCTAssertTrue(
      legacyPathRequest.userConfiguredPaths.isEmpty,
      "a persisted pathname alone must not be treated as sandbox authority after relaunch")

    try HDCApplicationDiagnosticsConfiguration.persistUserConfiguredExecutable(
      executable, userDefaults: defaults)
    let reopenedRequest = HDCApplicationDiagnosticsConfiguration.discoveryRequest(
      userDefaults: defaults, arguments: [], environment: [:])
    XCTAssertEqual(reopenedRequest.userConfiguredPaths, [executable.standardizedFileURL])
    XCTAssertNotNil(reopenedRequest.securityScopedBookmarks[executable.standardizedFileURL.path])

    let candidate = try XCTUnwrap(
      HDCExternalFirstDiscovery.discover(reopenedRequest).candidates.first)
    XCTAssertEqual(candidate.path, executable.standardizedFileURL)
    XCTAssertNotNil(candidate.securityScopedBookmark)
    XCTAssertTrue(HDCCandidateIdentityVerifier.matches(candidate))
  }

  // TEST-AC-HDC-001-01 / toolchainContract
  func testTEST_AC_HDC_001_01_SnapshotRemainsAValueWhenSelectionChanges() throws {
    let candidate = fixtureCandidate()
    let details = HDCProbeDetails(
      platformTrust: .unknown(reason: "fixture has no codesign evidence"),
      clientVersion: .known("3.2.0d"), serverVersion: .known("3.2.0d"),
      daemonVersion: .unknown(reason: "not exposed by checkserver"), serverGeneration: .known(4))
    let initial = HDCJobToolchainSnapshot(
      candidate: candidate, endpoint: "127.0.0.1:8710", details: details)
    _ = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:19710")
    XCTAssertEqual(initial.path, candidate.path)
    XCTAssertEqual(initial.sha256, candidate.sha256)
    XCTAssertEqual(initial.endpoint, "127.0.0.1:8710")
    XCTAssertEqual(initial.serverGeneration, .known(4))
  }

  // TEST-AC-HDC-002-01 / supervisorContract and
  // TEST-MAC-M1-HDC-001 / real-child-process supervisor matrix
  func testTEST_AC_HDC_002_01_CheckserverProbeDrivesOneHostWideHealthEvent() async throws {
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18710")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let deviceA = HDCServerRecipient(
      id: "device-a", kind: .deviceCoordinator, endpoint: endpoint.endpoint)
    let deviceB = HDCServerRecipient(
      id: "device-b", kind: .deviceCoordinator, endpoint: endpoint.endpoint)
    await supervisor.register(deviceA)
    await supervisor.register(deviceB)

    let healthyProbe = HDCServerProcessSupervisor(supervisor: supervisor)
    let healthy = await healthyProbe.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())
    XCTAssertEqual(healthy.classification, .healthy(serverVersion: "3.2.0d"))
    let observedState = await supervisor.state(for: endpoint.endpoint)
    XCTAssertEqual(observedState?.health, .healthy)
    XCTAssertEqual(
      observedState?.generationEvidence,
      .unknown(reason: "checkserver does not provide a verifiable server identity or generation"))
    XCTAssertEqual(observedState?.ownership, .unknown)

    let failedProbe = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_CHECKSERVER_MODE": "offline"])
    let failed = await failedProbe.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())
    guard case .unavailable = failed.classification else {
      return XCTFail("registered offline output must be unavailable")
    }
    let first = await supervisor.takeDeliveredEvents(for: deviceA)
    let second = await supervisor.takeDeliveredEvents(for: deviceB)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.count, 2)
    guard case .healthChanged(let event) = try XCTUnwrap(first.first) else {
      return XCTFail("probe failure must revoke the formerly observed health")
    }
    XCTAssertEqual(event.previousHealth, .healthy)
    XCTAssertEqual(event.currentHealth, .unknown)
    guard case .diagnostic(_, let reason) = try XCTUnwrap(first.last) else {
      return XCTFail("probe failure must remain a host-wide diagnostic event")
    }
    XCTAssertEqual(reason, "checkserver emitted a registered failure result")
    let failedState = await supervisor.state(for: endpoint.endpoint)
    XCTAssertEqual(failedState?.ownership, .unknown)
    XCTAssertEqual(failedState?.health, .unknown)
    guard case .unknown = failedState?.generationEvidence else {
      return XCTFail("probe failure must revoke generation evidence")
    }
  }

  // TEST-AC-HDC-003-01 / diagnosticArgvIsClosed
  func testDiagnosticsProcessSupervisorCanExpressOnlyCheckserver() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m1-006-diagnostic-argv-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invocationLog = root.appending(path: "fake-hdc-invocations.log")
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18716")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let diagnosticSupervisor = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path])

    _ = await diagnosticSupervisor.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())

    let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    XCTAssertEqual(invocations, ["-s\u{1F}127.0.0.1:18716\u{1F}checkserver"])
    XCTAssertEqual(
      invocations.filter {
        $0.contains("kill") || $0.contains("spawn-sub") || $0.contains("killall-sub")
      }
      .count,
      0)
  }

  // TEST-AC-HDC-010-03 / unverifiedCheckserverGeneration
  func testHealthyCheckserverReplacementNeverCreatesALifecycleEligibleGeneration() async throws {
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18717")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = HDCServerProcessSupervisor(supervisor: supervisor)

    _ = await processSupervisor.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())
    // A replacement between two healthy responses is observationally
    // indistinguishable to `checkserver`; both results must remain ineligible
    // for preview/confirmation rather than reusing an invented generation.
    _ = await processSupervisor.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())

    let observedState = await supervisor.state(for: endpoint.endpoint)
    let state = try XCTUnwrap(observedState)
    XCTAssertEqual(state.health, .healthy)
    guard case .unknown = state.generationEvidence else {
      return XCTFail("checkserver must not manufacture a verified generation")
    }
    let preview = await supervisor.createImpactPreview(
      action: .restartConfirmedGeneration, endpoint: endpoint.endpoint)
    XCTAssertEqual(preview, .blocked(.impactCannotBeReliablyDetermined))
  }

  // TEST-AC-HDC-005-01 / checkserver semantic and version compatibility gate
  func testCheckserverRejectsFailureStderrAndReportsVersionMismatchUnverified() async throws {
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18711")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let failureProbe = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_CHECKSERVER_MODE": "stderr-failure"])
    let failure = await failureProbe.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())
    guard case .unavailable = failure.classification else {
      return XCTFail("healthy-looking stdout with registered failure stderr must not be healthy")
    }

    let mismatchProbe = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_CHECKSERVER_MODE": "mismatch"])
    let mismatch = await mismatchProbe.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())
    XCTAssertEqual(
      mismatch.classification,
      .unknown(reason: "checkserver output is outside the registered pinned healthy family"))
    let observedState = await supervisor.state(for: endpoint.endpoint)
    XCTAssertNil(observedState, "failed probes must not manufacture endpoint ownership or health")

    let invalidIdentity = HDCCandidate(
      path: fixtureCandidate().path,
      source: .userConfigured,
      sha256: String(repeating: "0", count: 64))
    let identityFailure = await mismatchProbe.observeExistingServer(
      endpoint: endpoint, toolchain: invalidIdentity)
    XCTAssertEqual(
      identityFailure.classification,
      .unknown(reason: "checkserver process could not run"))
    let identityFailureState = await supervisor.state(for: endpoint.endpoint)
    XCTAssertNil(identityFailureState)
  }

  // TEST-AC-HDC-001-02 / pinnedClientVersionProcessProbe
  func testTEST_AC_HDC_001_02_ClientVersionUsesRegisteredPinnedProcessProbe() async throws {
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18711")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let probe = HDCServerProcessSupervisor(supervisor: supervisor)
    let result = await probe.probeClientVersion(endpoint: endpoint, toolchain: fixtureCandidate())
    XCTAssertEqual(result.clientVersion, .known("3.2.0d"))
    XCTAssertEqual(result.execution.termination, .exited(0))
    XCTAssertEqual(String(decoding: result.execution.stdout.data, as: UTF8.self), "Ver: 3.2.0d\n")
  }

  // TEST-AC-HDC-005-01 / adapterGolden
  func testTEST_AC_HDC_005_01_RegisteredGoldenBytesUseOnlyTheDeclaredSemanticFamilies() throws {
    let root = try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
    let cases: [(String, HDCCommandSemanticResult)] = [
      ("1.0.0/failure-unauthorized/stdout.bin", .failure(.unauthorized)),
      ("1.0.0/failure-offline/stdout.bin", .failure(.offline)),
      ("1.0.0/success-uninstall/stdout.bin", .success),
      ("1.0.0/healthy-checkserver/stdout.bin", .unknownOutput),
      ("1.0.0/version/stdout.bin", .unknownOutput),
    ]
    for (path, expected) in cases {
      var evaluator = HDCRegisteredSemanticEvaluator(commandFamily: .uninstall)
      evaluator.consume(
        ProcessOutputChunk(stream: .stdout, bytes: try Data(contentsOf: root.appending(path: path)))
      )
      XCTAssertEqual(evaluator.finish(execution: exitedZero()), expected, path)
    }

    var unknown = HDCRegisteredSemanticEvaluator(commandFamily: .uninstall)
    unknown.consume(
      ProcessOutputChunk(
        stream: .stdout,
        bytes: Data("[Info] msg:uninstall bundle successfully.\r\nAppMod finish\r\n".utf8)))
    XCTAssertEqual(unknown.finish(execution: exitedZero()), .unknownOutput)

    var splitSuccess = HDCRegisteredSemanticEvaluator()
    splitSuccess.consume(
      ProcessOutputChunk(stream: .stdout, bytes: Data("[Info] msg:uninstall ".utf8)))
    splitSuccess.consume(
      ProcessOutputChunk(stream: .stdout, bytes: Data("bundle successfully.\r\nApp".utf8)))
    splitSuccess.consume(ProcessOutputChunk(stream: .stdout, bytes: Data("Mod finish\r\n".utf8)))
    XCTAssertEqual(splitSuccess.finish(execution: exitedZero()), .unknownOutput)

    var version = HDCRegisteredSemanticEvaluator(commandFamily: .version)
    version.consume(
      ProcessOutputChunk(
        stream: .stdout,
        bytes: try Data(contentsOf: root.appending(path: "1.0.0/version/stdout.bin"))))
    XCTAssertEqual(version.finish(execution: exitedZero()), .success)
  }

  // TEST-AC-HDC-003-01 / productionDiagnosticsUseCase
  // TEST-AC-HDC-010-02 / lifecycleAuditContract
  func testProductionDiagnosticsUseCaseConsumesSupervisorStateAndOnlyRequestsConfirmation()
    async throws
  {
    let endpoint = HDCServerEndpoint("127.0.0.1:18713")
    let audit = InMemoryHDCServerLifecycleAuditStore()
    let supervisor = HDCServerSupervisor(auditStore: audit)
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 5,
          ownership: .external)),
      reason: "fixture verified checkserver state")
    let candidate = fixtureCandidate()
    let snapshot = HDCJobToolchainSnapshot(
      candidate: candidate, endpoint: endpoint.rawValue,
      details: HDCProbeDetails(
        platformTrust: .unknown(reason: "fixture trust inspection"),
        clientVersion: .known("3.2.0d"), serverVersion: .known("3.2.0d"),
        daemonVersion: .unknown(reason: "not exposed by checkserver"), serverGeneration: .known(5)))
    let useCase = HDCServerDiagnosticsUseCase(
      supervisor: supervisor, snapshot: snapshot, authorization: .ready,
      channelProtection: .unverifiedAssumeUnprotected)

    let current = await useCase.refresh()
    XCTAssertEqual(current.serverHealth, .healthy)
    XCTAssertEqual(current.ownership, .external)
    XCTAssertEqual(
      current.lifecycleRecovery,
      .unavailable(
        reason: "No recovery impact preview has been requested"))

    let preview = await useCase.requestRecoveryImpactPreview()
    guard case .preview(let previewState) = preview.lifecycleRecovery else {
      return XCTFail("the UI use case must surface a durable impact preview")
    }
    XCTAssertEqual(previewState.snapshot.generation, 5)
    XCTAssertEqual(previewState.snapshot.ownership, .external)
    let confirmed = await useCase.confirmRecoveryImpactPreview()
    guard case .confirmed(let confirmation) = confirmed.lifecycleRecovery else {
      return XCTFail("the UI use case must surface the explicit confirmation result")
    }
    XCTAssertEqual(confirmation.generation, 5)
    let auditEventCount = audit.events().count
    XCTAssertEqual(auditEventCount, 2)
  }

  // TEST-AC-HDC-001-02 / productionDiagnosticsUseCase
  func testReadOnlyProductionDiagnosticsReportsConfigurationStateRatherThanUnprobed() async {
    let useCase = HDCReadOnlyDiagnosticsUseCase(
      discoveryRequest: HDCDiscoveryRequest(), inheritedEnvironment: [:])
    let presentation = await useCase.refresh()
    XCTAssertEqual(presentation.endpoint, "127.0.0.1:8710")
    XCTAssertEqual(presentation.absolutePath, "unknown (no configured candidate)")
    XCTAssertEqual(
      presentation.authorization,
      .unavailable(reason: "No user-configured or SDK HDC candidate is available for diagnostics"))
    XCTAssertEqual(
      presentation.lifecycleRecovery,
      .unavailable(reason: "No user-configured or SDK HDC candidate is available for diagnostics"))
  }

  // TEST-AC-HDC-003-01 / applicationDiagnosticsComposition
  func testApplicationDiagnosticsUsesConfiguredDiscoveryThenSessionBackedRecovery() async throws {
    let endpoint = HDCServerEndpoint("127.0.0.1:18714")
    let candidate = fixtureCandidate()
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let application = HDCApplicationDiagnosticsProvider(
      discoveryRequest: HDCDiscoveryRequest(userConfiguredPaths: [candidate.path]),
      inheritedEnvironment: ["OHOS_HDC_SERVER_PORT": "18714"])

    let discovered = await application.refresh()
    XCTAssertEqual(
      discovered.absolutePath,
      candidate.path.resolvingSymlinksInPath().standardizedFileURL.path)
    XCTAssertEqual(discovered.source, HDCCandidateSource.userConfigured.rawValue)
    XCTAssertEqual(discovered.endpoint, endpoint.rawValue)

    let composition = try HDCSessionDiagnosticsBootstrap.makeHost(
      sessionRoot: root, sessionID: "application-hdc", jobID: "application-hdc-job",
      toolchain: candidate,
      snapshot: HDCJobToolchainSnapshot(
        candidate: candidate, endpoint: endpoint.rawValue,
        details: HDCProbeDetails(
          platformTrust: .unknown(reason: "fixture"), clientVersion: .known("3.2.0d"),
          serverVersion: .known("3.2.0d"),
          daemonVersion: .unknown(reason: "not exposed"), serverGeneration: .known(4))),
      authorization: .ready)
    await composition.supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 4,
          ownership: .external)),
      reason: "fixture verified session state")
    await application.attachSessionDiagnostics(composition.diagnostics)

    let preview = await application.requestRecoveryImpactPreview()
    guard case .preview = preview.lifecycleRecovery else {
      return XCTFail("attached Session diagnostics must supply a recovery preview")
    }
    let confirmed = await application.confirmRecoveryImpactPreview()
    guard case .confirmed = confirmed.lifecycleRecovery else {
      return XCTFail("attached Session diagnostics must supply confirmation recovery state")
    }
    let layout = try SessionLayout(
      sessionID: "application-hdc", jobID: "application-hdc-job", root: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.sessionAuditURL.path))
  }

  func testProductionCompositionBindsCoreToolchainIntentTypedStepExecutorAndFinalizer()
    async throws
  {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let candidate = fixtureCandidate()
    let endpoint = HDCServerEndpoint("127.0.0.1:18717")
    let jobID = "production-hdc-job"
    let invocationLog = root.appending(path: "production-composition-invocations.log")
    let snapshot = HDCJobToolchainSnapshot(
      candidate: candidate, endpoint: endpoint.rawValue,
      details: HDCProbeDetails(
        platformTrust: .unknown(reason: "fixture trust is not platform evidence"),
        clientVersion: .known("3.2.0d"),
        serverVersion: .known("3.2.0d"),
        daemonVersion: .unknown(reason: "not exposed by registered profile"),
        serverGeneration: .known(7)))
    let composition = try HDCSessionDiagnosticsBootstrap.makeHost(
      sessionRoot: root,
      sessionID: "production-hdc-session",
      jobID: jobID,
      toolchain: candidate,
      snapshot: snapshot,
      authorization: .ready,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      postDispatchProbe: { observed in observed == endpoint ? .generation(8) : nil })
    let lifecycle = try XCTUnwrap(composition.lifecycle)
    let fixedIntent = try XCTUnwrap(composition.toolchainIntent)
    let reopenedIntent = try await lifecycle.reopenToolchainIntent()
    XCTAssertEqual(reopenedIntent, fixedIntent)
    XCTAssertEqual(fixedIntent.executablePath, candidate.path.path)
    XCTAssertEqual(fixedIntent.executableSHA256, candidate.sha256)
    XCTAssertEqual(fixedIntent.endpoint, endpoint.rawValue)
    XCTAssertEqual(fixedIntent.serverGeneration, .known(7))

    await composition.supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 7,
          ownership: .external)),
      reason: "fixture verified production composition state")
    let previewPresentation = await composition.diagnostics.requestRecoveryImpactPreview()
    guard case .preview = previewPresentation.lifecycleRecovery else {
      return XCTFail("production diagnostics must create a durable preview")
    }
    let confirmedPresentation = await composition.diagnostics.confirmRecoveryImpactPreview()
    guard case .confirmed(let confirmation) = confirmedPresentation.lifecycleRecovery else {
      return XCTFail("production diagnostics must retain the accepted confirmation")
    }

    let dispatch = await lifecycle.dispatch(confirmation: confirmation)
    XCTAssertEqual(dispatch, .completed(.succeeded(resultingGeneration: 8)))
    XCTAssertEqual(
      try String(contentsOf: invocationLog, encoding: .utf8),
      "-s\u{1F}127.0.0.1:18717\u{1F}kill\u{1F}-r\n")
    let records = try await lifecycle.replay(auditID: confirmation.auditID)
    XCTAssertEqual(
      records.map { $0.details["eventType"] },
      [
        .string("impactPreview"), .string("confirmation"),
        .string("jobToolchainIntentBinding"), .string("intent"),
        .string("actualCommand"), .string("launchWindowEntered"),
        .string("outcome"), .string("reconciliation"),
      ])
    let bindingRecord = try XCTUnwrap(
      records.first { $0.details["eventType"] == .string("jobToolchainIntentBinding") })
    let bindingJSON = try XCTUnwrap(bindingRecord.details["binding"])
    let binding = try JSONDecoder().decode(
      JobToolchainIntentBinding.self, from: JSONEncoder().encode(bindingJSON))
    XCTAssertEqual(binding.intent, fixedIntent)
    XCTAssertEqual(binding.step.kind, .mutateHDCServerLifecycle)
    XCTAssertEqual(binding.step.effect, .destructive)
    XCTAssertEqual(records[3].details["stepId"], .string(binding.step.id))
    let launchReceipt = try XCTUnwrap(
      records.first { $0.details["eventType"] == .string("launchWindowEntered") })
    XCTAssertEqual(
      launchReceipt.details["authorizedExecutable"], .string(fixedIntent.executablePath))
    XCTAssertEqual(launchReceipt.details["executableSha256"], .string(fixedIntent.executableSHA256))

    let restoredManifestConfirmation = await lifecycle.manifestConfirmation(
      auditID: confirmation.auditID)
    let manifestConfirmation = try XCTUnwrap(restoredManifestConfirmation)
    let layout = try SessionLayout(
      sessionID: "production-hdc-session", jobID: jobID, root: root)
    let hdcStep = HDCServerLifecycleStep(
      id: try XCTUnwrap(UUID(uuidString: binding.step.id)),
      auditID: confirmation.auditID,
      action: confirmation.action,
      endpoint: confirmation.endpoint,
      expectedGeneration: confirmation.generation,
      expectedOwnership: .external,
      impactSnapshotHash: confirmation.scopeHash,
      confirmationID: confirmation.id)
    let manifest = try lifecycleManifest(
      layout: layout, step: hdcStep, confirmation: manifestConfirmation)
    try appendSuccessfulLifecycleJournal(layout: layout, manifest: manifest, step: hdcStep)
    let published = try await lifecycle.publishFinalManifest(
      manifest, auditID: confirmation.auditID)
    XCTAssertEqual(published.sha256, manifest.sha256)
  }

  // TEST-AC-HDC-002-01 / sharedHostSupervisorSessionComposition
  func testAttachedSessionsShareOneHostWideSupervisorAndFanOut() async throws {
    let endpoint = HDCServerEndpoint("127.0.0.1:18715")
    let candidate = fixtureCandidate()
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let snapshot = HDCJobToolchainSnapshot(
      candidate: candidate, endpoint: endpoint.rawValue,
      details: HDCProbeDetails(
        platformTrust: .unknown(reason: "fixture"), clientVersion: .known("3.2.0d"),
        serverVersion: .known("3.2.0d"),
        daemonVersion: .unknown(reason: "not exposed"), serverGeneration: .known(3)))
    let host = try HDCSessionDiagnosticsBootstrap.makeHost(
      sessionRoot: root, sessionID: "host-hdc", jobID: "host-hdc-job", toolchain: candidate,
      snapshot: snapshot,
      authorization: .ready)
    let attached = HDCSessionDiagnosticsBootstrap.makeAttached(
      supervisor: host.supervisor, snapshot: snapshot, authorization: .ready)

    XCTAssertTrue(host.supervisor === attached.supervisor)
    await host.supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 3,
          ownership: .external)),
      reason: "fixture initial host state")
    let firstSession = HDCServerRecipient(id: "host-session-job", kind: .job, endpoint: endpoint)
    let secondSession = HDCServerRecipient(
      id: "attached-session-job", kind: .job, endpoint: endpoint)
    await host.supervisor.register(firstSession)
    await attached.supervisor.register(secondSession)

    await attached.supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 4,
          ownership: .external)),
      reason: "fixture verified server replacement")
    let hostEvents = await host.supervisor.takeDeliveredEvents(for: firstSession)
    let attachedEvents = await attached.supervisor.takeDeliveredEvents(for: secondSession)
    XCTAssertEqual(hostEvents, attachedEvents)
    XCTAssertEqual(hostEvents.count, 1)
    guard case .generationChanged(let event) = try XCTUnwrap(hostEvents.first) else {
      return XCTFail("both Session recipients must receive the one host-wide generation event")
    }
    XCTAssertEqual(event.previousGeneration, 3)
    XCTAssertEqual(event.currentGeneration, 4)
  }

  // TEST-MAC-M1-HDC-001 / fake-hdc real-child-process supervisor matrix
  func testTEST_MAC_M1_HDC_001_FakeHDCProcessFaultMatrixHasNoImplicitSuccess() async throws {
    let runner = HDCProcessCommandRunner()
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18710")
    let expected: [([String], HDCCommandSemanticResult)] = [
      (["uninstall", "com.example.waterflowdemo"], .success),
      (["unauthorized"], .failure(.unauthorized)),
      (["offline"], .failure(.offline)),
      (["unknown"], .unknownOutput),
      (["checkserver"], .unknownOutput),
      (["-s", "hdc.example.invalid:18710", "checkserver"], .unknownOutput),
      (["-v"], .success),
      (["version"], .unknownOutput),
    ]
    for (arguments, semantic) in expected {
      let result = try await runner.execute(
        HDCProcessCommand(
          toolchain: fixtureCandidate(), endpoint: endpoint, arguments: arguments, timeout: 2))
      XCTAssertEqual(result.execution.termination, .exited(0), arguments.description)
      XCTAssertEqual(result.semantic, semantic, arguments.description)
      if arguments.first == "uninstall" {
        let goldenRoot = try XCTUnwrap(Bundle.module.url(forResource: "Golden", withExtension: nil))
        let golden = try Data(
          contentsOf: goldenRoot.appending(path: "1.0.0/success-uninstall/stdout.bin"))
        XCTAssertEqual(result.execution.stdout.data, golden)
      }
    }

    let crash = try await runner.execute(
      HDCProcessCommand(
        toolchain: fixtureCandidate(), endpoint: endpoint, arguments: ["crash"], timeout: 2))
    XCTAssertEqual(crash.execution.termination, .exited(23))
    guard case .failure = crash.semantic else {
      return XCTFail("crash cannot be a semantic success")
    }

    let slow = try await runner.execute(
      HDCProcessCommand(
        toolchain: fixtureCandidate(), endpoint: endpoint, arguments: ["slow"], timeout: 2))
    XCTAssertEqual(slow.execution.termination, .exited(0))
    XCTAssertEqual(slow.semantic, .failure(.offline))

    let hang = try await runner.execute(
      HDCProcessCommand(
        toolchain: fixtureCandidate(), endpoint: endpoint, arguments: ["hang"], timeout: 0.2))
    XCTAssertEqual(hang.execution.termination, .timedOut)
    guard case .failure = hang.semantic else {
      return XCTFail("hang timeout cannot be a semantic success")
    }

    let oversized = try await runner.execute(
      HDCProcessCommand(
        toolchain: fixtureCandidate(), endpoint: endpoint, arguments: ["oversized"], timeout: 5))
    guard case .failure = oversized.semantic else {
      return XCTFail("oversized fault output must never become semantic success")
    }
    XCTAssertTrue(oversized.execution.stdout.wasTruncated)
    XCTAssertGreaterThan(oversized.execution.stdout.totalByteCount, Int64(64 * 1024))
  }

  // TEST-AC-HDC-007-01 / authorizationWorkflowContract and
  // TEST-AC-HDC-007-02 / authorizationFaultInjection
  func testTEST_AC_HDC_007_AuthorizationPollingIsBoundedAndNeverMutatesLifecycle() async {
    let workflow = HDCAuthorizationWorkflow()
    let readyCounter = HDCProbeCounter()
    let ready = await workflow.poll(
      policy: HDCAuthorizationPollingPolicy(maximumAttempts: 3, pollingInterval: .zero)
    ) { _ in
      let attempt = await readyCounter.next()
      return attempt == 2 ? .ready : .unauthorized
    }
    XCTAssertEqual(ready, .ready)
    let readyAttemptCount = await readyCounter.value()
    XCTAssertEqual(readyAttemptCount, 2)

    let timedOutCounter = HDCProbeCounter()
    let timedOut = await workflow.poll(
      policy: HDCAuthorizationPollingPolicy(maximumAttempts: 2, pollingInterval: .zero)
    ) { _ in
      _ = await timedOutCounter.next()
      return .unauthorized
    }
    XCTAssertEqual(timedOut, .timedOut)
    let timedOutAttemptCount = await timedOutCounter.value()
    XCTAssertEqual(timedOutAttemptCount, 2)
    let denied = await workflow.poll(policy: HDCAuthorizationPollingPolicy(maximumAttempts: 2)) {
      _ in
      .denied(reason: "device declined trust")
    }
    XCTAssertEqual(denied, .denied(reason: "device declined trust"))
    XCTAssertTrue(timedOut.hasNonDestructiveRetry)
  }

  func testAuthorizationCancellationAfterAnUncooperativeProbeReturnsCancelled() async {
    let workflow = HDCAuthorizationWorkflow()
    let gate = BlockingAuthorizationProbe()
    let polling = Task {
      await workflow.poll(policy: HDCAuthorizationPollingPolicy(maximumAttempts: 1)) { _ in
        await gate.waitForRelease()
        return .ready
      }
    }
    await gate.waitUntilEntered()
    polling.cancel()
    await gate.release()

    let result = await polling.value
    XCTAssertEqual(result, .cancelled)
  }

  func testAuthorizationDeadlineReturnsEvenWhenProbeIgnoresCancellation() async {
    let workflow = HDCAuthorizationWorkflow()
    let gate = BlockingAuthorizationProbe()
    let clock = ContinuousClock()
    let started = clock.now

    let result = await workflow.poll(
      policy: HDCAuthorizationPollingPolicy(
        maximumAttempts: 2,
        perProbeTimeout: .milliseconds(30),
        overallTimeout: .milliseconds(100),
        pollingInterval: .milliseconds(5))
    ) { _ in
      await gate.waitForRelease()
      return .ready
    }

    XCTAssertEqual(result, .timedOut)
    XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    await gate.release()
  }

  // TEST-AC-HDC-006-01 / platformFileAccessContract
  func testTEST_AC_HDC_006_01_KeyAccessFailureIsDiagnostic() async {
    let workflow = HDCAuthorizationWorkflow()
    let result = await workflow.poll(policy: HDCAuthorizationPollingPolicy(maximumAttempts: 1)) {
      _ in
      .keyAccessDenied(reason: "fixture key permissions denied")
    }

    XCTAssertEqual(result, .keyAccessDenied(reason: "fixture key permissions denied"))
    XCTAssertTrue(result.hasNonDestructiveRetry)
  }

  // TEST-AC-HDC-008-01 / securityStateContract
  func testTEST_AC_HDC_008_AuthorizationDoesNotImplyChannelProtection() {
    let presentation = HDCSecurityPresentation(
      authorization: .ready, protection: .unverifiedAssumeUnprotected, transportIsTCP: true)
    XCTAssertEqual(presentation.authorization, .ready)
    XCTAssertEqual(presentation.protection, .unverifiedAssumeUnprotected)
    XCTAssertNotNil(presentation.tcpWarning)
  }

  // TEST-AC-HDC-009-01 / subserverCallCounter
  func testTEST_AC_HDC_009_ReadOnlySubserverObservationInvokesOnlyCheckserver() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m1-006-subserver-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invocationLog = root.appending(path: "fake-hdc-invocations.log")
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18712")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path])

    let result = await processSupervisor.observeExistingServer(
      endpoint: endpoint, toolchain: fixtureCandidate())
    XCTAssertEqual(result.classification, .healthy(serverVersion: "3.2.0d"))
    let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    XCTAssertEqual(invocations, ["-s\u{1F}127.0.0.1:18712\u{1F}checkserver"])
    XCTAssertFalse(invocations.contains { $0.contains("spawn-sub") || $0.contains("killall-sub") })
  }

  // TEST-AC-HDC-010-02 / lifecycleAuditContract
  func testTEST_AC_HDC_010_02_ConfirmedLifecyclePersistsActualArgvAndReopensByCorrelation()
    async throws
  {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let auditID = UUID()
    let invocationLog = root.appending(path: "fixture-invocations.log")
    let step = try await persistConfirmedLifecycle(
      root: root, auditID: auditID, invocationLog: invocationLog)

    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let reopened = try FileDurableSessionAuditStore(layout: layout)
    let reopenedAdapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: reopened, manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-18T11:20:00Z" })
    let records = try reopened.replay(correlationID: auditID.uuidString)
    XCTAssertEqual(records.count, 7)
    XCTAssertEqual(
      records.map(\.category),
      [.preview, .confirmation, .intent, .intent, .intent, .outcome, .outcome])
    let actual = try XCTUnwrap(
      records.first { $0.details["eventType"] == .string("actualCommand") })
    XCTAssertEqual(actual.details["stepId"], .string(step.id.uuidString))
    XCTAssertEqual(actual.details["endpoint"], .string("127.0.0.1:18710"))
    XCTAssertEqual(
      actual.details["argv"],
      .array([.string("-s"), .string("127.0.0.1:18710"), .string("kill"), .string("-r")]))
    XCTAssertEqual(actual.details["executable"], .string(fixtureExecutable().path))
    let launchWindow = try XCTUnwrap(
      records.first { $0.details["eventType"] == .string("launchWindowEntered") })
    XCTAssertEqual(launchWindow.details["stepId"], .string(step.id.uuidString))
    XCTAssertEqual(launchWindow.details["argv"], actual.details["argv"])
    XCTAssertEqual(launchWindow.details["executable"], actual.details["executable"])
    let restoredConfirmation = await reopenedAdapter.manifestConfirmation(auditID: auditID)
    let confirmation = try XCTUnwrap(restoredConfirmation)
    XCTAssertEqual(confirmation.relatedStepIDs, [step.id.uuidString])
    XCTAssertEqual(confirmation.scopeHash.count, 64)
    XCTAssertEqual(confirmation.decision, "accepted")
    XCTAssertEqual(confirmation.actor, "user")
    XCTAssertEqual(confirmation.decidedAt, "2026-07-18T11:20:00Z")
    let restoredOutcome = await reopenedAdapter.resolvedLifecycleOutcome(auditID: auditID)
    XCTAssertEqual(restoredOutcome, .succeeded(resultingGeneration: 8))
    let manifest = try lifecycleManifest(
      layout: layout, step: step, confirmation: confirmation)
    try appendSuccessfulLifecycleJournal(layout: layout, manifest: manifest, step: step)
    let published = try await reopenedAdapter.publishFinalManifest(manifest, auditID: auditID)
    XCTAssertEqual(published.sha256, manifest.sha256)
    XCTAssertEqual(
      try String(contentsOf: invocationLog, encoding: .utf8),
      "-s\u{1F}127.0.0.1:18710\u{1F}kill\u{1F}-r\n")
    let resumedExecutor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(
        explicitEndpoint: step.endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      durableAuthorization: reopenedAdapter,
      dispatchLeaseValidator: FixtureLifecycleLeaseValidator(),
      postDispatchProbe: { _ in .generation(9) })
    let resumedResult = await resumedExecutor.execute(step, lease: fixtureLease(for: step))
    XCTAssertEqual(
      resumedResult.outcome,
      .failed(
        reason:
          "lifecycle dispatch lacks an unused durable preview, confirmation, and intent authorization"
      ))
    XCTAssertEqual(
      try String(contentsOf: invocationLog, encoding: .utf8),
      "-s\u{1F}127.0.0.1:18710\u{1F}kill\u{1F}-r\n")
    let auditData = try Data(contentsOf: layout.sessionAuditURL)
    let auditHash = SHA256.hash(data: auditData).map { String(format: "%02x", $0) }.joined()
    print("TASK-M1-006 durable_audit_records=\(records.count) sha256=\(auditHash)")
  }

  func testDurableLifecycleReconciliationPersistsTheNewerObservedGeneration() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let layout = try SessionLayout(
      sessionID: "session-reconcile", jobID: "job-reconcile", root: root)
    let auditID = UUID()
    let stepID = UUID()
    let endpoint = HDCServerEndpoint("127.0.0.1:18710")
    let expectedScopeHash = String(repeating: "b", count: 64)
    let reconciliation = HDCServerLifecycleReconciliation(
      stepID: stepID,
      auditID: auditID,
      expectedScopeHash: expectedScopeHash,
      historicalOutcome: .succeeded(resultingGeneration: 8),
      outwardOutcome: .outcomeUnknown(reason: "newer scope requires reconciliation"),
      observedScope: HDCServerLifecycleObservedScope(
        action: .restartConfirmedGeneration,
        endpoint: endpoint,
        health: .healthy,
        version: .known("3.2.0d"),
        generation: 9,
        generationEvidence: .unknown(reason: "replacement identity is not verified"),
        ownership: .external,
        affectedDeviceCoordinators: ["device-b", "device-a"],
        affectedJobs: ["job-hdc"],
        otherClientDetection: .detected(["DevEco IDE"]),
        criticalJobs: [
          HDCServerCriticalJob(
            jobID: "job-hdc", stepID: "flash", safeBoundaryAction: "wait")
        ],
        impactReliable: false,
        scopeHash: nil),
      postDispatchObservation: .generation(8),
      requiresReconcile: true,
      reason: "server state changed during durable lifecycle outcome persistence")

    do {
      let durableStore = try FileDurableSessionAuditStore(layout: layout)
      let adapter = try DurableHDCServerLifecycleAuditStore(
        auditStore: durableStore,
        manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
        timestamp: { "2026-07-18T17:00:00Z" })
      try await adapter.append(.reconciliation(reconciliation))
    }

    let reopened = try FileDurableSessionAuditStore(layout: layout)
    let records = try reopened.replay(correlationID: auditID.uuidString)
    let record = try XCTUnwrap(records.first)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(record.details["eventType"], .string("reconciliation"))
    XCTAssertEqual(record.details["stepId"], .string(stepID.uuidString))
    XCTAssertEqual(record.details["result"], .string("succeeded"))
    XCTAssertEqual(record.details["resultingGeneration"], .integer(8))
    XCTAssertEqual(record.details["expectedScopeHash"], .string(expectedScopeHash))
    XCTAssertEqual(record.details["outwardResult"], .string("outcomeUnknown"))
    XCTAssertEqual(record.details["requiresReconcile"], .bool(true))
    XCTAssertEqual(
      record.details["postDispatchObservation"],
      .object([
        "kind": .string("generation"),
        "generation": .integer(8),
      ]))
    guard case .object(let observedScope) = record.details["observedScope"] else {
      return XCTFail("reconciliation must persist a typed observed scope")
    }
    XCTAssertEqual(observedScope["generation"], .integer(9))
    XCTAssertEqual(
      observedScope["generationEvidence"],
      .object([
        "certainty": .string("unknown"),
        "reason": .string("replacement identity is not verified"),
      ]))
    XCTAssertEqual(observedScope["health"], .string("healthy"))
    XCTAssertEqual(observedScope["ownership"], .string("external"))
    XCTAssertEqual(observedScope["impactReliable"], .bool(false))
    XCTAssertEqual(
      observedScope["affectedDeviceCoordinators"],
      .array([.string("device-a"), .string("device-b")]))
    XCTAssertEqual(
      observedScope["criticalJobs"],
      .array([
        .object([
          "jobId": .string("job-hdc"),
          "stepId": .string("flash"),
          "safeBoundaryAction": .string("wait"),
        ])
      ]))
  }

  func testReopenTreatsSuccessfulOutcomeWithoutTerminalReconciliationAsUnknown() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let auditID = UUID()
    let step = try await persistConfirmedLifecycle(
      root: root,
      auditID: auditID,
      invocationLog: root.appending(path: "missing-terminal-invocations.log"),
      includeTerminalReconciliation: false)

    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let reopenedAdapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-18T18:00:00Z" })
    let reopenedOutcome = await reopenedAdapter.resolvedLifecycleOutcome(auditID: auditID)
    XCTAssertEqual(
      reopenedOutcome,
      .outcomeUnknown(
        reason: "durable successful lifecycle outcome lacks terminal reconciliation"))
    let restoredConfirmation = await reopenedAdapter.manifestConfirmation(auditID: auditID)
    let confirmation = try XCTUnwrap(restoredConfirmation)
    let manifest = try lifecycleManifest(
      layout: layout, step: step, confirmation: confirmation)
    do {
      _ = try await reopenedAdapter.publishFinalManifest(manifest, auditID: auditID)
      XCTFail("a missing terminal reconciliation must block final manifest publication")
    } catch let error as HDCServerLifecycleAdapterError {
      XCTAssertEqual(error, .manifestConfirmationMissingOrMismatched)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.manifestURL.path))
  }

  func testReopenTreatsEnteredLaunchWindowWithoutOutcomeAsUnknown() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let auditID = UUID()
    let step = try await persistConfirmedLifecycle(
      root: root,
      auditID: auditID,
      invocationLog: root.appending(path: "missing-outcome-invocations.log"),
      includeOutcome: false,
      includeTerminalReconciliation: false)

    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let publisher = RejectIfCalledHDCManifestPublisher(layout: layout)
    let reopenedAdapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: publisher,
      timestamp: { "2026-07-18T20:30:00Z" })
    let records = try await reopenedAdapter.replay(auditID: auditID)
    XCTAssertEqual(
      records.map { $0.details["eventType"] },
      [
        .string("impactPreview"), .string("confirmation"), .string("intent"),
        .string("actualCommand"), .string("launchWindowEntered"),
      ])
    let restoredOutcome = await reopenedAdapter.resolvedLifecycleOutcome(auditID: auditID)
    XCTAssertEqual(
      restoredOutcome,
      .outcomeUnknown(reason: "durable lifecycle launch window has no persisted outcome"))

    let confirmationValue = await reopenedAdapter.manifestConfirmation(auditID: auditID)
    let confirmation = try XCTUnwrap(confirmationValue)
    let manifest = try lifecycleManifest(
      layout: layout, step: step, confirmation: confirmation)
    do {
      _ = try await reopenedAdapter.publishFinalManifest(manifest, auditID: auditID)
      XCTFail("an entered launch window with no outcome must remain in recovery")
    } catch let error as HDCServerLifecycleAdapterError {
      XCTAssertEqual(error, .manifestConfirmationMissingOrMismatched)
    }
    XCTAssertFalse(publisher.wasPublishCalled())
  }

  func testFinalManifestBindsLifecycleArgumentsDispositionSemanticResultAndJobStatus() async throws
  {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let auditID = UUID()
    let step = try await persistConfirmedLifecycle(
      root: root, auditID: auditID,
      invocationLog: root.appending(path: "manifest-binding-invocations.log"))
    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let publisher = RejectIfCalledHDCManifestPublisher(layout: layout)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: publisher,
      timestamp: { "2026-07-18T19:00:00Z" })
    let restoredConfirmation = await adapter.manifestConfirmation(auditID: auditID)
    let confirmation = try XCTUnwrap(restoredConfirmation)
    let mismatchedManifests = try [
      lifecycleManifest(
        layout: layout, step: step, confirmation: confirmation,
        manifestAction: .stopConfirmedGeneration),
      lifecycleManifest(
        layout: layout, step: step, confirmation: confirmation,
        disposition: "skipped", outcomeCertainty: "notApplicable", semanticResult: "notRun"),
      lifecycleManifest(
        layout: layout, step: step, confirmation: confirmation,
        status: "failed", semanticResult: "failed"),
      lifecycleManifest(
        layout: layout, step: step, confirmation: confirmation,
        status: "failed", semanticResult: "succeeded"),
    ]

    for manifest in mismatchedManifests {
      do {
        _ = try await adapter.publishFinalManifest(manifest, auditID: auditID)
        XCTFail("a lifecycle Manifest tuple that differs from durable execution must be rejected")
      } catch let error as HDCServerLifecycleAdapterError {
        XCTAssertEqual(error, .manifestConfirmationMissingOrMismatched)
      }
    }
    XCTAssertFalse(publisher.wasPublishCalled())
  }

  func testOutcomeUnknownRequiresRecoveryAndCannotPublishFinalManifest() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let auditID = UUID()
    let step = try await persistConfirmedLifecycle(
      root: root, auditID: auditID,
      invocationLog: root.appending(path: "unknown-outcome-invocations.log"),
      includeTerminalReconciliation: false,
      recordedOutcome: .outcomeUnknown(reason: "fixture external effect is unresolved"))
    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let publisher = RejectIfCalledHDCManifestPublisher(layout: layout)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: publisher,
      timestamp: { "2026-07-18T19:00:00Z" })
    let restoredConfirmation = await adapter.manifestConfirmation(auditID: auditID)
    let confirmation = try XCTUnwrap(restoredConfirmation)
    let manifest = try lifecycleManifest(
      layout: layout, step: step, confirmation: confirmation,
      status: "failed", semanticResult: "failed")

    do {
      _ = try await adapter.publishFinalManifest(manifest, auditID: auditID)
      XCTFail("outcomeUnknown must remain in recovery and cannot directly finalize a Manifest")
    } catch let error as HDCServerLifecycleAdapterError {
      XCTAssertEqual(error, .manifestConfirmationMissingOrMismatched)
    }
    XCTAssertFalse(publisher.wasPublishCalled())
  }

  private func fixtureCandidate() -> HDCCandidate {
    let url = fixtureExecutable()
    let bytes = (try? Data(contentsOf: url)) ?? Data()
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return HDCCandidate(path: url, source: .userConfigured, sha256: hash)
  }

  private func fixtureExecutable() -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return packageRoot.appending(path: ".build/debug/ArkDeckFakeHDCFixture")
  }

  private func temporarySessionRoot() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m1-006-\(UUID().uuidString)")
    let root = base.appending(path: "session", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: "audit", directoryHint: .isDirectory),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    for directory in ["artifacts/raw", "artifacts/derived", "artifacts/partial"] {
      try FileManager.default.createDirectory(
        at: root.appending(path: directory, directoryHint: .isDirectory),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    return root
  }

  private func persistConfirmedLifecycle(
    root: URL,
    auditID: UUID,
    invocationLog: URL,
    includeOutcome: Bool = true,
    includeTerminalReconciliation: Bool = true,
    recordedOutcome: HDCServerLifecycleExecutionOutcome? = nil
  ) async throws -> HDCServerLifecycleStep {
    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let durableAudit = try FileDurableSessionAuditStore(layout: layout)
    let publisher = AtomicSessionManifestPublisher(layout: layout)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: durableAudit, manifestPublisher: publisher,
      timestamp: { "2026-07-18T11:20:00Z" })
    let endpoint = HDCServerEndpoint("127.0.0.1:18710")
    let snapshot = HDCServerImpactSnapshot(
      action: .restartConfirmedGeneration, endpoint: endpoint, generation: 7, ownership: .external,
      affectedDeviceCoordinators: ["device-a", "device-b"], affectedJobs: ["job-hdc"],
      otherClientDetection: .detected(["DevEco IDE"]),
      expectedInterruption: "fixture interruption", recoveryPath: "fixture reconcile")
    let preview = HDCServerLifecycleImpactPreview(id: UUID(), auditID: auditID, snapshot: snapshot)
    let userConfirmation = HDCServerLifecycleConfirmation(id: UUID(), preview: preview)
    let step = HDCServerLifecycleStep(
      id: UUID(), auditID: auditID, action: .restartConfirmedGeneration, endpoint: endpoint,
      expectedGeneration: 7, expectedOwnership: .external, impactSnapshotHash: snapshot.scopeHash,
      confirmationID: userConfirmation.id)
    try await adapter.append(.impactPreview(preview))
    try await adapter.append(.confirmation(userConfirmation))
    try await adapter.append(.intent(step))

    let executor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      durableAuthorization: adapter,
      dispatchLeaseValidator: FixtureLifecycleLeaseValidator(),
      postDispatchProbe: { observed in observed == endpoint ? .generation(8) : nil })
    let executionOutcome = await executor.execute(step, lease: fixtureLease(for: step))
    XCTAssertEqual(executionOutcome.outcome, .succeeded(resultingGeneration: 8))
    XCTAssertEqual(executionOutcome.postDispatchObservation, .generation(8))
    let durableOutcome = recordedOutcome ?? executionOutcome.outcome
    if includeOutcome {
      try await adapter.append(.outcome(stepID: step.id, auditID: auditID, outcome: durableOutcome))
    }
    if includeOutcome, includeTerminalReconciliation {
      try adapter.appendTerminalReconciliation(
        HDCServerLifecycleReconciliation(
          stepID: step.id,
          auditID: auditID,
          expectedScopeHash: snapshot.scopeHash,
          historicalOutcome: durableOutcome,
          outwardOutcome: durableOutcome,
          observedScope: HDCServerLifecycleObservedScope(
            action: snapshot.action,
            endpoint: endpoint,
            health: .healthy,
            version: .known("3.2.0d"),
            generation: snapshot.generation,
            generationEvidence: .known(snapshot.generation),
            ownership: snapshot.ownership,
            affectedDeviceCoordinators: snapshot.affectedDeviceCoordinators,
            affectedJobs: snapshot.affectedJobs,
            otherClientDetection: snapshot.otherClientDetection,
            criticalJobs: [],
            impactReliable: true,
            scopeHash: snapshot.scopeHash),
          postDispatchObservation: executionOutcome.postDispatchObservation,
          requiresReconcile: false,
          reason: "durable lifecycle outcome reconciled against unchanged supervisor scope"))
    }
    return step
  }

  private func lifecycleManifest(
    layout: SessionLayout,
    step: HDCServerLifecycleStep,
    confirmation: HDCServerLifecycleManifestConfirmation,
    manifestAction: HDCServerLifecycleAction? = nil,
    status: String = "succeeded",
    disposition: String = "executed",
    outcomeCertainty: String = "confirmed",
    semanticResult: String = "succeeded"
  ) throws -> SessionManifestDocument {
    let arguments: [String: JSONValue] = [
      "action": .string((manifestAction ?? step.action).rawValue),
      "endpoint": .string(step.endpoint.rawValue),
      "expectedGeneration": step.expectedGeneration.map { .integer(Int64($0)) } ?? .null,
      "expectedOwnership": .string(step.expectedOwnership.rawValue),
      "impactSnapshotHash": .string(step.impactSnapshotHash),
      "confirmationId": step.confirmationID.map { .string($0.uuidString) } ?? .null,
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let argumentsData = try encoder.encode(JSONValue.object(arguments))
    let argumentsHash = SHA256.hash(data: argumentsData)
      .map { String(format: "%02x", $0) }.joined()
    let manifestStep: JSONValue = .object([
      "id": .string(step.id.uuidString),
      "kind": .string("mutateHDCServerLifecycle"),
      "effect": .string("destructive"),
      "cancellation": .string("atSafeBoundary"),
      "bindingRequirement": .string("none"),
      "arguments": .object(arguments),
      "argumentsHash": .string(argumentsHash),
      "compensationDescriptors": .array([]),
      "sourceStepId": .null,
      "compensationTrigger": .null,
      "disposition": .string(disposition),
      "outcomeCertainty": .string(outcomeCertainty),
      "bindingRevision": .null,
      "semanticResult": .string(semanticResult),
    ])
    let manifestConfirmation: JSONValue = .object([
      "confirmationId": .string(confirmation.confirmationID),
      "kind": .string("serverLifecycle"),
      "scopeHash": .string(confirmation.scopeHash),
      "decision": .string(confirmation.decision),
      "actor": .string(confirmation.actor),
      "decidedAt": .string(confirmation.decidedAt),
      "relatedStepIds": .array(confirmation.relatedStepIDs.map(JSONValue.string)),
    ])
    return try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: layout.sessionID,
        jobID: layout.jobID,
        status: status,
        executionMode: "execute",
        executionAuthority: "interactiveUser",
        steps: [manifestStep],
        confirmations: [manifestConfirmation]))
  }

  private func appendSuccessfulLifecycleJournal(
    layout: SessionLayout,
    manifest: SessionManifestDocument,
    step: HDCServerLifecycleStep
  ) throws {
    let arguments: [String: JSONValue] = [
      "action": .string(step.action.rawValue),
      "endpoint": .string(step.endpoint.rawValue),
      "expectedGeneration": step.expectedGeneration.map { .integer(Int64($0)) } ?? .null,
      "expectedOwnership": .string(step.expectedOwnership.rawValue),
      "impactSnapshotHash": .string(step.impactSnapshotHash),
      "confirmationId": step.confirmationID.map { .string($0.uuidString) } ?? .null,
    ]
    let workflowStep = try WorkflowStep(
      id: step.id.uuidString,
      kind: .mutateHDCServerLifecycle,
      declaredEffect: .destructive,
      declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .none,
      arguments: arguments)
    let journal = try FileDurableJournal(url: layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "hdc-job-created", sequence: 0,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        executionMode: "execute", executionAuthority: "interactiveUser",
        coreBaseline: "CORE-2.0.0"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "hdc-job-preflight", sequence: 1,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        from: .queued, to: .preflight, reason: "HDC lifecycle manifest fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "hdc-job-running", sequence: 2,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        from: .preflight, to: .running, reason: "HDC lifecycle manifest fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: "hdc-step-intent", sequence: 3,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        step: workflowStep,
        target: JournalTarget(
          scope: "host", targetID: step.endpoint.rawValue,
          connectKey: nil, identitySnapshotHash: nil),
        attempt: 1, bindingRevision: nil))
    try journal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "hdc-step-outcome", sequence: 4,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        stepID: workflowStep.id, attempt: 1,
        correlatesToIntentEventID: "hdc-step-intent",
        result: "succeeded", outcomeCertainty: .confirmed))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "hdc-job-finalizing", sequence: 5,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        from: .running, to: .finalizing, reason: "HDC lifecycle manifest fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "hdc-job-succeeded", sequence: 6,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        from: .finalizing, to: .succeeded, reason: "HDC lifecycle manifest fixture"))
    try journal.appendAndSynchronize(
      JournalEvent(
        eventID: "hdc-job-finalized", sequence: 7,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        kind: .finalized,
        payload: [
          "terminalStatus": .string("succeeded"),
          "manifestSha256": .string(manifest.sha256),
          "outcomeCertainty": .string("confirmed"),
        ]))
  }

  // TEST-AC-HDC-010-01 / lifecycleCallCounter
  func testLifecycleExecutorDoesNotLaunchAChildWithoutDurableProof() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-18T11:20:00Z" })
    let endpoint = HDCServerEndpoint("127.0.0.1:18710")
    let invocationLog = root.appending(path: "unauthorized-invocation.log")
    let executor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      durableAuthorization: adapter,
      dispatchLeaseValidator: FixtureLifecycleLeaseValidator(),
      postDispatchProbe: { _ in .generation(2) })
    let step = HDCServerLifecycleStep(
      id: UUID(), auditID: UUID(), action: .restartConfirmedGeneration, endpoint: endpoint,
      expectedGeneration: 1, expectedOwnership: .external, impactSnapshotHash: "untrusted",
      confirmationID: UUID())

    let result = await executor.execute(step, lease: fixtureLease(for: step))
    XCTAssertEqual(
      result.outcome,
      .failed(
        reason:
          "lifecycle dispatch lacks an unused durable preview, confirmation, and intent authorization"
      ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
  }

  // TEST-AC-HDC-010-02 / confirmedStopPostDispatchProbe
  func testConfirmedStopRequiresAnUnavailablePostDispatchObservation() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let endpoint = HDCServerEndpoint("127.0.0.1:18710")
    let step = HDCServerLifecycleStep(
      id: UUID(), auditID: UUID(), action: .stopConfirmedGeneration, endpoint: endpoint,
      expectedGeneration: 7, expectedOwnership: .external, impactSnapshotHash: "fixture-scope",
      confirmationID: UUID())
    let invocationLog = root.appending(path: "stop-invocation.log")
    let authorization = FixtureSingleUseLifecycleAuthorization()
    let executor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      durableAuthorization: authorization,
      dispatchLeaseValidator: FixtureLifecycleLeaseValidator(),
      postDispatchProbe: { _ in .unavailable })

    let result = await executor.execute(step, lease: fixtureLease(for: step))
    XCTAssertEqual(result.outcome, .stopped)
    XCTAssertEqual(result.postDispatchObservation, .unavailable)
    XCTAssertEqual(
      try String(contentsOf: invocationLog, encoding: .utf8),
      "-s\u{1F}127.0.0.1:18710\u{1F}kill\n")
    let actual = await authorization.recordedActualCommands()
    XCTAssertEqual(actual.map(\.arguments), [["-s", "127.0.0.1:18710", "kill"]])
  }

  func testRestartRequiresAStrictlyNewerPostDispatchGeneration() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let endpoint = HDCServerEndpoint("127.0.0.1:18710")
    let step = HDCServerLifecycleStep(
      id: UUID(), auditID: UUID(), action: .restartConfirmedGeneration, endpoint: endpoint,
      expectedGeneration: 7, expectedOwnership: .external, impactSnapshotHash: "fixture-scope",
      confirmationID: UUID())
    let authorization = FixtureSingleUseLifecycleAuthorization()
    let executor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": root.appending(path: "invocations.log").path
      ],
      durableAuthorization: authorization,
      dispatchLeaseValidator: FixtureLifecycleLeaseValidator(),
      postDispatchProbe: { _ in .generation(6) })

    let result = await executor.execute(step, lease: fixtureLease(for: step))
    XCTAssertEqual(
      result.outcome,
      .outcomeUnknown(
        reason: "restart completed but did not establish a strictly newer server generation"))
    XCTAssertEqual(result.postDispatchObservation, .generation(6))
  }

  func testPostLaunchFailuresProbeReconcileAndCannotPublishAsConfirmedExecution() async throws {
    try await assertPostLaunchFailureIsUncertain(mode: "nonzero")
    try await assertPostLaunchFailureIsUncertain(mode: "semantic-failure")
  }

  private func assertPostLaunchFailureIsUncertain(mode: String) async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let layout = try SessionLayout(
      sessionID: "post-launch-\(mode)", jobID: "job-post-launch", root: root)
    let publisher = RejectIfCalledHDCManifestPublisher(layout: layout)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: publisher,
      timestamp: { "2026-07-18T20:00:00Z" })
    let supervisor = HDCServerSupervisor(auditStore: adapter)
    let endpoint = HDCServerEndpoint("127.0.0.1:18715")
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 7,
          ownership: .external)),
      reason: "fixture verified state")
    guard
      case .ready(let preview) = await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint),
      case .accepted(let confirmation) = await supervisor.confirm(preview.id)
    else {
      return XCTFail("fixture must establish confirmed lifecycle scope")
    }

    let invocationLog = root.appending(path: "post-launch-\(mode).log")
    let probeCounter = HDCProbeCounter()
    let executor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path,
        "ARKDECK_FAKE_HDC_LIFECYCLE_MODE": mode,
      ],
      durableAuthorization: adapter,
      dispatchLeaseValidator: supervisor,
      postDispatchProbe: { _ in
        _ = await probeCounter.next()
        return .generation(8)
      })

    let dispatch = await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    let failureReason: String
    switch mode {
    case "nonzero":
      failureReason =
        "lifecycle launch window was entered and the process did not exit zero; post-dispatch state requires reconciliation"
    case "semantic-failure":
      failureReason =
        "lifecycle launch window was entered and the process emitted a registered failure result; post-dispatch state requires reconciliation"
    default:
      return XCTFail("unsupported lifecycle failure fixture mode")
    }
    let reconciledUnknown = HDCServerLifecycleExecutionOutcome.outcomeUnknown(
      reason: failureReason)
    XCTAssertEqual(dispatch, .completed(reconciledUnknown))
    let probeCount = await probeCounter.value()
    XCTAssertEqual(probeCount, 1)

    let records = try await adapter.replay(auditID: preview.auditID)
    XCTAssertEqual(
      records.map { $0.details["eventType"] },
      [
        .string("impactPreview"), .string("confirmation"), .string("intent"),
        .string("actualCommand"), .string("launchWindowEntered"), .string("outcome"),
        .string("reconciliation"),
      ])
    let reconciliation = try XCTUnwrap(
      records.first { $0.details["eventType"] == .string("reconciliation") })
    XCTAssertEqual(reconciliation.details["result"], .string("outcomeUnknown"))
    XCTAssertEqual(reconciliation.details["outwardResult"], .string("outcomeUnknown"))
    XCTAssertEqual(reconciliation.details["requiresReconcile"], .bool(true))
    XCTAssertEqual(
      reconciliation.details["postDispatchObservation"],
      .object([
        "kind": .string("generation"),
        "generation": .integer(8),
      ]))
    guard case .object(let observedSupervisorScope) = reconciliation.details["observedScope"]
    else {
      return XCTFail("reconciliation must retain the current Supervisor scope")
    }
    XCTAssertEqual(observedSupervisorScope["generation"], .integer(7))
    XCTAssertEqual(
      reconciliation.details["reconciliationReason"],
      .string("entered lifecycle launch window has an uncertain external effect"))
    let restoredOutcome = await adapter.resolvedLifecycleOutcome(auditID: preview.auditID)
    XCTAssertEqual(restoredOutcome, reconciledUnknown)

    let restoredConfirmationValue = await adapter.manifestConfirmation(auditID: preview.auditID)
    let restoredConfirmation = try XCTUnwrap(restoredConfirmationValue)
    let failedExecutedManifest = try lifecycleManifest(
      layout: layout,
      step: HDCServerLifecycleStep(
        id: UUID(uuidString: restoredConfirmation.relatedStepIDs[0])!,
        auditID: preview.auditID,
        action: confirmation.action,
        endpoint: confirmation.endpoint,
        expectedGeneration: confirmation.generation,
        expectedOwnership: .external,
        impactSnapshotHash: confirmation.scopeHash,
        confirmationID: confirmation.id),
      confirmation: restoredConfirmation,
      status: "failed", disposition: "executed", outcomeCertainty: "confirmed",
      semanticResult: "failed")
    do {
      _ = try await adapter.publishFinalManifest(
        failedExecutedManifest, auditID: preview.auditID)
      XCTFail("an entered launch window cannot finalize as confirmed failed execution")
    } catch let error as HDCServerLifecycleAdapterError {
      XCTAssertEqual(error, .manifestConfirmationMissingOrMismatched)
    }
    XCTAssertFalse(publisher.wasPublishCalled())
  }

  // TEST-AC-HDC-010-01 / lifecycleAuthorizationSingleUse
  func testLifecycleExecutorConsumesDurableAuthorizationBeforeTheOnlyChildLaunch() async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let layout = try SessionLayout(sessionID: "session-hdc", jobID: "job-hdc", root: root)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-18T11:20:00Z" })
    let endpoint = HDCServerEndpoint("127.0.0.1:18710")
    let snapshot = HDCServerImpactSnapshot(
      action: .restartConfirmedGeneration, endpoint: endpoint, generation: 7, ownership: .external,
      affectedDeviceCoordinators: [], affectedJobs: [],
      otherClientDetection: .noneDetectedExternalClientsMayStillExist,
      expectedInterruption: "fixture", recoveryPath: "fixture")
    let preview = HDCServerLifecycleImpactPreview(id: UUID(), auditID: UUID(), snapshot: snapshot)
    let confirmation = HDCServerLifecycleConfirmation(id: UUID(), preview: preview)
    let step = HDCServerLifecycleStep(
      id: UUID(), auditID: preview.auditID, action: .restartConfirmedGeneration, endpoint: endpoint,
      expectedGeneration: 7, expectedOwnership: .external, impactSnapshotHash: snapshot.scopeHash,
      confirmationID: confirmation.id)
    try await adapter.append(.impactPreview(preview))
    try await adapter.append(.confirmation(confirmation))
    try await adapter.append(.intent(step))

    let invocationLog = root.appending(path: "single-use-invocation.log")
    let executor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      durableAuthorization: adapter,
      dispatchLeaseValidator: FixtureLifecycleLeaseValidator(),
      postDispatchProbe: { _ in .generation(8) })
    let firstExecution = await executor.execute(step, lease: fixtureLease(for: step))
    XCTAssertEqual(firstExecution.outcome, .succeeded(resultingGeneration: 8))
    XCTAssertEqual(firstExecution.postDispatchObservation, .generation(8))
    let repeatedExecution = await executor.execute(step, lease: fixtureLease(for: step))
    XCTAssertEqual(
      repeatedExecution.outcome,
      .failed(
        reason:
          "lifecycle dispatch lacks an unused durable preview, confirmation, and intent authorization"
      ))
    let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
    XCTAssertEqual(invocations.count, 1)
    XCTAssertEqual(invocations.first, "-s\u{1F}127.0.0.1:18710\u{1F}kill\u{1F}-r")
  }

  // TEST-AC-HDC-010-03 / dispatchLeaseRaceFaults
  func testDispatchLeasePreventsLifecycleLaunchAfterConcurrentSupervisorChanges() async throws {
    try await assertDispatchLeaseInvalidatesBeforeChildLaunch(for: .generation)
    try await assertDispatchLeaseInvalidatesBeforeChildLaunch(for: .affectedJob)
    try await assertDispatchLeaseInvalidatesBeforeChildLaunch(for: .criticalState)
  }

  func testAtomicLaunchGatePreventsSpawnAfterFinalValidationAndConcurrentSupervisorChanges()
    async throws
  {
    try await assertAtomicLaunchGateInvalidatesBeforeSpawn(for: .generation)
    try await assertAtomicLaunchGateInvalidatesBeforeSpawn(for: .affectedJob)
    try await assertAtomicLaunchGateInvalidatesBeforeSpawn(for: .criticalState)
  }

  private enum DispatchLeaseInvalidation {
    case generation
    case affectedJob
    case criticalState
  }

  private func assertDispatchLeaseInvalidatesBeforeChildLaunch(
    for invalidation: DispatchLeaseInvalidation
  ) async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let endpoint = HDCServerEndpoint("127.0.0.1:18714")
    let layout = try SessionLayout(sessionID: "lease-race", jobID: "job-race", root: root)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-18T14:55:00Z" })
    let supervisor = HDCServerSupervisor(auditStore: adapter)
    let existingJob = HDCServerRecipient(id: "job-existing", kind: .job, endpoint: endpoint)
    await supervisor.register(existingJob)
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 7,
          ownership: .external)),
      reason: "fixture verified state")
    guard
      case .ready(let preview) = await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint)
    else {
      return XCTFail("fixture must create a recovery preview")
    }
    guard case .accepted(let confirmation) = await supervisor.confirm(preview.id) else {
      return XCTFail("fixture must accept the durable confirmation")
    }

    let invocationLog = root.appending(path: "lease-race-invocations.log")
    let leaseGate = BlockingDispatchLeaseValidator(supervisor: supervisor)
    let executor = HDCProcessLifecycleExecutor(
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      durableAuthorization: adapter,
      dispatchLeaseValidator: leaseGate,
      postDispatchProbe: { _ in .generation(8) })
    let dispatch = Task {
      await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    }
    await leaseGate.waitUntilEntered()

    switch invalidation {
    case .generation:
      await supervisor.observeExistingServer(
        HDCExistingServerObservation(
          state: HDCServerState(
            endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 8,
            ownership: .external)),
        reason: "fixture replacement while executor is paused")
    case .affectedJob:
      await supervisor.register(
        HDCServerRecipient(id: "job-added", kind: .job, endpoint: endpoint))
    case .criticalState:
      await supervisor.updateCriticalState(
        .criticalNonInterruptible(
          stepID: "flash-system", safeBoundaryAction: "wait for flash checkpoint"),
        for: existingJob)
    }
    await leaseGate.resume()

    let result = await dispatch.value
    XCTAssertEqual(
      result,
      .completed(
        .failed(
          reason:
            "lifecycle dispatch lease expired after durable authorization before process launch")),
      "\(invalidation) must invalidate a paused dispatch lease")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: invocationLog.path),
      "\(invalidation) must keep actual lifecycle invocation count at zero")
    let records = try await adapter.replay(auditID: preview.auditID)
    XCTAssertFalse(
      records.contains { $0.details["eventType"] == .string("launchWindowEntered") },
      "\(invalidation) must remain durably classified as pre-launch nonexecution")
    XCTAssertFalse(
      records.contains { $0.details["eventType"] == .string("reconciliation") },
      "a proven pre-launch failure does not manufacture an external-effect reconciliation")
    let durableConfirmationValue = await adapter.manifestConfirmation(auditID: preview.auditID)
    let durableConfirmation = try XCTUnwrap(durableConfirmationValue)
    let intentRecord = try XCTUnwrap(
      records.first { $0.details["eventType"] == .string("intent") })
    guard case .string(let stepIDText) = intentRecord.details["stepId"] else {
      return XCTFail("durable lifecycle intent must retain its typed Step ID")
    }
    let stepID = try XCTUnwrap(UUID(uuidString: stepIDText))
    let failedExecutedManifest = try lifecycleManifest(
      layout: layout,
      step: HDCServerLifecycleStep(
        id: stepID,
        auditID: preview.auditID,
        action: confirmation.action,
        endpoint: confirmation.endpoint,
        expectedGeneration: confirmation.generation,
        expectedOwnership: .external,
        impactSnapshotHash: confirmation.scopeHash,
        confirmationID: confirmation.id),
      confirmation: durableConfirmation,
      status: "failed", disposition: "executed", outcomeCertainty: "confirmed",
      semanticResult: "failed")
    do {
      _ = try await adapter.publishFinalManifest(
        failedExecutedManifest, auditID: preview.auditID)
      XCTFail("pre-launch lease invalidation cannot be published as an executed lifecycle step")
    } catch let error as HDCServerLifecycleAdapterError {
      XCTAssertEqual(error, .manifestConfirmationMissingOrMismatched)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.manifestURL.path))
  }

  private func assertAtomicLaunchGateInvalidatesBeforeSpawn(
    for invalidation: DispatchLeaseInvalidation
  ) async throws {
    let root = try temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let endpoint = HDCServerEndpoint("127.0.0.1:18716")
    let layout = try SessionLayout(
      sessionID: "atomic-launch-race", jobID: "job-atomic-race", root: root)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-18T22:00:00Z" })
    let supervisor = HDCServerSupervisor(auditStore: adapter)
    let existingJob = HDCServerRecipient(
      id: "job-existing", kind: .job, endpoint: endpoint)
    await supervisor.register(existingJob)
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 7,
          ownership: .external)),
      reason: "fixture verified state")
    guard
      case .ready(let preview) = await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint),
      case .accepted(let confirmation) = await supervisor.confirm(preview.id)
    else {
      return XCTFail("fixture must establish a confirmed lifecycle scope")
    }

    let launchHook = BlockingFinalLaunchHook()
    let launchCount = LockedHDCLaunchCounter()
    let processExecutor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in },
      identityBoundFinalLaunchHook: { _ in await launchHook.pause() },
      launchObserver: { _ in launchCount.recordLaunch() })
    let invocationLog = root.appending(path: "atomic-launch-race-invocations.log")
    let executor = HDCProcessLifecycleExecutor(
      runner: HDCProcessCommandRunner(executor: processExecutor),
      toolchain: fixtureCandidate(),
      endpointSelection: try HDCServerEndpointSelector.select(
        explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      durableAuthorization: adapter,
      dispatchLeaseValidator: supervisor,
      postDispatchProbe: { _ in .generation(8) })
    let dispatch = Task {
      await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    }
    await launchHook.waitUntilEntered()

    let pausedRecords = try await adapter.replay(auditID: preview.auditID)
    let launchWindow = try XCTUnwrap(
      pausedRecords.first { $0.details["eventType"] == .string("launchWindowEntered") })
    XCTAssertEqual(launchWindow.details["executable"], .string(fixtureExecutable().path))
    XCTAssertEqual(launchWindow.details["authorizedExecutable"], launchWindow.details["executable"])
    XCTAssertEqual(launchWindow.details["executableSha256"], .string(fixtureCandidate().sha256))
    XCTAssertNotNil(launchWindow.details["inodeLaunchPath"])

    switch invalidation {
    case .generation:
      await supervisor.observeExistingServer(
        HDCExistingServerObservation(
          state: HDCServerState(
            endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 8,
            ownership: .external)),
        reason: "fixture replacement after final executable validation")
    case .affectedJob:
      await supervisor.register(
        HDCServerRecipient(id: "job-added", kind: .job, endpoint: endpoint))
    case .criticalState:
      await supervisor.updateCriticalState(
        .criticalNonInterruptible(
          stepID: "flash-system", safeBoundaryAction: "wait for flash checkpoint"),
        for: existingJob)
    }
    await launchHook.resume()

    let result = await dispatch.value
    XCTAssertEqual(
      result,
      .completed(
        .outcomeUnknown(
          reason:
            "lifecycle launch window was entered but process execution could not be classified; post-dispatch state requires reconciliation"
        )))
    XCTAssertEqual(launchCount.count, 0, "\(invalidation) must win before posix_spawn")
    XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    let finalRecords = try await adapter.replay(auditID: preview.auditID)
    XCTAssertEqual(
      finalRecords.map { $0.details["eventType"] },
      [
        .string("impactPreview"), .string("confirmation"), .string("intent"),
        .string("actualCommand"), .string("launchWindowEntered"), .string("outcome"),
        .string("reconciliation"),
      ])
  }

  private func exitedZero() -> ProcessExecutionResult {
    ProcessExecutionResult(
      termination: .exited(0),
      stdout: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false),
      stderr: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false))
  }

}

private actor HDCProbeCounter {
  private var count = 0

  func next() -> Int {
    count += 1
    return count
  }

  func value() -> Int { count }
}

private actor BlockingAuthorizationProbe {
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitForRelease() async {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      enteredWaiters.append(continuation)
    }
  }

  func release() {
    let continuation = releaseContinuation
    releaseContinuation = nil
    continuation?.resume()
  }
}

private actor BlockingFinalLaunchHook {
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func pause() async {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      enteredWaiters.append(continuation)
    }
  }

  func resume() {
    let continuation = releaseContinuation
    releaseContinuation = nil
    continuation?.resume()
  }
}

private final class LockedHDCLaunchCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  func recordLaunch() {
    lock.withLock { storedCount += 1 }
  }

  var count: Int { lock.withLock { storedCount } }
}

private struct FixtureLifecycleLeaseValidator: HDCServerLifecycleDispatchLeaseValidating {
  func consumeDispatchLease(
    _: HDCServerLifecycleDispatchLease,
    for _: HDCServerLifecycleStep
  ) async -> Bool { true }
}

private func fixtureLease(for step: HDCServerLifecycleStep) -> HDCServerLifecycleDispatchLease {
  HDCServerLifecycleDispatchLease(
    id: UUID(), stepID: step.id, auditID: step.auditID, endpoint: step.endpoint,
    launchGate: ProcessAtomicLaunchGate())
}

/// Pauses precisely after durable actual-command authorization and before the
/// Supervisor's final lease consumption, so concurrent state changes can be
/// tested without launching the fake lifecycle child.
private actor BlockingDispatchLeaseValidator: HDCServerLifecycleDispatchLeaseValidating {
  private let supervisor: HDCServerSupervisor
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(supervisor: HDCServerSupervisor) {
    self.supervisor = supervisor
  }

  func consumeDispatchLease(
    _ lease: HDCServerLifecycleDispatchLease,
    for step: HDCServerLifecycleStep
  ) async -> Bool {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return await supervisor.consumeDispatchLease(lease, for: step)
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      enteredWaiters.append(continuation)
    }
  }

  func resume() {
    let continuation = releaseContinuation
    releaseContinuation = nil
    continuation?.resume()
  }
}

private enum UnexpectedHDCManifestPublisherCall: Error {
  case publish
  case unsupported
}

/// Negative adapter tests use this publisher to prove malformed lifecycle
/// tuples are rejected before the write-once storage seam is invoked.
private final class RejectIfCalledHDCManifestPublisher: SessionManifestPublishing,
  @unchecked Sendable
{
  let layout: SessionLayout
  private let lock = NSLock()
  private var publishCalled = false

  init(layout: SessionLayout) {
    self.layout = layout
  }

  func storageVolumeIdentity(using _: any VolumeIdentityResolving) throws -> VolumeIdentity {
    throw UnexpectedHDCManifestPublisherCall.unsupported
  }

  func publish(_: SessionManifestDocument) throws -> PublishedSessionManifest {
    lock.lock()
    publishCalled = true
    lock.unlock()
    throw UnexpectedHDCManifestPublisherCall.publish
  }

  func load() throws -> SessionManifestDocument {
    throw UnexpectedHDCManifestPublisherCall.unsupported
  }

  func wasPublishCalled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return publishCalled
  }
}

/// Isolates the executor's stop/post-probe behavior. Durable single-use is
/// verified separately against the production adapter and reopened file store.
private actor FixtureSingleUseLifecycleAuthorization: HDCServerLifecycleDispatchAuthorizing {
  private var actualCommands: [HDCServerLifecycleActualCommand] = []
  private var launchWindowEntries: [HDCServerLifecycleActualCommand] = []

  func consumeDispatchAuthorization(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand
  ) -> Bool {
    guard actualCommands.isEmpty,
      actualCommand.stepID == step.id,
      actualCommand.auditID == step.auditID,
      actualCommand.endpoint == step.endpoint
    else { return false }
    actualCommands.append(actualCommand)
    return true
  }

  func recordLaunchWindowEntry(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand,
    executableIdentity _: HDCServerLifecycleExecutableIdentityReceipt
  ) -> Bool {
    guard launchWindowEntries.isEmpty,
      actualCommands == [actualCommand],
      actualCommand.stepID == step.id,
      actualCommand.auditID == step.auditID,
      actualCommand.endpoint == step.endpoint
    else { return false }
    launchWindowEntries.append(actualCommand)
    return true
  }

  func recordedActualCommands() -> [HDCServerLifecycleActualCommand] { actualCommands }
}
