import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

/// CHG-2026-022 / TASK-OBS-001 contract tests.
///
/// Group A (C1-C8) = TEST-OBS-COUNTER-001, group B (O1-O8) =
/// TEST-OBS-OWNERSHIP-001, group C (E1-E4) = TEST-OBS-ENDPOINT-001, group D
/// (F1-F5) = TEST-OBS-FANOUT-001. Fake processes always run through the
/// repository fixture executable located under `.build/debug`, observed via
/// `ARKDECK_FAKE_HDC_INVOCATION_LOG`, with the `testOnlyFake` semantic
/// authority. No test calls the monitor record entry point, constructs an
/// origin marker, or injects a fixture into a production path.
final class HDCSupervisorObservabilityContractTests: XCTestCase {

  // MARK: - CHG-2026-043 / TASK-HSO-002

  func testHSO1_ExactCommandlessCatalogAndProductionFactoryHaveNoAuthorityInjection()
    throws
  {
    XCTAssertEqual(
      HDCSupervisorObservationProbeCatalog.registryID,
      "OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES")
    XCTAssertEqual(HDCSupervisorObservationProbeCatalog.registryVersion, "1.0.0")
    XCTAssertEqual(
      HDCSupervisorObservationProbeCatalog.integrationProfile,
      "OPENHARMONY-TOOLS@0.6.0")
    XCTAssertEqual(HDCSupervisorObservationProbeCatalog.targetToolVersion, "3.2.0f")
    XCTAssertEqual(
      HDCSupervisorObservationProbeCatalog.targetExecutableSHA256,
      "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83")
    XCTAssertEqual(HDCSupervisorObservationProbeCatalog.exactEndpoint, "127.0.0.1:8710")
    XCTAssertEqual(HDCSupervisorObservationProbeCatalog.exactArguments, [])
    XCTAssertFalse(HDCSupervisorObservationProbeCatalog.invocationAllowed)
    XCTAssertEqual(
      HDCSupervisorObservationProbeCatalog.targetExecutableSHA256,
      HDCDeviceObservationProbeCatalog.targetExecutableSHA256)
    XCTAssertEqual(
      HDCSupervisorObservationProbeCatalog.exactEndpoint,
      HDCDeviceObservationProbeCatalog.exactEndpoint)
    XCTAssertNotEqual(
      HDCSupervisorObservationProbeCatalog.registryID,
      HDCDeviceObservationProbeCatalog.registryID)

    let sourcesRoot = observabilityPackageRoot().appending(path: "Sources")
    let observerSource = try String(
      contentsOf: sourcesRoot.appending(
        path: "ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift"),
      encoding: .utf8)
    let factoryStart = try XCTUnwrap(
      observerSource.range(of: "package static func makeProduction("))
    let factoryTail = observerSource[factoryStart.lowerBound...]
    let factoryEnd = try XCTUnwrap(
      factoryTail.range(of: "  /// Contract-only seam."))
    let productionFactory = String(
      factoryTail[..<factoryEnd.lowerBound])
    let declaration = String(productionFactory.prefix { $0 != "{" })

    XCTAssertTrue(declaration.contains("supervisor: HDCServerSupervisor"))
    XCTAssertTrue(declaration.contains("toolchain: HDCCandidate"))
    XCTAssertTrue(declaration.contains("endpointSelection: HDCServerEndpointSelection"))
    for forbidden in [
      "receipt", "generation", "pid", "process", "socket", "runner", "registry",
      "identityObserver",
    ] {
      XCTAssertFalse(
        declaration.localizedCaseInsensitiveContains(forbidden),
        "production factory must not expose \(forbidden)")
    }
    XCTAssertEqual(matchCount("HDCProcessCommand\\(", in: observerSource), 0)
    XCTAssertEqual(matchCount("HDCProcessCommandRunner", in: observerSource), 0)
    XCTAssertEqual(
      matchCount("HDCCandidateIdentityVerifier\\.matches", in: observerSource),
      2,
      "candidate bytes must be verified before and after the bounded scans")
    XCTAssertEqual(matchCount("let first = scan\\(", in: observerSource), 1)
    XCTAssertEqual(matchCount("let second = scan\\(", in: observerSource), 1)
    XCTAssertTrue(observerSource.contains("health: .unknown"))
    XCTAssertTrue(observerSource.contains("version: .unknown("))
    XCTAssertTrue(observerSource.contains("recordUnverifiedServerProbeFailure("))
  }

