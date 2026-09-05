// arkdeck-agentd: local device-runtime control plane (CHG-2026-047, T07).
//
// One composition root for device execution. Transport is a user-private
// Unix domain socket (0700 directory, 0600 socket, zero network listeners)
// carrying a versioned JSON line protocol; the method table is closed and
// the handler is transport-free so contract tests drive it directly.
// Single-instance: an flock'd lock plus an instance document - a second
// start returns the existing instance's info instead of competing.

import ArkDeckCore
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation

package struct RuntimeControlRequestContext: Sendable, Equatable {
  package enum Transport: String, Sendable { case direct, unixSocket, appXPC }
  package let transport: Transport
  package let hasForegroundConsole: Bool

  package static let direct = Self(transport: .direct, hasForegroundConsole: false)
  package static let appXPC = Self(transport: .appXPC, hasForegroundConsole: false)
  package static func unixSocket(foregroundConsole: Bool) -> Self {
    Self(transport: .unixSocket, hasForegroundConsole: foregroundConsole)
  }
}

// MARK: - Wire protocol (v1)

package enum AgentWireProtocol {
  public static let version = ArkDeckAgentXPC.wireProtocolVersion

  package struct Request: Codable, Sendable {
    package let protocolVersion: String
    package let contractIdentity: String
    public let id: String
    public let method: String
    package let params: [String: JSONValue]?

    public init(id: String, method: String, params: [String: JSONValue]? = nil) {
      self.protocolVersion = AgentWireProtocol.version
      self.contractIdentity = ArkDeckControlProtocol.contractIdentity
      self.id = id
      self.method = method
      self.params = params
    }
  }

  package struct WireError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    let details: [String: JSONValue]?

    init(code: String, message: String, details: [String: JSONValue]? = nil) {
      self.code = code
      self.message = message
      self.details = details
    }
  }

  package struct Response: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: WireError?
  }
}

package enum AgentDaemonErrorCode: String, Sendable {
  case unsupportedProtocolVersion
  case malformedFrame
  case unknownMethod
  case invalidParams
  case rejected
  case conflict
  case notFound
  /// §7.9's own code for an unknown project or preset reference.
  ///
  /// Distinct from `notFound` because the two send a caller somewhere
  /// different: `notFound` is a durable record that does not exist, while this
  /// is a reference that is not registered on *this host* — the fix is
  /// `workspace project list`, not a different identity.
  case workspaceReferenceNotFound
  case recordUnreadable
  case internalError
}

// MARK: - Handler (transport-free)

public struct RuntimeControlPlaneHandler: Sendable {
  private let engine: RuntimeJobEngine
  private let capabilityStore: RuntimeCapabilityStore
  private let providerIDs: [String]
  private let nowUTC: @Sendable () -> String
  private let targetStore: RuntimeTargetStore?
  private let bootstrap: DeviceBootstrapMachine?
  private let targetObservations: TargetObservationCoordinator?
  private let agentExecutions: RuntimeAgentExecutionCoordinator?
  private let humanActionResources: RuntimeHumanActionResourceCoordinator?
  private let hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics?
  private let hdcStatusObserver: (any HDCStatusObserving)?
  private let hdcControlActions: RuntimeHDCControlActionCoordinator?
  private let toolSelectionActions: RuntimeToolSelectionControlActionCoordinator?
  private let controlActions: RuntimeControlActionResourceCoordinator?
  private let artifactStore: RuntimeArtifactStore?
  private let historyFilterStore: RuntimeHistoryFilterStore?
  private let runtimeSessionStorage: RuntimeSessionStorageStore?
  private let traceCacheMaintenance: (any RuntimeTraceCacheMaintaining)?
  private let traceInspector: (any RuntimeTraceInspecting)?
  private let flashPrerequisiteObserver: (any RockchipFlashPrerequisiteObserving)?
  private let flashLanePlanPreviewer: (any FlashLanePlanPreviewing)?
  private let rockchipBootloaderStatusObserver: (any RockchipBootloaderStatusObserving)?
  private let rockchipDeviceAccessObserver: (any RockchipDeviceAccessObserving)?
  private let rockchipLoaderBindingCoordinator: (any RockchipLoaderBindingCoordinating)?
  private let traceRuntimeProbe: (any TraceRuntimeProbing)?
  private let debugRuntimeProbe: (any DebugRuntimeProbing)?
  private let debugInvocationController: RuntimeDebugInvocationController?
  private let importGateway = RuntimeImportControlGateway()
  /// Test seam: records which methods a client invoked. Production passes
  /// nil, so this cannot affect behaviour.
  /// The workspace projects this daemon actually derived a profile for.
  ///
  /// §7.9 asks `workspace project list/show` to project the daemon's *current
  /// registered configuration*, which is exactly this — not the environment
  /// variable it was configured from. A root the daemon was told about but
  /// could not derive a profile for is not registered, and the pair of
  /// properties keeps those two facts apart instead of letting an empty list
  /// stand for both "none configured" and "configured but unusable".
  private let durableImportFlashPolicy: FlashBundleImportPolicy
  private let workspaceProjects: [WorkspaceProjectPublication]
  private let methodObserver: (@Sendable (String) -> Void)?
  /// Test seam: receives every dispatched request with its response. Production
  /// passes nil; a debug build may install the environment-driven recorder
  /// (`ControlFrameRecorder`) so a contract-test run leaves the frame corpus the
  /// per-method schemas are derived from and checked against.
  private let frameObserver: (@Sendable (ControlFrameRecord) -> Void)?

  public init(
    engine: RuntimeJobEngine,
    capabilityStore: RuntimeCapabilityStore,
    providerIDs: [String],
    nowUTC: @escaping @Sendable () -> String,
    targetStore: RuntimeTargetStore? = nil,
    bootstrap: DeviceBootstrapMachine? = nil,
    targetObservations: TargetObservationCoordinator? = nil,
    agentExecutions: RuntimeAgentExecutionCoordinator? = nil,
    humanActionResources: RuntimeHumanActionResourceCoordinator? = nil,
    hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics? = nil,
    hdcStatusObserver: (any HDCStatusObserving)? = nil,
    hdcControlActions: RuntimeHDCControlActionCoordinator? = nil,
    toolSelectionActions: RuntimeToolSelectionControlActionCoordinator? = nil,
    controlActions: RuntimeControlActionResourceCoordinator? = nil,
    artifactStore: RuntimeArtifactStore? = nil,
    historyFilterStore: RuntimeHistoryFilterStore? = nil,
    runtimeSessionStorage: RuntimeSessionStorageStore? = nil,
    traceCacheMaintenance: (any RuntimeTraceCacheMaintaining)? = nil,
    traceInspector: (any RuntimeTraceInspecting)? = nil,
    flashBundleImportDirectory: URL? = nil,
    flashPrerequisiteObserver: (any RockchipFlashPrerequisiteObserving)? = nil,
    flashLanePlanPreviewer: (any FlashLanePlanPreviewing)? = nil,
    rockchipBootloaderStatusObserver: (any RockchipBootloaderStatusObserving)? = nil,
    rockchipDeviceAccessObserver: (any RockchipDeviceAccessObserving)? = nil,
    rockchipLoaderBindingCoordinator: (any RockchipLoaderBindingCoordinating)? = nil,
    traceRuntimeProbe: (any TraceRuntimeProbing)? = nil,
    debugRuntimeProbe: (any DebugRuntimeProbing)? = nil,
    debugInvocationController: RuntimeDebugInvocationController? = nil,
    workspaceProjects: [WorkspaceProjectPublication] = [],
    methodObserver: (@Sendable (String) -> Void)? = nil
  ) {
    self.init(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providerIDs, nowUTC: nowUTC,
      targetStore: targetStore, bootstrap: bootstrap, targetObservations: targetObservations,
      agentExecutions: agentExecutions,
      humanActionResources: humanActionResources,
      hdcRuntimeDiagnostics: hdcRuntimeDiagnostics,
      hdcStatusObserver: hdcStatusObserver,
      hdcControlActions: hdcControlActions,
      toolSelectionActions: toolSelectionActions,
      controlActions: controlActions,
      artifactStore: artifactStore,
      historyFilterStore: historyFilterStore,
      runtimeSessionStorage: runtimeSessionStorage,
      traceCacheMaintenance: traceCacheMaintenance,
      traceInspector: traceInspector,
      flashBundleImportDirectory: flashBundleImportDirectory,
      flashBundleImportPolicy: .production,
      flashPrerequisiteObserver: flashPrerequisiteObserver,
      flashLanePlanPreviewer: flashLanePlanPreviewer,
      rockchipBootloaderStatusObserver: rockchipBootloaderStatusObserver,
      rockchipDeviceAccessObserver: rockchipDeviceAccessObserver,
      rockchipLoaderBindingCoordinator: rockchipLoaderBindingCoordinator,
      traceRuntimeProbe: traceRuntimeProbe,
      debugRuntimeProbe: debugRuntimeProbe,
      debugInvocationController: debugInvocationController,
      workspaceProjects: workspaceProjects,
      methodObserver: methodObserver)
  }

  init(
    engine: RuntimeJobEngine,
    capabilityStore: RuntimeCapabilityStore,
    providerIDs: [String],
    nowUTC: @escaping @Sendable () -> String,
    targetStore: RuntimeTargetStore?,
    bootstrap: DeviceBootstrapMachine?,
    targetObservations: TargetObservationCoordinator? = nil,
    agentExecutions: RuntimeAgentExecutionCoordinator? = nil,
    humanActionResources: RuntimeHumanActionResourceCoordinator? = nil,
    hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics? = nil,
    hdcStatusObserver: (any HDCStatusObserving)? = nil,
    hdcControlActions: RuntimeHDCControlActionCoordinator? = nil,
    toolSelectionActions: RuntimeToolSelectionControlActionCoordinator? = nil,
    controlActions: RuntimeControlActionResourceCoordinator? = nil,
    artifactStore: RuntimeArtifactStore?,
    historyFilterStore: RuntimeHistoryFilterStore? = nil,
    runtimeSessionStorage: RuntimeSessionStorageStore? = nil,
    traceCacheMaintenance: (any RuntimeTraceCacheMaintaining)? = nil,
    traceInspector: (any RuntimeTraceInspecting)? = nil,
    flashBundleImportDirectory: URL?,
    flashBundleImportPolicy: FlashBundleImportPolicy,
    flashPrerequisiteObserver: (any RockchipFlashPrerequisiteObserving)? = nil,
    flashLanePlanPreviewer: (any FlashLanePlanPreviewing)? = nil,
    rockchipBootloaderStatusObserver: (any RockchipBootloaderStatusObserving)? = nil,
    rockchipDeviceAccessObserver: (any RockchipDeviceAccessObserving)? = nil,
    rockchipLoaderBindingCoordinator: (any RockchipLoaderBindingCoordinating)? = nil,
    traceRuntimeProbe: (any TraceRuntimeProbing)? = nil,
    debugRuntimeProbe: (any DebugRuntimeProbing)? = nil,
    debugInvocationController: RuntimeDebugInvocationController? = nil,
    workspaceProjects: [WorkspaceProjectPublication] = [],
    methodObserver: (@Sendable (String) -> Void)?,
    frameObserver: (@Sendable (ControlFrameRecord) -> Void)? = nil
  ) {
    self.engine = engine
    self.capabilityStore = capabilityStore
    self.providerIDs = providerIDs
    self.nowUTC = nowUTC
    self.targetStore = targetStore
    self.bootstrap = bootstrap
    self.targetObservations = targetObservations
    self.agentExecutions = agentExecutions
    self.humanActionResources = humanActionResources
    self.hdcRuntimeDiagnostics = hdcRuntimeDiagnostics
    self.hdcStatusObserver = hdcStatusObserver
    self.hdcControlActions = hdcControlActions
    self.toolSelectionActions = toolSelectionActions
    self.controlActions = controlActions
    self.artifactStore = artifactStore
    self.historyFilterStore = historyFilterStore
    self.runtimeSessionStorage = runtimeSessionStorage
    self.traceCacheMaintenance = traceCacheMaintenance
    self.traceInspector = traceInspector
    self.flashPrerequisiteObserver = flashPrerequisiteObserver
    self.flashLanePlanPreviewer = flashLanePlanPreviewer
    self.rockchipBootloaderStatusObserver = rockchipBootloaderStatusObserver
    self.rockchipDeviceAccessObserver = rockchipDeviceAccessObserver
    self.rockchipLoaderBindingCoordinator = rockchipLoaderBindingCoordinator
    self.traceRuntimeProbe = traceRuntimeProbe
    self.debugRuntimeProbe = debugRuntimeProbe
    self.debugInvocationController = debugInvocationController
    self.durableImportFlashPolicy = flashBundleImportPolicy
    self.workspaceProjects = workspaceProjects.sorted { $0.projectRef < $1.projectRef }
    self.methodObserver = methodObserver
    self.frameObserver = frameObserver ?? ControlFrameRecorder.environmentObserver()
  }

  public func handleLine(_ line: Data) async -> Data {
    await handleLine(line, context: .direct)
  }

  package func handleLine(
    _ line: Data, context: RuntimeControlRequestContext
  ) async -> Data {
    let response = await handleFrame(line, context: context)
    let encoder = CanonicalJSONEncoders.canonical()
    let payload = (try? encoder.encode(response)) ?? Data("{}".utf8)
    return payload + Data("\n".utf8)
  }

  func handleFrame(_ line: Data) async -> AgentWireProtocol.Response {
    await handleFrame(line, context: .direct)
  }

  private func handleFrame(
    _ line: Data, context: RuntimeControlRequestContext
  ) async -> AgentWireProtocol.Response {
    let request: AgentWireProtocol.Request
    do {
      _ = try ControlProtocolContract.requestFields(line)
      request = try JSONDecoder().decode(AgentWireProtocol.Request.self, from: line)
    } catch ControlProtocolContract.Failure.unsupportedVersion {
      return failure(id: Self.frameID(line), code: .unsupportedProtocolVersion,
        message: "this Runtime requires exactly \(ArkDeckControlProtocol.currentVersion)")
    } catch ControlProtocolContract.Failure.contractMismatch {
      return failure(id: Self.frameID(line), code: .unsupportedProtocolVersion,
        message: "client and Runtime must use the same current control contract")
    } catch {
      return failure(id: "-", code: .malformedFrame, message: "undecodable current request frame")
    }
    guard ArkDeckControlProtocol.methods.contains(request.method) else {
      return failure(id: request.id, code: .unknownMethod, message: "method is not published by this Runtime")
    }
    return await dispatch(request, context: context)
  }

  private static func frameID(_ line: Data) -> String {
    guard let fields = try? ControlFrameJSON.decodeObject(line, maximumBytes: ArkDeckControlProtocol.maximumRequestFrameBytes),
      case .string(let id)? = fields["id"], !id.isEmpty, id.utf8.count <= 128
    else { return "-" }
    return id
  }

  private func dispatch(
    _ request: AgentWireProtocol.Request, context: RuntimeControlRequestContext
  ) async -> AgentWireProtocol.Response {
    let response = await dispatchUnobserved(request, context: context)
    frameObserver?(ControlFrameRecord(request: request, response: response))
    return response
  }

