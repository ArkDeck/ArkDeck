import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import Foundation

package struct HeadlessHDCToolSelectionLifecycleDriver:
  RuntimeToolSelectionLifecycleDriving
{
  private let oldExecutable: ResolvedExecutable
  private let endpoint: HDCServerEndpointSelection
  private let engine: RuntimeJobEngine
  private let supervisor: HDCServerSupervisor
  private let auditRouter: RuntimeHDCControlLifecycleAuditRouter
  private let expectConfirmedLifecycleExit: @Sendable () -> Void
  private let registry: any RuntimeToolSelectionRegistryControlling
  private let requestDaemonRecomposition: @Sendable () -> Void

  package init(
    oldExecutable: ResolvedExecutable,
    endpoint: HDCServerEndpointSelection,
    engine: RuntimeJobEngine,
    supervisor: HDCServerSupervisor,
    auditRouter: RuntimeHDCControlLifecycleAuditRouter,
    expectConfirmedLifecycleExit: @escaping @Sendable () -> Void,
    registry: any RuntimeToolSelectionRegistryControlling,
    requestDaemonRecomposition: @escaping @Sendable () -> Void
  ) {
    self.oldExecutable = oldExecutable
    self.endpoint = endpoint
    self.engine = engine
    self.supervisor = supervisor
    self.auditRouter = auditRouter
    self.expectConfirmedLifecycleExit = expectConfirmedLifecycleExit
    self.registry = registry
    self.requestDaemonRecomposition = requestDaemonRecomposition
  }

  package func acquireFinalInterlock() async throws -> any HDCControlLifecycleInterlock {
    RuntimeHDCLifecycleInterlockOwner(
      engine: engine, lease: try await engine.acquireHDCLifecycleInterlock())
  }

  package func noteLaunchWindowEntered() { expectConfirmedLifecycleExit() }

  package func restartWithSelectedTool(
    approved: RuntimeToolSelectionControlActionRecord,
    reading: RuntimeToolSelectionImpactReading,
    audit: RuntimeToolSelectionLifecycleAuditStore
  ) async throws {
    let newExecutable = try registry.prepare(
      actionID: approved.actionID, newToolRef: approved.intent.newToolRef,
      expectedActiveGeneration: approved.intent.expectedActiveGeneration)
    do {
      let expected = try expectedSnapshot(approved: approved, reading: reading)
      try await dispatch(
        expected: expected, newExecutable: newExecutable, audit: audit)
      requestDaemonRecomposition()
    } catch {
      if audit.launchWindowWasEntered() {
        // The accepted executor entered its launch window. The next daemon
        // must read back/publish or retain pending; replay is forbidden.
        requestDaemonRecomposition()
      } else {
        _ = try? registry.failPending(
          actionID: approved.actionID,
          reasonCode: "tool.lifecycleFailedBeforeLaunch")
      }
      throw error
    }
  }

  private func dispatch(
    expected: HDCServerImpactSnapshot,
    newExecutable: ResolvedExecutable,
    audit: RuntimeToolSelectionLifecycleAuditStore
  ) async throws {
    let participants =
      expected.affectedDeviceCoordinators.map {
        (
          HDCServerRecipient(id: $0, kind: .deviceCoordinator, endpoint: endpoint.endpoint),
          HDCServerCriticalState.none
        )
      }
      + expected.affectedJobs.map {
        (
          HDCServerRecipient(id: $0, kind: .job, endpoint: endpoint.endpoint),
          HDCServerCriticalState.none
        )
      }
    guard expected.affectedJobs.isEmpty,
      await supervisor.replaceParticipants(participants, for: endpoint.endpoint)
    else {
      throw HDCControlValue.failure(
        "factsDrifted", "final HDC participant inventory contains current Jobs")
    }
    await supervisor.setOtherClientDetection(
      expected.otherClientDetection, for: endpoint.endpoint)

    let oldTool = HDCCandidate(
      path: URL(filePath: oldExecutable.path), source: .userConfigured,
      sha256: oldExecutable.sha256)
    let observed = await HDCServerProcessSupervisor(supervisor: supervisor)
      .observeRegisteredExistingServer(endpoint: endpoint, toolchain: oldTool)
    guard case .observed(let generation, _) = observed.classification,
      generation == expected.generation,
      let state = await supervisor.state(for: endpoint.endpoint),
      state.health == .healthy, state.generation == expected.generation,
      state.ownership == expected.ownership
    else {
      throw HDCControlValue.failure(
        "factsDrifted", "managed HDC differs from the approved old tool and generation")
    }

    let binding = try auditRouter.bind(audit)
    defer { try? auditRouter.unbind(binding) }
    let lifecyclePreview: HDCServerLifecycleImpactPreview
    switch await supervisor.createImpactPreview(
      action: .restartConfirmedGeneration, endpoint: endpoint.endpoint)
    {
    case .ready(let preview):
      guard preview.snapshot == expected else {
        throw HDCControlValue.failure(
          "factsDrifted", "accepted HDC lifecycle scope differs from the tool-selection preview")
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
    let newTool = HDCCandidate(
      path: URL(filePath: newExecutable.path), source: .userConfigured,
      sha256: newExecutable.sha256)
    let executor = HDCProcessLifecycleExecutor(
      toolchain: newTool, endpointSelection: endpoint,
      durableAuthorization: auditRouter, supervisor: supervisor,
      postDispatchProbe: { [newTool, endpoint] step in
        await Self.postDispatchProbe(toolchain: newTool, endpoint: endpoint, step: step)
      })
    switch await supervisor.dispatch(
      confirmationID: confirmation.id, coreStep: coreStep, using: executor)
    {
    case .completed: return
    case .blocked(let block):
      if try audit.record().state == "outcomeUnknown" { return }
      throw HDCControlValue.failure(
        "admissionDenied",
        "selected HDC lifecycle dispatch was blocked: \(String(describing: block))")
    }
  }

  private func expectedSnapshot(
    approved: RuntimeToolSelectionControlActionRecord,
    reading: RuntimeToolSelectionImpactReading
  ) throws -> HDCServerImpactSnapshot {
    guard let preview = approved.preview, preview.impact == reading.impact,
      approved.value["observationRelations"] == .array(reading.observationRelations),
      reading.impact.hdc.criticalGateIsClear,
      reading.blockerReasonCode == nil,
      reading.impact.hdc.value["serverEndpointRef"]
        == .string("hdc-endpoint:" + SHA256Hex.string(of: Data(endpoint.endpoint.rawValue.utf8))),
      reading.impact.hdc.value["endpoint"] == .string(endpoint.endpoint.rawValue),
      reading.impact.hdc.value["serverHealth"] == .string("healthy"),
      case .string(let generationText)? = reading.impact.hdc.value["serverGeneration"],
      let generation = Int(generationText),
      case .string(let ownershipText)? = reading.impact.hdc.value["serverOwnership"],
      let ownership = HDCServerOwnership(rawValue: ownershipText),
      let targets = Self.stringArray(reading.impact.hdc.value["affectedTargetIds"]),
      let jobs = Self.stringArray(reading.impact.hdc.value["affectedJobIds"]), jobs.isEmpty,
      let clients = Self.stringArray(reading.impact.hdc.value["detectedOtherClientIds"]),
      case .bool(let clientsMayExist)? = reading.impact.hdc.value["otherClientsMayExist"]
    else {
      throw HDCControlValue.failure(
        "factsDrifted", "tool-selection impact cannot reproduce the accepted HDC scope")
    }
    let detection: HDCServerOtherClientDetection
    if !clients.isEmpty {
      detection = .detected(clients)
    } else if clientsMayExist {
      detection = .unavailableExternalClientsMayStillExist
    } else {
      detection = .noneDetectedExternalClientsMayStillExist
    }
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
    let values = rows.compactMap {
      if case .string(let value) = $0 { return value }
      return nil
    }
    guard values.count == rows.count, values == values.sorted(), Set(values).count == values.count
    else { return nil }
    return values
  }

  private static func postDispatchProbe(
    toolchain: HDCCandidate,
    endpoint: HDCServerEndpointSelection,
    step: HDCServerLifecycleStep
  ) async -> HDCServerLifecyclePostDispatchObservation? {
    let deadline = ContinuousClock().now.advanced(by: .seconds(12))
    while ContinuousClock().now < deadline {
      if Task.isCancelled { return nil }
      let observation = await HDCCommandlessServerIdentity.observe(
        toolchain: toolchain, endpoint: endpoint.endpoint)
      if case .observed(let generation) = observation.classification,
        let expected = step.expectedGeneration, generation > expected
      {
        return .generation(generation)
      }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
    }
    return nil
  }
}