  func testHSO2_StableReceiptUsesExactSelectedInputsAndAllFourEvidenceClassifyExternal()
    async throws
  {
    let supervisor = HDCServerSupervisor(
      auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = hsoCandidate("hso2")
    let endpointSelection = try hsoEndpointSelection()
    let receipt = hsoIdentityReceipt(
      candidate: candidate, endpoint: endpointSelection.endpoint)
    let observer = HSORecordingIdentityObserver(observation: .observed(receipt))
    let session = HDCSupervisorObservationApplicationSession.makeContract(
      supervisor: supervisor,
      toolchain: candidate,
      endpointSelection: endpointSelection,
      identityObserver: observer)

    let result = await session.observe()

    XCTAssertEqual(
      result.classification,
      .observed(generation: try XCTUnwrap(receipt.stableGeneration)))
    XCTAssertEqual(result.identity, receipt)
    let inputs = await observer.inputs
    XCTAssertEqual(inputs.count, 1)
    XCTAssertEqual(inputs.first?.endpoint, endpointSelection.endpoint)
    XCTAssertEqual(inputs.first?.toolchain, candidate)
    let stateValue = await supervisor.state(for: endpointSelection.endpoint)
    let state = try XCTUnwrap(stateValue)
    XCTAssertEqual(state.health, .unknown)
    XCTAssertEqual(
      state.version,
      .unknown(
        reason: "OPENHARMONY-TOOLS@0.6.0 has no registered HDC health or version source"))
    XCTAssertEqual(state.generationEvidence, .known(try XCTUnwrap(receipt.stableGeneration)))
    XCTAssertEqual(state.ownership, .external)
    let basisValue = await supervisor.ownershipBasis(for: endpointSelection.endpoint)
    let basis = try XCTUnwrap(basisValue)
    XCTAssertTrue(basis.preExistingServerReceipt)
    XCTAssertTrue(basis.zeroAutomaticLifecycleDispatch)
    XCTAssertTrue(basis.generationMintedFromObservation)
    XCTAssertTrue(basis.noActiveOrUnreconciledManagedProvenance)
    XCTAssertEqual(
      supervisor.dispatchMonitor.countersSnapshot(),
      HDCSupervisorDispatchMonitor.CountersSnapshot(
        automaticLifecycleDispatchCount: 0,
        automaticSubserverDispatchCount: 0,
        confirmedLifecycleDispatchCount: 0,
        managedStartDispatchCount: 0))
    XCTAssertTrue(supervisor.dispatchMonitor.spawnAuditTrail().isEmpty)
  }

  func testHSO3_WrongCandidateOrEndpointNeverReachesObserverAndRevokesStaleExternalClaim()
    async throws
  {
    let exactCandidate = hsoCandidate("hso3")
    let exactEndpoint = try hsoEndpointSelection()

    for mutation in ["candidate", "endpoint"] {
      let supervisor = HDCServerSupervisor(
        auditStore: InMemoryHDCServerLifecycleAuditStore())
      let observer = HSORecordingIdentityObserver(
        observation: .observed(
          hsoIdentityReceipt(
            candidate: exactCandidate, endpoint: exactEndpoint.endpoint)))
      let candidate =
        mutation == "candidate"
        ? HDCCandidate(
          path: exactCandidate.path,
          source: exactCandidate.source,
          sha256: String(repeating: "0", count: 64))
        : exactCandidate
      let endpoint =
        mutation == "endpoint"
        ? try HDCServerEndpointSelector.select(
          explicitEndpoint: "127.0.0.1:18710")
        : exactEndpoint
      await seedHSOExternalClaim(
        supervisor: supervisor, endpoint: endpoint.endpoint)
      let session = HDCSupervisorObservationApplicationSession.makeContract(
        supervisor: supervisor,
        toolchain: candidate,
        endpointSelection: endpoint,
        identityObserver: observer)

      let result = await session.observe()

      guard case .unsupported = result.classification else {
        return XCTFail("\(mutation) must fail unsupported: \(result.classification)")
      }
      let observedInputs = await observer.inputs
      XCTAssertEqual(observedInputs.count, 0)
      let stateValue = await supervisor.state(for: endpoint.endpoint)
      let state = try XCTUnwrap(stateValue)
      XCTAssertEqual(state.ownership, .unknown)
      XCTAssertEqual(state.health, .unknown)
      guard case .unknown = state.generationEvidence else {
        return XCTFail("the stale generation claim must be revoked")
      }
      XCTAssertEqual(
        supervisor.dispatchMonitor.countersSnapshot(),
        hsoZeroDispatchCounters())
      XCTAssertTrue(supervisor.dispatchMonitor.spawnAuditTrail().isEmpty)
    }
  }

  func testHSO4_EveryRawFailureAndReceiptMismatchRevokesPriorExternalClaim()
    async throws
  {
    let candidate = hsoCandidate("hso4")
    let endpointSelection = try hsoEndpointSelection()
    let validReceipt = hsoIdentityReceipt(
      candidate: candidate, endpoint: endpointSelection.endpoint)
    let wrongPath = HDCServerProcessIdentityReceipt(
      pid: validReceipt.pid,
      startSeconds: validReceipt.startSeconds,
      startMicroseconds: validReceipt.startMicroseconds,
      executablePath: URL(fileURLWithPath: "/private/tmp/hso-wrong-path"),
      executableSHA256: validReceipt.executableSHA256,
      endpoint: validReceipt.endpoint)
    let wrongHash = HDCServerProcessIdentityReceipt(
      pid: validReceipt.pid,
      startSeconds: validReceipt.startSeconds,
      startMicroseconds: validReceipt.startMicroseconds,
      executablePath: validReceipt.executablePath,
      executableSHA256: String(repeating: "f", count: 64),
      endpoint: validReceipt.endpoint)
    let wrongEndpoint = HDCServerProcessIdentityReceipt(
      pid: validReceipt.pid,
      startSeconds: validReceipt.startSeconds,
      startMicroseconds: validReceipt.startMicroseconds,
      executablePath: validReceipt.executablePath,
      executableSHA256: validReceipt.executableSHA256,
      endpoint: HDCServerEndpoint("127.0.0.1:18710"))
    let overflow = HDCServerProcessIdentityReceipt(
      pid: validReceipt.pid,
      startSeconds: UInt64.max,
      startMicroseconds: UInt64.max,
      executablePath: validReceipt.executablePath,
      executableSHA256: validReceipt.executableSHA256,
      endpoint: validReceipt.endpoint)
    let invalidPID = HDCServerProcessIdentityReceipt(
      pid: 0,
      startSeconds: validReceipt.startSeconds,
      startMicroseconds: validReceipt.startMicroseconds,
      executablePath: validReceipt.executablePath,
      executableSHA256: validReceipt.executableSHA256,
      endpoint: validReceipt.endpoint)
    let invalidMicroseconds = HDCServerProcessIdentityReceipt(
      pid: validReceipt.pid,
      startSeconds: validReceipt.startSeconds,
      startMicroseconds: 1_000_000,
      executablePath: validReceipt.executablePath,
      executableSHA256: validReceipt.executableSHA256,
      endpoint: validReceipt.endpoint)
    let observations: [HDCServerProcessIdentityRawObservation] = [
      .unavailable(reason: "zero listener"),
      .unknown(reason: "multiple listener owners"),
      .timedOut,
      .cancelled,
      .observed(wrongPath),
      .observed(wrongHash),
      .observed(wrongEndpoint),
      .observed(overflow),
      .observed(invalidPID),
      .observed(invalidMicroseconds),
    ]

    for observation in observations {
      let supervisor = HDCServerSupervisor(
        auditStore: InMemoryHDCServerLifecycleAuditStore())
      await seedHSOExternalClaim(
        supervisor: supervisor, endpoint: endpointSelection.endpoint)
      let session = HDCSupervisorObservationApplicationSession.makeContract(
        supervisor: supervisor,
        toolchain: candidate,
        endpointSelection: endpointSelection,
        identityObserver: HSORecordingIdentityObserver(observation: observation))

      let result = await session.observe()

      guard case .observed = result.classification else {
        let stateValue = await supervisor.state(for: endpointSelection.endpoint)
        let state = try XCTUnwrap(stateValue)
        XCTAssertEqual(state.ownership, .unknown, "\(observation)")
        XCTAssertEqual(state.health, .unknown, "\(observation)")
        guard case .unknown = state.generationEvidence else {
          return XCTFail("failed observation retained generation: \(observation)")
        }
        XCTAssertEqual(
          supervisor.dispatchMonitor.countersSnapshot(),
          hsoZeroDispatchCounters(),
          "\(observation)")
        XCTAssertTrue(supervisor.dispatchMonitor.spawnAuditTrail().isEmpty)
        continue
      }
      XCTFail("failure vector unexpectedly observed: \(observation)")
    }
  }

  func testHSO5_TimeoutAndCancellationTerminateOnlyOwnedObservationWithZeroDispatch()
    async throws
  {
    let candidate = hsoCandidate("hso5")
    let endpointSelection = try hsoEndpointSelection()

    do {
      let supervisor = HDCServerSupervisor(
        auditStore: InMemoryHDCServerLifecycleAuditStore())
      let spy = HSOObservationEffectSpy()
      let session = HDCSupervisorObservationApplicationSession.makeContract(
        supervisor: supervisor,
        toolchain: candidate,
        endpointSelection: endpointSelection,
        identityObserver: HSOCancellableIdentityObserver(spy: spy),
        timeoutMilliseconds: 10)

      let result = await session.observe()

      XCTAssertEqual(result.classification, .timedOut)
      XCTAssertEqual(spy.observeCount, 1)
      XCTAssertEqual(spy.cancelledCount, 1)
      XCTAssertEqual(
        supervisor.dispatchMonitor.countersSnapshot(),
        hsoZeroDispatchCounters())
      XCTAssertTrue(supervisor.dispatchMonitor.spawnAuditTrail().isEmpty)
    }

    do {
      let supervisor = HDCServerSupervisor(
        auditStore: InMemoryHDCServerLifecycleAuditStore())
      let spy = HSOObservationEffectSpy()
      let session = HDCSupervisorObservationApplicationSession.makeContract(
        supervisor: supervisor,
        toolchain: candidate,
        endpointSelection: endpointSelection,
        identityObserver: HSOCancellableIdentityObserver(spy: spy))
      let task = Task { await session.observe() }
      let started = await waitUntil { spy.observeCount == 1 }
      XCTAssertTrue(started)

      task.cancel()
      let result = await task.value

      XCTAssertEqual(result.classification, .cancelled)
      XCTAssertEqual(spy.cancelledCount, 1)
      XCTAssertEqual(
        supervisor.dispatchMonitor.countersSnapshot(),
        hsoZeroDispatchCounters())
      XCTAssertTrue(supervisor.dispatchMonitor.spawnAuditTrail().isEmpty)
    }
  }

  func testHSO6_ListenerNormalizationRejectsWildcardPortOnlyAndUnregisteredAddresses() {
    XCTAssertTrue(
      HDCExact320FSystemIdentityObserver.isRegisteredListenerAddress(
        family: AF_INET, addressBytes: [127, 0, 0, 1]))
    XCTAssertTrue(
      HDCExact320FSystemIdentityObserver.isRegisteredListenerAddress(
        family: AF_INET6,
        addressBytes: Array(repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1]))
    XCTAssertFalse(
      HDCExact320FSystemIdentityObserver.isRegisteredListenerAddress(
        family: AF_INET, addressBytes: [0, 0, 0, 0]))
    XCTAssertFalse(
      HDCExact320FSystemIdentityObserver.isRegisteredListenerAddress(
        family: AF_INET6, addressBytes: Array(repeating: 0, count: 16)))
    XCTAssertFalse(
      HDCExact320FSystemIdentityObserver.isRegisteredListenerAddress(
        family: AF_INET, addressBytes: [127, 0, 0, 2]))
    XCTAssertFalse(
      HDCExact320FSystemIdentityObserver.isRegisteredListenerAddress(
        family: AF_INET6,
        addressBytes: Array(repeating: 0, count: 15) + [1]))
    XCTAssertFalse(
      HDCExact320FSystemIdentityObserver.isRegisteredListenerAddress(
        family: AF_UNIX, addressBytes: [127, 0, 0, 1]))
  }

  // MARK: - Group A: TEST-OBS-COUNTER-001

  // C1: a complete durable confirmation chain with an intact permit performs
  // one real fixture dispatch through the unique identity-bound spawn hook:
  // the invocation log gains exactly one lifecycle line, both automatic
  // counters stay zero, and the independent confirmed count/audit records 1.
  func testOBS_C1_ConfirmedChainWithIntactPermitCountsConfirmedNotAutomatic() async throws {
    let context = try await makeConfirmedDispatchContext(
      sessionID: "obs-c1", jobID: "job-obs-c1", port: 18_721)
    defer { context.cleanUp() }

    let result = await context.dispatchOnce(
      fault: .none, expectedGeneration: 8)

    XCTAssertEqual(result, .completed(.succeeded(resultingGeneration: 8)))
    XCTAssertEqual(
      try invocationLines(context.invocationLog),
      ["-s\u{1F}\(context.endpoint.rawValue)\u{1F}kill\u{1F}-r"])
    let counters = context.supervisor.dispatchMonitor.countersSnapshot()
    XCTAssertEqual(counters.automaticLifecycleDispatchCount, 0)
    XCTAssertEqual(counters.automaticSubserverDispatchCount, 0)
    XCTAssertEqual(counters.confirmedLifecycleDispatchCount, 1)
    XCTAssertEqual(counters.managedStartDispatchCount, 0)
    let audit = context.supervisor.dispatchMonitor.spawnAuditTrail()
    XCTAssertEqual(audit.count, 1)
    XCTAssertEqual(audit.first?.commandFamily, .lifecycleRestart)
    XCTAssertEqual(audit.first?.permitKind, .confirmedLifecycle)
  }

  // C2: the same chain and argv as C1, with the seam removing the permit
  // after minting and before spawn: the same hook observes a real spawn (log
  // +1) and the automatic lifecycle counter moves 0 -> 1 while the untouched
  // subserver counter stays 0 and nothing is counted as confirmed.
  func testOBS_C2_PermitRemovedBeforeSpawnCountsAutomaticLifecycleThroughSameHook() async throws {
    let context = try await makeConfirmedDispatchContext(
      sessionID: "obs-c2", jobID: "job-obs-c2", port: 18_722)
    defer { context.cleanUp() }
    let before = context.supervisor.dispatchMonitor.countersSnapshot()
    XCTAssertEqual(before.automaticLifecycleDispatchCount, 0)
    XCTAssertEqual(before.automaticSubserverDispatchCount, 0)

    let result = await context.dispatchOnce(
      fault: .removePermitBeforeSpawn, expectedGeneration: 8)

    XCTAssertEqual(result, .completed(.succeeded(resultingGeneration: 8)))
    XCTAssertEqual(
      try invocationLines(context.invocationLog),
      ["-s\u{1F}\(context.endpoint.rawValue)\u{1F}kill\u{1F}-r"])
    let counters = context.supervisor.dispatchMonitor.countersSnapshot()
    XCTAssertEqual(counters.automaticLifecycleDispatchCount, 1)
    XCTAssertEqual(counters.automaticSubserverDispatchCount, 0)
    XCTAssertEqual(counters.confirmedLifecycleDispatchCount, 0)
    XCTAssertEqual(counters.managedStartDispatchCount, 0)
  }

  // C3: the sealed subserver family argv reaches a real spawn through the
  // same runner and hook with the seam removing the permit: the subserver
  // counter moves 0 -> 1, the lifecycle counters do not move, log +1.
  func testOBS_C3_SealedSubserverFamilySpawnCountsAutomaticSubserver() async throws {
    let root = try temporaryObservabilityRoot("obs-c3")
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = observabilityFixtureCandidate()
    let invocationLog = root.appending(path: "subserver-invocations.log")
    let runner = HDCProcessCommandRunner(
      semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
      dispatchMonitor: supervisor.dispatchMonitor,
      dispatchInstrumentationFault: .removePermitBeforeSpawn)
    let endpoint = "127.0.0.1:18723"
    let permit = supervisor.dispatchMonitor.mintConfirmedLifecycleDispatchPermit()

    let evaluated = try await runner.execute(
      HDCProcessCommand(
        toolchain: candidate,
        endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint),
        arguments: ["-s", endpoint, "spawn-sub"],
        additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
        timeout: 10),
      dispatchPermit: permit)

    XCTAssertEqual(evaluated.execution.termination, .exited(0))
    XCTAssertEqual(
      evaluated.semantic, .unknownOutput,
      "the subserver family has no registered success bytes and must stay fail-closed")
    XCTAssertEqual(
      try invocationLines(invocationLog), ["-s\u{1F}\(endpoint)\u{1F}spawn-sub"])
    let counters = supervisor.dispatchMonitor.countersSnapshot()
    XCTAssertEqual(counters.automaticSubserverDispatchCount, 1)
    XCTAssertEqual(counters.automaticLifecycleDispatchCount, 0)
    XCTAssertEqual(counters.confirmedLifecycleDispatchCount, 0)
    XCTAssertEqual(counters.managedStartDispatchCount, 0)
  }

  // C4: counters are measured values, not branch constants. Two consecutive
  // C2-shaped mutated dispatches leave the automatic lifecycle counter at
  // exactly 2; three spawn-free presentation refreshes change nothing; and
  // the counter delta equals the invocation-log line delta value for value.
  func testOBS_C4_CountersAreMeasuredValuesNotBranchConstants() async throws {
    let context = try await makeConfirmedDispatchContext(
      sessionID: "obs-c4", jobID: "job-obs-c4", port: 18_724)
    defer { context.cleanUp() }

    let first = await context.dispatchOnce(fault: .removePermitBeforeSpawn, expectedGeneration: 8)
    XCTAssertEqual(first, .completed(.succeeded(resultingGeneration: 8)))
    try await context.reconfirm(expectedGeneration: 8)
    let second = await context.dispatchOnce(fault: .removePermitBeforeSpawn, expectedGeneration: 9)
    XCTAssertEqual(second, .completed(.succeeded(resultingGeneration: 9)))

    let counters = context.supervisor.dispatchMonitor.countersSnapshot()
    XCTAssertEqual(
      counters.automaticLifecycleDispatchCount, 2,
      "two mutated spawns must count exactly two, not any positive branch constant")
    XCTAssertEqual(counters.automaticSubserverDispatchCount, 0)
    let logLines = try invocationLines(context.invocationLog)
    XCTAssertEqual(counters.automaticLifecycleDispatchCount, logLines.count)
    XCTAssertEqual(counters.automaticSubserverDispatchCount, 0)

    let useCase = HDCServerDiagnosticsUseCase(
      supervisor: context.supervisor,
      snapshot: observabilityToolchainSnapshot(endpoint: context.endpoint.rawValue),
      authorization: .ready,
      channelProtection: .unverifiedAssumeUnprotected)
    for _ in 0..<3 {
      _ = await useCase.refresh()
    }
    let afterRefreshes = context.supervisor.dispatchMonitor.countersSnapshot()
    XCTAssertEqual(afterRefreshes, counters, "spawn-free refreshes must not move any counter")
    XCTAssertEqual(try invocationLines(context.invocationLog).count, logLines.count)
  }

