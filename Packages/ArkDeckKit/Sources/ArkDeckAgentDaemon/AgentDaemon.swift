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

// MARK: - Wire protocol (v1)

package enum AgentWireProtocol {
  public static let version = ArkDeckAgentXPC.wireProtocolVersion
  package static let requiredMajor = 1

  package struct Request: Codable, Sendable {
    package let protocolVersion: String
    public let id: String
    public let method: String
    package let params: [String: JSONValue]?

    public init(id: String, method: String, params: [String: JSONValue]? = nil) {
      self.protocolVersion = AgentWireProtocol.version
      self.id = id
      self.method = method
      self.params = params
    }
  }

  package struct WireError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
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
  private let hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics?
  private let artifactStore: RuntimeArtifactStore?
  private let flashPrerequisiteObserver: (any RockchipFlashPrerequisiteObserving)?
  private let rockchipBootloaderStatusObserver: (any RockchipBootloaderStatusObserving)?
  private let rockchipLoaderBindingCoordinator: (any RockchipLoaderBindingCoordinating)?
  private let traceRuntimeProbe: (any TraceRuntimeProbing)?
  private let debugRuntimeProbe: (any DebugRuntimeProbing)?
  private let debugInvocationController: RuntimeDebugInvocationController?
  private let hapImports: HAPArtifactImportCoordinator
  private let workspacePatchImports: WorkspacePatchArtifactImportCoordinator
  private let flashBundleImports: FlashBundleArtifactImportCoordinator
  private let nativeLibraryImports: NativeLibraryArtifactImportCoordinator
  /// Test seam: records which methods a client invoked. Production passes
  /// nil, so this cannot affect behaviour.
  private let methodObserver: (@Sendable (String) -> Void)?

  public init(
    engine: RuntimeJobEngine,
    capabilityStore: RuntimeCapabilityStore,
    providerIDs: [String],
    nowUTC: @escaping @Sendable () -> String,
    targetStore: RuntimeTargetStore? = nil,
    bootstrap: DeviceBootstrapMachine? = nil,
    hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics? = nil,
    artifactStore: RuntimeArtifactStore? = nil,
    flashBundleImportDirectory: URL? = nil,
    flashPrerequisiteObserver: (any RockchipFlashPrerequisiteObserving)? = nil,
    rockchipBootloaderStatusObserver: (any RockchipBootloaderStatusObserving)? = nil,
    rockchipLoaderBindingCoordinator: (any RockchipLoaderBindingCoordinating)? = nil,
    traceRuntimeProbe: (any TraceRuntimeProbing)? = nil,
    debugRuntimeProbe: (any DebugRuntimeProbing)? = nil,
    debugInvocationController: RuntimeDebugInvocationController? = nil,
    methodObserver: (@Sendable (String) -> Void)? = nil
  ) {
    self.init(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providerIDs, nowUTC: nowUTC,
      targetStore: targetStore, bootstrap: bootstrap,
      hdcRuntimeDiagnostics: hdcRuntimeDiagnostics,
      artifactStore: artifactStore,
      flashBundleImportDirectory: flashBundleImportDirectory,
      flashBundleImportPolicy: .production,
      flashPrerequisiteObserver: flashPrerequisiteObserver,
      rockchipBootloaderStatusObserver: rockchipBootloaderStatusObserver,
      rockchipLoaderBindingCoordinator: rockchipLoaderBindingCoordinator,
      traceRuntimeProbe: traceRuntimeProbe,
      debugRuntimeProbe: debugRuntimeProbe,
      debugInvocationController: debugInvocationController,
      methodObserver: methodObserver)
  }

  init(
    engine: RuntimeJobEngine,
    capabilityStore: RuntimeCapabilityStore,
    providerIDs: [String],
    nowUTC: @escaping @Sendable () -> String,
    targetStore: RuntimeTargetStore?,
    bootstrap: DeviceBootstrapMachine?,
    hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics? = nil,
    artifactStore: RuntimeArtifactStore?,
    flashBundleImportDirectory: URL?,
    flashBundleImportPolicy: FlashBundleImportPolicy,
    flashPrerequisiteObserver: (any RockchipFlashPrerequisiteObserving)? = nil,
    rockchipBootloaderStatusObserver: (any RockchipBootloaderStatusObserving)? = nil,
    rockchipLoaderBindingCoordinator: (any RockchipLoaderBindingCoordinating)? = nil,
    traceRuntimeProbe: (any TraceRuntimeProbing)? = nil,
    debugRuntimeProbe: (any DebugRuntimeProbing)? = nil,
    debugInvocationController: RuntimeDebugInvocationController? = nil,
    methodObserver: (@Sendable (String) -> Void)?
  ) {
    self.engine = engine
    self.capabilityStore = capabilityStore
    self.providerIDs = providerIDs
    self.nowUTC = nowUTC
    self.targetStore = targetStore
    self.bootstrap = bootstrap
    self.hdcRuntimeDiagnostics = hdcRuntimeDiagnostics
    self.artifactStore = artifactStore
    self.flashPrerequisiteObserver = flashPrerequisiteObserver
    self.rockchipBootloaderStatusObserver = rockchipBootloaderStatusObserver
    self.rockchipLoaderBindingCoordinator = rockchipLoaderBindingCoordinator
    self.traceRuntimeProbe = traceRuntimeProbe
    self.debugRuntimeProbe = debugRuntimeProbe
    self.debugInvocationController = debugInvocationController
    self.hapImports = HAPArtifactImportCoordinator()
    self.workspacePatchImports = WorkspacePatchArtifactImportCoordinator()
    if let flashBundleImportDirectory {
      self.flashBundleImports = FlashBundleArtifactImportCoordinator(
        directoryURL: flashBundleImportDirectory,
        policy: flashBundleImportPolicy)
    } else {
      self.flashBundleImports = FlashBundleArtifactImportCoordinator(
        policy: flashBundleImportPolicy)
    }
    self.nativeLibraryImports = NativeLibraryArtifactImportCoordinator()
    self.methodObserver = methodObserver
  }

  public func handleLine(_ line: Data) async -> Data {
    let response = await handleFrame(line)
    let encoder = CanonicalJSONEncoders.canonical()
    let payload = (try? encoder.encode(response)) ?? Data("{}".utf8)
    return payload + Data("\n".utf8)
  }

  func handleFrame(_ line: Data) async -> AgentWireProtocol.Response {
    let request: AgentWireProtocol.Request
    do {
      request = try JSONDecoder().decode(AgentWireProtocol.Request.self, from: line)
    } catch {
      return failure(id: "-", code: .malformedFrame, message: "undecodable request frame")
    }
    let majorText = request.protocolVersion.split(separator: ".").first.map(String.init) ?? ""
    guard Int(majorText) == AgentWireProtocol.requiredMajor else {
      return failure(
        id: request.id, code: .unsupportedProtocolVersion,
        message: "this daemon speaks protocol major \(AgentWireProtocol.requiredMajor)")
    }
    return await dispatch(request)
  }

  private func dispatch(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    methodObserver?(request.method)
    switch request.method {
    case "health":
      return success(
        id: request.id,
        result: .object([
          "status": .string("ok"),
          "protocolVersion": .string(AgentWireProtocol.version),
          "catalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
          "providers": .array(providerIDs.map(JSONValue.string)),
        ]))

    case "runtime.hdc-status":
      guard request.params == nil || request.params?.isEmpty == true else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "runtime.hdc-status does not accept parameters")
      }
      guard let diagnostics = hdcRuntimeDiagnostics else {
        return success(
          id: request.id,
          result: .object([
            "availability": .string("unavailable"),
            "reason": .string("Runtime has no managed HDC server"),
          ]))
      }
      return success(
        id: request.id,
        result: .object([
          "availability": .string("ready"),
          "source": .string("runtimeManaged"),
          "toolSha256": .string(diagnostics.executableSHA256),
          "clientVersion": .string(diagnostics.clientVersion),
          "serverVersion": .string(diagnostics.serverVersion),
          "endpoint": .string(diagnostics.endpoint),
          "endpointSource": .string(diagnostics.endpointSource),
          "serverHealth": .string("healthy"),
          "ownership": .string("arkDeckManaged"),
          "protocolVersion": .string(AgentWireProtocol.version),
        ]))

    case "operation.list":
      let availability = await engine.operationAvailability()
      return success(
        id: request.id,
        result: .array(
          availability.map { item in
            .object([
              "reference": .string(item.reference),
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
        result: .object([
          "reference": .string(descriptor.reference),
          "title": .string(descriptor.title),
          "provider": .string(descriptor.provider.rawValue),
          "minimumEffect": .string(descriptor.minimumEffect.rawValue),
          "binding": .string(descriptor.binding.rawValue),
          "timeoutSeconds": .integer(Int64(descriptor.timeoutSeconds)),
          "stepCount": .integer(Int64(descriptor.steps.count)),
          "availability": .string(availability?.state.rawValue ?? "unavailable"),
          "availabilityReasons": .array(
            (availability?.reasons ?? ["runtime availability could not be resolved"])
              .map(JSONValue.string)),
          "availabilityReasonCodes": .array(
            (availability?.reasonCodes ?? [.providerNotRegistered])
              .map { .string($0.rawValue) }),
          "availabilityReasonOrigins": .array(
            (availability?.reasonCodes ?? [.providerNotRegistered])
              .map { .string($0.origin.rawValue) }),
        ]))

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
      guard case .string(let targetID)? = request.params?["targetId"] else {
        return failure(
          id: request.id, code: .invalidParams, message: "targetId is required")
      }
      guard let debugRuntimeProbe else {
        return failure(
          id: request.id, code: .internalError,
          message: "Debug Runtime probing is not configured")
      }
      do {
        let snapshot = try await debugRuntimeProbe.probeDebugRuntime(targetID: targetID)
        return success(
          id: request.id,
          result: .object([
            "targetId": .string(snapshot.targetID),
            "bindingRevision": .integer(Int64(snapshot.bindingRevision)),
            "packages": .array(snapshot.packages.map(JSONValue.string)),
            "portRules": .array(
              snapshot.portRules.map { rule in
                .object([
                  "direction": .string(rule.direction.rawValue),
                  "localPort": .integer(Int64(rule.localPort)),
                  "remotePort": .integer(Int64(rule.remotePort)),
                ])
              }),
            "warnings": .array(snapshot.warnings.map(JSONValue.string)),
          ]))
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

    case "capability.draft", "capability.install", "capability.revoke":
      return failure(
        id: request.id, code: .rejected,
        message:
          "RuntimeCapability administration is not an Agent-facing API; "
          + "the protected Runtime generates and consumes policy capabilities")

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

    case "job.plan":
      guard case .string(let requestJson)? = request.params?["requestJson"] else {
        return failure(id: request.id, code: .invalidParams, message: "requestJson is required")
      }
      do {
        let preview = try await engine.planOnly(Data(requestJson.utf8))
        let encoded = try JSONEncoder().encode(preview)
        let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
        return success(id: request.id, result: json)
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.submit":
      guard case .string(let requestJson)? = request.params?["requestJson"] else {
        return failure(id: request.id, code: .invalidParams, message: "requestJson is required")
      }
      do {
        let acceptance = try await engine.submit(Data(requestJson.utf8))
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(acceptance.jobID),
            "deduplicated": .bool(acceptance.deduplicated),
          ]))
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.run":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let status = try await engine.run(jobID: jobID)
        // `recovered` is a durable Runtime terminal with richer lineage. The
        // synchronous client terminal set (see AgentRuntimeExecutor) uses
        // `succeeded` for successful completion. Evidence and subsequent
        // status/list calls keep the exact `recovered` state; only this
        // completion response uses the transport terminal so automation does
        // not cancel a completed recovery Job.
        let completionState =
          status.state == JobState.recovered.rawValue
          ? JobState.succeeded.rawValue : status.state
        return success(
          id: request.id,
          result: Self.encodeStatus(status, stateOverride: completionState))
      } catch let error as RuntimeJobEngineError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.list":
      do {
        if request.params?["pageSize"] != nil || request.params?["order"] != nil
          || request.params?["includeTimeline"] != nil
          || request.params?["includeCurrent"] != nil
          || request.params?["cursor"] != nil
        {
          let options = try Self.jobListOptions(
            request.params, acceptsCursor: false, acceptsCurrent: false)
          let page = try await engine.listJobs(
            pageSize: options.pageSize, newestFirst: options.newestFirst)
          return success(
            id: request.id,
            result: .array(
              page.jobs.map {
                Self.encodeStatus($0, includeTimeline: options.includeTimeline)
              }))
        }
        let statuses = try await engine.listJobs()
        return success(id: request.id, result: .array(statuses.map { Self.encodeStatus($0) }))
      } catch let error as JobListOptionsError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch RuntimeJobEngineError.jobRecordUnreadable(let jobID) {
        return failure(
          id: request.id, code: .recordUnreadable,
          message: "Runtime job record \(jobID) is unreadable")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.list-page":
      do {
        let options = try Self.jobListOptions(
          request.params, acceptsCursor: true, acceptsCurrent: true)
        let page = try await engine.listJobs(
          pageSize: options.pageSize, cursor: options.cursor,
          newestFirst: options.newestFirst)
        let current = options.includeCurrent ? try await engine.listCurrentJobs() : []
        return success(
          id: request.id,
          result: .object([
            "jobs": .array(
              page.jobs.map {
                Self.encodeStatus($0, includeTimeline: options.includeTimeline)
              }),
            "currentJobs": .array(
              current.map {
                Self.encodeStatus($0, includeTimeline: options.includeTimeline)
              }),
            "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
          ]))
      } catch let error as JobListOptionsError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch RuntimeJobEngineError.jobRecordUnreadable(let jobID) {
        return failure(
          id: request.id, code: .recordUnreadable,
          message: "Runtime job record \(jobID) is unreadable")
      } catch {
        // This used to be `invalidParams`, which was doing two jobs: it
        // correctly named a malformed cursor as the caller's mistake, and it
        // also told a caller whose request was fine that its parameters were
        // wrong when the daemon had failed to read its own history — sending
        // it to correct a correct request and retry forever. The cursor is now
        // validated with the other parameters above, so the only thing that
        // reaches here is unexpected, and `job.list` already ends this way.
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.status":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let status = try await engine.status(jobID: jobID)
        return success(id: request.id, result: Self.encodeStatus(status))
      } catch RuntimeJobEngineError.jobNotFound {
        return failure(id: request.id, code: .notFound, message: "unknown job \(jobID)")
      } catch RuntimeJobEngineError.jobRecordUnreadable {
        return failure(
          id: request.id, code: .recordUnreadable,
          message: "Runtime job record \(jobID) is unreadable")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "job.evidence":
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let snapshot = try await engine.evidenceSnapshot(jobID: jobID)
        var artifacts: [RuntimeVerifiedArtifactEvidence] = []
        var blockers: [String] = []
        if let artifactStore {
          do {
            let omitted = try await engine.intentionallyOmittedArtifactNames(jobID: jobID)
            artifacts = try await artifactStore.verifiedEvidenceArtifacts(
              jobID: jobID, intentionallyOmittedNames: omitted)
          } catch {
            blockers.append("artifactVerification:\(error)")
          }
        } else {
          blockers.append("artifactStoreUnavailable")
        }
        return success(
          id: request.id,
          result: Self.encodeEvidence(
            snapshot: snapshot, artifacts: artifacts, blockers: blockers))
      } catch RuntimeJobEngineError.jobNotFound {
        return failure(id: request.id, code: .notFound, message: "unknown job \(jobID)")
      } catch RuntimeJobEngineError.jobRecordUnreadable {
        return failure(
          id: request.id, code: .recordUnreadable,
          message: "Runtime job record \(jobID) is unreadable")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

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
        return success(id: request.id, result: Self.encodeStatus(status))
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
      var report: [String: JSONValue] = [
        "protocolVersion": .string(AgentWireProtocol.version),
        "catalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
        "providers": .array(providerIDs.map(JSONValue.string)),
        "targetStore": .string(targetStore == nil ? "unavailable" : "ready"),
        "bootstrap": .string(bootstrap == nil ? "unavailable" : "ready"),
      ]
      if let targetStore, let targets = try? targetStore.listActive() {
        report["adoptedTargetCount"] = .integer(Int64(targets.count))
      }
      return success(id: request.id, result: .object(report))

    case "artifact.importHap.begin":
      guard artifactStore != nil, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for HAP import")
      }
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let name)? = request.params?["name"],
        case .integer(let byteCountValue)? = request.params?["byteCount"],
        case .string(let sha256)? = request.params?["sha256"],
        byteCountValue >= 0, byteCountValue <= Int64(Int.max)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId, name, byteCount and sha256 are required")
      }
      do {
        guard let target = try targetStore.find(targetID: targetID) else {
          return failure(
            id: request.id, code: .notFound, message: "unknown target \(targetID)")
        }
        let uploadID = try await hapImports.begin(
          target: target, name: name, byteCount: Int(byteCountValue), sha256: sha256)
        return success(
          id: request.id,
          result: .object([
            "uploadId": .string(uploadID),
            "maximumChunkBytes": .integer(
              Int64(HAPArtifactImportCoordinator.maximumChunkBytes)),
            "targetId": .string(target.targetID),
            "bindingRevision": .integer(Int64(target.bindingRevision)),
          ]))
      } catch let error as HAPArtifactImportError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importHap.append":
      guard artifactStore != nil, targetStore != nil else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for HAP import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"],
        case .integer(let offsetValue)? = request.params?["offset"],
        offsetValue >= 0, offsetValue <= Int64(Int.max),
        case .string(let base64)? = request.params?["base64"],
        base64.utf8.count <= ((HAPArtifactImportCoordinator.maximumChunkBytes + 2) / 3) * 4,
        let chunk = Data(base64Encoded: base64, options: [])
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "uploadId, non-negative offset and a bounded base64 chunk are required")
      }
      do {
        let nextOffset = try await hapImports.append(
          uploadID: uploadID, offset: Int(offsetValue), chunk: chunk)
        return success(
          id: request.id,
          result: .object(["nextOffset": .integer(Int64(nextOffset))]))
      } catch let error as HAPArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importHap.commit":
      guard let artifactStore, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for HAP import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      do {
        let completed = try await hapImports.commit(uploadID: uploadID)
        guard let currentTarget = try targetStore.find(targetID: completed.target.targetID),
          currentTarget.bindingRevision == completed.target.bindingRevision,
          currentTarget.stablePhysicalIdentitySHA256
            == completed.target.stablePhysicalIdentitySHA256,
          let hdcRoute = try targetStore.hdcExecutionRoute(targetID: currentTarget.targetID),
          hdcRoute.bindingRevision == currentTarget.bindingRevision
        else {
          return failure(
            id: request.id, code: .conflict,
            message: "target binding changed during HAP import")
        }
        let hdcStableIdentity = HDCObservationProviderAdapter.stableIdentitySHA256(
          connectKey: hdcRoute.connectKey)
        let jobID =
          "input-hap-\(currentTarget.targetID)-r\(currentTarget.bindingRevision)-"
          + String(hdcStableIdentity.prefix(16)) + "-"
          + String(completed.sha256.prefix(16))
        let metadata = try await artifactStore.publish(
          RuntimeArtifactPublicationRequest(
            jobID: jobID,
            sessionID: "session-\(jobID)",
            stepID: "import-hap",
            name: completed.name,
            mediaType: "application/vnd.openharmony.hap",
            privacy: .standard,
            retentionClass: .pinnedUntilVerified,
            sourceOperation: "artifact.import-hap",
            providerID: "host",
            bindingSnapshot: ArtifactBindingSnapshot(
              targetID: currentTarget.targetID,
              bindingRevision: currentTarget.bindingRevision,
              // A HAP is consumed by the HDC provider, whose identity is the
              // connect-key derivation. After Flash, the canonical target's
              // original connect key is historical; bind to the same proven
              // alias route used by plan materialization and execution.
              stableIdentitySHA256: hdcStableIdentity),
            contents: completed.contents))
        let lease = try await artifactStore.leaseReference(
          jobID: metadata.jobID, artifactID: metadata.artifactID)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(metadata.jobID),
            "artifactId": .string(metadata.artifactID),
            "lease": .string(lease),
            "name": .string(metadata.name),
            "byteCount": .integer(Int64(metadata.byteCount)),
            "sha256": .string(metadata.sha256),
            "targetId": .string(currentTarget.targetID),
            "bindingRevision": .integer(Int64(currentTarget.bindingRevision)),
            "stableIdentitySha256": .string(hdcStableIdentity),
          ]))
      } catch let error as HAPArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch let error as RuntimeArtifactError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importHap.abort":
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      let aborted = await hapImports.abort(uploadID: uploadID)
      return success(
        id: request.id, result: .object(["aborted": .bool(aborted)]))

    case "artifact.importWorkspacePatch.begin":
      guard artifactStore != nil, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for workspace patch import")
      }
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let name)? = request.params?["name"],
        case .integer(let byteCountValue)? = request.params?["byteCount"],
        case .string(let sha256)? = request.params?["sha256"],
        byteCountValue >= 0, byteCountValue <= Int64(Int.max)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId, name, byteCount and sha256 are required")
      }
      do {
        guard try targetStore.find(targetID: targetID) != nil else {
          return failure(
            id: request.id, code: .notFound, message: "unknown target \(targetID)")
        }
        let uploadID = try await workspacePatchImports.begin(
          targetID: targetID, name: name,
          byteCount: Int(byteCountValue), sha256: sha256)
        return success(
          id: request.id,
          result: .object([
            "uploadId": .string(uploadID),
            "maximumChunkBytes": .integer(
              Int64(WorkspacePatchArtifactImportCoordinator.maximumChunkBytes)),
            "targetId": .string(targetID),
          ]))
      } catch let error as WorkspacePatchArtifactImportError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importWorkspacePatch.append":
      guard artifactStore != nil, targetStore != nil else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for workspace patch import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"],
        case .integer(let offsetValue)? = request.params?["offset"],
        offsetValue >= 0, offsetValue <= Int64(Int.max),
        case .string(let base64)? = request.params?["base64"],
        base64.utf8.count
          <= ((WorkspacePatchArtifactImportCoordinator.maximumChunkBytes + 2) / 3) * 4,
        let chunk = Data(base64Encoded: base64, options: [])
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "uploadId, non-negative offset and a bounded base64 chunk are required")
      }
      do {
        let nextOffset = try await workspacePatchImports.append(
          uploadID: uploadID, offset: Int(offsetValue), chunk: chunk)
        return success(
          id: request.id,
          result: .object(["nextOffset": .integer(Int64(nextOffset))]))
      } catch let error as WorkspacePatchArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importWorkspacePatch.commit":
      guard let artifactStore, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for workspace patch import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      do {
        let completed = try await workspacePatchImports.commit(uploadID: uploadID)
        guard try targetStore.find(targetID: completed.targetID) != nil else {
          return failure(
            id: request.id, code: .conflict,
            message: "target was removed during workspace patch import")
        }
        let jobID =
          "input-workspace-patch-\(completed.targetID)-"
          + String(completed.sha256.prefix(16))
        let metadata = try await artifactStore.publish(
          RuntimeArtifactPublicationRequest(
            jobID: jobID,
            sessionID: "session-\(jobID)",
            stepID: "import-workspace-patch",
            name: completed.name,
            mediaType: "text/x-diff",
            privacy: .standard,
            retentionClass: .pinnedUntilVerified,
            sourceOperation: "artifact.import-workspace-patch",
            providerID: "host",
            bindingSnapshot: ArtifactBindingSnapshot(
              targetID: completed.targetID,
              bindingRevision: nil,
              stableIdentitySHA256: nil),
            contents: completed.contents))
        let lease = try await artifactStore.leaseReference(
          jobID: metadata.jobID, artifactID: metadata.artifactID)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(metadata.jobID),
            "artifactId": .string(metadata.artifactID),
            "lease": .string(lease),
            "name": .string(metadata.name),
            "byteCount": .integer(Int64(metadata.byteCount)),
            "sha256": .string(metadata.sha256),
            "targetId": .string(completed.targetID),
            "touchedFiles": .array(completed.touchedFiles.map(JSONValue.string)),
          ]))
      } catch let error as WorkspacePatchArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch let error as RuntimeArtifactError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importWorkspacePatch.abort":
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      let aborted = await workspacePatchImports.abort(uploadID: uploadID)
      return success(
        id: request.id, result: .object(["aborted": .bool(aborted)]))

    case "artifact.importFlashBundle.begin":
      guard artifactStore != nil, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for flash bundle import")
      }
      guard case .string(let targetID)? = request.params?["targetId"],
        case .integer(let byteCountValue)? = request.params?["byteCount"],
        case .string(let sha256)? = request.params?["sha256"],
        byteCountValue >= 0, byteCountValue <= Int64(Int.max)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId, byteCount and sha256 are required")
      }
      do {
        guard let target = try targetStore.find(targetID: targetID) else {
          return failure(
            id: request.id, code: .notFound, message: "unknown target \(targetID)")
        }
        // `name`, when supplied by an older caller, is untrusted source
        // metadata rather than an admission fact or daemon-local path. The
        // bytes are staged under an opaque ID and judged on commit by
        // gzip/tar, digest and DAYU200 structure. Keep the store's logical
        // product name server-owned so local filenames neither gate import
        // nor influence the artifact namespace.
        let uploadID = try await flashBundleImports.begin(
          target: target, name: "images.tar.gz", byteCount: Int(byteCountValue),
          sha256: sha256)
        return success(
          id: request.id,
          result: .object([
            "uploadId": .string(uploadID),
            "maximumChunkBytes": .integer(
              Int64(FlashBundleArtifactImportCoordinator.maximumChunkBytes)),
            "targetId": .string(target.targetID),
            "bindingRevision": .integer(Int64(target.bindingRevision)),
          ]))
      } catch let error as FlashBundleArtifactImportError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importFlashBundle.append":
      guard artifactStore != nil, targetStore != nil else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for flash bundle import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"],
        case .integer(let offsetValue)? = request.params?["offset"],
        offsetValue >= 0, offsetValue <= Int64(Int.max),
        case .string(let base64)? = request.params?["base64"],
        base64.utf8.count
          <= ((FlashBundleArtifactImportCoordinator.maximumChunkBytes + 2) / 3) * 4,
        let chunk = Data(base64Encoded: base64, options: [])
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "uploadId, non-negative offset and a bounded base64 chunk are required")
      }
      do {
        let nextOffset = try await flashBundleImports.append(
          uploadID: uploadID, offset: Int(offsetValue), chunk: chunk)
        return success(
          id: request.id,
          result: .object(["nextOffset": .integer(Int64(nextOffset))]))
      } catch let error as FlashBundleArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importFlashBundle.commit":
      guard let artifactStore, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for flash bundle import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      do {
        let completed = try await flashBundleImports.commit(uploadID: uploadID)
        defer { try? FileManager.default.removeItem(at: completed.fileURL) }
        guard
          let currentTarget = try targetStore.find(
            targetID: completed.target.targetID),
          currentTarget.bindingRevision == completed.target.bindingRevision,
          currentTarget.stablePhysicalIdentitySHA256
            == completed.target.stablePhysicalIdentitySHA256
        else {
          return failure(
            id: request.id, code: .conflict,
            message: "target binding changed during flash bundle import")
        }
        let jobID =
          "input-flash-\(currentTarget.targetID)-r\(currentTarget.bindingRevision)-"
          + String(completed.sha256.prefix(16))
        let metadata = try await artifactStore.publishFile(
          RuntimeArtifactFilePublicationRequest(
            jobID: jobID, sessionID: "session-\(jobID)",
            stepID: "import-flash-bundle", name: completed.name,
            mediaType: "application/gzip",
            privacy: .standard, retentionClass: .pinnedUntilVerified,
            sourceOperation: "artifact.import-flash-bundle",
            providerID: "host",
            bindingSnapshot: ArtifactBindingSnapshot(
              targetID: currentTarget.targetID,
              bindingRevision: currentTarget.bindingRevision,
              stableIdentitySHA256:
                currentTarget.stablePhysicalIdentitySHA256),
            sourceFileURL: completed.fileURL,
            expectedByteCount: completed.byteCount,
            expectedSHA256: completed.sha256))
        let lease = try await artifactStore.leaseReference(
          jobID: metadata.jobID, artifactID: metadata.artifactID)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(metadata.jobID),
            "artifactId": .string(metadata.artifactID),
            "lease": .string(lease),
            "name": .string(metadata.name),
            "byteCount": .integer(Int64(metadata.byteCount)),
            "sha256": .string(metadata.sha256),
            "targetId": .string(currentTarget.targetID),
            "bindingRevision": .integer(
              Int64(currentTarget.bindingRevision)),
            "stableIdentitySha256": .string(
              currentTarget.stablePhysicalIdentitySHA256),
          ]))
      } catch let error as FlashBundleArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch let error as RuntimeArtifactError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importFlashBundle.abort":
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      let aborted = await flashBundleImports.abort(uploadID: uploadID)
      return success(
        id: request.id, result: .object(["aborted": .bool(aborted)]))

    case "artifact.importNativeLibrary.begin":
      guard artifactStore != nil, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for native library import")
      }
      guard case .string(let targetID)? = request.params?["targetId"],
        case .string(let name)? = request.params?["name"],
        case .integer(let byteCountValue)? = request.params?["byteCount"],
        case .string(let sha256)? = request.params?["sha256"],
        byteCountValue >= 0, byteCountValue <= Int64(Int.max)
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "targetId, name, byteCount and sha256 are required")
      }
      do {
        guard let target = try targetStore.find(targetID: targetID) else {
          return failure(
            id: request.id, code: .notFound, message: "unknown target \(targetID)")
        }
        let uploadID = try await nativeLibraryImports.begin(
          target: target, name: name, byteCount: Int(byteCountValue),
          sha256: sha256)
        return success(
          id: request.id,
          result: .object([
            "uploadId": .string(uploadID),
            "maximumChunkBytes": .integer(
              Int64(NativeLibraryArtifactImportCoordinator.maximumChunkBytes)),
            "targetId": .string(target.targetID),
            "bindingRevision": .integer(Int64(target.bindingRevision)),
          ]))
      } catch let error as NativeLibraryArtifactImportError {
        return failure(id: request.id, code: .invalidParams, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importNativeLibrary.append":
      guard artifactStore != nil, targetStore != nil else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for native library import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"],
        case .integer(let offsetValue)? = request.params?["offset"],
        offsetValue >= 0, offsetValue <= Int64(Int.max),
        case .string(let base64)? = request.params?["base64"],
        base64.utf8.count
          <= ((NativeLibraryArtifactImportCoordinator.maximumChunkBytes + 2) / 3) * 4,
        let chunk = Data(base64Encoded: base64, options: [])
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "uploadId, non-negative offset and a bounded base64 chunk are required")
      }
      do {
        let nextOffset = try await nativeLibraryImports.append(
          uploadID: uploadID, offset: Int(offsetValue), chunk: chunk)
        return success(
          id: request.id,
          result: .object(["nextOffset": .integer(Int64(nextOffset))]))
      } catch let error as NativeLibraryArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importNativeLibrary.commit":
      guard let artifactStore, let targetStore else {
        return failure(
          id: request.id, code: .internalError,
          message: "artifact store and target store are required for native library import")
      }
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      do {
        let completed = try await nativeLibraryImports.commit(uploadID: uploadID)
        guard
          let currentTarget = try targetStore.find(
            targetID: completed.target.targetID),
          currentTarget.bindingRevision == completed.target.bindingRevision,
          currentTarget.stablePhysicalIdentitySHA256
            == completed.target.stablePhysicalIdentitySHA256,
          let hdcRoute = try targetStore.hdcExecutionRoute(targetID: currentTarget.targetID),
          hdcRoute.bindingRevision == currentTarget.bindingRevision
        else {
          return failure(
            id: request.id, code: .conflict,
            message: "target binding changed during native library import")
        }
        let hdcStableIdentity = HDCObservationProviderAdapter.stableIdentitySHA256(
          connectKey: hdcRoute.connectKey)
        let jobID =
          "input-so-\(currentTarget.targetID)-r\(currentTarget.bindingRevision)-"
          + String(hdcStableIdentity.prefix(16)) + "-"
          + String(completed.sha256.prefix(16))
        let metadata = try await artifactStore.publish(
          RuntimeArtifactPublicationRequest(
            jobID: jobID, sessionID: "session-\(jobID)",
            stepID: "import-native-library", name: completed.name,
            mediaType: "application/x-elf",
            privacy: .standard, retentionClass: .pinnedUntilVerified,
            sourceOperation: "artifact.import-native-library",
            providerID: "host",
            bindingSnapshot: ArtifactBindingSnapshot(
              targetID: currentTarget.targetID,
              bindingRevision: currentTarget.bindingRevision,
              // Consumed by the HDC provider: bind the lease to the
              // same proven HDC route as plan materialization, like
              // import-hap above. Only the flash bundle stays on the store
              // identity — its consumer is the Rockchip provider.
              stableIdentitySHA256: hdcStableIdentity),
            contents: completed.contents))
        let lease = try await artifactStore.leaseReference(
          jobID: metadata.jobID, artifactID: metadata.artifactID)
        return success(
          id: request.id,
          result: .object([
            "jobId": .string(metadata.jobID),
            "artifactId": .string(metadata.artifactID),
            "lease": .string(lease),
            "name": .string(metadata.name),
            "byteCount": .integer(Int64(metadata.byteCount)),
            "sha256": .string(metadata.sha256),
            "abi": .string(completed.facts.abi.rawValue),
            "elfClassBits": .integer(
              Int64(completed.facts.elfClassBits)),
            "machine": .integer(Int64(completed.facts.machine)),
            "buildId": .string(completed.facts.buildID),
            "targetId": .string(currentTarget.targetID),
            "bindingRevision": .integer(
              Int64(currentTarget.bindingRevision)),
            "stableIdentitySha256": .string(hdcStableIdentity),
          ]))
      } catch let error as NativeLibraryArtifactImportError {
        return failure(id: request.id, code: .rejected, message: error.description)
      } catch let error as RuntimeArtifactError {
        return failure(id: request.id, code: .rejected, message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.importNativeLibrary.abort":
      guard case .string(let uploadID)? = request.params?["uploadId"] else {
        return failure(id: request.id, code: .invalidParams, message: "uploadId is required")
      }
      let aborted = await nativeLibraryImports.abort(uploadID: uploadID)
      return success(
        id: request.id, result: .object(["aborted": .bool(aborted)]))

    case "artifact.list":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"] else {
        return failure(id: request.id, code: .invalidParams, message: "jobId is required")
      }
      do {
        let artifacts = try await artifactStore.list(jobID: jobID)
        return success(
          id: request.id,
          result: .array(artifacts.map(Self.encodeArtifact)))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.inspect":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"],
        case .string(let artifactID)? = request.params?["artifactId"]
      else {
        return failure(
          id: request.id, code: .invalidParams, message: "jobId and artifactId are required")
      }
      do {
        let metadata = try await artifactStore.inspect(jobID: jobID, artifactID: artifactID)
        return success(id: request.id, result: Self.encodeArtifact(metadata))
      } catch let error as RuntimeArtifactError {
        return failure(id: request.id, code: Self.artifactErrorCode(error), message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.read":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"],
        case .string(let artifactID)? = request.params?["artifactId"]
      else {
        return failure(
          id: request.id, code: .invalidParams, message: "jobId and artifactId are required")
      }
      var maximumBytes = 1 << 20
      if case .integer(let requested)? = request.params?["maxBytes"] {
        maximumBytes = max(1, min(Int(requested), 1 << 22))
      }
      var allowSensitive = false
      if case .bool(let flag)? = request.params?["allowSensitive"] { allowSensitive = flag }
      var offset = 0
      if case .integer(let requestedOffset)? = request.params?["offset"] {
        guard requestedOffset >= 0, requestedOffset <= Int64(Int.max) else {
          return failure(
            id: request.id, code: .invalidParams,
            message: "offset must be a non-negative host integer")
        }
        offset = Int(requestedOffset)
      }
      do {
        let metadata = try await artifactStore.inspect(
          jobID: jobID, artifactID: artifactID)
        let data = try await artifactStore.read(
          jobID: jobID, artifactID: artifactID, offset: offset,
          maximumBytes: maximumBytes,
          allowSensitive: allowSensitive)
        let nextOffset = offset + data.count
        return success(
          id: request.id,
          result: .object([
            "artifactId": .string(artifactID),
            "offset": .integer(Int64(offset)),
            "nextOffset": .integer(Int64(nextOffset)),
            "totalByteCount": .integer(Int64(metadata.byteCount)),
            "eof": .bool(nextOffset == metadata.byteCount),
            "byteCount": .integer(Int64(data.count)),
            "base64": .string(data.base64EncodedString()),
          ]))
      } catch let error as RuntimeArtifactError {
        if case .sensitiveAccessRequiresOptIn = error {
          return failure(
            id: request.id, code: .rejected,
            message: "artifact is sensitive; pass allowSensitive to read it")
        }
        return failure(id: request.id, code: Self.artifactErrorCode(error), message: "\(error)")
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "artifact.export":
      guard let artifactStore else {
        return failure(
          id: request.id, code: .internalError, message: "artifact store is not configured")
      }
      guard case .string(let jobID)? = request.params?["jobId"],
        case .string(let artifactID)? = request.params?["artifactId"],
        case .string(let destination)? = request.params?["destinationDirectory"]
      else {
        return failure(
          id: request.id, code: .invalidParams,
          message: "jobId, artifactId and destinationDirectory are required")
      }
      var allowSensitive = false
      if case .bool(let flag)? = request.params?["allowSensitive"] { allowSensitive = flag }
      do {
        let exported = try await artifactStore.export(
          jobID: jobID, artifactID: artifactID,
          destinationDirectory: URL(filePath: destination, directoryHint: .isDirectory),
          allowSensitive: allowSensitive)
        return success(
          id: request.id,
          result: .object([
            "artifactId": .string(artifactID),
            "exportedPath": .string(exported.path),
          ]))
      } catch let error as RuntimeArtifactError {
        if case .sensitiveAccessRequiresOptIn = error {
          return failure(
            id: request.id, code: .rejected,
            message: "artifact is sensitive; pass allowSensitive to export it")
        }
        return failure(id: request.id, code: .rejected, message: "\(error)")
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
        return success(
          id: request.id,
          result: .array(
            targets.map { record in
              .object([
                "targetId": .string(record.targetID),
                "bindingRevision": .integer(Int64(record.bindingRevision)),
                "toolVersion": .string(record.toolVersion),
                "adoptedAtUtc": .string(record.adoptedAtUTC),
              ])
            }))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "device.candidates":
      // Read-only discovery: the one enumeration the App's device list needs.
      // It calls the bootstrap's candidate read directly — never `advance`,
      // which adopts when a single Connected candidate is present — so this
      // method cannot create, change or select a binding. Adopted targets are
      // joined by connect key so a caller can tell a ready adopted device
      // from a candidate that still needs physical trust.
      guard let bootstrap else {
        return failure(
          id: request.id, code: .internalError,
          message: "bootstrap is not configured in this composition")
      }
      let usesWarmSnapshot: Bool
      switch request.params {
      case nil, .some([:]):
        usesWarmSnapshot = false
      case .some(["useWarmSnapshot": .bool(true)]):
        usesWarmSnapshot = true
      default:
        return failure(
          id: request.id, code: .invalidParams,
          message: "device.candidates accepts only useWarmSnapshot=true")
      }
      do {
        // The daemon keeps the official HDC candidate read warm outside the
        // App launch path. Reading that completed snapshot and the compact
        // local observation history are independent, so both projections are
        // still composed in one XPC response without a serial I/O chain.
        async let candidateRead =
          usesWarmSnapshot
          ? bootstrap.candidateSnapshotForPresentation()
          : bootstrap.refreshCandidateSnapshotForPresentation()
        // Historical device facts are optional decoration. A damaged or
        // temporarily unreadable history store must not hide the primary HDC
        // candidate observation from the App.
        async let observationRead = try? engine.latestSucceededDeviceObservations()
        let (candidateSnapshot, observedFacts) = try await (candidateRead, observationRead)
        let observations = observedFacts ?? [:]
        var projected: [(candidate: BootstrapCandidate, target: RuntimeTargetRecord?)] = []
        for candidate in candidateSnapshot.candidates {
          let target = try targetStore?.candidateTarget(connectKey: candidate.connectKey)
          if let target,
            let index = projected.firstIndex(where: { $0.target?.targetID == target.targetID })
          {
            func rank(_ state: String) -> Int {
              switch state {
              case "Connected": return 3
              case "Unauthorized": return 2
              case "Offline": return 1
              default: return 0
              }
            }
            if rank(candidate.state) > rank(projected[index].candidate.state) {
              projected[index] = (candidate, target)
            }
          } else {
            projected.append((candidate, target))
          }
        }
        return success(
          id: request.id,
          result: .array(
            projected.map { row in
              let observation = row.target.flatMap { observations[$0.targetID] }
              return .object([
                "connectKey": .string(row.candidate.connectKey),
                "state": .string(row.candidate.state),
                "stateObservedAtUtc": .string(candidateSnapshot.observedAtUTC),
                "stateObservationHealth": .string(candidateSnapshot.health.rawValue),
                "adoptedTargetId": row.target.map { .string($0.targetID) } ?? .null,
                "bindingRevision": row.target.map {
                  .integer(Int64($0.bindingRevision))
                } ?? .null,
                "observedFacts": observation.map {
                  .object([
                    "targetId": $0.targetID.map(JSONValue.string) ?? .null,
                    "model": $0.model.map(JSONValue.string) ?? .null,
                    "firmware": $0.firmware.map(JSONValue.string) ?? .null,
                    "transport": $0.transport.map(JSONValue.string) ?? .null,
                    "confirmedAtUtc": $0.confirmedAtUTC.map(JSONValue.string) ?? .null,
                  ])
                } ?? .null,
              ])
            }))
      } catch {
        return failure(id: request.id, code: .internalError, message: "\(error)")
      }

    case "target.adopt":
      guard let bootstrap else {
        return failure(
          id: request.id, code: .internalError,
          message: "bootstrap is not configured in this composition")
      }
      var selected: String?
      if case .string(let candidate)? = request.params?["candidate"] {
        selected = candidate
      }
      switch await bootstrap.advance(selectedConnectKey: selected) {
      case .adopted(let record):
        return success(
          id: request.id,
          result: .object([
            "outcome": .string("adopted"),
            "targetId": .string(record.targetID),
            "bindingRevision": .integer(Int64(record.bindingRevision)),
          ]))
      case .needsSelection(let candidates):
        return success(
          id: request.id,
          result: .object([
            "outcome": .string("needsSelection"),
            "candidates": .array(
              candidates.map {
                .object(["candidate": .string($0.connectKey), "state": .string($0.state)])
              }),
          ]))
      case .waitingForHuman(let kind, let prompt):
        return success(
          id: request.id,
          result: .object([
            "outcome": .string("waitingForHuman"),
            "humanActionKind": .string(kind.rawValue),
            "prompt": .string(prompt),
          ]))
      case .failed(let reason):
        return failure(id: request.id, code: .rejected, message: reason)
      }

    default:
      return failure(
        id: request.id, code: .unknownMethod, message: "unknown method \(request.method)")
    }
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

  private static func encodeArtifact(_ metadata: RuntimeArtifactMetadata) -> JSONValue {
    var status = "published"
    var detail: JSONValue = .null
    switch metadata.status {
    case .published: break
    case .missing(let reason):
      status = "missing"
      detail = .string(reason)
    case .truncated(let atBytes):
      status = "truncated"
      detail = .integer(Int64(atBytes))
    }
    return .object([
      "artifactId": .string(metadata.artifactID),
      "jobId": .string(metadata.jobID),
      "name": .string(metadata.name),
      "mediaType": .string(metadata.mediaType),
      "byteCount": .integer(Int64(metadata.byteCount)),
      "sha256": .string(metadata.sha256),
      "privacy": .string(metadata.privacy.rawValue),
      "status": .string(status),
      "statusDetail": detail,
      "sourceOperation": .string(metadata.sourceOperation),
      "createdAtUtc": .string(metadata.createdAtUTC),
      "redactionApplied": .bool(metadata.redactionApplied),
      "targetId": .string(metadata.bindingSnapshot.targetID),
      "bindingRevision": metadata.bindingSnapshot.bindingRevision
        .map { .integer(Int64($0)) } ?? .null,
      "stableIdentitySha256": metadata.bindingSnapshot.stableIdentitySHA256
        .map(JSONValue.string) ?? .null,
    ])
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

  private struct JobListOptions {
    let pageSize: Int
    let cursor: String?
    let newestFirst: Bool
    let includeTimeline: Bool
    let includeCurrent: Bool
  }

  private struct JobListOptionsError: Error, CustomStringConvertible {
    let description: String
  }

  private static func jobListOptions(
    _ params: [String: JSONValue]?, acceptsCursor: Bool, acceptsCurrent: Bool
  ) throws -> JobListOptions {
    let pageSize: Int
    if let supplied = params?["pageSize"] {
      guard case .integer(let raw) = supplied else {
        throw JobListOptionsError(description: "pageSize must be 1...1000")
      }
      guard let value = Int(exactly: raw), (1...1_000).contains(value) else {
        throw JobListOptionsError(description: "pageSize must be 1...1000")
      }
      pageSize = value
    } else {
      pageSize = 100
    }
    let cursor: String?
    if let supplied = params?["cursor"] {
      guard acceptsCursor, case .string(let value) = supplied else {
        throw JobListOptionsError(description: "cursor must be a string")
      }
      // A cursor is opaque to the caller but not arbitrary: the repository
      // requires a non-negative integer and rejects anything else as corrupt.
      // Checking the same rule here keeps a bad cursor a typed request error,
      // which is what it is, instead of letting it arrive as a storage
      // failure that is indistinguishable from the store actually breaking.
      guard let parsed = Int64(value), parsed >= 0 else {
        throw JobListOptionsError(description: "cursor must be a non-negative integer")
      }
      cursor = value
    } else {
      cursor = nil
    }
    let newestFirst: Bool
    if let supplied = params?["order"] {
      guard case .string(let value) = supplied,
        value == "oldestFirst" || value == "newestFirst"
      else {
        throw JobListOptionsError(description: "order must be oldestFirst or newestFirst")
      }
      newestFirst = value == "newestFirst"
    } else {
      newestFirst = false
    }
    let includeTimeline: Bool
    if let supplied = params?["includeTimeline"] {
      guard case .bool(let value) = supplied else {
        throw JobListOptionsError(description: "includeTimeline must be a boolean")
      }
      includeTimeline = value
    } else {
      includeTimeline = true
    }
    let includeCurrent: Bool
    if let supplied = params?["includeCurrent"] {
      guard acceptsCurrent, case .bool(let value) = supplied else {
        throw JobListOptionsError(
          description: "includeCurrent must be a boolean on job.list-page")
      }
      includeCurrent = value
    } else {
      includeCurrent = false
    }
    return JobListOptions(
      pageSize: pageSize, cursor: cursor, newestFirst: newestFirst,
      includeTimeline: includeTimeline, includeCurrent: includeCurrent)
  }

  private static func encodeStatus(
    _ status: RuntimeJobStatus,
    stateOverride: String? = nil,
    includeTimeline: Bool = true
  ) -> JSONValue {
    let encodedFailure: JSONValue
    if let failure = status.operationFailure {
      encodedFailure = .object([
        "schemaVersion": .string(failure.schemaVersion),
        "code": .string(failure.code.rawValue),
        "category": .string(failure.category.rawValue),
        "retryability": .string(failure.retryability.rawValue),
        "recovery": .string(failure.recovery.rawValue),
      ])
    } else {
      encodedFailure = .null
    }
    return .object([
      "jobId": .string(status.jobID),
      "operation": .string(status.operationReference),
      "targetId": .string(status.targetID),
      "state": .string(stateOverride ?? status.state),
      "waitingForHuman": .bool(status.waitingForHuman),
      "outcomeUnknown": .bool(status.outcomeUnknown),
      "failure": encodedFailure,
      "outstandingResidueCount": .integer(Int64(status.outstandingResidueCount ?? 0)),
      "timeline": includeTimeline ? .array(status.timeline.map(JSONValue.string)) : .null,
      "processProgress": encodeProcessProgress(status.processProgress),
      "executionMode": status.executionMode.map(JSONValue.string) ?? .null,
      "sessionId": status.sessionID.map(JSONValue.string) ?? .null,
      "actualEffect": status.actualEffect.map(JSONValue.string) ?? .null,
      "createdAtUtc": status.createdAtUTC.map(JSONValue.string) ?? .null,
      "startedAtUtc": status.startedAtUTC.map(JSONValue.string) ?? .null,
      "finishedAtUtc": status.finishedAtUTC.map(JSONValue.string) ?? .null,
      "supersededByRecoveryEpochId": status.supersededByRecoveryEpochID
        .map(JSONValue.string) ?? .null,
      "recoveryEpochId": status.recoveryEpochID.map(JSONValue.string) ?? .null,
      "resolvedByTargetAliasResolutionId": status.resolvedByTargetAliasResolutionID
        .map(JSONValue.string) ?? .null,
    ])
  }

  private static func encodeProcessProgress(
    _ progress: RuntimeJobProcessProgress?
  ) -> JSONValue {
    guard let progress else { return .null }
    return .object([
      "stepId": .string(progress.stepID),
      "phase": .string(progress.phase.rawValue),
      "unitName": progress.unitName.map(JSONValue.string) ?? .null,
      "completedUnitCount": .integer(Int64(progress.completedUnitCount)),
      "totalUnitCount": .integer(Int64(progress.totalUnitCount)),
      "currentUnitPercent": progress.currentUnitPercent
        .map { .integer(Int64($0)) } ?? .null,
    ])
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
        let response = await handler.handleLine(line)
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
}

public enum AgentDaemonError: Error, Equatable, Sendable {
  case io(String)
}
