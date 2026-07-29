// Device Runtime Agent runner (CHG-2026-049, T00).
//
// One published operation, executed end to end by the agent itself:
// health -> target list/adopt -> submit -> run -> status -> artifact
// query, with a redacted receipt at the end. This exists so device runs
// stop being "the maintainer pastes host commands back": a human is a
// physicalAssistant here (screen trust, ambiguous choice, replug), never
// the thing that drives the runtime.
//
// The surface is deliberately narrow. It composes typed daemon methods
// only - there is no executable, argv, shell or remote path anywhere on
// it - and it cannot create, modify, approve or revoke a capability. It
// may only reference one by ID that a maintainer already accepted.

import ArkDeckCore
import Foundation

public enum RuntimeExecutorKind: String, Codable, Sendable {
  case agent
  case human
}

/// The three things only a person standing at the device can do. Each is
/// a closed case with a resume token, so waiting for a human is a
/// recorded, resumable state rather than an abandoned run.
public enum RuntimeHumanActionKind: String, Codable, Sendable {
  case trustDevice
  case selectTarget
  case physicalReconnect
}

public struct RuntimeHumanActionReceipt: Codable, Sendable, Equatable {
  public let kind: RuntimeHumanActionKind
  public let prompt: String
  public let resumeToken: String
  public let raisedAtUTC: String
  public var resolvedAtUTC: String?
}

public struct RuntimeAgentExecutionReceipt: Codable, Sendable, Equatable {
  public let executor: RuntimeExecutorKind
  public let executorID: String
  public let operationReference: String
  public let jobID: String?
  public let targetID: String?
  public let bindingRevision: Int?
  public let catalogDigest: String
  public let providerID: String
  public let executionMode: String
  public let actualEffect: RuntimeHardwareEvidenceEffectLevel?
  public let authority: RuntimeHardwareEvidenceAuthority?
  public let stepKinds: [String]
  public let evidenceObservation: RuntimeHardwareEvidenceObservation?
  public let firstEvidenceStepAtUTC: String?
  public let outcomeUnknown: Bool
  public let humanActions: [RuntimeHumanActionReceipt]
  public let terminalState: String
  public let artifacts: [RuntimeHardwareEvidenceArtifact]
  public let evidenceBlockers: [String]
  public let startedAtUTC: String
  public let finishedAtUTC: String

  public var authorityReference: String {
    authority?.reference ?? ""
  }
}

public enum RuntimeAgentExecutionOutcome: Sendable, Equatable {
  case completed(RuntimeAgentExecutionReceipt)
  /// The run is paused on a physical action. The receipt records what is
  /// needed; resuming continues the same target and binding.
  case awaitingHumanAction(RuntimeHumanActionReceipt, RuntimeAgentExecutionReceipt)
  case failed(reason: String, receipt: RuntimeAgentExecutionReceipt)
}

public enum RuntimeAgentExecutorError: Error, Equatable, Sendable {
  case daemonUnavailable(String)
  case malformedResponse(String)
  case operationRejected(String)
}

public struct RuntimeAgentExecutionRequest: Sendable {
  public let operationID: String
  public let operationVersion: Int
  /// Typed inputs, exactly as the catalog declares them. There is no
  /// free-form command field to smuggle anything through.
  public let inputs: [String: JSONValue]
  /// A capability the maintainer already accepted. The runner references
  /// it; it cannot create or change one.
  public let capabilityReference: String?
  public let targetID: String?
  public let maximumWaitSeconds: Int

  public init(
    operationID: String,
    operationVersion: Int,
    inputs: [String: JSONValue] = [:],
    capabilityReference: String? = nil,
    targetID: String? = nil,
    maximumWaitSeconds: Int = 900
  ) {
    self.operationID = operationID
    self.operationVersion = operationVersion
    self.inputs = inputs
    self.capabilityReference = capabilityReference
    self.targetID = targetID
    self.maximumWaitSeconds = maximumWaitSeconds
  }

  var reference: String { "\(operationID)@\(operationVersion)" }
}

public struct AgentRuntimeExecutor: Sendable {
  private let client: AgentClient
  private let nowUTC: @Sendable () -> String

  public init(client: AgentClient, nowUTC: @escaping @Sendable () -> String) {
    self.client = client
    self.nowUTC = nowUTC
  }

