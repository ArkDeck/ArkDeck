import Foundation
import Testing

@testable import ArkDeckCore

struct DeviceTargetingContractTests {
  // TEST-AC-DEV-001-01 / bindingStateContract
  @Test func TEST_AC_DEV_001_01_OriginalTargetAndRevisionOneRoundTripWithoutSelectionMutation()
    throws
  {
    let original = try originalTarget(connectKey: "synthetic-usb-A")
    let revisionOne = try binding(
      revision: 1, connectKey: "synthetic-usb-A", serial: "SERIAL-A")
    let history = try DeviceBindingHistory(
      targetID: "device-A", originalTarget: original, initialBinding: revisionOne)

    let encoded = try JSONEncoder().encode(history)
    let reopened = try JSONDecoder().decode(DeviceBindingHistory.self, from: encoded)
    let laterUISelection = try originalTarget(connectKey: "synthetic-usb-B")

    #expect(reopened == history)
    #expect(reopened.originalTarget.connectKey == "synthetic-usb-A")
    #expect(reopened.current == revisionOne)
    #expect(laterUISelection != reopened.originalTarget)
    #expect(throws: (any Error).self) {
      try DeviceBindingHistory(
        targetID: "device-A",
        originalTarget: original,
        initialBinding: binding(
          revision: 2, connectKey: "synthetic-usb-A", serial: "SERIAL-A"))
    }
    #expect(throws: DeviceTargetingValidationError.emptyIdentitySnapshot) {
      try DeviceIdentitySnapshot(attributes: [:])
    }
    #expect(throws: DeviceTargetingValidationError.invalidTargetShape) {
      try OriginalTargetSnapshot(
        kind: .real,
        connectKey: nil,
        transport: .usb,
        identitySnapshot: identity(serial: "SERIAL-A"))
    }
    #expect(throws: DeviceTargetingValidationError.invalidBindingShape) {
      try CurrentDeviceBinding(
        revision: 1,
        connectKey: "synthetic-usb-A",
        transport: .usb,
        identitySnapshot: identity(serial: "SERIAL-A"),
        evidence: [],
        confirmedBy: .user,
        channelProtection: .unverifiedAssumeUnprotected)
    }
  }

  // TEST-AC-DEV-003-01 / rebindPolicyContract
  @Test func TEST_AC_DEV_003_01_USBAutoRebindRequiresTheCompleteCoreThreshold() throws {
    let complete = try candidate(
      id: "complete", key: "synthetic-usb-updater", serial: true, fingerprint: true,
      topology: true, mode: true)
    #expect(
      DeviceRebindPolicy.evaluate(
        transport: .usb,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: true,
        candidates: [complete])
        == .autoRebindEligible(complete))

    let booleanValues = [false, true]
    var evaluated = 0
    var eligible = 0
    for serial in booleanValues {
      for fingerprint in booleanValues {
        for topology in booleanValues {
          for mode in booleanValues {
            evaluated += 1
            let value = try candidate(
              id: "candidate-\(evaluated)", key: "synthetic-key-\(evaluated)",
              serial: serial, fingerprint: fingerprint, topology: topology, mode: mode)
            let decision = DeviceRebindPolicy.evaluate(
              transport: .usb,
              disconnected: true,
              endpointExplicitlyAdded: true,
              expectedModeTransition: true,
              candidates: [value])
            if case .autoRebindEligible = decision { eligible += 1 }
          }
        }
      }
    }
    #expect(evaluated == 16)
    #expect(eligible == 1)
    assertAwaiting(
      DeviceRebindPolicy.evaluate(
        transport: .usb,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: false,
        candidates: [complete]),
      reason: .coreEvidenceInsufficient)
    print("TASK-M1-007 usb_truth_table=\(evaluated) auto_rebind_eligible=\(eligible)")
  }

  // TEST-AC-DEV-003-02 / rebindPolicyContract
  @Test func TEST_AC_DEV_003_02_ProfileCannotRelaxMissingOrAmbiguousUSBEvidence() throws {
    let modelOnly = try candidate(
      id: "model-only", key: "synthetic-model-only", serial: false, fingerprint: false,
      topology: false, mode: true)
    let second = try candidate(
      id: "second", key: "synthetic-second", serial: true, fingerprint: true,
      topology: true, mode: true)
    let permissiveProfile = DeviceRebindProfilePolicy(
      requiresManualConfirmation: false, additionalEvidenceSatisfied: true)

    assertAwaiting(
      DeviceRebindPolicy.evaluate(
        transport: .usb,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: true,
        candidates: [modelOnly],
        profile: permissiveProfile),
      reason: .coreEvidenceInsufficient)
    assertAwaiting(
      DeviceRebindPolicy.evaluate(
        transport: .usb,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: true,
        candidates: [second, modelOnly],
        profile: permissiveProfile),
      reason: .ambiguousCandidates)
    assertAwaiting(
      DeviceRebindPolicy.evaluate(
        transport: .usb,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: true,
        candidates: [second],
        profile: DeviceRebindProfilePolicy(requiresManualConfirmation: true)),
      reason: .profileRequiresConfirmation)
    #expect(
      DeviceEffectGate.evaluate(
        effect: .deviceMutation,
        intendedBinding: nil,
        durableBinding: nil,
        identity: .unconfirmed)
        == .rejected(.identityUnconfirmed))
  }

  // TEST-AC-DEV-004-01 / transportRecoveryContract
  @Test func TEST_AC_DEV_004_01_TCPReconnectAlwaysRequiresExplicitConfirmation() throws {
    let replacement = try DeviceRebindCandidate(
      candidateID: "replacement-board",
      connectKey: "192.0.2.10:8710",
      transport: .tcp,
      identitySnapshot: identity(serial: "SERIAL-B"),
      evidence: ["probe:identity-diff"])

    let reconnectDecision = DeviceRebindPolicy.evaluate(
      transport: .tcp,
      disconnected: true,
      endpointExplicitlyAdded: true,
      expectedModeTransition: false,
      candidates: [replacement])
    guard
      case .awaitingRebindConfirmation(let reconnectReason, let displayedCandidates) =
        reconnectDecision
    else {
      Issue.record("TCP replacement unexpectedly auto-rebound")
      return
    }
    #expect(reconnectReason == .tcpReconnectRequiresConfirmation)
    #expect(displayedCandidates == [replacement])
    #expect(
      try displayedCandidates[0].identitySnapshot != identity(serial: "SERIAL-A"),
      "the paused state must retain the replacement identity diff")
    assertAwaiting(
      DeviceRebindPolicy.evaluate(
        transport: .tcp,
        disconnected: true,
        endpointExplicitlyAdded: false,
        expectedModeTransition: false,
        candidates: [replacement]),
      reason: .tcpEndpointNotExplicitlyAdded)
  }

  // TEST-AC-DEV-005-01 / transportRecoveryContract
  @Test func TEST_AC_DEV_005_01_UARTNodeOrAdapterChangeNeverAutoResumes() throws {
    let rebuiltNode = try DeviceRebindCandidate(
      candidateID: "rebuilt-node",
      connectKey: "/dev/cu.usbserial-synthetic-2",
      transport: .uart,
      identitySnapshot: identity(serial: "SERIAL-A"),
      evidence: ["adapter:synthetic-B", "node:rebuilt"])

    assertAwaiting(
      DeviceRebindPolicy.evaluate(
        transport: .uart,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: true,
        candidates: [rebuiltNode]),
      reason: .uartReconnectRequiresConfirmation)
  }

  // TEST-AC-DEV-008-01 / concurrencyProperty
  @Test func TEST_AC_DEV_008_01_PerDeviceMutationLaneQueuesCancelsAndReleasesAllPaths()
    async throws
  {
    let normalIdentity = try identity(serial: "SERIAL-A", mode: "normal")
    let updaterIdentity = try identity(serial: "SERIAL-A", mode: "updater")
    let paddedIdentity = try identity(serial: "  SERIAL-A\n", mode: "updater")
    #expect(try normalIdentity.sha256() != updaterIdentity.sha256())
    #expect(
      try normalIdentity.stablePhysicalIdentitySha256()
        == updaterIdentity.stablePhysicalIdentitySha256())
    #expect(
      try normalIdentity.stablePhysicalIdentitySha256()
        == paddedIdentity.stablePhysicalIdentitySha256())
    #expect(throws: DeviceTargetingValidationError.stablePhysicalIdentityMissing) {
      try DeviceIdentitySnapshot(attributes: ["mode": .string("normal")])
        .stablePhysicalIdentitySha256()
    }

    let coordinator = DeviceMutationLaneCoordinator()
    let firstGate = TestAsyncGate()
    let first = Task {
      try await coordinator.withMutationLane(deviceID: "device-A", requestID: "first") {
        await firstGate.wait()
        return "first-finished"
      }
    }
    try await waitForState(.active, requestID: "first", coordinator: coordinator)

    let cancelled = Task {
      try await coordinator.withMutationLane(deviceID: "device-A", requestID: "cancelled") {
        Issue.record("a queued cancelled request must never enter its operation")
        return
      }
    }
    try await waitForState(
      .queued(reason: .deviceLaneBusy), requestID: "cancelled", coordinator: coordinator)
    cancelled.cancel()
    do {
      try await cancelled.value
      Issue.record("cancelled queued request unexpectedly succeeded")
    } catch {
      #expect(error as? DeviceMutationLaneError == .cancelled)
    }

    await firstGate.open()
    let firstResult = try await first.value
    #expect(firstResult == "first-finished")

    struct SyntheticFailure: Error {}
    do {
      _ =
        try await coordinator.withMutationLane(
          deviceID: "device-A", requestID: "throwing"
        ) {
          throw SyntheticFailure()
        } as String
      Issue.record("throwing operation unexpectedly succeeded")
    } catch is SyntheticFailure {
      // Expected. The following request proves the throwing path released the lane.
    }
    let afterThrow = try await coordinator.withMutationLane(
      deviceID: "device-A", requestID: "after-throw"
    ) {
      "released"
    }
    #expect(afterThrow == "released")

    let handoffCoordinator = DeviceMutationLaneCoordinator()
    let handoffIdentity = DeviceMutationLaneRequestIdentity.job(
      sessionID: "handoff-session",
      jobID: "handoff-job")
    let originalLease = try await handoffCoordinator.acquireLease(
      deviceID: "handoff-device",
      requestIdentity: handoffIdentity,
      ownerID: "original-adapter")
    try await handoffCoordinator.beginDispatch(originalLease)
    do {
      _ = try await handoffCoordinator.adoptActiveLease(
        deviceID: "handoff-device",
        requestIdentity: handoffIdentity,
        ownerID: "reopened-adapter")
      Issue.record("reopen took ownership while the original adapter was dispatching")
    } catch {
      #expect(
        error as? DeviceMutationLaneError
          == .leaseInUse(handoffIdentity.diagnosticID))
    }
    try await handoffCoordinator.endDispatch(originalLease)
    do {
      _ = try await handoffCoordinator.acquireLease(
        deviceID: "different-device",
        requestIdentity: handoffIdentity,
        ownerID: "independent-adapter")
      Issue.record("one durable Job identity acquired two physical-device lanes")
    } catch {
      #expect(
        error as? DeviceMutationLaneError
          == .duplicateRequest(handoffIdentity.diagnosticID))
    }
    let adoptedLease = try await handoffCoordinator.adoptActiveLease(
      requestIdentity: handoffIdentity,
      ownerID: "reopened-adapter")
    let reopenedLease = try #require(adoptedLease)
    do {
      try await handoffCoordinator.beginDispatch(originalLease)
      Issue.record("the superseded adapter retained dispatch authority")
    } catch {
      #expect(
        error as? DeviceMutationLaneError
          == .staleLease(handoffIdentity.diagnosticID))
    }
    try await handoffCoordinator.beginDispatch(reopenedLease)
    try await handoffCoordinator.endDispatch(reopenedLease)
    try await handoffCoordinator.releaseLease(reopenedLease)
    let handoffSnapshot = await handoffCoordinator.snapshot()
    #expect(handoffSnapshot.activeRequestIDs.isEmpty)

    let probe = LaneConcurrencyProbe()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<96 {
        group.addTask {
          let deviceID = "device-\(index % 4)"
          _ = try? await coordinator.withMutationLane(
            deviceID: deviceID, requestID: "property-\(index)"
          ) {
            await probe.enter(deviceID)
            for _ in 0..<3 { await Task.yield() }
            await probe.leave(deviceID)
          }
        }
      }
    }
    let maxima = await probe.maximumByDevice()
    let overallMaximum = await probe.maximumOverall()
    #expect(maxima == ["device-0": 1, "device-1": 1, "device-2": 1, "device-3": 1])
    #expect(overallMaximum > 1)

    let snapshot = await coordinator.snapshot()
    #expect(snapshot.activeRequestIDs.isEmpty)
    #expect(snapshot.queuedRequestIDs.isEmpty)
    #expect(snapshot.maximumConcurrentByDevice.values.allSatisfy { $0 <= 1 })
    print(
      "TASK-M1-007 lane_property_operations=96 same_device_max=1 overall_max=\(overallMaximum) queued_cancelled=1 active_final=\(snapshot.activeRequestIDs.count) queued_final=\(snapshot.queuedRequestIDs.count)"
    )
  }

  private func originalTarget(connectKey: String) throws -> OriginalTargetSnapshot {
    try OriginalTargetSnapshot(
      kind: .real,
      connectKey: connectKey,
      transport: .usb,
      identitySnapshot: identity(serial: "SERIAL-A"))
  }

  private func binding(revision: Int, connectKey: String, serial: String) throws
    -> CurrentDeviceBinding
  {
    try CurrentDeviceBinding(
      revision: revision,
      connectKey: connectKey,
      transport: .usb,
      identitySnapshot: identity(serial: serial),
      evidence: ["synthetic:serial", "synthetic:topology"],
      confirmedBy: .corePolicy,
      channelProtection: .unverifiedAssumeUnprotected)
  }

  private func identity(serial: String, mode: String = "normal") throws -> DeviceIdentitySnapshot {
    try DeviceIdentitySnapshot(attributes: [
      "serial": .string(serial),
      "daemonFingerprint": .string("synthetic-daemon"),
      "usbTopology": .string("synthetic-port-1"),
      "mode": .string(mode),
    ])
  }

  private func candidate(
    id: String,
    key: String,
    serial: Bool,
    fingerprint: Bool,
    topology: Bool,
    mode: Bool
  ) throws -> DeviceRebindCandidate {
    try DeviceRebindCandidate(
      candidateID: id,
      connectKey: key,
      transport: .usb,
      identitySnapshot: identity(serial: serial ? "SERIAL-A" : "SIMILAR-MODEL"),
      evidence: ["synthetic:truth-table"],
      usbEvidence: USBRebindEvidence(
        serialMatches: serial,
        daemonFingerprintMatches: fingerprint,
        topologyMatches: topology,
        expectedModeMatches: mode,
        modelBuildMatches: true))
  }

  private func assertAwaiting(
    _ decision: DeviceRebindDecision,
    reason: DeviceRebindAwaitingReason,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard case .awaitingRebindConfirmation(let actual, _) = decision else {
      Issue.record("expected awaitingRebindConfirmation", sourceLocation: sourceLocation)
      return
    }
    #expect(actual == reason, sourceLocation: sourceLocation)
  }

  private func waitForState(
    _ expected: DeviceMutationLaneRequestState,
    requestID: String,
    coordinator: DeviceMutationLaneCoordinator
  ) async throws {
    for _ in 0..<10_000 {
      if await coordinator.state(deviceID: "device-A", requestID: requestID) == expected { return }
      await Task.yield()
    }
    Issue.record("request \(requestID) did not reach \(expected)")
  }
}

private actor TestAsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in waiters.append(continuation) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private actor LaneConcurrencyProbe {
  private var activeByDevice: [String: Int] = [:]
  private var maximaByDevice: [String: Int] = [:]
  private var overall = 0
  private var overallMaximum = 0

  func enter(_ deviceID: String) {
    activeByDevice[deviceID, default: 0] += 1
    overall += 1
    maximaByDevice[deviceID] = max(
      maximaByDevice[deviceID] ?? 0, activeByDevice[deviceID] ?? 0)
    overallMaximum = max(overallMaximum, overall)
  }

  func leave(_ deviceID: String) {
    activeByDevice[deviceID, default: 0] -= 1
    overall -= 1
  }

  func maximumByDevice() -> [String: Int] { maximaByDevice }
  func maximumOverall() -> Int { overallMaximum }
}
