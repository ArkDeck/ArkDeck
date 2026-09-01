import ArkDeckCore
import ArkDeckOpenHarmony
import Foundation

package protocol HDCControlLifecycleInterlock: Sendable {
  func release() async throws
}

package protocol HDCControlLifecycleDriving: Sendable {
  func acquireFinalInterlock() async throws -> any HDCControlLifecycleInterlock
  func noteLaunchWindowEntered()
  func restart(
    approved: HDCControlActionRecord,
    reading: HDCControlImpactReading,
    audit: RuntimeHDCControlLifecycleAuditStore
  ) async throws -> HDCControlActionRecord
}

package final class RuntimeHDCLifecycleInterlockOwner:
  HDCControlLifecycleInterlock, @unchecked Sendable
{
  private let engine: RuntimeJobEngine
  private let lease: RuntimeHDCLifecycleInterlockLease
  private let lock = NSLock()
  private var released = false

  init(engine: RuntimeJobEngine, lease: RuntimeHDCLifecycleInterlockLease) {
    self.engine = engine
    self.lease = lease
  }

  package func release() async throws {
    let firstRelease = lock.withLock { () -> Bool in
      guard !released else { return false }
      released = true
      return true
    }
    guard firstRelease else {
      throw HDCControlValue.failure(
        "resourceConflict", "HDC lifecycle final interlock was already released")
    }
    try await engine.releaseHDCLifecycleInterlock(lease)
  }
}

