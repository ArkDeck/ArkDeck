// Campaign flash dispatch over the engine lane (CHG-2026-025 r16,
// TASK-AIN-019).
//
// Until now a campaign attempt executed in this process: the CLI called the
// in-process RockchipFlashExecution host, which admitted inside its own
// execute and drove the device itself. #992 built the other lane — a request
// may carry an open campaign reservation, the engine re-verifies its pins,
// re-proves the subject before the first mutation and closes it with the job's
// terminal — but nothing used it. This dispatcher is what uses it.
//
// It lives in ArkDeckCLI because it needs both the campaign protocol
// (ArkDeckAgentComposition/ArkDeckWorkflows) and the daemon transport
// (ArkDeckAgentClient), and ArkDeckWorkflows must not gain a dependency on the
// client — that would be a boundary-matrix change, not a lane swap.

import ArkDeckAgentClient
import ArkDeckAgentComposition
import ArkDeckCore
import ArkDeckRuntime
import ArkDeckWorkflows
import CryptoKit
import Darwin
import Foundation

/// The terminal the engine reached for one submitted job.
package struct EngineLaneJobTerminal: Sendable, Equatable {
  package let jobID: String
  package let state: String
  package let outcomeUnknown: Bool
  package let timeline: [String]

  package init(jobID: String, state: String, outcomeUnknown: Bool, timeline: [String]) {
    self.jobID = jobID
    self.state = state
    self.outcomeUnknown = outcomeUnknown
    self.timeline = timeline
  }
}

/// The daemon explicitly rejected `job.submit` — no job identifier was ever
/// minted, so nothing can have been dispatched. Only an authored daemon
/// rejection may produce this; transport failures must not, because they
/// cannot prove the daemon did not accept the request.
package struct EngineLaneSubmissionRefusal: Error, Equatable {
  package let detail: String

  package init(detail: String) {
    self.detail = detail
  }
}

/// Everything the dispatcher needs from the daemon, as one injectable seam.
/// The production value is `.overDaemonSocket`; contract tests substitute a
/// recording gateway so the mapping can be pinned with zero RPC and zero
/// device.
package struct EngineLaneRuntimeGateway: Sendable {
  /// Imports the archive into the daemon's artifact store and returns a lease.
  package var importFlashBundle:
    @Sendable (_ targetID: String, _ archiveURL: URL, _ profile: RockchipFlashProfile) throws ->
      String
  /// The daemon's current binding revision for an adopted target.
  package var bindingRevision: @Sendable (_ targetID: String) throws -> Int
  /// Submits the request and runs it to a terminal.
  package var submitAndRun: @Sendable (_ requestJSON: String) throws -> EngineLaneJobTerminal

  package init(
    importFlashBundle: @escaping @Sendable (String, URL, RockchipFlashProfile) throws -> String,
    bindingRevision: @escaping @Sendable (String) throws -> Int,
    submitAndRun: @escaping @Sendable (String) throws -> EngineLaneJobTerminal
  ) {
    self.importFlashBundle = importFlashBundle
    self.bindingRevision = bindingRevision
    self.submitAndRun = submitAndRun
  }
}

public struct EngineLaneEvolutionFlashDispatcher: RockchipEvolutionFlashDispatching {
  public let attemptAdmitter: (any RockchipEvolutionCampaignAttemptAdmitting)?
  private let runtimeTargetID: String
  private let gateway: EngineLaneRuntimeGateway

  /// Production: the nine gates run in the product-owned admitter and every
  /// daemon call goes over the user-private socket.
  public init(socketPath: String, runtimeTargetID: String) throws {
    try self.init(
      runtimeTargetID: runtimeTargetID,
      admitter: RockchipProductionEvolutionCampaignAttemptAdmitter(),
      gateway: .overDaemonSocket(AgentClient(socketPath: socketPath)))
  }

  package init(
    runtimeTargetID: String,
    admitter: (any RockchipEvolutionCampaignAttemptAdmitting)?,
    gateway: EngineLaneRuntimeGateway
  ) {
    self.runtimeTargetID = runtimeTargetID
    attemptAdmitter = admitter
    self.gateway = gateway
  }

  public func execute(
    _ request: RockchipFlashExecutionRequest,
    admitted: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult {
    // Fail closed rather than dispatching an unauthorized flash. The engine
    // never reserves, so a missing pre-admitted attempt is not "admit later" —
    // it is no authority at all.
    guard let admitted else {
      throw RockchipFlashExecutionError.admissionRejected(
        "the engine lane requires a campaign reservation minted before dispatch")
    }
    guard
      let profile = RockchipFlashProfile.profile(
        reference: admitted.deviceProfileReference),
      profile.archiveSHA256 == admitted.archiveSHA256,
      profile.mappedPartitions.map(\.partitionName) == admitted.partitionPlan
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "admitted attempt does not name an exact published DAYU200 profile")
    }