  private func dispatchUnobserved(
    _ request: AgentWireProtocol.Request, context: RuntimeControlRequestContext
  ) async -> AgentWireProtocol.Response {
    methodObserver?(request.method)
    if ["job.plan", "job.submit", "job.run"].contains(request.method)
    {
      return await jobLifecycleRequest(request)
    }
    switch request.method {
    case "agent.run", "agent.status", "agent.list", "agent.abandon", "agent.resume":
      return await agentExecutionRequest(request)
    case "human-action.list", "human-action.show", "human-action.resume":
      return await humanActionRequest(request, context: context)
    case "health":
      guard request.params == nil || request.params?.isEmpty == true else {
        return failure(
          id: request.id, code: .invalidParams, message: "health accepts no parameters")
      }
      return success(
        id: request.id,
        result: .object([
          "status": .string("ok"),
          "protocolVersion": .string(request.protocolVersion),
          "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
          "publishedMethods": .array(
            ArkDeckControlProtocol.methods.sorted().map(JSONValue.string)),
          "catalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
          "providers": .array(providerIDs.map(JSONValue.string)),
        ]))

    case "runtime.hdc.impact-preview", "runtime.hdc.restart", "runtime.tool.select", "control-action.list", "control-action.show", "control-action.reconcile":
      return await hdcControlActionRequest(request)
    case "runtime.storage.status", "runtime.storage.policy", "runtime.storage.root":
      return await RuntimeStorageResourceHandler(
        sessions: runtimeSessionStorage, artifacts: artifactStore
      ).response(request)
    case "session.list", "session.show", "session.pin", "session.unpin", "session.cleanup.preview", "session.cleanup.apply", "session.export.preview", "session.export.apply":
      return await RuntimeSessionResourceHandler(
        storage: runtimeSessionStorage,
        activeSessionIDs: { await engine.activeSessionIDsForRetention() })
        .response(request)
    case "runtime.hdc.status":
      guard request.params == nil || request.params?.isEmpty == true else {
        return failure(id: request.id, code: .invalidParams, message: "live HDC status does not accept caller facts or paths")
      }
      return success(id: request.id, result: await hdcStatusObserver?.snapshot() ?? HeadlessHDCStatusObserver.unconfigured())

    case "operation.list":
      let availability = await engine.operationAvailability()
      return success(
        id: request.id,
        result: .array(
          availability.map { item in
            // §6.1 asks the list to carry alias lineage, effect, binding and
            // profile alongside availability, so an Agent can narrow the
            // catalog without one describe call per operation.
            let descriptor = RuntimeOperationCatalog.descriptor(reference: item.reference)
            return .object([
              "reference": .string(item.reference),
              "canonicalReference": .string(descriptor?.reference ?? item.reference),
              "aliasFor": descriptor?.aliasFor.map(JSONValue.string) ?? .null,
              "minimumEffect": descriptor.map { .string($0.minimumEffect.rawValue) } ?? .null,
              "binding": descriptor.map { .string($0.binding.rawValue) } ?? .null,
              "profiles": .array((descriptor?.profiles ?? []).map(JSONValue.string)),
              "availability": .string(item.state.rawValue),
              "reasons": .array(item.reasons.map(JSONValue.string)),
              // PRODUCT-LOOP §8: the machine-readable half, positionally
              // paired with `reasons`. `reasons` stays for readers that
              // already parse it.
              "reasonCodes": .array(item.reasonCodes.map { .string($0.rawValue) }),
              // Positionally paired the same way, and the field an operator
              // actually acts on: whether configuring this machine can make
              // the operation available at all.
              "reasonOrigins": .array(
                item.reasonCodes.map { .string($0.origin.rawValue) }),
            ])
          }))

    case "operation.describe":
      guard case .string(let reference)? = request.params?["reference"],
        let descriptor = RuntimeOperationCatalog.descriptor(reference: reference)
      else {
        return failure(id: request.id, code: .notFound, message: "unknown operation reference")
      }
      let availability = await engine.operationAvailability()
        .first { $0.reference == descriptor.reference }
      return success(
        id: request.id,
        result: Self.encodeOperationDescriptor(descriptor, availability: availability))

    case "flash.lanePlanPreview":
      // Read-only preview of the arkforged plan the permits would anchor
      // (CHG-2026-068). Never imports, never starts anything; every state is
      // an honest fact the review renders as-is.
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let profileReference)? = request.params?["profileReference"],
        case .string(let archiveSHA256)? = request.params?["archiveSha256"],
        RockchipFlashProfile.board(reference: profileReference) != nil,
        archiveSHA256.count == 64,
        archiveSHA256.allSatisfy(\.isHexDigit)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message:
            "a supported targetId, profileReference and 64-hex archiveSha256 are required")
      }
      guard let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "lane plan preview is not configured")
      }
      do {
        guard let target = try targetStore.find(targetID: targetID) else {
          return failure(id: request.id, code: .notFound, message: "target is not adopted")
        }
        var fields: [String: JSONValue] = [
          "targetId": .string(target.targetID),
          "bindingRevision": .integer(Int64(target.bindingRevision)),
        ]
        guard let flashLanePlanPreviewer else {
          fields["state"] = .string("laneNotComposed")
          return success(id: request.id, result: .object(fields))
        }
        switch await flashLanePlanPreviewer.preview(
          targetID: target.targetID,
          profileReference: profileReference,
          archiveSHA256: archiveSHA256.lowercased())
        {
        case .available(let planID, let planSHA256, let observationMode):
          fields["state"] = .string("available")
          fields["planId"] = .string(planID)
          fields["planSha256"] = .string(planSHA256)
          fields["observationMode"] = .string(observationMode)
        case .bundleNotInLaneStore:
          fields["state"] = .string("bundleNotInLaneStore")
        case .deviceNotObserved(let reason):
          fields["state"] = .string("deviceNotObserved")
          fields["reason"] = .string(reason)
        case .planNotExecutable(let availability, let reason, let unknowns):
          fields["state"] = .string("planNotExecutable")
          fields["availability"] = .string(availability)
          fields["reason"] = .string(reason)
          fields["unknowns"] = .array(
            unknowns.sorted { $0.key < $1.key }
              .map { .string("\($0.key): \($0.value)") })
        case .previewFailed(let detail):
          fields["state"] = .string("previewFailed")
          fields["reason"] = .string(detail)
        }
        return success(id: request.id, result: .object(fields))
      } catch {
        return failure(
          id: request.id, code: .rejected,
          message: "lane plan preview could not resolve the target: \(error)")
      }

    case "flash.prerequisites":
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let profileReference)? = request.params?["profileReference"],
        RockchipFlashProfile.board(reference: profileReference) != nil
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "a supported targetId and profileReference are required")
      }
      guard let targetStore, let flashPrerequisiteObserver else {
        return failure(
          id: request.id, code: .internalError,
          message: "Flash prerequisite observation is not configured")
      }
      do {
        guard let target = try targetStore.find(targetID: targetID) else {
          return failure(id: request.id, code: .notFound, message: "target is not adopted")
        }
        let observations = try await flashPrerequisiteObserver.observePrerequisites(
          targetID: targetID)
        return success(
          id: request.id,
          result: .object([
            "targetId": .string(target.targetID),
            "bindingRevision": .integer(Int64(target.bindingRevision)),
            "profileReference": .string(profileReference),
            "observations": .array(
              observations.map {
                .object([
                  "identifier": .string($0.identifier.rawValue),
                  "status": .string($0.status.rawValue),
                ])
              }),
          ]))
      } catch {
        return failure(
          id: request.id, code: .rejected,
          message: "Flash prerequisites could not be observed: \(error)")
      }

    case "flash.device-access":
      guard request.params?.isEmpty != false else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "Device access discovery does not accept parameters")
      }
      guard let rockchipDeviceAccessObserver else {
        return failure(
          id: request.id, code: .internalError,
          message: "Rockchip device access observation is not configured")
      }
      do {
        let modes = try rockchipDeviceAccessObserver.observeDeviceAccess()
        return success(
          id: request.id,
          result: .object([
            "observationCount": .integer(Int64(modes.count)),
            "observedModes": .array(modes.map { .string($0.rawValue) }),
          ]))
      } catch {
        // Do not export socket paths, provider diagnostics or USB identities.
        return failure(
          id: request.id, code: .rejected,
          message: "Rockchip device access observation failed")
      }

    case "flash.bootloader-status":
      guard let rockchipBootloaderStatusObserver else {
        return failure(
          id: request.id, code: .internalError,
          message: "Rockchip bootloader status observation is not configured")
      }
      do {
        let status = try rockchipBootloaderStatusObserver.observeBootloaderStatus()
        return success(
          id: request.id,
          result: .object([
            "disposition": .string(status.disposition.rawValue),
            "observationCount": .integer(Int64(status.observationCount)),
            "mode": status.mode.map(JSONValue.string) ?? .null,
            "targetId": status.targetID.map(JSONValue.string) ?? .null,
            "bindingRevision": status.bindingRevision.map { .integer(Int64($0)) } ?? .null,
          ]))
      } catch {
        return failure(
          id: request.id, code: .rejected,
          message: "Rockchip bootloader status could not be observed: \(error)")
      }

    case "flash.bind-current-loader":
      guard case .string(let targetID)? = request.params?["targetId"],
        case .integer(let expectedRevision)? = request.params?["expectedBindingRevision"],
        expectedRevision > 0
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId and expectedBindingRevision are required")
      }
      guard let rockchipLoaderBindingCoordinator else {
        return failure(
          id: request.id, code: .internalError,
          message: "Rockchip Loader binding is not configured")
      }
      do {
        let pendingJobID = try await engine.loaderTransitionAwaitingBinding(
          targetID: targetID,
          expectedBindingRevision: Int(expectedRevision))
        let receipt = try rockchipLoaderBindingCoordinator.bindCurrentLoader(
          targetID: targetID,
          expectedBindingRevision: Int(expectedRevision))
        if let pendingJobID {
          _ = try await engine.settleLoaderTransitionAfterBinding(
            jobID: pendingJobID,
            targetID: receipt.targetID,
            previousBindingRevision: receipt.previousRevision,
            currentBindingRevision: receipt.currentRevision,
            selectionEvidenceSHA256: receipt.selectionEvidenceSHA256)
        }
        return success(
          id: request.id,
          result: .object([
            "targetId": .string(receipt.targetID),
            "previousBindingRevision": .integer(Int64(receipt.previousRevision)),
            "bindingRevision": .integer(Int64(receipt.currentRevision)),
            "updated": .bool(receipt.updated),
            "selectionEvidenceSha256": .string(receipt.selectionEvidenceSHA256),
            "settledJobId": pendingJobID.map(JSONValue.string) ?? .null,
          ]))
      } catch {
        return failure(
          id: request.id, code: .rejected,
          message: "Rockchip Loader binding was refused: \(error)")
      }

    case "trace.probe":
      guard case .string(let targetID)? = request.params?["targetId"] else {
        return failure(
          id: request.id, code: .invalidParams, message: "targetId is required")
      }
      guard let traceRuntimeProbe else {
        return failure(
          id: request.id, code: .internalError,
          message: "Trace Runtime probing is not configured")
      }
      do {
        let snapshot = try await traceRuntimeProbe.probeTraceRuntime(targetID: targetID)
        return success(
          id: request.id,
          result: .object([
            "targetId": .string(snapshot.targetID),
            "bindingRevision": .integer(Int64(snapshot.bindingRevision)),
            "adapterDisposition": .string(snapshot.adapterDisposition),
            "tool": snapshot.tool.map(JSONValue.string) ?? .null,
            "family": snapshot.family.map(JSONValue.string) ?? .null,
            "supportedTags": .array(snapshot.supportedTags.map(JSONValue.string)),
            "rawHelp": snapshot.rawHelp.map(JSONValue.string) ?? .null,
            "rawHelpSha256": snapshot.rawHelpSHA256.map(JSONValue.string) ?? .null,
            "tools": .array(
              snapshot.tools.map { observation in
                .object([
                  "tool": .string(observation.tool),
                  "disposition": .string(observation.disposition.rawValue),
                  "family": observation.family.map(JSONValue.string) ?? .null,
                  "rawHelpSha256": observation.rawHelpSHA256.map(JSONValue.string) ?? .null,
                  "detail": observation.detail.map(JSONValue.string) ?? .null,
                ])
              }),
            "parameters": .array(
              snapshot.parameters.map { observation in
                .object([
                  "name": .string(observation.name),
                  "state": .string(observation.state.rawValue),
                  "value": observation.value.map(JSONValue.string) ?? .null,
                  "detail": observation.detail.map(JSONValue.string) ?? .null,
                ])
              }),
          ]))
      } catch {
        return failure(
          id: request.id, code: .rejected,
          message: "Trace Runtime probe failed: \(error)")
      }

    case "debug.probe":
      let params = request.params ?? [:]
      if Set(params.keys) != ["targetId"]
      {
        return failure(
          id: request.id, code: .invalidParams,
          message: "Debug Runtime probe accepts only targetId")
      }
      guard case .string(let targetID)? = params["targetId"] else {
        return failure(
          id: request.id, code: .invalidParams, message: "targetId is required")
      }
      if targetID.isEmpty || targetID.utf8.count > 128
      {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId must be a bounded durable target identity")
      }
      guard let debugRuntimeProbe else {
        return failure(
          id: request.id, code: .internalError,
          message: "Debug Runtime probing is not configured")
      }
      do {
        let snapshot = try await debugRuntimeProbe.probeDebugRuntime(targetID: targetID)
        let closedWarnings: Set<String> = [
          "packageInventoryUnavailable", "packageInventoryUnparseable",
          "forwardRulesUnavailable", "reverseRulesUnavailable",
        ]
        guard snapshot.targetID == targetID, snapshot.bindingRevision >= 1,
          snapshot.packages.count <= 10_000,
          Set(snapshot.packages).count == snapshot.packages.count,
          snapshot.packages.allSatisfy({
            DebugTypedValueValidator.isValidBundleName($0)
          }),
          snapshot.portRules.count <= 4_096,
          snapshot.portRules.allSatisfy({
            (1_024...65_535).contains($0.localPort)
              && (1_024...65_535).contains($0.remotePort)
          }),
          snapshot.warnings.count <= closedWarnings.count,
          Set(snapshot.warnings).count == snapshot.warnings.count,
          snapshot.warnings.allSatisfy(closedWarnings.contains)
        else {
          return failure(
            id: request.id, code: .internalError,
            message: "Debug Runtime probe returned an invalid bounded projection")
        }

        let packages = snapshot.packages.sorted()
        let portRules = snapshot.portRules.sorted {
            if $0.direction.rawValue != $1.direction.rawValue {
              return $0.direction.rawValue < $1.direction.rawValue
            }
            if $0.localPort != $1.localPort { return $0.localPort < $1.localPort }
            return $0.remotePort < $1.remotePort
          }
        let warnings = snapshot.warnings.sorted()
        var result: [String: JSONValue] = [
          "targetId": .string(snapshot.targetID),
          "bindingRevision": .integer(Int64(snapshot.bindingRevision)),
          "packages": .array(packages.map(JSONValue.string)),
          "portRules": .array(
            portRules.map { rule in
              .object([
                "direction": .string(rule.direction.rawValue),
                "localPort": .integer(Int64(rule.localPort)),
                "remotePort": .integer(Int64(rule.remotePort)),
              ])
            }),
          "warnings": .array(warnings.map(JSONValue.string)),
        ]
        result["schemaVersion"] = .string("arkdeck.debug-probe/1")

        return success(
          id: request.id,
          result: .object(result))
      } catch {
        return failure(
          id: request.id, code: .rejected,
          message: "Debug Runtime probe failed: \(error)")
      }

    case "debug.template.run":
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let templateID)? = request.params?["templateId"],
        let template = DebugRuntimeCommandTemplate(rawValue: templateID)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId and a closed templateId are required")
      }
      guard let debugRuntimeProbe else {
        return failure(
          id: request.id, code: .internalError,
          message: "Debug Runtime probing is not configured")
      }
      do {
        let result = try await debugRuntimeProbe.runDebugTemplate(
          targetID: targetID, template: template)
        return success(
          id: request.id,
          result: .object([
            "targetId": .string(result.targetID),
            "bindingRevision": .integer(Int64(result.bindingRevision)),
            "templateId": .string(result.templateID),
            "effect": .string(result.effect),
            "executable": .string(result.executable),
            "executableSha256": .string(result.executableSHA256),
            "arguments": .array(result.argumentDisclosure.map(JSONValue.string)),
            "loweringSha256": .string(result.loweringSHA256),
            "exitCode": result.exitCode.map { .integer(Int64($0)) } ?? .null,
            "durationMilliseconds": .integer(Int64(result.durationMilliseconds)),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "outputTruncated": .bool(result.outputTruncated),
          ]))
      } catch {
        return failure(
          id: request.id, code: .rejected,
          message: "Debug template failed: \(error)")
      }

    case "capability.list":
      do {
        let statuses = try await capabilityStore.list()
        return success(
          id: request.id,
          result: .array(
            statuses.map { status in
              .object([
                "capabilityId": .string(status.capability.capabilityID),
                "effectCeiling": .string(status.capability.effectCeiling.rawValue),
                "maximumUses": .integer(Int64(status.capability.maximumUses)),
                "remainingUses": .integer(Int64(status.remainingUses)),
                "consumptionCount": .integer(Int64(status.consumptionCount)),
                "lineageAllowsNewExecution": .bool(status.lineageAllowsNewExecution),
                "lineageBlocker": status.lineageBlocker.map(JSONValue.string) ?? .null,
              ])
            }))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "capability.inspect":
      guard case .string(let capabilityID)? = request.params?["capabilityId"] else {
        return failure(id: request.id, code: .invalidParams, message: "capabilityId is required")
      }
      do {
        guard let status = try await capabilityStore.inspect(capabilityID: capabilityID) else {
          return failure(id: request.id, code: .notFound, message: "unknown capability")
        }
        let encoded = try JSONEncoder().encode(status)
        let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
        return success(id: request.id, result: json)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "debug.start":
      guard let debugInvocationController else {
        return failure(
          id: request.id, code: .internalError,
          message: "Runtime debug invocation is not configured")
      }
      guard let params = request.params, Set(params.keys) == ["requestJson"],
        case .string(let requestJSON)? = params["requestJson"]
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "debug.start accepts exactly requestJson")
      }
      do {
        let status = try await debugInvocationController.start(
          seedRequestData: Data(requestJSON.utf8))
        return success(id: request.id, result: try Self.encodeCodable(status))
      } catch let error as RuntimeDebugInvocationError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "debug.evaluate":
      guard let debugInvocationController else {
        return failure(
          id: request.id, code: .internalError,
          message: "Runtime debug invocation is not configured")
      }
      let expected = Set(["invocationId", "actionJson", "sourceSha256", "buildSha256"])
      guard let params = request.params, Set(params.keys) == expected,
        case .string(let invocationID)? = params["invocationId"],
        case .string(let actionJSON)? = params["actionJson"],
        case .string(let sourceSHA256)? = params["sourceSha256"],
        case .string(let buildSHA256)? = params["buildSha256"]
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message:
            "debug.evaluate accepts exactly invocationId, actionJson, sourceSha256 and buildSha256")
      }
      do {
        let provenance = try RuntimeDebugCandidateProvenance(
          sourceSHA256: sourceSHA256, buildSHA256: buildSHA256)
        let status = try await debugInvocationController.evaluate(
          invocationID: invocationID,
          actionData: Data(actionJSON.utf8),
          provenance: provenance)
        return success(id: request.id, result: try Self.encodeCodable(status))
      } catch let error as RuntimeDebugInvocationError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "debug.status":
      guard let debugInvocationController else {
        return failure(
          id: request.id, code: .internalError,
          message: "Runtime debug invocation is not configured")
      }
      guard let params = request.params, Set(params.keys) == ["invocationId"],
        case .string(let invocationID)? = params["invocationId"]
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "debug.status accepts exactly invocationId")
      }
      do {
        return success(
          id: request.id,
          result: try await Self.encodeCodable(
            debugInvocationController.status(invocationID: invocationID)))
      } catch let error as RuntimeDebugInvocationError {
        return failure(
          id: request.id, code: Self.debugInvocationErrorCode(error), message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "recovery.flash-invocation.list":
      guard let debugInvocationController else {
        return failure(
          id: request.id, code: .internalError,
          message: "Runtime Flash invocation owner is not configured")
      }
      let params = request.params ?? [:]
      guard Set(params.keys).isSubset(of: ["pageSize", "cursor"]) else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "Flash invocation list accepts only pageSize and cursor")
      }
      let pageSize: Int
      if let value = params["pageSize"] {
        guard case .integer(let number) = value, (1...1000).contains(number) else {
          return failure(
            id: request.id, code: .invalidParams,
            message: "pageSize must be between 1 and 1000")
        }
        pageSize = Int(number)
      } else {
        pageSize = 100
      }
      let cursor: String?
      if let value = params["cursor"] {
        guard case .string(let text) = value, text.utf8.count <= 256 else {
          return AgentWireProtocol.Response(
            id: request.id, ok: false, result: nil,
            error: .init(
              code: "invalidCursor", message: "cursor must be a bounded opaque string",
              details: [:]))
        }
        cursor = text
      } else {
        cursor = nil
      }
      do {
        return success(
          id: request.id,
          result: try await debugInvocationController.list(
            pageSize: pageSize, cursor: cursor))
      } catch let error as AgentExecutionControlFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(code: error.code, message: error.message, details: [:]))
      } catch let error as RuntimeDebugInvocationError {
        return failure(
          id: request.id, code: Self.debugInvocationErrorCode(error), message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.list":
      return await RuntimeJobResourceReader(engine: engine, artifactStore: artifactStore).response(request)

    case "job.show", "job.result", "job.timeline":
      return await RuntimeJobResourceReader(engine: engine, artifactStore: artifactStore).response(request)

    case "job.events":
      do {
        let fields = request.params ?? [:]
        guard Set(fields.keys).isSubset(of: ["jobId", "afterCursor", "pageSize"]),
          case .string(let jobID)? = fields["jobId"], AgentExecutionIntent.validIdentifier(jobID)
        else { throw AgentExecutionControlFailure("invalidInput", "job.events requires an exact Job identity and closed options") }
        var cursor: String?
        if let value = fields["afterCursor"] {
          guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 2048 else {
            throw AgentExecutionControlFailure("invalidCursor", "afterCursor must be a bounded opaque cursor")
          }
          cursor = text
        }
        var size = 100
        if let value = fields["pageSize"] {
          guard case .integer(let number) = value, (1...1000).contains(number) else {
            throw AgentExecutionControlFailure("invalidInput", "pageSize must be between 1 and 1000")
          }
          size = Int(number)
        }
        return success(id: request.id, result: try await engine.eventPage(jobID: jobID, afterCursor: cursor, pageSize: size))
      } catch let error as AgentExecutionControlFailure {
        return AgentWireProtocol.Response(id: request.id, ok: false, result: nil,
          error: .init(code: error.code, message: error.message, details: [
            "phase": .string("preAdmission"), "newDispatchCount": .integer(0),
          ]))
      } catch RuntimeJobEngineError.jobNotFound {
        return failure(id: request.id, code: .notFound, message: "the referenced Job does not exist")
      } catch {
        return failure(id: request.id, code: .recordUnreadable, message: "the retained Job event history is unreadable")
      }

    case "job.status":
      return await RuntimeJobResourceReader(engine: engine, artifactStore: artifactStore).response(request)

    case "job.evidence":
      return await RuntimeJobResourceReader(engine: engine, artifactStore: artifactStore).response(request)

    case "job.cancel":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        try await engine.requestCancel(jobID: jobID)
        return success(id: request.id, result: .object(["cancelRequested": .bool(true)]))
      } catch RuntimeJobEngineError.jobNotFound {
        return failure(id: request.id, code: .notFound, message: "unknown job \(jobID)")
      } catch let error as RuntimeJobEngineError {
        // The same correction `job.reconcile` already carries below. Cancelling
        // persists a decision, so it can fail long after the job was found —
        // and reporting that as `notFound` tells the caller the job does not
        // exist while its steps may still be running. The caller then has no
        // way to see which gate refused, and no reason to retry. Only a
        // genuinely absent job is notFound.
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.reconcile":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let status = try await engine.reconcile(jobID: jobID)
        return success(id: request.id, result: try RuntimeJobReadProjection.status(status))
      } catch RuntimeJobEngineError.jobNotFound {
        return failure(id: request.id, code: .notFound, message: "unknown job \(jobID)")
      } catch let error as RuntimeJobEngineError {
        // Reconciliation resolves a durable intent against the device: it can
        // fail at facts, evidence or the typed readback long after the job was
        // found. Reporting every one of those as `notFound` denied a job the
        // daemon had just journaled into `reconciling`, and left the operator
        // with no way to see which gate refused. Only a genuinely absent job
        // is notFound; the rest surface like `job.run`.
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "cleanupDebt.list":
      do {
        let debts = try await engine.listCleanupDebt()
        return success(
          id: request.id,
          result: .array(debts.map(Self.encodeCleanupDebt)))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "cleanupDebt.continue":
      // Either shape of residue, one ledger key. `bundleName` is not a
      // free-form uninstall target: the engine refuses any identity that is
      // not already an outstanding record for this job.
      let residueIdentity: String?
      if case .string(let path)? = request.params?["remotePath"] {
        residueIdentity = path
      } else if case .string(let bundle)? = request.params?["bundleName"] {
        residueIdentity = CleanupResidue.installedBundle(bundle).identity
      } else {
        residueIdentity = nil
      }
      guard case .string(let jobID)? = request.params?["jobId"],
        let identity = residueIdentity
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "jobId and one of remotePath / bundleName are required")
      }
      do {
        let result = try await engine.continueCleanupDebt(
          jobID: jobID, identity: identity)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(result.jobID),
            "identity": .string(result.identity),
            "state": .string(result.state.rawValue),
            "detail": .string(result.detail),
          ]))
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "doctor":
      let params = request.params ?? [:]
      guard Set(params.keys).isSubset(of: ["deep"]) else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "doctor accepts only the deep boolean")
      }
      let deep: Bool
      if let value = params["deep"] {
        guard case .bool(let requested) = value else {
          return failure(
            id: request.id, code: .invalidParams,
            message: "doctor deep must be a boolean")
        }
        deep = requested
      } else {
        deep = false
      }
      return success(id: request.id, result: await doctorReport(deep: deep))

    case "artifact.import.begin", "artifact.import.append", "artifact.import.commit", "artifact.import.abort", "artifact.import.list", "artifact.import.inspect", "artifact.import.inspection", "artifact.import.release":
      return await importGateway.response(request, context: context,
        resources: RuntimeImportControlHandler(artifacts: artifactStore, targets: targetStore,
          flashPolicy: durableImportFlashPolicy, engine: engine))

    case "artifact.quota":
      // Read-only headroom, so a caller can be refused before it starts work
      // rather than after. The store's rule is refuse-never-evict: a full
      // store does not make room by discarding what somebody already
      // captured, so "there is no room" is a fact a caller has to act on
      // rather than something the runtime can quietly resolve.
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      do {
        let used = try await artifactStore.totalBytesUsed()
        let total = await artifactStore.quotaTotalBytes
        return success(
          id: request.id,
          result: .object([
            "totalBytes": .integer(Int64(total)),
            "usedBytes": .integer(Int64(used)),
            "remainingBytes": .integer(Int64(max(0, total - used))),
          ]))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.list":
      return await RuntimeArtifactResourceHandler(engine: engine, artifacts: artifactStore).response(request)

    case "artifact.inspect":
      return await RuntimeArtifactResourceHandler(engine: engine, artifacts: artifactStore).response(request)

    case "artifact.read":
      return await RuntimeArtifactResourceHandler(engine: engine, artifacts: artifactStore).response(request)

    case "artifact.export":
      return await RuntimeArtifactResourceHandler(engine: engine, artifacts: artifactStore).response(request)

    case "history.filter.list", "history.filter.save", "history.filter.delete":
      guard let historyFilterStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "History filter store is not configured")
      }
      let fields = request.params ?? [:]
      do {
        switch request.method {
        case "history.filter.list":
          guard fields.isEmpty else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "History filter list accepts no parameters")
          }
          return success(id: request.id, result: try historyFilterStore.read().listProjection)
        case "history.filter.save":
          let expectedKeys: Set<String> = [
            "expectedGeneration", "search", "status", "mode", "sessionId", "targetId",
            "timeRange", "activity",
          ]
          guard Set(fields.keys) == expectedKeys,
            case .string(let generationText)? = fields["expectedGeneration"],
            let expectedGeneration = UInt64(generationText), expectedGeneration > 0,
            expectedGeneration <= UInt64(Int64.max), String(expectedGeneration) == generationText,
            case .string(let search)? = fields["search"],
            case .string(let status)? = fields["status"],
            case .string(let mode)? = fields["mode"],
            case .string(let timeRange)? = fields["timeRange"],
            case .string(let activity)? = fields["activity"]
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "History filter save requires one complete typed query and generation")
          }
          func nullableString(_ value: JSONValue?) -> (valid: Bool, value: String?) {
            switch value {
            case .string(let text)?: return (true, text)
            case .null?: return (true, nil)
            default: return (false, nil)
            }
          }
          let session = nullableString(fields["sessionId"])
          let target = nullableString(fields["targetId"])
          guard session.valid, target.valid else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "History filter Session and target must be an identity or null")
          }
          let query = RuntimeHistoryFilterQuery(
            search: search, status: status, mode: mode,
            sessionID: session.value, targetID: target.value,
            timeRange: timeRange, activity: activity)
          return success(
            id: request.id,
            result: try historyFilterStore.save(
              expectedGeneration: expectedGeneration, query: query).projection)
        default:
          guard Set(fields.keys) == ["expectedGeneration"],
            case .string(let generationText)? = fields["expectedGeneration"],
            let expectedGeneration = UInt64(generationText), expectedGeneration > 0,
            expectedGeneration <= UInt64(Int64.max), String(expectedGeneration) == generationText
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "History filter delete requires one exact generation")
          }
          return success(
            id: request.id,
            result: try historyFilterStore.delete(
              expectedGeneration: expectedGeneration).projection)
        }
      } catch let error as RuntimeHistoryFilterFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: error.code, message: error.message,
            details: [
              "phase": .string("historyFilterOwner"),
              "newDispatchCount": .integer(0),
            ]))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "trace.inspect":
      return await RuntimeTraceInspectionResourceHandler(
        engine: engine, artifacts: artifactStore, inspector: traceInspector
      ).response(request)

    case "trace.cache.status", "trace.cache.purge":
      guard request.params?.isEmpty != false else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "Trace cache status and purge accept no parameters")
      }
      guard let traceCacheMaintenance else {
        return failure(
          id: request.id, code: .internalError,
          message: "Trace cache maintenance is not configured")
      }
      do {
        if request.method == "trace.cache.status" {
          return success(
            id: request.id,
            result: try await traceCacheMaintenance.inventory().statusProjection)
        }
        return success(
          id: request.id,
          result: try await traceCacheMaintenance.purgeUnused().projection)
      } catch {
        let code = request.method == "trace.cache.status" ? "recordUnreadable" : "outcomeUnknown"
        let message = request.method == "trace.cache.status"
          ? "Trace cache inventory is unavailable"
          : "Trace cache purge outcome is unknown; read status before requesting another purge"
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: code, message: message,
            details: [
              "phase": .string("traceCacheOwner"),
              "newDispatchCount": .integer(0),
              "purgeScope": .string("inactiveDerivedDatabases"),
            ]))
      }

    case "device.display-name.set", "device.display-name.clear":
      guard let targetObservations else {
        return failure(
          id: request.id, code: .internalError,
          message: "target observation owner is not configured")
      }
      let fields = request.params ?? [:]
      let expectedKeys: Set<String> = request.method == "device.display-name.set"
        ? ["candidate", "observationId", "observationGeneration", "name"]
        : ["candidate", "observationId", "observationGeneration"]
      guard Set(fields.keys) == expectedKeys else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "candidate display-name mutation requires one exact observation")
      }
      do {
        let reference = try Self.targetObservationReference(
          Dictionary(uniqueKeysWithValues: [
            "candidate", "observationId", "observationGeneration",
          ].compactMap { key in fields[key].map { (key, $0) } }))
        let resource: RuntimeCandidateDisplayName
        if request.method == "device.display-name.set" {
          guard case .string(let name)? = fields["name"] else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "candidate display-name set requires bounded text")
          }
          resource = try await targetObservations.setDisplayName(reference, name: name)
        } else {
          resource = try await targetObservations.clearDisplayName(reference)
        }
        return success(id: request.id, result: resource.projection)
      } catch let error as TargetObservationFailure {
        var details: [String: JSONValue] = [
          "phase": .string("candidateDisplayNameOwner"),
          "newDispatchCount": .integer(0),
        ]
        if let reference = error.reference {
          details["candidate"] = .string(reference.candidate)
          details["observationId"] = .string(reference.observationID)
          details["observationGeneration"] = .string(String(reference.generation))
        }
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(code: error.code, message: error.message, details: details))
      } catch let error as RuntimeTargetDisplayNameFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: error.code, message: error.message,
            details: [
              "phase": .string("candidateDisplayNameOwner"),
              "newDispatchCount": .integer(0),
            ]))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "target.display-name.set", "target.display-name.clear":
      guard let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "target store is not configured")
      }
      let fields = request.params ?? [:]
      let expectedKeys: Set<String> = request.method == "target.display-name.set"
        ? ["targetId", "expectedGeneration", "name"]
        : ["targetId", "expectedGeneration"]
      guard Set(fields.keys) == expectedKeys,
        case .string(let targetID)? = fields["targetId"],
        case .string(let generationText)? = fields["expectedGeneration"],
        let expectedGeneration = UInt64(generationText), expectedGeneration > 0,
        expectedGeneration <= UInt64(Int64.max), String(expectedGeneration) == generationText
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "target display-name mutation requires an exact target and generation")
      }
      do {
        let resource: RuntimeTargetDisplayName
        if request.method == "target.display-name.set" {
          guard case .string(let name)? = fields["name"] else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "target display-name set requires bounded text")
          }
          resource = try targetStore.setTargetDisplayName(
            targetID: targetID, expectedGeneration: expectedGeneration, name: name)
        } else {
          resource = try targetStore.clearTargetDisplayName(
            targetID: targetID, expectedGeneration: expectedGeneration)
        }
        return success(id: request.id, result: resource.projection)
      } catch let error as RuntimeTargetDisplayNameFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: error.code, message: error.message,
            details: [
              "phase": .string("targetDisplayNameOwner"),
              "newDispatchCount": .integer(0),
            ]))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "target.list":
      guard let targetStore else {
        return failure(
          id: request.id, code: .internalError, message: "target store is not configured")
      }
      do {
        let targets = try targetStore.listActive()
        let displayNames = try targetStore.targetDisplayNames(
          targetIDs: targets.map(\.targetID))
        return success(
          id: request.id,
          result: .array(
            targets.map { record in
              let display = displayNames[record.targetID]!
              return .object([
                "targetId": .string(record.targetID),
                "bindingRevision": .integer(Int64(record.bindingRevision)),
                "toolVersion": .string(record.toolVersion),
                "adoptedAtUtc": .string(record.adoptedAtUTC),
                "displayName": display.name.map(JSONValue.string) ?? .null,
                "displayNameGeneration": .string(String(display.generation)),
              ])
            }))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "target.show":
      // §13.2 is explicit that this is not an alias of `target.list`. A caller
      // deciding whether it can drive this device needs the binding revision it
      // will pin, the physical identity that binding is against, the last facts
      // the Runtime actually confirmed, and whether the device is visible right
      // now. `target.list` publishes none of the last three, so a caller had to
      // adopt-and-see instead of look.
      //
      // Additive and read-only: it creates nothing, and the field vocabulary is
      // shared with `device.candidates` so the two projections cannot describe
      // the same device in two spellings.
      if (Set((request.params ?? [:]).keys) != ["targetId"]
          || request.params?["targetId"].flatMap({ value -> String? in
            if case .string(let id) = value, AgentExecutionIntent.validIdentifier(id) { return id }; return nil
          }) == nil) {
        return failure(id: request.id, code: .invalidParams, message: "target.show requires an exact targetId")
      }
      guard let targetStore else {
        return failure(
          id: request.id, code: .internalError, message: "target store is not configured")
      }
      guard case .string(let requestedTargetID)? = request.params?["targetId"],
        !requestedTargetID.isEmpty
      else {
        return failure(id: request.id, code: .invalidParams, message: "targetId is required")
      }
      do {
        guard let record = try targetStore.find(targetID: requestedTargetID) else {
          return failure(
            id: request.id, code: .notFound,
            message: "no durable target \(requestedTargetID)")
        }
        let displayName = try targetStore.targetDisplayNames(
          targetIDs: [record.targetID])[record.targetID]!
        let observation =
          (try? await engine.latestSucceededDeviceObservations())?[record.targetID]
        // The warm snapshot only. Forcing a candidate refresh here would turn a
        // record lookup into a device round trip; the freshness of what is
        // reported is published instead of implied, so a caller that needs a
        // current reading knows to ask for one.
        var live: JSONValue = .null
        if let bootstrap, let snapshot = try? await bootstrap.candidateSnapshotForPresentation() {
          let match = snapshot.candidates.first { $0.connectKey == record.connectKey }
          live = .object([
            "state": match.map { .string($0.state) } ?? .string("Absent"),
            "observedAtUtc": .string(snapshot.observedAtUTC),
            "observationHealth": .string(snapshot.health.rawValue),
          ])
        }
        var projection: [String: JSONValue] = [
            "targetId": .string(record.targetID),
            "bindingRevision": .integer(Int64(record.bindingRevision)),
            "toolVersion": .string(record.toolVersion),
            "adoptedAtUtc": .string(record.adoptedAtUTC),
            "connectKey": .string(record.connectKey),
            "stablePhysicalIdentitySha256": .string(record.stablePhysicalIdentitySHA256),
            "displayName": displayName.name.map(JSONValue.string) ?? .null,
            "displayNameGeneration": .string(String(displayName.generation)),
            "live": live,
            "observedFacts": observation.map {
              .object([
                "targetId": $0.targetID.map(JSONValue.string) ?? .null,
                "model": $0.model.map(JSONValue.string) ?? .null,
                "firmware": $0.firmware.map(JSONValue.string) ?? .null,
                "transport": $0.transport.map(JSONValue.string) ?? .null,
                "confirmedAtUtc": $0.confirmedAtUTC.map(JSONValue.string) ?? .null,
              ])
            } ?? .null,
          ]
        projection["schemaVersion"] = .string("arkdeck.target/1")

        return success(id: request.id, result: .object(projection))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "target.availability":
      // §6.1's aggregate, owned by the Runtime because §7.1 forbids the
      // alternative by name: the CLI must not issue several reads and declare
      // from stale answers that a device is usable. Every fact below is read
      // in one pass here, and each leg publishes its own freshness and reason
      // so a caller can tell "checked and true" from "not checked".
      //
      // §5.1 admits this as a bounded read-only observation, not an operation:
      // it creates no Job, produces no evidence and runs no device workflow.
      // That last one is the line to keep — the App's capability matrix reaches
      // this shape by running `debug.template.run`, and doing that here would
      // move the aggregate inside Catalog + Job/WAL where §5.1 says it belongs.
      guard let targetStore else {
        return failure(
          id: request.id, code: .internalError, message: "target store is not configured")
      }
      guard case .string(let availabilityTargetID)? = request.params?["targetId"],
        !availabilityTargetID.isEmpty
      else {
        return failure(id: request.id, code: .invalidParams, message: "targetId is required")
      }
      do {
        guard let record = try targetStore.find(targetID: availabilityTargetID) else {
          return failure(
            id: request.id, code: .notFound,
            message: "no durable target \(availabilityTargetID)")
        }
        var presence: JSONValue = Self.unobservedPresence()
        if let bootstrap, let snapshot = try? await bootstrap.candidateSnapshotForPresentation() {
          presence = Self.encodePresence(snapshot: snapshot, connectKey: record.connectKey)
        }
        return success(
          id: request.id,
          result: Self.encodeTargetAvailability(
            record: record,
            presence: presence,
            tool: Self.encodeToolLeg(hdcRuntimeDiagnostics),
            operations: await engine.operationAvailability(),
            observedAtUTC: nowUTC()))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "workspace.project.register", "workspace.project.update", "workspace.project.remove":
      let fields = request.params ?? [:]
      do {
        let resource: RuntimeWorkspaceProjectResource
        switch request.method {
        case "workspace.project.register":
          guard Set(fields.keys) == ["registrationRequestId", "kind", "root"],
            case .string(let requestID)? = fields["registrationRequestId"],
            case .string(let kind)? = fields["kind"],
            case .string(let root)? = fields["root"]
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "workspace project register requires request identity, kind and root")
          }
          resource = try await engine.workspaceProjectRegister(
            requestID: requestID, kind: kind, rootPath: root)
        case "workspace.project.update":
          guard Set(fields.keys) == ["projectRef", "expectedGeneration", "kind", "root"],
            case .string(let projectRef)? = fields["projectRef"],
            case .string(let generationText)? = fields["expectedGeneration"],
            let generation = UInt64(generationText), generation > 0,
            generation <= UInt64(Int64.max), String(generation) == generationText,
            case .string(let kind)? = fields["kind"],
            case .string(let root)? = fields["root"]
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "workspace project update requires exact project, generation, kind and root")
          }
          resource = try await engine.workspaceProjectUpdate(
            projectRef: projectRef, expectedGeneration: generation,
            kind: kind, rootPath: root)
        default:
          guard Set(fields.keys) == ["projectRef", "expectedGeneration"],
            case .string(let projectRef)? = fields["projectRef"],
            case .string(let generationText)? = fields["expectedGeneration"],
            let generation = UInt64(generationText), generation > 0,
            generation <= UInt64(Int64.max), String(generation) == generationText
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "workspace project remove requires exact project and generation")
          }
          resource = try await engine.workspaceProjectRemove(
            projectRef: projectRef, expectedGeneration: generation)
        }
        let publication = workspaceProjects.first { $0.projectRef == resource.projectRef }
        return success(
          id: request.id,
          result: Self.encodeRegisteredWorkspaceProject(resource, publication: publication))
      } catch let error as RuntimeWorkspaceProjectFailure {
        return Self.workspaceProjectFailure(id: request.id, error: error)
      } catch let error as AgentExecutionControlFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: error.code, message: error.message,
            details: error.details.merging([
              "phase": .string("workspaceProjectOwner"),
              "newDispatchCount": .integer(0),
            ], uniquingKeysWith: { _, new in new })))
      } catch {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: "recordUnreadable", message: "workspace project owner failed",
            details: [
              "phase": .string("workspaceProjectOwner"),
              "newDispatchCount": .integer(0),
            ]))
      }

    case "workspace.project.list":
      // §7.9: project the daemon's current registered configuration. Read-only
      // and derived from what was resolved at composition time, so it neither
      // grants nor widens anything — it is the discovery half, and today it is
      // the only way to learn a `projectRef` at all. §7.9 is explicit that the
      // free-form strings in Catalog descriptors do not count as discovery.
      do {
        let resources = try await engine.workspaceProjectList()
        return success(
          id: request.id,
          result: .object([
            "schemaVersion": .string("arkdeck.workspace-project-list/1"),
            "projects": .array(resources.map { resource in
              Self.encodeRegisteredWorkspaceProject(
                resource,
                publication: workspaceProjects.first { $0.projectRef == resource.projectRef })
            }),
          ]))
      } catch let error as RuntimeWorkspaceProjectFailure {
        return Self.workspaceProjectFailure(id: request.id, error: error)
      } catch let error as AgentExecutionControlFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: error.code, message: error.message,
            details: [
              "phase": .string("workspaceProjectOwner"),
              "newDispatchCount": .integer(0),
            ]))
      } catch {
        return failure(id: request.id, code: .recordUnreadable, message: "workspace project owner failed")
      }

    case "workspace.project.show":
      guard case .string(let projectRef)? = request.params?["projectRef"], !projectRef.isEmpty
      else {
        return failure(id: request.id, code: .invalidParams, message: "projectRef is required")
      }
      do {
        let resource = try await engine.workspaceProjectInspect(projectRef: projectRef)
        return success(
          id: request.id,
          result: Self.encodeRegisteredWorkspaceProject(
            resource,
            publication: workspaceProjects.first { $0.projectRef == resource.projectRef }))
      } catch let error as RuntimeWorkspaceProjectFailure {
        return Self.workspaceProjectFailure(id: request.id, error: error)
      } catch let error as AgentExecutionControlFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: error.code, message: error.message,
            details: [
              "phase": .string("workspaceProjectOwner"),
              "newDispatchCount": .integer(0),
            ]))
      } catch {
        return failure(id: request.id, code: .recordUnreadable, message: "workspace project owner failed")
      }

    case "workspace.preset.register", "workspace.preset.update", "workspace.preset.remove":
      let fields = request.params ?? [:]
      do {
        let resource: RuntimeWorkspacePresetResource
        switch request.method {
        case "workspace.preset.register":
          guard let input = Self.decodeWorkspacePresetDefinition(
            fields, mutationKeys: ["registrationRequestId", "projectRef"]),
            case .string(let requestID)? = fields["registrationRequestId"],
            case .string(let projectRef)? = fields["projectRef"]
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "workspace preset register requires one closed typed definition")
          }
          resource = try await engine.workspacePresetRegister(
            requestID: requestID, projectRef: projectRef,
            kind: input.kind, templateRef: input.templateRef,
            toolchainRef: input.toolchainRef,
            toolchainGeneration: input.toolchainGeneration,
            credentialRef: input.credentialRef,
            timeoutSeconds: input.timeoutSeconds, constraints: input.constraints)
        case "workspace.preset.update":
          guard let input = Self.decodeWorkspacePresetDefinition(
            fields,
            mutationKeys: [
              "mutationRequestId", "projectRef", "presetRef", "expectedGeneration",
            ]),
            case .string(let requestID)? = fields["mutationRequestId"],
            case .string(let projectRef)? = fields["projectRef"],
            case .string(let presetRef)? = fields["presetRef"],
            let generation = Self.canonicalPositiveUInt64(fields["expectedGeneration"])
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "workspace preset update requires identity, exact generation and definition")
          }
          resource = try await engine.workspacePresetUpdate(
            requestID: requestID, projectRef: projectRef, presetRef: presetRef,
            expectedGeneration: generation, kind: input.kind,
            templateRef: input.templateRef, toolchainRef: input.toolchainRef,
            toolchainGeneration: input.toolchainGeneration,
            credentialRef: input.credentialRef,
            timeoutSeconds: input.timeoutSeconds, constraints: input.constraints)
        default:
          guard Set(fields.keys)
            == ["mutationRequestId", "projectRef", "presetRef", "expectedGeneration"],
            case .string(let requestID)? = fields["mutationRequestId"],
            case .string(let projectRef)? = fields["projectRef"],
            case .string(let presetRef)? = fields["presetRef"],
            let generation = Self.canonicalPositiveUInt64(fields["expectedGeneration"])
          else {
            return failure(
              id: request.id, code: .invalidParams,
              message: "workspace preset remove requires identity and exact generation")
          }
          resource = try await engine.workspacePresetRemove(
            requestID: requestID, projectRef: projectRef, presetRef: presetRef,
            expectedGeneration: generation)
        }
        return success(id: request.id, result: resource.projection)
      } catch let error as RuntimeWorkspaceProjectFailure {
        return Self.workspacePresetFailure(id: request.id, error: error)
      } catch let error as AgentExecutionControlFailure {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: error.code, message: error.message,
            details: error.details.merging([
              "phase": .string("workspacePresetOwner"),
              "newDispatchCount": .integer(0),
            ], uniquingKeysWith: { _, new in new })))
      } catch {
        return AgentWireProtocol.Response(
          id: request.id, ok: false, result: nil,
          error: .init(
            code: "recordUnreadable", message: "workspace preset owner failed",
            details: [
              "phase": .string("workspacePresetOwner"),
              "newDispatchCount": .integer(0),
            ]))
      }

    case "workspace.preset.list":
      guard case .string(let projectRef)? = request.params?["projectRef"], !projectRef.isEmpty
      else {
        return failure(id: request.id, code: .invalidParams, message: "projectRef is required")
      }
      let fields = request.params ?? [:]
      guard Set(fields.keys).isSubset(of: ["projectRef", "kind"]) else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "workspace preset list accepts only projectRef and kind")
      }
      let kind: String?
      if let value = fields["kind"] {
        guard case .string(let text) = value else {
          return failure(id: request.id, code: .invalidParams, message: "kind must be text")
        }
        kind = text
      } else {
        kind = nil
      }
      do {
        let presets = try await engine.workspacePresetList(
          projectRef: projectRef, kind: kind)
        return success(
          id: request.id,
          result: .object([
            "schemaVersion": .string("arkdeck.workspace-preset-list/1"),
            "projectRef": .string(projectRef),
            "presets": .array(presets.map(\.projection)),
          ]))
      } catch let error as RuntimeWorkspaceProjectFailure {
        return Self.workspacePresetFailure(id: request.id, error: error)
      } catch let error as AgentExecutionControlFailure {
        return Self.workspacePresetFailure(
          id: request.id,
          error: RuntimeWorkspaceProjectFailure(error.code, error.message))
      } catch {
        return failure(
          id: request.id, code: .recordUnreadable,
          message: "workspace preset owner failed")
      }

    case "workspace.preset.show":
      guard case .string(let projectRef)? = request.params?["projectRef"], !projectRef.isEmpty,
        case .string(let presetRef)? = request.params?["presetRef"], !presetRef.isEmpty
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "projectRef and presetRef are required")
      }
      guard Set(request.params?.keys.map { $0 } ?? []) == ["projectRef", "presetRef"] else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "workspace preset show requires exact projectRef and presetRef")
      }
      do {
        let preset = try await engine.workspacePresetInspect(
          projectRef: projectRef, presetRef: presetRef)
        return success(id: request.id, result: preset.projection)
      } catch let error as RuntimeWorkspaceProjectFailure {
        return Self.workspacePresetFailure(id: request.id, error: error)
      } catch let error as AgentExecutionControlFailure {
        return Self.workspacePresetFailure(
          id: request.id,
          error: RuntimeWorkspaceProjectFailure(error.code, error.message))
      } catch {
        return failure(
          id: request.id, code: .recordUnreadable,
          message: "workspace preset owner failed")
      }

    case "device.observations":
      return await targetObservationRequest(request, adopting: false)

    case "target.adopt":
      return await targetObservationRequest(request, adopting: true)

    default:
      return failure(
        id: request.id, code: .unknownMethod, message: "unknown method \(request.method)")
    }
  }

  /// §7's bounded diagnostic query. It always returns the minimum versioned
  /// report, even when one of the optional probes fails. A failed subcheck is a
  /// blocker finding; it is not allowed to erase the rest of the report or to
  /// turn an observed unavailable component into a transport failure.
  private func doctorReport(deep: Bool) async -> JSONValue {
    var findings: [JSONValue] = []
    var blockerCount = 0
    var warningCount = 0

    func addFinding(
      code: String, severity: String, scope: String, summary: String,
      details: [String: JSONValue] = [:]
    ) {
      if severity == "blocker" { blockerCount += 1 }
      if severity == "warning" { warningCount += 1 }
      var finding: [String: JSONValue] = [
        "code": .string(code),
        "severity": .string(severity),
        "scope": .string(scope),
        "summary": .string(summary),
      ]
      if !details.isEmpty { finding["details"] = .object(details) }
      findings.append(.object(finding))
    }

    addFinding(
      code: "runtime.controlReady", severity: "info", scope: "runtime",
      summary: "the target control protocol is serving bounded diagnostic requests")

    let operationAvailability = await engine.operationAvailability()
    let availableOperationCount = operationAvailability.filter { $0.state == .available }.count
    let unavailableOperationCount = operationAvailability.count - availableOperationCount
    if availableOperationCount == 0 {
      addFinding(
        code: "catalog.noAvailableOperations", severity: "blocker", scope: "catalog",
        summary: "the published Catalog has no operation available on this Runtime")
    } else {
      addFinding(
        code: "catalog.availableOperations", severity: "info", scope: "catalog",
        summary: "the Runtime can materialize at least one published operation",
        details: ["availableOperationCount": .integer(Int64(availableOperationCount))])
    }
    if unavailableOperationCount > 0 {
      addFinding(
        code: "catalog.unavailableOperations", severity: "warning", scope: "catalog",
        summary: "some published operations are unavailable with the current host configuration",
        details: ["unavailableOperationCount": .integer(Int64(unavailableOperationCount))])
    }

    let sortedProviderIDs = providerIDs.sorted()
    if sortedProviderIDs.isEmpty {
      addFinding(
        code: "provider.noneRegistered", severity: "blocker", scope: "provider",
        summary: "the Runtime has no registered provider")
    } else {
      addFinding(
        code: "provider.registered", severity: "info", scope: "provider",
        summary: "the Runtime has registered providers",
        details: ["providerCount": .integer(Int64(sortedProviderIDs.count))])
    }

    var hdcCheck: [String: JSONValue] = [
      "checked": .bool(deep), "configured": .bool(hdcStatusObserver != nil),
      "availability": .string(deep ? "unknown" : "notChecked"),
      "ownership": .string("unknown"), "serverHealth": .string("unknown"),
      "reasonCode": .string(deep ? "hdc.statusUnavailable" : "doctor.deepNotRequested"),
    ]
    if let hdcStatusObserver {
      if deep {
        let snapshot = await hdcStatusObserver.snapshot()
        if case .object(let fields) = snapshot {
          let availability = fields["availability"] ?? .string("unknown")
          let ownership = fields["ownership"] ?? .string("unknown")
          let serverHealth = fields["serverHealth"] ?? .string("unknown")
          let reasonCode = fields["reasonCode"] ?? .string("hdc.statusIncomplete")
          hdcCheck["availability"] = availability
          hdcCheck["ownership"] = ownership
          hdcCheck["serverHealth"] = serverHealth
          hdcCheck["reasonCode"] = reasonCode
          let isAvailable = availability == .string("available")
          let isManaged = ownership == .string("arkDeckManaged")
          if isAvailable, isManaged {
            addFinding(
              code: "hdc.identityReady", severity: "info", scope: "hdc",
              summary: "the selected HDC server has a live Runtime-managed identity")
          } else {
            addFinding(
              code: "hdc.identityUnavailable", severity: "blocker", scope: "hdc",
              summary: "the selected HDC server identity is unavailable or not Runtime-managed",
              details: ["reasonCode": reasonCode])
          }
        } else {
          addFinding(
            code: "hdc.statusUnreadable", severity: "blocker", scope: "hdc",
            summary: "the bounded HDC status probe returned no structured report")
          hdcCheck["reasonCode"] = .string("hdc.statusUnreadable")
        }
      } else {
        addFinding(
          code: "hdc.deepCheckSkipped", severity: "info", scope: "hdc",
          summary: "live HDC identity was not requested; use doctor --deep to check it")
      }
    } else {
      addFinding(
        code: "hdc.notConfigured", severity: "blocker", scope: "hdc",
        summary: "the Runtime has no bounded HDC status observer")
      hdcCheck["availability"] = .string("unavailable")
      hdcCheck["reasonCode"] = .string("hdc.notConfigured")
    }

    var artifactStorageCheck: [String: JSONValue] = [
      "checked": .bool(deep), "configured": .bool(artifactStore != nil),
      "totalBytes": .null, "usedBytes": .null, "remainingBytes": .null,
    ]
    if let artifactStore {
      if deep {
        do {
          let used = try await artifactStore.totalBytesUsed()
          let total = await artifactStore.quotaTotalBytes
          let remaining = max(0, total - used)
          artifactStorageCheck["totalBytes"] = .integer(Int64(total))
          artifactStorageCheck["usedBytes"] = .integer(Int64(used))
          artifactStorageCheck["remainingBytes"] = .integer(Int64(remaining))
          if remaining == 0 {
            addFinding(
              code: "storage.quotaExhausted", severity: "blocker", scope: "storage",
              summary: "the Runtime Artifact store has no remaining quota")
          } else {
            addFinding(
              code: "storage.artifactStoreReady", severity: "info", scope: "storage",
              summary: "the Runtime Artifact store is readable and has remaining quota")
          }
        } catch {
          addFinding(
            code: "storage.artifactStoreUnreadable", severity: "blocker", scope: "storage",
            summary: "the Runtime Artifact store could not produce bounded quota facts")
        }
      } else {
        addFinding(
          code: "storage.deepCheckSkipped", severity: "info", scope: "storage",
          summary: "Artifact quota accounting was not requested; use doctor --deep to check it")
      }
    } else {
      addFinding(
        code: "storage.artifactStoreNotConfigured", severity: "blocker", scope: "storage",
        summary: "the Runtime Artifact store is not configured")
    }
    // The App-owned Session output root and the Runtime Artifact root are
    // separate stores with different quotas and retention rules. Until a
    // single Runtime owner for Session output is published, doctor reports the
    // gap explicitly and never combines the two domains into one number.
    addFinding(
      code: "storage.sessionOutputOwnerUnavailable", severity: "warning", scope: "storage",
      summary: "Session output storage has no published Runtime owner")
    let storageCheck: [String: JSONValue] = [
      "runtimeArtifacts": .object(artifactStorageCheck),
      "sessionOutput": .object([
        "checked": .bool(false),
        "availability": .string("unavailable"),
        "reasonCode": .string("storage.sessionOutputOwnerNotPublished"),
      ]),
    ]

    var targetCheck: [String: JSONValue] = [
      "configured": .bool(targetStore != nil), "bootstrapConfigured": .bool(bootstrap != nil),
      "adoptedTargetCount": .null,
    ]
    if let targetStore {
      do {
        let targets = try targetStore.listActive()
        targetCheck["adoptedTargetCount"] = .integer(Int64(targets.count))
        addFinding(
          code: targets.isEmpty ? "target.noneAdopted" : "target.storeReady",
          severity: "info", scope: "target",
          summary: targets.isEmpty
            ? "the target store is readable and has no adopted target"
            : "the target store is readable",
          details: ["adoptedTargetCount": .integer(Int64(targets.count))])
      } catch {
        addFinding(
          code: "target.storeUnreadable", severity: "blocker", scope: "target",
          summary: "the durable target store could not be read")
      }
    } else {
      addFinding(
        code: "target.storeNotConfigured", severity: "blocker", scope: "target",
        summary: "the durable target store is not configured")
    }
    if bootstrap == nil {
      addFinding(
        code: "target.discoveryNotConfigured", severity: "blocker", scope: "target",
        summary: "device discovery is not configured")
    }

    var recoveryCheck: [String: JSONValue] = [
      "checked": .bool(deep), "outstandingCleanupCount": .null,
    ]
    if deep {
      do {
        let debts = try await engine.listCleanupDebt()
        recoveryCheck["outstandingCleanupCount"] = .integer(Int64(debts.count))
        addFinding(
          code: debts.isEmpty ? "recovery.noCleanupDebt" : "recovery.cleanupDebtOutstanding",
          severity: debts.isEmpty ? "info" : "blocker", scope: "recovery",
          summary: debts.isEmpty
            ? "the Runtime has no outstanding cleanup debt"
            : "the Runtime has outstanding cleanup debt",
          details: ["outstandingCleanupCount": .integer(Int64(debts.count))])
      } catch {
        addFinding(
          code: "recovery.cleanupDebtUnreadable", severity: "blocker", scope: "recovery",
          summary: "the Runtime could not inspect outstanding cleanup debt")
      }
    } else {
      addFinding(
        code: "recovery.deepCheckSkipped", severity: "info", scope: "recovery",
        summary: "cleanup debt was not requested; use doctor --deep to check it")
    }

    let ready = blockerCount == 0
    let overall = blockerCount > 0 ? "blocked" : (warningCount > 0 ? "degraded" : "healthy")
    return .object([
      "schemaVersion": .string("arkdeck.doctor-report/1"),
      "observedAt": .string(nowUTC()),
      "mode": .string(deep ? "deep" : "standard"),
      "overall": .string(overall),
      "ready": .bool(ready),
      "findingCounts": .object([
        "blocker": .integer(Int64(blockerCount)),
        "warning": .integer(Int64(warningCount)),
        "info": .integer(Int64(max(0, findings.count - blockerCount - warningCount))),
      ]),
      "findings": .array(findings),
      "checks": .object([
        "runtime": .object([
          "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
          "runtimeRequestSchemaVersion": .string(RuntimeRequestEnvelope.schemaVersion),
        ]),
        "catalog": .object([
          "digest": .string(RuntimeOperationCatalog.catalogDigest),
          "operationCount": .integer(Int64(operationAvailability.count)),
          "availableOperationCount": .integer(Int64(availableOperationCount)),
          "unavailableOperationCount": .integer(Int64(unavailableOperationCount)),
        ]),
        "providers": .object([
          "registered": .array(sortedProviderIDs.map(JSONValue.string)),
        ]),
        "hdc": .object(hdcCheck),
        "storage": .object(storageCheck),
        "target": .object(targetCheck),
        "recovery": .object(recoveryCheck),
      ]),
    ])
  }

  /// The current Job lifecycle uses closed request shapes, stable resource
  /// projections and phase evidence
  /// required to distinguish a proven refusal from an unknown mutation
  /// outcome.
  private func jobLifecycleRequest(
    _ request: AgentWireProtocol.Request
  ) async -> AgentWireProtocol.Response {
    let fields = request.params ?? [:]
    func structuredFailure(
      _ code: String, _ message: String, provesZeroNewDispatch: Bool,
      inheritedDetails: [String: JSONValue] = [:]
    ) -> AgentWireProtocol.Response {
      var details = inheritedDetails
      if provesZeroNewDispatch {
        details["phase"] = .string("preAdmission")
        details["newDispatchCount"] = .integer(0)
      }
      return AgentWireProtocol.Response(
        id: request.id, ok: false, result: nil,
        error: .init(code: code, message: message, details: details))
    }
    func requestJSON() throws -> String {
      guard Set(fields.keys) == ["requestJson"] else {
        throw AgentExecutionControlFailure(
          "invalidInput",
          "the target Job request accepts exactly one bounded requestJson")
      }
      guard case .string(let value)? = fields["requestJson"], !value.isEmpty else {
        throw AgentExecutionControlFailure(
          "invalidInput", "requestJson must be a non-empty typed request document")
      }
      guard value.utf8.count <= 4 * 1024 * 1024 else {
        throw AgentExecutionControlFailure(
          "inputTooLarge", "requestJson exceeds the target control request bound")
      }
      return value
    }
    do {
      switch request.method {
      case "job.plan":
        let preview = try await engine.planOnly(Data(try requestJSON().utf8))
        return success(id: request.id, result: Self.targetJobPlanProjection(preview))
      case "job.submit":
        let acceptance = try await engine.submitForTargetControl(
          Data(try requestJSON().utf8))
        return success(
          id: request.id,
          result: .object([
            "schemaVersion": .string("arkdeck.job-acceptance/1"),
            "jobId": .string(acceptance.jobID),
            "deduplicated": .bool(acceptance.deduplicated),
            "newDispatchCount": .integer(0),
          ]))
      case "job.run":
        guard Set(fields.keys) == ["jobId"],
          case .string(let jobID)? = fields["jobId"],
          AgentExecutionIntent.validIdentifier(jobID)
        else {
          return structuredFailure(
            "invalidInput", "job.run requires one exact bounded Job identity",
            provesZeroNewDispatch: true)
        }
        let status = try await engine.runForTargetControl(jobID: jobID)
        return success(id: request.id, result: try RuntimeJobReadProjection.status(status))
      default:
        return failure(id: request.id, code: .unknownMethod, message: "unknown Job lifecycle method")
      }
    } catch let error as AgentExecutionControlFailure {
      let provenCodes: Set<String> = [
        "invalidInput", "inputTooLarge", "idempotencyConflict", "reviewedPlanMismatch",
        "resourceConflict", "resourceNotFound", "operationUnavailable", "admissionDenied",
        "bindingRevisionStale", "factsDrifted",
      ]
      let ownerProvesZero =
        error.details["phase"] == .string("preAdmission")
        && error.details["newDispatchCount"] == .integer(0)
      return structuredFailure(
        error.code, error.message,
        provesZeroNewDispatch:
          ownerProvesZero
          || (request.method != "job.run" && provenCodes.contains(error.code)),
        inheritedDetails: error.details)
    } catch let error as RuntimeJobEngineError {
      switch error {
      case .rejected(let code, let message):
        let mapped: String
        switch code {
        case .invalidRequest, .invalidInput, .governanceFieldRejected:
          mapped = "invalidInput"
        case .requestTooLarge:
          mapped = "inputTooLarge"
        case .unknownOperation, .unsupportedProfile, .unsupportedVersion:
          mapped = "operationUnavailable"
        case .targetNotFound:
          mapped = "resourceNotFound"
        case .authorizationRequired:
          mapped = "admissionDenied"
        case .conflict, .deviceBusyBySession:
          mapped = "resourceConflict"
        }
        return structuredFailure(
          mapped, message,
          // Planning never dispatches. Submit rejections are raised before
          // the durable admission point. A run-time rejection may have
          // followed device work and therefore carries no such proof.
          provesZeroNewDispatch: request.method != "job.run")
      case .idempotencyConflict(let message):
        return structuredFailure(
          "idempotencyConflict", message, provesZeroNewDispatch: true)
      case .jobNotFound:
        return structuredFailure(
          "resourceNotFound", "the referenced Job does not exist",
          provesZeroNewDispatch: request.method != "job.run")
      case .jobRecordUnreadable:
        return structuredFailure(
          "recordUnreadable", "the referenced Job record is unreadable",
          provesZeroNewDispatch: request.method != "job.run")
      case .jobNotRunnable(let message):
        return structuredFailure(
          "resourceConflict", message, provesZeroNewDispatch: true)
      case .internalFailure:
        return structuredFailure(
          "internalError", "the Runtime could not complete the Job lifecycle request",
          provesZeroNewDispatch: request.method == "job.plan")
      }
    } catch {
      return structuredFailure(
        "internalError", "the Runtime could not complete the Job lifecycle request",
        provesZeroNewDispatch: request.method == "job.plan")
    }
  }

  private static func targetJobPlanProjection(
    _ preview: RuntimePlanOnlyPreview
  ) -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.job-plan/1"),
      "executionMode": .string(preview.executionMode),
      "operation": .string(preview.operationReference),
      "targetId": .string(preview.targetID),
      "bindingRevision": preview.bindingRevision.map { .integer(Int64($0)) } ?? .null,
      "stableIdentitySha256": preview.stableIdentitySHA256.map(JSONValue.string) ?? .null,
      "providerId": .string(preview.providerID),
      "catalogDigest": .string(preview.catalogDigest),
      "requestFingerprintSha256": .string(preview.requestFingerprintSHA256),
      "materializedPlanDigest": .string(preview.materializedPlanDigest),
      "inputs": .object(preview.inputs),
      "steps": .array(
        preview.steps.map { step in
          .object([
            "stepId": .string(step.stepID), "kind": .string(step.kind),
            "effect": .string(step.effect), "cancellation": .string(step.cancellation),
            "binding": .string(step.binding), "optional": .bool(step.isOptional),
          ])
        }),
      "effectiveEffect": .string(preview.effectiveEffect),
      "authorizationPolicy": preview.authorizationPolicy.map(JSONValue.string) ?? .null,
      "providerAdmissionBlocker": preview.providerAdmissionBlocker.map(JSONValue.string) ?? .null,
      "jobAdmitted": .bool(preview.jobAdmitted),
      "dispatchDisposition": .string(preview.dispatchDisposition),
    ])
  }

  /// Which reply an Artifact-store failure deserves.
  ///
  /// Only a genuinely missing Artifact is `notFound`. A corrupt index or a
  /// failed read is the store saying it cannot answer, and reporting that as
  /// absence tells the caller the Artifact was never produced. For a caller
  /// whose recovery is to re-run the operation that produced it, that turns a
  /// local disk problem into a repeated device effect — and for the evidence
  /// chain, which resolves every Artifact by lease, it turns damaged storage
  /// into "this evidence never existed". `job.cancel` and `job.reconcile`
  /// already carry the same correction.
  static func artifactErrorCode(_ error: RuntimeArtifactError) -> AgentDaemonErrorCode {
    switch error {
    case .artifactNotFound:
      return .notFound
    case .indexCorrupted:
      return .recordUnreadable
    case .sensitiveAccessRequiresOptIn, .exportDestinationRejected, .quotaExceeded,
      .evidenceVerificationFailed:
      return .rejected
    case .artifactConflict:
      return .conflict
    case .ioFailure:
      return .internalError
    }
  }

  /// The same rule for a debug invocation. Only a missing invocation is
  /// absent; an unreadable document is damaged state, and every other case is
  /// a gate that refused a request about an invocation that exists.
  static func debugInvocationErrorCode(
    _ error: RuntimeDebugInvocationError
  ) -> AgentDaemonErrorCode {
    switch error {
    case .invocationNotFound:
      return .notFound
    case .persistenceFailure:
      return .recordUnreadable
    case .invalidSeedRequest, .invalidCandidate, .invalidProvenance, .invocationNotActive,
      .invocationExpired, .epochBudgetExhausted, .evaluationAlreadyRunning,
      .predecessorBlocksContinuation:
      return .rejected
    }
  }

  /// One catalog field, projected whole.
  ///
  /// Absent constraints stay absent rather than becoming nulls a caller has to
  /// tell apart from "unconstrained": every key present here is a rule that
  /// applies.
  /// The full descriptor an Agent needs before it decides to submit.
  ///
  /// Built in steps rather than as one literal: the compiler cannot type-check
  /// a dictionary this size in reasonable time, and splitting it also keeps the
  /// decision fields readable as groups.
  // MARK: target availability (§6.1)

  /// The aggregate's leg vocabulary, closed on purpose and deliberately not
  /// `RuntimeAvailabilityReasonCode`.
  ///
  /// That enum answers "why is this *operation* unavailable on this host"; this
  /// one answers "what did the Runtime actually establish about this target
  /// just now". §6.1 asks for the name not to be confused with
  /// `RuntimeCapability`, and the same care applies one level down: sharing a
  /// vocabulary between the two would make `provider_tool_unavailable` mean
  /// both "the catalog cannot run this" and "we could not look".
  enum TargetAvailabilityLeg {
    /// Established true, from a fact read in this call.
    static let ready = "ready"
    /// Established false.
    static let absent = "absent"
    /// Not established either way, and the reason says which fact is missing.
    /// This is never a pass: a caller must read it as "unknown", not "fine".
    static let unresolved = "unresolved"
  }

  static func unobservedPresence() -> JSONValue {
    .object([
      "state": .string(TargetAvailabilityLeg.unresolved),
      "observedAtUtc": .null,
      "observationHealth": .null,
      "reasonCode": .string("device_observation_unavailable"),
      "reason": .string("the Runtime has no device observation source configured"),
    ])
  }

  /// The warm snapshot, never a forced refresh.
  ///
  /// Making this probe the device would turn an availability question into a
  /// device round trip, and §5.1 keeps bounded observations bounded. What the
  /// caller gets instead is the observation's own age and health, published
  /// rather than implied, so "present as of 40 seconds ago" cannot be misread
  /// as "present now".
  static func encodePresence(
    snapshot: BootstrapCandidateSnapshot, connectKey: String
  ) -> JSONValue {
    let match = snapshot.candidates.first { $0.connectKey == connectKey }
    let state = match == nil ? TargetAvailabilityLeg.absent : TargetAvailabilityLeg.ready
    var fields: [String: JSONValue] = [
      "state": .string(state),
      "observedAtUtc": .string(snapshot.observedAtUTC),
      "observationHealth": .string(snapshot.health.rawValue),
      "deviceState": match.map { .string($0.state) } ?? .null,
    ]
    if match == nil {
      fields["reasonCode"] = .string("device_not_observed")
      fields["reason"] = .string("no candidate in the current snapshot matches this binding")
    }
    return .object(fields)
  }

  static func encodeToolLeg(_ diagnostics: HDCManagedRuntimeDiagnostics?) -> JSONValue {
    guard let diagnostics else {
      return .object([
        "state": .string(TargetAvailabilityLeg.absent),
        "reasonCode": .string("runtime_tool_unavailable"),
        "reason": .string("Runtime has no managed HDC server"),
      ])
    }
    return .object([
      "state": .string(TargetAvailabilityLeg.ready),
      "toolSha256": .string(diagnostics.executableSHA256),
      "clientVersion": .string(diagnostics.clientVersion),
      "serverVersion": .string(diagnostics.serverVersion),
      "endpointSource": .string(diagnostics.endpointSource),
    ])
  }

  /// Assembled in one function because the dictionary literal is past what the
  /// type checker will infer inside a `switch` arm — the same reason
  /// `encodeOperationDescriptor` exists.
  static func encodeTargetAvailability(
    record: RuntimeTargetRecord,
    presence: JSONValue,
    tool: JSONValue,
    operations: [RuntimeOperationAvailability],
    observedAtUTC: String
  ) -> JSONValue {
    .object([
      "targetId": .string(record.targetID),
      "observedAtUtc": .string(observedAtUTC),
      "binding": .object([
        "state": .string(TargetAvailabilityLeg.ready),
        "bindingRevision": .integer(Int64(record.bindingRevision)),
        "toolVersion": .string(record.toolVersion),
        "stablePhysicalIdentitySha256": .string(record.stablePhysicalIdentitySHA256),
        "adoptedAtUtc": .string(record.adoptedAtUTC),
      ]),
      "presence": presence,
      "tool": tool,
      // Host-scoped, and labelled as such. §7.2 allows target-dependent
      // availability only from fresh binding/profile/tool facts, and
      // `operationAvailability()` resolves none of those — it answers provider
      // registration, provider availability, dispatcher tool and artifact
      // store, all of which are properties of this host. Publishing it as
      // target-resolved would be the exact failure this aggregate exists to
      // prevent: a caller reading "available" as "available *on this device*".
      "operations": .object([
        "scope": .string("host"),
        "targetResolution": .string(TargetAvailabilityLeg.unresolved),
        "reasonCode": .string("target_scoped_operation_availability_unavailable"),
        "reason": .string(
          "operation availability is computed per host; no target-scoped resolver exists"),
        "items": .array(
          operations.map { item in
            .object([
              "reference": .string(item.reference),
              "availability": .string(item.state.rawValue),
              "reasons": .array(item.reasons.map(JSONValue.string)),
              "reasonCodes": .array(item.reasonCodes.map { .string($0.rawValue) }),
            ])
          }),
      ]),
      // Nothing in this build resolves a target to a device profile:
      // `descriptor.profiles` is published by the catalog and consumed by no
      // resolver. Reporting a match would be inventing one, and reporting
      // `ready` would be worse — so the leg says it is unresolved and names
      // what is missing.
      "profile": .object([
        "state": .string(TargetAvailabilityLeg.unresolved),
        "reasonCode": .string("profile_resolver_unavailable"),
        "reason": .string(
          "no target-to-profile resolver exists; catalog profiles are published but unmatched"),
      ]),
    ])
  }

  // MARK: workspace discovery (§7.9)

  private struct WorkspacePresetDefinitionInput {
    let kind: String
    let templateRef: String
    let toolchainRef: String?
    let toolchainGeneration: UInt64?
    let credentialRef: String?
    let timeoutSeconds: Int
    let constraints: RuntimeWorkspacePresetConstraints
  }

  private static func decodeWorkspacePresetDefinition(
    _ fields: [String: JSONValue], mutationKeys: Set<String>
  ) -> WorkspacePresetDefinitionInput? {
    let required = mutationKeys.union(["kind", "templateRef", "timeoutSeconds"])
    let optional: Set<String> = [
      "toolchainRef", "toolchainGeneration", "credentialRef",
      "module", "product", "buildMode", "relativeSourceMap",
    ]
    guard required.isSubset(of: Set(fields.keys)),
      Set(fields.keys).isSubset(of: required.union(optional)),
      case .string(let kind)? = fields["kind"],
      case .string(let templateRef)? = fields["templateRef"],
      let timeout = canonicalPositiveUInt64(fields["timeoutSeconds"]),
      timeout <= UInt64(Int.max)
    else { return nil }
    func optionalString(_ key: String) -> String? {
      guard let value = fields[key], case .string(let text) = value else { return nil }
      return text
    }
    for key in optional where fields[key] != nil && key != "toolchainGeneration" {
      guard case .string? = fields[key] else { return nil }
    }
    let toolchainGeneration: UInt64?
    if fields["toolchainGeneration"] != nil {
      guard let generation = canonicalPositiveUInt64(fields["toolchainGeneration"]) else {
        return nil
      }
      toolchainGeneration = generation
    } else {
      toolchainGeneration = nil
    }
    return WorkspacePresetDefinitionInput(
      kind: kind, templateRef: templateRef,
      toolchainRef: optionalString("toolchainRef"),
      toolchainGeneration: toolchainGeneration,
      credentialRef: optionalString("credentialRef"),
      timeoutSeconds: Int(timeout),
      constraints: RuntimeWorkspacePresetConstraints(
        module: optionalString("module"), product: optionalString("product"),
        buildMode: optionalString("buildMode"),
        relativeSourceMap: optionalString("relativeSourceMap")))
  }

  private static func canonicalPositiveUInt64(_ value: JSONValue?) -> UInt64? {
    guard case .string(let text)? = value, let parsed = UInt64(text), parsed > 0,
      parsed <= UInt64(Int64.max), String(parsed) == text
    else { return nil }
    return parsed
  }

  /// Everything §7.9 permits, and nothing it forbids.
  ///
  /// There is no host root, executable or argv here because
  /// `WorkspaceProjectPublication` cannot carry them — the omission is a
  /// property of the value this function receives rather than a rule this
  /// function follows.
  static func encodeWorkspaceProject(_ project: WorkspaceProjectPublication) -> JSONValue {
    .object([
      "projectRef": .string(project.projectRef),
      "kind": project.kind.map(JSONValue.string) ?? .null,
      "availability": .string(project.available ? "available" : "unavailable"),
      "reasonCode": project.reasonCode.map(JSONValue.string) ?? .null,
      "reason": project.reason.map(JSONValue.string) ?? .null,
      "allowedFileGlobs": .array(project.allowedFileGlobs.map(JSONValue.string)),
      "presetRefs": .array(project.presets.map(Self.encodeWorkspacePreset)),
      "operations": .array(
        project.operations.map { operation in
          .object([
            "reference": .string(operation.reference),
            "availability": .string(operation.available ? "available" : "unavailable"),
            "reasonCode": operation.reasonCode.map(JSONValue.string) ?? .null,
            "reason": operation.reason.map(JSONValue.string) ?? .null,
          ])
        }),
    ])
  }

  static func encodeWorkspacePreset(_ preset: WorkspaceProjectPublication.Preset) -> JSONValue {
    .object([
      "presetRef": .string(preset.presetRef),
      "kind": .string(preset.kind),
      "timeoutSeconds": .integer(Int64(preset.timeoutSeconds)),
    ])
  }

  static func encodeRegisteredWorkspaceProject(
    _ resource: RuntimeWorkspaceProjectResource,
    publication: WorkspaceProjectPublication?
  ) -> JSONValue {
    guard case .object(var fields) = resource.projection else { return resource.projection }
    if resource.configurationStatus == "removed" {
      fields["availability"] = .string("removed")
      fields["reasonCode"] = .string("workspace_project_removed")
      fields["reason"] = .string("the private workspace root grant was removed")
      fields["allowedFileGlobs"] = .array([])
      fields["presetRefs"] = .array([])
      fields["operations"] = .array([])
      return .object(fields)
    }
    guard resource.configurationStatus == "active", let publication else {
      fields["availability"] = .string("unavailable")
      fields["reasonCode"] = .string("workspace_runtime_restart_required")
      fields["reason"] = .string(
        "restart the Runtime to compose the registered root before submitting a workspace Job")
      fields["allowedFileGlobs"] = .array([])
      fields["presetRefs"] = .array([])
      fields["operations"] = .array([])
      return .object(fields)
    }
    guard case .object(let published) = encodeWorkspaceProject(publication) else {
      return .object(fields)
    }
    for (key, value) in published where key != "projectRef" && key != "kind" {
      fields[key] = value
    }
    return .object(fields)
  }

  static func workspaceProjectFailure(
    id: String, error: RuntimeWorkspaceProjectFailure
  ) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(
      id: id, ok: false, result: nil,
      error: .init(
        code: error.code, message: error.message,
        details: [
          "phase": .string("workspaceProjectOwner"),
          "newDispatchCount": .integer(0),
        ]))
  }

  static func workspacePresetFailure(
    id: String, error: RuntimeWorkspaceProjectFailure
  ) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(
      id: id, ok: false, result: nil,
      error: .init(
        code: error.code, message: error.message,
        details: [
          "phase": .string("workspacePresetOwner"),
          "newDispatchCount": .integer(0),
        ]))
  }

  // MARK: device observations (§6.1, §8.5)

  private func hdcControlActionRequest(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    let fields = request.params ?? [:]
    do {
      let result: JSONValue
      switch request.method {
      case "runtime.hdc.impact-preview":
        guard let hdcControlActions else {
          throw HDCControlValue.failure(
            "operationUnavailable", "the Runtime HDC control-action owner is unavailable")
        }
        result = try await hdcControlActions.preview(fields)
      case "runtime.hdc.restart":
        guard let hdcControlActions else {
          throw HDCControlValue.failure(
            "operationUnavailable", "the Runtime HDC control-action owner is unavailable")
        }
        guard Set(fields.keys) == ["controlAction", "previewId", "previewDigest"],
          case .string(let action)? = fields["controlAction"], HDCControlValue.identifier(action),
          case .string(let preview)? = fields["previewId"], HDCControlValue.identifier(preview),
          case .string(let digest)? = fields["previewDigest"], HDCControlValue.digest(digest)
        else { throw HDCControlValue.failure("invalidInput", "restart requires one exact control-action preview tuple") }
        result = try await hdcControlActions.requestRestart(
          actionID: action, previewID: preview, previewDigest: digest)
      case "runtime.tool.select":
        guard let toolSelectionActions else {
          throw HDCControlValue.failure(
            "operationUnavailable", "the Runtime tool-selection owner is unavailable")
        }
        result = try await toolSelectionActions.select(fields)
      case "control-action.show", "control-action.reconcile":
        guard Set(fields.keys) == ["controlAction"], case .string(let id)? = fields["controlAction"], HDCControlValue.identifier(id) else {
          throw HDCControlValue.failure("invalidInput", "an exact control-action identity is required")
        }
        if let controlActions {
          result = request.method == "control-action.show"
            ? try await controlActions.show(id)
            : try await controlActions.reconcile(id)
        } else if let hdcControlActions {
          result = request.method == "control-action.show"
            ? try await hdcControlActions.show(id)
            : try await hdcControlActions.reconcile(id)
        } else {
          throw HDCControlValue.failure(
            "operationUnavailable", "the Runtime control-action owner is unavailable")
        }
      case "control-action.list":
        guard Set(fields.keys).isSubset(of: ["kind", "state", "pageSize", "cursor"]) else { throw HDCControlValue.failure("invalidInput", "unknown control-action list field") }
        let size: Int
        if let value = fields["pageSize"] {
          guard case .integer(let number) = value, (1...1000).contains(number) else { throw HDCControlValue.failure("invalidInput", "invalid page size") }
          size = Int(number)
        } else { size = 100 }
        let cursor: String?
        if let value = fields["cursor"] {
          guard case .string(let text) = value, text.utf8.count <= 256 else { throw HDCControlValue.failure("invalidCursor", "invalid control-action cursor") }
          cursor = text
        } else { cursor = nil }
        let filters = fields.filter { ["kind", "state"].contains($0.key) }
        if let controlActions {
          result = try await controlActions.list(
            filters: filters, pageSize: size, cursor: cursor)
        } else if let hdcControlActions {
          result = try await hdcControlActions.list(
            filters: filters, pageSize: size, cursor: cursor)
        } else {
          throw HDCControlValue.failure(
            "operationUnavailable", "the Runtime control-action owner is unavailable")
        }
      default: return failure(id: request.id, code: .unknownMethod, message: "unknown control-action method")
      }
      return success(id: request.id, result: result)
    } catch let error as AgentExecutionControlFailure {
      return AgentWireProtocol.Response(id: request.id, ok: false, result: nil,
        error: .init(code: error.code, message: error.message, details: error.details.merging(["newDispatchCount": .integer(0)], uniquingKeysWith: { _, new in new })))
    } catch {
      return AgentWireProtocol.Response(id: request.id, ok: false, result: nil,
        error: .init(code: "recordUnreadable", message: "control-action state cannot be read or persisted", details: ["newDispatchCount": .integer(0)]))
    }
  }

  private func humanActionRequest(
    _ request: AgentWireProtocol.Request, context: RuntimeControlRequestContext
  ) async -> AgentWireProtocol.Response {
    guard let humanActionResources else {
      // Older/test compositions with only AgentExecution ownership preserve
      // their exact behavior. Production always installs the union owner.
      return await agentExecutionRequest(request)
    }
    let fields = request.params ?? [:]
    func identifier(_ key: String) throws -> String {
      guard case .string(let value)? = fields[key], AgentExecutionIntent.validIdentifier(value) else {
        throw AgentExecutionControlFailure("invalidInput", "\(key) must be a bounded resource identity")
      }
      return value
    }
    do {
      let result: JSONValue
      switch request.method {
      case "human-action.show":
        guard Set(fields.keys) == ["humanAction"] else {
          throw AgentExecutionControlFailure("invalidInput", "show requires one exact human action")
        }
        result = try await humanActionResources.show(identifier("humanAction"))
      case "human-action.list":
        guard Set(fields.keys).isSubset(of: ["ownerKind", "owner", "pageSize", "cursor"]) else {
          throw AgentExecutionControlFailure("invalidInput", "unknown human-action list field")
        }
        let size: Int
        if let value = fields["pageSize"] {
          guard case .integer(let number) = value, (1...1000).contains(number) else {
            throw AgentExecutionControlFailure("invalidInput", "pageSize must be between 1 and 1000")
          }
          size = Int(number)
        } else { size = 100 }
        let cursor: String?
        if let value = fields["cursor"] {
          guard case .string(let text) = value, text.utf8.count <= 256 else {
            throw AgentExecutionControlFailure("invalidCursor", "cursor must be a bounded opaque string")
          }
          cursor = text
        } else { cursor = nil }
        result = try await humanActionResources.list(
          filters: fields.filter { ["ownerKind", "owner"].contains($0.key) },
          pageSize: size, cursor: cursor)
      case "human-action.resume":
        guard Set(fields.keys).isSubset(of: ["resumeReference", "humanAction", "selection", "challengeResponse"]),
          Set(fields.keys).isSuperset(of: ["resumeReference", "humanAction"])
        else { throw AgentExecutionControlFailure("invalidInput", "resume requires one exact human action and reference") }
        let actionID = try identifier("humanAction")
        let reference = try identifier("resumeReference")
        guard let row = try await humanActionResources.owner(
          actionID: actionID, resumeReference: reference)
        else { throw AgentExecutionControlFailure("resourceNotFound", "human action does not exist") }
        if row.ownerKind == "controlAction" {
          guard fields["selection"] == nil else {
            throw AgentExecutionControlFailure("invalidInput", "impact approval accepts no selection")
          }
          if context.transport == .unixSocket, context.hasForegroundConsole {
            if fields["challengeResponse"] == nil {
              if let controlActions {
                result = try await controlActions.issueInteractiveChallenge(
                  actionID: actionID, resumeReference: reference)
              } else if let hdcControlActions {
                result = try await hdcControlActions.issueInteractiveChallenge(
                  actionID: actionID, resumeReference: reference)
              } else {
                throw AgentExecutionControlFailure(
                  "operationUnavailable", "control-action owner is unavailable")
              }
            } else if case .string(let response)? = fields["challengeResponse"] {
              if let controlActions {
                result = try await controlActions.consumeInteractiveChallenge(
                  actionID: row.ownerID, resumeReference: reference,
                  response: response)
              } else if let hdcControlActions {
                result = try await hdcControlActions.consumeInteractiveChallenge(
                  actionID: row.ownerID, resumeReference: reference,
                  response: response)
              } else {
                throw AgentExecutionControlFailure(
                  "operationUnavailable", "control-action owner is unavailable")
              }
            } else {
              throw AgentExecutionControlFailure(
                "invalidInput", "challengeResponse must be the bounded console challenge")
            }
          } else {
            // A transport-free/direct RPC, redirected/background console or
            // XPC response gets the same HAR back and cannot advance the owner.
            result = row.value
          }
        } else {
          guard let agentExecutions else {
            throw AgentExecutionControlFailure("operationUnavailable", "AgentExecution owner is unavailable")
          }
          let execution = try await agentExecutions.resume(
            reference: reference, actionID: actionID,
            selection: fields["selection"])
          result = try await executionResultProjection(execution)
        }
      default: return failure(id: request.id, code: .unknownMethod, message: "unknown human-action method")
      }
      return success(id: request.id, result: result)
    } catch let error as AgentExecutionControlFailure {
      var details = error.details
      details["newDispatchCount"] = .integer(0)
      details["phase"] = .string("preAdmission")
      return AgentWireProtocol.Response(
        id: request.id, ok: false, result: nil,
        error: .init(code: error.code, message: error.message, details: details))
    } catch {
      return failure(id: request.id, code: .internalError, message: "human-action resource could not be read")
    }
  }

  private func agentExecutionRequest(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    let fields = request.params ?? [:]
    func string(_ key: String) throws -> String {
      guard case .string(let value)? = fields[key], AgentExecutionIntent.validIdentifier(value) else {
        throw AgentExecutionControlFailure("invalidInput", "\(key) must be a bounded resource identity")
      }
      return value
    }
    func exact(_ keys: Set<String>, optional: Set<String> = []) throws {
      guard keys.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: keys.union(optional)) else {
        throw AgentExecutionControlFailure("invalidInput", "request fields do not match the closed method contract")
      }
    }
    do {
      if request.method == "agent.resume", let humanActionResources {
        try exact(["resumeReference"], optional: ["selection"])
        if let row = try await humanActionResources.owner(
          actionID: nil, resumeReference: string("resumeReference")),
          row.ownerKind == "controlAction"
        {
          throw AgentExecutionControlFailure(
            "admissionDenied", "agent resume cannot consume an impact approval",
            details: ["humanAction": row.value])
        }
      }
      guard let agentExecutions else {
        throw AgentExecutionControlFailure("operationUnavailable", "AgentExecution owner is unavailable")
      }
      let result: JSONValue
      switch request.method {
      case "agent.run": result = try await agentExecutions.run(fields)
      case "agent.status":
        try exact(["executionId"])
        result = try await agentExecutions.status(string("executionId"))
      case "agent.abandon":
        try exact(["executionId", "expectedGeneration"])
        let text = try string("expectedGeneration")
        guard let generation = Int64(text), generation > 0, String(generation) == text else {
          throw AgentExecutionControlFailure("invalidInput", "expectedGeneration must be a positive canonical decimal string")
        }
        result = try await agentExecutions.abandon(string("executionId"), expectedGeneration: generation)
      case "agent.resume", "human-action.resume":
        try exact(request.method == "agent.resume" ? ["resumeReference"] : ["resumeReference", "humanAction"], optional: ["selection"])
        result = try await agentExecutions.resume(
          reference: string("resumeReference"),
          actionID: request.method == "human-action.resume" ? try string("humanAction") : nil,
          selection: fields["selection"])
      case "human-action.show":
        try exact(["humanAction"])
        result = try await agentExecutions.humanAction(string("humanAction"))
      case "agent.list", "human-action.list":
        let filterKeys: Set<String> = request.method == "agent.list" ? ["state", "operation", "target"] : ["ownerKind", "owner"]
        try exact([], optional: filterKeys.union(["pageSize", "cursor"]))
        let size: Int
        if let value = fields["pageSize"] {
          guard case .integer(let number) = value, (1...1000).contains(number) else {
            throw AgentExecutionControlFailure("invalidInput", "pageSize must be between 1 and 1000")
          }
          size = Int(number)
        } else { size = 100 }
        let cursor: String?
        if let value = fields["cursor"] {
          guard case .string(let text) = value, text.utf8.count <= 256 else {
            throw AgentExecutionControlFailure("invalidCursor", "cursor must be a bounded opaque string")
          }
          cursor = text
        } else { cursor = nil }
        let filters = fields.filter { filterKeys.contains($0.key) }
        result = request.method == "agent.list"
          ? try await agentExecutions.list(filters: filters, pageSize: size, cursor: cursor)
          : try await agentExecutions.humanActions(filters: filters, pageSize: size, cursor: cursor)
      default: return failure(id: request.id, code: .unknownMethod, message: "unknown execution method")
      }
      let executionMethods: Set<String> = ["agent.run", "agent.status", "agent.resume", "human-action.resume"]
      return success(id: request.id, result: executionMethods.contains(request.method)
        ? try await executionResultProjection(result) : result)
    } catch let error as AgentExecutionControlFailure {
      var details = error.details
      // These named owner refusals occur before any new Job admission or
      // dispatch in this invocation. Store/transport/internal failures do not
      // receive this proof, since a durable publication may already exist.
      if ["invalidInput", "inputTooLarge", "invalidCursor", "idempotencyConflict", "reviewedPlanMismatch",
        "resourceConflict", "resourceNotFound", "operationUnavailable", "humanActionExpired",
        "orchestrationBudgetExpired", "orchestrationClockUntrusted", "bindingRevisionStale", "admissionDenied"
      ].contains(error.code) {
        details["phase"] = .string("preAdmission")
        details["newDispatchCount"] = .integer(0)
      }
      return AgentWireProtocol.Response(
        id: request.id, ok: false, result: nil,
        error: .init(code: error.code, message: error.message, details: details))
    } catch let error as RuntimeJobEngineError {
      switch error {
      case .rejected(.invalidInput, _), .rejected(.invalidRequest, _):
        return AgentWireProtocol.Response(id: request.id, ok: false, result: nil,
          error: .init(code: "invalidInput", message: "typed operation inputs were rejected", details: [
            "phase": .string("preAdmission"), "newDispatchCount": .integer(0),
          ]))
      default: return failure(id: request.id, code: .internalError, message: "execution could not be advanced; inspect the exact owner")
      }
    } catch {
      return failure(id: request.id, code: .internalError, message: "execution resource could not be read or advanced; inspect the exact owner")
    }
  }

  private func executionResultProjection(_ value: JSONValue) async throws -> JSONValue {
    guard case .object(var fields) = value, case .string(let jobID)? = fields["jobId"] else { return value }
    let job = try await engine.status(jobID: jobID)
    fields["jobState"] = .string(job.state)
    fields["outcomeUnknown"] = .bool(job.outcomeUnknown)
    let terminal = JobState(rawValue: job.state)?.isTerminal == true
    fields["state"] = .string(terminal ? "completed" : "jobOwned")
    fields["nextAction"] = try Self.jobNextAction(job)
    fields["job"] = .object([
      "jobId": .string(jobID), "state": .string(job.state), "outcome": .string(job.outcomeUnknown ? "outcomeUnknown" : job.state),
      "outcomeUnknown": .bool(job.outcomeUnknown), "waitingForHuman": .bool(job.waitingForHuman),
      "outstandingResidueCount": job.outstandingResidueCount.map { .integer(Int64($0)) } ?? .null,
    ])
    guard JobState(rawValue: job.state)?.isTerminal == true else { return .object(fields) }
    let snapshot = try await engine.evidenceSnapshot(jobID: jobID)
    var artifacts: [RuntimeVerifiedArtifactEvidence] = []
    var blockers: [String] = []
    let declaresNoArtifacts = RuntimeOperationCatalog.descriptor(reference: snapshot.operationReference)?.artifacts.isEmpty == true
    if let artifactStore {
      do {
        let inventory = try await artifactStore.list(jobID: jobID)
        if !declaresNoArtifacts || !inventory.isEmpty {
          let omitted = try await engine.intentionallyOmittedArtifactNames(jobID: jobID)
          artifacts = try await artifactStore.verifiedEvidenceArtifacts(jobID: jobID, intentionallyOmittedNames: omitted)
        }
      } catch { blockers.append("artifactIntegrityFailed") }
    } else if !declaresNoArtifacts { blockers.append("artifactStoreUnavailable") }
    if case .object(var evidence) = Self.encodeEvidence(snapshot: snapshot, artifacts: artifacts, blockers: blockers) {
      // Automatic Agent results disclose evidence identities, never original
      // inputs or unbounded probe detail. Sensitive bytes still require export.
      for key in ["parameters", "traceProbeBefore", "traceProbeAfter"] { evidence.removeValue(forKey: key) }
      evidence["status"] = .string(blockers.isEmpty ? "verified" : "blocked")
      fields["evidence"] = .object(evidence)
      fields["artifacts"] = evidence["artifacts"]
    }
    return .object(fields)
  }

  private func targetObservationRequest(
    _ request: AgentWireProtocol.Request, adopting: Bool
  ) async -> AgentWireProtocol.Response {
    guard let targetObservations else {
      return failure(id: request.id, code: .unknownMethod, message: "target observation owner unavailable")
    }
    do {
      if adopting {
        let reference = try Self.targetObservationReference(request.params)
        let record = try await targetObservations.adopt(reference)
        return success(id: request.id, result: .object([
          "outcome": .string("adopted"), "targetId": .string(record.targetID),
          "bindingRevision": .integer(Int64(record.bindingRevision)),
          "observationId": .string(reference.observationID),
          "snapshotGeneration": .string(String(reference.generation)),
        ]))
      }
      let following: TargetObservationReference?
      switch request.params {
      case nil, .some([:]): following = nil
      case .some(let fields) where Set(fields.keys) == ["following"]:
        guard case .object(let value)? = fields["following"] else {
          throw TargetObservationFailure("invalidInput", "following must be an observation reference")
        }
        following = try Self.targetObservationReference(value)
      default:
        throw TargetObservationFailure("invalidInput", "device observations accepts only following")
      }
      async let observationRead = engine.latestSucceededDeviceObservations()
      let snapshot = try await targetObservations.snapshot(following: following)
      async let informationRead = bootstrap?.deviceInformationSnapshotForPresentation(
        observation: snapshot)
      let observedFacts = (try? await observationRead) ?? [:]
      let information = await informationRead
      let rows: [JSONValue] = try snapshot.observations.map { row in
        guard let display = snapshot.displayNames[row.observationID] else {
          throw TargetObservationFailure(
            "recordUnreadable", "candidate display-name projection is incomplete")
        }
        let target = row.relation == nil ? nil
          : try targetStore?.candidateTarget(connectKey: row.candidate.connectKey)
        return .object([
          "observationId": .string(row.observationID),
          "candidateKey": .string(row.candidate.connectKey),
          "authorizationState": .string(row.candidate.state),
          "observationContinuity": .string(row.continuity),
          "adoptedTargetId": target.map { .string($0.targetID) } ?? .null,
          "bindingRevision": target.map { .integer(Int64($0.bindingRevision)) } ?? .null,
          "displayName": display.name.map(JSONValue.string) ?? .null,
          "displayNameGeneration": .string(String(display.generation)),
          "deviceInformation": information?.information[row.candidate.connectKey].map { value in
            .object([
              "name": value.name.map(JSONValue.string) ?? .null,
              "systemVersion": value.systemVersion.map(JSONValue.string) ?? .null,
              "transport": .string(value.transport),
              "observedAtUtc": information.map { .string($0.observedAtUTC) } ?? .null,
            ])
          } ?? .null,
          "observedFacts": target.flatMap { observedFacts[$0.targetID] }.map { value in
            .object([
              "targetId": value.targetID.map(JSONValue.string) ?? .null,
              "model": value.model.map(JSONValue.string) ?? .null,
              "firmware": value.firmware.map(JSONValue.string) ?? .null,
              "transport": value.transport.map(JSONValue.string) ?? .null,
              "confirmedAtUtc": value.confirmedAtUTC.map(JSONValue.string) ?? .null,
            ])
          } ?? .null,
        ])
      }
      return success(id: request.id, result: .object([
        "schemaVersion": .string("arkdeck.device-observations/1"),
        "snapshotGeneration": .string(String(snapshot.generation)),
        "observedAtUtc": .string(snapshot.observedAtUTC),
        "health": .string("current"), "observations": .array(rows),
      ]))
    } catch let error as TargetObservationFailure {
      var details: [String: JSONValue] = [
        "phase": .string("preAdmission"), "newDispatchCount": .integer(0),
      ]
      if let reference = error.reference {
        details["candidate"] = .string(reference.candidate)
        details["observationId"] = .string(reference.observationID)
        details["observationGeneration"] = .string(String(reference.generation))
      }
      return AgentWireProtocol.Response(
        id: request.id, ok: false, result: nil,
        error: .init(code: error.code, message: error.message, details: details))
    } catch {
      // A store error may occur after its write started. Do not invent a
      // zero-mutation receipt for that case; callers must inspect the target.
      return failure(id: request.id, code: .internalError, message: "\(error)")
    }
  }

  private static func targetObservationReference(_ fields: [String: JSONValue]?) throws
    -> TargetObservationReference
  {
    guard let fields,
      Set(fields.keys) == ["candidate", "observationId", "observationGeneration"],
      case .string(let candidate)? = fields["candidate"], (1...1024).contains(candidate.utf8.count),
      case .string(let observationID)? = fields["observationId"],
      (1...128).contains(observationID.utf8.count),
      case .string(let text)? = fields["observationGeneration"],
      text.first != "0", text.utf8.allSatisfy({ (48...57).contains($0) }),
      let generation = UInt64(text), generation > 0, generation <= UInt64(Int64.max)
    else {
      throw TargetObservationFailure(
        "invalidInput", "candidate, observationId and canonical positive observationGeneration are required")
    }
    return TargetObservationReference(candidate: candidate, observationID: observationID, generation: generation)
  }

  static func encodeOperationDescriptor(
    _ descriptor: CatalogOperationDescriptor,
    availability: RuntimeOperationAvailability?
  ) -> JSONValue {
    let reasonCodes = availability?.reasonCodes ?? [.providerNotRegistered]
    var projected: [String: JSONValue] = [
      "reference": .string(descriptor.reference),
      "title": .string(descriptor.title),
      "provider": .string(descriptor.provider.rawValue),
      "minimumEffect": .string(descriptor.minimumEffect.rawValue),
      "binding": .string(descriptor.binding.rawValue),
      "timeoutSeconds": .integer(Int64(descriptor.timeoutSeconds)),
      "stepCount": .integer(Int64(descriptor.steps.count)),
    ]
    projected["availability"] = .string(availability?.state.rawValue ?? "unavailable")
    projected["availabilityReasons"] = .array(
      (availability?.reasons ?? ["runtime availability could not be resolved"])
        .map(JSONValue.string))
    projected["availabilityReasonCodes"] = .array(reasonCodes.map { .string($0.rawValue) })
    projected["availabilityReasonOrigins"] = .array(
      reasonCodes.map { .string($0.origin.rawValue) })

    // The input contract, which this reply carried none of before CHG-2026-064.
    // A caller could learn a field's name only by being refused for omitting
    // it, and its meaning only by reading the catalog source — which is not a
    // surface anything talking to an installed daemon has.
    projected["inputs"] = .array(descriptor.inputs.map(encodeCatalogField))
    projected["outputs"] = .array(descriptor.outputs.map(encodeCatalogField))
    projected["exampleRequest"] =
      RuntimeRequestEnvelope.exampleRequestJSON(for: descriptor) ?? .null

    // The decision fields §13.2 records as missing. An Agent choosing whether
    // to submit needs to know which effects this operation may reach and what
    // authorises each of them, what the plan will do step by step and whether
    // any of it compensates, what it will produce and how private that is, and
    // whether a complete-overwrite recovery contract exists.
    projected["aliasFor"] = descriptor.aliasFor.map(JSONValue.string) ?? .null
    projected["permittedEffects"] = .array(
      descriptor.permittedEffects.map { .string($0.rawValue) })
    projected["authorization"] = .object(
      Dictionary(
        uniqueKeysWithValues: descriptor.authorization.map {
          ($0.key.rawValue, JSONValue.string($0.value.rawValue))
        }))
    projected["defaultPolicyIssuanceEnabled"] = .bool(descriptor.defaultPolicyIssuanceEnabled)
    projected["concurrencyKey"] = .string(descriptor.concurrencyKey.rawValue)
    projected["outputByteBudget"] = .integer(Int64(descriptor.outputByteBudget))
    projected["preflightAttempts"] = .integer(Int64(descriptor.preflightAttempts))
    projected["profiles"] = .array(descriptor.profiles.map(JSONValue.string))
    projected["steps"] = .array(descriptor.steps.map(encodeCatalogStep))
    projected["artifacts"] = .array(descriptor.artifacts.map(encodeCatalogArtifact))
    projected["completeOverwriteRecovery"] =
      descriptor.completeOverwriteRecovery.map { recovery in
        .object([
          "contractVersion": .string(recovery.contractVersion),
          "overwriteStepId": .string(recovery.overwriteStepID),
          "verificationStepIds": .array(recovery.verificationStepIDs.map(JSONValue.string)),
          "profiles": .array(
            recovery.profiles.map {
              .object([
                "reference": .string($0.reference),
                "coveredEffects": .array($0.coveredEffects.map(JSONValue.string)),
              ])
            }),
        ])
      } ?? .null
    return .object(projected)
  }

  /// One plan step, as an Agent needs to reason about it: what it does, what
  /// effect it may reach, whether it can be cancelled, and what undoes it.
  private static func encodeCatalogStep(_ step: CatalogStepDescriptor) -> JSONValue {
    .object([
      "stepId": .string(step.stepID),
      "kind": .string(step.kind.rawValue),
      "effect": .string(step.effect.rawValue),
      "cancellation": .string(step.cancellation.rawValue),
      "binding": .string(step.binding.rawValue),
      "optional": .bool(step.isOptional),
      "compensation": .string(step.compensation.rawValue),
      "action": step.actionReference.map {
        .object(["catalogId": .string($0.catalogID), "actionId": .string($0.actionID)])
      } ?? .null,
    ])
  }

  /// What the operation declares it will produce, and how private it is. The
  /// privacy class is what decides whether reading or exporting it needs an
  /// explicit opt-in, so a caller has to be able to see it before it starts.
  private static func encodeCatalogArtifact(_ artifact: CatalogArtifactDescriptor) -> JSONValue {
    .object([
      "name": .string(artifact.name),
      "role": .string(artifact.role.rawValue),
      "mediaType": .string(artifact.mediaType),
      "privacy": .string(artifact.privacy.rawValue),
      "required": .bool(artifact.isRequired),
      "retentionClass": .string(artifact.retentionClass.rawValue),
    ])
  }

  private static func encodeCatalogField(_ field: CatalogFieldDescriptor) -> JSONValue {
    var projected: [String: JSONValue] = [
      "name": .string(field.name),
      "type": .string(field.type.rawValue),
      "required": .bool(field.isRequired),
    ]
    if let summary = field.summary { projected["description"] = .string(summary) }
    if let declared = field.defaultValue { projected["default"] = declared }
    if let values = field.enumValues { projected["enum"] = .array(values.map(JSONValue.string)) }
    if let pattern = field.pattern { projected["pattern"] = .string(pattern) }
    if let minimum = field.minimum { projected["minimum"] = .integer(Int64(minimum)) }
    if let maximum = field.maximum { projected["maximum"] = .integer(Int64(maximum)) }
    if let maxLength = field.maxLength { projected["maxLength"] = .integer(Int64(maxLength)) }
    if let maxItems = field.maxItems { projected["maxItems"] = .integer(Int64(maxItems)) }
    return .object(projected)
  }

  private static func encodeCleanupDebt(_ debt: CleanupDebtRecord) -> JSONValue {
    .object([
      "jobId": .string(debt.jobID),
      "stepId": .string(debt.stepID),
      "remotePath": .string(debt.remotePath),
      "bundleName": debt.bundleName.map(JSONValue.string) ?? .null,
      "identity": .string(debt.identity),
      "reason": .string(debt.reason),
      "recordedAtUtc": .string(debt.recordedAtUTC),
      "retryOutcomeUnknown": .bool(
        debt.retryOutcomeUnknown == true || debt.retryAttemptStartedAtUTC != nil),
    ])
  }

  private static func encodeCodable<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = CanonicalJSONEncoders.canonical()
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
  }

  private static func jobNextAction(_ status: RuntimeJobStatus) throws -> JSONValue {
    try RuntimeJobReadProjection.nextAction(status)
  }

  static func encodeEvidence(
    snapshot: RuntimeJobEvidenceSnapshot,
    artifacts: [RuntimeVerifiedArtifactEvidence],
    blockers: [String]
  ) -> JSONValue {
    func optionalString(_ value: String?) -> JSONValue {
      value.map(JSONValue.string) ?? .null
    }
    func optionalInteger(_ value: Int?) -> JSONValue {
      value.map { .integer(Int64($0)) } ?? .null
    }
    let effectLevel = snapshot.actualEffect.flatMap {
      ["hostOnly", "readOnly", "deviceMutation", "destructive"].contains($0) ? $0 : nil
    }
    var authority: JSONValue
    if let value = snapshot.authority {
      var fields: [String: JSONValue] = [
        "kind": .string(value.kind.rawValue),
        "reference": .string(value.reference),
        "admittedAtUtc": .string(value.admittedAtUTC),
        "validUntilUtc": optionalString(value.validUntilUTC),
        "consumptionFingerprintSha256": optionalString(
          value.consumptionFingerprintSHA256),
      ]
      if let campaign = value.campaignCorrelation {
        fields["campaignId"] = .string(campaign.campaignID)
        fields["attemptId"] = .string(campaign.attemptID)
        fields["attemptOrdinal"] = .integer(Int64(campaign.attemptOrdinal))
        fields["planDigest"] = .string(campaign.planDigestSHA256)
        fields["targetBindingDigest"] = .string(campaign.targetBindingDigestSHA256)
        fields["candidateDigest"] = .string(campaign.candidateDigestSHA256)
        if let reviewDigest = campaign.reviewDigestSHA256 {
          fields["reviewDigest"] = .string(reviewDigest)
        }
        fields["brokerDigest"] = .string(campaign.brokerDigestSHA256)
      }
      if let runtime = value.runtimeCapabilityCorrelation {
        fields["reservationId"] = .string(runtime.reservationID)
        fields["useOrdinal"] = .integer(Int64(runtime.useOrdinal))
        fields["planDigest"] = .string(runtime.planDigestSHA256)
        fields["stepSetDigest"] = .string(runtime.stepSetDigestSHA256)
        fields["targetBindingDigest"] = .string(runtime.targetBindingDigestSHA256)
        fields["artifactDigest"] = optionalString(runtime.artifactSHA256)
      }
      authority = .object(fields)
    } else {
      authority = .null
    }
    let observation: JSONValue
    if let value = snapshot.observation {
      observation = .object([
        "targetId": optionalString(value.targetID),
        "bindingRevision": optionalInteger(value.bindingRevision),
        "stableIdentitySha256": optionalString(value.stableIdentitySHA256),
        "model": optionalString(value.model),
        "firmware": optionalString(value.firmware),
        "transport": optionalString(value.transport),
        "providerId": .string(value.providerID),
        "toolVersion": .string(value.toolVersion),
        "toolSha256": .string(value.toolSHA256),
        "confirmedAtUtc": optionalString(value.confirmedAtUTC),
        "confirmationMethod": .string(value.confirmationMethod),
        "preflightSteps": .array(
          value.preflightSteps.map {
            .object([
              "stepId": .string($0.stepID),
              "stepKind": .string($0.stepKind),
              "outcomeAtUtc": .string($0.outcomeAtUTC),
            ])
          }),
      ])
    } else {
      observation = .null
    }
    let recoveryEpoch: JSONValue
    if let value = snapshot.recoveryEpoch {
      recoveryEpoch = .object([
        "epochId": .string(value.epochID),
        "source": .string(value.source.rawValue),
        "stableTargetIdentitySha256": .string(value.stableTargetIdentitySHA256),
        "bindingRevision": .integer(Int64(value.bindingRevision)),
        "coveredIntents": .array(
          value.coveredIntents.map { intent in
            .object([
              "jobId": .string(intent.jobID),
              "intentEventId": .string(intent.intentEventID),
              "operationReference": .string(intent.operationReference),
              "profileReference": .string(intent.profileReference),
              "observedAtUtc": .string(intent.observedAtUTC),
              "possibleEffects": .array(intent.possibleEffects.map(JSONValue.string)),
            ])
          }),
        "uncertainEffectSetSha256": .string(value.uncertainEffectSetSHA256),
        "coverageContractVersion": .string(value.coverageContractVersion),
        "coveredEffectSetSha256": .string(value.coveredEffectSetSHA256),
        "recoveryJobId": .string(value.recoveryJobID),
        "recoveryIntentEventId": .string(value.recoveryIntentEventID),
        "operationReference": .string(value.operationReference),
        "profileReference": .string(value.profileReference),
        "materializedPlanDigestSha256": .string(value.materializedPlanDigestSHA256),
        "artifactSha256": .string(value.artifactSHA256),
        "providerExecutableSha256": .string(value.providerExecutableSHA256),
        "confirmedStepIds": .array(value.confirmedStepIDs.map(JSONValue.string)),
        "resultingTargetEpochSha256": .string(value.resultingTargetEpochSHA256),
        "establishedAtUtc": .string(value.establishedAtUTC),
        "epochSha256": .string(value.epochSHA256),
      ])
    } else {
      recoveryEpoch = .null
    }
    if case .object(var fields) = authority {
      fields["recoveryEpoch"] = recoveryEpoch
      authority = .object(fields)
    }
    return .object([
      "jobId": .string(snapshot.jobID),
      "operationReference": .string(snapshot.operationReference),
      "catalogDigest": .string(snapshot.catalogDigest),
      "targetId": .string(snapshot.targetID),
      "bindingRevision": optionalInteger(snapshot.bindingRevision),
      "providerId": .string(snapshot.providerID),
      "actualEffect": optionalString(effectLevel),
      "authority": authority,
      "observation": observation,
      "actualStepKinds": .array(snapshot.actualStepKinds.map(JSONValue.string)),
      "executionMode": .string(snapshot.executionMode),
      "terminalState": .string(snapshot.terminalState),
      "outcomeUnknown": .bool(snapshot.outcomeUnknown),
      "startedAtUtc": optionalString(snapshot.startedAtUTC),
      "firstEvidenceStepAtUtc": optionalString(snapshot.firstEvidenceStepAtUTC),
      "finishedAtUtc": optionalString(snapshot.finishedAtUTC),
      "recoveryEpoch": recoveryEpoch,
      "traceProbeBefore": encodeTraceRuntimeProbe(snapshot.traceProbeBefore),
      "traceProbeAfter": encodeTraceRuntimeProbe(snapshot.traceProbeAfter),
      "parameters": .object(snapshot.inputs ?? [:]),
      "artifacts": .array(
        artifacts.map { artifact in
          .object([
            "reference": .string(artifact.reference),
            "sha256": .string(artifact.sha256),
            "jobId": .string(artifact.jobID),
            "targetId": .string(artifact.targetID),
            "bindingRevision": optionalInteger(artifact.bindingRevision),
            "stableIdentitySha256": optionalString(artifact.stableIdentitySHA256),
            "providerId": .string(artifact.providerID),
            "byteCount": .integer(Int64(artifact.byteCount)),
            "bytesVerified": .bool(true),
          ])
        }),
      "blockers": .array(blockers.map(JSONValue.string)),
    ])
  }

  private static func encodeTraceRuntimeProbe(
    _ snapshot: TraceRuntimeProbeSnapshot?
  ) -> JSONValue {
    guard let snapshot else { return .null }
    return .object([
      "targetId": .string(snapshot.targetID),
      "bindingRevision": .integer(Int64(snapshot.bindingRevision)),
      "adapterDisposition": .string(snapshot.adapterDisposition),
      "tool": snapshot.tool.map(JSONValue.string) ?? .null,
      "family": snapshot.family.map(JSONValue.string) ?? .null,
      "supportedTags": .array(snapshot.supportedTags.map(JSONValue.string)),
      "rawHelpSha256": snapshot.rawHelpSHA256.map(JSONValue.string) ?? .null,
      "parameters": .array(
        snapshot.parameters.map { observation in
          .object([
            "name": .string(observation.name),
            "state": .string(observation.state.rawValue),
            "value": observation.value.map(JSONValue.string) ?? .null,
            "detail": observation.detail.map(JSONValue.string) ?? .null,
          ])
        }),
    ])
  }

  func success(id: String, result: JSONValue) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(id: id, ok: true, result: result, error: nil)
  }

  func failure(
    id: String, code: AgentDaemonErrorCode, message: String
  ) -> AgentWireProtocol.Response {
    AgentWireProtocol.Response(
      id: id, ok: false, result: nil,
      error: AgentWireProtocol.WireError(code: code.rawValue, message: message))
  }

  private static func addingUTCSeconds(_ seconds: Int, to value: String) -> String? {
    guard let date = ISO8601Timestamps.parseCanonicalPlain(value) else { return nil }
    return ISO8601Timestamps.string(from: date.addingTimeInterval(TimeInterval(seconds)))
  }

  private static func isMergedPRIssuerReference(_ reference: String) -> Bool {
    guard let token = reference.split(separator: " ").first,
      token.hasPrefix("PR#"),
      let number = Int(token.dropFirst(3)),
      number > 0
    else {
      return false
    }
    return true
  }
}

