// Transport-neutral `task.*` application service (CHG-2026-054, TASK-HTP-001).
//
// The product-facing autonomous debug surface. `job.*` stays exactly as it
// was: the low-level safe execution primitive the harness itself uses. A
// caller here submits a *typed* task - a goal, a target, criteria and
// budgets - and never an operation argv, a remote path or a device flag.
//
// Every method is a thin projection over the coordinator. A transport adapter
// supplies an opaque request ID, JSON parameters, and platform-specific
// application-reference validation. This module never imports a device
// provider or constructs platform command arguments.

import ArkDeckCore
import Foundation

package enum HarnessTaskMethodErrorCode: String, Sendable {
  case unknownMethod
  case invalidParams
  case rejected
  case notFound
  case internalError
}

package struct HarnessTaskMethodResponse: Sendable {
  package let id: String
  package let result: JSONValue?
  package let errorCode: HarnessTaskMethodErrorCode?
  package let errorMessage: String?
}

package struct HarnessTaskMethodService: Sendable {
  private struct MethodRequest: Sendable {
    let id: String
    let params: [String: JSONValue]?
  }

  private let harness: HarnessTaskCoordinator
  private let validateApplicationReference:
    @Sendable (_ bundleName: String, _ abilityName: String?) throws -> Void

  package init(
    coordinator: HarnessTaskCoordinator,
    applicationReferenceValidator:
      @escaping @Sendable (
        _ bundleName: String, _ abilityName: String?
      ) throws -> Void
  ) {
    self.harness = coordinator
    self.validateApplicationReference = applicationReferenceValidator
  }

  private static let defaultBudgets = HarnessTaskBudgets(
    maxRounds: 8, maxWallClockSeconds: 1800, maxArtifactBytes: 64 << 20, maxE1Mutations: 0,
    maxNoProgressRounds: 2, maxActionRetriesPerRun: 2, maxModelCalls: 24)

  package func handle(
    _ method: String,
    requestID: String,
    params: [String: JSONValue]?
  ) async -> HarnessTaskMethodResponse {
    let request = MethodRequest(id: requestID, params: params)

    func taskID() -> String? {
      if case .string(let value)? = request.params?["htaskId"] { return value }
      return nil
    }

    do {
      switch method {
      case "task.submit":
        let submission = try Self.decodeSubmission(
          request.params,
          applicationReferenceValidator: validateApplicationReference)
        let snapshot = try await harness.submit(submission)
        return success(id: request.id, result: Self.encodeTask(snapshot))

      case "task.list":
        let snapshots = try await harness.list()
        return success(id: request.id, result: .array(snapshots.map(Self.encodeTask)))

      case "task.status":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        return success(id: request.id, result: Self.encodeTask(try await harness.status(id)))

      case "task.result":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        let snapshot = try await harness.status(id)
        return success(
          id: request.id,
          result: .object([
            "htaskId": .string(snapshot.htaskID),
            "lifecycle": .string(snapshot.lifecycle.rawValue),
            "stage": .string(snapshot.stage.rawValue),
            "waitReason": snapshot.waitReason.map { .string($0.rawValue) } ?? .null,
            "conditions": .array(snapshot.conditions.map(Self.encode)),
            "status": .string(snapshot.status.rawValue),
            "phase": .string(snapshot.phase.rawValue),
            // A result exists only when the task reached a terminal status
            // or a human block. There is no "probably done" projection.
            "result": snapshot.result.map(Self.encode) ?? .null,
          ]))

      case "task.events":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        let events = try await harness.events(id)
        return success(id: request.id, result: .array(events.map(Self.encode)))

      case "task.evaluations":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        let evaluations = try await harness.evaluations(id)
        return success(id: request.id, result: .array(evaluations.map(Self.encode)))

      case "task.attempts":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        let attempts = try await harness.attempts(id)
        return success(id: request.id, result: .array(attempts.map(Self.encode)))

      case "task.humanActions":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        let actions = try await harness.humanActions(id)
        return success(id: request.id, result: .array(actions.map(Self.encode)))

      case "task.memory":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        let entries = try await harness.taskMemory(id)
        return success(id: request.id, result: .array(entries.map(Self.encode)))

      case "task.reconcile":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        let outcome = try await harness.reconcile(id)
        return success(
          id: request.id,
          result: .object([
            "action": .string(outcome.action.rawValue),
            "reasonCode": .string(outcome.reasonCode),
            "dispatchedJobId": outcome.dispatchedJobID.map(JSONValue.string) ?? .null,
            "task": Self.encodeTask(outcome.snapshot),
          ]))

      case "task.proposePatch":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        guard case .string(let proposalJSON)? = request.params?["proposalJson"],
          !proposalJSON.isEmpty
        else {
          return failure(
            id: request.id, code: .invalidParams,
            message: "proposalJson is required")
        }
        let outcome = try await harness.proposePatch(
          id, proposalJSON: Data(proposalJSON.utf8))
        return success(
          id: request.id,
          result: .object([
            "action": .string(outcome.action.rawValue),
            "reasonCode": .string(outcome.reasonCode),
            "dispatchedJobId": outcome.dispatchedJobID.map(JSONValue.string) ?? .null,
            "task": Self.encodeTask(outcome.snapshot),
          ]))

      case "task.pause":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        return success(id: request.id, result: Self.encodeTask(try await harness.pause(id)))

      case "task.resume":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        guard case .string(let resolution)? = request.params?["resolution"] else {
          return failure(
            id: request.id, code: .invalidParams,
            message: "resolution is required: a human block is only left through a typed decision")
        }
        return success(
          id: request.id,
          result: Self.encodeTask(try await harness.resume(id, resolution: resolution)))

      case "task.cancel":
        guard let id = taskID() else {
          return failure(id: request.id, code: .invalidParams, message: "htaskId is required")
        }
        return success(id: request.id, result: Self.encodeTask(try await harness.cancel(id)))

      case "task.workspaceGC":
        let retention = try Self.decodeRetention(request.params)
        let findings = try await harness.sweepEvolutionWorkspaces(retention: retention)
        return success(
          id: request.id,
          result: .object([
            "dryRun": .bool(retention.dryRun),
            "reclaimedBytes": .integer(
              findings.reduce(Int64(0)) {
                switch $1.disposition {
                case .destroyed, .wouldDestroy: $0 + $1.reclaimedBytes
                default: $0
                }
              }),
            "workspaces": .array(
              findings.map { finding in
                .object([
                  "workspaceId": .string(finding.workspaceID),
                  "htaskId": finding.htaskID.map(JSONValue.string) ?? .null,
                  "disposition": .string(finding.disposition.rawValue),
                  "reclaimedBytes": .integer(finding.reclaimedBytes),
                ])
              }),
          ]))

      default:
        return failure(
          id: request.id, code: .unknownMethod, message: "unknown method \(method)")
      }
    } catch let error as HarnessCoordinatorError {
      switch error {
      case .notFound(let id):
        return failure(id: request.id, code: .notFound, message: "unknown task \(id)")
      case .malformedPatchProposal(let reason):
        return failure(id: request.id, code: .invalidParams, message: reason)
      default:
        return failure(id: request.id, code: .rejected, message: "\(error)")
      }
    } catch let error as HarnessTaskSubmissionError {
      return failure(id: request.id, code: .invalidParams, message: "\(error)")
    } catch let error as HarnessEvolutionWorkspaceRetentionError {
      return failure(id: request.id, code: .invalidParams, message: "\(error)")
    } catch let error as HarnessTaskStoreError {
      if case .notFound(let id) = error {
        return failure(id: request.id, code: .notFound, message: "unknown task \(id)")
      }
      return failure(id: request.id, code: .internalError, message: "\(error)")
    } catch {
      return failure(id: request.id, code: .internalError, message: "\(error)")
    }
  }

  // MARK: - Wire decoding

  /// Default retention: a week of post-mortem lifetime and the two most
  /// recently terminal trees. A caller can only narrow or widen how long
  /// terminal trees linger — active and unknown workspaces stay untouchable.
  private static func decodeRetention(
    _ params: [String: JSONValue]?
  ) throws -> HarnessEvolutionWorkspaceRetention {
    func integer(_ key: String) throws -> Int? {
      switch params?[key] {
      case .integer(let value): return Int(value)
      case .unsignedInteger(let value): return Int(value)
      case .none, .null: return nil
      default: throw HarnessEvolutionWorkspaceRetentionError.malformedBound(key)
      }
    }
    var dryRun = false
    if case .bool(let value)? = params?["dryRun"] { dryRun = value }
    return try HarnessEvolutionWorkspaceRetention(
      minimumTerminalAgeSeconds: (try integer("retainDays") ?? 7) * 86_400,
      retainLatestTerminalCount: try integer("retainLast") ?? 2,
      dryRun: dryRun)
  }

  private static func decodeSubmission(
    _ params: [String: JSONValue]?,
    applicationReferenceValidator:
      @Sendable (
        _ bundleName: String, _ abilityName: String?
      ) throws -> Void
  ) throws -> HarnessTaskSubmission {
    func text(_ key: String) -> String? {
      if case .string(let value)? = params?[key] { return value }
      return nil
    }
    func integer(_ key: String) -> Int? {
      switch params?[key] {
      case .integer(let value): return Int(value)
      case .unsignedInteger(let value): return Int(value)
      case .number(let value): return Int(value)
      default: return nil
      }
    }

    guard let targetID = text("targetId") else {
      throw HarnessTaskSubmissionError.malformedTargetID
    }
    guard let goal = text("goal") else {
      throw HarnessTaskSubmissionError.emptyGoal
    }
    let type = HarnessTaskType(rawValue: text("type") ?? HarnessTaskType.debugCrash.rawValue)
    guard let type else {
      throw HarnessTaskSubmissionError.unsupportedTaskType(.debugCrash)
    }

    var allowedOperations: [String] = []
    if case .array(let entries)? = params?["allowedOperations"] {
      allowedOperations = entries.compactMap { entry in
        if case .string(let value) = entry { return value }
        return nil
      }
    }
    // Omitted means "the closed set this task type already permits", never
    // "everything": the type's handler owns that set.
    let policy =
      allowedOperations.isEmpty
      ? HarnessTaskCoordinator.defaultPolicy(for: type)
      : HarnessTaskPolicy(allowedOperations: allowedOperations)

    let defaults = defaultBudgets
    let budgets = HarnessTaskBudgets(
      maxRounds: integer("maxRounds") ?? defaults.maxRounds,
      maxWallClockSeconds: integer("maxWallClockSeconds") ?? defaults.maxWallClockSeconds,
      maxArtifactBytes: integer("maxArtifactBytes") ?? defaults.maxArtifactBytes,
      maxE1Mutations: integer("maxE1Mutations") ?? defaults.maxE1Mutations,
      maxNoProgressRounds: integer("maxNoProgressRounds") ?? defaults.maxNoProgressRounds,
      maxActionRetriesPerRun: integer("maxActionRetriesPerRun")
        ?? defaults.maxActionRetriesPerRun,
      maxModelCalls: integer("maxModelCalls") ?? defaults.maxModelCalls)

    // The declared crash signature is what makes "matching crash" a
    // checkable statement instead of a judgement call. Absent, the evaluator
    // counts every fatal as a new fatal and can never confirm a specific fix.
    var desiredState: [String: JSONValue] = [:]
    if let signature = text("crashSignature") {
      guard !signature.isEmpty, signature.utf8.count <= 512,
        !signature.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else {
        throw HarnessTaskSubmissionError.malformedDesiredState("crashSignature")
      }
      desiredState["crashSignature"] = .string(signature)
    }
    let bundleName = text("bundleName")
    let abilityName = text("abilityName")
    let processName = text("processName")
    if let bundleName {
      do {
        try applicationReferenceValidator(bundleName, abilityName)
        desiredState["bundleName"] = .string(bundleName)
        if let abilityName {
          desiredState["abilityName"] = .string(abilityName)
        }
      } catch {
        throw HarnessTaskSubmissionError.malformedDesiredState(
          abilityName == nil ? "bundleName" : "bundleName/abilityName")
      }
    } else if abilityName != nil {
      throw HarnessTaskSubmissionError.malformedDesiredState("abilityName requires bundleName")
    }
    if let processName {
      guard bundleName != nil, !processName.isEmpty, processName.count <= 200,
        processName.first?.isASCII == true,
        processName.first?.isLetter == true,
        processName.allSatisfy({
          $0.isASCII
            && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == ":")
        })
      else {
        throw HarnessTaskSubmissionError.malformedDesiredState(
          bundleName == nil ? "processName requires bundleName" : "processName")
      }
      desiredState["processName"] = .string(processName)
    }
    for key in ["deviceProfile", "buildPresetRef", "testPresetRef"] {
      guard let value = text(key) else { continue }
      guard isWireIdentifier(value) else {
        throw HarnessTaskSubmissionError.malformedDesiredState(key)
      }
      desiredState[key] = .string(value)
    }
    if let revision = text("baseWorkspaceRevision") {
      guard revision.utf8.count == 64,
        revision.utf8.allSatisfy({
          (48...57).contains($0) || (97...102).contains($0)
        })
      else {
        throw HarnessTaskSubmissionError.malformedDesiredState("baseWorkspaceRevision")
      }
      desiredState["baseWorkspaceRevision"] = .string(revision)
    }
    if let component = text("component") {
      guard !component.isEmpty, component.utf8.count <= 256,
        !component.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        })
      else {
        throw HarnessTaskSubmissionError.malformedDesiredState("component")
      }
      desiredState["component"] = .string(component)
    }
    if let lease = text("baselineHapArtifactLease") {
      guard isArtifactLeaseReference(lease) else {
        throw HarnessTaskSubmissionError.malformedDesiredState("baselineHapArtifactLease")
      }
      guard bundleName != nil, abilityName != nil else {
        throw HarnessTaskSubmissionError.malformedDesiredState(
          "baselineHapArtifactLease requires bundleName/abilityName")
      }
      desiredState["baselineHapArtifactLease"] = .string(lease)
    }
    if let projectRef = text("projectRef"), !isWireIdentifier(projectRef) {
      throw HarnessTaskSubmissionError.malformedDesiredState("projectRef")
    }
    // r10 removes the mode-shaped wire vocabulary. Reject obsolete fields instead of silently
    // translating them into the workspace policy that now drives the single Agent path.
    for obsolete in ["executionMode", "allowedPaths", "evolutionAllowedOperations"]
    where params?[obsolete] != nil {
      throw HarnessTaskSubmissionError.malformedEvolutionPolicy(obsolete)
    }
    let evolutionPolicy: HarnessEvolutionPolicy?
    if params?["workspaceAllowedPaths"] != nil || params?["workspaceAllowedOperations"] != nil
      || params?["maxAttempts"] != nil || params?["maxChangedFiles"] != nil
      || params?["maxDiffLines"] != nil
    {
      guard text("projectRef") != nil else {
        throw HarnessTaskSubmissionError.evolutionProjectRequired
      }
      guard let baseRevision = text("baseWorkspaceRevision") else {
        throw HarnessTaskSubmissionError.malformedEvolutionPolicy("baseRevision")
      }
      guard case .array(let pathValues)? = params?["workspaceAllowedPaths"] else {
        throw HarnessTaskSubmissionError.malformedEvolutionPolicy("workspaceAllowedPaths")
      }
      let paths = pathValues.compactMap { value -> String? in
        guard case .string(let path) = value else { return nil }
        return path
      }
      guard paths.count == pathValues.count else {
        throw HarnessTaskSubmissionError.malformedEvolutionPolicy("workspaceAllowedPaths")
      }
      let evolutionOperations: [String]
      if case .array(let values)? = params?["workspaceAllowedOperations"] {
        evolutionOperations = values.compactMap { value in
          guard case .string(let operation) = value else { return nil }
          return operation
        }
        guard evolutionOperations.count == values.count else {
          throw HarnessTaskSubmissionError.malformedEvolutionPolicy(
            "workspaceAllowedOperations")
        }
      } else {
        evolutionOperations = policy.allowedOperations
      }
      do {
        evolutionPolicy = try HarnessEvolutionPolicy(
          baseRevision: baseRevision,
          allowedPaths: paths,
          maxAttempts: integer("maxAttempts") ?? 20,
          maxChangedFiles: integer("maxChangedFiles") ?? 20,
          maxDiffLines: integer("maxDiffLines") ?? 2_000,
          allowedOperations: evolutionOperations)
      } catch {
        throw HarnessTaskSubmissionError.malformedEvolutionPolicy("\(error)")
      }
    } else {
      evolutionPolicy = nil
    }
    return HarnessTaskSubmission(
      type: type,
      intakeDescription: text("intake"),
      projectRef: text("projectRef"),
      target: HarnessTaskTargetReference(
        targetID: targetID, expectedBindingRevision: integer("expectedBindingRevision")),
      goal: HarnessTaskGoal(summary: goal, desiredState: desiredState),
      budgets: budgets,
      policy: policy,
      evolutionPolicy: evolutionPolicy)
  }

  private static func isWireIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:@-".contains($0))
      }
  }

  private static func isArtifactLeaseReference(_ value: String) -> Bool {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count == 3 && parts[0] == "lease-v1"
      && parts[1...].allSatisfy { isWireIdentifier(String($0)) }
  }

  // MARK: - Wire encoding

  static func encodeTask(_ snapshot: HarnessTaskSnapshot) -> JSONValue {
    .object([
      "htaskId": .string(snapshot.htaskID),
      "type": .string(snapshot.type.rawValue),
      "lifecycle": .string(snapshot.lifecycle.rawValue),
      "stage": .string(snapshot.stage.rawValue),
      "waitReason": snapshot.waitReason.map { .string($0.rawValue) } ?? .null,
      "conditions": .array(snapshot.conditions.map(encode)),
      "status": .string(snapshot.status.rawValue),
      "phase": .string(snapshot.phase.rawValue),
      "targetId": .string(snapshot.target.targetID),
      "goal": .string(snapshot.goal.summary),
      "projectRef": snapshot.projectRef.map(JSONValue.string) ?? .null,
      "evolutionPolicy": snapshot.evolutionPolicy.map(encode) ?? .null,
      "evolutionWorkspace": snapshot.evolutionWorkspace.map(encode) ?? .null,
      "desiredState": .object(snapshot.goal.desiredState),
      "activeRound": .integer(Int64(snapshot.activeRound)),
      "activeJobId": snapshot.activeJobID.map(JSONValue.string) ?? .null,
      "cancelRequested": .bool(snapshot.cancelRequested),
      "version": .integer(Int64(snapshot.version)),
      "createdAtUtc": .string(snapshot.createdAtUTC),
      "updatedAtUtc": .string(snapshot.updatedAtUTC),
      "budgets": encode(snapshot.budgets),
      "consumedBudget": encode(snapshot.consumedBudget),
      "allowedOperations": .array(snapshot.policy.allowedOperations.map(JSONValue.string)),
      "successCriteria": .array(snapshot.successCriteria.map(encode)),
      "artifactRefs": .array(snapshot.artifactRefs.map(JSONValue.string)),
      "result": snapshot.result.map(encode) ?? .null,
    ])
  }

  /// Documents already carry a stable, reviewed JSON shape; re-deriving it
  /// by hand here would be a second contract to keep in step.
  static func encode<T: Encodable>(_ value: T) -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
      let projected = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return .null }
    return projected
  }

  private func success(id: String, result: JSONValue) -> HarnessTaskMethodResponse {
    HarnessTaskMethodResponse(
      id: id, result: result, errorCode: nil, errorMessage: nil)
  }

  private func failure(
    id: String, code: HarnessTaskMethodErrorCode, message: String
  ) -> HarnessTaskMethodResponse {
    HarnessTaskMethodResponse(
      id: id, result: nil, errorCode: code, errorMessage: message)
  }
}