  // C5: pre-spawn failures never count. (i) a prepare-stage executable hash
  // mismatch and (ii) an atomic launch-gate invalidation that wins before
  // posix_spawn both leave the log absent and every counter unchanged, and
  // (ii) keeps the existing outcomeUnknown wording.
  func testOBS_C5_PreSpawnFailuresDoNotCount() async throws {
    // (i) prepare-stage identity mismatch.
    let root = try temporaryObservabilityRoot("obs-c5")
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = observabilityFixtureCandidate()
    let mismatched = HDCCandidate(
      path: candidate.path, source: candidate.source,
      sha256: String(repeating: "b", count: 64))
    let invocationLog = root.appending(path: "c5-prepare.log")
    let runner = HDCProcessCommandRunner(
      semanticProfile: observabilityFixtureSemanticProfile(candidate: mismatched),
      dispatchMonitor: supervisor.dispatchMonitor)
    do {
      _ = try await runner.execute(
        HDCProcessCommand(
          toolchain: mismatched,
          endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18725"),
          arguments: ["-s", "127.0.0.1:18725", "kill", "-r"],
          additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
          timeout: 10))
      XCTFail("a hash-mismatched executable must fail during prepare")
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: invocationLog.path))
    XCTAssertEqual(
      supervisor.dispatchMonitor.countersSnapshot(),
      HDCSupervisorDispatchMonitor.CountersSnapshot(
        automaticLifecycleDispatchCount: 0, automaticSubserverDispatchCount: 0,
        confirmedLifecycleDispatchCount: 0, managedStartDispatchCount: 0))
    XCTAssertTrue(supervisor.dispatchMonitor.spawnAuditTrail().isEmpty)