// MARK: - Instance document

public struct AgentDaemonInstance: Codable, Sendable, Equatable {
  public let pid: Int32
  public let socketPath: String
  public let protocolVersion: String
  public let startedAtUTC: String
}

public enum AgentDaemonStartResult: Sendable, Equatable {
  case started
  case alreadyRunning(AgentDaemonInstance)
}

// MARK: - UDS server

public final class AgentDaemonServer: @unchecked Sendable {
  public let stateDirectory: URL
  public let socketURL: URL
  private let handler: RuntimeControlPlaneHandler
  private let nowUTC: @Sendable () -> String
  private var listenerFD: Int32 = -1
  private var lockFD: Int32 = -1
  private var acceptThread: Thread?
  private let lifecycle = NSCondition()
  private var accepting = true
  private var stopped = false
  private var activeConnections: Set<Int32> = []
  private var activeRequestCount = 0

  public init(
    stateDirectory: URL,
    handler: RuntimeControlPlaneHandler,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.stateDirectory = stateDirectory
    self.socketURL = stateDirectory.appending(
      path:
        ArkDeckAgentFilesystemLayout.socketFilename)
    self.handler = handler
    self.nowUTC = nowUTC
  }

  public func start() throws -> AgentDaemonStartResult {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    let lockURL = stateDirectory.appending(path: "instance.lock")
    let instanceURL = stateDirectory.appending(path: "instance.json")
    lockFD = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else { throw AgentDaemonError.io("cannot open instance lock") }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
      close(lockFD)
      lockFD = -1
      if let data = try? Data(contentsOf: instanceURL),
        let instance = try? JSONDecoder().decode(AgentDaemonInstance.self, from: data)
      {
        return .alreadyRunning(instance)
      }
      throw AgentDaemonError.io("another instance holds the lock but left no instance document")
    }

