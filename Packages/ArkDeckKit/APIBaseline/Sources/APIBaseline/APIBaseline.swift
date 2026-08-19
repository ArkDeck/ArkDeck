// Compile-time assertions over ArkDeckKit's published public API, evaluated
// from OUTSIDE the package so `package` access is invisible (the view a
// repository-external consumer has).
//
// Techniques (all zero-runtime): `T.self` proves a type is visible,
// key paths prove result fields are readable, function references prove
// entry points are callable, `catch let as E` proves structured error
// contracts are catchable. When narrowing hides anything referenced here,
// this package stops compiling — that is the gate.

import ArkDeckAgentClient
import ArkDeckAgentDaemon
import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckOpenHarmony
import ArkDeckProcess
import ArkDeckRuntime
import ArkDeckStorage
import ArkDeckWorkflows
import Foundation

// MARK: - ArkDeckProcess: execution results carry their semantics

private enum ProcessSurface {
  static let termination = \ProcessExecutionResult.termination
  static let groupTermination = \ProcessExecutionResult.processGroupTermination
  static let byteCount = \ProcessStreamCapture.totalByteCount
  static let truncated = \ProcessStreamCapture.wasTruncated
  static let executor: FoundationProcessExecutor.Type = FoundationProcessExecutor.self
  static let execute = FoundationProcessExecutor.execute(_:captureLimit:onOutput:)
  static let executeIdentityBound =
    FoundationProcessExecutor.executeIdentityBound(_:captureLimit:onOutput:)
  static let error: ProcessExecutionError.Type = ProcessExecutionError.self
}

// MARK: - ArkDeckAgentClient: runtime client entry point and error contract

private enum AgentClientSurface {
  static let client: AgentClient.Type = AgentClient.self
  static let request = AgentClient.request(method:params:id:timeoutSeconds:)

  static func branches(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as AgentClientError {
      return "\(error)"
    } catch {
      return nil
    }
  }
}

// MARK: - ArkDeckAgentDaemon: daemon entry point, instance identity, error

private enum DaemonSurface {
  static let server: AgentDaemonServer.Type = AgentDaemonServer.self
  static let makeServer = AgentDaemonServer.init(stateDirectory:handler:nowUTC:)
  static let start = AgentDaemonServer.start
  static let socketPath = \AgentDaemonInstance.socketPath
  static let protocolVersion = \AgentDaemonInstance.protocolVersion

  static func branches(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as AgentDaemonError {
      return "\(error)"
    } catch {
      return nil
    }
  }
}

// MARK: - ArkDeckRuntime: v2 wire models, request semantics, rejection contract

private enum RuntimeSurface {
  static let errorCodes = RuntimeOperationErrorCode.allCases
  static let requestedOutputs = \RuntimeOperationRequest.requestedOutputs
  static let campaignReservation = \RuntimeOperationRequest.campaignReservation
  static let clientContext = \RuntimeOperationRequest.clientContext
  static let rejection: RuntimeOperationRequestRejection.Type =
    RuntimeOperationRequestRejection.self
  static let humanAction: HumanActionRequired.Type = HumanActionRequired.self
}

// MARK: - ArkDeckCore: job/catalog vocabulary

private enum CoreSurface {
  static let jobStates = JobState.allCases
  static let failureClassifications = WorkflowFailureClassification.allCases
  static let catalog: CatalogOperationDescriptor.Type = CatalogOperationDescriptor.self
  static let issuerKind: RuntimeCapabilityIssuer.Kind.Type = RuntimeCapabilityIssuer.Kind.self
}

// MARK: - ArkDeckOpenHarmony: probe classification vocabulary

private enum OpenHarmonySurface {
  static let probe: HDCServerProbeClassification.Type = HDCServerProbeClassification.self
  static let authorization: HDCAuthorizationState.Type = HDCAuthorizationState.self
  static let subserver: HDCSubserverCapability.Type = HDCSubserverCapability.self
}

// MARK: - ArkDeckWorkflows: discovery vocabulary

private enum WorkflowsSurface {
  static let rockUSBMode = RockchipDeviceMode.loader
}

// MARK: - ArkDeckStorage: strict-JSON public error contract (#1267)

private enum StorageSurface {
  static func branches(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as ArkDeckStorage.StrictJSONError {
      return "\(error)"
    } catch {
      return nil
    }
  }
}

// MARK: - ArkDeckLaunchAgent: service lifecycle entry, error contract, status

private enum LaunchAgentSurface {
  static let module: ArkDeckLaunchAgent.Type = ArkDeckLaunchAgent.self
  static let service: LaunchAgentService.Type = LaunchAgentService.self
  static let makeService = LaunchAgentService.init(
    paths:runner:fileManager:uid:nowUTC:)
  static let install = LaunchAgentService.install(
    daemonBundleSource:hdcExecutable:workspace:beforeBootstrap:)
  static let status = LaunchAgentService.status
  static let installed = \LaunchAgentStatus.installed
  static let loaded = \LaunchAgentStatus.loaded

  static func branches(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as LaunchAgentServiceError {
      return "\(error)"
    } catch {
      return nil
    }
  }
}
