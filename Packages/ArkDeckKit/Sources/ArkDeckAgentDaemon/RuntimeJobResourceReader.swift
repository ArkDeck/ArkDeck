import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Current v1 read resources. A result is assembled inside the Runtime owner;
/// the client never guesses that several unrelated reads form one Job result.
struct RuntimeJobResourceReader {
  let engine: RuntimeJobEngine
  let artifactStore: RuntimeArtifactStore?

  func response(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    do {
      let fields = request.params ?? [:]
      let result: JSONValue
      if request.method == "job.list" {
        result = try await engine.jobListSnapshot(RuntimeJobListQuery(fields))
      } else {
        let allowed: Set<String> = request.method == "job.timeline" ? ["jobId", "pageSize", "cursor"] : ["jobId"]
        guard Set(fields.keys).isSubset(of: allowed),
          case .string(let jobID)? = fields["jobId"], AgentExecutionIntent.validIdentifier(jobID)
        else { throw failure("invalidInput", "an exact Job identity and closed read options are required") }
        if request.method == "job.timeline" {
          var options = fields; options.removeValue(forKey: "jobId")
          let query = try RuntimeJobListQuery(options)
          result = try await engine.jobTimelineSnapshot(jobID: jobID, pageSize: query.pageSize, cursor: query.cursor)
        } else {
          let captured = try await engine.jobReadSnapshot(jobID: jobID)
          switch request.method {
          case "job.status": result = try RuntimeJobReadProjection.status(captured.status)
          case "job.show": result = try RuntimeJobReadProjection.show(captured.record, status: captured.status)
          case "job.result", "job.evidence":
            let terminal = JobState(rawValue: captured.status.state)?.isTerminal == true
            if request.method == "job.result", !terminal {
              throw AgentExecutionControlFailure("resultNotReady", "the Job has no terminal result yet", details: [
                "jobId": .string(jobID), "state": .string(captured.status.state),
                "nextAction": try RuntimeJobReadProjection.nextAction(captured.status),
              ])
            }
            let verified = try await evidence(record: captured.record, terminal: terminal)
            if request.method == "job.evidence" { result = verified.evidence }
            else {
              let debts: [CleanupDebtRecord]
              do { debts = try await engine.listCleanupDebt().filter { $0.jobID == jobID } }
              catch { throw failure("recordUnreadable", "the Job cleanup ledger is unreadable") }
              var next = try RuntimeJobReadProjection.nextAction(captured.status)
              let cleanup = try debts.map(Self.cleanup)
              if !captured.status.outcomeUnknown, let first = cleanup.first,
                case .object(let fields) = first, let id = fields["cleanupDebtId"] {
                next = .object([
                  "kind": .string("cleanup"), "owner": .object(["kind": .string("job"), "id": .string(jobID)]),
                  "resource": .object(["kind": .string("cleanupDebt"), "id": id]),
                  "reasonCode": .string("recovery.cleanupDebt"),
                ])
              } else if !captured.status.outcomeUnknown { next = .null }
              guard case .object(var job) = try RuntimeJobReadProjection.status(captured.status) else {
                throw failure("recordUnreadable", "the Job status is unreadable")
              }
              job["outstandingResidueCount"] = .integer(Int64(debts.count))
              result = .object([
                "schemaVersion": .string("arkdeck.job-result/1"),
                "job": .object(job),
                "terminal": .bool(terminal), "outcomeUnknown": .bool(captured.status.outcomeUnknown),
                "evidence": verified.evidence, "artifacts": .array(verified.inventory),
                "cleanup": .array(cleanup), "nextAction": next,
              ])
            }
            // Async verification cannot attach evidence from a newer Job
            // snapshot to an older state. A caller can retry this read only.
            let current = try await engine.jobReadSnapshot(jobID: jobID)
            guard current.record == captured.record else {
              throw failure("resourceConflict", "the Job changed while its evidence was being read")
            }
          default: throw failure("controlMethodUnavailable", "the Job read method is not published")
          }
        }
      }
      return .init(id: request.id, ok: true, result: try RuntimeJobReadProjection.bounded(result), error: nil)
    } catch let error as AgentExecutionControlFailure {
      var details = error.details
      details["phase"] = .string("preAdmission")
      details["newDispatchCount"] = .integer(0)
      return .init(id: request.id, ok: false, result: nil,
        error: .init(code: error.code, message: error.message, details: details))
    } catch RuntimeJobEngineError.jobNotFound {
      return .init(id: request.id, ok: false, result: nil,
        error: .init(code: "notFound", message: "the referenced Job does not exist"))
    } catch {
      return .init(id: request.id, ok: false, result: nil,
        error: .init(code: "recordUnreadable", message: "the Job read resource is unreadable"))
    }
  }

