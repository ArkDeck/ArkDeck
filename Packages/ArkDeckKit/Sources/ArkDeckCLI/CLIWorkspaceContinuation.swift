import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckRuntime
import ArkDeckWorkflows
import Foundation

/// The immutable source facts a CLI continuation is allowed to carry forward.
///
/// This is deliberately reconstructed from the Runtime's v2 Job projection on
/// every invocation. It stores no App state, authority, session identity or
/// provider lowering, and it cannot turn an old request into a replay token.
struct CLIWorkspaceContinuationDraft: Equatable {
  static let schemaVersion = "arkdeck.workspace-continuation/1"

  let sourceJobID: String
  let sourceRequest: RuntimeOperationRequest
  let catalogDigest: String
  let effectiveEffect: WorkflowEffect
  let bindingRevision: Int?
  let stablePhysicalIdentitySHA256: String?

  var operationReference: String { sourceRequest.operation.reference }
  var targetID: String { sourceRequest.target.targetID }
  var threadID: String? { sourceRequest.clientContext?.threadID }
  var requiresCurrentTarget: Bool { bindingRevision != nil }

  private static func nonnegativeInteger(_ value: JSONValue?) -> Int64? {
    switch value {
    case .integer(let number)? where number >= 0:
      return number
    case .unsignedInteger(let number)? where number <= UInt64(Int64.max):
      return Int64(number)
    default:
      return nil
    }
  }

