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
}

public struct RuntimeArtifactStoreHarnessPort: HarnessArtifactPort {
  private let store: RuntimeArtifactStore
  /// The operator's sensitive-evidence opt-in, by artifact name, enforced here
  /// as well as in the observation builder.
  ///
  /// Two gates on purpose. The builder decides *what to consider*; this port
  /// decides *what may actually be read*, so a future builder change cannot
  /// widen access on its own. Measured need: with the opt-in wired only into
  /// the builder, the 2026-07-31 GJ-5 window captured real HiLog, was allowed
  /// to look at it, and then failed with
  /// `evidenceIntegrity:artifactUnreadable:hilog.txt` - the store's own
  /// `allowSensitive` defaults to false, so the read was refused after the
  /// decision to read it had already been made. A half-wired opt-in is a
  /// stop, not a leak, but it is still a stop.
  private let sensitiveEvidenceAllowList: Set<String>

  public init(store: RuntimeArtifactStore, sensitiveEvidenceAllowList: Set<String> = []) {
    self.store = store
    self.sensitiveEvidenceAllowList = sensitiveEvidenceAllowList
  }

  public func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor] {
    do {
      return try await store.list(jobID: jobID).map { metadata in
        HarnessArtifactDescriptor(
          artifactID: metadata.artifactID,
          name: metadata.name,
          mediaType: metadata.mediaType,
          byteCount: metadata.byteCount,
          sha256: metadata.sha256,
          published: metadata.status.isPublished,
          sensitive: metadata.privacy == .sensitive,
          // A declared-but-absent artifact carries the store's own reason;
          // the evaluator reports it instead of inventing one.
          missingReason: metadata.status.isPublished ? nil : "\(metadata.status)")
      }
    } catch {
      throw HarnessArtifactPortError.unavailable("\(error)")
    }
  }

  public func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data {
    do {
      // The name, not the caller's word, decides: an artifact is readable as
      // sensitive only if the operator named it. Anything else keeps the
      // store's default refusal.
      let metadata = try await store.list(jobID: jobID)
        .first { $0.artifactID == artifactID }
      let allowSensitive =
        metadata.map { sensitiveEvidenceAllowList.contains($0.name) } ?? false
      return try await store.read(
        jobID: jobID, artifactID: artifactID, maximumBytes: maximumBytes,
        allowSensitive: allowSensitive)
    } catch {
      throw HarnessArtifactPortError.unreadable("\(error)")
    }
  }
}