  private func evidence(record: RuntimeJobRecord, terminal: Bool) async throws -> (evidence: JSONValue, inventory: [JSONValue]) {
    let jobID = record.jobID
    var blockers: Set<String> = []
    var metadata: [RuntimeArtifactMetadata] = []
    var verified: [RuntimeVerifiedArtifactEvidence] = []
    var inventoryAvailable = false
    let descriptor = record.catalogDigest == RuntimeOperationCatalog.catalogDigest
      ? RuntimeOperationCatalog.descriptor(reference: record.operationReference) : nil
    if descriptor == nil { blockers.insert("operationUnavailable") }
    let omitted: Set<String>
    do { omitted = try await engine.intentionallyOmittedArtifactNames(jobID: jobID) }
    catch { omitted = []; blockers.insert("recordUnreadable") }
    if let artifactStore {
      do {
        let inventory = try await artifactStore.evidenceInventory(jobID: jobID, intentionallyOmittedNames: omitted)
        metadata = inventory.metadata
        inventoryAvailable = true
        guard metadata.allSatisfy({
          $0.jobID == jobID && $0.providerID == record.providerID && $0.sourceOperation == record.operationReference
            && $0.bindingSnapshot.targetID == record.request.target.targetID
            && (record.materializedBindingRevision == nil || $0.bindingSnapshot.bindingRevision == record.materializedBindingRevision)
            && (record.materializedStableTargetIdentitySHA256 == nil || $0.bindingSnapshot.stableIdentitySHA256 == record.materializedStableTargetIdentitySHA256)
        }) else { throw failure("artifactIntegrityFailed", "Artifact ownership does not match its Job") }
        verified = inventory.verified
        if inventory.integrityFailed { blockers.insert("artifactIntegrityFailed") }
      } catch { blockers.insert("artifactIntegrityFailed") }
    } else if descriptor?.artifacts.isEmpty != true { blockers.insert("artifactStoreUnavailable") }
    let expected = Set((descriptor?.artifacts ?? []).filter { $0.isRequired && !omitted.contains($0.name) }.map(\.name))
    let missing = expected.subtracting(Set(metadata.map(\.name)))
    if !missing.isEmpty { blockers.insert("artifactIntegrityFailed") }
    if !terminal { blockers.insert("resultNotReady") }
    let snapshot: RuntimeJobEvidenceSnapshot?
    do { snapshot = try await engine.evidenceSnapshot(jobID: jobID) }
    catch { snapshot = nil; blockers.insert("recordUnreadable") }
    let reason: String
    if !terminal { reason = "resultNotReady" }
    else if blockers.contains("recordUnreadable") { reason = "recordUnreadable" }
    else if blockers.contains("artifactIntegrityFailed") || blockers.contains("artifactStoreUnavailable") { reason = "artifactIntegrityFailed" }
    else if blockers.contains("operationUnavailable") { reason = "operationUnavailable" }
    else { reason = "verified" }
    var fields: [String: JSONValue]
    if let snapshot, case .object(let value) = RuntimeControlPlaneHandler.encodeEvidence(
      snapshot: snapshot, artifacts: verified, blockers: blockers.sorted()) { fields = value }
    else {
      fields = ["jobId": .string(jobID), "operationReference": .string(record.operationReference),
        "catalogDigest": .string(record.catalogDigest), "targetId": .string(record.request.target.targetID),
        "terminalState": .string(record.outcomeUnknown ? "outcomeUnknown" : record.state),
        "outcomeUnknown": .bool(record.outcomeUnknown), "artifacts": .array([]),
        "blockers": .array(blockers.sorted().map(JSONValue.string))]
    }
    // A failed evidence read retains the same closed shape. Unknown facts are
    // explicit nulls, not invented defaults or an alternate success schema.
    for name in ["bindingRevision", "providerId", "actualEffect", "authority", "observation", "actualStepKinds",
      "executionMode", "startedAtUtc", "firstEvidenceStepAtUtc", "finishedAtUtc", "recoveryEpoch",
      "parameters", "traceProbeBefore", "traceProbeAfter"] where fields[name] == nil {
      fields[name] = .null
    }
    if case .array(let values)? = fields["artifacts"] {
      fields["artifacts"] = .array(values.map { value in
        guard case .object(var row) = value else { return value }
        if case .integer(let count)? = row["byteCount"] { row["byteCount"] = .string(String(count)) }
        return .object(row)
      })
    }
    fields["schemaVersion"] = .string("arkdeck.job-evidence/1")
    fields["status"] = .string(reason)
    fields["inventoryAvailable"] = .bool(inventoryAvailable || descriptor?.artifacts.isEmpty == true)
    fields["missingRequiredArtifacts"] = .array(missing.sorted().map(JSONValue.string))
    let verifiedReferences = Set(verified.map(\.reference))
    let inventory = metadata.sorted { ($0.name, $0.artifactID) < ($1.name, $1.artifactID) }.map { value in
      let reference = "arkdeck-artifact://\(jobID)/\(value.artifactID)"
      let state: String
      switch value.status { case .published: state = "published"; case .missing: state = "missing"; case .truncated: state = "truncated" }
      return JSONValue.object([
        "artifactId": .string(value.artifactID), "owner": .object(["kind": .string("job"), "id": .string(jobID)]),
        "reference": .string(reference), "name": .string(value.name), "mediaType": .string(value.mediaType),
        "byteCount": .string(String(value.byteCount)), "sha256": .string(value.sha256),
        "privacy": .string(value.privacy.rawValue), "status": .string(state),
        "bytesVerified": .bool(verifiedReferences.contains(reference)),
      ])
    }
    return (.object(fields), inventory)
  }

  private static func cleanup(_ value: CleanupDebtRecord) throws -> JSONValue {
    let identity = try PortableCanonicalJSON.canonicalBytes(.object([
      "jobId": .string(value.jobID), "identity": .string(value.identity), "recordedAtUtc": .string(value.recordedAtUTC),
    ]))
    return .object([
      "cleanupDebtId": .string("cleanup-" + SHA256Hex.string(of: identity)),
      "jobId": .string(value.jobID), "stepId": .string(value.stepID),
      "recordedAtUtc": .string(value.recordedAtUTC),
      "outcomeUnknown": .bool(value.retryOutcomeUnknown == true || value.retryAttemptStartedAtUTC != nil),
    ])
  }
  private func failure(_ code: String, _ text: String) -> AgentExecutionControlFailure { .init(code, text) }
}
