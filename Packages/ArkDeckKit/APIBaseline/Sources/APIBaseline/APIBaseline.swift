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
import ArkDeckClientKit
import ArkDeckCore
import ArkDeckRuntime
import ArkDeckTraceAdapter
import Foundation

private enum TraceAdapterSurface {
  static let bundleIdentifier = ArkDeckTraceConfiguration.bundleIdentifier
  static let recentDocumentsKey = ArkDeckTraceConfiguration.recentDocumentsKey
  static let supportedTraceExtensions = ArkDeckTraceConfiguration.supportedTraceExtensions
  static let make = ArkDeckTraceConfiguration.make(bundleURL:cachesDirectory:)
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

// MARK: - ArkDeckRuntime: current v1 wire models, request semantics, rejection contract

private enum RuntimeSurface {
  static let errorCodes = RuntimeOperationErrorCode.allCases
  static let requestedOutputs = \RuntimeOperationRequest.requestedOutputs
  static let authorization = \RuntimeOperationRequest.authorization
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

// MARK: - ArkDeckClientKit: discovery vocabulary

private enum ClientKitSurface {
  static let rockUSBMode = RockchipDeviceMode.loader
}