  /// Executes one published operation. Single-shot by construction: it
  /// submits at most one job and returns, so it cannot become an
  /// open-ended debugging loop.
  public func run(_ request: RuntimeAgentExecutionRequest) throws
    -> RuntimeAgentExecutionOutcome
  {
    let startedAt = nowUTC()
    var humanActions: [RuntimeHumanActionReceipt] = []

    let health: JSONValue
    do {
      health = try client.request(method: "health")
    } catch {
      throw RuntimeAgentExecutorError.daemonUnavailable("\(error)")
    }
    guard case .object(let healthFields) = health,
      case .string(let catalogDigest)? = healthFields["catalogDigest"]
    else {
      throw RuntimeAgentExecutorError.malformedResponse("health lacks a catalog digest")
    }

    func receipt(
      jobID: String?, targetID: String?, bindingRevision: Int?, state: String,
      trustedFacts: RuntimeHardwareEvidenceTrustedFacts? = nil,
      blockers: [String] = []
    ) -> RuntimeAgentExecutionReceipt {
      let evidenceBindingRevision: Int?
      let evidenceStartedAtUTC: String
      let evidenceFinishedAtUTC: String
      if let trustedFacts {
        // Once the daemon returned its product-owned snapshot, absence is
        // evidence absence. Never replace it with target-list or runner
        // timestamps, which would turn local context into trusted facts.
        evidenceBindingRevision = trustedFacts.bindingRevision
        evidenceStartedAtUTC = trustedFacts.startedAtUTC ?? ""
        evidenceFinishedAtUTC = trustedFacts.finishedAtUTC ?? ""
      } else {
        evidenceBindingRevision = bindingRevision
        evidenceStartedAtUTC = startedAt
        evidenceFinishedAtUTC = nowUTC()
      }
      return RuntimeAgentExecutionReceipt(
        executor: .agent,
        executorID: "arkdeck-device-runtime-agent",
        operationReference: trustedFacts?.operationReference ?? request.reference,
        jobID: trustedFacts?.jobID ?? jobID,
        targetID: trustedFacts?.targetID ?? targetID,
        bindingRevision: evidenceBindingRevision,
        catalogDigest: trustedFacts?.catalogDigest ?? catalogDigest,
        providerID: trustedFacts?.providerID ?? "",
        executionMode: trustedFacts?.executionMode ?? "execute",
        actualEffect: trustedFacts?.actualEffect,
        authority: trustedFacts?.authority,
        stepKinds: trustedFacts?.actualStepKinds ?? [],
        evidenceObservation: trustedFacts?.observation,
        firstEvidenceStepAtUTC: trustedFacts?.firstEvidenceStepAtUTC,
        outcomeUnknown: trustedFacts?.outcomeUnknown ?? false,
        humanActions: humanActions,
        terminalState: trustedFacts?.terminalState ?? state,
        artifacts: trustedFacts?.artifacts ?? [],
        evidenceBlockers: blockers + (trustedFacts?.blockers ?? []),
        startedAtUTC: evidenceStartedAtUTC,
        finishedAtUTC: evidenceFinishedAtUTC)
    }

    // Resolve the target: an explicit one, an already adopted one, or
    // adoption - which is where a human may be needed.
    var targetID = request.targetID
    var bindingRevision: Int?
    let listed = try client.request(method: "target.list")
    if case .array(let rows) = listed {
      for row in rows {
        guard case .object(let fields) = row,
          case .string(let existing)? = fields["targetId"]
        else { continue }
        if targetID == nil || targetID == existing {
          targetID = existing
          if case .integer(let revision)? = fields["bindingRevision"] {
            bindingRevision = Int(revision)
          }
          break
        }
      }
    }
    if targetID == nil {
      let adopted: JSONValue
      do {
        adopted = try client.request(method: "target.adopt")
      } catch let error as AgentClientError {
        // A refusal is still a run that happened: it gets a receipt so the
        // evidence records who tried, against what, and why it stopped.
        guard case .daemonError(_, let message) = error else {
          throw RuntimeAgentExecutorError.daemonUnavailable("\(error)")
        }
        return .failed(
          reason: message,
          receipt: receipt(
            jobID: nil, targetID: nil, bindingRevision: nil, state: "adoptRefused"))
      }
      guard case .object(let fields) = adopted,
        case .string(let outcome)? = fields["outcome"]
      else {
        throw RuntimeAgentExecutorError.malformedResponse("adopt returned no outcome")
      }
      switch outcome {
      case "adopted":
        if case .string(let identifier)? = fields["targetId"] { targetID = identifier }
        if case .integer(let revision)? = fields["bindingRevision"] {
          bindingRevision = Int(revision)
        }
      case "waitingForHuman", "needsSelection":
        let kind: RuntimeHumanActionKind =
          outcome == "needsSelection" ? .selectTarget : .trustDevice
        var prompt = "physical action required at the device"
        if case .string(let text)? = fields["prompt"] { prompt = text }
        if case .array(let candidates)? = fields["candidates"] {
          prompt += " (candidates: \(candidates.count))"
        }
        let action = RuntimeHumanActionReceipt(
          kind: kind, prompt: prompt,
          // The token is the operation itself: resuming re-runs this same
          // request against the same daemon, continuing the same target.
          resumeToken: "resume:\(request.reference)", raisedAtUTC: nowUTC(),
          resolvedAtUTC: nil)
        humanActions.append(action)
        return .awaitingHumanAction(
          action,
          receipt(
            jobID: nil, targetID: nil, bindingRevision: nil, state: "awaitingHumanAction"))
      default:
        let detail = "adopt reported \(outcome)"
        return .failed(
          reason: detail,
          receipt: receipt(jobID: nil, targetID: nil, bindingRevision: nil, state: "failed"))
      }
    }
    guard let resolvedTarget = targetID else {
      throw RuntimeAgentExecutorError.malformedResponse("no target could be resolved")
    }

    // Build the typed request. Governance identifiers do not exist on
    // this surface, so none can leak into a runtime job.
    var target: [String: JSONValue] = ["targetId": .string(resolvedTarget)]
    if let bindingRevision {
      target["expectedBindingRevision"] = .integer(Int64(bindingRevision))
    }
    var payload: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("2.0.0"),
      "requestId": .string("agent-\(UUID().uuidString.prefix(8).lowercased())"),
      "idempotencyKey": .string("agent-\(UUID().uuidString.lowercased())"),
      "target": .object(target),
      "operation": .object([
        "id": .string(request.operationID),
        "version": .integer(Int64(request.operationVersion)),
      ]),
    ]
    if !request.inputs.isEmpty { payload["inputs"] = .object(request.inputs) }
    if let capability = request.capabilityReference {
      payload["authorization"] = .object(["capabilityId": .string(capability)])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let requestJSON = try? encoder.encode(JSONValue.object(payload)),
      let requestText = String(data: requestJSON, encoding: .utf8)
    else {
      throw RuntimeAgentExecutorError.malformedResponse("cannot encode the runtime request")
    }

    let submitted: JSONValue
    do {
      submitted = try client.request(
        method: "job.submit", params: ["requestJson": .string(requestText)])
    } catch let error as AgentClientError {
      if case .daemonError(_, let message) = error {
        return .failed(
          reason: message,
          receipt: receipt(
            jobID: nil, targetID: resolvedTarget, bindingRevision: bindingRevision,
            state: "rejected"))
      }
      throw RuntimeAgentExecutorError.daemonUnavailable("\(error)")
    }
    guard case .object(let submitFields) = submitted,
      case .string(let jobID)? = submitFields["jobId"]
    else {
      throw RuntimeAgentExecutorError.malformedResponse("submit returned no job id")
    }

    let finished = try client.request(method: "job.run", params: ["jobId": .string(jobID)])
    guard case .object(let statusFields) = finished,
      case .string(let state)? = statusFields["state"]
    else {
      throw RuntimeAgentExecutorError.malformedResponse("run returned no state")
    }

    var trustedFacts: RuntimeHardwareEvidenceTrustedFacts?
    var evidenceBlockers: [String] = []
    do {
      let evidence = try client.request(
        method: "job.evidence", params: ["jobId": .string(jobID)])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(evidence)
      trustedFacts = try JSONDecoder().decode(
        RuntimeHardwareEvidenceTrustedFacts.self, from: data)
    } catch {
      evidenceBlockers.append("trustedEvidenceQuery:\(error)")
    }

    let final = receipt(
      jobID: jobID, targetID: resolvedTarget, bindingRevision: bindingRevision,
      state: state, trustedFacts: trustedFacts, blockers: evidenceBlockers)
    if state == "succeeded" { return .completed(final) }
    if state == "waitingForRecovery" {
      // An unknown outcome is not something the agent may resolve on its
      // own: it surfaces as a failure with the evidence attached.
      return .failed(reason: "job requires reconcile", receipt: final)
    }
    return .failed(reason: "job ended in \(state)", receipt: final)
  }
}
