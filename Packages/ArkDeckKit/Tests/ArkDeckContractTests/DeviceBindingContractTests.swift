import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class DeviceBindingContractTests: XCTestCase {
  // TEST-AC-DEV-002-01 / bindingDispatchContract
  func testTEST_AC_DEV_002_01_RebindPersistsRevisionTwoBeforeExactTargetDispatch() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    var adapter: DeviceBindingJournalAdapter! = try makeAdapter(fixture: fixture)

    let revisionOne = try await adapter.persistInitialBinding()
    let staleRevisionOneIntent = try await adapter.persistStepIntent(
      step: mutationStep(id: "reboot-before-rebind"),
      attempt: 1)
    let candidate = try rebindCandidate(
      id: "updater-candidate", key: "synthetic-usb-updater", serial: "SERIAL-A")
    let revisionTwoBinding = try binding(
      revision: 2, key: candidate.connectKey, serial: "SERIAL-A", evidence: candidate.evidence)
    let revisionTwo = try await adapter.persistRebind(
      candidate: candidate,
      binding: revisionTwoBinding,
      context: strongUSBContext(candidate))
    let staleDispatcher = CountingDeviceDispatcher()
    await assertDispatchRejected(
      staleRevisionOneIntent,
      through: adapter,
      dispatcher: staleDispatcher,
      expected: .bindingMismatch)
    let staleDispatchCount = await staleDispatcher.dispatchCount()
    XCTAssertEqual(staleDispatchCount, 0)

    let step = try mutationStep(id: "reboot-after-rebind")
    let commandIntent = try await adapter.persistStepIntent(
      step: step,
      attempt: 1)
    let dispatcher = CountingDeviceDispatcher()

    let receipt = try await HDCDeviceCommandExecutionGate.dispatch(
      commandIntent,
      through: adapter,
      using: dispatcher)

    XCTAssertEqual(receipt.journalIntentEventID, commandIntent.journalIntentEventID)
    XCTAssertEqual(receipt.bindingReference.revision, 2)
    XCTAssertEqual(
      receipt.actualArguments,
      ["-t", "synthetic-usb-updater", "shell", "reboot", "updater"])
    XCTAssertFalse(receipt.actualArguments.contains("synthetic-usb-A"))
    let successfulDispatchCount = await dispatcher.dispatchCount()
    XCTAssertEqual(successfulDispatchCount, 1)
    print(
      "TASK-M1-007 revision=2 synthetic_executor_seam_dispatch=\(successfulDispatchCount) real_hdc=0 real_device=0 network=0 external_process=0"
    )

    XCTAssertEqual(revisionOne.reference.revision, 1)
    let replayBeforeReopen = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    let durableStep = try XCTUnwrap(
      replayBeforeReopen.events.first {
        $0.eventID == commandIntent.journalIntentEventID && $0.kind == .stepIntent
      })
    XCTAssertEqual(durableStep.bindingRevision, 2)
    XCTAssertEqual(string("kind", in: try XCTUnwrap(durableStep.payload["step"])), "rebootDevice")
    XCTAssertEqual(
      nestedString(
        "targetMode", objectKey: "arguments", in: try XCTUnwrap(durableStep.payload["step"])),
      "updater")

    let manifest = try await adapter.manifestSnapshot()
    XCTAssertEqual(manifest.bindingHistory.count, 2)
    XCTAssertEqual(integer("revision", in: manifest.bindingHistory[0]), 1)
    XCTAssertEqual(integer("revision", in: manifest.bindingHistory[1]), 2)
    XCTAssertEqual(string("connectKey", in: manifest.bindingHistory[1]), "synthetic-usb-updater")

    adapter = nil
    var forgedHistory = try initialHistory()
    try forgedHistory.append(
      binding(
        revision: 2,
        key: "synthetic-usb-forged",
        serial: "SERIAL-ATTACKER",
        evidence: ["synthetic:forged"]))
    XCTAssertThrowsError(
      try DeviceBindingJournalAdapter(
        history: forgedHistory,
        journal: FileDurableJournal(url: fixture.layout.journalURL),
        auditStore: FileDurableSessionAuditStore(layout: fixture.layout),
        replay: DurableJournalRecovery.inspect(url: fixture.layout.journalURL),
        timestamp: fixedTimestamp)
    ) { error in
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .incompleteDurableBindingChain(2))
    }
    let reopened = try DeviceBindingJournalAdapter.reopen(
      layout: fixture.layout, targetID: "device-A", timestamp: fixedTimestamp)
    let reopenedBinding = try await reopened.currentDurableBinding()
    let reopenedHistory = await reopened.bindingHistory()
    XCTAssertEqual(reopenedBinding, revisionTwo)
    XCTAssertEqual(reopenedHistory.originalTarget.connectKey, "synthetic-usb-A")
  }

  // TEST-AC-DEV-002-02 / multiDeviceProperty
  func testTEST_AC_DEV_002_02_MissingMismatchedAndCrossDeviceTargetsDispatchZero() async throws {
    let fixtureA = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixtureA.container) }
    let adapterA = try makeAdapter(fixture: fixtureA)
    _ = try await adapterA.persistInitialBinding()
    let intentA = try await adapterA.persistStepIntent(
      step: mutationStep(id: "device-A-command"),
      attempt: 1)
    let dispatcher = CountingDeviceDispatcher()

    let fixtureB = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixtureB.container) }
    let adapterB = try makeAdapter(
      fixture: fixtureB,
      history: initialHistory(
        targetID: "device-B", key: "synthetic-usb-B", serial: "SERIAL-B"))
    _ = try await adapterB.persistInitialBinding()
    await assertDispatchRejected(
      intentA,
      through: adapterB,
      dispatcher: dispatcher,
      expected: .commandIntentNotDurable)

    let wrongRevisionIntent = try HDCDeviceCommandIntent(
      step: mutationStep(id: "wrong-revision"),
      bindingReference: DeviceBindingReference(targetID: "device-A", revision: 2))
    let forgedRevision = try DurableHDCDeviceCommandIntent(
      journalIntentEventID: intentA.journalIntentEventID,
      intent: wrongRevisionIntent)
    await assertDispatchRejected(
      forgedRevision,
      through: adapterA,
      dispatcher: dispatcher,
      expected: .commandIntentNotDurable)

    let missingJournalIntent = try DurableHDCDeviceCommandIntent(
      journalIntentEventID: "missing-intent-event",
      intent: intentA.intent)
    await assertDispatchRejected(
      missingJournalIntent,
      through: adapterA,
      dispatcher: dispatcher,
      expected: .commandIntentNotDurable)

    let stepIntentCountBefore = try DurableJournalRecovery.inspect(
      url: fixtureA.layout.journalURL
    ).events.filter { $0.kind == .stepIntent }.count
    do {
      _ = try await adapterA.persistStepIntent(step: probeStep(id: "typed-read-only"), attempt: 1)
      XCTFail("probeDevice unexpectedly accepted caller-selected shell reboot argv")
    } catch {
      XCTAssertEqual(error as? HDCDeviceCommandError, .unsupportedStepKind(.probeDevice))
    }
    let stepIntentCountAfter = try DurableJournalRecovery.inspect(
      url: fixtureA.layout.journalURL
    ).events.filter { $0.kind == .stepIntent }.count
    XCTAssertEqual(stepIntentCountAfter, stepIntentCountBefore)

    let rejectedDispatchCount = await dispatcher.dispatchCount()
    XCTAssertEqual(rejectedDispatchCount, 0)
    print(
      "TASK-M1-007 rejected_target_vectors=3 typed_step_argv_bypass=0 synthetic_executor_seam_dispatch=\(rejectedDispatchCount) real_hdc=0 real_device=0 network=0 external_process=0"
    )
  }

  // TEST-AC-DEV-008-01 / bindingDispatchContract
  func testTEST_AC_DEV_008_01_MutationDispatchSeamSerializesPerDevice() async throws {
    let mutationLane = DeviceMutationLaneCoordinator()
    let fixtureA = try makeFixture(
      sessionID: "a:b",
      jobID: "c",
      mutationLane: mutationLane)
    defer { try? FileManager.default.removeItem(at: fixtureA.container) }
    let fixtureB = try makeFixture(
      sessionID: "a",
      jobID: "b:c",
      mutationLane: mutationLane)
    defer { try? FileManager.default.removeItem(at: fixtureB.container) }
    let historyA = try initialHistory(targetID: "job-target-alias-A", mode: "normal")
    let historyB = try initialHistory(
      targetID: "job-target-alias-B",
      serial: "  SERIAL-A\n",
      mode: "updater")
    XCTAssertNotEqual(historyA.targetID, historyB.targetID)
    XCTAssertNotEqual(historyA.originalTarget, historyB.originalTarget)
    XCTAssertNotEqual(
      try historyA.originalTarget.identitySnapshot.sha256(),
      try historyB.originalTarget.identitySnapshot.sha256())
    let physicalDeviceIdentityKey =
      try historyA.originalTarget.identitySnapshot.stablePhysicalIdentitySha256()
    XCTAssertEqual(
      physicalDeviceIdentityKey,
      try historyB.originalTarget.identitySnapshot.stablePhysicalIdentitySha256())
    let jobIdentityA = DeviceMutationLaneRequestIdentity.job(
      sessionID: fixtureA.layout.sessionID,
      jobID: fixtureA.layout.jobID)
    let jobIdentityB = DeviceMutationLaneRequestIdentity.job(
      sessionID: fixtureB.layout.sessionID,
      jobID: fixtureB.layout.jobID)
    XCTAssertEqual(
      "\(fixtureA.layout.sessionID):\(fixtureA.layout.jobID)",
      "\(fixtureB.layout.sessionID):\(fixtureB.layout.jobID)")
    XCTAssertNotEqual(jobIdentityA, jobIdentityB)
    XCTAssertNotEqual(jobIdentityA.diagnosticID, jobIdentityB.diagnosticID)
    var adapterA: DeviceBindingJournalAdapter? = try makeAdapter(
      fixture: fixtureA,
      history: historyA)
    let adapterB = try makeAdapter(fixture: fixtureB, history: historyB)
    _ = try await XCTUnwrap(adapterA).persistInitialBinding()
    _ = try await adapterB.persistInitialBinding()
    let firstIntent = try await XCTUnwrap(adapterA).persistStepIntent(
      step: mutationStep(id: "first-concurrent-mutation"),
      attempt: 1)
    let terminalObservedIntent = try await XCTUnwrap(adapterA).persistStepIntent(
      step: mutationStep(id: "journal-terminal-mutation"),
      attempt: 1)
    let secondIntent = try await adapterB.persistStepIntent(
      step: mutationStep(id: "second-concurrent-mutation"),
      attempt: 1)
    let dispatcher = BlockingDeviceDispatcher()

    var firstTask: Task<HDCDeviceCommandDispatchReceipt, any Error>?
    do {
      let firstAdapter = try XCTUnwrap(adapterA)
      firstTask = Task {
        try await HDCDeviceCommandExecutionGate.dispatch(
          firstIntent,
          through: firstAdapter,
          using: dispatcher)
      }
    }
    await dispatcher.waitUntilStarted(1)
    var dispatchSnapshot = await dispatcher.snapshot()
    XCTAssertEqual(dispatchSnapshot.started, 1)
    XCTAssertEqual(dispatchSnapshot.maximumConcurrent, 1)

    await dispatcher.releaseOne()
    do {
      let completedFirstTask = try XCTUnwrap(firstTask)
      _ = try await completedFirstTask.value
    }
    firstTask = nil
    let firstReplayAfterCommand = try DurableJournalRecovery.inspect(
      url: fixtureA.layout.journalURL)
    XCTAssertEqual(firstReplayAfterCommand.currentState, .running)
    let secondTask = Task {
      try await HDCDeviceCommandExecutionGate.dispatch(
        secondIntent,
        through: adapterB,
        using: dispatcher)
    }
    await mutationLane.waitUntilState(
      deviceID: physicalDeviceIdentityKey,
      requestIdentity: jobIdentityB,
      equals: .queued(reason: .deviceLaneBusy))
    let secondStateAfterFirstCommand = await mutationLane.state(
      deviceID: physicalDeviceIdentityKey,
      requestIdentity: jobIdentityB)
    XCTAssertEqual(
      secondStateAfterFirstCommand,
      .queued(reason: .deviceLaneBusy))
    dispatchSnapshot = await dispatcher.snapshot()
    XCTAssertEqual(dispatchSnapshot.started, 1)
    do {
      try await XCTUnwrap(adapterA).releaseExclusiveMutationLaneAfterDurableTerminal()
      XCTFail("command completion released an exclusive Job before durable terminal")
    } catch {
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .mutationJobNotDurablyTerminal)
    }

    try appendSuccessfulTerminalLifecycle(
      fixture: fixtureA,
      intents: [firstIntent, terminalObservedIntent])
    let terminalDispatcher = CountingDeviceDispatcher()
    await assertDispatchRejected(
      terminalObservedIntent,
      through: try XCTUnwrap(adapterA),
      dispatcher: terminalDispatcher,
      expected: .commandIntentAlreadyDispatched)
    let terminalDispatchCount = await terminalDispatcher.dispatchCount()
    XCTAssertEqual(terminalDispatchCount, 0)

    weak let releasedAdapterA = adapterA
    adapterA = nil
    XCTAssertNil(releasedAdapterA)
    let reopenedA = try DeviceBindingJournalAdapter.reopen(
      layout: fixtureA.layout,
      targetID: historyA.targetID,
      mutationLane: mutationLane,
      timestamp: fixedTimestamp)
    let reopenedState = await mutationLane.state(
      deviceID: physicalDeviceIdentityKey,
      requestIdentity: jobIdentityA)
    XCTAssertEqual(reopenedState, .active)
    try await reopenedA.releaseExclusiveMutationLaneAfterDurableTerminal()
    await dispatcher.waitUntilStarted(2)
    dispatchSnapshot = await dispatcher.snapshot()
    XCTAssertEqual(dispatchSnapshot.maximumConcurrent, 1)
    await dispatcher.releaseOne()
    _ = try await secondTask.value
    try appendSuccessfulTerminalLifecycle(fixture: fixtureB, intents: [secondIntent])
    try await adapterB.releaseExclusiveMutationLaneAfterDurableTerminal()

    dispatchSnapshot = await dispatcher.snapshot()
    let laneSnapshot = await mutationLane.snapshot()
    XCTAssertEqual(dispatchSnapshot.started, 2)
    XCTAssertEqual(dispatchSnapshot.maximumConcurrent, 1)
    XCTAssertTrue(laneSnapshot.activeRequestIDs.isEmpty)
    XCTAssertTrue(laneSnapshot.queuedRequestIDs.isEmpty)
    print(
      "TASK-M1-007 dispatch_seam_mutations=2 target_aliases=2 modes=2 normalized_serial_keys=1 legacy_request_id_collisions=1 structured_request_id_collisions=0 terminal_window_dispatch=0 reopened_terminal_cleanup=1 second_job_queued_until_terminal=1 same_device_max=\(dispatchSnapshot.maximumConcurrent)"
    )
  }

  // TEST-AC-DEV-008-01 / bindingDispatchContract
  func testTEST_AC_DEV_008_01_IdentityChangingRebindMigratesToCurrentDeviceLane() async throws {
    let mutationLane = DeviceMutationLaneCoordinator()
    let fixtureA = try makeFixture(
      sessionID: "identity-rebind-session-A",
      jobID: "identity-rebind-job-A",
      mutationLane: mutationLane)
    defer { try? FileManager.default.removeItem(at: fixtureA.container) }
    let fixtureB = try makeFixture(
      sessionID: "identity-rebind-session-B",
      jobID: "identity-rebind-job-B",
      mutationLane: mutationLane)
    defer { try? FileManager.default.removeItem(at: fixtureB.container) }
    let historyA = try initialHistory(
      targetID: "identity-rebind-target-A",
      key: "synthetic-usb-A",
      serial: "SERIAL-A")
    let historyB = try initialHistory(
      targetID: "identity-rebind-target-B",
      key: "synthetic-usb-B",
      serial: "SERIAL-B")
    var adapterA: DeviceBindingJournalAdapter? = try makeAdapter(
      fixture: fixtureA,
      history: historyA)
    let adapterB = try makeAdapter(fixture: fixtureB, history: historyB)
    _ = try await XCTUnwrap(adapterA).persistInitialBinding()
    _ = try await adapterB.persistInitialBinding()

    let preRebindIntent = try await XCTUnwrap(adapterA).persistStepIntent(
      step: mutationStep(id: "device-A-before-identity-rebind"),
      attempt: 1)
    let preRebindDispatcher = CountingDeviceDispatcher()
    _ = try await HDCDeviceCommandExecutionGate.dispatch(
      preRebindIntent,
      through: try XCTUnwrap(adapterA),
      using: preRebindDispatcher)
    let preRebindDispatchCount = await preRebindDispatcher.dispatchCount()
    XCTAssertEqual(preRebindDispatchCount, 1)
    try appendConfirmedStepOutcomes(
      fixture: fixtureA,
      intents: [preRebindIntent],
      result: "succeeded")

    let originalDeviceKey =
      try historyA.originalTarget.identitySnapshot.stablePhysicalIdentitySha256()
    let currentDeviceKey =
      try historyB.originalTarget.identitySnapshot.stablePhysicalIdentitySha256()
    XCTAssertNotEqual(originalDeviceKey, currentDeviceKey)
    let jobIdentityA = DeviceMutationLaneRequestIdentity.job(
      sessionID: fixtureA.layout.sessionID,
      jobID: fixtureA.layout.jobID)
    let originalLaneState = await mutationLane.state(
      deviceID: originalDeviceKey,
      requestIdentity: jobIdentityA)
    XCTAssertEqual(originalLaneState, .active)

    let candidateB = try DeviceRebindCandidate(
      candidateID: "user-confirmed-device-B",
      connectKey: "192.0.2.20:8710",
      transport: .tcp,
      identitySnapshot: identity(serial: "SERIAL-B"),
      evidence: ["synthetic:user-confirmed-device-B"])
    let reboundToB = try binding(
      revision: 2,
      key: candidateB.connectKey,
      serial: "SERIAL-B",
      evidence: candidateB.evidence,
      transport: .tcp,
      confirmedBy: .user)
    _ = try await XCTUnwrap(adapterA).persistRebind(
      candidate: candidateB,
      binding: reboundToB,
      context: DeviceRebindContext(
        transport: .tcp,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: false,
        candidates: [candidateB],
        userConfirmedCandidateID: candidateB.candidateID))
    let adapterACurrent = try await XCTUnwrap(adapterA).currentDurableBinding()
    let adapterBCurrent = try await adapterB.currentDurableBinding()
    XCTAssertEqual(
      try adapterACurrent.binding.identitySnapshot.stablePhysicalIdentitySha256(),
      try adapterBCurrent.binding.identitySnapshot.stablePhysicalIdentitySha256())

    let postRebindIntent = try await XCTUnwrap(adapterA).persistStepIntent(
      step: mutationStep(id: "device-B-after-identity-rebind"),
      attempt: 1)
    let deviceBIntent = try await adapterB.persistStepIntent(
      step: mutationStep(id: "device-B-original-job"),
      attempt: 1)
    let dispatcher = BlockingDeviceDispatcher()
    let deviceBTask = Task {
      try await HDCDeviceCommandExecutionGate.dispatch(
        deviceBIntent,
        through: adapterB,
        using: dispatcher)
    }
    await dispatcher.waitUntilStarted(1)
    var reboundTask: Task<HDCDeviceCommandDispatchReceipt, any Error>?
    do {
      let reboundAdapter = try XCTUnwrap(adapterA)
      reboundTask = Task {
        try await HDCDeviceCommandExecutionGate.dispatch(
          postRebindIntent,
          through: reboundAdapter,
          using: dispatcher)
      }
    }
    await mutationLane.waitUntilState(
      deviceID: currentDeviceKey,
      requestIdentity: jobIdentityA,
      equals: .queued(reason: .deviceLaneBusy))
    let staleDeviceLaneState = await mutationLane.state(
      deviceID: originalDeviceKey,
      requestIdentity: jobIdentityA)
    XCTAssertNil(staleDeviceLaneState)
    var dispatchSnapshot = await dispatcher.snapshot()
    XCTAssertEqual(dispatchSnapshot.started, 1)
    XCTAssertEqual(dispatchSnapshot.maximumConcurrent, 1)

    await dispatcher.releaseOne()
    _ = try await deviceBTask.value
    let reboundStateAfterDeviceBCommand = await mutationLane.state(
      deviceID: currentDeviceKey,
      requestIdentity: jobIdentityA)
    XCTAssertEqual(reboundStateAfterDeviceBCommand, .queued(reason: .deviceLaneBusy))
    try appendSuccessfulTerminalLifecycle(fixture: fixtureB, intents: [deviceBIntent])
    try await adapterB.releaseExclusiveMutationLaneAfterDurableTerminal()
    await dispatcher.waitUntilStarted(2)
    dispatchSnapshot = await dispatcher.snapshot()
    XCTAssertEqual(dispatchSnapshot.maximumConcurrent, 1)

    await dispatcher.releaseOne()
    _ = try await XCTUnwrap(reboundTask).value
    reboundTask = nil
    try appendSuccessfulTerminalLifecycle(
      fixture: fixtureA,
      intents: [postRebindIntent])
    weak let releasedAdapterA = adapterA
    adapterA = nil
    XCTAssertNil(releasedAdapterA)
    let reopenedA = try DeviceBindingJournalAdapter.reopen(
      layout: fixtureA.layout,
      targetID: historyA.targetID,
      mutationLane: mutationLane,
      timestamp: fixedTimestamp)
    try await reopenedA.releaseExclusiveMutationLaneAfterDurableTerminal()
    let laneSnapshot = await mutationLane.snapshot()
    XCTAssertTrue(laneSnapshot.activeRequestIDs.isEmpty)
    XCTAssertTrue(laneSnapshot.queuedRequestIDs.isEmpty)
    print(
      "TASK-M1-007 identity_changing_rebinds=1 stale_device_lane_after_migration=0 rebound_job_queued=1 reopened_rebound_cleanup=1 current_device_max=\(dispatchSnapshot.maximumConcurrent)"
    )
  }

  // TEST-AC-DEV-008-01 / bindingDispatchContract
  func testTEST_AC_DEV_008_01_UnpersistedMutationOutcomeBlocksRebindAndRetainsLane()
    async throws
  {
    let mutationLane = DeviceMutationLaneCoordinator()
    let fixtureA = try makeFixture(
      sessionID: "outcome-recovery-session-A",
      jobID: "outcome-recovery-job-A",
      mutationLane: mutationLane)
    defer { try? FileManager.default.removeItem(at: fixtureA.container) }
    let fixtureB = try makeFixture(
      sessionID: "outcome-recovery-session-B",
      jobID: "outcome-recovery-job-B",
      mutationLane: mutationLane)
    defer { try? FileManager.default.removeItem(at: fixtureB.container) }
    let historyA = try initialHistory(
      targetID: "outcome-recovery-target-A",
      key: "synthetic-usb-A",
      serial: "SERIAL-A")
    let historyB = try initialHistory(
      targetID: "outcome-recovery-target-B",
      key: "synthetic-usb-A-alias",
      serial: " SERIAL-A ")
    let adapterA = try makeAdapter(fixture: fixtureA, history: historyA)
    let adapterB = try makeAdapter(fixture: fixtureB, history: historyB)
    _ = try await adapterA.persistInitialBinding()
    _ = try await adapterB.persistInitialBinding()

    let dispatchedIntent = try await adapterA.persistStepIntent(
      step: mutationStep(id: "mutation-without-durable-outcome"),
      attempt: 1)
    let pendingIntent = try await adapterA.persistStepIntent(
      step: mutationStep(id: "mutation-after-unknown-outcome"),
      attempt: 1)
    let firstDispatcher = CountingDeviceDispatcher()
    _ = try await HDCDeviceCommandExecutionGate.dispatch(
      dispatchedIntent,
      through: adapterA,
      using: firstDispatcher)
    let firstDispatchCount = await firstDispatcher.dispatchCount()
    XCTAssertEqual(firstDispatchCount, 1)

    let originalDeviceKey =
      try historyA.originalTarget.identitySnapshot.stablePhysicalIdentitySha256()
    XCTAssertEqual(
      originalDeviceKey,
      try historyB.originalTarget.identitySnapshot.stablePhysicalIdentitySha256())
    let jobIdentityA = DeviceMutationLaneRequestIdentity.job(
      sessionID: fixtureA.layout.sessionID,
      jobID: fixtureA.layout.jobID)
    let originalLaneState = await mutationLane.state(
      deviceID: originalDeviceKey,
      requestIdentity: jobIdentityA)
    XCTAssertEqual(originalLaneState, .active)

    let candidateB = try DeviceRebindCandidate(
      candidateID: "rebind-blocked-until-outcome",
      connectKey: "192.0.2.30:8710",
      transport: .tcp,
      identitySnapshot: identity(serial: "SERIAL-B"),
      evidence: ["synthetic:user-confirmed-device-B"])
    let reboundToB = try binding(
      revision: 2,
      key: candidateB.connectKey,
      serial: "SERIAL-B",
      evidence: candidateB.evidence,
      transport: .tcp,
      confirmedBy: .user)
    do {
      _ = try await adapterA.persistRebind(
        candidate: candidateB,
        binding: reboundToB,
        context: DeviceRebindContext(
          transport: .tcp,
          disconnected: true,
          endpointExplicitlyAdded: true,
          expectedModeTransition: false,
          candidates: [candidateB],
          userConfirmedCandidateID: candidateB.candidateID))
      XCTFail("rebind advanced to another device while a mutation outcome was not durable")
    } catch {
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .mutationRecoveryRequired)
    }

    let blockedDispatcher = CountingDeviceDispatcher()
    await assertDispatchRejected(
      pendingIntent,
      through: adapterA,
      dispatcher: blockedDispatcher,
      expected: .mutationRecoveryRequired)
    do {
      _ = try await adapterA.persistStepIntent(
        step: mutationStep(id: "new-mutation-while-recovery-required"),
        attempt: 1)
      XCTFail("new mutation intent persisted while an earlier outcome was unresolved")
    } catch {
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .mutationRecoveryRequired)
    }

    let recoveryReplay = try DurableJournalRecovery.inspect(url: fixtureA.layout.journalURL)
    XCTAssertEqual(recoveryReplay.currentState, .waitingForRecovery)
    XCTAssertEqual(recoveryReplay.outstandingIntents.count, 2)
    XCTAssertTrue(recoveryReplay.unknownOutcomes.isEmpty)
    XCTAssertEqual(recoveryReplay.events.filter { $0.kind == .bindingConfirmed }.count, 1)
    XCTAssertEqual(recoveryReplay.events.filter { $0.kind == .stepIntent }.count, 2)
    let currentBindingAfterRejectedRebind = try await adapterA.currentDurableBinding()
    XCTAssertEqual(currentBindingAfterRejectedRebind.reference.revision, 1)
    let blockedDispatchCount = await blockedDispatcher.dispatchCount()
    XCTAssertEqual(blockedDispatchCount, 0)
    let recoveryHeldLaneState = await mutationLane.state(
      deviceID: originalDeviceKey,
      requestIdentity: jobIdentityA)
    XCTAssertEqual(recoveryHeldLaneState, .active)

    let competingIntent = try await adapterB.persistStepIntent(
      step: mutationStep(id: "competing-job-on-original-device"),
      attempt: 1)
    let competingDispatcher = CountingDeviceDispatcher()
    let competingTask = Task {
      try await HDCDeviceCommandExecutionGate.dispatch(
        competingIntent,
        through: adapterB,
        using: competingDispatcher)
    }
    let jobIdentityB = DeviceMutationLaneRequestIdentity.job(
      sessionID: fixtureB.layout.sessionID,
      jobID: fixtureB.layout.jobID)
    await mutationLane.waitUntilState(
      deviceID: originalDeviceKey,
      requestIdentity: jobIdentityB,
      equals: .queued(reason: .deviceLaneBusy))
    let competingDispatchCount = await competingDispatcher.dispatchCount()
    XCTAssertEqual(competingDispatchCount, 0)
    competingTask.cancel()
    do {
      _ = try await competingTask.value
      XCTFail("cancelled competing mutation unexpectedly acquired the recovery-held lane")
    } catch {
      XCTAssertEqual(error as? DeviceMutationLaneError, .cancelled)
    }

    print(
      "TASK-M1-007 unresolved_mutation_outcomes=1 rebind_dispatch=0 new_mutation_intents=0 waiting_for_recovery=1 original_lane_retained=1 competing_job_queued=1"
    )
  }

  // TEST-AC-DEV-008-01 / bindingDispatchContract
  func testTEST_AC_DEV_008_01_MissingStableIdentityRejectsBeforeDurableMutationIntent()
    async throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let seriallessIdentity = try DeviceIdentitySnapshot(attributes: [
      "daemonFingerprint": .string("synthetic-daemon"),
      "usbTopology": .string("synthetic-port-1"),
      "mode": .string("normal"),
    ])
    let original = try OriginalTargetSnapshot(
      kind: .real,
      connectKey: "synthetic-usb-no-serial",
      transport: .usb,
      identitySnapshot: seriallessIdentity)
    let initialBinding = try CurrentDeviceBinding(
      revision: 1,
      connectKey: "synthetic-usb-no-serial",
      transport: .usb,
      identitySnapshot: seriallessIdentity,
      evidence: ["synthetic:user-confirmed-no-serial"],
      confirmedBy: .user,
      channelProtection: .unverifiedAssumeUnprotected)
    let history = try DeviceBindingHistory(
      targetID: "device-no-serial",
      originalTarget: original,
      initialBinding: initialBinding)
    let adapter = try makeAdapter(fixture: fixture, history: history)
    _ = try await adapter.persistInitialBinding()
    let before = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)

    do {
      _ = try await adapter.persistStepIntent(
        step: mutationStep(id: "mutation-without-stable-identity"),
        attempt: 1)
      XCTFail("serialless mutation unexpectedly persisted an outstanding intent")
    } catch {
      XCTAssertEqual(
        error as? DeviceTargetingValidationError,
        .stablePhysicalIdentityMissing)
    }

    let after = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    XCTAssertEqual(after.events.filter { $0.kind == .stepIntent }.count, 0)
    XCTAssertTrue(after.outstandingIntents.isEmpty)
    XCTAssertEqual(after.lastDurableSequence, before.lastDurableSequence)
    print("TASK-M1-007 serialless_mutation_intents=0 outstanding_intents=0")
  }

  // TEST-AC-DEV-004-01 / TEST-AC-DEV-005-01 / effectGateProperty
  func testDisconnectWithoutCandidateDurablyClosesMutationGateForEveryRealTransport()
    async throws
  {
    let vectors: [(DeviceTransport, String)] = [
      (.usb, "synthetic-usb-disconnected"),
      (.tcp, "192.0.2.20:8710"),
      (.uart, "/dev/cu.synthetic-disconnected"),
    ]
    var rejectedDispatches = 0

    for (transport, connectKey) in vectors {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.container) }
      let targetID = "device-\(transport.rawValue)"
      var adapter: DeviceBindingJournalAdapter? = try makeAdapter(
        fixture: fixture,
        history: initialHistory(
          targetID: targetID,
          key: connectKey,
          serial: "SERIAL-\(transport.rawValue)",
          transport: transport))
      _ = try await XCTUnwrap(adapter).persistInitialBinding()
      let intent = try await XCTUnwrap(adapter).persistStepIntent(
        step: mutationStep(id: "mutation-before-\(transport.rawValue)-disconnect"),
        attempt: 1)

      try await XCTUnwrap(adapter).recordRejectedCandidates([], reason: .policyBlocked)
      let dispatcher = CountingDeviceDispatcher()
      await assertDispatchRejected(
        intent,
        through: try XCTUnwrap(adapter),
        dispatcher: dispatcher,
        expected: .effectRejected(.identityUnconfirmed))
      rejectedDispatches += await dispatcher.dispatchCount()

      let replay = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
      XCTAssertEqual(replay.currentState, .waitingForDevice)
      XCTAssertTrue(
        replay.events.contains {
          $0.kind == .stateTransition
            && $0.payload["from"] == .string(JobState.running.rawValue)
            && $0.payload["to"] == .string(JobState.waitingForDevice.rawValue)
            && $0.payload["reason"] == .string("deviceDisconnectedNoCandidate")
        })

      adapter = nil
      let reopened = try DeviceBindingJournalAdapter.reopen(
        layout: fixture.layout,
        targetID: targetID,
        timestamp: fixedTimestamp)
      do {
        _ = try await reopened.persistStepIntent(
          step: mutationStep(id: "mutation-after-\(transport.rawValue)-reopen"),
          attempt: 1)
        XCTFail("reopen lost the durable no-candidate disconnect gate for \(transport)")
      } catch {
        XCTAssertEqual(
          error as? DeviceBindingJournalAdapterError,
          .mutationRecoveryRequired)
      }
      let reopenedReplay = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
      XCTAssertEqual(reopenedReplay.currentState, .waitingForRecovery)
    }

    XCTAssertEqual(rejectedDispatches, 0)
    print(
      "TASK-M1-007 no_candidate_disconnect_transports=3 mutation_dispatch=\(rejectedDispatches)"
    )
  }

  // TEST-AC-DEV-006-01 / effectGateProperty
  func testTEST_AC_DEV_006_01_AmbiguousIdentityIsDurablyAuditedAndMutationDispatchesZero()
    async throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    var adapter: DeviceBindingJournalAdapter! = try makeAdapter(fixture: fixture)
    let durable = try await adapter.persistInitialBinding()
    let intentBeforeAmbiguity = try await adapter.persistStepIntent(
      step: mutationStep(id: "mutation-before-ambiguity"),
      attempt: 1)
    let candidates = [
      try rebindCandidate(id: "candidate-A", key: "synthetic-reconnect-A", serial: "SERIAL-A"),
      try rebindCandidate(id: "candidate-B", key: "synthetic-reconnect-B", serial: "SERIAL-A"),
    ]
    try await adapter.recordRejectedCandidates(candidates, reason: .ambiguous)

    let dispatcher = CountingDeviceDispatcher()
    await assertDispatchRejected(
      intentBeforeAmbiguity,
      through: adapter,
      dispatcher: dispatcher,
      expected: .effectRejected(.identityAmbiguous))
    do {
      _ = try await adapter.persistStepIntent(
        step: mutationStep(id: "mutation-after-ambiguity"),
        attempt: 1)
      XCTFail("caller must not override the journal-backed ambiguous identity state")
    } catch {
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .effectRejected(.identityAmbiguous))
    }
    let ambiguousDispatchCount = await dispatcher.dispatchCount()
    XCTAssertEqual(ambiguousDispatchCount, 0)
    try appendConfirmedStepOutcomes(
      fixture: fixture,
      intents: [intentBeforeAmbiguity],
      result: "failed")
    print(
      "TASK-M1-007 ambiguous_candidates=2 mutation_dispatch=\(ambiguousDispatchCount) real_hdc=0 real_device=0 network=0 external_process=0"
    )

    let replay = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    XCTAssertEqual(
      replay.events.filter {
        $0.kind == .bindingCandidate && $0.payload["ambiguity"] == .string("ambiguous")
      }.count,
      2)
    XCTAssertEqual(
      replay.events.filter {
        $0.kind == .bindingRejected && $0.payload["reason"] == .string("ambiguous")
      }.count,
      2)
    XCTAssertEqual(replay.currentState, .awaitingRebindConfirmation)

    adapter = nil
    var audit: FileDurableSessionAuditStore? = try FileDurableSessionAuditStore(
      layout: fixture.layout)
    let records = try XCTUnwrap(audit).replay(correlationID: "device-binding-device-A")
    XCTAssertTrue(
      records.contains {
        $0.details["eventType"] == .string("bindingRejected")
          && $0.details["state"] == .string("awaitingRebindConfirmation")
      })
    audit = nil
    let reopened = try DeviceBindingJournalAdapter.reopen(
      layout: fixture.layout, targetID: "device-A", timestamp: fixedTimestamp)
    let reopenedBinding = try await reopened.currentDurableBinding()
    XCTAssertEqual(reopenedBinding, durable)
    do {
      _ = try await reopened.persistStepIntent(
        step: mutationStep(id: "mutation-after-reopen"),
        attempt: 1)
      XCTFail("reopen lost the durable ambiguous identity state")
    } catch {
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .effectRejected(.identityAmbiguous))
    }

    let selectedCandidate = candidates[0]
    let userConfirmedBinding = try binding(
      revision: 2,
      key: selectedCandidate.connectKey,
      serial: "SERIAL-A",
      evidence: selectedCandidate.evidence,
      confirmedBy: .user)
    _ = try await reopened.persistRebind(
      candidate: selectedCandidate,
      binding: userConfirmedBinding,
      context: DeviceRebindContext(
        transport: .usb,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: true,
        candidates: candidates,
        userConfirmedCandidateID: selectedCandidate.candidateID))
    let postConfirmationIntent = try await reopened.persistStepIntent(
      step: mutationStep(id: "mutation-after-user-confirmation"),
      attempt: 1)
    let postConfirmationDispatcher = CountingDeviceDispatcher()
    _ = try await HDCDeviceCommandExecutionGate.dispatch(
      postConfirmationIntent,
      through: reopened,
      using: postConfirmationDispatcher)
    let replayAfterConfirmation = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    XCTAssertEqual(replayAfterConfirmation.currentState, .running)
    let postConfirmationDispatchCount = await postConfirmationDispatcher.dispatchCount()
    XCTAssertEqual(postConfirmationDispatchCount, 1)
  }

  // TEST-AC-DEV-003-02 / rebindPolicyContract
  func testTEST_AC_DEV_003_02_DurableRebindCannotBypassTransportPolicy() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let adapter = try makeAdapter(fixture: fixture)
    _ = try await adapter.persistInitialBinding()

    let weakUSB = try DeviceRebindCandidate(
      candidateID: "model-only-usb",
      connectKey: "synthetic-usb-model-only",
      transport: .usb,
      identitySnapshot: identity(serial: "SIMILAR-MODEL"),
      evidence: ["synthetic:model-only"])
    let weakUSBBinding = try binding(
      revision: 2,
      key: weakUSB.connectKey,
      serial: "SIMILAR-MODEL",
      evidence: weakUSB.evidence)
    await assertRebindRejected(
      adapter: adapter,
      candidate: weakUSB,
      binding: weakUSBBinding,
      context: strongUSBContext(weakUSB),
      expected: .corePolicyNotEligible(.coreEvidenceInsufficient))

    let tcp = try DeviceRebindCandidate(
      candidateID: "tcp-replacement",
      connectKey: "192.0.2.10:8710",
      transport: .tcp,
      identitySnapshot: identity(serial: "SERIAL-TCP"),
      evidence: ["synthetic:tcp-probe"])
    let tcpContext = DeviceRebindContext(
      transport: .tcp,
      disconnected: true,
      endpointExplicitlyAdded: true,
      expectedModeTransition: false,
      candidates: [tcp])
    XCTAssertThrowsError(
      try binding(
        revision: 2,
        key: tcp.connectKey,
        serial: "SERIAL-TCP",
        evidence: tcp.evidence,
        transport: .tcp,
        confirmedBy: .corePolicy)
    ) { error in
      XCTAssertEqual(error as? DeviceTargetingValidationError, .invalidBindingShape)
    }
    XCTAssertThrowsError(
      try DeviceRebindPolicy.authorizePersistence(
        context: tcpContext,
        selectedCandidate: tcp,
        confirmedBy: .corePolicy)
    ) { error in
      XCTAssertEqual(
        error as? DeviceRebindAuthorizationError,
        .corePolicyNotEligible(.tcpReconnectRequiresConfirmation))
    }

    let uart = try DeviceRebindCandidate(
      candidateID: "uart-replacement",
      connectKey: "/dev/cu.synthetic-uart",
      transport: .uart,
      identitySnapshot: identity(serial: "SERIAL-UART"),
      evidence: ["synthetic:uart-adapter"])
    let uartContext = DeviceRebindContext(
      transport: .uart,
      disconnected: true,
      endpointExplicitlyAdded: true,
      expectedModeTransition: false,
      candidates: [uart])
    XCTAssertThrowsError(
      try binding(
        revision: 2,
        key: uart.connectKey,
        serial: "SERIAL-UART",
        evidence: uart.evidence,
        transport: .uart,
        confirmedBy: .corePolicy)
    ) { error in
      XCTAssertEqual(error as? DeviceTargetingValidationError, .invalidBindingShape)
    }
    XCTAssertThrowsError(
      try DeviceRebindPolicy.authorizePersistence(
        context: uartContext,
        selectedCandidate: uart,
        confirmedBy: .corePolicy)
    ) { error in
      XCTAssertEqual(
        error as? DeviceRebindAuthorizationError,
        .corePolicyNotEligible(.uartReconnectRequiresConfirmation))
    }

    var replay = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    XCTAssertEqual(replay.events.filter { $0.kind == .bindingCandidate }.count, 1)
    XCTAssertEqual(replay.events.filter { $0.kind == .bindingConfirmed }.count, 1)

    let tcpUserBinding = try binding(
      revision: 2,
      key: tcp.connectKey,
      serial: "SERIAL-TCP",
      evidence: tcp.evidence,
      transport: .tcp,
      confirmedBy: .user)
    let tcpUserReceipt = try await adapter.persistRebind(
      candidate: tcp,
      binding: tcpUserBinding,
      context: DeviceRebindContext(
        transport: .tcp,
        disconnected: true,
        endpointExplicitlyAdded: true,
        expectedModeTransition: false,
        candidates: [tcp],
        userConfirmedCandidateID: tcp.candidateID))
    XCTAssertEqual(tcpUserReceipt.binding, tcpUserBinding)
    replay = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    XCTAssertEqual(replay.events.filter { $0.kind == .bindingConfirmed }.count, 2)
    print("TASK-M1-007 policy_bypass_vectors=3 durable_confirmed=0 explicit_user_tcp=1")
  }

  func testTEST_AC_DEV_006_01_FailedBindingConfirmationMintsNoDurableReceipt() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let counter = SynchronizedFaultCounter(failAtJournalAppend: 2)
    let faultingJournal = try FileDurableJournal(
      url: fixture.layout.journalURL,
      faultInjector: DurabilityFaultInjector { point in try counter.check(point) })
    var adapter: DeviceBindingJournalAdapter? = try DeviceBindingJournalAdapter(
      history: initialHistory(),
      journal: faultingJournal,
      auditStore: FileDurableSessionAuditStore(layout: fixture.layout),
      replay: DurableJournalRecovery.inspect(url: fixture.layout.journalURL),
      timestamp: fixedTimestamp)

    do {
      _ = try await XCTUnwrap(adapter).persistInitialBinding()
      XCTFail("faulted binding confirmation unexpectedly returned a durable receipt")
    } catch is SyntheticBindingFault {
      // Expected: candidate and audit may be durable, but bindingConfirmed is absent.
    }
    print("TASK-M1-007 confirmation_fault durable_receipt_count=0")
    adapter = nil
    XCTAssertThrowsError(
      try DeviceBindingJournalAdapter.reopen(
        layout: fixture.layout, targetID: "device-A", timestamp: fixedTimestamp)
    ) { error in
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .incompleteDurableBindingChain(1))
    }

    let retryFixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: retryFixture.container) }
    let retryCounter = SynchronizedFaultCounter(failAtJournalAppend: 4)
    let retryJournal = try FileDurableJournal(
      url: retryFixture.layout.journalURL,
      faultInjector: DurabilityFaultInjector { point in try retryCounter.check(point) })
    var retryAdapter: DeviceBindingJournalAdapter? = try DeviceBindingJournalAdapter(
      history: initialHistory(),
      journal: retryJournal,
      auditStore: FileDurableSessionAuditStore(layout: retryFixture.layout),
      replay: DurableJournalRecovery.inspect(url: retryFixture.layout.journalURL),
      timestamp: fixedTimestamp)
    _ = try await XCTUnwrap(retryAdapter).persistInitialBinding()
    let abandonedCandidate = try rebindCandidate(
      id: "abandoned-candidate", key: "synthetic-usb-abandoned", serial: "SERIAL-A")
    do {
      _ = try await XCTUnwrap(retryAdapter).persistRebind(
        candidate: abandonedCandidate,
        binding: binding(
          revision: 2,
          key: abandonedCandidate.connectKey,
          serial: "SERIAL-A",
          evidence: abandonedCandidate.evidence),
        context: strongUSBContext(abandonedCandidate))
      XCTFail("faulted rebind confirmation unexpectedly returned a durable receipt")
    } catch is SyntheticBindingFault {
      // Expected. A later candidate may safely retry the still-unconfirmed revision.
    }
    let recoveredCandidate = try rebindCandidate(
      id: "recovered-candidate", key: "synthetic-usb-recovered", serial: "SERIAL-A")
    let recoveredBinding = try binding(
      revision: 2,
      key: recoveredCandidate.connectKey,
      serial: "SERIAL-A",
      evidence: recoveredCandidate.evidence)
    let recoveredReceipt = try await XCTUnwrap(retryAdapter).persistRebind(
      candidate: recoveredCandidate,
      binding: recoveredBinding,
      context: strongUSBContext(recoveredCandidate))
    retryAdapter = nil
    let retryReopened = try DeviceBindingJournalAdapter.reopen(
      layout: retryFixture.layout, targetID: "device-A", timestamp: fixedTimestamp)
    let reopenedReceipt = try await retryReopened.currentDurableBinding()
    XCTAssertEqual(reopenedReceipt, recoveredReceipt)
    print("TASK-M1-007 stale_rebind_intents=1 recovered_revision=2")
  }

  private struct Fixture {
    let container: URL
    let layout: SessionLayout
    let mutationLane: DeviceMutationLaneCoordinator
  }

  private func makeFixture(
    sessionID: String = "session-device-binding",
    jobID: String = "job-device-binding",
    mutationLane: DeviceMutationLaneCoordinator = DeviceMutationLaneCoordinator()
  ) throws -> Fixture {
    let container = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-task-m1-007-\(UUID().uuidString)", directoryHint: .isDirectory)
    let root = container.appending(path: "session-device-binding", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: "audit", directoryHint: .isDirectory),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let layout = try SessionLayout(
      sessionID: sessionID, jobID: jobID, root: root)
    let journal = try FileDurableJournal(url: layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: UUID().uuidString,
        sequence: 0,
        sessionID: layout.sessionID,
        jobID: layout.jobID,
        timestamp: fixedTimestamp(),
        executionMode: "execute"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: UUID().uuidString,
        sequence: 1,
        sessionID: layout.sessionID,
        jobID: layout.jobID,
        timestamp: fixedTimestamp(),
        from: .queued,
        to: .preflight,
        reason: "syntheticPreflight"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: UUID().uuidString,
        sequence: 2,
        sessionID: layout.sessionID,
        jobID: layout.jobID,
        timestamp: fixedTimestamp(),
        from: .preflight,
        to: .running,
        reason: "syntheticPreflightPassed"))
    return Fixture(container: container, layout: layout, mutationLane: mutationLane)
  }

  private func makeAdapter(
    fixture: Fixture,
    history: DeviceBindingHistory? = nil
  ) throws -> DeviceBindingJournalAdapter {
    try DeviceBindingJournalAdapter(
      history: history ?? initialHistory(),
      journal: FileDurableJournal(url: fixture.layout.journalURL),
      auditStore: FileDurableSessionAuditStore(layout: fixture.layout),
      replay: DurableJournalRecovery.inspect(url: fixture.layout.journalURL),
      mutationLane: fixture.mutationLane,
      timestamp: fixedTimestamp)
  }

  private func initialHistory(
    targetID: String = "device-A",
    key: String = "synthetic-usb-A",
    serial: String = "SERIAL-A",
    transport: DeviceTransport = .usb,
    mode: String = "normal"
  ) throws -> DeviceBindingHistory {
    let original = try OriginalTargetSnapshot(
      kind: .real,
      connectKey: key,
      transport: transport,
      identitySnapshot: identity(serial: serial, mode: mode))
    return try DeviceBindingHistory(
      targetID: targetID,
      originalTarget: original,
      initialBinding: binding(
        revision: 1,
        key: key,
        serial: serial,
        evidence: ["synthetic:selection", "synthetic:identity"],
        transport: transport,
        mode: mode))
  }

  private func identity(serial: String, mode: String = "normal") throws
    -> DeviceIdentitySnapshot
  {
    try DeviceIdentitySnapshot(attributes: [
      "serial": .string(serial),
      "daemonFingerprint": .string("synthetic-daemon"),
      "usbTopology": .string("synthetic-port-1"),
      "mode": .string(mode),
    ])
  }

  private func binding(
    revision: Int,
    key: String,
    serial: String,
    evidence: [String],
    transport: DeviceTransport = .usb,
    confirmedBy: DeviceBindingConfirmation? = nil,
    mode: String = "normal"
  ) throws -> CurrentDeviceBinding {
    try CurrentDeviceBinding(
      revision: revision,
      connectKey: key,
      transport: transport,
      identitySnapshot: identity(serial: serial, mode: mode),
      evidence: evidence,
      confirmedBy: confirmedBy ?? (revision == 1 ? .user : .corePolicy),
      channelProtection: .unverifiedAssumeUnprotected)
  }

  private func appendSuccessfulTerminalLifecycle(
    fixture: Fixture,
    intents: [DurableHDCDeviceCommandIntent]
  ) throws {
    try appendConfirmedStepOutcomes(
      fixture: fixture,
      intents: intents,
      result: "succeeded")
    let replay = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    var sequence = (replay.lastDurableSequence ?? -1) + 1
    let journal = try FileDurableJournal(url: fixture.layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: UUID().uuidString,
        sequence: sequence,
        sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID,
        timestamp: fixedTimestamp(),
        from: .running,
        to: .finalizing,
        reason: "syntheticMutationJobCompleted"))
    sequence += 1
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: UUID().uuidString,
        sequence: sequence,
        sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID,
        timestamp: fixedTimestamp(),
        from: .finalizing,
        to: .succeeded,
        reason: "syntheticMutationJobFinalized"))
  }

  private func appendConfirmedStepOutcomes(
    fixture: Fixture,
    intents: [DurableHDCDeviceCommandIntent],
    result: String
  ) throws {
    let replay = try DurableJournalRecovery.inspect(url: fixture.layout.journalURL)
    var sequence = (replay.lastDurableSequence ?? -1) + 1
    let journal = try FileDurableJournal(url: fixture.layout.journalURL)
    for intent in intents {
      try journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: UUID().uuidString,
          sequence: sequence,
          sessionID: fixture.layout.sessionID,
          jobID: fixture.layout.jobID,
          timestamp: fixedTimestamp(),
          stepID: intent.intent.step.id,
          attempt: 1,
          correlatesToIntentEventID: intent.journalIntentEventID,
          result: result,
          outcomeCertainty: .confirmed))
      sequence += 1
    }
  }

  private func rebindCandidate(id: String, key: String, serial: String) throws
    -> DeviceRebindCandidate
  {
    try DeviceRebindCandidate(
      candidateID: id,
      connectKey: key,
      transport: .usb,
      identitySnapshot: identity(serial: serial),
      evidence: ["synthetic:serial", "synthetic:fingerprint", "synthetic:topology"],
      usbEvidence: USBRebindEvidence(
        serialMatches: true,
        daemonFingerprintMatches: true,
        topologyMatches: true,
        expectedModeMatches: true,
        modelBuildMatches: true))
  }

  private func mutationStep(id: String) throws -> WorkflowStep {
    try WorkflowStep(
      id: id,
      kind: .rebootDevice,
      declaredEffect: .deviceMutation,
      declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "targetMode": .string("updater"),
        "reason": .string("synthetic-contract"),
      ])
  }

  private func probeStep(id: String) throws -> WorkflowStep {
    try WorkflowStep(
      id: id,
      kind: .probeDevice,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .confirmedDevice,
      arguments: ["evidencePolicy": .string("synthetic-contract")])
  }

  private func strongUSBContext(_ candidate: DeviceRebindCandidate) -> DeviceRebindContext {
    DeviceRebindContext(
      transport: .usb,
      disconnected: true,
      endpointExplicitlyAdded: true,
      expectedModeTransition: true,
      candidates: [candidate])
  }

  private func string(_ key: String, in value: JSONValue) -> String? {
    guard case .object(let object) = value, case .string(let result)? = object[key] else {
      return nil
    }
    return result
  }

  private func integer(_ key: String, in value: JSONValue) -> Int? {
    guard case .object(let object) = value, case .integer(let result)? = object[key] else {
      return nil
    }
    return Int(exactly: result)
  }

  private func nestedString(
    _ key: String,
    objectKey: String,
    in value: JSONValue
  ) -> String? {
    guard case .object(let object) = value,
      case .object(let nested)? = object[objectKey],
      case .string(let result)? = nested[key]
    else { return nil }
    return result
  }

  private func assertDispatchRejected(
    _ intent: DurableHDCDeviceCommandIntent,
    through adapter: DeviceBindingJournalAdapter,
    dispatcher: CountingDeviceDispatcher,
    expected: DeviceBindingJournalAdapterError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await HDCDeviceCommandExecutionGate.dispatch(
        intent,
        through: adapter,
        using: dispatcher)
      XCTFail("dispatch unexpectedly succeeded", file: file, line: line)
    } catch {
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        expected,
        file: file,
        line: line)
    }
  }

  private func assertRebindRejected(
    adapter: DeviceBindingJournalAdapter,
    candidate: DeviceRebindCandidate,
    binding: CurrentDeviceBinding,
    context: DeviceRebindContext,
    expected: DeviceRebindAuthorizationError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await adapter.persistRebind(
        candidate: candidate,
        binding: binding,
        context: context)
      XCTFail("policy-bypassing rebind unexpectedly persisted", file: file, line: line)
    } catch {
      XCTAssertEqual(
        error as? DeviceBindingJournalAdapterError,
        .rebindNotAuthorized(expected),
        file: file,
        line: line)
    }
  }

}

