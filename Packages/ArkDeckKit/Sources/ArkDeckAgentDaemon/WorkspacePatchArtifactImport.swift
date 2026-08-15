import ArkDeckCore
import ArkDeckWorkflows
import Foundation

enum WorkspacePatchArtifactImportError: Error, Equatable, CustomStringConvertible {
  case invalidName
  case invalidByteCount
  case invalidSHA256
  case stagingCapacityExceeded
  case unknownUpload
  case expiredUpload
  case offsetMismatch(expected: Int, actual: Int)
  case invalidChunk
  case incompleteUpload(expected: Int, actual: Int)
  case digestMismatch
  case invalidUnifiedDiff

  var description: String {
    switch self {
    case .invalidName:
      return "workspace patch name must be a safe .patch or .diff basename"
    case .invalidByteCount:
      return
        "workspace patch byteCount must be 1..."
        + "\(WorkspacePatchArtifactImportCoordinator.maximumPatchBytes)"
    case .invalidSHA256:
      return "workspace patch sha256 must be 64 lowercase hexadecimal characters"
    case .stagingCapacityExceeded:
      return "workspace patch import staging capacity is exhausted"
    case .unknownUpload:
      return "unknown workspace patch import upload"
    case .expiredUpload:
      return "workspace patch import upload expired"
    case .offsetMismatch(let expected, let actual):
      return "workspace patch import offset mismatch: expected \(expected), got \(actual)"
    case .invalidChunk:
      return
        "workspace patch import chunk must be 1..."
        + "\(WorkspacePatchArtifactImportCoordinator.maximumChunkBytes) bytes"
    case .incompleteUpload(let expected, let actual):
      return "workspace patch import is incomplete: expected \(expected), got \(actual)"
    case .digestMismatch:
      return "workspace patch import sha256 does not match the declared digest"
    case .invalidUnifiedDiff:
      return "workspace patch import is not a safe bounded UTF-8 unified diff"
    }
  }
}

/// Bounded, target-correlated ingestion for a host-side workspace patch.
///
/// Importing bytes grants no workspace authority. `workspace.apply-patch@1`
/// resolves the returned immutable lease and independently enforces the exact
/// workspace revision, ProjectProfile scope, requested paths and Runtime
/// capability before the first mutation.
actor WorkspacePatchArtifactImportCoordinator {
  static let maximumPatchBytes = 512 * 1_024
  static let maximumChunkBytes = 128 * 1_024
  private static let maximumStagedBytes = maximumPatchBytes
  private static let lifetimeSeconds: TimeInterval = 5 * 60

  struct Completed: Sendable {
    let targetID: String
    let name: String
    let sha256: String
    let contents: Data
    let touchedFiles: [String]
  }

  private struct Session: Sendable {
    let targetID: String
    let name: String
    let expectedByteCount: Int
    let expectedSHA256: String
    let createdAt: Date
    var contents: Data
  }

  private var sessions: [String: Session] = [:]

  func begin(
    targetID: String,
    name: String,
    byteCount: Int,
    sha256: String,
    now: Date = Date()
  ) throws -> String {
    _ = pruneExpired(now: now)
    guard Self.isSafePatchName(name) else {
      throw WorkspacePatchArtifactImportError.invalidName
    }
    guard (1...Self.maximumPatchBytes).contains(byteCount) else {
      throw WorkspacePatchArtifactImportError.invalidByteCount
    }
    guard SHA256Hex.isLowercaseSHA256(sha256) else {
      throw WorkspacePatchArtifactImportError.invalidSHA256
    }
    let staged = sessions.values.reduce(0) { $0 + $1.expectedByteCount }
    guard staged <= Self.maximumStagedBytes - byteCount else {
      throw WorkspacePatchArtifactImportError.stagingCapacityExceeded
    }
    let uploadID = "PATCH-\(UUID().uuidString.lowercased())"
    sessions[uploadID] = Session(
      targetID: targetID,
      name: name,
      expectedByteCount: byteCount,
      expectedSHA256: sha256,
      createdAt: now,
      contents: Data())
    return uploadID
  }

  func append(
    uploadID: String,
    offset: Int,
    chunk: Data,
    now: Date = Date()
  ) throws -> Int {
    let expired = pruneExpired(now: now)
    if expired.contains(uploadID) {
      throw WorkspacePatchArtifactImportError.expiredUpload
    }
    guard var session = sessions[uploadID] else {
      throw WorkspacePatchArtifactImportError.unknownUpload
    }
    guard offset == session.contents.count else {
      throw WorkspacePatchArtifactImportError.offsetMismatch(
        expected: session.contents.count, actual: offset)
    }
    guard (1...Self.maximumChunkBytes).contains(chunk.count),
      chunk.count <= session.expectedByteCount - session.contents.count
    else {
      throw WorkspacePatchArtifactImportError.invalidChunk
    }
    session.contents.append(chunk)
    sessions[uploadID] = session
    return session.contents.count
  }

  func commit(uploadID: String, now: Date = Date()) throws -> Completed {
    let expired = pruneExpired(now: now)
    if expired.contains(uploadID) {
      throw WorkspacePatchArtifactImportError.expiredUpload
    }
    guard let session = sessions[uploadID] else {
      throw WorkspacePatchArtifactImportError.unknownUpload
    }
    guard session.contents.count == session.expectedByteCount else {
      throw WorkspacePatchArtifactImportError.incompleteUpload(
        expected: session.expectedByteCount, actual: session.contents.count)
    }
    let digest = SHA256Hex.string(of: session.contents)
    guard digest == session.expectedSHA256 else {
      sessions.removeValue(forKey: uploadID)
      throw WorkspacePatchArtifactImportError.digestMismatch
    }
    let touchedFiles: [String]
    do {
      touchedFiles = try WorkspaceProviderSupport.patchPaths(from: session.contents)
    } catch {
      sessions.removeValue(forKey: uploadID)
      throw WorkspacePatchArtifactImportError.invalidUnifiedDiff
    }
    sessions.removeValue(forKey: uploadID)
    return Completed(
      targetID: session.targetID,
      name: session.name,
      sha256: digest,
      contents: session.contents,
      touchedFiles: touchedFiles)
  }

  @discardableResult
  func abort(uploadID: String) -> Bool {
    sessions.removeValue(forKey: uploadID) != nil
  }

  private func pruneExpired(now: Date) -> Set<String> {
    let expired = Set(
      sessions.compactMap { uploadID, session in
        now.timeIntervalSince(session.createdAt) > Self.lifetimeSeconds ? uploadID : nil
      })
    for uploadID in expired {
      sessions.removeValue(forKey: uploadID)
    }
    return expired
  }

  private static func isSafePatchName(_ name: String) -> Bool {
    name.count <= 128
      && name.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.(patch|diff)$"#,
        options: .regularExpression) != nil
  }
}
