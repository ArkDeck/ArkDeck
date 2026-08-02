// Production workspace repair adapter for ArkDeckHarness.

import ArkDeckCore
import ArkDeckHarness
import ArkDeckWorkflows
import ArkDeckStorage
import CryptoKit
import Foundation

public struct WorkspaceHarnessRepairPort: HarnessRepairPort {
  private let profile: WorkspaceProjectProfile
  private let profileRegistry: WorkspaceProjectProfileRegistry
  private let attempts: WorkspacePatchAttemptStore
  private let artifacts: RuntimeArtifactStore

  public init(
    profile: WorkspaceProjectProfile,
    attemptStore: WorkspacePatchAttemptStore,
    artifactStore: RuntimeArtifactStore
  ) {
    self.profile = profile
    self.profileRegistry = WorkspaceProjectProfileRegistry(profile: profile)
    self.attempts = attemptStore
    self.artifacts = artifactStore
  }

  public init(
    profile: WorkspaceProjectProfile,
    profileRegistry: WorkspaceProjectProfileRegistry,
    attemptStore: WorkspacePatchAttemptStore,
    artifactStore: RuntimeArtifactStore
  ) {
    self.profile = profile
    self.profileRegistry = profileRegistry
    self.attempts = attemptStore
    self.artifacts = artifactStore
  }