  static func prepare(
    sourceJobID: String,
    jobShow: JSONValue,
    health: JSONValue,
    targetShow: JSONValue?,
    session: CLIRuntimeSession
  ) throws -> Self {
    guard AgentExecutionIntent.validIdentifier(sourceJobID) else {
      throw session.fail(.invalidInput, "workspace continuation requires an exact source Job identity")
    }
    _ = try CLIJobReadValidation.validate(
      jobShow, verb: "show", jobID: sourceJobID, options: [:], session: session)
    guard case .object(let show) = jobShow,
      case .object(let job)? = show["job"],
      case .object? = show["request"],
      let sourceDigest = CLIJobEventPage.string(show["catalogDigest"]),
      SHA256Hex.isLowercaseSHA256(sourceDigest),
      case .object(let healthFields) = health,
      Set(healthFields.keys) == [
        "status", "protocolVersion", "supportedExactVersions", "publishedMethods",
        "catalogDigest", "providers",
      ],
      healthFields["status"] == .string("ok"),
      healthFields["protocolVersion"] == .string(ArkDeckControlProtocol.targetVersion),
      healthFields["supportedExactVersions"] == .array(
        ArkDeckControlProtocol.supportedExactVersions.map(JSONValue.string)),
      healthFields["publishedMethods"] == .array(
        ArkDeckControlProtocol.targetMethods.sorted().map(JSONValue.string)),
      case .array(let providerValues)? = healthFields["providers"],
      providerValues.allSatisfy({ CLIJobEventPage.string($0)?.isEmpty == false }),
      Set(providerValues.compactMap(CLIJobEventPage.string)).count == providerValues.count,
      let currentDigest = CLIJobEventPage.string(healthFields["catalogDigest"]),
      SHA256Hex.isLowercaseSHA256(currentDigest)
    else {
      throw session.fail(.recordUnreadable, "the Runtime returned no closed continuation source")
    }
    guard sourceDigest == currentDigest, currentDigest == RuntimeOperationCatalog.catalogDigest else {
      throw session.fail(
        .factsDrifted,
        "the source Job, current Runtime and this CLI do not use the same Catalog",
        details: [
          "sourceCatalogDigest": .string(sourceDigest),
          "runtimeCatalogDigest": .string(currentDigest),
          "cliCatalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
        ])
    }
    guard let sourceProvider = CLIJobEventPage.string(show["providerId"]),
      providerValues.contains(.string(sourceProvider))
    else {
      throw session.fail(
        .operationUnavailable,
        "the source Job provider is not published by the current Runtime")
    }

    let sourceRequest: RuntimeOperationRequest
    do {
      let bytes = try CanonicalJSONEncoders.canonical().encode(show["request"]!)
      sourceRequest = try JSONDecoder().decode(RuntimeOperationRequest.self, from: bytes)
    } catch {
      throw session.fail(.recordUnreadable, "the source Job request is not a valid typed request")
    }
    guard sourceRequest.authorization == nil, sourceRequest.campaignReservation == nil else {
      throw session.fail(.admissionDenied, "workspace continuation never copies Runtime authority")
    }
    guard job["jobId"] == .string(sourceJobID),
      job["operation"] == .string(sourceRequest.operation.reference),
      job["targetId"] == .string(sourceRequest.target.targetID)
    else {
      throw session.fail(.recordUnreadable, "the source Job and typed request identities disagree")
    }
    guard case .string(let stateText)? = job["state"],
      let state = JobState(rawValue: stateText), state.isTerminal
    else {
      throw session.fail(.admissionDenied, "the source Job is not terminal")
    }
    guard job["outcomeUnknown"] == .bool(false),
      job["waitingForHuman"] == .bool(false),
      Self.nonnegativeInteger(job["outstandingResidueCount"]) == 0,
      case .null? = job["supersededByRecoveryEpochId"]
    else {
      throw session.fail(
        .admissionDenied,
        "the source Job has an unknown outcome, human wait, residue or superseding recovery")
    }
    guard let descriptor = RuntimeOperationCatalog.descriptor(
      reference: sourceRequest.operation.reference)
    else {
      throw session.fail(.operationUnavailable, "the source operation is absent from the current Catalog")
    }
    guard RuntimeWorkspaceContinuation.inputsMatchCatalog(
      sourceRequest.inputs, descriptor: descriptor)
    else {
      throw session.fail(.recordUnreadable, "the source typed inputs do not match the current Catalog")
    }
    let effect = CatalogOperationEffectResolver.effectiveEffect(
      descriptor: descriptor, inputs: sourceRequest.inputs)
    guard effect <= .readOnly, job["actualEffect"] == .string(effect.rawValue) else {
      throw session.fail(
        .admissionDenied,
        "workspace continuation accepts only a source whose recorded effect is hostOnly or readOnly")
    }
    if case .array(let markers)? = sourceRequest.inputs["markers"], !markers.isEmpty {
      throw session.fail(
        .admissionDenied,
        "capture markers contain old timestamps and require a newly authored typed request")
    }

    let bindingRevision: Int?
    let stableIdentity: String?
    switch descriptor.binding {
    case .confirmedDevice:
      guard let requested = sourceRequest.target.expectedBindingRevision,
        requested > 0,
        Self.nonnegativeInteger(show["materializedBindingRevision"]) == Int64(requested),
        let materializedIdentity = CLIJobEventPage.string(
          show["materializedStableIdentitySha256"]),
        SHA256Hex.isLowercaseSHA256(materializedIdentity),
        case .object(let target)? = targetShow,
        Set(target.keys) == [
          "schemaVersion", "targetId", "bindingRevision", "toolVersion", "adoptedAtUtc",
          "connectKey", "stablePhysicalIdentitySha256", "live", "observedFacts",
        ],
        target["schemaVersion"] == .string("arkdeck.target/1"),
        target["targetId"] == .string(sourceRequest.target.targetID),
        Self.nonnegativeInteger(target["bindingRevision"]) == Int64(requested),
        target["stablePhysicalIdentitySha256"] == .string(materializedIdentity)
      else {
        throw session.fail(
          .bindingRevisionStale,
          "the source Job target identity or binding revision is no longer current")
      }
      bindingRevision = requested
      stableIdentity = materializedIdentity
    case .none:
      guard sourceRequest.target.expectedBindingRevision == nil,
        show["materializedBindingRevision"] == .null,
        show["materializedStableIdentitySha256"] == .null,
        targetShow == nil
      else {
        throw session.fail(
          .recordUnreadable,
          "a host-only continuation source carries an unexpected device binding")
      }
      bindingRevision = nil
      stableIdentity = nil
    }

    return Self(
      sourceJobID: sourceJobID,
      sourceRequest: sourceRequest,
      catalogDigest: currentDigest,
      effectiveEffect: effect,
      bindingRevision: bindingRevision,
      stablePhysicalIdentitySHA256: stableIdentity)
  }

