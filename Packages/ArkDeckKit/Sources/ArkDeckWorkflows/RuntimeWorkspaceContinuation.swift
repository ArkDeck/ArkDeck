import ArkDeckCore
import ArkDeckRuntime
import Foundation

public struct RuntimeContinuationFailure: Error, Sendable, Equatable {
  public let reason: String
  init(_ reason: String) { self.reason = reason }
}

/// A new request draft, not a replay plan or stored authority. The closed
/// initial scope is the two published, device-bound observation operations.
/// Artifact leases, mutation inputs and historical session IDs never migrate.
public struct RuntimeWorkspaceContinuation: Sendable, Equatable, Identifiable {
  public let sourceJob: RuntimeJobSummaryPresentation
  public let workspaceKind: RuntimeWorkspaceKind
  public let bindingRevision: Int
  public let inputs: [String: JSONValue]
  public var id: String { sourceJob.id }

  public static func prepare(
    job: RuntimeJobSummaryPresentation, detail: RuntimeJobDetailPresentation?,
    currentTargetID: String?, currentBindingRevision: Int?
  ) -> Result<Self, RuntimeContinuationFailure> {
    guard OverviewRunRecordProjection.resumeDisposition(
      for: job, parametersWereReported: detail?.evidence?.parametersWereReported).isResumable
    else { return .failure(.init("continuation_source_not_repeatable")) }
    guard ["observe.device@1", "capture.diagnostics@1"].contains(job.operationReference),
      let descriptor = RuntimeOperationCatalog.descriptor(reference: job.operationReference),
      let detail, detail.jobID == job.id, let evidence = detail.evidence,
      evidence.actualEffect == job.actualEffect,
      let inputs = evidence.typedParameters,
      let correlation = detail.correlation, correlation.jobID == job.id,
      correlation.targetID == job.targetID, correlation.sessionID == job.sessionID,
      correlation.operationReference == job.operationReference,
      let workspaceKind = job.resolvedWorkspaceKind
        ?? RuntimeWorkspaceKindProjection.kind(forOperation: job.operationReference, inputs: inputs)
    else { return .failure(.init("continuation_typed_source_unavailable")) }
    guard currentTargetID == job.targetID,
      let recorded = evidence.bindingRevision, recorded > 0,
      currentBindingRevision == recorded
    else { return .failure(.init("continuation_target_or_binding_changed")) }
    guard inputsMatchCatalog(inputs, descriptor: descriptor),
      CatalogOperationEffectResolver.effectiveEffect(descriptor: descriptor, inputs: inputs) <= .readOnly
    else { return .failure(.init("continuation_inputs_not_read_only_or_invalid")) }
    if case .array(let markers)? = inputs["markers"], !markers.isEmpty {
      return .failure(.init("continuation_markers_require_new_capture_times"))
    }
    let draft = Self(sourceJob: job, workspaceKind: workspaceKind, bindingRevision: recorded, inputs: inputs)
    // This checks bounded thread/provenance syntax too. Missing thread is
    // allowed and remains ungrouped, rather than inventing historical lineage.
    do { _ = try draft.request() }
    catch { return .failure(.init("continuation_invalid_source_provenance")) }
    return .success(draft)
  }

  public func request(nonce: String = UUID().uuidString.lowercased()) throws -> RuntimeOperationRequest {
    let parts = sourceJob.operationReference.split(separator: "@")
    var provenance = ["arkdeck.continuedFromJob": sourceJob.id]
    if let thread = sourceJob.threadID { provenance[RuntimeClientContext.threadProvenanceKey] = thread }
    return try RuntimeOperationRequest(
      requestID: "continue-ui-\(nonce)", idempotencyKey: "continue-ui-\(nonce)",
      target: DurableTargetReference(targetID: sourceJob.targetID, expectedBindingRevision: bindingRevision),
      operation: RuntimeOperationReference(id: String(parts[0]), version: 1),
      inputs: inputs, requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
      clientContext: RuntimeClientContext(clientName: "arkdeck-overview-continuation", provenance: provenance))
  }

  package static func inputsMatchCatalog(
    _ inputs: [String: JSONValue], descriptor: CatalogOperationDescriptor
  ) -> Bool {
    guard descriptor.inputs.filter(\.isRequired).allSatisfy({ inputs[$0.name] != nil }) else { return false }
    for (name, value) in inputs {
      guard let field = descriptor.inputs.first(where: { $0.name == name }) else { return false }
      func textFits(_ text: String) -> Bool {
        (field.maxLength.map { text.utf8.count <= $0 } ?? true)
          && (field.pattern.map { text.range(of: $0, options: .regularExpression) != nil } ?? true)
      }
      switch (field.type, value) {
      case (.boolean, .bool): break
      case (.integer, .integer(let number)):
        if let minimum = field.minimum, number < minimum { return false }
        if let maximum = field.maximum, number > maximum { return false }
      case (.string, .string(let text)):
        guard textFits(text), field.enumValues?.contains(text) ?? true else { return false }
      case (.stringArray, .array(let values)):
        guard values.count <= (field.maxItems ?? 0), values.allSatisfy({
          if case .string(let text) = $0 { return textFits(text) }
          return false
        }) else { return false }
      default: return false
      }
    }
    return true
  }
}