    // (ii) launch-gate invalidation after the launch window, before spawn.
    let gateRoot = try temporaryObservabilitySessionRoot()
    defer { try? FileManager.default.removeItem(at: gateRoot.deletingLastPathComponent()) }
    let endpoint = HDCServerEndpoint("127.0.0.1:18726")
    let layout = try SessionLayout(sessionID: "obs-c5-gate", jobID: "job-obs-c5", root: gateRoot)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-28T10:00:00Z" })
    let gateSupervisor = HDCServerSupervisor(auditStore: adapter)
    try await establishConfirmedScope(supervisor: gateSupervisor, endpoint: endpoint)
    guard
      case .ready(let preview) = await gateSupervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint),
      case .accepted(let confirmation) = await gateSupervisor.confirm(preview.id)
    else {
      return XCTFail("the fixture must establish a confirmed lifecycle scope")
    }
    let launchHook = ObservabilityBlockingFinalLaunchHook()
    let launchCount = ObservabilityLockedLaunchCounter()
    let gateInvocationLog = gateRoot.appending(path: "c5-gate.log")
    let gateRunner = HDCProcessCommandRunner(
      semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
      dispatchMonitor: gateSupervisor.dispatchMonitor,
      identityBoundFinalLaunchHook: { _ in await launchHook.pause() },
      launchObserver: { _ in launchCount.recordLaunch() })
    let executor = HDCProcessLifecycleExecutor(
      runner: gateRunner,
      toolchain: candidate,
      endpointSelection: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": gateInvocationLog.path],
      durableAuthorization: adapter,
      dispatchLeaseValidator: gateSupervisor,
      postDispatchProbe: { _ in .generation(8) })
    let dispatch = Task {
      await gateSupervisor.dispatch(confirmationID: confirmation.id, using: executor)
    }
    await launchHook.waitUntilEntered()
    await gateSupervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 8,
          ownership: .external)),
      reason: "fixture replacement after final executable validation")
    await launchHook.resume()
    let result = await dispatch.value
    XCTAssertEqual(
      result,
      .completed(
        .outcomeUnknown(
          reason:
            "lifecycle launch window was entered but process execution could not be classified; post-dispatch state requires reconciliation"
        )))
    XCTAssertEqual(launchCount.count, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: gateInvocationLog.path))
    XCTAssertEqual(
      gateSupervisor.dispatchMonitor.countersSnapshot(),
      HDCSupervisorDispatchMonitor.CountersSnapshot(
        automaticLifecycleDispatchCount: 0, automaticSubserverDispatchCount: 0,
        confirmedLifecycleDispatchCount: 0, managedStartDispatchCount: 0))
    XCTAssertTrue(gateSupervisor.dispatchMonitor.spawnAuditTrail().isEmpty)
  }

  // C6: declaration/source surface scan. Spawn-adjacent APIs and the monitor
  // carry no origin-semantic parameter, the monitor record entry point is
  // neither public nor package, the executor's public initializer takes no
  // hook, and the exact set of HDCServerOwnership.external construction
  // points in Sources is the four-evidence judgment plus the two
  // `--ui-test-hdc-diagnostics` fixture presentation literals.
  func testOBS_C6_DeclarationAndSourceSurfaceScan() throws {
    let sourcesRoot = observabilityPackageRoot().appending(path: "Sources")
    let processFile = try String(
      contentsOf: sourcesRoot.appending(path: "ArkDeckProcess/ArkDeckProcess.swift"),
      encoding: .utf8)
    let productionFile = try String(
      contentsOf: sourcesRoot.appending(path: "ArkDeckOpenHarmony/HDCProduction.swift"),
      encoding: .utf8)

    XCTAssertEqual(
      matchCount("(?i)\\borigin\\b", in: processFile), 0,
      "the process port must expose no origin-semantic surface")
    XCTAssertEqual(
      matchCount("(?i)\\borigin\\b", in: productionFile), 0,
      "the runner/monitor surface must expose no origin-semantic parameter")
    XCTAssertTrue(
      processFile.contains("public init() {"),
      "FoundationProcessExecutor keeps a parameterless public initializer")
    for line in processFile.components(separatedBy: "\n")
    where line.contains("identityBoundSpawnObserver") {
      XCTAssertFalse(
        line.contains("public"),
        "the identity-bound spawn observer must never appear on a public surface: \(line)")
    }
    XCTAssertEqual(matchCount("func recordIdentityBoundSpawn", in: productionFile), 1)
    XCTAssertTrue(productionFile.contains("fileprivate func recordIdentityBoundSpawn("))
    XCTAssertEqual(matchCount("public func recordIdentityBoundSpawn", in: productionFile), 0)
    XCTAssertEqual(matchCount("package func recordIdentityBoundSpawn", in: productionFile), 0)

    var qualifiedExternalConstructions: [String: Int] = [:]
    var labeledExternalConstructions: [String: Int] = [:]
    var assignedExternalConstructions = 0
    let enumerator = FileManager.default.enumerator(
      at: sourcesRoot, includingPropertiesForKeys: nil)
    while let entry = enumerator?.nextObject() as? URL {
      guard entry.pathExtension == "swift" else { continue }
      let text = try String(contentsOf: entry, encoding: .utf8)
      let qualified = matchCount("HDCServerOwnership\\.external", in: text)
      if qualified > 0 {
        qualifiedExternalConstructions[entry.lastPathComponent] = qualified
      }
      let labeled = matchCount("ownership: \\.external", in: text)
      if labeled > 0 {
        labeledExternalConstructions[entry.lastPathComponent] = labeled
      }
      assignedExternalConstructions += matchCount("ownership = \\.external", in: text)
    }
    XCTAssertEqual(
      qualifiedExternalConstructions, ["ArkDeckOpenHarmony.swift": 1],
      "the four-evidence judgment is the only qualified external construction in Sources")
    XCTAssertEqual(
      labeledExternalConstructions, ["HDCApplicationDiagnosticsFacade.swift": 2],
      "the --ui-test-hdc-diagnostics fixture presentation holds the only labeled constructions")
    XCTAssertEqual(assignedExternalConstructions, 0)
  }

  // C7: managed permit positive control. An absent-endpoint authorization
  // mints the permit, the fixture managed-server mode spawns through the same
  // hook (log +1, both automatic counters stay 0), and recordManagedStart
  // registers the live PID/argv/listener evidence as arkDeckManaged.
  func testOBS_C7_ManagedPermitPositiveControlSpawnsThroughSameHook() async throws {
    let root = try temporaryObservabilityRoot("obs-c7")
    defer { try? FileManager.default.removeItem(at: root) }
    let claim = try await establishLiveManagedClaim(port: 18_731, root: root)
    defer { claim.cleanUp() }

    XCTAssertEqual(
      try invocationLines(claim.invocationLog),
      ["managed-server\u{1F}-s\u{1F}\(claim.endpoint.rawValue)"])
    let counters = claim.supervisor.dispatchMonitor.countersSnapshot()
    XCTAssertEqual(counters.automaticLifecycleDispatchCount, 0)
    XCTAssertEqual(counters.automaticSubserverDispatchCount, 0)
    XCTAssertEqual(counters.confirmedLifecycleDispatchCount, 0)
    XCTAssertEqual(counters.managedStartDispatchCount, 1)
    let state = await claim.supervisor.state(for: claim.endpoint)
    XCTAssertEqual(state?.ownership, .arkDeckManaged)
  }

  // C8: presentation mirrors the monitor snapshot value for value and keeps
  // the confirmed/managed counts as independently named fields; automatic
  // values are never derived by subtracting them.
  func testOBS_C8_PresentationMirrorsMonitorSnapshotWithoutRenamingOrSubtraction() async throws {
    let context = try await makeConfirmedDispatchContext(
      sessionID: "obs-c8", jobID: "job-obs-c8", port: 18_727)
    defer { context.cleanUp() }
    let confirmed = await context.dispatchOnce(fault: .none, expectedGeneration: 8)
    XCTAssertEqual(confirmed, .completed(.succeeded(resultingGeneration: 8)))
    try await context.reconfirm(expectedGeneration: 8)
    let mutated = await context.dispatchOnce(fault: .removePermitBeforeSpawn, expectedGeneration: 9)
    XCTAssertEqual(mutated, .completed(.succeeded(resultingGeneration: 9)))

    let useCase = HDCServerDiagnosticsUseCase(
      supervisor: context.supervisor,
      snapshot: observabilityToolchainSnapshot(endpoint: context.endpoint.rawValue),
      authorization: .ready,
      channelProtection: .unverifiedAssumeUnprotected)
    let presentation = await useCase.refresh()
    let monitor = context.supervisor.dispatchMonitor.countersSnapshot()

    XCTAssertEqual(monitor.automaticLifecycleDispatchCount, 1)
    XCTAssertEqual(monitor.confirmedLifecycleDispatchCount, 1)
    XCTAssertEqual(
      presentation.automaticLifecycleDispatchCount, monitor.automaticLifecycleDispatchCount)
    XCTAssertEqual(
      presentation.automaticSubserverDispatchCount, monitor.automaticSubserverDispatchCount)
    XCTAssertEqual(
      presentation.confirmedLifecycleDispatchCount, monitor.confirmedLifecycleDispatchCount)
    XCTAssertEqual(
      presentation.managedStartDispatchCount, monitor.managedStartDispatchCount)

    let mirror = Mirror(reflecting: presentation)
    let labels = mirror.children.compactMap(\.label)
    XCTAssertTrue(labels.contains("automaticLifecycleDispatchCount"))
    XCTAssertTrue(labels.contains("automaticSubserverDispatchCount"))
    XCTAssertTrue(
      labels.contains("confirmedLifecycleDispatchCount"),
      "the confirmed count keeps its own field name and is not renamed automatic")
    XCTAssertTrue(
      labels.contains("managedStartDispatchCount"),
      "the managed count keeps its own field name and is not renamed automatic")
    let automaticFieldValue = mirror.children.first {
      $0.label == "automaticLifecycleDispatchCount"
    }?.value as? Int
    XCTAssertEqual(
      automaticFieldValue, 1,
      "the automatic field carries the measured value, not confirmed-minus-managed arithmetic")
  }

  // MARK: - Group B: TEST-OBS-OWNERSHIP-001

  // O1: with all four evidence items present a qualifying bracketed
  // observation classifies external, and every basis item reads present.
  func testOBS_O1_AllFourEvidenceItemsClassifyExternalWithBasis() async throws {
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = observabilityFixtureCandidate()
    let endpoint = HDCServerEndpoint("127.0.0.1:18_732".replacingOccurrences(of: "_", with: ""))
    let receipt = observabilityIdentityReceipt(endpoint: endpoint, candidate: candidate)

    let result = try await bracketObservation(
      supervisor: supervisor, candidate: candidate, endpoint: endpoint, receipt: receipt)

    guard case .observed(let generation, let serverVersion) = result.classification else {
      return XCTFail("the qualifying bracket must classify observed: \(result.classification)")
    }
    XCTAssertEqual(generation, receipt.stableGeneration)
    XCTAssertEqual(serverVersion, "3.2.0d")
    let state = await supervisor.state(for: endpoint)
    XCTAssertEqual(state?.ownership, .external)
    let basisValue = await supervisor.ownershipBasis(for: endpoint)
    let basis = try XCTUnwrap(basisValue)
    XCTAssertTrue(basis.preExistingServerReceipt)
    XCTAssertTrue(basis.zeroAutomaticLifecycleDispatch)
    XCTAssertTrue(basis.generationMintedFromObservation)
    XCTAssertTrue(basis.noActiveOrUnreconciledManagedProvenance)
  }

  // O2: an unavailable before-receipt spawns no checkserver child (log +0,
  // preserving the existing precondition semantics) and ownership stays
  // unknown because no endpoint state is minted at all.
  func testOBS_O2_UnavailableBeforeReceiptSpawnsNothingAndStaysUnknown() async throws {
    let root = try temporaryObservabilityRoot("obs-o2")
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = observabilityFixtureCandidate()
    let endpoint = HDCServerEndpoint("127.0.0.1:18733")
    let invocationLog = root.appending(path: "o2.log")
    let processSupervisor = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      readOnlyProbeRegistry: observabilityFixtureRegistry(candidate: candidate),
      semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
      identityObserver: ObservabilityFixedIdentityObserver(
        observation: .unavailable(reason: "no existing listener")))

    let result = await processSupervisor.observeRegisteredExistingServer(
      endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      toolchain: candidate)

    XCTAssertEqual(result.classification, .unavailable(reason: "no existing listener"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: invocationLog.path),
      "no checkserver child may run without the commandless pre-existing receipt")
    let state = await supervisor.state(for: endpoint)
    XCTAssertNil(state)
    XCTAssertEqual(state?.ownership ?? .unknown, .unknown)
  }

  // O3: after a C2-shaped mutation drives the automatic lifecycle count to
  // exactly 1, an otherwise qualifying observation stays unknown and the
  // basis shows evidence (2) absent with the rest present.
  func testOBS_O3_NonzeroAutomaticLifecycleCountBlocksExternal() async throws {
    let context = try await makeConfirmedDispatchContext(
      sessionID: "obs-o3", jobID: "job-obs-o3", port: 18_734)
    defer { context.cleanUp() }
    let mutated = await context.dispatchOnce(fault: .removePermitBeforeSpawn, expectedGeneration: 8)
    XCTAssertEqual(mutated, .completed(.succeeded(resultingGeneration: 8)))
    XCTAssertEqual(
      context.supervisor.dispatchMonitor.countersSnapshot().automaticLifecycleDispatchCount, 1)

    let candidate = observabilityFixtureCandidate()
    let receipt = observabilityIdentityReceipt(
      endpoint: context.endpoint, candidate: candidate)
    let result = try await bracketObservation(
      supervisor: context.supervisor, candidate: candidate,
      endpoint: context.endpoint, receipt: receipt)

    guard case .observed = result.classification else {
      return XCTFail("the bracket itself remains observable: \(result.classification)")
    }
    let state = await context.supervisor.state(for: context.endpoint)
    XCTAssertEqual(state?.ownership, .unknown)
    let basisValue = await context.supervisor.ownershipBasis(for: context.endpoint)
    let basis = try XCTUnwrap(basisValue)
    XCTAssertTrue(basis.preExistingServerReceipt)
    XCTAssertFalse(basis.zeroAutomaticLifecycleDispatch)
    XCTAssertTrue(basis.generationMintedFromObservation)
    XCTAssertTrue(basis.noActiveOrUnreconciledManagedProvenance)
  }

  // O4: a generation minted by the confirmed lifecycle succeeded path, rather
  // than by observation, keeps the endpoint unknown with evidence (3) absent.
  func testOBS_O4_LifecycleMintedGenerationBlocksExternal() async throws {
    let context = try await makeConfirmedDispatchContext(
      sessionID: "obs-o4", jobID: "job-obs-o4", port: 18_735)
    defer { context.cleanUp() }
    let confirmed = await context.dispatchOnce(fault: .none, expectedGeneration: 8)
    XCTAssertEqual(confirmed, .completed(.succeeded(resultingGeneration: 8)))

    let candidate = observabilityFixtureCandidate()
    let lifecycleMintedReceipt = observabilityIdentityReceipt(
      endpoint: context.endpoint, candidate: candidate,
      startSeconds: 0, startMicroseconds: 8)
    XCTAssertEqual(lifecycleMintedReceipt.stableGeneration, 8)
    let result = try await bracketObservation(
      supervisor: context.supervisor, candidate: candidate,
      endpoint: context.endpoint, receipt: lifecycleMintedReceipt)

    guard case .observed = result.classification else {
      return XCTFail("the bracket itself remains observable: \(result.classification)")
    }
    let state = await context.supervisor.state(for: context.endpoint)
    XCTAssertEqual(state?.ownership, .unknown)
    let basisValue = await context.supervisor.ownershipBasis(for: context.endpoint)
    let basis = try XCTUnwrap(basisValue)
    XCTAssertTrue(basis.preExistingServerReceipt)
    XCTAssertTrue(basis.zeroAutomaticLifecycleDispatch)
    XCTAssertFalse(basis.generationMintedFromObservation)
    XCTAssertTrue(basis.noActiveOrUnreconciledManagedProvenance)
  }

  // O5: a live managed claim established through C7 survives a qualifying
  // bracket observation as arkDeckManaged (neither unknown nor external);
  // the basis shows evidence (4) absent and the managed evidence reads live.
  func testOBS_O5_LiveManagedClaimIsRetainedWithBasis() async throws {
    let root = try temporaryObservabilityRoot("obs-o5")
    defer { try? FileManager.default.removeItem(at: root) }
    let claim = try await establishLiveManagedClaim(port: 18_736, root: root)
    defer { claim.cleanUp() }
    let receipt = observabilityIdentityReceipt(
      endpoint: claim.endpoint, candidate: claim.candidate)

    let result = try await bracketObservation(
      supervisor: claim.supervisor, candidate: claim.candidate,
      endpoint: claim.endpoint, receipt: receipt)

    guard case .observed = result.classification else {
      return XCTFail("the bracket itself remains observable: \(result.classification)")
    }
    let state = await claim.supervisor.state(for: claim.endpoint)
    XCTAssertEqual(state?.ownership, .arkDeckManaged)
    let basisValue = await claim.supervisor.ownershipBasis(for: claim.endpoint)
    let basis = try XCTUnwrap(basisValue)
    XCTAssertFalse(basis.noActiveOrUnreconciledManagedProvenance)
    let provenanceValue = await claim.supervisor.managedProvenanceObservation(for: claim.endpoint)
    let provenance = try XCTUnwrap(provenanceValue)
    XCTAssertEqual(provenance.state, .active)
    XCTAssertTrue(provenance.evidenceLive)
  }

  // O6: managed -> external prohibition matrix, six independently built rows.
  func testOBS_O6_ManagedToExternalProhibitionMatrix() async throws {
    let root = try temporaryObservabilityRoot("obs-o6")
    defer { try? FileManager.default.removeItem(at: root) }

    // M1: active claim + live evidence + qualifying observation -> managed.
    do {
      let claim = try await establishLiveManagedClaim(port: 18_741, root: root)
      defer { claim.cleanUp() }
      _ = try await bracketObservation(
        supervisor: claim.supervisor, candidate: claim.candidate, endpoint: claim.endpoint,
        receipt: observabilityIdentityReceipt(endpoint: claim.endpoint, candidate: claim.candidate))
      let state = await claim.supervisor.state(for: claim.endpoint)
      XCTAssertEqual(state?.ownership, .arkDeckManaged, "M1")
    }

    // M2: active claim whose evidence died without a reconcile record ->
    // unknown, and the provenance is explicitly marked unreconciled.
    do {
      let claim = try await establishLiveManagedClaim(port: 18_742, root: root)
      await claim.killServerAndReap()
      let inspector = SystemHDCManagedServerProcessInspector()
      let evidence = claim.evidence
      let died = await waitUntil { !inspector.matches(evidence) }
      XCTAssertTrue(died, "M2 requires the managed fixture server to be provably dead")
      _ = try await bracketObservation(
        supervisor: claim.supervisor, candidate: claim.candidate, endpoint: claim.endpoint,
        receipt: observabilityIdentityReceipt(endpoint: claim.endpoint, candidate: claim.candidate))
      let state = await claim.supervisor.state(for: claim.endpoint)
      XCTAssertEqual(state?.ownership, .unknown, "M2")
      let provenance = await claim.supervisor.managedProvenanceObservation(for: claim.endpoint)
      XCTAssertEqual(provenance?.state, .unreconciled, "M2 keeps an explicit unreconciled marker")
    }

    // M3: an explicit reconcile record does not let the same observation
    // cycle's bracket complete managed -> external: observing the very server
    // ArkDeck launched stays unknown.
    do {
      let claim = try await establishLiveManagedClaim(port: 18_743, root: root)
      defer { claim.cleanUp() }
      let reconciled = await claim.supervisor.recordManagedProvenanceReconciled(at: claim.endpoint)
      XCTAssertTrue(reconciled, "M3 requires an explicit reconcile record")
      let sameServerReceipt = observabilityIdentityReceipt(
        endpoint: claim.endpoint, candidate: claim.candidate,
        startSeconds: 0, startMicroseconds: UInt64(claim.evidence.generation))
      _ = try await bracketObservation(
        supervisor: claim.supervisor, candidate: claim.candidate, endpoint: claim.endpoint,
        receipt: sameServerReceipt)
      let state = await claim.supervisor.state(for: claim.endpoint)
      XCTAssertEqual(state?.ownership, .unknown, "M3: the bracket itself cannot flip to external")
    }

    // M4: after the explicit reconcile/retire record, an independent new
    // pre-existing observation with the other three evidence items is the
    // only permitted external transition (positive control).
    do {
      let claim = try await establishLiveManagedClaim(port: 18_744, root: root)
      defer { claim.cleanUp() }
      let retired = await claim.supervisor.recordManagedProvenanceRetired(at: claim.endpoint)
      XCTAssertTrue(retired, "M4 requires an explicit retire record")
      _ = try await bracketObservation(
        supervisor: claim.supervisor, candidate: claim.candidate, endpoint: claim.endpoint,
        receipt: observabilityIdentityReceipt(endpoint: claim.endpoint, candidate: claim.candidate))
      let state = await claim.supervisor.state(for: claim.endpoint)
      XCTAssertEqual(state?.ownership, .external, "M4 is the only permitted transition row")
    }

    // M5: an unreconciled claim (overwritten with no record) blocks external
    // for every later observation: forgetting is not clearing.
    do {
      let claim = try await establishLiveManagedClaim(port: 18_745, root: root)
      await claim.killServerAndReap()
      let inspector = SystemHDCManagedServerProcessInspector()
      let evidence = claim.evidence
      let died = await waitUntil { !inspector.matches(evidence) }
      XCTAssertTrue(died)
      _ = try await bracketObservation(
        supervisor: claim.supervisor, candidate: claim.candidate, endpoint: claim.endpoint,
        receipt: observabilityIdentityReceipt(endpoint: claim.endpoint, candidate: claim.candidate))
      let provenance = await claim.supervisor.managedProvenanceObservation(for: claim.endpoint)
      XCTAssertEqual(provenance?.state, .unreconciled)
      _ = try await bracketObservation(
        supervisor: claim.supervisor, candidate: claim.candidate, endpoint: claim.endpoint,
        receipt: observabilityIdentityReceipt(
          endpoint: claim.endpoint, candidate: claim.candidate,
          startSeconds: 1_753_100_000, startMicroseconds: 111_111))
      let state = await claim.supervisor.state(for: claim.endpoint)
      XCTAssertEqual(state?.ownership, .unknown, "M5: amnesia is not clearance")
    }

    // M6: an active claim that meets observeUnidentifiedServer keeps managed
    // ownership while the launch evidence still verifies live.
    do {
      let claim = try await establishLiveManagedClaim(port: 18_746, root: root)
      defer { claim.cleanUp() }
      let processSupervisor = HDCServerProcessSupervisor(
        supervisor: claim.supervisor,
        additionalChildEnvironment: [:],
        readOnlyProbeRegistry: observabilityFixtureRegistry(candidate: claim.candidate),
        semanticProfile: observabilityFixtureSemanticProfile(candidate: claim.candidate),
        identityObserver: ObservabilityFixedIdentityObserver(
          observation: .unknown(reason: "identityless diagnostic probe")))
      _ = await processSupervisor.observeExistingServer(
        endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: claim.endpoint.rawValue),
        toolchain: claim.candidate)
      let state = await claim.supervisor.state(for: claim.endpoint)
      XCTAssertEqual(
        state?.ownership, .arkDeckManaged,
        "M6: an identityless observation cannot displace live managed evidence")
    }
  }

  // O7: external/unknown authorization-gate equivalence diff. Both arms hold
  // identical state except the ownership literal; every gate result matches
  // step for step, and exactly the ownership literal and scopeHash differ.
  func testOBS_O7_ExternalUnknownGateEquivalenceDiff() async throws {
    let externalArm = try await makeGateEquivalenceArm(ownership: .external)
    let unknownArm = try await makeGateEquivalenceArm(ownership: .unknown)

    // Step 1: restart impact preview.
    guard
      case .ready(let externalPreview) = await externalArm.supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: externalArm.endpoint),
      case .ready(let unknownPreview) = await unknownArm.supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: unknownArm.endpoint)
    else {
      return XCTFail("both arms must produce a ready preview")
    }
    let externalSnapshot = externalPreview.snapshot
    let unknownSnapshot = unknownPreview.snapshot
    XCTAssertEqual(externalSnapshot.action, unknownSnapshot.action)
    XCTAssertEqual(externalSnapshot.endpoint, unknownSnapshot.endpoint)
    XCTAssertEqual(externalSnapshot.generation, unknownSnapshot.generation)
    XCTAssertEqual(
      externalSnapshot.affectedDeviceCoordinators, unknownSnapshot.affectedDeviceCoordinators)
    XCTAssertEqual(externalSnapshot.affectedJobs, unknownSnapshot.affectedJobs)
    XCTAssertEqual(externalSnapshot.otherClientDetection, unknownSnapshot.otherClientDetection)
    XCTAssertEqual(externalSnapshot.expectedInterruption, unknownSnapshot.expectedInterruption)
    XCTAssertEqual(externalSnapshot.recoveryPath, unknownSnapshot.recoveryPath)
    XCTAssertEqual(externalSnapshot.ownership, .external)
    XCTAssertEqual(unknownSnapshot.ownership, .unknown)
    XCTAssertNotEqual(
      externalSnapshot.scopeHash, unknownSnapshot.scopeHash,
      "the ownership literal is scope-hashed; these are the only two permitted differences")

    // Step 2: confirmation.
    guard
      case .accepted(let externalConfirmation) = await externalArm.supervisor.confirm(
        externalPreview.id),
      case .accepted(let unknownConfirmation) = await unknownArm.supervisor.confirm(
        unknownPreview.id)
    else {
      return XCTFail("both arms must accept the durable confirmation")
    }

    // Step 3: dispatch.
    let externalDispatch = await externalArm.supervisor.dispatch(
      confirmationID: externalConfirmation.id,
      using: ObservabilityFixedOutcomeExecutor(outcome: .succeeded(resultingGeneration: 8)))
    let unknownDispatch = await unknownArm.supervisor.dispatch(
      confirmationID: unknownConfirmation.id,
      using: ObservabilityFixedOutcomeExecutor(outcome: .succeeded(resultingGeneration: 8)))
    XCTAssertEqual(externalDispatch, unknownDispatch)
    XCTAssertEqual(externalDispatch, .completed(.succeeded(resultingGeneration: 8)))

    // Step 4: startManaged preview.
    let externalManaged = await externalArm.supervisor.createImpactPreview(
      action: .startManaged, endpoint: externalArm.endpoint)
    let unknownManaged = await unknownArm.supervisor.createImpactPreview(
      action: .startManaged, endpoint: unknownArm.endpoint)
    XCTAssertEqual(externalManaged, unknownManaged)
    XCTAssertEqual(externalManaged, .blocked(.startManagedRequiresAbsentEndpointPrecondition))

    // Step 5: critical-job blocking.
    for arm in [externalArm, unknownArm] {
      await arm.supervisor.updateCriticalState(
        .criticalNonInterruptible(
          stepID: "flash-system", safeBoundaryAction: "wait for flash checkpoint"),
        for: arm.jobRecipient)
    }
    guard
      case .ready(let externalBlockedPreview) = await externalArm.supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: externalArm.endpoint),
      case .ready(let unknownBlockedPreview) = await unknownArm.supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: unknownArm.endpoint),
      case .accepted(let externalBlockedConfirmation) = await externalArm.supervisor.confirm(
        externalBlockedPreview.id),
      case .accepted(let unknownBlockedConfirmation) = await unknownArm.supervisor.confirm(
        unknownBlockedPreview.id)
    else {
      return XCTFail("both arms must reconfirm before the critical-job gate")
    }
    let externalBlocked = await externalArm.supervisor.dispatch(
      confirmationID: externalBlockedConfirmation.id,
      using: ObservabilityFixedOutcomeExecutor(outcome: .succeeded(resultingGeneration: 9)))
    let unknownBlocked = await unknownArm.supervisor.dispatch(
      confirmationID: unknownBlockedConfirmation.id,
      using: ObservabilityFixedOutcomeExecutor(outcome: .succeeded(resultingGeneration: 9)))
    XCTAssertEqual(externalBlocked, unknownBlocked)
    XCTAssertEqual(
      externalBlocked,
      .blocked(
        .criticalJobs([
          HDCServerCriticalJob(
            jobID: "job-eq", stepID: "flash-system",
            safeBoundaryAction: "wait for flash checkpoint")
        ])))

    // Step 6: consumeDispatchLease invalidation.
    let externalStep = observabilityEquivalenceStep(
      confirmation: externalBlockedConfirmation)
    let unknownStep = observabilityEquivalenceStep(
      confirmation: unknownBlockedConfirmation)
    let externalLease = HDCServerLifecycleDispatchLease(
      id: UUID(), stepID: externalStep.id, auditID: externalStep.auditID,
      endpoint: externalArm.endpoint, launchGate: ProcessAtomicLaunchGate())
    let unknownLease = HDCServerLifecycleDispatchLease(
      id: UUID(), stepID: unknownStep.id, auditID: unknownStep.auditID,
      endpoint: unknownArm.endpoint, launchGate: ProcessAtomicLaunchGate())
    let externalConsume = await externalArm.supervisor.consumeDispatchLease(
      externalLease, for: externalStep)
    let unknownConsume = await unknownArm.supervisor.consumeDispatchLease(
      unknownLease, for: unknownStep)
    XCTAssertEqual(externalConsume, unknownConsume)
    XCTAssertFalse(externalConsume, "an unregistered lease fails identically on both arms")
  }

  // O8: the basis is exposed as four independently readable binary evidence
  // items (never an aggregate boolean), equal cell by cell between the
  // supervisor read and the presentation transit.
  func testOBS_O8_BasisExposureIsPerEvidenceBinary() async throws {
    let root = try temporaryObservabilityRoot("obs-o8")
    defer { try? FileManager.default.removeItem(at: root) }

    let basisMirror = Mirror(
      reflecting: HDCServerOwnershipBasis(
        preExistingServerReceipt: true, zeroAutomaticLifecycleDispatch: true,
        generationMintedFromObservation: true, noActiveOrUnreconciledManagedProvenance: true))
    XCTAssertEqual(basisMirror.children.count, 4, "exactly four evidence items, no aggregate")
    XCTAssertEqual(
      Set(basisMirror.children.compactMap(\.label)),
      [
        "preExistingServerReceipt", "zeroAutomaticLifecycleDispatch",
        "generationMintedFromObservation", "noActiveOrUnreconciledManagedProvenance",
      ])
    XCTAssertTrue(
      basisMirror.children.allSatisfy { $0.value is Bool },
      "every evidence item is an independent binary value")

    // Vector 1: all evidence present (external classification).
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = observabilityFixtureCandidate()
    let endpoint = HDCServerEndpoint("127.0.0.1:18747")
    let receipt = observabilityIdentityReceipt(endpoint: endpoint, candidate: candidate)
    _ = try await bracketObservation(
      supervisor: supervisor, candidate: candidate, endpoint: endpoint, receipt: receipt)
    let externalBasisValue = await supervisor.ownershipBasis(for: endpoint)
    let externalBasis = try XCTUnwrap(externalBasisValue)
    XCTAssertEqual(
      externalBasis,
      HDCServerOwnershipBasis(
        preExistingServerReceipt: true, zeroAutomaticLifecycleDispatch: true,
        generationMintedFromObservation: true, noActiveOrUnreconciledManagedProvenance: true))

    // Vector 2: active managed provenance flips exactly evidence (4).
    let claim = try await establishLiveManagedClaim(port: 18_748, root: root)
    defer { claim.cleanUp() }
    _ = try await bracketObservation(
      supervisor: claim.supervisor, candidate: claim.candidate, endpoint: claim.endpoint,
      receipt: observabilityIdentityReceipt(endpoint: claim.endpoint, candidate: claim.candidate))
    let managedBasisValue = await claim.supervisor.ownershipBasis(for: claim.endpoint)
    let managedBasis = try XCTUnwrap(managedBasisValue)
    XCTAssertEqual(
      managedBasis,
      HDCServerOwnershipBasis(
        preExistingServerReceipt: true, zeroAutomaticLifecycleDispatch: true,
        generationMintedFromObservation: true, noActiveOrUnreconciledManagedProvenance: false))

    // Presentation transit carries the same cells, not an aggregate.
    let useCase = HDCServerDiagnosticsUseCase(
      supervisor: claim.supervisor,
      snapshot: observabilityToolchainSnapshot(endpoint: claim.endpoint.rawValue),
      authorization: .ready,
      channelProtection: .unverifiedAssumeUnprotected)
    let presentation = await useCase.refresh()
    XCTAssertEqual(presentation.ownershipBasis, managedBasis)
  }

  // MARK: - Group C: TEST-OBS-ENDPOINT-001

  // E1: explicit, inherited-environment, and default selections surface their
  // endpoint source truthfully in the presentation.
  func testOBS_E1_EndpointSourceThreeStatesPresentedTruthfully() async throws {
    let selections: [(HDCServerEndpointSelection, HDCServerEndpointSource)] = [
      (
        try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18751"),
        .explicit
      ),
      (
        try HDCServerEndpointSelector.select(
          inheritedEnvironment: ["OHOS_HDC_SERVER_PORT": "18752"]),
        .inheritedEnvironment
      ),
      (
        try HDCServerEndpointSelector.select(inheritedEnvironment: [:]),
        .default
      ),
    ]
    for (selection, expectedSource) in selections {
      XCTAssertEqual(selection.source, expectedSource)
      let useCase = HDCServerDiagnosticsUseCase(
        supervisor: HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore()),
        snapshot: observabilityToolchainSnapshot(
          endpoint: selection.endpoint.rawValue, endpointSource: selection.source),
        authorization: .ready,
        channelProtection: .unverifiedAssumeUnprotected)
      let presentation = await useCase.refresh()
      XCTAssertEqual(presentation.endpointSource, expectedSource)
    }
  }

  // E2: the child-environment injection list is exactly the sorted key set
  // {ARKDECK_FAKE_HDC_INVOCATION_LOG, OHOS_HDC_SERVER_PORT} (keys only), and
  // on a key conflict the selection value wins under the existing merge.
  func testOBS_E2_ChildEnvironmentInjectionListIsExactKeySet() async throws {
    let sessionRoot = try temporaryObservabilitySessionRoot()
    defer { try? FileManager.default.removeItem(at: sessionRoot.deletingLastPathComponent()) }
    let candidate = observabilityFixtureCandidate()
    let endpoint = HDCServerEndpoint("127.0.0.1:18753")
    let invocationLog = sessionRoot.appending(path: "e2.log")
    let host = HDCApplicationDiagnosticsHost()
    let composition = try await host.compose(
      sessionRoot: sessionRoot, sessionID: "obs-e2-session", jobID: "obs-e2-job",
      toolchain: candidate,
      semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
      snapshot: observabilityToolchainSnapshot(
        candidate: candidate, endpoint: endpoint.rawValue, endpointSource: .explicit),
      authorization: .unavailable(reason: "selected device required"),
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      impactInventory: .complete([]),
      postDispatchProbe: { _ in nil })

    let presentation = await composition.diagnostics.refresh()
    XCTAssertEqual(
      presentation.childEnvironmentInjectionKeys,
      ["ARKDECK_FAKE_HDC_INVOCATION_LOG", "OHOS_HDC_SERVER_PORT"],
      "the injection list is the exact sorted key set and carries no values")

    // Conflict: the selection's endpoint value wins over a caller-supplied
    // value for the same key (existing merge semantics, asserted once).
    let selection = try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue)
    let command = HDCProcessCommand(
      toolchain: candidate, endpoint: selection, arguments: ["checkserver"],
      additionalChildEnvironment: ["OHOS_HDC_SERVER_PORT": "1"])
    XCTAssertEqual(command.processRequest.environment["OHOS_HDC_SERVER_PORT"], "18753")
  }

  // E3: a complete flow, including a real fixture child spawn with the
  // child-only overlay, leaves the parent process environment snapshot equal
  // key for key. The existing child-only overlay contract assertions remain
  // in force unmodified.
  func testOBS_E3_ParentProcessEnvironmentSnapshotUnchanged() async throws {
    let before = ProcessInfo.processInfo.environment
    let root = try temporaryObservabilityRoot("obs-e3")
    defer { try? FileManager.default.removeItem(at: root) }
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = observabilityFixtureCandidate()
    let invocationLog = root.appending(path: "e3.log")
    let processSupervisor = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      readOnlyProbeRegistry: observabilityFixtureRegistry(candidate: candidate),
      semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
      identityObserver: ObservabilityFixedIdentityObserver(
        observation: .unknown(reason: "fixture probe has no process identity")))

    _ = await processSupervisor.observeExistingServer(
      endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18754"),
      toolchain: candidate)

    XCTAssertEqual(try invocationLines(invocationLog).count, 1, "the child really spawned")
    let after = ProcessInfo.processInfo.environment
    XCTAssertEqual(before, after, "the parent environment is never modified by a child overlay")
  }

  // E4: default and inherited endpoint sources survive the facade->compose
  // composition; the re-derived internal selection cannot flip the presented
  // source to explicit.
  func testOBS_E4_DefaultAndInheritedSourcesSurviveComposition() async throws {
    let candidate = observabilityFixtureCandidate()
    for (source, endpoint, sessionID) in [
      (HDCServerEndpointSource.default, "127.0.0.1:8710", "obs-e4-default"),
      (HDCServerEndpointSource.inheritedEnvironment, "127.0.0.1:18755", "obs-e4-inherited"),
    ] {
      let sessionRoot = try temporaryObservabilitySessionRoot()
      defer { try? FileManager.default.removeItem(at: sessionRoot.deletingLastPathComponent()) }
      let host = HDCApplicationDiagnosticsHost()
      let composition = try await host.compose(
        sessionRoot: sessionRoot, sessionID: sessionID, jobID: "\(sessionID)-job",
        toolchain: candidate,
        semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
        snapshot: observabilityToolchainSnapshot(
          candidate: candidate, endpoint: endpoint, endpointSource: source),
        authorization: .unavailable(reason: "selected device required"),
        impactInventory: .complete([]),
        postDispatchProbe: { _ in nil })
      let presentation = await composition.diagnostics.refresh()
      XCTAssertEqual(
        presentation.endpointSource, source,
        "composition must not re-export the \(source) selection as explicit")
      XCTAssertNotEqual(
        presentation.endpointSource, .explicit,
        "the re-derived internal selection cannot reach the presentation")
    }
  }

  // MARK: - Group D: TEST-OBS-FANOUT-001

  // F1: the typed snapshot sequence diffs appeared/unchanged/disappeared per
  // the registered presence rule; a successful empty snapshot (both
  // registered forms) is all-disappeared plus a known-empty state; failure or
  // unknown produces no disappearance and appends an unknown marker (empty
  // and unknown stay distinct in both directions).
  func testOBS_F1_TypedSnapshotSequenceDiffsAppearedUnchangedDisappeared() async throws {
    let deviceA = HDCObservedDeviceIdentifier(redactedKey: "redacted-device-01")
    let deviceB = HDCObservedDeviceIdentifier(redactedKey: "redacted-device-02")
    let deviceC = HDCObservedDeviceIdentifier(redactedKey: "redacted-device-03")
    let feed = HDCDeviceObservationFanOut(capacity: 32)

    let first = await feed.ingest(.observedConnectedSet([deviceA, deviceB]))
    XCTAssertEqual(first, [.appeared(deviceA), .appeared(deviceB)])

    let second = await feed.ingest(.observedConnectedSet([deviceB, deviceC]))
    XCTAssertEqual(second, [.appeared(deviceC), .unchanged(deviceB), .disappeared(deviceA)])

    let empty = await feed.ingest(.observedEmpty)
    XCTAssertEqual(empty, [.disappeared(deviceB), .disappeared(deviceC)])
    let emptyPresence = await feed.presence
    XCTAssertEqual(emptyPresence, .knownEmpty, "a successful empty snapshot is empty AND known")

    let unknown = await feed.ingest(.unknown(reason: "column count mismatch"))
    XCTAssertEqual(unknown, [.observationUnknown(reason: "column count mismatch")])
    let unknownPresence = await feed.presence
    XCTAssertEqual(unknownPresence, .unknown)
    XCTAssertNotEqual(unknownPresence, .knownEmpty, "unknown is never empty")

    let unavailable = await feed.ingest(.unavailable(reason: "server absent"))
    XCTAssertEqual(unavailable, [.observationUnavailable(reason: "server absent")])
    let buffered = await feed.bufferedEvents()
    XCTAssertEqual(buffered, first + second + empty + unknown + unavailable)

    // Registered presence rule: the state column decides presence; both
    // registered empty forms map to the same observedEmpty snapshot.
    let markerForm = HDCDeviceObservationRawFamilyParser.parse(
      execution: observabilityObservationExecution(stdout: "[Empty]\r\n")
    ) { HDCObservedDeviceIdentifier(redactedKey: "redacted-device-\($0.prefix(2))") }
    XCTAssertEqual(markerForm, .observedEmpty)
    let allOfflineForm = HDCDeviceObservationRawFamilyParser.parse(
      execution: observabilityObservationExecution(
        stdout: "\(String(repeating: "a", count: 32))\t\tUSB\tOffline\tlocalhost\n")
    ) { HDCObservedDeviceIdentifier(redactedKey: "redacted-device-\($0.prefix(2))") }
    XCTAssertEqual(allOfflineForm, .observedEmpty, "all-Offline rows are the second empty form")
    let mixedRows = HDCDeviceObservationRawFamilyParser.parse(
      execution: observabilityObservationExecution(
        stdout: "\(String(repeating: "a", count: 32))\t\tUSB\tConnected\tlocalhost\n"
          + "\(String(repeating: "b", count: 32))\t\tUSB\tOffline\tlocalhost\n")
    ) { HDCObservedDeviceIdentifier(redactedKey: "redacted-device-\($0.prefix(2))") }
    XCTAssertEqual(
      mixedRows,
      .observedConnectedSet([HDCObservedDeviceIdentifier(redactedKey: "redacted-device-aa")]),
      "presence follows the state column, not row existence")
    let failureForm = HDCDeviceObservationRawFamilyParser.parse(
      execution: observabilityObservationExecution(stdout: "", termination: .exited(1))
    ) { HDCObservedDeviceIdentifier(redactedKey: "redacted-device-\($0.prefix(2))") }
    guard case .unknown = failureForm else {
      return XCTFail("a nonzero exit is unknown, never empty: \(failureForm)")
    }
  }

  // F2: a capacity-N buffer receiving N+K events keeps exactly the latest N
  // in stable order with no drop-induced reordering or merging.
  func testOBS_F2_BoundedBufferKeepsLatestEventsInStableOrder() async throws {
    let capacity = 4
    let feed = HDCDeviceObservationFanOut(capacity: capacity)
    var emitted: [HDCDeviceObservationEvent] = []
    for index in 0..<5 {
      let device = HDCObservedDeviceIdentifier(
        redactedKey: "redacted-device-\(String(format: "%02d", index))")
      emitted += await feed.ingest(.observedConnectedSet([device]))
    }
    XCTAssertEqual(emitted.count, 9, "five singleton snapshots emit 5 appears and 4 disappears")
    let buffered = await feed.bufferedEvents()
    XCTAssertEqual(buffered.count, capacity)
    XCTAssertEqual(
      buffered, Array(emitted.suffix(capacity)),
      "the buffer holds exactly the latest N events in emission order")
  }

  // F3: the complete fan-out composition against the fixture issues only the
  // registered exact argv; the zero-to-many family existence is bound to the
  // registered family, and family absence fails this test rather than
  // skipping it.
  func testOBS_F3_FullFanOutCompositionIssuesOnlyRegisteredArgv() async throws {
    guard HDCDeviceObservationProbeCatalog.familyIsRegistered else {
      // Deliberate hard failure: an absent zero-to-many family must never be
      // interpreted as a skippable environment condition.
      return XCTFail("the registered zero-to-many device observation family is absent")
    }
    XCTAssertEqual(
      HDCDeviceObservationProbeCatalog.registryID, "OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES")
    XCTAssertEqual(HDCDeviceObservationProbeCatalog.registryVersion, "1.0.0")
    XCTAssertEqual(HDCDeviceObservationProbeCatalog.integrationProfile, "OPENHARMONY-TOOLS@0.5.0")
    XCTAssertEqual(HDCDeviceObservationProbeCatalog.family, "deviceObservationSnapshot")
    XCTAssertEqual(HDCDeviceObservationProbeCatalog.exactArguments, ["list", "targets", "-v"])
    XCTAssertEqual(HDCDeviceObservationProbeCatalog.exactEndpoint, "127.0.0.1:8710")
    XCTAssertEqual(HDCDeviceObservationProbeCatalog.targetToolVersion, "3.2.0f")
    XCTAssertEqual(
      HDCDeviceObservationProbeCatalog.targetExecutableSHA256,
      "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83")

    let root = try temporaryObservabilityRoot("obs-f3")
    defer { try? FileManager.default.removeItem(at: root) }
    let candidate = observabilityFixtureCandidate()
    let endpoint = HDCServerEndpoint(HDCDeviceObservationProbeCatalog.exactEndpoint)
    let selection = try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue)
    let invocationLog = root.appending(path: "f3.log")
    let rawConnectKey = String(repeating: "c", count: 32)
    let rows =
      "\(rawConnectKey)\t\tUSB\tConnected\tlocalhost\n"
      + "\(String(repeating: "d", count: 32))\t\tUSB\tOffline\tlocalhost\n"
    let receipt = observabilityIdentityReceipt(endpoint: endpoint, candidate: candidate)
    let source = HDCRegisteredDeviceObservationSource(
      runner: HDCProcessCommandRunner(
        semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate)),
      toolchain: candidate,
      endpointSelection: selection,
      identityObserver: ObservabilityFixedIdentityObserver(observation: .observed(receipt)),
      additionalChildEnvironment: [
        "ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path,
        "ARKDECK_FAKE_HDC_SELECTED_DEVICE_ROW": rows,
      ])
    let composition = try HDCDeviceObservationComposition.makeProduction(source: source)

    let events = await composition.pollOnce()

    XCTAssertEqual(events.count, 1)
    guard case .appeared(let device) = events.first else {
      return XCTFail("one Connected row must appear exactly once: \(events)")
    }
    XCTAssertTrue(device.redactedKey.hasPrefix("redacted-device-"))
    XCTAssertEqual(device.redactedKey.count, "redacted-device-".count + 24)
    XCTAssertFalse(
      device.redactedKey.contains(rawConnectKey),
      "raw connect keys never leave the observation adapter")
    let argvLines = try invocationLines(invocationLog)
    XCTAssertEqual(
      argvLines, ["list\u{1F}targets\u{1F}-v"],
      "the composition issues only the registered exact argv")
    let presence = await composition.feed.presence
    XCTAssertEqual(presence, .knownConnected([device]))
  }

  // F4: device observation recipients are separate from the lifecycle impact
  // scope: the impact snapshot sets equal exactly the lifecycle participants,
  // device consumers receive device events, and neither side receives the
  // other's events.
  func testOBS_F4_DeviceRecipientsAreSeparatedFromLifecycleImpact() async throws {
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let endpoint = HDCServerEndpoint("127.0.0.1:18756")
    let coordinator = HDCServerRecipient(
      id: "device-a", kind: .deviceCoordinator, endpoint: endpoint)
    let job = HDCServerRecipient(id: "job-hdc", kind: .job, endpoint: endpoint)
    await supervisor.register(coordinator)
    await supervisor.register(job)
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 7,
          ownership: .external)),
      reason: "fixture verified state")
    await supervisor.setImpactReliability(true, for: endpoint)
    await supervisor.setParticipantImpactReliability(true, for: endpoint)

    let feed = HDCDeviceObservationFanOut(capacity: 8)
    await feed.register(consumerID: "device-events-consumer")

    guard
      case .ready(let preview) = await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint)
    else {
      return XCTFail("the fixture must create an impact preview")
    }
    XCTAssertEqual(
      preview.snapshot.affectedDeviceCoordinators, ["device-a"],
      "the impact scope holds exactly the lifecycle participants, no device consumer")
    XCTAssertEqual(preview.snapshot.affectedJobs, ["job-hdc"])

    let device = HDCObservedDeviceIdentifier(redactedKey: "redacted-device-f4")
    await feed.ingest(.observedConnectedSet([device]))
    let deviceEvents = await feed.takeDeliveredEvents(for: "device-events-consumer")
    XCTAssertEqual(deviceEvents, [.appeared(device)])

    guard case .accepted(let confirmation) = await supervisor.confirm(preview.id) else {
      return XCTFail("the fixture must accept the confirmation")
    }
    let dispatch = await supervisor.dispatch(
      confirmationID: confirmation.id,
      using: ObservabilityFixedOutcomeExecutor(outcome: .succeeded(resultingGeneration: 8)))
    XCTAssertEqual(dispatch, .completed(.succeeded(resultingGeneration: 8)))
    let jobEvents = await supervisor.takeDeliveredEvents(for: job)
    XCTAssertTrue(
      jobEvents.contains { event in
        if case .lifecycleOutcome = event { return true }
        return false
      }, "lifecycle participants keep receiving lifecycle broadcasts")
    let deviceEventsAfterLifecycle = await feed.takeDeliveredEvents(
      for: "device-events-consumer")
    XCTAssertEqual(
      deviceEventsAfterLifecycle, [],
      "a lifecycle broadcast never reaches a device observation consumer")
  }

  // F5: a test-only snapshot source is rejected by the production composition
  // entry; only the integration-registered source marker is accepted.
  func testOBS_F5_TestOnlySnapshotSourceIsRejectedFromProductionComposition() async throws {
    XCTAssertThrowsError(
      try HDCDeviceObservationComposition.makeProduction(
        source: ObservabilityTestOnlySnapshotSource())
    ) { error in
      XCTAssertEqual(
        error as? HDCDeviceObservationCompositionError, .testOnlySnapshotSourceRejected)
    }

    let candidate = observabilityFixtureCandidate()
    let registeredSource = HDCRegisteredDeviceObservationSource(
      runner: HDCProcessCommandRunner(
        semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate)),
      toolchain: candidate,
      endpointSelection: try HDCServerEndpointSelector.select(
        explicitEndpoint: HDCDeviceObservationProbeCatalog.exactEndpoint),
      identityObserver: ObservabilityFixedIdentityObserver(
        observation: .unavailable(reason: "no server")))
    XCTAssertNoThrow(
      try HDCDeviceObservationComposition.makeProduction(source: registeredSource),
      "the integration-registered source is the only admissible production source")
  }

  // MARK: - Confirmed dispatch chain helpers

  private final class ConfirmedDispatchContext: @unchecked Sendable {
    let supervisor: HDCServerSupervisor
    let endpoint: HDCServerEndpoint
    let invocationLog: URL
    let candidate: HDCCandidate
    private let adapter: DurableHDCServerLifecycleAuditStore
    private let root: URL
    private var confirmation: HDCServerLifecycleConfirmation
    private let owner: HDCSupervisorObservabilityContractTests

    init(
      supervisor: HDCServerSupervisor,
      endpoint: HDCServerEndpoint,
      invocationLog: URL,
      candidate: HDCCandidate,
      adapter: DurableHDCServerLifecycleAuditStore,
      root: URL,
      confirmation: HDCServerLifecycleConfirmation,
      owner: HDCSupervisorObservabilityContractTests
    ) {
      self.supervisor = supervisor
      self.endpoint = endpoint
      self.invocationLog = invocationLog
      self.candidate = candidate
      self.adapter = adapter
      self.root = root
      self.confirmation = confirmation
      self.owner = owner
    }

    func dispatchOnce(
      fault: HDCDispatchInstrumentationFault,
      expectedGeneration: Int
    ) async -> HDCServerLifecycleDispatchResult {
      let runner = HDCProcessCommandRunner(
        semanticProfile: owner.observabilityFixtureSemanticProfile(candidate: candidate),
        dispatchMonitor: supervisor.dispatchMonitor,
        dispatchInstrumentationFault: fault)
      guard
        let selection = try? HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue)
      else {
        return .blocked(.invalidTypedStep)
      }
      let executor = HDCProcessLifecycleExecutor(
        runner: runner,
        toolchain: candidate,
        endpointSelection: selection,
        additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
        durableAuthorization: adapter,
        dispatchLeaseValidator: supervisor,
        postDispatchProbe: { _ in .generation(expectedGeneration) })
      return await supervisor.dispatch(confirmationID: confirmation.id, using: executor)
    }

    func reconfirm(expectedGeneration _: Int) async throws {
      guard
        case .ready(let preview) = await supervisor.createImpactPreview(
          action: .restartConfirmedGeneration, endpoint: endpoint),
        case .accepted(let nextConfirmation) = await supervisor.confirm(preview.id)
      else {
        throw ObservabilityContractError.confirmationUnavailable
      }
      confirmation = nextConfirmation
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
  }

  private enum ObservabilityContractError: Error {
    case confirmationUnavailable
    case managedClaimUnavailable
  }

  private func makeConfirmedDispatchContext(
    sessionID: String,
    jobID: String,
    port: Int
  ) async throws -> ConfirmedDispatchContext {
    let root = try temporaryObservabilitySessionRoot()
    let endpoint = HDCServerEndpoint("127.0.0.1:\(port)")
    let layout = try SessionLayout(sessionID: sessionID, jobID: jobID, root: root)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: try FileDurableSessionAuditStore(layout: layout),
      manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
      timestamp: { "2026-07-28T09:00:00Z" })
    let supervisor = HDCServerSupervisor(auditStore: adapter)
    try await establishConfirmedScope(supervisor: supervisor, endpoint: endpoint)
    guard
      case .ready(let preview) = await supervisor.createImpactPreview(
        action: .restartConfirmedGeneration, endpoint: endpoint),
      case .accepted(let confirmation) = await supervisor.confirm(preview.id)
    else {
      throw ObservabilityContractError.confirmationUnavailable
    }
    return ConfirmedDispatchContext(
      supervisor: supervisor,
      endpoint: endpoint,
      invocationLog: root.appending(path: "\(sessionID)-invocations.log"),
      candidate: observabilityFixtureCandidate(),
      adapter: adapter,
      root: root,
      confirmation: confirmation,
      owner: self)
  }

  private func establishConfirmedScope(
    supervisor: HDCServerSupervisor,
    endpoint: HDCServerEndpoint
  ) async throws {
    await supervisor.register(HDCServerRecipient(id: "job-obs", kind: .job, endpoint: endpoint))
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 7,
          ownership: .external)),
      reason: "fixture verified state")
    await supervisor.setImpactReliability(true, for: endpoint)
    await supervisor.setParticipantImpactReliability(true, for: endpoint)
  }

  // MARK: - Managed claim helpers

  private final class ManagedClaimContext: @unchecked Sendable {
    let supervisor: HDCServerSupervisor
    let candidate: HDCCandidate
    let endpoint: HDCServerEndpoint
    let evidence: HDCManagedServerLaunchEvidence
    let pid: pid_t
    let invocationLog: URL
    private let spawnTask: Task<Void, Never>

    init(
      supervisor: HDCServerSupervisor,
      candidate: HDCCandidate,
      endpoint: HDCServerEndpoint,
      evidence: HDCManagedServerLaunchEvidence,
      pid: pid_t,
      invocationLog: URL,
      spawnTask: Task<Void, Never>
    ) {
      self.supervisor = supervisor
      self.candidate = candidate
      self.endpoint = endpoint
      self.evidence = evidence
      self.pid = pid
      self.invocationLog = invocationLog
      self.spawnTask = spawnTask
    }

    func killServerAndReap() async {
      kill(pid, SIGKILL)
      _ = await spawnTask.value
    }

    func cleanUp() {
      kill(pid, SIGKILL)
    }
  }

  private func establishLiveManagedClaim(
    port: UInt16,
    root: URL
  ) async throws -> ManagedClaimContext {
    let endpoint = HDCServerEndpoint("127.0.0.1:\(port)")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let candidate = observabilityFixtureCandidate()
    let authorizationValue = await supervisor.authorizeManagedStart(at: endpoint)
    let authorization = try XCTUnwrap(authorizationValue)
    let invocationLog = root.appending(path: "managed-\(port).log")
    let runner = HDCProcessCommandRunner(
      semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
      dispatchMonitor: supervisor.dispatchMonitor)
    let arguments = ["managed-server", "-s", endpoint.rawValue]
    let command = HDCProcessCommand(
      toolchain: candidate,
      endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      arguments: arguments,
      additionalChildEnvironment: ["ARKDECK_FAKE_HDC_INVOCATION_LOG": invocationLog.path],
      timeout: 60)
    let permit = authorization.dispatchPermit
    let spawnTask = Task { _ = try? await runner.execute(command, dispatchPermit: permit) }
    let spawned = await waitUntil {
      supervisor.dispatchMonitor.spawnAuditTrail().contains { $0.arguments == arguments }
    }
    guard spawned,
      let record = supervisor.dispatchMonitor.spawnAuditTrail().last(
        where: { $0.arguments == arguments })
    else {
      throw ObservabilityContractError.managedClaimUnavailable
    }
    let listenerUp = await waitUntil { [port] in
      observabilityLoopbackConnectSucceeds(port: port)
    }
    guard listenerUp else {
      kill(record.processIdentifier, SIGKILL)
      throw ObservabilityContractError.managedClaimUnavailable
    }
    let evidence = HDCManagedServerLaunchEvidence(
      endpoint: endpoint,
      pid: record.processIdentifier,
      toolPath: candidate.path,
      arguments: arguments,
      generation: 4_242,
      version: .unknown(reason: "managed fixture"))
    let recorded = await supervisor.recordManagedStart(
      authorization: authorization, evidence: evidence)
    guard recorded else {
      kill(record.processIdentifier, SIGKILL)
      throw ObservabilityContractError.managedClaimUnavailable
    }
    return ManagedClaimContext(
      supervisor: supervisor,
      candidate: candidate,
      endpoint: endpoint,
      evidence: evidence,
      pid: record.processIdentifier,
      invocationLog: invocationLog,
      spawnTask: spawnTask)
  }

  // MARK: - HSO-002 commandless observation helpers

  private func hsoCandidate(_ label: String) -> HDCCandidate {
    HDCCandidate(
      path: URL(fileURLWithPath: "/private/tmp/arkdeck-\(label)-hdc"),
      source: .userConfigured,
      sha256: HDCSupervisorObservationProbeCatalog.targetExecutableSHA256)
  }

  private func hsoEndpointSelection() throws -> HDCServerEndpointSelection {
    try HDCServerEndpointSelector.select(inheritedEnvironment: [:])
  }

  private func hsoZeroDispatchCounters() -> HDCSupervisorDispatchMonitor.CountersSnapshot {
    HDCSupervisorDispatchMonitor.CountersSnapshot(
      automaticLifecycleDispatchCount: 0,
      automaticSubserverDispatchCount: 0,
      confirmedLifecycleDispatchCount: 0,
      managedStartDispatchCount: 0)
  }

  private func hsoIdentityReceipt(
    candidate: HDCCandidate,
    endpoint: HDCServerEndpoint,
    pid: Int32 = 32_001,
    startSeconds: UInt64 = 1_785_196_800,
    startMicroseconds: UInt64 = 654_321
  ) -> HDCServerProcessIdentityReceipt {
    HDCServerProcessIdentityReceipt(
      pid: pid,
      startSeconds: startSeconds,
      startMicroseconds: startMicroseconds,
      executablePath: candidate.path.resolvingSymlinksInPath().standardizedFileURL,
      executableSHA256: candidate.sha256,
      endpoint: endpoint)
  }

  private func seedHSOExternalClaim(
    supervisor: HDCServerSupervisor,
    endpoint: HDCServerEndpoint
  ) async {
    await supervisor.observeRegisteredServerIdentity(
      endpoint: endpoint,
      health: .healthy,
      version: .known("stale-must-be-revoked"),
      generation: 99,
      reason: "HSO stale-claim negative control")
  }

  // MARK: - Bracket observation helpers

  private func bracketObservation(
    supervisor: HDCServerSupervisor,
    candidate: HDCCandidate,
    endpoint: HDCServerEndpoint,
    receipt: HDCServerProcessIdentityReceipt
  ) async throws -> HDCRegisteredServerObservationResult {
    let processSupervisor = HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: [:],
      readOnlyProbeRegistry: observabilityFixtureRegistry(candidate: candidate),
      semanticProfile: observabilityFixtureSemanticProfile(candidate: candidate),
      identityObserver: ObservabilityFixedIdentityObserver(observation: .observed(receipt)))
    return await processSupervisor.observeRegisteredExistingServer(
      endpoint: try HDCServerEndpointSelector.select(explicitEndpoint: endpoint.rawValue),
      toolchain: candidate)
  }

  private func observabilityIdentityReceipt(
    endpoint: HDCServerEndpoint,
    candidate: HDCCandidate,
    startSeconds: UInt64 = 1_753_000_000,
    startMicroseconds: UInt64 = 654_321,
    pid: Int32 = 4_321
  ) -> HDCServerProcessIdentityReceipt {
    HDCServerProcessIdentityReceipt(
      pid: pid,
      startSeconds: startSeconds,
      startMicroseconds: startMicroseconds,
      executablePath: candidate.path.resolvingSymlinksInPath().standardizedFileURL,
      executableSHA256: candidate.sha256,
      endpoint: endpoint)
  }

  // MARK: - Gate equivalence helpers

  private struct GateEquivalenceArm {
    let supervisor: HDCServerSupervisor
    let endpoint: HDCServerEndpoint
    let jobRecipient: HDCServerRecipient
  }

  private func makeGateEquivalenceArm(
    ownership: HDCServerOwnership
  ) async throws -> GateEquivalenceArm {
    let endpoint = HDCServerEndpoint("127.0.0.1:18757")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let job = HDCServerRecipient(id: "job-eq", kind: .job, endpoint: endpoint)
    await supervisor.register(job)
    await supervisor.register(
      HDCServerRecipient(id: "device-eq", kind: .deviceCoordinator, endpoint: endpoint))
    await supervisor.observeExistingServer(
      HDCExistingServerObservation(
        state: HDCServerState(
          endpoint: endpoint, health: .healthy, version: .known("3.2.0d"), generation: 7,
          ownership: ownership)),
      reason: "gate equivalence arm")
    await supervisor.setOtherClientDetection(.detected(["DevEco IDE"]), for: endpoint)
    await supervisor.setImpactReliability(true, for: endpoint)
    await supervisor.setParticipantImpactReliability(true, for: endpoint)
    return GateEquivalenceArm(supervisor: supervisor, endpoint: endpoint, jobRecipient: job)
  }

  private func observabilityEquivalenceStep(
    confirmation: HDCServerLifecycleConfirmation
  ) -> HDCServerLifecycleStep {
    HDCServerLifecycleStep(
      id: UUID(),
      auditID: confirmation.auditID,
      action: confirmation.action,
      endpoint: confirmation.endpoint,
      expectedGeneration: confirmation.generation,
      expectedOwnership: HDCServerExpectedOwnership(rawValue: confirmation.ownership.rawValue)
        ?? .unknown,
      impactSnapshotHash: confirmation.scopeHash,
      confirmationID: confirmation.id)
  }

  // MARK: - Shared fixtures

  fileprivate func observabilityFixtureExecutable() -> URL {
    observabilityPackageRoot().appending(path: ".build/debug/ArkDeckFakeHDCFixture")
  }

  private func observabilityPackageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  fileprivate func observabilityFixtureCandidate() -> HDCCandidate {
    let url = observabilityFixtureExecutable()
    let bytes = (try? Data(contentsOf: url)) ?? Data()
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return HDCCandidate(path: url, source: .userConfigured, sha256: hash)
  }

  fileprivate func observabilityFixtureSemanticProfile(
    candidate: HDCCandidate
  ) -> HDCRegisteredSemanticProfile {
    let selectedDeviceRow = Data(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n".utf8)
    let rowHash = SHA256.hash(data: selectedDeviceRow)
      .map { String(format: "%02x", $0) }.joined()
    return HDCRegisteredSemanticProfile.testOnlyFake(
      executableSHA256: candidate.sha256,
      selectedDeviceAuthorizationSHA256: rowHash)
  }

  private func observabilityFixtureRegistry(
    candidate: HDCCandidate
  ) -> HDCReadOnlyProbeRegistry {
    let registeredFixtureRow = Data(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n".utf8)
    let rowHash = SHA256.hash(data: registeredFixtureRow)
      .map { String(format: "%02x", $0) }.joined()
    let entries = HDCReadOnlyProbeRegistry.pinnedProduction.entries.map { entry in
      guard entry.family == .selectedDeviceAuthorizationBinding else { return entry }
      return HDCReadOnlyProbeRegistry.Entry(
        id: entry.id, family: entry.family, status: entry.status,
        probeKind: entry.probeKind, exactArguments: entry.exactArguments,
        invocationAllowed: entry.invocationAllowed,
        timeoutMilliseconds: entry.timeoutMilliseconds, rawFamily: entry.rawFamily,
        rawSHA256: rowHash, receiptID: entry.receiptID,
        receiptSHA256: entry.receiptSHA256, unsupportedReason: entry.unsupportedReason)
    }
    return HDCReadOnlyProbeRegistry(entries: entries, targetExecutableSHA256: candidate.sha256)
  }

  private func observabilityToolchainSnapshot(
    candidate: HDCCandidate? = nil,
    endpoint: String,
    endpointSource: HDCServerEndpointSource? = nil
  ) -> HDCJobToolchainSnapshot {
    HDCJobToolchainSnapshot(
      candidate: candidate ?? observabilityFixtureCandidate(),
      endpoint: endpoint,
      endpointSource: endpointSource,
      details: HDCProbeDetails(
        platformTrust: .unknown(reason: "fixture"),
        clientVersion: .unknown(reason: "registered client family unavailable"),
        serverVersion: .unknown(reason: "commandless observation has not completed"),
        daemonVersion: .unknown(reason: "not registered"),
        serverGeneration: .unknown(reason: "commandless observation has not completed")))
  }

  private func observabilityObservationExecution(
    stdout: String,
    stderr: String = "",
    termination: ProcessTermination = .exited(0)
  ) -> ProcessExecutionResult {
    let stdoutData = Data(stdout.utf8)
    let stderrData = Data(stderr.utf8)
    return ProcessExecutionResult(
      termination: termination,
      stdout: ProcessStreamCapture(
        data: stdoutData, totalByteCount: Int64(stdoutData.count), wasTruncated: false),
      stderr: ProcessStreamCapture(
        data: stderrData, totalByteCount: Int64(stderrData.count), wasTruncated: false))
  }

  private func temporaryObservabilityRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func temporaryObservabilitySessionRoot() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-obs-\(UUID().uuidString)")
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

  private func invocationLines(_ invocationLog: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: invocationLog.path) else { return [] }
    return try String(contentsOf: invocationLog, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
  }

  private func matchCount(_ pattern: String, in text: String) -> Int {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return -1 }
    return expression.numberOfMatches(
      in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
  }

  private func waitUntil(
    timeout: TimeInterval = 8,
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
  }
}

private func observabilityLoopbackConnectSucceeds(port: UInt16) -> Bool {
  let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard socketDescriptor >= 0 else { return false }
  defer { close(socketDescriptor) }
  var address = sockaddr_in(
    sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
    sin_family: sa_family_t(AF_INET),
    sin_port: port.bigEndian,
    sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
    sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
      Darwin.connect(
        socketDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  return result == 0
}

private actor ObservabilityFixedIdentityObserver: HDCServerProcessIdentityObserving {
  private let observation: HDCServerProcessIdentityRawObservation

  init(observation: HDCServerProcessIdentityRawObservation) {
    self.observation = observation
  }

  func observe(
    endpoint _: HDCServerEndpoint,
    selectedToolchain _: HDCCandidate
  ) async -> HDCServerProcessIdentityRawObservation {
    observation
  }
}

private actor HSORecordingIdentityObserver: HDCServerProcessIdentityObserving {
  struct Input: Sendable, Equatable {
    let endpoint: HDCServerEndpoint
    let toolchain: HDCCandidate
  }

  private let observation: HDCServerProcessIdentityRawObservation
  private var recordedInputs: [Input] = []

  init(observation: HDCServerProcessIdentityRawObservation) {
    self.observation = observation
  }

  func observe(
    endpoint: HDCServerEndpoint,
    selectedToolchain: HDCCandidate
  ) async -> HDCServerProcessIdentityRawObservation {
    recordedInputs.append(
      Input(endpoint: endpoint, toolchain: selectedToolchain))
    return observation
  }

  var inputs: [Input] { recordedInputs }
}

private final class HSOObservationEffectSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var storedObserveCount = 0
  private var storedCancelledCount = 0

  func recordObservation() {
    lock.withLock { storedObserveCount += 1 }
  }

  func recordCancellation() {
    lock.withLock { storedCancelledCount += 1 }
  }

  var observeCount: Int { lock.withLock { storedObserveCount } }
  var cancelledCount: Int { lock.withLock { storedCancelledCount } }
}

private struct HSOCancellableIdentityObserver: HDCServerProcessIdentityObserving {
  let spy: HSOObservationEffectSpy

  func observe(
    endpoint _: HDCServerEndpoint,
    selectedToolchain _: HDCCandidate
  ) async -> HDCServerProcessIdentityRawObservation {
    spy.recordObservation()
    do {
      try await Task.sleep(for: .seconds(60))
      return .unknown(reason: "cancellable observer unexpectedly completed")
    } catch {
      spy.recordCancellation()
      return .cancelled
    }
  }
}

private actor ObservabilityBlockingFinalLaunchHook {
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

private final class ObservabilityLockedLaunchCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  func recordLaunch() {
    lock.withLock { storedCount += 1 }
  }

  var count: Int { lock.withLock { storedCount } }
}

private struct ObservabilityFixedOutcomeExecutor: HDCServerLifecycleExecutor {
  let outcome: HDCServerLifecycleExecutionOutcome

  func execute(
    _: HDCServerLifecycleStep,
    lease _: HDCServerLifecycleDispatchLease
  ) async -> HDCServerLifecycleExecutorResult {
    HDCServerLifecycleExecutorResult(outcome: outcome)
  }
}

private struct ObservabilityTestOnlySnapshotSource: HDCDeviceObservationSnapshotProviding {
  let authority = HDCDeviceObservationSourceAuthority.testOnlyFake

  func observe() async -> HDCDeviceObservationSnapshot {
    .observedConnectedSet([HDCObservedDeviceIdentifier(redactedKey: "redacted-device-test")])
  }
}