  func request(continuationRequestID: String, session: CLIRuntimeSession)
    throws -> RuntimeOperationRequest
  {
    guard continuationRequestID.utf8.count >= 8,
      AgentExecutionIntent.validIdentifier(continuationRequestID)
    else {
      throw session.fail(
        .invalidInput,
        "--continuation-request-id must be 8...128 ASCII [A-Za-z0-9._-] characters")
    }
    var provenance = ["arkdeck.continuedFromJob": sourceJobID]
    if let threadID { provenance[RuntimeClientContext.threadProvenanceKey] = threadID }
    do {
      return try RuntimeOperationRequest(
        requestID: continuationRequestID,
        idempotencyKey: continuationRequestID,
        target: sourceRequest.target,
        operation: sourceRequest.operation,
        inputs: sourceRequest.inputs,
        requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
        clientContext: RuntimeClientContext(
          clientName: "arkdeck-cli-workspace-continuation", provenance: provenance))
    } catch let rejection as RuntimeOperationRequestRejection {
      throw session.fail(.invalidInput, rejection.message)
    }
  }

  func validateAcceptedJob(
    _ jobShow: JSONValue,
    jobID: String,
    expectedRequest: RuntimeOperationRequest,
    session: CLIRuntimeSession
  ) throws -> JSONValue {
    guard jobID != sourceJobID, AgentExecutionIntent.validIdentifier(jobID) else {
      throw session.fail(.recordUnreadable, "the continuation did not create a distinct Job identity")
    }
    _ = try CLIJobReadValidation.validate(
      jobShow, verb: "show", jobID: jobID, options: [:], session: session)
    guard case .object(let show) = jobShow,
      show["catalogDigest"] == .string(catalogDigest),
      case .object(let job)? = show["job"],
      job["jobId"] == .string(jobID),
      job["operation"] == .string(operationReference),
      job["targetId"] == .string(targetID),
      job["outcomeUnknown"] == .bool(false),
      case .null? = job["supersededByRecoveryEpochId"]
    else {
      throw session.fail(.recordUnreadable, "the accepted continuation Job does not match its source")
    }
    let recordedRequest: RuntimeOperationRequest
    do {
      let bytes = try CanonicalJSONEncoders.canonical().encode(show["request"]!)
      recordedRequest = try JSONDecoder().decode(RuntimeOperationRequest.self, from: bytes)
    } catch {
      throw session.fail(.recordUnreadable, "the continuation Job request is unreadable")
    }
    guard recordedRequest == expectedRequest else {
      throw session.fail(
        .idempotencyConflict,
        "the continuation identity resolves to a Job with different typed inputs")
    }
    if let bindingRevision {
      guard Self.nonnegativeInteger(show["materializedBindingRevision"])
          == Int64(bindingRevision),
        show["materializedStableIdentitySha256"]
          == stablePhysicalIdentitySHA256.map(JSONValue.string)
      else {
        throw session.fail(
          .bindingRevisionStale,
          "the continuation Job materialized a different device binding")
      }
    } else {
      guard show["materializedBindingRevision"] == .null,
        show["materializedStableIdentitySha256"] == .null
      else {
        throw session.fail(.recordUnreadable, "a host-only continuation gained a device binding")
      }
    }
    if job["actualEffect"] != .null,
      job["actualEffect"] != .string(effectiveEffect.rawValue)
    {
      throw session.fail(.factsDrifted, "the continuation Job effect differs from its current Catalog")
    }
    return .object(job)
  }