    unlink(socketURL.path)
    listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerFD >= 0 else { throw AgentDaemonError.io("cannot create socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketURL.path
    // sun_path is 104 bytes on Darwin: a deep state directory silently
    // becomes an unusable socket, so say exactly what to do about it.
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw AgentDaemonError.io(
        "socket path is \(path.utf8.count) bytes but the platform limit is "
          + "\(MemoryLayout.size(ofValue: address.sun_path) - 1); "
          + "choose a shorter --state-dir (the socket is <state-dir>/agentd.sock)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      path.utf8CString.withUnsafeBytes { source in
        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count)))
      }
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(listenerFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else { throw AgentDaemonError.io("bind failed: errno \(errno)") }
    guard chmod(socketURL.path, 0o600) == 0 else {
      throw AgentDaemonError.io("cannot restrict socket permissions")
    }
    guard listen(listenerFD, 16) == 0 else { throw AgentDaemonError.io("listen failed") }

    let instance = AgentDaemonInstance(
      pid: getpid(), socketPath: socketURL.path,
      protocolVersion: AgentWireProtocol.version, startedAtUTC: nowUTC())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try (try encoder.encode(instance)).write(to: instanceURL, options: [])

    let thread = Thread { [weak self] in self?.acceptLoop() }
    thread.name = "arkdeck-agentd-accept"
    thread.start()
    acceptThread = thread
    return .started
  }

  public func stop() {
    drainAndStop(deadline: 0)
  }

  /// Stop accepting new work, allow current request handlers to cross their
  /// own durable boundaries, then close idle client sockets before releasing
  /// the instance lock.  A bounded deadline prevents one vanished client from
  /// making a supervisor wait forever; Runtime jobs still recover from their
  /// journal rather than being treated as completed.
  public func drainAndStop(deadline: TimeInterval) {
    let cutoff = Date().addingTimeInterval(max(0, deadline))
    lifecycle.lock()
    guard !stopped else {
      lifecycle.unlock()
      return
    }
    accepting = false
    if listenerFD >= 0 {
      close(listenerFD)
      listenerFD = -1
    }
    unlink(socketURL.path)
    while activeRequestCount > 0, Date() < cutoff {
      lifecycle.wait(until: cutoff)
    }
    // A request that already completed may leave a client waiting for the
    // next frame.  Closing its connection lets the task leave cleanly instead
    // of retaining the daemon through the shutdown deadline.
    let connections = activeConnections
    lifecycle.unlock()
    for connection in connections { Darwin.shutdown(connection, SHUT_RDWR) }
    lifecycle.lock()
    while !activeConnections.isEmpty, Date() < cutoff {
      lifecycle.wait(until: cutoff)
    }
    stopped = true
    if lockFD >= 0 {
      flock(lockFD, LOCK_UN)
      close(lockFD)
      lockFD = -1
    }
    lifecycle.broadcast()
    lifecycle.unlock()
  }

  private var isAccepting: Bool {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    return accepting && !stopped
  }

  private func register(connection: Int32) -> Bool {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    guard accepting && !stopped else { return false }
    activeConnections.insert(connection)
    return true
  }

  private func finish(connection: Int32) {
    lifecycle.lock()
    activeConnections.remove(connection)
    lifecycle.broadcast()
    lifecycle.unlock()
  }

  private func beginRequest() {
    lifecycle.lock()
    activeRequestCount += 1
    lifecycle.unlock()
  }

  private func finishRequest() {
    lifecycle.lock()
    activeRequestCount = max(0, activeRequestCount - 1)
    lifecycle.broadcast()
    lifecycle.unlock()
  }

  private func acceptLoop() {
    while isAccepting {
      let connectionFD = accept(listenerFD, nil, nil)
      guard connectionFD >= 0 else {
        if !isAccepting { return }
        continue
      }
      guard register(connection: connectionFD) else {
        close(connectionFD)
        continue
      }
      let handler = self.handler
      Task.detached { [self] in
        defer { finish(connection: connectionFD) }
        await Self.serve(
          connectionFD: connectionFD, handler: handler,
          beginRequest: { self.beginRequest() }, finishRequest: { self.finishRequest() })
      }
    }
  }

  /// Only bytes that arrived since the last search can hold the next frame
  /// terminator, so the scan starts where the previous one stopped. Re-scanning
  /// the whole buffer after every read made a large frame quadratic: a 2 MiB
  /// flash-bundle chunk encodes to a ~2.8 MB frame that arrives in ~8 KiB
  /// pieces (`net.local.stream.recvspace`), so it was rescanned ~350 times, and
  /// `Data.firstIndex(of:)` compares byte by byte through non-inlined
  /// `__DataStorage` accessors. Frame semantics are unchanged.
  private static func serve(
    connectionFD: Int32,
    handler: RuntimeControlPlaneHandler,
    beginRequest: @escaping @Sendable () -> Void,
    finishRequest: @escaping @Sendable () -> Void
  ) async {
    defer { close(connectionFD) }
    // A client that hangs up before reading leaves this socket with no reader.
    // The response write below already treats that as a short write and drops
    // the connection, but the default SIGPIPE disposition kills the process
    // before that code runs, so one interrupted client would take down a
    // daemon holding every job, session and upload. Suppressed per connection
    // rather than process-wide: `SIG_IGN` survives exec, and this process
    // spawns device tools that rely on the default disposition.
    var suppressSignal: Int32 = 1
    guard
      setsockopt(
        connectionFD, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal,
        socklen_t(MemoryLayout<Int32>.size)) == 0
    else { return }
    var buffer = Data()
    var scannedByteCount = 0  // leading bytes already known to hold no terminator
    let chunkSize = 64 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let count = read(connectionFD, &chunk, chunkSize)
      if count <= 0 { return }
      buffer.append(contentsOf: chunk[0..<count])
      if buffer.count > 4 * 1024 * 1024 { return }  // frame bomb guard
      while let terminatorOffset = frameTerminatorOffset(in: buffer, from: scannedByteCount) {
        let start = buffer.startIndex
        let line = buffer.subdata(in: start..<(start + terminatorOffset))
        buffer.removeSubrange(start...(start + terminatorOffset))
        scannedByteCount = 0
        guard !line.isEmpty else { continue }
        beginRequest()
        let response = await handler.handleLine(
          line, context: requestContext(connectionFD: connectionFD))
        var written = 0
        let total = response.count
        let sent: Bool = response.withUnsafeBytes { raw in
          guard let base = raw.baseAddress else { return false }
          while written < total {
            let result = write(connectionFD, base + written, total - written)
            if result <= 0 { return false }
            written += result
          }
          return true
        }
        // Handing the response to the socket is part of serving the request,
        // so the count drops only after the bytes are out. Reporting the
        // request finished before the write let `drainAndStop` observe an
        // idle daemon and `shutdown(SHUT_RDWR)` the connection in the gap:
        // the write then failed with EPIPE and a caller whose job had already
        // crossed every durable boundary read "connection closed before
        // response", unable to tell whether its request ran. The gap is a few
        // instructions wide, so it needs only one unlucky preemption — a
        // 200 us probe there fails the drain contract test on an idle host.
        // A client that is alive but not reading can now hold the drain until
        // its deadline instead; that is what the deadline is for, and the
        // vanished-client case the shutdown below exists for is unaffected
        // (its connection is idle between requests, never mid-response).
        finishRequest()
        if !sent { return }
      }
      scannedByteCount = buffer.count
    }
  }

  /// Offset of the first frame terminator at or after `searchedByteCount`,
  /// relative to `buffer.startIndex`, or nil while no complete frame has
  /// arrived. `memchr` is a vectorized library call where the equivalent
  /// `Collection` scan walks one byte at a time.
  private static func frameTerminatorOffset(
    in buffer: Data, from searchedByteCount: Int
  ) -> Int? {
    guard searchedByteCount < buffer.count else { return nil }
    return buffer.withUnsafeBytes { raw -> Int? in
      guard let base = raw.baseAddress,
        let hit = memchr(
          base.advanced(by: searchedByteCount), 0x0A, raw.count - searchedByteCount)
      else { return nil }
      return base.distance(to: UnsafeRawPointer(hit))
    }
  }

  /// Derive interaction eligibility from the accepted socket and the live
  /// peer process. No request field participates. stdin and stderr must still
  /// be the peer's controlling terminal and its process group must be the
  /// foreground group; a redirected stdin, background job, exited/reused PID,
  /// XPC frame or direct handler call therefore gets no console carrier.
  private static func requestContext(
    connectionFD: Int32
  ) -> RuntimeControlRequestContext {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(connectionFD, &peerUID, &peerGID) == 0,
      peerUID == geteuid()
    else { return .unixSocket(foregroundConsole: false) }
    var peerPID: pid_t = 0
    var peerPIDSize = socklen_t(MemoryLayout.size(ofValue: peerPID))
    guard getsockopt(
      connectionFD, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) == 0,
      peerPIDSize == MemoryLayout.size(ofValue: peerPID), peerPID > 1,
      peerPID != getpid()
    else { return .unixSocket(foregroundConsole: false) }

    func processInfo() -> proc_bsdinfo? {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(peerPID, PROC_PIDTBSDINFO, 0, &info, size) == size,
        info.pbi_pid == UInt32(peerPID), info.pbi_uid == peerUID,
        info.pbi_pgid > 0, info.e_tpgid > 0,
        info.pbi_pgid == info.e_tpgid,
        info.e_tdev != 0, info.e_tdev != UInt32.max
      else { return nil }
      return info
    }
    func terminal(_ descriptor: Int32, device: UInt32) -> Bool {
      var info = vnode_fdinfo()
      let size = Int32(MemoryLayout<vnode_fdinfo>.size)
      guard proc_pidfdinfo(
        peerPID, descriptor, PROC_PIDFDVNODEINFO, &info, size) == size
      else { return false }
      return mode_t(info.pvi.vi_stat.vst_mode) & S_IFMT == S_IFCHR
        && info.pvi.vi_stat.vst_rdev == device
    }
    guard let before = processInfo(),
      terminal(STDIN_FILENO, device: before.e_tdev),
      terminal(STDERR_FILENO, device: before.e_tdev),
      let after = processInfo(),
      before.pbi_start_tvsec == after.pbi_start_tvsec,
      before.pbi_start_tvusec == after.pbi_start_tvusec,
      before.pbi_pgid == after.pbi_pgid, before.e_tpgid == after.e_tpgid,
      before.e_tdev == after.e_tdev
    else { return .unixSocket(foregroundConsole: false) }
    return .unixSocket(foregroundConsole: true)
  }
}

public enum AgentDaemonError: Error, Equatable, Sendable {
  case io(String)
}
