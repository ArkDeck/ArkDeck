// App-facing ArkUI UI Dump projection over Runtime's read-only XPC door.
//
// The accepted UI contract has four canonical window-scoped recipes, while
// the currently published capture.diagnostics@1 request has no recipeId,
// windowId, or componentId input. This facade preserves that distinction: it
// exposes exact Catalog facts and safe local validation, but no App import,
// submission, parameter mutation, remote-path, or command surface.

import ArkDeckCore
import Foundation
import os

public enum UIDumpRecipeID: String, CaseIterable, Sendable {
  case nodeSummary
  case elementTree
  case fullDefaultTree
  case componentDetail
}

public struct UIDumpRecipeDefinition: Sendable, Equatable, Identifiable {
  public let id: UIDumpRecipeID
  package let candidateArguments: [String]
  public let requiresComponentID: Bool

  public init(
    id: UIDumpRecipeID, candidateArguments: [String], requiresComponentID: Bool = false
  ) {
    self.id = id
    self.candidateArguments = candidateArguments
    self.requiresComponentID = requiresComponentID
  }

  public func displayArguments(windowID: String?, componentID: String?) -> String {
    candidateArguments.map { token in
      switch token {
      case "{windowId}": windowID.flatMap { $0.isEmpty ? nil : $0 } ?? "<windowId>"
      case "{componentId}": componentID.flatMap { $0.isEmpty ? nil : $0 } ?? "<componentId>"
      default: token
      }
    }.joined(separator: " ")
  }
}

public enum UIDumpRecipeCatalog {
  /// elementTree leads: it is the default selection and the first option a
  /// reader compares against the echoed hidumper arguments.
  public static let definitions: [UIDumpRecipeDefinition] = [
    UIDumpRecipeDefinition(
      id: .elementTree,
      candidateArguments: ["-w", "{windowId}", "-element", "-c"]),
    UIDumpRecipeDefinition(
      id: .nodeSummary, candidateArguments: ["-w", "{windowId}", "-default"]),
    UIDumpRecipeDefinition(
      id: .fullDefaultTree,
      candidateArguments: ["-w", "{windowId}", "-default", "-all"]),
    UIDumpRecipeDefinition(
      id: .componentDetail,
      candidateArguments: [
        "-w", "{windowId}", "-element", "-lastpage", "{componentId}",
      ],
      requiresComponentID: true),
  ]

  public static func definition(_ id: UIDumpRecipeID) -> UIDumpRecipeDefinition {
    definitions.first { $0.id == id }!
  }
}

public enum UIDumpIdentifierFailure: String, Sendable, Equatable {
  case missing
  case notDecimal
  case tooLong
}

public enum UIDumpIdentifierValidation: Sendable, Equatable {
  case valid(String)
  case invalid(UIDumpIdentifierFailure)
}

/// The current accepted UI uses decimal device identifiers. Keeping this
/// validator stricter than the generic workflow identifier prevents leading
/// options, whitespace, separators, control characters, and shell fragments.
public enum UIDumpIdentifierValidator {
  public static func validate(_ value: String) -> UIDumpIdentifierValidation {
    guard !value.isEmpty else { return .invalid(.missing) }
    guard value.count <= 20 else { return .invalid(.tooLong) }
    guard value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      return .invalid(.notDecimal)
    }
    return .valid(value)
  }
}

public enum UIDumpDebugParameterPolicy: String, CaseIterable, Sendable {
  case unchanged
  case temporaryRestore
  case persistentlyEnabled

  public var requiresMutation: Bool { self != .unchanged }
}

public enum UIDumpRuntimeAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reasons: [String])
}

public struct UIDumpOperationPresentation: Sendable, Equatable {
  public let reference: String
  public let title: String
  public let availability: UIDumpRuntimeAvailability
  public let minimumEffect: String
  package let permittedEffects: [String]
  package let inputNames: [String]
  package let artifactNames: [String]
  public let supportsWindowInventory: Bool
  public let supportsScreenComponentTree: Bool
  public let supportsCanonicalWindowRecipes: Bool

  public init(
    reference: String,
    title: String,
    availability: UIDumpRuntimeAvailability,
    minimumEffect: String,
    permittedEffects: [String],
    inputNames: [String],
    artifactNames: [String],
    supportsWindowInventory: Bool,
    supportsScreenComponentTree: Bool,
    supportsCanonicalWindowRecipes: Bool
  ) {
    self.reference = reference
    self.title = title
    self.availability = availability
    self.minimumEffect = minimumEffect
    self.permittedEffects = permittedEffects
    self.inputNames = inputNames
    self.artifactNames = artifactNames
    self.supportsWindowInventory = supportsWindowInventory
    self.supportsScreenComponentTree = supportsScreenComponentTree
    self.supportsCanonicalWindowRecipes = supportsCanonicalWindowRecipes
  }
}

