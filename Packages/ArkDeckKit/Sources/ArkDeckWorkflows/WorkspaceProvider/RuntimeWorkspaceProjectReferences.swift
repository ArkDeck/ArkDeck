import ArkDeckCore
import ArkDeckRuntime
import Foundation

extension RuntimeAdmissionService {
  private static let workspacePresetInputNames: Set<String> = [
    "buildPresetRef", "testPresetRef", "signingPresetRef", "symbolPresetRef",
  ]

  /// Runs while the registration owner excludes in-flight materialization.
  /// A Job whose initial record is durable is therefore visible here before
  /// its short-lived owner token is released, closing the remove/admit race.
  func requireNoActiveWorkspaceProjectReference(
    _ projectRef: String,
    resolveRegistrationProjectRef: (String) -> String? = { _ in nil }
  ) throws {
    try forEachJob { persisted in
      guard let data = persisted.initialRecordData,
        let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data),
        record.jobID == persisted.jobID, record.state == persisted.state,
        record.request.idempotencyKey == persisted.idempotencyKey,
        record.hasVerifiedSubmissionFingerprint(persisted.requestHash),
        persisted.createdAtMatches(record.createdAtUTC), persisted.version > 0
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace Job references cannot be verified")
      }
      if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true { return }
      // The provider is a durable identity fact of the record: a Job another
      // provider owns cannot reference a workspace project, whatever Catalog
      // digest it was admitted under.
      guard record.providerID == CatalogProvider.workspace.rawValue else { return }
      let referencedProject: String
      if let descriptor = Self.currentDescriptor(for: record) {
        guard descriptor.inputs.contains(where: { $0.name == "projectRef" }) else { return }
        guard case .string(let typed)? = record.request.inputs["projectRef"] else {
          throw RuntimeWorkspaceProjectFailure(
            "recordUnreadable", "active workspace Job has no typed project reference")
        }
        referencedProject = typed
      } else {
        // A nonterminal workspace Job from another Catalog digest has no
        // descriptor to type its inputs against, but its inputs are still
        // durable text under the same closed names. Reading the project
        // reference directly can only over-report a reference, never miss one.
        guard case .string(let durable)? = record.request.inputs["projectRef"] else {
          throw RuntimeWorkspaceProjectFailure(
            "recordUnreadable", "active workspace Job has no verifiable project reference")
        }
        referencedProject = durable
      }
      // A Runtime-owned isolated copy is named by its derived projectRef in
      // the request, but its registration, preset pins and removal protection
      // belong to the source project. Admission uses this same provider-owned
      // mapping before making the Job durable; the durable-reference scan must
      // reuse it after the short-lived use token has been released. Unknown
      // legacy/stale references keep the conservative literal comparison.
      let registrationProject =
        resolveRegistrationProjectRef(referencedProject) ?? referencedProject
      if registrationProject == projectRef {
        throw RuntimeWorkspaceProjectFailure(
          "resourceConflict", "workspace project is referenced by an active or uncertain Job")
      }
    }
  }

  func requireNoActiveWorkspacePresetReference(_ presetRef: String) throws {
    try forEachJob { persisted in
      guard let data = persisted.initialRecordData,
        let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data),
        record.jobID == persisted.jobID, record.state == persisted.state,
        record.request.idempotencyKey == persisted.idempotencyKey,
        record.hasVerifiedSubmissionFingerprint(persisted.requestHash),
        persisted.createdAtMatches(record.createdAtUTC), persisted.version > 0
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace Job references cannot be verified")
      }
      if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true { return }
      guard record.providerID == CatalogProvider.workspace.rawValue else { return }
      // With a current descriptor only its declared preset inputs count; a
      // stale-digest Job is read by the closed preset input names directly.
      let presetInputNames: [String] =
        Self.currentDescriptor(for: record).map { descriptor in
          descriptor.inputs.map(\.name).filter(Self.workspacePresetInputNames.contains)
        } ?? Self.workspacePresetInputNames.sorted()
      for name in presetInputNames {
        if case .string(let referencedPreset)? = record.request.inputs[name],
          referencedPreset == presetRef
        {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace preset is referenced by an active or uncertain Job")
        }
      }
    }
  }

  /// The record's descriptor in this build's Catalog, when the record was
  /// admitted under this exact digest; `nil` for a Job from another digest.
  private static func currentDescriptor(for record: RuntimeJobRecord) -> CatalogOperationDescriptor? {
    guard record.catalogDigest == RuntimeOperationCatalog.catalogDigest,
      record.operationReference == record.request.operation.reference
    else { return nil }
    return RuntimeOperationCatalog.descriptor(reference: record.operationReference)
  }
}