private actor CountingDeviceDispatcher: HDCDeviceCommandDispatching {
  private var commands: [HDCDeviceCommand] = []

  func dispatch(_ command: HDCDeviceCommand) async throws -> HDCDeviceCommandDispatchReceipt {
    commands.append(command)
    return HDCDeviceCommandDispatchReceipt(
      journalIntentEventID: command.journalIntentEventID,
      stepID: command.stepID,
      bindingReference: command.bindingReference,
      actualArguments: command.arguments)
  }

  func dispatchCount() -> Int { commands.count }
}

private actor BlockingDeviceDispatcher: HDCDeviceCommandDispatching {
  struct Snapshot: Equatable, Sendable {
    let started: Int
    let maximumConcurrent: Int
  }

  private struct StartWaiter {
    let expected: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private var active = 0
  private var maximumConcurrent = 0
  private var started = 0
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
  private var startWaiters: [StartWaiter] = []

  func dispatch(_ command: HDCDeviceCommand) async throws -> HDCDeviceCommandDispatchReceipt {
    active += 1
    started += 1
    maximumConcurrent = max(maximumConcurrent, active)
    let readyWaiters = startWaiters.filter { started >= $0.expected }
    startWaiters.removeAll { started >= $0.expected }
    for waiter in readyWaiters {
      waiter.continuation.resume()
    }

    await withCheckedContinuation { continuation in
      releaseContinuations.append(continuation)
    }
    active -= 1
    return HDCDeviceCommandDispatchReceipt(
      journalIntentEventID: command.journalIntentEventID,
      stepID: command.stepID,
      bindingReference: command.bindingReference,
      actualArguments: command.arguments)
  }

  func waitUntilStarted(_ expected: Int) async {
    guard started < expected else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(StartWaiter(expected: expected, continuation: continuation))
    }
  }

  func releaseOne() {
    guard !releaseContinuations.isEmpty else { return }
    releaseContinuations.removeFirst().resume()
  }

  func snapshot() -> Snapshot {
    Snapshot(started: started, maximumConcurrent: maximumConcurrent)
  }
}

private struct SyntheticBindingFault: Error {}

private final class SynchronizedFaultCounter: @unchecked Sendable {
  private let lock = NSLock()
  private let failAtJournalAppend: Int
  private var journalAppends = 0

  init(failAtJournalAppend: Int) {
    self.failAtJournalAppend = failAtJournalAppend
  }

  func check(_ point: DurabilityFaultPoint) throws {
    guard point == .journalAppend else { return }
    lock.lock()
    journalAppends += 1
    let shouldFail = journalAppends == failAtJournalAppend
    lock.unlock()
    if shouldFail { throw SyntheticBindingFault() }
  }
}

private func fixedTimestamp() -> String { "2026-07-19T00:00:00Z" }
