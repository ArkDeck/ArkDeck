// Evidence access for the evaluator (CHG-2026-054, TASK-HTP-002).
//
// The evaluator never touches the filesystem: it asks this port for the
// inventory a job published and for bytes by artifact id. Two properties
// matter more than convenience:
//
//   * the port reports *what the store recorded* - byte count, SHA-256,
//     published/missing status - so the observation builder can verify the
//     bytes it reads rather than trusting them;
//   * sensitive artifacts are not opted into. The harness evaluates what it
//     is allowed to read, and an artifact it may not read is a blocker, not
//     a silent omission.

import ArkDeckCore
import Foundation

public struct HarnessArtifactDescriptor: Equatable, Sendable {
  public let artifactID: String
  public let name: String
  public let mediaType: String
  public let byteCount: Int
  public let sha256: String
  public let published: Bool
  public let sensitive: Bool
  public let missingReason: String?

  public init(
    artifactID: String,
    name: String,
    mediaType: String,
    byteCount: Int,
    sha256: String,
    published: Bool,
    sensitive: Bool,
    missingReason: String? = nil
  ) {
    self.artifactID = artifactID
    self.name = name
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.sha256 = sha256
    self.published = published
    self.sensitive = sensitive
    self.missingReason = missingReason
  }
}

public enum HarnessArtifactPortError: Error, Equatable, Sendable {
  case unavailable(String)
  case unreadable(String)
}

public protocol HarnessArtifactPort: Sendable {
  func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor]
  func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data
  /// Mint the store's ID-only lease for a verified published Artifact.  The
  /// coordinator uses it only to hand raw evidence to a typed analyzer job;
  /// no host path crosses this boundary.
  func leaseReference(jobID: String, artifactID: String) async throws -> String
}

extension HarnessArtifactPort {
  public func leaseReference(jobID: String, artifactID: String) async throws -> String {
    throw HarnessArtifactPortError.unavailable(
      "artifact leases are unavailable in this composition")
  }
}