  func projection(
    continuationRequestID: String? = nil,
    jobID: String? = nil,
    deduplicated: Bool? = nil,
    dispatched: Bool = false,
    job: JSONValue? = nil
  ) -> JSONValue {
    .object([
      "schemaVersion": .string(Self.schemaVersion),
      "eligible": .bool(true),
      "sourceJobId": .string(sourceJobID),
      "operation": .string(operationReference),
      "targetId": .string(targetID),
      "bindingRevision": bindingRevision.map { .integer(Int64($0)) } ?? .null,
      "catalogDigest": .string(catalogDigest),
      "effectiveEffect": .string(effectiveEffect.rawValue),
      "inputs": .object(sourceRequest.inputs),
      "threadId": threadID.map(JSONValue.string) ?? .null,
      "continuationRequestId": continuationRequestID.map(JSONValue.string) ?? .null,
      "jobId": jobID.map(JSONValue.string) ?? .null,
      "deduplicated": deduplicated.map(JSONValue.bool) ?? .null,
      "dispatched": .bool(dispatched),
      "job": job ?? .null,
    ])
  }
}

extension RuntimeCLI {
  /// §7.9's stable headless continuation path.
  ///
  /// `inspect` is a pure read. `submit` and `run` reconstruct the same fresh
  /// typed request from the source and a caller-stable identity, then read the
  /// accepted Job back before trusting it. A new CLI process therefore
  /// rediscovers the same Job instead of relying on App memory or replaying the
  /// source Job's authority.
  static func runWorkspaceContinuation(_ arguments: [String]) throws {
    guard let verb = arguments.first, ["inspect", "submit", "run"].contains(verb) else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing workspace continuation subcommand (inspect|submit|run)")
    }
    var rest = Array(arguments.dropFirst())
    var session = runtimeSession(&rest, command: "workspace.continuation.\(verb)")
    let options = try CLIOptions(rest)
    try options.validateAllowed([
      "--source-job", "--continuation-request-id", "--timeout", "--require-protocol",
    ])
    guard options.value("--require-protocol").map({ $0 == "2" }) ?? true else {
      throw session.fail(.invalidInput, "workspace continuation requires control protocol v2")
    }
    guard let timeout = CLIDuration.parse(
      options.value("--timeout") ?? "30s", maximumMilliseconds: 86_400_000)
    else {
      throw session.fail(.invalidInput, "timeout must be a bounded duration")
    }
    session.client = session.client.bounded(
      by: try AgentClientWaitDeadline(milliseconds: timeout.milliseconds))
    guard let sourceJobID = options.value("--source-job") else {
      throw session.fail(.invalidInput, "workspace continuation requires --source-job <job-id>")
    }
    let continuationRequestID = options.value("--continuation-request-id")
    if verb == "inspect", continuationRequestID != nil {
      throw session.fail(.invalidInput, "workspace continuation inspect does not take a request identity")
    }
    if verb != "inspect", continuationRequestID == nil {
      throw session.fail(
        .invalidInput,
        "workspace continuation \(verb) requires --continuation-request-id <id>")
    }