public struct UIDumpTargetPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let bindingRevision: Int
  public let toolVersion: String
  public let adoptedAtUTC: String

  public init(id: String, bindingRevision: Int, toolVersion: String, adoptedAtUTC: String) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
  }
}

public struct UIDumpJobPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  public let outstandingResidueCount: Int

  public var needsAttention: Bool {
    waitingForHuman || outcomeUnknown || outstandingResidueCount > 0
  }

  public init(
    id: String, targetID: String, state: String, waitingForHuman: Bool,
    outcomeUnknown: Bool, outstandingResidueCount: Int
  ) {
    self.id = id
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.outstandingResidueCount = outstandingResidueCount
  }
}

public struct UIDumpWorkspacePresentation: Sendable, Equatable {
  public let operation: UIDumpOperationPresentation
  public let targets: [UIDumpTargetPresentation]
  public let relatedJobs: [UIDumpJobPresentation]
  public let targetLoadFailure: String?
  public let jobLoadFailure: String?

  public init(
    operation: UIDumpOperationPresentation,
    targets: [UIDumpTargetPresentation],
    relatedJobs: [UIDumpJobPresentation],
    targetLoadFailure: String? = nil,
    jobLoadFailure: String? = nil
  ) {
    self.operation = operation
    self.targets = targets
    self.relatedJobs = relatedJobs
    self.targetLoadFailure = targetLoadFailure
    self.jobLoadFailure = jobLoadFailure
  }

  public static let loading = UIDumpWorkspacePresentation(
    operation: UIDumpApplicationFacade.operationPresentation(availability: .checking),
    targets: [], relatedJobs: [])
}

public protocol UIDumpApplicationProviding: Sendable {
  func refreshWorkspace() async -> UIDumpWorkspacePresentation
}

public enum UIDumpApplicationFacade {
  public static let operationReference = "capture.diagnostics@1"

  private static let descriptor = RuntimeOperationCatalog.descriptor(
    reference: operationReference)!

  public static func make() -> any UIDumpApplicationProviding {
    UIDumpProductionApplicationProvider()
  }

  static func operationPresentation(
    availability: UIDumpRuntimeAvailability
  ) -> UIDumpOperationPresentation {
    let inputNames = descriptor.inputs.map(\.name)
    return UIDumpOperationPresentation(
      reference: descriptor.reference,
      title: descriptor.title,
      availability: availability,
      minimumEffect: descriptor.minimumEffect.rawValue,
      permittedEffects: descriptor.permittedEffects.map(\.rawValue),
      inputNames: inputNames,
      artifactNames: descriptor.artifacts.map(\.name),
      supportsWindowInventory: descriptor.steps.contains {
        $0.actionReference?.catalogID == "arkdeck-diagnostics"
          && $0.actionReference?.actionID == "windowInventory"
      },
      supportsScreenComponentTree: inputNames.contains("uiComponentTree"),
      supportsCanonicalWindowRecipes: inputNames.contains("recipeId")
        && inputNames.contains("windowId")
        && inputNames.contains("componentId"))
  }
}

private actor UIDumpProductionApplicationProvider: UIDumpApplicationProviding {
  func refreshWorkspace() async -> UIDumpWorkspacePresentation {
    async let operations = UIDumpXPCReadTransport.request(method: "operation.list")
    async let targets = UIDumpXPCReadTransport.request(method: "target.list")
    async let jobs = UIDumpXPCReadTransport.request(method: "job.list")
    return UIDumpWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      jobResponse: await jobs)
  }
}

enum UIDumpWorkspaceResponseDecoding {
  static func presentation(
    operationResponse: Result<Data, UIDumpXPCReadFailure>,
    targetResponse: Result<Data, UIDumpXPCReadFailure>,
    jobResponse: Result<Data, UIDumpXPCReadFailure>
  ) -> UIDumpWorkspacePresentation {
    let targets = decodeTargets(targetResponse)
    let jobs = decodeJobs(jobResponse)
    return UIDumpWorkspacePresentation(
      operation: UIDumpApplicationFacade.operationPresentation(
        availability: decodeAvailability(operationResponse)),
      targets: targets.value ?? [],
      relatedJobs: jobs.value ?? [],
      targetLoadFailure: targets.failure,
      jobLoadFailure: jobs.failure)
  }