    let lease: String
    let bindingRevision: Int
    do {
      bindingRevision = try gateway.bindingRevision(runtimeTargetID)
      lease = try gateway.importFlashBundle(
        runtimeTargetID, request.archiveURL, profile)
    } catch let error as CLIError {
      throw RockchipFlashExecutionError.storageRejected(error.message)
    } catch {
      throw RockchipFlashExecutionError.storageRejected(
        "runtime job lane is unreachable: \(error)")
    }

    let requestJSON = try Self.encodedRequest(
      admitted: admitted, lease: lease, profile: profile,
      runtimeTargetID: runtimeTargetID, bindingRevision: bindingRevision)
    let terminal: EngineLaneJobTerminal
    do {
      terminal = try gateway.submitAndRun(requestJSON)
    } catch let refusal as EngineLaneSubmissionRefusal {
      // The daemon itself said no before a job existed. That is an authored
      // answer, not a lost one: provably nothing was dispatched, and the
      // campaign layer may settle the attempt retry-safe instead of sealing
      // the whole campaign over a host configuration fault (the 2026-08-04
      // shape: a daemon restarted without its HDC path rejected the submit
      // and the campaign tombstoned as outcomeUnknown).
      throw RockchipFlashExecutionError.submissionRefused(detail: refusal.detail)
    } catch {
      // Submit/run reported no terminal at all. The reservation may or may not
      // have been consumed on the other side, so this is unresolved, never a
      // safe failure the campaign may retry against.
      throw RockchipFlashExecutionError.recoveryRequired(
        stepID: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
        detail: "runtime job terminal was never observed: \(error)")
    }
    return try Self.result(terminal, admitted: admitted)
  }

  /// The request the engine admits. `deviceProfile` and `partitionPlan` come
  /// from the admitted attempt's materialized plan, so the bytes submitted
  /// here cannot name a different archive or a wider partition set than the
  /// campaign was confirmed against.
  package static func encodedRequest(
    admitted: RockchipEvolutionCampaignAdmittedAttempt,
    lease: String,
    profile: RockchipFlashProfile,
    runtimeTargetID: String,
    bindingRevision: Int
  ) throws -> String {
    let request = try RuntimeOperationRequest(
      requestID: "campaign-\(admitted.campaignID)-a\(admitted.ordinal)",
      idempotencyKey: "campaign-\(admitted.reservationID)",
      target: DurableTargetReference(
        targetID: runtimeTargetID, expectedBindingRevision: bindingRevision),
      operation: RuntimeOperationReference(id: "flash.dayu200", version: 1),
      inputs: [
        "imageBundleLease": .string(lease),
        "deviceProfile": .string(profile.catalogReference),
        "partitionPlan": .array(admitted.partitionPlan.map(JSONValue.string)),
        // The confirmed plan's own level, never a level chosen here. The
        // engine still refuses anything the catalog does not publish.
        "postFlashVerification": .string(admitted.postFlashVerification),
      ],
      campaignReservation: RuntimeCampaignReservationReference(
        reservationID: admitted.reservationID))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(request), as: UTF8.self)
  }

  /// Terminal mapping. The one rule that matters: `outcomeUnknown` is never
  /// downgraded to a failure the campaign may retry against, and never
  /// upgraded to success.
  package static func result(
    _ terminal: EngineLaneJobTerminal,
    admitted: RockchipEvolutionCampaignAdmittedAttempt
  ) throws -> RockchipFlashExecutionResult {
    guard !terminal.outcomeUnknown else {
      throw RockchipFlashExecutionError.recoveryRequired(
        stepID: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
        detail: "runtime job \(terminal.jobID) reached an unknown outcome")
    }
    switch terminal.state {
    case "succeeded":
      return RockchipFlashExecutionResult(
        // The engine lane has one durable record per attempt and names it by
        // job identifier; there is no second session document to reference.
        sessionID: terminal.jobID,
        jobID: terminal.jobID,
        status: .succeeded,
        evidenceClass: .production,
        manifestURL: nil)
    case "cancelled":
      throw RockchipFlashExecutionError.cancelledAtSafeBoundary
    case "failed":
      let diagnostic = RockchipFlashRuntimeDiagnostic.allCases.first { value in
        terminal.timeline.contains(
          "confirmed not executed enter-loader-mode [diagnostic=\(value.rawValue)]")
      }
      throw RockchipFlashExecutionError.semanticFailure(
        stepID: diagnostic?.evolutionFailureCode
          ?? RockchipEvolutionCampaignConfirmationAssertion.operationReference,
        detail: "runtime job \(terminal.jobID) failed: \(terminal.timeline.suffix(3).joined(separator: " | "))")
    default:
      // Any state that is not a decided terminal is unresolved by definition.
      throw RockchipFlashExecutionError.recoveryRequired(
        stepID: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
        detail:
          "runtime job \(terminal.jobID) for campaign \(admitted.campaignID) "
          + "ended in unrecognized state \(terminal.state)")
    }
  }
}

