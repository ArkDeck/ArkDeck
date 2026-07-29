// Unified runtime artifact model (CHG-2026-049, T14).
//
// Every product of a runtime job - device facts, HiLog, UI dumps, traces,
// reports - lands here with the same identity, metadata and lifecycle.
// Two structural properties matter most:
//
//   * Names are derived from content, never from a caller. An artifact ID
//     is a digest, and the on-disk name is that ID, so path traversal and
//     symlink escape are not expressible through this API at all (they are
//     still pinned by negative tests).
//   * A missing product is a first-class recorded status, not an absence.
//     Callers read per-artifact status, so "the trace failed" can never be
//     laundered into overall success.

import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum RuntimeArtifactError: Error, Equatable, Sendable {
  case ioFailure(String)
  case indexCorrupted(String)
  case artifactNotFound(String)
  case quotaExceeded(requestedBytes: Int, remainingBytes: Int)
  case sensitiveAccessRequiresOptIn(String)
  case exportDestinationRejected(String)
  case evidenceVerificationFailed(String)
}

public enum ArtifactStatus: Sendable, Equatable, Codable {
  case published
  case missing(reason: String)
  case truncated(atBytes: Int)

  public var isPublished: Bool {
    if case .published = self { return true }
    return false
  }
}

public struct ArtifactBindingSnapshot: Sendable, Equatable, Codable {
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?

  public init(targetID: String, bindingRevision: Int?, stableIdentitySHA256: String?) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableIdentitySHA256 = stableIdentitySHA256
  }
}

public struct ArtifactRetention: Sendable, Equatable, Codable {
  public let retentionClass: CatalogArtifactRetentionClass
  public let deadlineUTC: String?
  public let pinned: Bool

  public init(
    retentionClass: CatalogArtifactRetentionClass, deadlineUTC: String?, pinned: Bool = false
  ) {
    self.retentionClass = retentionClass
    self.deadlineUTC = deadlineUTC
    self.pinned = pinned
  }
}

public struct RuntimeArtifactMetadata: Sendable, Equatable, Codable {
  public let artifactID: String
  public let jobID: String
  public let sessionID: String
  public let stepID: String
  public let name: String
  public let mediaType: String
  public let byteCount: Int
  public let sha256: String
  public let createdAtUTC: String
  public let providerID: String
  public let sourceOperation: String
  public let bindingSnapshot: ArtifactBindingSnapshot
  public let privacy: CatalogArtifactPrivacy
  public let retention: ArtifactRetention
  public let status: ArtifactStatus
  public let redactionApplied: Bool
}

public struct RuntimeVerifiedArtifactEvidence: Sendable, Equatable, Codable {
  public let reference: String
  public let sha256: String
  public let jobID: String
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let providerID: String
  public let byteCount: Int

  public init(
    reference: String,
    sha256: String,
    jobID: String,
    targetID: String,
    bindingRevision: Int?,
    stableIdentitySHA256: String?,
    providerID: String,
    byteCount: Int
  ) {
    self.reference = reference
    self.sha256 = sha256
    self.jobID = jobID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.providerID = providerID
    self.byteCount = byteCount
  }
}

private struct ArtifactIndexDocument: Codable, Equatable {
  static let currentSchemaVersion = "1.0.0"
  var schemaVersion: String
  var artifacts: [RuntimeArtifactMetadata]
}

/// Default redaction for text products. Deliberately conservative and
/// cheap: it removes the shapes that must never leave the host, and marks
/// that it ran so evidence can state it plainly.
public struct ArtifactRedactionPolicy: Sendable {
  public let homeDirectory: String

  public init(homeDirectory: String = NSHomeDirectory()) {
    self.homeDirectory = homeDirectory
  }

  private static let secretKeyPattern =
    "(?i)(token|secret|password|passwd|api[_-]?key|authorization)([\"'\\s:=]+)([^\\s\"',}]{6,})"

