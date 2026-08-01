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