  private static func decodeAvailability(
    _ response: Result<Data, UIDumpXPCReadFailure>
  ) -> UIDumpRuntimeAvailability {
    switch response {
    case .failure(let failure): return .unavailable(reasons: [failure.message])
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure): return .unavailable(reasons: [failure.message])
      case .success(let entries):
        guard
          let entry = entries.first(where: {
            $0["reference"] as? String == UIDumpApplicationFacade.operationReference
          }),
          let state = entry["availability"] as? String,
          let reasons = entry["reasons"] as? [String]
        else {
          return .unavailable(
            reasons: ["capture.diagnostics@1 is missing complete availability facts"])
        }
        return state == "available"
          ? .available
          : .unavailable(
            reasons: reasons.isEmpty
              ? ["Runtime did not report an availability reason"] : reasons)
      }
    }
  }

  private static func decodeTargets(
    _ response: Result<Data, UIDumpXPCReadFailure>
  ) -> UIDumpDecodedList<UIDumpTargetPresentation> {
    switch response {
    case .failure(let failure): return UIDumpDecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure): return UIDumpDecodedList(failure: failure.message)
      case .success(let entries):
        var values: [UIDumpTargetPresentation] = []
        for entry in entries {
          guard
            let id = entry["targetId"] as? String,
            let revision = entry["bindingRevision"] as? Int,
            let toolVersion = entry["toolVersion"] as? String,
            let adoptedAtUTC = entry["adoptedAtUtc"] as? String
          else {
            return UIDumpDecodedList(
              failure: "Runtime returned a target without complete binding facts")
          }
          values.append(
            UIDumpTargetPresentation(
              id: id, bindingRevision: revision, toolVersion: toolVersion,
              adoptedAtUTC: adoptedAtUTC))
        }
        return UIDumpDecodedList(value: values)
      }
    }
  }

  private static func decodeJobs(
    _ response: Result<Data, UIDumpXPCReadFailure>
  ) -> UIDumpDecodedList<UIDumpJobPresentation> {
    switch response {
    case .failure(let failure): return UIDumpDecodedList(failure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure): return UIDumpDecodedList(failure: failure.message)
      case .success(let entries):
        var values: [UIDumpJobPresentation] = []
        for entry in entries {
          guard let operation = entry["operation"] as? String else { continue }
          guard operation == UIDumpApplicationFacade.operationReference else { continue }
          guard
            let id = entry["jobId"] as? String,
            let targetID = entry["targetId"] as? String,
            let state = entry["state"] as? String,
            let waitingForHuman = entry["waitingForHuman"] as? Bool,
            let outcomeUnknown = entry["outcomeUnknown"] as? Bool,
            let residueCount = entry["outstandingResidueCount"] as? Int
          else {
            return UIDumpDecodedList(
              failure: "Runtime returned an incomplete diagnostics job")
          }
          values.append(
            UIDumpJobPresentation(
              id: id, targetID: targetID, state: state,
              waitingForHuman: waitingForHuman, outcomeUnknown: outcomeUnknown,
              outstandingResidueCount: residueCount))
        }
        return UIDumpDecodedList(value: values)
      }
    }
  }

  private static func decodeResultArray(
    _ data: Data
  ) -> Result<[[String: Any]], UIDumpResponseFailure> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(UIDumpResponseFailure(message: "Runtime returned an unreadable response"))
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .failure(
        UIDumpResponseFailure(message: "Runtime refused the request: \(code) — \(message)"))
    }
    guard object["ok"] as? Bool == true, let result = object["result"] as? [[String: Any]] else {
      return .failure(UIDumpResponseFailure(message: "Runtime returned no result list"))
    }
    return .success(result)
  }
}

private struct UIDumpResponseFailure: Error {
  let message: String
}

private struct UIDumpDecodedList<Value> {
  let value: [Value]?
  let failure: String?

  init(value: [Value]) {
    self.value = value
    failure = nil
  }

  init(failure: String) {
    value = nil
    self.failure = failure
  }
}

enum UIDumpXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)

  var message: String {
    switch self {
    case .transport(let message): message
    }
  }
}

private enum UIDumpXPCReadTransport {
  static func request(method: String) async -> Result<Data, UIDumpXPCReadFailure> {
    let frame: Data
    do {
      frame = try JSONSerialization.data(
        withJSONObject: ["v": 1, "id": UUID().uuidString, "method": method])
    } catch {
      return .failure(.transport("Could not compose a Runtime request"))
    }
    return await withCheckedContinuation { continuation in
      let box = XPCConnectionBox(
        NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()
      let answered = OSAllocatedUnfairLock(initialState: false)
      @Sendable func finish(_ result: Result<Data, UIDumpXPCReadFailure>) {
        let alreadyAnswered = answered.withLock { state -> Bool in
          if state { return true }
          state = true
          return false
        }
        guard !alreadyAnswered else { return }
        box.connection.invalidate()
        continuation.resume(returning: result)
      }
      let proxy =
        connection.remoteObjectProxyWithErrorHandler { error in
          finish(
            .failure(
              .transport(
                "ArkDeck Runtime is not reachable: \(error.localizedDescription)")))
        } as? ArkDeckAgentXPCProtocol
      guard let proxy else {
        finish(.failure(.transport("ArkDeck Runtime is not reachable")))
        return
      }
      proxy.sendRequestFrame(frame) { data, refusal in
        if let refusal {
          finish(.failure(.transport("Runtime transport refused this request: \(refusal)")))
        } else if let data {
          finish(.success(data))
        } else {
          finish(.failure(.transport("Runtime returned neither a response nor a reason")))
        }
      }
    }
  }
}
