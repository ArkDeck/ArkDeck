import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class DeviceBootstrapContractTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-bootstrap-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// Scripted observation port: the only surface bootstrap can reach.
  private final class ScriptedObservation: BootstrapObservationPort, @unchecked Sendable {
    var toolVersion = "3.2.0f"
    var candidates: [BootstrapCandidate]
    var identity: [String: String] = ["serial": "150100424A544E4600"]
    private(set) var identityCalls = 0

    init(candidates: [BootstrapCandidate]) {
      self.candidates = candidates
    }

    func observeToolVersion() async throws -> String { toolVersion }
    func listCandidates() async throws -> [BootstrapCandidate] { candidates }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      identityCalls += 1
      return identity
    }
  }

  private actor SlowCountingObservation: BootstrapObservationPort {
    private(set) var candidateReadCount = 0
    let candidates: [BootstrapCandidate]

    init(candidates: [BootstrapCandidate]) {
      self.candidates = candidates
    }

    func observeToolVersion() async throws -> String { "3.2.0f" }

    func listCandidates() async throws -> [BootstrapCandidate] {
      candidateReadCount += 1
      try await Task.sleep(for: .milliseconds(50))
      return candidates
    }

    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private actor WarmThenSlowObservation: BootstrapObservationPort {
    private(set) var candidateReadCount = 0
    let first: [BootstrapCandidate]
    let second: [BootstrapCandidate]

    init(first: [BootstrapCandidate], second: [BootstrapCandidate]) {
      self.first = first
      self.second = second
    }

    func observeToolVersion() async throws -> String { "3.2.0f" }

    func listCandidates() async throws -> [BootstrapCandidate] {
      candidateReadCount += 1
      if candidateReadCount == 1 { return first }
      try await Task.sleep(for: .milliseconds(250))
      return second
    }

    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private actor SucceedThenFailObservation: BootstrapObservationPort {
    private(set) var candidateReadCount = 0
    let candidate: BootstrapCandidate

    init(candidate: BootstrapCandidate) {
      self.candidate = candidate
    }

    func observeToolVersion() async throws -> String { "3.2.0f" }

    func listCandidates() async throws -> [BootstrapCandidate] {
      candidateReadCount += 1
      if candidateReadCount == 1 { return [candidate] }
      throw BootstrapError.observationFailed("scripted refresh failure")
    }

    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private func makeMachine(
    _ observation: ScriptedObservation
  ) throws -> (DeviceBootstrapMachine, RuntimeTargetStore) {
    let store = try RuntimeTargetStore(directoryURL: directory)
    let machine = DeviceBootstrapMachine(
      observation: observation, targetStore: store, nowUTC: { "2026-07-29T00:00:00Z" })
    return (machine, store)
  }

  func testSingleAuthorizedCandidateAdoptsFromCleanEnvironment() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "150100424A544E4600", state: "Connected")
    ])
    let (machine, store) = try makeMachine(observation)
    XCTAssertEqual(try store.list(), [], "clean environment: zero prior bindings")
    guard case .adopted(let record) = await machine.advance() else {
      return XCTFail("single connected candidate must adopt")
    }
    XCTAssertTrue(record.targetID.hasPrefix("TGT-"))
    XCTAssertEqual(record.bindingRevision, 1)
    XCTAssertEqual(record.toolVersion, "3.2.0f")
    XCTAssertEqual(
      record.stablePhysicalIdentitySHA256,
      DeviceBootstrapMachine.stableIdentitySHA256(serial: "150100424A544E4600"))
    let phase = await machine.phase
    XCTAssertEqual(phase, .handedOff)
    XCTAssertEqual(try store.list().count, 1)
    XCTAssertEqual(
      try store.hdcExecutionRoute(targetID: record.targetID),
      RuntimeTargetHDCRoute(
        targetID: record.targetID, bindingRevision: record.bindingRevision,
        toolVersion: record.toolVersion, connectKey: record.connectKey))
  }

  func testConcurrentCandidateReadsShareOneProviderProbe() async throws {
    let candidate = BootstrapCandidate(connectKey: "candidate-a", state: "Connected")
    let observation = SlowCountingObservation(candidates: [candidate])
    let store = try RuntimeTargetStore(directoryURL: directory)
    let machine = DeviceBootstrapMachine(
      observation: observation, targetStore: store, nowUTC: { "2026-08-12T00:00:00Z" })

    async let first = machine.enumerateCandidates()
    async let second = machine.enumerateCandidates()
    let results = try await (first, second)

    XCTAssertEqual(results.0, [candidate])
    XCTAssertEqual(results.1, [candidate])
    let candidateReadCount = await observation.candidateReadCount
    XCTAssertEqual(
      candidateReadCount, 1,
      "App diagnostics and sidebar startup reads must not launch duplicate HDC probes")
    XCTAssertTrue(try store.list().isEmpty, "coalesced discovery remains read-only")
  }

  func testPresentationReadsWarmSnapshotWithoutWaitingForSlowHDCRefresh() async throws {
    let first = BootstrapCandidate(connectKey: "candidate-a", state: "Connected")
    let second = BootstrapCandidate(connectKey: "candidate-a", state: "Offline")
    let observation = WarmThenSlowObservation(first: [first], second: [second])
    let store = try RuntimeTargetStore(directoryURL: directory)
    let machine = DeviceBootstrapMachine(
      observation: observation, targetStore: store, nowUTC: { "2026-08-13T00:00:00Z" })

    let initial = try await machine.candidateSnapshotForPresentation()
    XCTAssertEqual(initial.candidates, [first])

    let clock = ContinuousClock()
    let startedAt = clock.now
    let warm = try await machine.candidateSnapshotForPresentation()
    XCTAssertLessThan(
      startedAt.duration(to: clock.now), .milliseconds(50),
      "a warm App launch must not join the next HDC command")
    XCTAssertEqual(warm.candidates, [first])

    // Await the coalesced refresh itself instead of assuming a fixed wall
    // clock delay is enough on every CI runner. The assertion above owns the
    // warm-path latency contract; this call deterministically observes the
    // eventual refresh result without launching a duplicate provider probe.
    let refreshed = try await machine.refreshCandidateSnapshotForPresentation()
    XCTAssertEqual(refreshed.candidates, [second])
    let published = try await machine.candidateSnapshotForPresentation()
    XCTAssertEqual(published.candidates, [second])
    let refreshedReadCount = await observation.candidateReadCount
    XCTAssertGreaterThanOrEqual(refreshedReadCount, 2)
    XCTAssertTrue(try store.list().isEmpty, "background observation remains read-only")
  }

  func testFailedFollowUpMarksCachedCandidateStateStale() async throws {
    let candidate = BootstrapCandidate(connectKey: "candidate-a", state: "Connected")
    let observation = SucceedThenFailObservation(candidate: candidate)
    let store = try RuntimeTargetStore(directoryURL: directory)
    let machine = DeviceBootstrapMachine(
      observation: observation, targetStore: store, nowUTC: { "2026-08-13T00:00:00Z" })

    let initial = try await machine.candidateSnapshotForPresentation()
    XCTAssertEqual(initial.health, .current)
    _ = try await machine.candidateSnapshotForPresentation()
    try await Task.sleep(for: .milliseconds(20))

    let stale = try await machine.candidateSnapshotForPresentation()
    XCTAssertEqual(stale.candidates, [candidate])
    XCTAssertEqual(stale.health, .stale)
    let failedReadCount = await observation.candidateReadCount
    XCTAssertGreaterThanOrEqual(failedReadCount, 2)
    XCTAssertTrue(try store.list().isEmpty)
  }

  func testMultipleCandidatesRequireExplicitSelection() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Connected"),
      BootstrapCandidate(connectKey: "BBB", state: "Connected"),
    ])
    let (machine, store) = try makeMachine(observation)
    guard case .needsSelection(let candidates) = await machine.advance() else {
      return XCTFail("two candidates must require selection")
    }
    XCTAssertEqual(candidates.map(\.connectKey), ["AAA", "BBB"])
    XCTAssertEqual(try store.list(), [], "no target is created before selection")
    XCTAssertEqual(observation.identityCalls, 0, "no device is observed before selection")

    guard case .adopted(let record) = await machine.advance(selectedConnectKey: "BBB") else {
      return XCTFail("explicit selection must adopt")
    }
    XCTAssertEqual(record.connectKey, "BBB")
  }

  func testUnauthorizedDeviceParksForPhysicalTrustThenResumes() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Unauthorized")
    ])
    let (machine, store) = try makeMachine(observation)
    guard case .waitingForHuman(let kind, let prompt) = await machine.advance() else {
      return XCTFail("unauthorized device must park for physical trust")
    }
    XCTAssertEqual(kind, .trustDevice)
    XCTAssertTrue(prompt.contains("trust"), "prompt must name the physical action")
    let parkedPhase = await machine.phase
    XCTAssertEqual(parkedPhase, .waitForPhysicalTrust)
    XCTAssertEqual(try store.list(), [], "no binding is created without trust")

    // The user trusts the device: the same call resumes automatically.
    observation.candidates = [BootstrapCandidate(connectKey: "AAA", state: "Connected")]
    guard case .adopted = await machine.advance() else {
      return XCTFail("bootstrap must resume after trust")
    }
  }

  func testOfflineDeviceAlsoParks() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Offline")
    ])
    let (machine, _) = try makeMachine(observation)
    guard case .waitingForHuman(let kind, let prompt) = await machine.advance() else {
      return XCTFail("offline device must park, never adopt")
    }
    XCTAssertEqual(kind, .physicalReconnect)
    XCTAssertTrue(prompt.contains("Reconnect"), prompt)
    XCTAssertFalse(prompt.contains("trust"), prompt)
  }

  func testReAdoptIsIdempotent() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "150100424A544E4600", state: "Connected")
    ])
    let (machine, store) = try makeMachine(observation)
    guard case .adopted(let first) = await machine.advance(),
      case .adopted(let second) = await machine.advance()
    else {
      return XCTFail("both adoptions must succeed")
    }
    XCTAssertEqual(first.targetID, second.targetID)
    XCTAssertEqual(first.adoptedAtUTC, second.adoptedAtUTC, "the original record is preserved")
    XCTAssertEqual(try store.list().count, 1, "no duplicate target is created")
  }

  func testNoCandidatesAndMissingSerialFailClosed() async throws {
    let empty = ScriptedObservation(candidates: [])
    let (emptyMachine, _) = try makeMachine(empty)
    guard case .failed(let reason) = await emptyMachine.advance() else {
      return XCTFail("zero candidates must fail closed")
    }
    XCTAssertTrue(reason.contains("no device candidates"))

    let serialless = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Connected")
    ])
    serialless.identity = [:]
    let (serialessMachine, store) = try makeMachine(serialless)
    guard case .failed(let serialReason) = await serialessMachine.advance() else {
      return XCTFail("a device with no stable serial must fail closed")
    }
    XCTAssertTrue(serialReason.contains("stable serial"))
    XCTAssertEqual(try store.list(), [], "no binding without stable identity")
  }

  func testTargetStoreSurvivesReopen() async throws {
    let observation = ScriptedObservation(candidates: [
      BootstrapCandidate(connectKey: "150100424A544E4600", state: "Connected")
    ])
    let (machine, _) = try makeMachine(observation)
    guard case .adopted(let record) = await machine.advance() else {
      return XCTFail("adoption must succeed")
    }
    let reopened = try RuntimeTargetStore(directoryURL: directory)
    XCTAssertEqual(try reopened.find(targetID: record.targetID), record)
    XCTAssertEqual(try reopened.list().count, 1)
  }

  /// Re-observing a flashed device through another provider face must not
  /// adopt it twice.
  ///
  /// Found on 2026-08-05, after the 08-04 reflash. A lineage advance keeps the
  /// durable target ID and the connect key while replacing the identity with
  /// the Loader-derived one. The next daemon start observed the same device
  /// through HDC, derived the *normal-mode* identity, found no record carrying
  /// it, and appended a second record — whose derived ID is a prefix of that
  /// identity and therefore collided with the first. Bootstrap then refused
  /// both with `ambiguous completed target binding lineage`, and the daemon
  /// would not start at all until the store was edited by hand.
  ///
  /// So this is not a tidiness test: without it a flash eventually bricks the
  /// host it was run from.
  func testReobservingAFlashedDeviceThroughAnotherFaceDoesNotAdoptItTwice() throws {
    // The normal-mode identity is what the durable ID is derived from, and the
    // Loader-mode identity is what the advance writes.
    let normalModeIdentity = String(repeating: "a", count: 64)
    let loaderModeIdentity = String(repeating: "b", count: 64)
    let connectKey = "150100424a544434520325874bbf4900"
    let store = try RuntimeTargetStore(directoryURL: directory)
    let adopted = try store.adopt(
      stableIdentitySHA256: normalModeIdentity, connectKey: connectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-07-29T00:00:00Z"
    ).record
    let flashed = try store.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: normalModeIdentity, previousRevision: 1,
        currentStableIdentitySHA256: loaderModeIdentity, currentRevision: 2)
    ).record
    XCTAssertEqual(flashed.targetID, adopted.targetID)
    XCTAssertEqual(flashed.stablePhysicalIdentitySHA256, loaderModeIdentity)

    // The HDC face derives the normal-mode identity again on the next start.
    let readopted = try store.adopt(
      stableIdentitySHA256: normalModeIdentity, connectKey: connectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-05T14:54:49Z")
    XCTAssertFalse(readopted.created, "a flashed device must not be adopted a second time")
    XCTAssertEqual(readopted.record, flashed)
    XCTAssertEqual(try store.list().count, 1)

    // And the store still opens, which is the failure this prevents.
    let reopened = try RuntimeTargetStore(directoryURL: directory)
    XCTAssertEqual(try reopened.list().count, 1)
    XCTAssertEqual(try reopened.find(targetID: adopted.targetID), flashed)
  }

  /// The same durable ID at a different address is a real ambiguity, and is
  /// refused rather than resolved by guessing which device was meant.
  func testTheSameDurableIDAtAnotherConnectKeyIsRefused() throws {
    let identity = String(repeating: "a", count: 64)
    let store = try RuntimeTargetStore(directoryURL: directory)
    _ = try store.adopt(
      stableIdentitySHA256: identity, connectKey: "address-one",
      toolVersion: "3.2.0f", nowUTC: "2026-07-29T00:00:00Z")
    _ = try store.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: identity, previousRevision: 1,
        currentStableIdentitySHA256: String(repeating: "b", count: 64), currentRevision: 2))
    XCTAssertThrowsError(
      try store.adopt(
        stableIdentitySHA256: identity, connectKey: "address-two",
        toolVersion: "3.2.0f", nowUTC: "2026-08-05T00:00:00Z"))
    XCTAssertEqual(try store.list().count, 1)
  }

  func testTargetStoreAdvancesOneExactBindingLineageEdgeIdempotently() throws {
    let previousIdentity = String(repeating: "a", count: 64)
    let currentIdentity = String(repeating: "b", count: 64)
    let store = try RuntimeTargetStore(directoryURL: directory)
    let adopted = try store.adopt(
      stableIdentitySHA256: previousIdentity,
      connectKey: "normal-mode-connect-key",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:00:00Z"
    ).record
    let advance = RuntimeTargetBindingLineageAdvance(
      previousStableIdentitySHA256: previousIdentity,
      previousRevision: 1,
      currentStableIdentitySHA256: currentIdentity,
      currentRevision: 2)

    let first = try store.advanceBindingLineage(advance)
    XCTAssertTrue(first.updated)
    XCTAssertEqual(first.record.targetID, adopted.targetID)
    XCTAssertEqual(first.record.connectKey, adopted.connectKey)
    XCTAssertEqual(first.record.adoptedAtUTC, adopted.adoptedAtUTC)
    XCTAssertEqual(first.record.stablePhysicalIdentitySHA256, currentIdentity)
    XCTAssertEqual(first.record.bindingRevision, 2)

    let second = try store.advanceBindingLineage(advance)
    XCTAssertFalse(second.updated)
    XCTAssertEqual(second.record, first.record)
    let reopened = try RuntimeTargetStore(directoryURL: directory)
    XCTAssertEqual(try reopened.find(targetID: adopted.targetID), first.record)
    XCTAssertEqual(try reopened.list().count, 1)
  }

  func testTargetStoreRejectsUnprovenSkippedAndCollidingLineage() throws {
    let previousIdentity = String(repeating: "a", count: 64)
    let currentIdentity = String(repeating: "b", count: 64)
    let store = try RuntimeTargetStore(directoryURL: directory)
    let adopted = try store.adopt(
      stableIdentitySHA256: previousIdentity,
      connectKey: "normal-mode-connect-key",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:00:00Z"
    ).record

    XCTAssertThrowsError(
      try store.advanceBindingLineage(
        RuntimeTargetBindingLineageAdvance(
          previousStableIdentitySHA256: previousIdentity,
          previousRevision: 1,
          currentStableIdentitySHA256: currentIdentity,
          currentRevision: 3)))
    XCTAssertThrowsError(
      try store.advanceBindingLineage(
        RuntimeTargetBindingLineageAdvance(
          previousStableIdentitySHA256: String(repeating: "c", count: 64),
          previousRevision: 1,
          currentStableIdentitySHA256: currentIdentity,
          currentRevision: 2)))
    _ = try store.adopt(
      stableIdentitySHA256: currentIdentity,
      connectKey: "different-connect-key",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:01:00Z")
    XCTAssertThrowsError(
      try store.advanceBindingLineage(
        RuntimeTargetBindingLineageAdvance(
          previousStableIdentitySHA256: previousIdentity,
          previousRevision: 1,
          currentStableIdentitySHA256: currentIdentity,
          currentRevision: 2)))
    XCTAssertEqual(try store.find(targetID: adopted.targetID), adopted)
  }

  func testProvenAliasResolutionPreservesHistoryAndSelectsOnlyCanonicalTarget() throws {
    let store = try RuntimeTargetStore(directoryURL: directory)
    let originalIdentity = String(repeating: "a", count: 64)
    let loaderIdentity = String(repeating: "b", count: 64)
    let aliasConnectKey = "post-flash-hdc-address"
    let aliasIdentity = DeviceBootstrapMachine.stableIdentitySHA256(
      serial: aliasConnectKey)
    let adopted = try store.adopt(
      stableIdentitySHA256: originalIdentity, connectKey: "original-hdc-address",
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let canonical = try store.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: originalIdentity, previousRevision: 1,
        currentStableIdentitySHA256: loaderIdentity, currentRevision: 2)
    ).record
    let alias = try store.adopt(
      stableIdentitySHA256: aliasIdentity, connectKey: aliasConnectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:01:00Z"
    ).record
    XCTAssertNotEqual(alias.targetID, adopted.targetID)

    let draft = RuntimeTargetAliasResolutionDraft(
      aliasTargetID: alias.targetID,
      aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
      aliasBindingRevision: alias.bindingRevision,
      canonicalTargetID: canonical.targetID,
      canonicalStableIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
      canonicalBindingRevision: canonical.bindingRevision,
      routedHDCIdentitySHA256: aliasIdentity,
      routedUSBTopology: "18874368",
      establishingFlashJobID: "job-0123456789abcdef0123456789abcdef",
      establishingFlashPlanDigestSHA256: String(repeating: "c", count: 64),
      confirmedStepIDs: [
        "enter-loader-mode", "flash-partitions", "verify-flash-readback",
        "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
      ],
      coveredUnknownIntents: [
        RuntimeTargetAliasCoveredIntent(
          jobID: "job-unknown", intentEventID: "intent-enter-loader",
          stepID: "enter-loader-mode", effect: "deviceMutation")
      ],
      establishedAtUTC: "2026-08-08T00:10:00Z")
    let resolution = try store.appendAliasResolution(draft)
    XCTAssertEqual(try store.appendAliasResolution(draft), resolution)
    XCTAssertEqual(try store.list().count, 2, "historical target identities remain immutable")
    XCTAssertEqual(try store.listActive(), [canonical])
    XCTAssertEqual(try store.candidateTarget(connectKey: aliasConnectKey), canonical)
    XCTAssertEqual(
      try store.hdcExecutionRoute(targetID: canonical.targetID),
      RuntimeTargetHDCRoute(
        targetID: canonical.targetID, bindingRevision: canonical.bindingRevision,
        toolVersion: canonical.toolVersion, connectKey: aliasConnectKey),
      "the HDC provider must use only the proven alias route while preserving canonical identity")
    XCTAssertEqual(
      try store.adopt(
        stableIdentitySHA256: aliasIdentity, connectKey: aliasConnectKey,
        toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:20:00Z"
      ).record,
      canonical)
    XCTAssertFalse(
      try store.hasConflictingHDCAliasOwner(
        canonicalTargetID: canonical.targetID, connectKey: aliasConnectKey,
        identitySHA256: aliasIdentity,
        establishingFlashJobID: draft.establishingFlashJobID))
    XCTAssertFalse(
      try store.hasConflictingHDCAliasOwner(
        canonicalTargetID: canonical.targetID, connectKey: aliasConnectKey,
        identitySHA256: aliasIdentity,
        establishingFlashJobID: "job-fedcba9876543210fedcba9876543210"),
      "the exact durable identity relation survives a later successful Flash Job")
    XCTAssertThrowsError(
      try store.hasConflictingHDCAliasOwner(
        canonicalTargetID: canonical.targetID, connectKey: "another-address",
        identitySHA256: aliasIdentity,
        establishingFlashJobID: draft.establishingFlashJobID))

    let reopened = try RuntimeTargetStore(directoryURL: directory)
    XCTAssertEqual(try reopened.listActive(), [canonical])
    XCTAssertEqual(try reopened.aliasResolutions(), [resolution])
  }

  func testTargetAliasResolutionHashTamperFailsClosed() throws {
    let store = try RuntimeTargetStore(directoryURL: directory)
    let canonical = try store.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "canonical", toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let aliasKey = "alias"
    let aliasIdentity = DeviceBootstrapMachine.stableIdentitySHA256(serial: aliasKey)
    let alias = try store.adopt(
      stableIdentitySHA256: aliasIdentity, connectKey: aliasKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:01:00Z"
    ).record
    _ = try store.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: alias.targetID,
        aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
        aliasBindingRevision: alias.bindingRevision,
        canonicalTargetID: canonical.targetID,
        canonicalStableIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: canonical.bindingRevision,
        routedHDCIdentitySHA256: aliasIdentity, routedUSBTopology: "42",
        establishingFlashJobID: "job-0123456789abcdef0123456789abcdef",
        establishingFlashPlanDigestSHA256: String(repeating: "c", count: 64),
        confirmedStepIDs: [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback",
          "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
        ],
        coveredUnknownIntents: [], establishedAtUTC: "2026-08-08T00:10:00Z"))

    let url = directory.appending(path: "targets.json")
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var resolutions = try XCTUnwrap(document["aliasResolutions"] as? [[String: Any]])
    resolutions[0]["resolutionSHA256"] = String(repeating: "f", count: 64)
    document["aliasResolutions"] = resolutions
    try JSONSerialization.data(withJSONObject: document).write(to: url)

    XCTAssertThrowsError(try RuntimeTargetStore(directoryURL: directory).listActive())
  }

  func testLegacyTargetRecordRemainsReadableWithoutCachedEvidenceFields() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = Data(
      """
      {
        "schemaVersion": "1.0.0",
        "targets": [{
          "targetID": "TGT-LEGACY",
          "stablePhysicalIdentitySHA256": "\(String(repeating: "a", count: 64))",
          "bindingRevision": 1,
          "connectKey": "legacy-address",
          "toolVersion": "3.2.0f",
          "adoptedAtUTC": "2026-07-01T00:00:00Z"
        }]
      }
      """.utf8)
    try legacy.write(to: directory.appending(path: "targets.json"))
    let store = try RuntimeTargetStore(directoryURL: directory)
    let record = try XCTUnwrap(store.find(targetID: "TGT-LEGACY"))
    XCTAssertEqual(record.bindingRevision, 1)
    XCTAssertEqual(record.connectKey, "legacy-address")
    XCTAssertEqual(
      Set(Mirror(reflecting: record).children.compactMap(\.label)),
      Set([
        "targetID", "stablePhysicalIdentitySHA256", "bindingRevision", "connectKey",
        "toolVersion", "adoptedAtUTC",
      ]),
      "the target store must not cache or synthesize same-operation evidence facts")
  }

  func testBootstrapActionVocabularyIsObservationOnly() {
    // Structural E0: every case of the bootstrap action enum maps to a
    // provider action whose effect is at most readOnly. A future mutation
    // case would break this test at compile time (new case) or at runtime.
    let actions: [BootstrapObservationAction] = [
      .observeTool, .observeServer, .listCandidates, .observeDevice(connectKey: "AAA"),
    ]
    for action in actions {
      XCTAssertLessThanOrEqual(
        action.providerAction.effect, .readOnly,
        "bootstrap action \(action) must never exceed readOnly")
    }
  }
}