    do {
      try session.negotiate(requiredMajor: 2, forMethod: "job.show")
      let health = try session.request("health")
      let sourceShow = try session.request("job.show", ["jobId": .string(sourceJobID)])
      let targetShow: JSONValue?
      if try CLIWorkspaceContinuationDraft.sourceRequiresCurrentTarget(
        sourceShow, sourceJobID: sourceJobID, session: session)
      {
        guard case .object(let show) = sourceShow,
          case .object(let job)? = show["job"],
          let targetID = CLIJobEventPage.string(job["targetId"])
        else {
          throw session.fail(.recordUnreadable, "the source Job target is unreadable")
        }
        targetShow = try session.request("target.show", ["targetId": .string(targetID)])
      } else {
        targetShow = nil
      }
      let draft = try CLIWorkspaceContinuationDraft.prepare(
        sourceJobID: sourceJobID,
        jobShow: sourceShow,
        health: health,
        targetShow: targetShow,
        session: session)
      guard verb != "inspect" else {
        session.emit(draft.projection())
        return
      }

      let stableID = continuationRequestID!
      let request = try draft.request(continuationRequestID: stableID, session: session)
      let bytes = try CanonicalJSONEncoders.canonical().encode(request)
      let submitted = try session.request(
        "job.submit", ["requestJson": .string(String(decoding: bytes, as: UTF8.self))])
      try CLIJobLifecycleValidation.validateAcceptance(submitted, session: session)
      guard case .object(let acceptance) = submitted,
        let jobID = CLIJobEventPage.string(acceptance["jobId"]),
        case .bool(let deduplicated)? = acceptance["deduplicated"]
      else {
        throw session.fail(.recordUnreadable, "job.submit returned no exact continuation owner")
      }
      let acceptedShow = try session.request("job.show", ["jobId": .string(jobID)])
      let acceptedJob = try draft.validateAcceptedJob(
        acceptedShow, jobID: jobID, expectedRequest: request, session: session)
      guard verb == "run" else {
        session.emit(
          draft.projection(
            continuationRequestID: stableID,
            jobID: jobID,
            deduplicated: deduplicated,
            job: acceptedJob))
        return
      }

      guard case .object(let acceptedStatus) = acceptedJob,
        case .string(let acceptedStateText)? = acceptedStatus["state"],
        let acceptedState = JobState(rawValue: acceptedStateText)
      else {
        throw session.fail(.recordUnreadable, "the continuation Job state is unreadable")
      }
      var dispatched = false
      var finalJob = acceptedJob
      let isRunnable = switch acceptedState {
      case .preflight, .running, .recoveringByCompleteOverwrite,
        .resumeAtConfirmedSafeBoundary: true
      default: false
      }
      if isRunnable {
        let runResult = try session.request("job.run", ["jobId": .string(jobID)])
        _ = try CLIJobReadValidation.validate(
          runResult, verb: "status", jobID: jobID, options: [:], session: session)
        guard case .object(let runStatus) = runResult,
          runStatus["jobId"] == .string(jobID),
          runStatus["operation"] == .string(draft.operationReference),
          runStatus["targetId"] == .string(draft.targetID),
          runStatus["outcomeUnknown"] == .bool(false)
        else {
          throw session.fail(
            .outcomeUnknown,
            "the continuation run result is unconfirmed; inspect this Job and never replay it")
        }
        dispatched = true
        let finalShow = try session.request("job.show", ["jobId": .string(jobID)])
        finalJob = try draft.validateAcceptedJob(
          finalShow, jobID: jobID, expectedRequest: request, session: session)
      } else if !acceptedState.isTerminal {
        throw session.fail(
          .resourceConflict,
          "the continuation Job is \(acceptedState.rawValue), not runnable; inspect or resume this exact Job")
      }
      session.emit(
        draft.projection(
          continuationRequestID: stableID,
          jobID: jobID,
          deduplicated: deduplicated,
          dispatched: dispatched,
          job: finalJob))
      if let terminal = terminalJobExit(finalJob) {
        throw CLIError(exitCode: terminal.code, message: terminal.reason)
      }
    } catch let error as CLIRegistryError {
      throw session.stamped(error)
    }
  }
}

extension CLIWorkspaceContinuationDraft {
  /// Reads only enough of the already validated Job request to decide whether
  /// `target.show` is required. `prepare` repeats the full closed validation;
  /// this helper grants nothing and exists only to avoid issuing a device
  /// target lookup for host-only workspace Jobs.
  static func sourceRequiresCurrentTarget(
    _ jobShow: JSONValue,
    sourceJobID: String,
    session: CLIRuntimeSession
  ) throws -> Bool {
    _ = try CLIJobReadValidation.validate(
      jobShow, verb: "show", jobID: sourceJobID, options: [:], session: session)
    guard case .object(let show) = jobShow, let requestValue = show["request"] else {
      throw session.fail(.recordUnreadable, "the source Job request is unavailable")
    }
    do {
      let bytes = try CanonicalJSONEncoders.canonical().encode(requestValue)
      let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: bytes)
      guard let descriptor = RuntimeOperationCatalog.descriptor(
        reference: request.operation.reference)
      else {
        throw session.fail(.operationUnavailable, "the source operation is absent from the current Catalog")
      }
      return descriptor.binding == .confirmedDevice
    } catch let error as CLIRegistryError {
      throw error
    } catch {
      throw session.fail(.recordUnreadable, "the source Job request is not a valid typed request")
    }
  }
}
