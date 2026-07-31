// Host-fact boundary for the harness repair leg
// (CHG-2026-055, TASK-HFA-003).
//
// The coordinator never opens a workspace path and never creates a command.
// It asks this port to turn an already bounded patch proposal into an
// immutable Artifact lease, and to read back the three structural gates.  A
// fake implementation can exercise the complete host/fake-device journey;
// the production implementation below binds the checks to one
// repository-managed WorkspaceProjectProfile and RuntimeArtifactStore.

import ArkDeckCore
import CryptoKit
import Foundation

public enum HarnessRepairPortError: Error, Equatable, Sendable {
  case unavailable(String)
  case proposalRejected(String)
  case workspaceRevisionConflict(expected: String, actual: String)
  case stageGateMismatch(stage: String, expected: String, actual: String)
  case missingBuildProduct(String)
  case malformedReadback(String)

  public var reasonCode: String {
    switch self {
    case .unavailable(let reason): return "repairUnavailable:\(reason)"
    case .proposalRejected(let reason): return "patchProposalRejected:\(reason)"
    case .workspaceRevisionConflict: return "WORKSPACE_REVISION_CONFLICT"
    case .stageGateMismatch(let stage, _, _): return "stageGateMismatch:\(stage)"
    case .missingBuildProduct: return "buildOutputUnavailable"
    case .malformedReadback(let name): return "malformedRepairReadback:\(name)"
    }
  }
}

/// One equality primitive for all three repair-stage gates. Keeping the
/// comparison structural and shared prevents a future stage from degrading
/// into a truthy "build succeeded"/"install succeeded" check.
public enum HarnessRepairStageGate {
  public static func requireEqual(
    stage: String, expected: String, actual: String
  ) throws {
    guard !expected.isEmpty, actual == expected else {
      throw HarnessRepairPortError.stageGateMismatch(
        stage: stage, expected: expected, actual: actual)
    }
  }
}

public struct HarnessPreparedPatch: Equatable, Sendable {
  public let inputs: [String: JSONValue]
  public let artifactLease: String

  public init(inputs: [String: JSONValue], artifactLease: String) {
    self.inputs = inputs
    self.artifactLease = artifactLease
  }
}

public struct HarnessAppliedPatchReadback: Equatable, Sendable {
  public let patchAttemptRef: String
  public let patchRevision: String

  public init(patchAttemptRef: String, patchRevision: String) {
    self.patchAttemptRef = patchAttemptRef
    self.patchRevision = patchRevision
  }
}

public struct HarnessBuildReadback: Equatable, Sendable {
  public let sourceRevision: String
  public let outputDigest: String
  public let outputArtifactLease: String

  public init(sourceRevision: String, outputDigest: String, outputArtifactLease: String) {
    self.sourceRevision = sourceRevision
    self.outputDigest = outputDigest
    self.outputArtifactLease = outputArtifactLease
  }
}

public enum HarnessPatchApplicationReadback: Equatable, Sendable {
  case patchApplied(HarnessAppliedPatchReadback)
  case patchNotApplied
  case stillUnknown
  case partiallyApplied
}

public protocol HarnessRepairPort: Sendable {
  func preparePatch(
    _ proposal: HarnessPatchProposal,
    projectRef: String,
    task: HarnessTaskSnapshot,
    decisionID: String
  ) async throws -> HarnessPreparedPatch

  func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback

  func buildReadback(
    jobID: String,
    attempt: HarnessRepairAttempt,
    buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback

  func deployedArtifactDigest(jobID: String) async throws -> String

  func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback
}

public struct WorkspaceHarnessRepairPort: HarnessRepairPort {
  private let profile: WorkspaceProjectProfile
  private let attempts: WorkspacePatchAttemptStore
  private let artifacts: RuntimeArtifactStore

  public init(
    profile: WorkspaceProjectProfile,
    attemptStore: WorkspacePatchAttemptStore,
    artifactStore: RuntimeArtifactStore
  ) {
    self.profile = profile
    self.attempts = attemptStore
    self.artifacts = artifactStore
  }

  public func preparePatch(
    _ proposal: HarnessPatchProposal,
    projectRef: String,
    task: HarnessTaskSnapshot,
    decisionID: String
  ) async throws -> HarnessPreparedPatch {
    guard projectRef == profile.projectRef else {
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
    let current = try WorkspaceProviderSupport.snapshots(
      relativePaths: proposal.touchedFiles, root: profile.projectRoot)
    let revision = WorkspaceProviderSupport.revision(current)
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
          bindingRevision: task.target.expectedBindingRevision,
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
      artifactLease: lease)
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
    let patchRevision = WorkspaceProviderSupport.revision(durable.after)
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
    let current = try WorkspaceProviderSupport.snapshots(
      relativePaths: attempt.proposal.touchedFiles, root: profile.projectRoot)
    let sourceRevision = WorkspaceProviderSupport.revision(current)
    try HarnessRepairStageGate.requireEqual(
      stage: "buildSourceRevision", expected: patchRevision, actual: sourceRevision)
    guard let relativeProduct = profile.buildProducts[buildPresetRef] else {
      throw HarnessRepairPortError.missingBuildProduct(buildPresetRef)
    }
    // `snapshots` performs the same symlink/path containment validation as
    // patching before the product bytes are opened.
    _ = try WorkspaceProviderSupport.snapshots(
      relativePaths: [relativeProduct], root: profile.projectRoot)
    let productURL = URL(fileURLWithPath: profile.projectRoot).appendingPathComponent(relativeProduct)
    guard FileManager.default.fileExists(atPath: productURL.path) else {
      throw HarnessRepairPortError.missingBuildProduct(relativeProduct)
    }
    let bytes = try Data(contentsOf: productURL)
    let metadata = try await artifacts.publish(
      RuntimeArtifactPublicationRequest(
        jobID: jobID, sessionID: task.htaskID, stepID: "harness-build-readback",
        name: "harness-build-output.hap", mediaType: "application/octet-stream",
        privacy: .standard, retentionClass: .pinnedUntilVerified,
        sourceOperation: "workspace.build-openharmony@1", providerID: "workspace",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: task.target.targetID,
          bindingRevision: task.target.expectedBindingRevision,
          stableIdentitySHA256: nil),
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
    let current = try WorkspaceProviderSupport.snapshots(
      relativePaths: proposal.touchedFiles, root: profile.projectRoot)
    let revision = WorkspaceProviderSupport.revision(current)
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
