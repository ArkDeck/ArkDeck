import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import Foundation

/// Only Catalog-declared Artifact slots can hold an executable input lease.
/// Plain strings, arbitrary nested JSON and caller paths never become refs.
package struct RuntimeImportLeaseReference: Equatable, Hashable, Sendable {
  package let value: String
  package let importID: String
  package let artifactID: String

  package init?(_ value: String) throws {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts[0] == "lease-v1", parts[1].hasPrefix("imp-") else { return nil }
    guard parts.count == 3, let uuid = UUID(uuidString: String(parts[1].dropFirst(4))),
      "imp-" + uuid.uuidString.lowercased() == parts[1], parts[2].hasPrefix("ART-"),
      parts[2].count == 36, parts[2].dropFirst(4).allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else {
      throw AgentExecutionControlFailure("invalidInput", "imported input requires an exact registered lease")
    }
    self.value = value; importID = String(parts[1]); artifactID = String(parts[2])
  }

  package static func inputs(_ inputs: [String: JSONValue], descriptor: CatalogOperationDescriptor) throws -> [Self] {
    guard Set(inputs.keys).isSubset(of: Set(descriptor.inputs.map(\.name))) else {
      throw AgentExecutionControlFailure("invalidInput", "input references contain an undeclared slot")
    }
    var found = Set<Self>()
    for field in descriptor.inputs {
      guard !field.isRequired || inputs[field.name] != nil else {
        throw AgentExecutionControlFailure("invalidInput", "required input reference metadata is missing")
      }
      let values: [JSONValue]
      switch field.type {
      case .artifactLease, .artifactReference: values = inputs[field.name].map { [$0] } ?? []
      case .artifactLeaseArray:
        guard let value = inputs[field.name] else { continue }
        guard case .array(let array) = value else { throw AgentExecutionControlFailure("invalidInput", "Artifact array input is malformed") }
        values = array
      default: continue
      }
      for value in values {
        guard case .string(let text) = value else { throw AgentExecutionControlFailure("invalidInput", "Artifact input is malformed") }
        if let reference = try Self(text) { found.insert(reference) }
      }
    }
    return found.sorted { $0.value.utf8.lexicographicallyPrecedes($1.value.utf8) }
  }
}

/// An in-flight materialization hold, created and recognized only by the
/// Artifact actor. It is not a Runtime capability and permits no dispatch.
package struct RuntimeImportUseToken: Sendable {
  let id: UUID
  let references: [RuntimeImportLeaseReference]
}

extension RuntimeAdmissionService {
  /// Invoked synchronously inside the Artifact owner's release transaction.
  /// Every admission owns an Artifact-actor hold until its Job row is durable.
  /// Release refuses such holds before calling this bounded read, so no Job
  /// insertion can become untracked. Durable inputs retain the reference after
  /// a crash; no second reference count can drift.
  func requireNoActiveImportReference(_ importID: String) throws {
    try forEachActiveImportReference(importID) { _ in
      throw AgentExecutionControlFailure("resourceConflict", "Import is still referenced by an active or uncertain Job")
    }
  }

  func activeImportReferenceJobs(_ importID: String) throws -> [(id: String, outcomeUnknown: Bool)] {
    var jobs: [(id: String, outcomeUnknown: Bool)] = []
    try forEachActiveImportReference(importID) { record in
      guard jobs.count < 1000 else { throw AgentExecutionControlFailure("inputTooLarge", "Import reference inspection exceeds its Job bound") }
      jobs.append((record.jobID, record.outcomeUnknown))
    }
    return jobs.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
  }

  /// Reuse exactly the release owner's durable-reference verification. This
  /// scan runs synchronously while the Artifact actor holds its observation;
  /// no asynchronous gap can separate plan holds from committed Job refs.
  private func forEachActiveImportReference(_ importID: String, visit: (RuntimeJobRecord) throws -> Void) throws {
    try forEachJob { persisted in
      guard let data = persisted.initialRecordData,
        let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data),
        record.jobID == persisted.jobID, record.state == persisted.state,
        record.request.idempotencyKey == persisted.idempotencyKey,
        record.hasVerifiedSubmissionFingerprint(persisted.requestHash),
        record.createdAtUTC == persisted.createdAtUTC, persisted.version > 0 else {
        throw AgentExecutionControlFailure("recordUnreadable", "Job references cannot be verified from durable history")
      }
      if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true { return }
      guard record.catalogDigest == RuntimeOperationCatalog.catalogDigest,
        record.operationReference == record.request.operation.reference,
        let descriptor = RuntimeOperationCatalog.descriptor(reference: record.operationReference) else {
        throw AgentExecutionControlFailure("recordUnreadable", "active Job Artifact slots have no verifiable Catalog")
      }
      let references: [RuntimeImportLeaseReference]
      do { references = try RuntimeImportLeaseReference.inputs(record.request.inputs, descriptor: descriptor) }
      catch { throw AgentExecutionControlFailure("recordUnreadable", "active Job Artifact references are malformed") }
      if references.contains(where: { $0.importID == importID }) {
        try visit(record)
      }
    }
  }
}