  public func redact(_ data: Data, mediaType: String) -> (data: Data, applied: Bool) {
    guard mediaType.hasPrefix("text/") || mediaType == "application/json",
      var text = String(data: data, encoding: .utf8)
    else {
      return (data, false)
    }
    let original = text
    if !homeDirectory.isEmpty {
      text = text.replacingOccurrences(of: homeDirectory, with: "<HOME>")
    }
    text = text.replacingOccurrences(
      of: Self.secretKeyPattern, with: "$1$2<REDACTED>", options: .regularExpression)
    let applied = text != original
    return (Data(text.utf8), applied)
  }
}

/// Storage quota. The rule is "refuse new work, never damage existing
/// artifacts": approaching the limit rejects a publication instead of
/// evicting something already recorded.
public struct ArtifactQuota: Sendable, Equatable {
  public let totalBytes: Int

  public init(totalBytes: Int = 8 * 1024 * 1024 * 1024) {
    self.totalBytes = totalBytes
  }
}

public struct RuntimeArtifactPublicationRequest: Sendable {
  public let jobID: String
  public let sessionID: String
  public let stepID: String
  public let name: String
  public let mediaType: String
  public let privacy: CatalogArtifactPrivacy
  public let retentionClass: CatalogArtifactRetentionClass
  public let sourceOperation: String
  public let providerID: String
  public let bindingSnapshot: ArtifactBindingSnapshot
  public let contents: Data

  public init(
    jobID: String, sessionID: String, stepID: String, name: String, mediaType: String,
    privacy: CatalogArtifactPrivacy, retentionClass: CatalogArtifactRetentionClass,
    sourceOperation: String, providerID: String, bindingSnapshot: ArtifactBindingSnapshot,
    contents: Data
  ) {
    self.jobID = jobID
    self.sessionID = sessionID
    self.stepID = stepID
    self.name = name
    self.mediaType = mediaType
    self.privacy = privacy
    self.retentionClass = retentionClass
    self.sourceOperation = sourceOperation
    self.providerID = providerID
    self.bindingSnapshot = bindingSnapshot
    self.contents = contents
  }
}

/// Remote cleanup that failed is debt, never silence: it is recorded so a
/// later reconcile can settle it.
public struct CleanupDebtRecord: Sendable, Equatable, Codable {
  public let jobID: String
  public let stepID: String
  public let remotePath: String
  public let reason: String
  public let recordedAtUTC: String
  public var settledAtUTC: String?
}