  public func currentWorkspaceRevision(
    relativePaths: [String], projectRef: String, task: HarnessTaskSnapshot
  ) async throws -> String {
    guard let profile = profileRegistry.profile(for: projectRef) else {
      throw HarnessRepairPortError.proposalRejected("projectProfileMismatch")
    }
    if profile.kind == .evolution {
      return try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: profile.allowedFileGlobs)
    }
    let current = try WorkspaceProviderSupport.snapshots(
      relativePaths: relativePaths, root: profile.projectRoot)
    return WorkspaceProviderSupport.revision(current)
  }

  public func preparePatch(
    _ proposal: HarnessPatchProposal,
    projectRef: String,
    task: HarnessTaskSnapshot,
    decisionID: String
  ) async throws -> HarnessPreparedPatch {
    guard let profile = profileRegistry.profile(for: projectRef) else {
      throw HarnessRepairPortError.proposalRejected("projectProfileMismatch")
    }
    let bytes = Data(proposal.unifiedDiff.utf8)
    let parsed: [String]
    do {
      parsed = try WorkspaceProviderSupport.patchPaths(from: bytes)
      guard Set(parsed) == Set(proposal.touchedFiles) else {
        throw HarnessRepairPortError.proposalRejected("touchedFilesMismatch")
      }
      try WorkspaceProviderSupport.validate(
        relativePaths: parsed, root: profile.projectRoot,
        profileGlobs: profile.allowedFileGlobs, requestGlobs: proposal.touchedFiles)
    } catch let error as HarnessRepairPortError {
      throw error
    } catch {
      throw HarnessRepairPortError.proposalRejected("\(error)")
    }
    let revision: String
    if profile.kind == .evolution {
      revision = try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: profile.allowedFileGlobs)
    } else {
      let current = try WorkspaceProviderSupport.snapshots(
        relativePaths: proposal.touchedFiles, root: profile.projectRoot)
      revision = WorkspaceProviderSupport.revision(current)
    }
    guard revision == proposal.baseWorkspaceRevision else {
      throw HarnessRepairPortError.workspaceRevisionConflict(
        expected: proposal.baseWorkspaceRevision, actual: revision)
    }

    let patchJobID = "hpatch-\(decisionID)"
    let metadata = try await artifacts.publish(
      RuntimeArtifactPublicationRequest(
        jobID: patchJobID, sessionID: task.htaskID, stepID: "propose-patch",
        name: "proposed.patch", mediaType: "text/x-diff", privacy: .standard,
        retentionClass: .pinnedUntilVerified, sourceOperation: "harness.propose-patch@1",
        providerID: "harness",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: task.target.targetID,
          // This lease is consumed by a host-only workspace operation. Keep
          // the task target as correlation, but do not fabricate a device
          // binding for a host-side patch.
          bindingRevision: nil,
          stableIdentitySHA256: nil),
        contents: bytes))
    guard metadata.sha256 == proposal.patchSHA256 else {
      throw HarnessRepairPortError.proposalRejected("publishedPatchDigestMismatch")
    }
    let lease = try await artifacts.leaseReference(
      jobID: patchJobID, artifactID: metadata.artifactID)
    return HarnessPreparedPatch(
      inputs: [
        "projectRef": .string(projectRef),
        "patchArtifactRef": .string(lease),
        // Exact paths narrow the ProjectProfile globs; the provider parses the
        // diff again and requires every touched path to match both sets.
        "allowedFileGlobs": .array(proposal.touchedFiles.map(JSONValue.string)),
      ],
      artifactLease: lease,
      artifactID: metadata.artifactID)
  }

  public func candidatePatch(
    proposal: HarnessPatchProposal,
    prepared: HarnessPreparedPatch,
    task: HarnessTaskSnapshot,
    attemptID: String,
    createdBy: HarnessCandidatePatchCreator,
    createdAtUTC: String
  ) async throws -> HarnessCandidatePatch {
    guard let diffArtifactID = prepared.artifactID else {
      throw HarnessRepairPortError.malformedReadback("candidatePatch.diffArtifactId")
    }
    let candidate = HarnessCandidatePatch.create(
      proposal: proposal, diffArtifactID: diffArtifactID,
      htaskID: task.htaskID, attemptID: attemptID,
      createdBy: createdBy, createdAtUTC: createdAtUTC)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(candidate)
    let metadata = try await artifacts.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "hcandidate-\(attemptID.lowercased())", sessionID: task.htaskID,
        stepID: "candidate-patch", name: "candidate-patch.json",
        mediaType: "application/json", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "harness.candidate-patch@1", providerID: "harness",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: task.target.targetID, bindingRevision: nil,
          stableIdentitySHA256: nil),
        contents: bytes))
    return candidate.recordingMetadataArtifact(metadata.artifactID)
  }

  public func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback {
    let fields = try await readJSONArtifact(named: "applied-patch.json", jobID: jobID)
    guard case .string(let reference)? = fields["patchAttemptRef"],
      case .string(let reportedRevision)? = fields["workspaceRevision"],
      case .string(let previousRevision)? = fields["previousWorkspaceRevision"]
    else {
      throw HarnessRepairPortError.malformedReadback("applied-patch.json")
    }
    try HarnessRepairStageGate.requireEqual(
      stage: "patchBaseRevision", expected: proposal.baseWorkspaceRevision,
      actual: previousRevision)
    let durable = try attempts.load(reference)
    let patchRevision =
      durable.workspaceRevisionAfter
      ?? WorkspaceProviderSupport.revision(durable.after)
    try HarnessRepairStageGate.requireEqual(
      stage: "appliedPatchRevision", expected: patchRevision, actual: reportedRevision)
    guard Set(durable.after.map(\.relativePath)) == Set(proposal.touchedFiles),
      durable.patchSHA256 == proposal.patchSHA256
    else {
      throw HarnessRepairPortError.stageGateMismatch(
        stage: "appliedPatchIdentity", expected: proposal.patchSHA256,
        actual: durable.patchSHA256)
    }
    return HarnessAppliedPatchReadback(
      patchAttemptRef: reference, patchRevision: patchRevision)
  }

  public func buildReadback(
    jobID: String,
    attempt: HarnessRepairAttempt,
    buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback {
    guard let patchRevision = attempt.patchRevision else {
      throw HarnessRepairPortError.malformedReadback("missingPatchRevision")
    }
    guard let projectRef = task.executionProjectRef,
      let profile = profileRegistry.profile(for: projectRef)
    else {
      throw HarnessRepairPortError.proposalRejected("projectProfileMismatch")
    }
    let sourceRevision: String
    if profile.kind == .evolution {
      sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: profile.allowedFileGlobs)
    } else {
      let current = try WorkspaceProviderSupport.snapshots(
        relativePaths: attempt.proposal.touchedFiles, root: profile.projectRoot)
      sourceRevision = WorkspaceProviderSupport.revision(current)
    }
    try HarnessRepairStageGate.requireEqual(
      stage: "buildSourceRevision", expected: patchRevision, actual: sourceRevision)
    guard let relativeProduct = profile.buildProducts[buildPresetRef] else {
      throw HarnessRepairPortError.missingBuildProduct(buildPresetRef)
    }
    // `snapshots` performs the same symlink/path containment validation as
    // patching before the product bytes are opened.
    _ = try WorkspaceProviderSupport.snapshots(
      relativePaths: [relativeProduct], root: profile.projectRoot)
    let productURL = URL(fileURLWithPath: profile.projectRoot).appendingPathComponent(
      relativeProduct)
    guard FileManager.default.fileExists(atPath: productURL.path) else {
      throw HarnessRepairPortError.missingBuildProduct(relativeProduct)
    }
    let bytes = try Data(contentsOf: productURL)
    guard
      case .string(let baselineLease)? = task.goal.desiredState[
        "baselineHapArtifactLease"]
    else {
      throw HarnessRepairPortError.malformedReadback("baselineHapArtifactLease")
    }
    let baseline = try await artifacts.resolveLease(baselineLease)
    guard baseline.bindingSnapshot.targetID == task.target.targetID,
      baseline.bindingSnapshot.bindingRevision == task.target.expectedBindingRevision,
      baseline.bindingSnapshot.stableIdentitySHA256?.count == 64
    else {
      throw HarnessRepairPortError.stageGateMismatch(
        stage: "buildOutputTargetBinding",
        expected:
          "\(task.target.targetID)@\(task.target.expectedBindingRevision.map(String.init) ?? "-")",
        actual:
          "\(baseline.bindingSnapshot.targetID)@"
          + "\(baseline.bindingSnapshot.bindingRevision.map(String.init) ?? "-")")
    }
    let metadata = try await artifacts.publish(
      RuntimeArtifactPublicationRequest(
        jobID: jobID, sessionID: task.htaskID, stepID: "harness-build-readback",
        name: "harness-build-output.hap", mediaType: "application/octet-stream",
        privacy: .standard, retentionClass: .pinnedUntilVerified,
        sourceOperation: "workspace.build-openharmony@1", providerID: "workspace",
        // This HAP later enters device-bound `debug.hap@1`. Inherit the
        // exact binding and stable identity of the immutable baseline HAP
        // already admitted for this task; host code never invents identity.
        bindingSnapshot: baseline.bindingSnapshot,
        contents: bytes))
    let lease = try await artifacts.leaseReference(
      jobID: jobID, artifactID: metadata.artifactID)
    return HarnessBuildReadback(
      sourceRevision: sourceRevision, outputDigest: metadata.sha256,
      outputArtifactLease: lease)
  }

  public func deployedArtifactDigest(jobID: String) async throws -> String {
    let fields = try await readJSONArtifact(named: "install-readback.json", jobID: jobID)
    guard case .string(let digest)? = fields["deployedArtifactSha256"],
      digest.count == 64
    else {
      throw HarnessRepairPortError.malformedReadback("install-readback.json")
    }
    return digest
  }

  public func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback {
    if let applied = try? await appliedPatchReadback(jobID: jobID, proposal: proposal) {
      return .patchApplied(applied)
    }
    let fields = try await readJSONArtifact(named: "applied-patch.json", jobID: jobID)
    guard case .string(let reference)? = fields["patchAttemptRef"] else {
      return .stillUnknown
    }
    let durable = try attempts.load(reference)
    let revision: String
    if let profile = profileRegistry.profile(for: durable.projectRef),
      profile.kind == .evolution
    {
      revision = try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: profile.allowedFileGlobs)
    } else {
      let current = try WorkspaceProviderSupport.snapshots(
        relativePaths: proposal.touchedFiles, root: durable.projectRoot)
      revision = WorkspaceProviderSupport.revision(current)
    }
    if revision == proposal.baseWorkspaceRevision { return .patchNotApplied }
    // Some bytes changed, but there is no exact durable provider postimage.
    // That is not success and not permission to run the patch again.
    return .partiallyApplied
  }

  private func readJSONArtifact(
    named name: String, jobID: String
  ) async throws -> [String: JSONValue] {
    let inventory = try await artifacts.list(jobID: jobID)
    let metadata = inventory.first { $0.name == name && $0.status.isPublished }
    guard let metadata else { throw HarnessRepairPortError.malformedReadback(name) }
    let bytes = try await artifacts.read(
      jobID: jobID, artifactID: metadata.artifactID, maximumBytes: max(1, metadata.byteCount))
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: bytes),
      case .object(let fields) = value
    else {
      throw HarnessRepairPortError.malformedReadback(name)
    }
    return fields
  }
}