public protocol RuntimeContinuationApplicationProviding: Sendable {
  func submit(_ draft: RuntimeWorkspaceContinuation) async -> Result<String, RuntimeContinuationFailure>
  func run(jobID: String) async -> Result<String, RuntimeContinuationFailure>
}

public enum RuntimeContinuationApplicationFacade {
  public static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> any RuntimeContinuationApplicationProviding {
    if arguments.contains("--ui-test-runtime-history") { return Fixture() }
    return RuntimeContinuationXPCProvider()
  }

  private struct Fixture: RuntimeContinuationApplicationProviding {
    func submit(_ draft: RuntimeWorkspaceContinuation) async -> Result<String, RuntimeContinuationFailure> {
      .failure(.init("fixture_continuation_not_dispatched"))
    }
    func run(jobID: String) async -> Result<String, RuntimeContinuationFailure> {
      .failure(.init("fixture_continuation_not_dispatched"))
    }
  }

}

actor RuntimeContinuationXPCProvider: RuntimeContinuationApplicationProviding {
    private var acceptedJobs: [String: RuntimeWorkspaceContinuation] = [:]
    private let reader: any RuntimeJobDetailApplicationProviding
    private let request: @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult

    init(
      reader: any RuntimeJobDetailApplicationProviding = RuntimeJobDetailApplicationFacade.make(arguments: []),
      request: @escaping @Sendable (String, [String: JSONValue]) async -> RuntimeHistoryTransportResult = {
        switch await RuntimeXPCRequestTransport.request(method: $0, params: $1) {
        case .success(let bytes): return .success(bytes)
        case .failure(let failure): return .failure(failure.message)
        }
      }
    ) {
      self.reader = reader
      self.request = request
    }

    func submit(_ draft: RuntimeWorkspaceContinuation) async -> Result<String, RuntimeContinuationFailure> {
      let fresh = await reader.loadJobDetail(jobID: draft.sourceJob.id, operationReference: draft.sourceJob.operationReference)
      guard let targets = await result("target.list") as? [[String: Any]],
        targets.filter({ $0["targetId"] as? String == draft.sourceJob.targetID }).count == 1,
        let target = targets.first(where: { $0["targetId"] as? String == draft.sourceJob.targetID }),
        let revision = target["bindingRevision"] as? Int,
        let status = await result("job.status", params: ["jobId": .string(draft.sourceJob.id)]) as? [String: Any],
        status["jobId"] as? String == draft.sourceJob.id,
        status["operation"] as? String == draft.sourceJob.operationReference,
        status["targetId"] as? String == draft.sourceJob.targetID,
        status["sessionId"] as? String == draft.sourceJob.sessionID,
        status["outcomeUnknown"] as? Bool == false,
        let state = status["state"] as? String, JobState(rawValue: state)?.isTerminal == true,
        case .success(let checked) = RuntimeWorkspaceContinuation.prepare(
          job: draft.sourceJob, detail: fresh,
          currentTargetID: draft.sourceJob.targetID, currentBindingRevision: revision),
        checked == draft
      else { return .failure(.init("continuation_source_or_target_drifted")) }
      do {
        // Fresh request + idempotency key and Runtime-owned admission. No
        // authority or Runtime session field is copied out of history.
        let request = try draft.request()
        let bytes = try CanonicalJSONEncoders.canonical().encode(request)
        guard let accepted = await result("job.submit", params: [
          "requestJson": .string(String(decoding: bytes, as: UTF8.self))
        ]) as? [String: Any], let jobID = accepted["jobId"] as? String,
          !jobID.isEmpty, jobID != draft.sourceJob.id, accepted["deduplicated"] as? Bool == false
        else {
          return .failure(.init("continuation_submit_not_confirmed"))
        }
        acceptedJobs[jobID] = draft
        return .success(jobID)
      } catch { return .failure(.init("continuation_invalid_request")) }
    }

    func run(jobID: String) async -> Result<String, RuntimeContinuationFailure> {
      guard let draft = acceptedJobs.removeValue(forKey: jobID) else {
        return .failure(.init("continuation_run_requires_newly_accepted_job"))
      }
      guard let status = await result("job.run", params: ["jobId": .string(jobID)]) as? [String: Any],
        status["jobId"] as? String == jobID,
        status["targetId"] as? String == draft.sourceJob.targetID,
        status["operation"] as? String == draft.sourceJob.operationReference,
        let state = status["state"] as? String, JobState(rawValue: state) != nil,
        status["outcomeUnknown"] as? Bool == false
      else { return .failure(.init("continuation_run_result_unconfirmed_check_history")) }
      return .success(state)
    }

    private func result(_ method: String, params: [String: JSONValue]? = nil) async -> Any? {
      guard case .success(let bytes) = await request(method, params ?? [:]),
        let response = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        response["ok"] as? Bool == true,
        response["error"] == nil || response["error"] is NSNull
      else { return nil }
      return response["result"]
    }
}