public actor RuntimeArtifactStore {
  private let rootURL: URL
  private let quota: ArtifactQuota
  private let redaction: ArtifactRedactionPolicy
  private let nowUTC: @Sendable () -> String

  public init(
    rootURL: URL,
    quota: ArtifactQuota = ArtifactQuota(),
    redaction: ArtifactRedactionPolicy = ArtifactRedactionPolicy(),
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.rootURL = rootURL
    self.quota = quota
    self.redaction = redaction
    self.nowUTC = nowUTC
    do {
      try FileManager.default.createDirectory(
        at: rootURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw RuntimeArtifactError.ioFailure("cannot create artifact root: \(error)")
    }
  }

  // MARK: - Publication

  public func publish(_ request: RuntimeArtifactPublicationRequest) throws -> RuntimeArtifactMetadata {
    let (payload, redacted) = redaction.redact(request.contents, mediaType: request.mediaType)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let artifactID = "ART-\(digest.prefix(16))"

    let used = try totalBytesUsed()
    guard used + payload.count <= quota.totalBytes else {
      // Refuse the new product; never evict an existing one to make room.
      throw RuntimeArtifactError.quotaExceeded(
        requestedBytes: payload.count, remainingBytes: max(0, quota.totalBytes - used))
    }

    let jobDirectory = try directory(for: request.jobID)
    // The on-disk name is the derived ID, so no caller-supplied string ever
    // reaches the filesystem path.
    let destination = jobDirectory.appendingPathComponent(artifactID)
    if !FileManager.default.fileExists(atPath: destination.path) {
      try atomicWrite(payload, to: destination, directory: jobDirectory)
    }

    let metadata = RuntimeArtifactMetadata(
      artifactID: artifactID,
      jobID: request.jobID,
      sessionID: request.sessionID,
      stepID: request.stepID,
      name: request.name,
      mediaType: request.mediaType,
      byteCount: payload.count,
      sha256: digest,
      createdAtUTC: nowUTC(),
      providerID: request.providerID,
      sourceOperation: request.sourceOperation,
      bindingSnapshot: request.bindingSnapshot,
      privacy: request.privacy,
      retention: ArtifactRetention(
        retentionClass: request.retentionClass, deadlineUTC: nil,
        pinned: request.retentionClass == .pinnedUntilVerified),
      status: .published,
      redactionApplied: redacted)
    try upsert(metadata, jobID: request.jobID)
    return metadata
  }

  /// Records a declared-but-absent product. This is how a partial capture
  /// stays honest: the artifact exists in the index with a reason.
  public func recordMissing(
    jobID: String, sessionID: String, stepID: String, name: String, mediaType: String,
    privacy: CatalogArtifactPrivacy, retentionClass: CatalogArtifactRetentionClass,
    sourceOperation: String, providerID: String, bindingSnapshot: ArtifactBindingSnapshot,
    reason: String
  ) throws -> RuntimeArtifactMetadata {
    let metadata = RuntimeArtifactMetadata(
      artifactID: "ART-MISSING-\(name)",
      jobID: jobID, sessionID: sessionID, stepID: stepID, name: name, mediaType: mediaType,
      byteCount: 0, sha256: "", createdAtUTC: nowUTC(), providerID: providerID,
      sourceOperation: sourceOperation, bindingSnapshot: bindingSnapshot, privacy: privacy,
      retention: ArtifactRetention(retentionClass: retentionClass, deadlineUTC: nil),
      status: .missing(reason: reason), redactionApplied: false)
    try upsert(metadata, jobID: jobID)
    return metadata
  }

  // MARK: - Access (ID only)

  public func list(jobID: String) throws -> [RuntimeArtifactMetadata] {
    try loadIndex(jobID: jobID).artifacts
  }

  public func inspect(jobID: String, artifactID: String) throws -> RuntimeArtifactMetadata {
    guard let match = try loadIndex(jobID: jobID).artifacts.first(where: {
      $0.artifactID == artifactID
    }) else {
      throw RuntimeArtifactError.artifactNotFound(artifactID)
    }
    return match
  }

  /// Re-hashes the immutable bytes immediately before evidence projection.
  /// Metadata alone is not sufficient: missing, truncated, moved or
  /// changed bytes fail the whole evidence query closed.
  public func verifiedEvidenceArtifacts(
    jobID: String
  ) throws -> [RuntimeVerifiedArtifactEvidence] {
    let artifacts = try loadIndex(jobID: jobID).artifacts
    guard !artifacts.isEmpty else {
      throw RuntimeArtifactError.evidenceVerificationFailed(
        "job \(jobID) has no published artifact metadata")
    }
    return try artifacts.map { metadata in
      guard metadata.status.isPublished else {
        throw RuntimeArtifactError.evidenceVerificationFailed(
          "artifact \(metadata.artifactID) is not published")
      }
      let url = try directory(for: jobID).appendingPathComponent(metadata.artifactID)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw RuntimeArtifactError.evidenceVerificationFailed(
          "artifact \(metadata.artifactID) bytes are missing")
      }
      let bytes: Data
      do {
        bytes = try Data(contentsOf: url)
      } catch {
        throw RuntimeArtifactError.evidenceVerificationFailed(
          "artifact \(metadata.artifactID) bytes cannot be read")
      }
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      guard digest == metadata.sha256, bytes.count == metadata.byteCount else {
        throw RuntimeArtifactError.evidenceVerificationFailed(
          "artifact \(metadata.artifactID) bytes/hash metadata mismatch")
      }
      return RuntimeVerifiedArtifactEvidence(
        reference: "arkdeck-artifact://\(jobID)/\(metadata.artifactID)",
        sha256: digest,
        jobID: metadata.jobID,
        targetID: metadata.bindingSnapshot.targetID,
        bindingRevision: metadata.bindingSnapshot.bindingRevision,
        stableIdentitySHA256: metadata.bindingSnapshot.stableIdentitySHA256,
        providerID: metadata.providerID,
        byteCount: bytes.count)
    }
  }

  public func read(
    jobID: String, artifactID: String, maximumBytes: Int = 1 << 20, allowSensitive: Bool = false
  ) throws -> Data {
    let metadata = try inspect(jobID: jobID, artifactID: artifactID)
    guard metadata.status.isPublished else {
      throw RuntimeArtifactError.artifactNotFound(
        "\(artifactID) is recorded as \(metadata.status)")
    }
    guard metadata.privacy != .sensitive || allowSensitive else {
      throw RuntimeArtifactError.sensitiveAccessRequiresOptIn(artifactID)
    }
    let url = try directory(for: jobID).appendingPathComponent(metadata.artifactID)
    guard let handle = FileHandle(forReadingAtPath: url.path) else {
      throw RuntimeArtifactError.ioFailure("artifact bytes are missing for \(artifactID)")
    }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: maximumBytes)) ?? Data()
  }

  public func export(
    jobID: String, artifactID: String, destinationDirectory: URL, allowSensitive: Bool = false
  ) throws -> URL {
    let metadata = try inspect(jobID: jobID, artifactID: artifactID)
    guard metadata.status.isPublished else {
      throw RuntimeArtifactError.artifactNotFound("\(artifactID) has no bytes to export")
    }
    guard metadata.privacy != .sensitive || allowSensitive else {
      throw RuntimeArtifactError.sensitiveAccessRequiresOptIn(artifactID)
    }
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: destinationDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw RuntimeArtifactError.exportDestinationRejected("destination must be a directory")
    }
    // The exported file name comes from the recorded artifact name, with
    // any path separator stripped: a hostile catalog entry still cannot
    // escape the destination directory.
    let safeName = metadata.name.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "..", with: "_")
    let destination = destinationDirectory.appendingPathComponent("\(artifactID)-\(safeName)")
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw RuntimeArtifactError.exportDestinationRejected(
        "refusing to overwrite \(destination.lastPathComponent)")
    }
    let source = try directory(for: jobID).appendingPathComponent(metadata.artifactID)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  // MARK: - Lifecycle

  public func totalBytesUsed() throws -> Int {
    let jobsRoot = rootURL
    let entries =
      (try? FileManager.default.contentsOfDirectory(at: jobsRoot, includingPropertiesForKeys: nil))
      ?? []
    var total = 0
    for entry in entries where entry.hasDirectoryPath {
      let index = try? loadIndex(jobID: entry.lastPathComponent)
      total += (index?.artifacts ?? []).filter { $0.status.isPublished }.reduce(0) {
        $0 + $1.byteCount
      }
    }
    return total
  }

  /// Collects artifacts whose retention has lapsed. Active jobs and pinned
  /// artifacts are skipped - GC never removes something still referenced.
  public func collectGarbage(
    activeJobIDs: Set<String>, nowUTC currentUTC: String
  ) throws -> [String] {
    var removed: [String] = []
    let entries =
      (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil))
      ?? []
    for entry in entries where entry.hasDirectoryPath {
      let jobID = entry.lastPathComponent
      if activeJobIDs.contains(jobID) { continue }
      var index = try loadIndex(jobID: jobID)
      var kept: [RuntimeArtifactMetadata] = []
      for metadata in index.artifacts {
        let expired =
          metadata.retention.deadlineUTC.map { $0 <= currentUTC } ?? false
        if expired && !metadata.retention.pinned && metadata.status.isPublished {
          try? FileManager.default.removeItem(
            at: entry.appendingPathComponent(metadata.artifactID))
          removed.append(metadata.artifactID)
        } else {
          kept.append(metadata)
        }
      }
      if kept.count != index.artifacts.count {
        index.artifacts = kept
        try persistIndex(index, jobID: jobID)
      }
    }
    return removed
  }

  public func recordCleanupDebt(
    jobID: String, stepID: String, remotePath: String, reason: String
  ) throws {
    var debts = try loadCleanupDebt()
    debts.append(
      CleanupDebtRecord(
        jobID: jobID, stepID: stepID, remotePath: remotePath, reason: reason,
        recordedAtUTC: nowUTC(), settledAtUTC: nil))
    try persistCleanupDebt(debts)
  }

  public func outstandingCleanupDebt() throws -> [CleanupDebtRecord] {
    try loadCleanupDebt().filter { $0.settledAtUTC == nil }
  }

  public func settleCleanupDebt(jobID: String, remotePath: String) throws {
    var debts = try loadCleanupDebt()
    for index in debts.indices
    where debts[index].jobID == jobID && debts[index].remotePath == remotePath
      && debts[index].settledAtUTC == nil
    {
      debts[index].settledAtUTC = nowUTC()
    }
    try persistCleanupDebt(debts)
  }

  // MARK: - Internals

  private func directory(for jobID: String) throws -> URL {
    // jobID comes from the engine (a UUID-derived identifier), never from
    // a client; still validated so a malformed one cannot walk the tree.
    guard !jobID.isEmpty, jobID.count <= 128,
      jobID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else {
      throw RuntimeArtifactError.ioFailure("malformed job identifier")
    }
    let url = rootURL.appendingPathComponent(jobID, isDirectory: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      do {
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw RuntimeArtifactError.ioFailure("cannot create artifact directory: \(error)")
      }
    }
    return url
  }

  private func indexURL(for jobID: String) throws -> URL {
    try directory(for: jobID).appendingPathComponent("index.json")
  }

  private func loadIndex(jobID: String) throws -> ArtifactIndexDocument {
    let url = try indexURL(for: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ArtifactIndexDocument(
        schemaVersion: ArtifactIndexDocument.currentSchemaVersion, artifacts: [])
    }
    do {
      let document = try JSONDecoder().decode(
        ArtifactIndexDocument.self, from: Data(contentsOf: url))
      guard document.schemaVersion == ArtifactIndexDocument.currentSchemaVersion else {
        throw RuntimeArtifactError.indexCorrupted(
          "unsupported index schema \(document.schemaVersion)")
      }
      return document
    } catch let error as RuntimeArtifactError {
      throw error
    } catch {
      throw RuntimeArtifactError.indexCorrupted("undecodable artifact index: \(error)")
    }
  }

  private func upsert(_ metadata: RuntimeArtifactMetadata, jobID: String) throws {
    var index = try loadIndex(jobID: jobID)
    index.artifacts.removeAll { $0.artifactID == metadata.artifactID }
    index.artifacts.append(metadata)
    try persistIndex(index, jobID: jobID)
  }

  private func persistIndex(_ index: ArtifactIndexDocument, jobID: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data: Data
    do {
      data = try encoder.encode(index)
    } catch {
      throw RuntimeArtifactError.ioFailure("cannot encode artifact index: \(error)")
    }
    let directoryURL = try directory(for: jobID)
    try atomicWrite(data, to: try indexURL(for: jobID), directory: directoryURL)
  }

  private func cleanupDebtURL() -> URL {
    rootURL.appendingPathComponent("cleanup-debt.json")
  }

  private func loadCleanupDebt() throws -> [CleanupDebtRecord] {
    let url = cleanupDebtURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      return try JSONDecoder().decode([CleanupDebtRecord].self, from: Data(contentsOf: url))
    } catch {
      throw RuntimeArtifactError.indexCorrupted("undecodable cleanup debt ledger: \(error)")
    }
  }

  private func persistCleanupDebt(_ debts: [CleanupDebtRecord]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = (try? encoder.encode(debts)) ?? Data("[]".utf8)
    try atomicWrite(data, to: cleanupDebtURL(), directory: rootURL)
  }

  private func atomicWrite(_ data: Data, to destination: URL, directory: URL) throws {
    let temporary = directory.appendingPathComponent(
      ".tmp-\(UUID().uuidString.prefix(8).lowercased())")
    do {
      try data.write(to: temporary, options: [])
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.synchronize()
      try handle.close()
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw RuntimeArtifactError.ioFailure("cannot persist artifact bytes: \(error)")
    }
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if directoryFD >= 0 {
      _ = fsync(directoryFD)
      close(directoryFD)
    }
  }
}