/// The runtime's own answer to "what did this attempt actually journal an
/// intent for", read over the existing evidence RPC. It lives here for the
/// same reason the dispatcher does: the campaign protocol must not learn about
/// the daemon transport, so the CLI composition root joins the two.
///
/// Read-only, and deliberately strict — one unreadable entry refuses the whole
/// answer rather than returning a shorter list, because a silently shortened
/// list is exactly how a partition write would go unnoticed.
public struct DaemonRockchipEvolutionAttemptIntents: RockchipEvolutionAttemptIntentReading {
  private let client: AgentClient

  public init(socketPath: String) {
    client = AgentClient(socketPath: socketPath)
  }

  public func journaledStepKinds(jobID: String) throws -> [String] {
    let response: JSONValue
    do {
      response = try client.request(
        method: "job.evidence", params: ["jobId": .string(jobID)])
    } catch {
      throw RockchipEvolutionAttemptIntentError.unavailable(
        "job.evidence for \(jobID) failed: \(error)")
    }
    guard case .object(let fields) = response,
      case .array(let entries)? = fields["actualStepKinds"]
    else {
      throw RockchipEvolutionAttemptIntentError.unavailable(
        "job.evidence for \(jobID) carried no actualStepKinds array")
    }
    return try entries.map { entry in
      guard case .string(let kind) = entry else {
        throw RockchipEvolutionAttemptIntentError.unavailable(
          "job.evidence for \(jobID) carried a non-string step kind")
      }
      return kind
    }
  }
}

extension EngineLaneRuntimeGateway {
  package static func overDaemonSocket(_ client: AgentClient) -> EngineLaneRuntimeGateway {
    EngineLaneRuntimeGateway(
      importFlashBundle: { targetID, archiveURL, profile in
        try RuntimeCLI.importFlashBundleLease(
          client: client, targetID: targetID, archiveURL: archiveURL,
          profile: profile)
      },
      bindingRevision: { targetID in
        guard case .array(let records) = try client.request(method: "target.list")
        else {
          throw AgentClientError.malformedResponse("target.list returned no records")
        }
        for record in records {
          guard case .object(let fields) = record,
            case .string(let id)? = fields["targetId"], id == targetID,
            case .integer(let revision)? = fields["bindingRevision"],
            revision > 0, revision <= Int64(Int.max)
          else { continue }
          return Int(revision)
        }
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "the runtime has not adopted target \(targetID); adopt it with "
            + "`arkdeck device adopt` before continuing the campaign")
      },
      submitAndRun: { requestJSON in
        let accepted: [String: JSONValue]
        do {
          guard
            case .object(let fields) = try client.request(
              method: "job.submit", params: ["requestJson": .string(requestJSON)])
          else {
            throw AgentClientError.malformedResponse("job.submit returned no job identifier")
          }
          accepted = fields
        } catch AgentClientError.daemonError(let code, let message) where code == "rejected" {
          // An authored daemon rejection: the runtime refused the request and
          // no job record exists. Typed so the campaign layer can settle the
          // attempt retry-safe instead of unknown.
          throw EngineLaneSubmissionRefusal(
            detail: "the runtime rejected the submission: \(message)")
        }
        guard case .string(let jobID)? = accepted["jobId"] else {
          throw AgentClientError.malformedResponse("job.submit returned no job identifier")
        }
        let status = try client.request(
          method: "job.run", params: ["jobId": .string(jobID)])
        return try decodeTerminal(status, fallbackJobID: jobID)
      })
  }

  private static func decodeTerminal(
    _ value: JSONValue, fallbackJobID: String
  ) throws -> EngineLaneJobTerminal {
    guard case .object(let fields) = value,
      case .string(let state)? = fields["state"],
      case .bool(let outcomeUnknown)? = fields["outcomeUnknown"]
    else {
      throw AgentClientError.malformedResponse("job status is not a runtime terminal")
    }
    let jobID: String
    if case .string(let value)? = fields["jobId"] { jobID = value } else { jobID = fallbackJobID }
    var timeline: [String] = []
    if case .array(let entries)? = fields["timeline"] {
      timeline = entries.compactMap {
        guard case .string(let text) = $0 else { return nil }
        return text
      }
    }
    return EngineLaneJobTerminal(
      jobID: jobID, state: state, outcomeUnknown: outcomeUnknown, timeline: timeline)
  }
}