package struct HeadlessHDCControlLifecycleDriver: HDCControlLifecycleDriving {
  private let executable: ResolvedExecutable
  private let endpoint: HDCServerEndpointSelection
  private let engine: RuntimeJobEngine
  private let supervisor: HDCServerSupervisor
  private let auditRouter: RuntimeHDCControlLifecycleAuditRouter
  private let expectConfirmedLifecycleExit: @Sendable () -> Void

  package init(
    executable: ResolvedExecutable,
    endpoint: HDCServerEndpointSelection,
    expectConfirmedLifecycleExit: @escaping @Sendable () -> Void,
    engine: RuntimeJobEngine,
    supervisor: HDCServerSupervisor,
    auditRouter: RuntimeHDCControlLifecycleAuditRouter
  ) {
    self.executable = executable
    self.endpoint = endpoint
    self.expectConfirmedLifecycleExit = expectConfirmedLifecycleExit
    self.engine = engine
    self.supervisor = supervisor
    self.auditRouter = auditRouter
  }

  package func acquireFinalInterlock() async throws -> any HDCControlLifecycleInterlock {
    RuntimeHDCLifecycleInterlockOwner(
      engine: engine, lease: try await engine.acquireHDCLifecycleInterlock())
  }

  package func noteLaunchWindowEntered() {
    expectConfirmedLifecycleExit()
  }

  package func restart(
    approved: HDCControlActionRecord,
    reading: HDCControlImpactReading,
    audit: RuntimeHDCControlLifecycleAuditStore
  ) async throws -> HDCControlActionRecord {
    let expected = try expectedSnapshot(approved: approved, reading: reading)
    let binding = try auditRouter.bind(audit)
    do {
      let record = try await restartBound(expected: expected, audit: audit)
      try auditRouter.unbind(binding)
      return record
    } catch {
      try? auditRouter.unbind(binding)
      throw error
    }
  }

  private func restartBound(
    expected: HDCServerImpactSnapshot,
    audit: RuntimeHDCControlLifecycleAuditStore
  ) async throws -> HDCControlActionRecord {
    let participants = expected.affectedDeviceCoordinators.map {
      (HDCServerRecipient(id: $0, kind: .deviceCoordinator, endpoint: endpoint.endpoint),
        HDCServerCriticalState.none)
    } + expected.affectedJobs.map {
      (HDCServerRecipient(id: $0, kind: .job, endpoint: endpoint.endpoint),
        HDCServerCriticalState.none)
    }
    guard expected.affectedJobs.isEmpty,
      await supervisor.replaceParticipants(participants, for: endpoint.endpoint)
    else {
      throw HDCControlValue.failure(
        "factsDrifted", "the final HDC participant inventory contains current Jobs")
    }
    await supervisor.setOtherClientDetection(
      expected.otherClientDetection, for: endpoint.endpoint)

    let toolchain = HDCCandidate(
      path: URL(filePath: executable.path), source: .userConfigured,
      sha256: executable.sha256)
    let observed = await HDCServerProcessSupervisor(supervisor: supervisor)
      .observeRegisteredExistingServer(endpoint: endpoint, toolchain: toolchain)
    guard case .observed(let generation, _) = observed.classification,
      generation == expected.generation,
      let state = await supervisor.state(for: endpoint.endpoint),
      state.health == .healthy, state.generation == expected.generation,
      state.ownership == expected.ownership
    else {
      throw HDCControlValue.failure(
        "factsDrifted", "the shared HDC Supervisor differs from the approved server identity")
    }

    let lifecyclePreview: HDCServerLifecycleImpactPreview
    switch await supervisor.createImpactPreview(
      action: .restartConfirmedGeneration, endpoint: endpoint.endpoint)
    {
    case .ready(let preview):
      guard preview.snapshot == expected else {
        throw HDCControlValue.failure(
          "factsDrifted", "the accepted HDC lifecycle scope differs from the approved preview")
      }
      lifecyclePreview = preview
    case .blocked(let block):
      throw HDCControlValue.failure(
        "admissionDenied", "HDC lifecycle preview was blocked: \(String(describing: block))")
    }

    let confirmation: HDCServerLifecycleConfirmation
    switch await supervisor.confirm(lifecyclePreview.id) {
    case .accepted(let accepted): confirmation = accepted
    case .blocked(let block):
      throw HDCControlValue.failure(
        "factsDrifted", "HDC lifecycle confirmation was blocked: \(String(describing: block))")
    }
    let coreStep = try HDCServerLifecycleStep.coreWorkflowStep(confirmation: confirmation)
    let executor = HDCProcessLifecycleExecutor(
      toolchain: toolchain, endpointSelection: endpoint,
      durableAuthorization: auditRouter, supervisor: supervisor,
      postDispatchProbe: { [toolchain, endpoint] step in
        await Self.postDispatchProbe(
          toolchain: toolchain, endpoint: endpoint, step: step)
      })
    switch await supervisor.dispatch(
      confirmationID: confirmation.id, coreStep: coreStep, using: executor)
    {
    case .completed:
      return try audit.record()
    case .blocked(let block):
      let record = try audit.record()
      if record.state == "failed" { return record }
      throw HDCControlValue.failure(
        "admissionDenied", "HDC lifecycle dispatch was blocked: \(String(describing: block))",
        details: ["controlAction": record.projection])
    }
  }

  private func expectedSnapshot(
    approved: HDCControlActionRecord,
    reading: HDCControlImpactReading
  ) throws -> HDCServerImpactSnapshot {
    guard let preview = approved.preview,
      preview.impact == reading.impact,
      approved.value["observationRelations"] == .array(reading.observationRelations),
      reading.impact.criticalGateIsClear,
      reading.blockerReasonCode == nil,
      reading.impact.value["serverEndpointRef"] == .string(approved.intent.endpointReference),
      reading.impact.value["endpoint"] == .string(endpoint.endpoint.rawValue),
      reading.impact.value["serverHealth"] == .string("healthy"),
      case .string(let generationText)? = reading.impact.value["serverGeneration"],
      let generation = Int(generationText), generation == approved.intent.expectedGeneration,
      case .string(let ownershipText)? = reading.impact.value["serverOwnership"],
      let ownership = HDCServerOwnership(rawValue: ownershipText),
      let targets = Self.stringArray(reading.impact.value["affectedTargetIds"]),
      let jobs = Self.stringArray(reading.impact.value["affectedJobIds"]), jobs.isEmpty,
      let clients = Self.stringArray(reading.impact.value["detectedOtherClientIds"]),
      case .bool(let clientsMayExist)? = reading.impact.value["otherClientsMayExist"]
    else {
      throw HDCControlValue.failure(
        "factsDrifted", "final HDC impact cannot reproduce the approved lifecycle scope")
    }
    let detection: HDCServerOtherClientDetection
    if !clients.isEmpty { detection = .detected(clients) }
    else if clientsMayExist { detection = .unavailableExternalClientsMayStillExist }
    else { detection = .noneDetectedExternalClientsMayStillExist }
    return HDCServerImpactSnapshot(
      action: .restartConfirmedGeneration, endpoint: endpoint.endpoint,
      generation: generation, ownership: ownership,
      affectedDeviceCoordinators: targets, affectedJobs: jobs,
      otherClientDetection: detection,
      expectedInterruption: "HDC requests using this endpoint will be interrupted.",
      recoveryPath: "Re-probe the shared endpoint and reconcile every affected Job.")
  }

  private static func stringArray(_ value: JSONValue?) -> [String]? {
    guard case .array(let rows)? = value else { return nil }
    let values = rows.compactMap { row -> String? in
      guard case .string(let value) = row, !value.isEmpty else { return nil }
      return value
    }
    guard values.count == rows.count, values == values.sorted(),
      Set(values).count == values.count else { return nil }
    return values
  }

  private static func postDispatchProbe(
    toolchain: HDCCandidate,
    endpoint: HDCServerEndpointSelection,
    step: HDCServerLifecycleStep
  ) async -> HDCServerLifecyclePostDispatchObservation? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(12))
    while clock.now < deadline {
      if Task.isCancelled { return nil }
      let observation = await HDCCommandlessServerIdentity.observe(
        toolchain: toolchain, endpoint: endpoint.endpoint)
      if case .observed(let generation) = observation.classification,
        let expected = step.expectedGeneration, generation > expected
      {
        return .generation(generation)
      }
      do { try await Task.sleep(for: .milliseconds(100)) }
      catch { return nil }
    }
    return nil
  }
}
