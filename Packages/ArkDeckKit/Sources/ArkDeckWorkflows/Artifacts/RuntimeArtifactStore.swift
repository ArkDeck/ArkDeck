// Unified runtime artifact model (CHG-2026-049, T14).
//
// Every product of a runtime job - device facts, HiLog, UI dumps, traces,
// reports - lands here with the same identity, metadata and lifecycle.
// Two structural properties matter most:
//
//   * Artifact IDs bind the job, declared product name and content digest.
//     The on-disk name is that ID, so caller-provided names never become
//     paths and one declared product cannot overwrite another.
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
  case artifactConflict(String)
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

public struct ArtifactRetentionPolicy: Sendable, Equatable {
  public let defaultLifetimeSeconds: TimeInterval
  public let shortLivedLifetimeSeconds: TimeInterval

  public init(
    defaultLifetimeSeconds: TimeInterval = 7 * 24 * 60 * 60,
    shortLivedLifetimeSeconds: TimeInterval = 24 * 60 * 60
  ) {
    self.defaultLifetimeSeconds = defaultLifetimeSeconds
    self.shortLivedLifetimeSeconds = shortLivedLifetimeSeconds
  }

  func retention(
    for retentionClass: CatalogArtifactRetentionClass,
    createdAtUTC: String
  ) throws -> ArtifactRetention {
    if retentionClass == .pinnedUntilVerified {
      return ArtifactRetention(
        retentionClass: retentionClass, deadlineUTC: nil, pinned: true)
    }
    let created = ISO8601Timestamps.parse(createdAtUTC)
    guard let created else {
      throw RuntimeArtifactError.ioFailure(
        "cannot derive retention from invalid UTC timestamp \(createdAtUTC)")
    }
    let lifetime =
      retentionClass == .shortLived
      ? shortLivedLifetimeSeconds : defaultLifetimeSeconds
    guard lifetime > 0 else {
      throw RuntimeArtifactError.ioFailure("artifact retention lifetime must be positive")
    }
    let deadlineFormatter = ISO8601DateFormatter()
    deadlineFormatter.formatOptions = [.withInternetDateTime]
    return ArtifactRetention(
      retentionClass: retentionClass,
      deadlineUTC: deadlineFormatter.string(from: created.addingTimeInterval(lifetime)),
      pinned: false)
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

/// File-backed publication for inputs that are intentionally much larger
/// than an in-memory diagnostic product (for example a 733 MB flash
/// bundle). The caller supplies only a local staging file plus its already
/// declared immutable facts; the store re-opens it without following
/// symlinks, hashes it through the descriptor, and copies it into the
/// product-owned Artifact root.
public struct RuntimeArtifactFilePublicationRequest: Sendable {
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
  public let sourceFileURL: URL
  public let expectedByteCount: Int
  public let expectedSHA256: String

  public init(
    jobID: String, sessionID: String, stepID: String, name: String, mediaType: String,
    privacy: CatalogArtifactPrivacy, retentionClass: CatalogArtifactRetentionClass,
    sourceOperation: String, providerID: String, bindingSnapshot: ArtifactBindingSnapshot,
    sourceFileURL: URL, expectedByteCount: Int, expectedSHA256: String
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
    self.sourceFileURL = sourceFileURL
    self.expectedByteCount = expectedByteCount
    self.expectedSHA256 = expectedSHA256
  }
}

/// File-backed publication for text and JSON products.  Unlike
/// `RuntimeArtifactFilePublicationRequest`, this path deliberately accepts
/// sensitive text: it redacts and hashes the source while streaming it to a
/// private staging file, then atomically publishes only the redacted bytes.
/// No expected digest is accepted because the immutable artifact identity is
/// derived from the post-redaction stream rather than the untrusted source.
public struct RuntimeArtifactTextFilePublicationRequest: Sendable {
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
  public let sourceFileURL: URL

  public init(
    jobID: String, sessionID: String, stepID: String, name: String, mediaType: String,
    privacy: CatalogArtifactPrivacy, retentionClass: CatalogArtifactRetentionClass,
    sourceOperation: String, providerID: String, bindingSnapshot: ArtifactBindingSnapshot,
    sourceFileURL: URL
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
    self.sourceFileURL = sourceFileURL
  }
}

public struct RuntimeArtifactLeaseResolution: Sendable, Equatable {
  public let artifactID: String
  public let fileURL: URL
  public let sha256: String
  public let byteCount: Int
  public let bindingSnapshot: ArtifactBindingSnapshot

  public init(
    artifactID: String,
    fileURL: URL,
    sha256: String,
    byteCount: Int,
    bindingSnapshot: ArtifactBindingSnapshot
  ) {
    self.artifactID = artifactID
    self.fileURL = fileURL
    self.sha256 = sha256
    self.byteCount = byteCount
    self.bindingSnapshot = bindingSnapshot
  }
}

/// Remote cleanup that failed is debt, never silence: it is recorded so a
/// later reconcile can settle it.
/// What a job left on the device and could not undo. The remote-path case
/// is the original; the bundle case is the same fact for an uninstall that
/// ran without taking effect (CHG-2026-049 r3). Both are recorded, queried
/// and settled through one ledger — the asymmetry between them was the
/// whole of D12.
public enum CleanupResidue: Sendable, Equatable {
  case remotePath(String)
  case installedBundle(String)

  /// Ledger key. The path case keeps the bare path so records written
  /// before r3 keep their identity; the bundle case is prefixed so a
  /// bundle can never collide with a path.
  public var identity: String {
    switch self {
    case .remotePath(let path): return path
    case .installedBundle(let bundle): return "bundle:\(bundle)"
    }
  }

  public var description: String {
    switch self {
    case .remotePath(let path): return "remote path \(path)"
    case .installedBundle(let bundle): return "installed bundle \(bundle)"
    }
  }
}

public struct CleanupDebtRecord: Sendable, Equatable, Codable {
  public let jobID: String
  public let stepID: String
  /// The path case's identity. Empty when the residue is not a path —
  /// kept under this name so records written before r3 decode unchanged.
  public let remotePath: String
  /// Set only for a bundle residue. Absent in every pre-r3 record, which
  /// is what makes those records decode as the path case.
  public var bundleName: String?
  public let reason: String
  public let recordedAtUTC: String
  public var settledAtUTC: String?
  public var retryAttemptStartedAtUTC: String?
  public var retryOutcomeUnknown: Bool?
  var persistedAction: PersistedTypedProviderAction?

  public var residue: CleanupResidue {
    if let bundleName { return .installedBundle(bundleName) }
    return .remotePath(remotePath)
  }

  public var identity: String { residue.identity }
}

public actor RuntimeArtifactStore {
  private static let maximumReadBytes = 4 * 1024 * 1024

  private let rootURL: URL
  private let quota: ArtifactQuota
  private let redaction: ArtifactRedactionPolicy
  private let retentionPolicy: ArtifactRetentionPolicy
  private let nowUTC: @Sendable () -> String
  /// Quota usage is derived from durable indexes on first use, then updated
  /// only after an index mutation commits. A long-lived headless host can
  /// retain thousands of immutable jobs; rescanning every historical index
  /// for each small final Artifact made one diagnostics finalization take
  /// almost a minute. The cache is process-local (so restart always rebuilds
  /// from durable truth) and GC invalidates it before changing indexes.
  private var cachedIndexedBytes: Int?

  public init(
    rootURL: URL,
    quota: ArtifactQuota = ArtifactQuota(),
    redaction: ArtifactRedactionPolicy = ArtifactRedactionPolicy(),
    retentionPolicy: ArtifactRetentionPolicy = ArtifactRetentionPolicy(),
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.rootURL = rootURL
    self.quota = quota
    self.redaction = redaction
    self.retentionPolicy = retentionPolicy
    self.nowUTC = nowUTC
    self.cachedIndexedBytes = nil
    do {
      try FileManager.default.createDirectory(
        at: rootURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try Self.requireDirectoryWithoutSymlink(rootURL, label: "artifact root")
    } catch {
      throw RuntimeArtifactError.ioFailure("cannot create artifact root: \(error)")
    }
  }

  // MARK: - Publication

  public func publish(_ request: RuntimeArtifactPublicationRequest) throws -> RuntimeArtifactMetadata {
    let (payload, redacted) = redaction.redact(request.contents, mediaType: request.mediaType)
    let digest = SHA256Hex.string(of: payload)
    let identityInput = Data("\(request.jobID)\u{0}\(request.name)\u{0}\(digest)".utf8)
    let identity =
      SHA256Hex.string(of: identityInput)
    let artifactID = "ART-\(identity.prefix(32))"
    let createdAtUTC = nowUTC()
    let retention = try retentionPolicy.retention(
      for: request.retentionClass, createdAtUTC: createdAtUTC)
    let metadata = RuntimeArtifactMetadata(
      artifactID: artifactID,
      jobID: request.jobID,
      sessionID: request.sessionID,
      stepID: request.stepID,
      name: request.name,
      mediaType: request.mediaType,
      byteCount: payload.count,
      sha256: digest,
      createdAtUTC: createdAtUTC,
      providerID: request.providerID,
      sourceOperation: request.sourceOperation,
      bindingSnapshot: request.bindingSnapshot,
      privacy: request.privacy,
      retention: retention,
      status: .published,
      redactionApplied: redacted)

    let jobDirectory = try directory(for: request.jobID)
    let existing = try loadIndex(jobID: request.jobID).artifacts.first {
      $0.name == request.name
    }
    if let existing, existing.status.isPublished {
      guard
        existing.artifactID == artifactID,
        Self.sameImmutablePublication(existing, metadata)
      else {
        throw RuntimeArtifactError.artifactConflict(
          "artifact name \(request.name) is already bound to immutable metadata or bytes")
      }
      _ = try storedFileURL(for: existing)
      return existing
    }

    let destination = jobDirectory.appendingPathComponent(artifactID)
    let destinationExists = FileManager.default.fileExists(atPath: destination.path)
    if destinationExists {
      // Recover only an exact payload left between the durable data write
      // and index write. A pre-existing symlink or drifted file is poison.
      _ = try validateStoredPayload(metadata, at: destination)
    }
    let additionalBytes = destinationExists ? 0 : payload.count
    let used = try totalBytesUsed()
    guard used + additionalBytes <= quota.totalBytes else {
      // Refuse the new product; never evict an existing one to make room.
      throw RuntimeArtifactError.quotaExceeded(
        requestedBytes: additionalBytes, remainingBytes: max(0, quota.totalBytes - used))
    }

    // The on-disk name is the derived ID, so no caller-supplied string ever
    // reaches the filesystem path.
    if !destinationExists {
      try atomicWrite(payload, to: destination, directory: jobDirectory)
    }
    try upsert(metadata, jobID: request.jobID)
    cachedIndexedBytes = used + metadata.byteCount
    return metadata
  }

  /// Publishes a large binary without ever materializing the whole file as
  /// `Data`. Source identity is checked before and after both the hash pass
  /// and descriptor-to-descriptor copy. The destination is made visible
  /// only after its bytes are synchronized and its digest is confirmed.
  public func publishFile(
    _ request: RuntimeArtifactFilePublicationRequest
  ) throws -> RuntimeArtifactMetadata {
    guard request.sourceFileURL.isFileURL,
      request.sourceFileURL.path.hasPrefix("/"),
      request.expectedByteCount > 0,
      request.expectedSHA256.range(
        of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
      !request.mediaType.hasPrefix("text/"),
      request.mediaType != "application/json"
    else {
      throw RuntimeArtifactError.ioFailure(
        "file-backed publication requires an absolute binary file with exact size and SHA-256")
    }
    let sourceFD = Darwin.open(
      request.sourceFileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard sourceFD >= 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot open file-backed Artifact source (errno \(errno))")
    }
    defer { Darwin.close(sourceFD) }
    var sourceBefore = stat()
    guard fstat(sourceFD, &sourceBefore) == 0,
      sourceBefore.st_mode & S_IFMT == S_IFREG,
      sourceBefore.st_size == Int64(request.expectedByteCount)
    else {
      throw RuntimeArtifactError.ioFailure(
        "file-backed Artifact source is not the declared regular file")
    }
    let digest = request.expectedSHA256

    let identityInput = Data(
      "\(request.jobID)\u{0}\(request.name)\u{0}\(digest)".utf8)
    let identity =
      SHA256Hex.string(of: identityInput)
    let artifactID = "ART-\(identity.prefix(32))"
    let createdAtUTC = nowUTC()
    let retention = try retentionPolicy.retention(
      for: request.retentionClass, createdAtUTC: createdAtUTC)
    let metadata = RuntimeArtifactMetadata(
      artifactID: artifactID,
      jobID: request.jobID,
      sessionID: request.sessionID,
      stepID: request.stepID,
      name: request.name,
      mediaType: request.mediaType,
      byteCount: request.expectedByteCount,
      sha256: digest,
      createdAtUTC: createdAtUTC,
      providerID: request.providerID,
      sourceOperation: request.sourceOperation,
      bindingSnapshot: request.bindingSnapshot,
      privacy: request.privacy,
      retention: retention,
      status: .published,
      redactionApplied: false)

    let jobDirectory = try directory(for: request.jobID)
    if let existing = try loadIndex(jobID: request.jobID).artifacts.first(where: {
      $0.name == request.name
    }), existing.status.isPublished {
      guard
        existing.artifactID == artifactID,
        Self.sameImmutablePublication(existing, metadata)
      else {
        throw RuntimeArtifactError.artifactConflict(
          "artifact name \(request.name) is already bound to immutable metadata or bytes")
      }
      _ = try storedFileURL(for: existing)
      return existing
    }

    let destination = jobDirectory.appendingPathComponent(artifactID)
    let used = try totalBytesUsed()
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try validateStoredPayload(metadata, at: destination)
    } else {
      guard used + request.expectedByteCount <= quota.totalBytes else {
        throw RuntimeArtifactError.quotaExceeded(
          requestedBytes: request.expectedByteCount,
          remainingBytes: max(0, quota.totalBytes - used))
      }
      try copyFileDescriptor(
        sourceFD, sourceBefore: sourceBefore, expectedSHA256: digest,
        expectedByteCount: request.expectedByteCount,
        destination: destination, directory: jobDirectory)
    }
    try upsert(metadata, jobID: request.jobID)
    cachedIndexedBytes = used + metadata.byteCount
    return metadata
  }

  /// Streams a text or JSON source through the Runtime redaction policy.
  /// The source is never materialized as one `Data` value: each bounded
  /// chunk is transformed, hashed and written directly to a private staging
  /// inode.  The artifact ID is bound to those redacted bytes only.
  public func publishTextFile(
    _ request: RuntimeArtifactTextFilePublicationRequest
  ) throws -> RuntimeArtifactMetadata {
    guard request.sourceFileURL.isFileURL,
      request.sourceFileURL.path.hasPrefix("/"),
      (request.mediaType.hasPrefix("text/") || request.mediaType == "application/json")
    else {
      throw RuntimeArtifactError.ioFailure(
        "text file publication requires an absolute text or JSON source")
    }
    let sourceFD = Darwin.open(
      request.sourceFileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard sourceFD >= 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot open text Artifact source (errno \(errno))")
    }
    defer { Darwin.close(sourceFD) }
    var sourceBefore = stat()
    guard fstat(sourceFD, &sourceBefore) == 0,
      sourceBefore.st_mode & S_IFMT == S_IFREG
    else {
      throw RuntimeArtifactError.ioFailure("text Artifact source is not a regular file")
    }

    let jobDirectory = try directory(for: request.jobID)
    let temporary = jobDirectory.appendingPathComponent(
      ".tmp-redacted-\(UUID().uuidString.prefix(12).lowercased())")
    let temporaryFD = Darwin.open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard temporaryFD >= 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot create text Artifact staging file (errno \(errno))")
    }
    var temporaryIsOpen = true
    var temporaryPublished = false
    defer {
      if temporaryIsOpen { Darwin.close(temporaryFD) }
      if !temporaryPublished { _ = Darwin.unlink(temporary.path) }
    }

    let streamed = try streamRedactedText(
      sourceFD: sourceFD, sourceBefore: sourceBefore, destinationFD: temporaryFD,
      sourcePath: request.sourceFileURL.path)
    guard Darwin.fsync(temporaryFD) == 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot synchronize redacted Artifact staging file (errno \(errno))")
    }
    guard Darwin.close(temporaryFD) == 0 else {
      temporaryIsOpen = false
      throw RuntimeArtifactError.ioFailure(
        "cannot close redacted Artifact staging file (errno \(errno))")
    }
    temporaryIsOpen = false

    let identityInput = Data(
      "\(request.jobID)\u{0}\(request.name)\u{0}\(streamed.sha256)".utf8)
    let identity = SHA256Hex.string(of: identityInput)
    let createdAtUTC = nowUTC()
    let metadata = RuntimeArtifactMetadata(
      artifactID: "ART-\(identity.prefix(32))",
      jobID: request.jobID,
      sessionID: request.sessionID,
      stepID: request.stepID,
      name: request.name,
      mediaType: request.mediaType,
      byteCount: streamed.byteCount,
      sha256: streamed.sha256,
      createdAtUTC: createdAtUTC,
      providerID: request.providerID,
      sourceOperation: request.sourceOperation,
      bindingSnapshot: request.bindingSnapshot,
      privacy: request.privacy,
      retention: try retentionPolicy.retention(
        for: request.retentionClass, createdAtUTC: createdAtUTC),
      status: .published,
      redactionApplied: streamed.redactionApplied)

    if let existing = try loadIndex(jobID: request.jobID).artifacts.first(where: {
      $0.name == request.name
    }), existing.status.isPublished {
      guard
        existing.artifactID == metadata.artifactID,
        Self.sameImmutablePublication(existing, metadata)
      else {
        throw RuntimeArtifactError.artifactConflict(
          "artifact name \(request.name) is already bound to immutable metadata or bytes")
      }
      _ = try storedFileURL(for: existing)
      return existing
    }

    let destination = jobDirectory.appendingPathComponent(metadata.artifactID)
    let used = try totalBytesUsed()
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try validateStoredPayload(metadata, at: destination)
    } else {
      guard used + streamed.byteCount <= quota.totalBytes else {
        throw RuntimeArtifactError.quotaExceeded(
          requestedBytes: streamed.byteCount, remainingBytes: max(0, quota.totalBytes - used))
      }
      guard Darwin.link(temporary.path, destination.path) == 0 else {
        throw RuntimeArtifactError.ioFailure(
          "cannot publish redacted Artifact without overwrite (errno \(errno))")
      }
      guard Darwin.unlink(temporary.path) == 0 else {
        throw RuntimeArtifactError.ioFailure(
          "cannot remove redacted Artifact staging link (errno \(errno))")
      }
      temporaryPublished = true
      let directoryFD = Darwin.open(
        jobDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      if directoryFD >= 0 {
        _ = Darwin.fsync(directoryFD)
        Darwin.close(directoryFD)
      }
    }
    try upsert(metadata, jobID: request.jobID)
    cachedIndexedBytes = used + metadata.byteCount
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
    let missingIdentity =
      SHA256Hex.string(of: Data("\(jobID)\u{0}\(name)\u{0}missing".utf8))
    let createdAtUTC = nowUTC()
    let retention = try retentionPolicy.retention(
      for: retentionClass, createdAtUTC: createdAtUTC)
    let metadata = RuntimeArtifactMetadata(
      artifactID: "ART-MISSING-\(missingIdentity.prefix(32))",
      jobID: jobID, sessionID: sessionID, stepID: stepID, name: name, mediaType: mediaType,
      byteCount: 0, sha256: "", createdAtUTC: createdAtUTC, providerID: providerID,
      sourceOperation: sourceOperation, bindingSnapshot: bindingSnapshot, privacy: privacy,
      retention: retention,
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
  /// Metadata alone is not sufficient: selected artifacts that are
  /// missing, truncated, moved or changed fail the whole evidence query
  /// closed. An optional product omitted by the persisted materialized
  /// request remains visible in the Artifact index but is not itself an
  /// evidence-bearing artifact.
  public func verifiedEvidenceArtifacts(
    jobID: String,
    intentionallyOmittedNames: Set<String> = []
  ) throws -> [RuntimeVerifiedArtifactEvidence] {
    let artifacts = try loadIndex(jobID: jobID).artifacts
    guard !artifacts.isEmpty else {
      throw RuntimeArtifactError.evidenceVerificationFailed(
        "job \(jobID) has no published artifact metadata")
    }
    let verified = try artifacts.compactMap { metadata -> RuntimeVerifiedArtifactEvidence? in
      switch metadata.status {
      case .published:
        break
      case .missing where intentionallyOmittedNames.contains(metadata.name):
        return nil
      case .missing, .truncated:
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
      let digest = SHA256Hex.string(of: bytes)
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
    guard !verified.isEmpty else {
      throw RuntimeArtifactError.evidenceVerificationFailed(
        "job \(jobID) has no published evidence artifacts")
    }
    return verified
  }

  public func read(
    jobID: String, artifactID: String, offset: Int = 0,
    maximumBytes: Int = 1 << 20, allowSensitive: Bool = false
  ) throws -> Data {
    guard (1...Self.maximumReadBytes).contains(maximumBytes) else {
      throw RuntimeArtifactError.ioFailure(
        "artifact read bound must be 1...\(Self.maximumReadBytes) bytes")
    }
    let metadata = try inspect(jobID: jobID, artifactID: artifactID)
    guard offset >= 0, offset <= metadata.byteCount else {
      throw RuntimeArtifactError.ioFailure(
        "artifact read offset must be within 0...\(metadata.byteCount)")
    }
    guard metadata.status.isPublished else {
      throw RuntimeArtifactError.artifactNotFound(
        "\(artifactID) is recorded as \(metadata.status)")
    }
    guard metadata.privacy != .sensitive || allowSensitive else {
      throw RuntimeArtifactError.sensitiveAccessRequiresOptIn(artifactID)
    }
    let url = try storedFileURL(for: metadata)
    guard let handle = FileHandle(forReadingAtPath: url.path) else {
      throw RuntimeArtifactError.ioFailure("artifact bytes are missing for \(artifactID)")
    }
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
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
    do {
      try Self.requireDirectoryWithoutSymlink(
        destinationDirectory, label: "export destination")
    } catch {
      throw RuntimeArtifactError.exportDestinationRejected(
        "destination must not be a symlink: \(error)")
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
    let source = try storedFileURL(for: metadata)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  /// Produces and resolves an ID-only Artifact lease. The reference carries
  /// no host path, and resolution revalidates index metadata plus the
  /// symlink-free immutable payload before returning a provider-only URL.
  public func leaseReference(jobID: String, artifactID: String) throws -> String {
    let metadata = try inspect(jobID: jobID, artifactID: artifactID)
    guard metadata.status.isPublished else {
      throw RuntimeArtifactError.artifactNotFound("\(artifactID) has no leaseable bytes")
    }
    _ = try storedFileURL(for: metadata)
    return "lease-v1:\(jobID):\(artifactID)"
  }

  public func resolveLease(_ reference: String) throws -> RuntimeArtifactLeaseResolution {
    let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "lease-v1" else {
      throw RuntimeArtifactError.artifactNotFound("malformed Artifact lease")
    }
    let jobID = String(parts[1])
    let artifactID = String(parts[2])
    let metadata = try inspect(jobID: jobID, artifactID: artifactID)
    guard metadata.status.isPublished, metadata.sha256.count == 64 else {
      throw RuntimeArtifactError.artifactNotFound("Artifact lease is not readable")
    }
    let fileURL = try storedFileURL(for: metadata)
    return RuntimeArtifactLeaseResolution(
      artifactID: artifactID, fileURL: fileURL, sha256: metadata.sha256,
      byteCount: metadata.byteCount, bindingSnapshot: metadata.bindingSnapshot)
  }

  // MARK: - Lifecycle

  public func preflightAdditionalBytes(_ requestedBytes: Int) throws {
    guard requestedBytes >= 0 else {
      throw RuntimeArtifactError.ioFailure("artifact preflight byte count must be nonnegative")
    }
    let used = try totalBytesUsed()
    guard requestedBytes <= quota.totalBytes - min(used, quota.totalBytes) else {
      throw RuntimeArtifactError.quotaExceeded(
        requestedBytes: requestedBytes,
        remainingBytes: max(0, quota.totalBytes - used))
    }
  }

  public func totalBytesUsed() throws -> Int {
    if let cachedIndexedBytes { return cachedIndexedBytes }
    var total = 0
    for entry in try jobDirectories() {
      let index = try loadIndex(jobID: entry.lastPathComponent)
      total += index.artifacts.filter { $0.status.isPublished }.reduce(0) {
        $0 + $1.byteCount
      }
    }
    cachedIndexedBytes = total
    return total
  }

  /// Collects artifacts whose retention has lapsed. Active jobs and pinned
  /// artifacts are skipped - GC never removes something still referenced.
  public func collectGarbage(
    activeJobIDs: Set<String>, nowUTC currentUTC: String
  ) throws -> [String] {
    var removed: [String] = []
    for entry in try jobDirectories() {
      let jobID = entry.lastPathComponent
      if activeJobIDs.contains(jobID) { continue }
      var index = try loadIndex(jobID: jobID)
      var kept: [RuntimeArtifactMetadata] = []
      var expiredEntries: [RuntimeArtifactMetadata] = []
      for metadata in index.artifacts {
        let expired = try Self.isExpired(
          deadlineUTC: metadata.retention.deadlineUTC, currentUTC: currentUTC)
        if expired && !metadata.retention.pinned {
          expiredEntries.append(metadata)
        } else {
          kept.append(metadata)
        }
      }
      if kept.count != index.artifacts.count {
        // If persistence succeeds but a later unlink fails, the durable
        // indexes have already changed. Invalidating before that boundary
        // ensures the next quota check rebuilds the exact indexed total in
        // either outcome.
        cachedIndexedBytes = nil
        // Remove the index references first. A later unlink failure leaves
        // an unreferenced owned file, never an index that points at missing
        // evidence.
        index.artifacts = kept
        try persistIndex(index, jobID: jobID)
        for metadata in expiredEntries {
          if metadata.status.isPublished {
            do {
              try FileManager.default.removeItem(
                at: entry.appendingPathComponent(metadata.artifactID))
            } catch {
              throw RuntimeArtifactError.ioFailure(
                "cannot collect \(metadata.artifactID): \(error)")
            }
          }
          removed.append(metadata.artifactID)
        }
      }
    }
    return removed
  }

  package func recordCleanupDebt(
    jobID: String, stepID: String, residue: CleanupResidue, reason: String,
    action: TypedProviderAction? = nil
  ) throws {
    let path: String
    let bundle: String?
    switch residue {
    case .remotePath(let remotePath):
      path = remotePath
      bundle = nil
    case .installedBundle(let bundleName):
      path = ""
      bundle = bundleName
    }
    var debts = try loadCleanupDebt()
    debts.append(
      CleanupDebtRecord(
        jobID: jobID, stepID: stepID, remotePath: path, bundleName: bundle,
        reason: reason,
        recordedAtUTC: nowUTC(), settledAtUTC: nil,
        retryAttemptStartedAtUTC: nil, retryOutcomeUnknown: nil,
        persistedAction: try action.map { try PersistedTypedProviderAction($0) }))
    try persistCleanupDebt(debts)
  }

  package func recordCleanupDebt(
    jobID: String, stepID: String, remotePath: String, reason: String,
    action: TypedProviderAction? = nil
  ) throws {
    try recordCleanupDebt(
      jobID: jobID, stepID: stepID, residue: .remotePath(remotePath),
      reason: reason, action: action)
  }

  public func outstandingCleanupDebt() throws -> [CleanupDebtRecord] {
    try loadCleanupDebt().filter { $0.settledAtUTC == nil }
  }

  public func settleCleanupDebt(jobID: String, identity: String) throws {
    var debts = try loadCleanupDebt()
    for index in debts.indices
    where debts[index].jobID == jobID && debts[index].identity == identity
      && debts[index].settledAtUTC == nil
    {
      debts[index].settledAtUTC = nowUTC()
    }
    try persistCleanupDebt(debts)
  }

  func beginCleanupDebtRetry(jobID: String, identity: String) throws
    -> CleanupDebtRecord
  {
    var debts = try loadCleanupDebt()
    guard let index = debts.firstIndex(where: {
      $0.jobID == jobID && $0.identity == identity && $0.settledAtUTC == nil
    }) else {
      throw RuntimeArtifactError.artifactNotFound("cleanup-debt:\(jobID):\(identity)")
    }
    guard debts[index].retryOutcomeUnknown != true,
      debts[index].retryAttemptStartedAtUTC == nil
    else {
      throw RuntimeArtifactError.ioFailure(
        "cleanup retry has an unknown outcome; mutation resend is forbidden")
    }
    debts[index].retryAttemptStartedAtUTC = nowUTC()
    try persistCleanupDebt(debts)
    return debts[index]
  }

  func completeCleanupDebtRetry(
    jobID: String, identity: String, outcomeUnknown: Bool
  ) throws {
    var debts = try loadCleanupDebt()
    guard let index = debts.firstIndex(where: {
      $0.jobID == jobID && $0.identity == identity && $0.settledAtUTC == nil
    }) else {
      throw RuntimeArtifactError.artifactNotFound("cleanup-debt:\(jobID):\(identity)")
    }
    debts[index].retryOutcomeUnknown = outcomeUnknown
    if !outcomeUnknown {
      debts[index].retryAttemptStartedAtUTC = nil
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
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        try Self.requireDirectoryWithoutSymlink(url, label: "artifact job directory")
      } catch {
        throw RuntimeArtifactError.ioFailure("\(error)")
      }
    } else {
      do {
        try FileManager.default.createDirectory(
          at: url, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try Self.requireDirectoryWithoutSymlink(url, label: "artifact job directory")
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
      try Self.requireRegularFileWithoutSymlink(url, label: "artifact index")
      let document = try JSONDecoder().decode(
        ArtifactIndexDocument.self, from: Data(contentsOf: url))
      guard document.schemaVersion == ArtifactIndexDocument.currentSchemaVersion else {
        throw RuntimeArtifactError.indexCorrupted(
          "unsupported index schema \(document.schemaVersion)")
      }
      var artifactIDs = Set<String>()
      var names = Set<String>()
      for metadata in document.artifacts {
        guard metadata.jobID == jobID,
          Self.isSafeArtifactID(metadata.artifactID),
          artifactIDs.insert(metadata.artifactID).inserted,
          names.insert(metadata.name).inserted
        else {
          throw RuntimeArtifactError.indexCorrupted(
            "artifact index contains a foreign, unsafe or duplicate identity")
        }
        if metadata.status.isPublished {
          _ = try validateStoredPayload(
            metadata, at: url.deletingLastPathComponent()
              .appendingPathComponent(metadata.artifactID))
        }
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
    guard metadata.jobID == jobID, Self.isSafeArtifactID(metadata.artifactID) else {
      throw RuntimeArtifactError.indexCorrupted("artifact metadata identity is invalid")
    }
    if let existing = index.artifacts.first(where: { $0.name == metadata.name }),
      existing.artifactID != metadata.artifactID,
      existing.status.isPublished
    {
      throw RuntimeArtifactError.artifactConflict(
        "artifact name \(metadata.name) is already bound to immutable bytes")
    }
    index.artifacts.removeAll {
      $0.artifactID == metadata.artifactID || $0.name == metadata.name
    }
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
      try Self.requireRegularFileWithoutSymlink(url, label: "cleanup debt ledger")
      return try JSONDecoder().decode([CleanupDebtRecord].self, from: Data(contentsOf: url))
    } catch {
      throw RuntimeArtifactError.indexCorrupted("undecodable cleanup debt ledger: \(error)")
    }
  }

  private func persistCleanupDebt(_ debts: [CleanupDebtRecord]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = (try? encoder.encode(debts)) ?? Data("[]".utf8)
    if FileManager.default.fileExists(atPath: cleanupDebtURL().path) {
      try Self.requireRegularFileWithoutSymlink(
        cleanupDebtURL(), label: "cleanup debt ledger")
    }
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

  private func copyFileDescriptor(
    _ sourceFD: Int32,
    sourceBefore: stat,
    expectedSHA256: String,
    expectedByteCount: Int,
    destination: URL,
    directory: URL
  ) throws {
    guard Darwin.lseek(sourceFD, 0, SEEK_SET) == 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot rewind file-backed Artifact source (errno \(errno))")
    }
    let temporary = directory.appendingPathComponent(
      ".tmp-file-\(UUID().uuidString.prefix(12).lowercased())")
    let destinationFD = Darwin.open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard destinationFD >= 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot create file-backed Artifact destination (errno \(errno))")
    }
    var destinationIsOpen = true
    defer {
      if destinationIsOpen { Darwin.close(destinationFD) }
      _ = Darwin.unlink(temporary.path)
    }

    var hasher = SHA256()
    var copied = 0
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
      let count = Darwin.read(sourceFD, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw RuntimeArtifactError.ioFailure(
          "cannot read file-backed Artifact source (errno \(errno))")
      }
      if count == 0 { break }
      copied += count
      hasher.update(data: Data(buffer[0..<count]))
      var offset = 0
      while offset < count {
        let written = buffer.withUnsafeBytes { bytes in
          Darwin.write(
            destinationFD, bytes.baseAddress!.advanced(by: offset), count - offset)
        }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else {
          throw RuntimeArtifactError.ioFailure(
            "cannot write file-backed Artifact destination (errno \(errno))")
        }
        offset += written
      }
    }
    var sourceAfter = stat()
    let copiedDigest =
      SHA256Hex.hexString(hasher.finalize())
    guard copied == expectedByteCount,
      copiedDigest == expectedSHA256,
      fstat(sourceFD, &sourceAfter) == 0,
      Self.sameFileIdentityAndContent(sourceBefore, sourceAfter)
    else {
      throw RuntimeArtifactError.ioFailure(
        "file-backed Artifact source changed while being published")
    }
    guard fsync(destinationFD) == 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot synchronize file-backed Artifact destination (errno \(errno))")
    }
    Darwin.close(destinationFD)
    destinationIsOpen = false
    guard Darwin.link(temporary.path, destination.path) == 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot publish file-backed Artifact without overwrite (errno \(errno))")
    }
    guard Darwin.unlink(temporary.path) == 0 else {
      throw RuntimeArtifactError.ioFailure(
        "cannot remove file-backed Artifact staging link (errno \(errno))")
    }
    let directoryFD = Darwin.open(
      directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    if directoryFD >= 0 {
      _ = Darwin.fsync(directoryFD)
      Darwin.close(directoryFD)
    }
  }

  private struct StreamedTextArtifact {
    let byteCount: Int
    let sha256: String
    let redactionApplied: Bool
  }

  private func streamRedactedText(
    sourceFD: Int32,
    sourceBefore: stat,
    destinationFD: Int32,
    sourcePath: String
  ) throws -> StreamedTextArtifact {
    var pipeline = StreamingTextArtifactRedactor(homeDirectory: redaction.homeDirectory)
    var hasher = SHA256()
    var byteCount = 0
    let bufferSize = 64 * 1024
    var input = [UInt8](repeating: 0, count: bufferSize)
    while true {
      let readCount = input.withUnsafeMutableBytes { buffer in
        Darwin.read(sourceFD, buffer.baseAddress, bufferSize)
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount >= 0 else {
        throw RuntimeArtifactError.ioFailure(
          "cannot read text Artifact source (errno \(errno))")
      }
      if readCount == 0 { break }
      var output = Data()
      output.reserveCapacity(readCount)
      pipeline.consume(input[0..<readCount], into: &output)
      try Self.writeAll(output, to: destinationFD, label: "redacted Artifact staging file")
      byteCount += output.count
      hasher.update(data: output)
    }
    var finalOutput = Data()
    pipeline.finish(into: &finalOutput)
    try Self.writeAll(finalOutput, to: destinationFD, label: "redacted Artifact staging file")
    byteCount += finalOutput.count
    hasher.update(data: finalOutput)

    var sourceAfter = stat()
    guard fstat(sourceFD, &sourceAfter) == 0,
      Self.sameFileIdentityAndContent(sourceBefore, sourceAfter)
    else {
      throw RuntimeArtifactError.ioFailure(
        "text Artifact source changed while being redacted (\(sourcePath))")
    }
    return StreamedTextArtifact(
      byteCount: byteCount,
      sha256: SHA256Hex.hexString(hasher.finalize()),
      redactionApplied: pipeline.redactionApplied)
  }

  private static func writeAll(_ data: Data, to descriptor: Int32, label: String) throws {
    guard !data.isEmpty else { return }
    var offset = 0
    try data.withUnsafeBytes { buffer in
      while offset < data.count {
        let written = Darwin.write(
          descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else {
          throw RuntimeArtifactError.ioFailure("cannot write \(label) (errno \(errno))")
        }
        offset += written
      }
    }
  }

  private func storedFileURL(for metadata: RuntimeArtifactMetadata) throws -> URL {
    guard Self.isSafeArtifactID(metadata.artifactID) else {
      throw RuntimeArtifactError.indexCorrupted("unsafe artifact identifier in index")
    }
    let url = try directory(for: metadata.jobID).appendingPathComponent(metadata.artifactID)
    return try validateStoredPayload(metadata, at: url)
  }

  private func validateStoredPayload(
    _ metadata: RuntimeArtifactMetadata, at url: URL
  ) throws -> URL {
    do {
      try Self.requireRegularFileWithoutSymlink(url, label: "artifact payload")
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let size = attributes[.size] as? NSNumber,
        size.intValue == metadata.byteCount
      else {
        throw RuntimeArtifactError.indexCorrupted("artifact payload size drifted")
      }
      let digest = try Self.sha256Hex(of: url)
      guard digest == metadata.sha256 else {
        throw RuntimeArtifactError.indexCorrupted("artifact payload digest drifted")
      }
    } catch let error as RuntimeArtifactError {
      throw error
    } catch {
      throw RuntimeArtifactError.ioFailure("cannot inspect artifact payload: \(error)")
    }
    return url
  }

  private func jobDirectories() throws -> [URL] {
    let entries = try FileManager.default.contentsOfDirectory(
      at: rootURL, includingPropertiesForKeys: nil)
    return try entries.compactMap { entry in
      let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
      if attributes[.type] as? FileAttributeType == .typeDirectory {
        return entry
      }
      if attributes[.type] as? FileAttributeType == .typeRegular,
        entry.lastPathComponent == "cleanup-debt.json"
      {
        return nil
      }
      throw RuntimeArtifactError.indexCorrupted(
        "artifact root contains an unexpected or linked entry \(entry.lastPathComponent)")
    }
  }

  private static func sameImmutablePublication(
    _ existing: RuntimeArtifactMetadata, _ proposed: RuntimeArtifactMetadata
  ) -> Bool {
    existing.jobID == proposed.jobID
      && existing.sessionID == proposed.sessionID
      && existing.stepID == proposed.stepID
      && existing.name == proposed.name
      && existing.mediaType == proposed.mediaType
      && existing.byteCount == proposed.byteCount
      && existing.sha256 == proposed.sha256
      && existing.providerID == proposed.providerID
      && existing.sourceOperation == proposed.sourceOperation
      && existing.bindingSnapshot == proposed.bindingSnapshot
      && existing.privacy == proposed.privacy
      && existing.retention.retentionClass == proposed.retention.retentionClass
      && existing.retention.pinned == proposed.retention.pinned
      && existing.status == proposed.status
      && existing.redactionApplied == proposed.redactionApplied
  }

  private static func isSafeArtifactID(_ value: String) -> Bool {
    value.range(
      of: #"^ART-(?:MISSING-)?[0-9a-f]{32}$"#,
      options: .regularExpression) != nil
  }

  private static func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return SHA256Hex.hexString(hasher.finalize())
  }

  private static func sameFileIdentityAndContent(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode == rhs.st_mode
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func isExpired(deadlineUTC: String?, currentUTC: String) throws -> Bool {
    guard let deadlineUTC else { return false }
    func parse(_ value: String) -> Date? {
      ISO8601Timestamps.parse(value)
    }
    guard let deadline = parse(deadlineUTC), let current = parse(currentUTC) else {
      throw RuntimeArtifactError.indexCorrupted(
        "artifact retention contains an invalid UTC timestamp")
    }
    return deadline <= current
  }

  private static func requireDirectoryWithoutSymlink(_ url: URL, label: String) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw RuntimeArtifactError.ioFailure("\(label) must be a real directory")
    }
  }

  private static func requireRegularFileWithoutSymlink(_ url: URL, label: String) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw RuntimeArtifactError.indexCorrupted("\(label) must be a real regular file")
    }
  }
}

/// A bounded-memory UTF-8 byte pipeline for the two redactions enforced by
/// `ArtifactRedactionPolicy`.  It is intentionally conservative: malformed
/// UTF-8 and non-ASCII delimiters are treated as part of a possible secret,
/// never as proof that a sensitive value ended.  Consequently the streaming
/// path may redact more than the in-memory convenience path, but cannot leak
/// a value merely because it crossed a read boundary.
private struct StreamingTextArtifactRedactor {
  private static let secretKeys = [
    Array("token".utf8), Array("secret".utf8), Array("password".utf8),
    Array("passwd".utf8), Array("api_key".utf8), Array("api-key".utf8),
    Array("apikey".utf8), Array("authorization".utf8),
  ]
  private static let redacted = Array("<REDACTED>".utf8)
  private static let homeReplacement = Array("<HOME>".utf8)
  private static let secretKeyInitials: Set<UInt8> = Set(
    secretKeys.compactMap(\.first))

  private enum SecretState {
    case normal
    case separators(key: [UInt8], separators: [UInt8])
    case valueCandidate([UInt8])
    case discardingValue
  }

  private let homeDirectory: [UInt8]
  private var homeCandidate: [UInt8] = []
  private var keyCandidate: [UInt8] = []
  private var secretState: SecretState = .normal
  private var replacedHome = false
  private var replacedSecret = false

  init(homeDirectory: String) {
    self.homeDirectory = Array(homeDirectory.utf8)
  }

  var redactionApplied: Bool { replacedHome || replacedSecret }

  mutating func consume(_ bytes: ArraySlice<UInt8>, into output: inout Data) {
    for byte in bytes { consumeHome(byte, into: &output) }
  }

  mutating func finish(into output: inout Data) {
    for byte in homeCandidate { consumeSecret(byte, into: &output) }
    homeCandidate.removeAll(keepingCapacity: true)
    switch secretState {
    case .normal:
      output.append(contentsOf: keyCandidate)
    case .separators(let key, let separators):
      output.append(contentsOf: key)
      output.append(contentsOf: separators)
    case .valueCandidate(let value):
      output.append(contentsOf: value)
    case .discardingValue:
      break
    }
    keyCandidate.removeAll(keepingCapacity: true)
    secretState = .normal
  }

  private mutating func consumeHome(_ byte: UInt8, into output: inout Data) {
    guard !homeDirectory.isEmpty else {
      consumeSecret(byte, into: &output)
      return
    }
    // Most log bytes cannot start the absolute home path.  Keep the common
    // path O(1) rather than repeatedly constructing a one-byte candidate.
    if homeCandidate.isEmpty, byte != homeDirectory[0] {
      consumeSecret(byte, into: &output)
      return
    }
    homeCandidate.append(byte)
    while !Self.matchesExactPrefix(homeCandidate, expected: homeDirectory) {
      consumeSecret(homeCandidate.removeFirst(), into: &output)
    }
    if homeCandidate == homeDirectory {
      for replacementByte in Self.homeReplacement {
        consumeSecret(replacementByte, into: &output)
      }
      homeCandidate.removeAll(keepingCapacity: true)
      replacedHome = true
    }
  }

  private mutating func consumeSecret(_ byte: UInt8, into output: inout Data) {
    switch secretState {
    case .normal:
      consumeNormal(byte, into: &output)
    case .separators(let key, var separators):
      if Self.isSeparator(byte) {
        separators.append(byte)
        secretState = .separators(key: key, separators: separators)
      } else if separators.isEmpty {
        // The matched key was only a prefix of ordinary text (for example
        // `tokenizer`).  Emit one byte before replaying the suffix so the
        // same complete key cannot immediately re-enter this state and lose
        // the following ordinary byte.  A secret key beginning inside that
        // suffix is still discovered normally.
        output.append(key[0])
        secretState = .normal
        for held in key.dropFirst() { consumeNormal(held, into: &output) }
        consumeNormal(byte, into: &output)
      } else if Self.isValueDelimiter(byte) {
        output.append(contentsOf: key)
        output.append(contentsOf: separators)
        output.append(byte)
        secretState = .normal
      } else {
        output.append(contentsOf: key)
        output.append(contentsOf: separators)
        secretState = .valueCandidate([byte])
      }
    case .valueCandidate(var value):
      if Self.isValueDelimiter(byte) {
        output.append(contentsOf: value)
        output.append(byte)
        secretState = .normal
      } else {
        value.append(byte)
        if value.count >= 6 {
          output.append(contentsOf: Self.redacted)
          replacedSecret = true
          secretState = .discardingValue
        } else {
          secretState = .valueCandidate(value)
        }
      }
    case .discardingValue:
      if Self.isValueDelimiter(byte) {
        output.append(byte)
        secretState = .normal
      }
    }
  }

  private mutating func consumeNormal(_ byte: UInt8, into output: inout Data) {
    // The overwhelming majority of artifact bytes cannot begin one of the
    // sensitive key names.  Avoid testing every key pattern for those bytes;
    // this keeps a 128 MiB log linear in its byte count.
    if keyCandidate.isEmpty,
      !Self.secretKeyInitials.contains(Self.asciiLower(byte))
    {
      output.append(byte)
      return
    }
    keyCandidate.append(byte)
    while !Self.hasSecretKeyPrefix(keyCandidate) {
      output.append(keyCandidate.removeFirst())
    }
    if Self.isSecretKey(keyCandidate) {
      secretState = .separators(key: keyCandidate, separators: [])
      keyCandidate.removeAll(keepingCapacity: true)
    }
  }

  private static func isSeparator(_ byte: UInt8) -> Bool {
    byte == 0x22 || byte == 0x27 || byte == 0x20 || byte == 0x09 || byte == 0x0A
      || byte == 0x0D || byte == 0x0B || byte == 0x0C || byte == 0x3A || byte == 0x3D
  }

  private static func isValueDelimiter(_ byte: UInt8) -> Bool {
    isSeparator(byte) || byte == 0x2C || byte == 0x7D
  }

  private static func hasSecretKeyPrefix(_ bytes: [UInt8]) -> Bool {
    secretKeys.contains { matchesPrefix(bytes, expected: $0) }
  }

  private static func isSecretKey(_ bytes: [UInt8]) -> Bool {
    secretKeys.contains { key in
      key.count == bytes.count && matchesPrefix(bytes, expected: key)
    }
  }

  private static func matchesPrefix(_ bytes: [UInt8], expected: [UInt8]) -> Bool {
    guard bytes.count <= expected.count else { return false }
    for (index, byte) in bytes.enumerated() {
      if asciiLower(byte) != expected[index] { return false }
    }
    return true
  }

  private static func matchesExactPrefix(_ bytes: [UInt8], expected: [UInt8]) -> Bool {
    guard bytes.count <= expected.count else { return false }
    for (index, byte) in bytes.enumerated() where byte != expected[index] {
      return false
    }
    return true
  }

  private static func asciiLower(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
  }
}
