import ArkDeckCore
import Darwin
import Foundation

public struct SessionLayout: Equatable, Sendable {
  public let sessionID: String
  public let jobID: String
  public let root: URL

  public var journalURL: URL { root.appending(path: "journal.jsonl") }
  public var snapshotURL: URL { root.appending(path: "snapshot.json") }
  public var commandAuditURL: URL { root.appending(path: "audit/commands.jsonl") }
  public var eventAuditURL: URL { root.appending(path: "audit/events.jsonl") }
  public var sessionAuditURL: URL { root.appending(path: "audit/session.jsonl") }
  public var identityURL: URL { root.appending(path: ".session-identity.json") }
  public var rawDirectory: URL {
    root.appending(path: "artifacts/raw", directoryHint: .isDirectory)
  }
  public var derivedDirectory: URL {
    root.appending(path: "artifacts/derived", directoryHint: .isDirectory)
  }
  public var partialDirectory: URL {
    root.appending(path: "artifacts/partial", directoryHint: .isDirectory)
  }
  /// Shared with `SessionTerminalPublicationLock`/`FileDurableJournal`, which coordinate the
  /// journal and the write-once manifest through these session-root entry names.
  public static let manifestFileName = "manifest.json"
  static let manifestLockFileName = ".manifest.lock"

  public var manifestURL: URL { root.appending(path: Self.manifestFileName) }
  public var manifestLockURL: URL { root.appending(path: Self.manifestLockFileName) }

  public init(sessionID: String, jobID: String, root: URL) throws {
    try SessionStorageValidation.identifier(sessionID, field: "sessionId")
    try SessionStorageValidation.identifier(jobID, field: "jobId")
    try DurableFilePrimitives.requireAbsoluteFileURL(root)
    self.sessionID = sessionID
    self.jobID = jobID
    self.root = root
  }
}

public struct SessionStore: Sendable {
  public let sessionsRoot: URL
  private let volumeIdentityResolver: any VolumeIdentityResolving
  private let faultInjector: SessionStorageFaultInjector

  public init(
    sessionsRoot: URL,
    volumeIdentityResolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver(),
    faultInjector: SessionStorageFaultInjector = .none
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(sessionsRoot)
    try SessionStorageValidation.secureDirectory(sessionsRoot)
    self.sessionsRoot = sessionsRoot
    self.volumeIdentityResolver = volumeIdentityResolver
    self.faultInjector = faultInjector
  }

  public func createSession(
    sessionID: String,
    jobID: String,
    createdAt: Date,
    claim: StorageClaim?
  ) throws
    -> SessionLayout
  {
    guard let claim else {
      throw SessionStorageError.claimUnavailable("session-creation:missing-claim")
    }
    let planned = try plannedLayout(sessionID: sessionID, jobID: jobID, createdAt: createdAt)
    return try claim.performSessionCreation(layout: planned.layout) { context, progress in
      let initialVolume = try volumeIdentityResolver.resolve(sessionsRoot)
      guard initialVolume == claim.volumeIdentity else {
        throw SessionStorageError.volumeIdentityChanged(
          expected: claim.volumeIdentity, actual: initialVolume)
      }
      if !context.isRepair {
        var existingMetadata = stat()
        if lstat(planned.layout.root.path, &existingMetadata) == 0 {
          throw SessionStorageError.invalidRecord(
            "Session already exists: \(planned.layout.sessionID)")
        } else if errno != ENOENT {
          throw SessionStorageError.writeFailed(path: planned.layout.root.path, errno: errno)
        }
      }
      let layout = try createSessionUnderClaim(
        planned.layout, yearRoot: planned.yearRoot, monthRoot: planned.monthRoot,
        context: context, progress: &progress)
      let finalVolume = try volumeIdentityResolver.resolve(layout.root)
      guard finalVolume == claim.volumeIdentity else {
        throw SessionStorageError.volumeIdentityChanged(
          expected: claim.volumeIdentity, actual: finalVolume)
      }
      return layout
    }
  }

  private func plannedLayout(sessionID: String, jobID: String, createdAt: Date) throws -> (
    layout: SessionLayout, yearRoot: URL, monthRoot: URL
  ) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents([.year, .month], from: createdAt)
    guard let year = components.year, let month = components.month else {
      throw SessionStorageError.invalidRecord("cannot derive Session date partition")
    }
    let yearRoot = sessionsRoot.appending(
      path: String(format: "%04d", year), directoryHint: .isDirectory)
    let monthRoot = yearRoot.appending(
      path: String(format: "%02d", month), directoryHint: .isDirectory)
    let root = monthRoot.appending(path: sessionID, directoryHint: .isDirectory)
    let layout = try SessionLayout(sessionID: sessionID, jobID: jobID, root: root)
    return (layout, yearRoot, monthRoot)
  }

  private func createSessionUnderClaim(
    _ layout: SessionLayout,
    yearRoot: URL,
    monthRoot: URL,
    context: StorageClaimSessionCreationContext,
    progress: inout StorageClaimSessionCreationProgress
  ) throws -> SessionLayout {
    try SessionStorageValidation.secureDirectory(yearRoot)
    try SessionStorageValidation.secureDirectory(monthRoot)

    if context.isRepair {
      var existingMetadata = stat()
      if lstat(layout.root.path, &existingMetadata) != 0 {
        if errno == ENOENT {
          progress.rootCreated = false
          progress.rootOwnership = nil
          throw SessionStorageError.invalidRecord(
            "owned Session root disappeared before repair: \(layout.sessionID)")
        }
        throw SessionStorageError.writeFailed(path: layout.root.path, errno: errno)
      }
    } else {
      try faultInjector.check(.sessionBeforeRootCreate)
      guard Darwin.mkdir(layout.root.path, 0o700) == 0 else {
        if errno == EEXIST {
          throw SessionStorageError.invalidRecord("Session already exists: \(layout.sessionID)")
        }
        throw SessionStorageError.writeFailed(path: layout.root.path, errno: errno)
      }
      progress.rootCreated = true
    }

    let rootDescriptor = Darwin.open(
      layout.root.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else {
      let openError = errno
      if !context.isRepair {
        if let rootOwnership = safeRootOwnership(at: layout.root) {
          // Preserve the exact inode for an idempotent retry even when descriptor acquisition
          // itself failed (for example, a transient descriptor-limit condition).
          progress.rootOwnership = rootOwnership
        } else if Darwin.rmdir(layout.root.path) == 0 || errno == ENOENT {
          // No child mutation has happened yet. If the unproven empty root can be removed, this
          // claim may be released instead of retaining headroom for a root it cannot identify.
          progress.rootCreated = false
        }
      }
      throw SessionStorageError.writeFailed(path: layout.root.path, errno: openError)
    }
    defer { Darwin.close(rootDescriptor) }
    let rootOwnership = try validateOwnedSessionRoot(
      descriptor: rootDescriptor, at: layout.root,
      expected: context.expectedRootOwnership)
    progress.rootOwnership = rootOwnership
    if !context.isRepair {
      try faultInjector.check(.sessionRootCreated)
    }

    for directory in [
      layout.commandAuditURL.deletingLastPathComponent(), layout.rawDirectory,
      layout.derivedDirectory, layout.partialDirectory,
    ] {
      try SessionStorageValidation.secureDirectory(directory)
    }
    try ensureIdentity(layout)
    let artifactsRoot = layout.rawDirectory.deletingLastPathComponent()
    for directory in [
      layout.commandAuditURL.deletingLastPathComponent(), layout.rawDirectory,
      layout.derivedDirectory, layout.partialDirectory, artifactsRoot, layout.root, monthRoot,
      yearRoot, sessionsRoot,
    ] {
      try faultInjector.check(.sessionDirectorySync)
      try DurableFilePrimitives.syncDirectory(directory)
    }
    _ = try validateOwnedSessionRoot(
      descriptor: rootDescriptor, at: layout.root, expected: rootOwnership)
    return layout
  }

  public func openSession(sessionID: String, jobID: String, root: URL) throws -> SessionLayout {
    let layout = try SessionLayout(sessionID: sessionID, jobID: jobID, root: root)
    guard root.standardizedFileURL.lastPathComponent == sessionID else {
      throw SessionStorageError.invalidRecord("Session ID does not match its directory")
    }
    try DurableFilePrimitives.rejectSymbolicLink(root)
    let lexicalSessionsRoot = sessionsRoot.standardizedFileURL
    let lexicalRoot = root.standardizedFileURL
    let sessionsPrefix =
      lexicalSessionsRoot.path.hasSuffix("/")
      ? lexicalSessionsRoot.path : lexicalSessionsRoot.path + "/"
    guard lexicalRoot.path.hasPrefix(sessionsPrefix) else {
      throw SessionStorageError.invalidRecord("Session root escapes the configured catalog")
    }
    let relativePath = String(lexicalRoot.path.dropFirst(sessionsPrefix.count))
    let expectedResolvedRoot = lexicalSessionsRoot.resolvingSymlinksInPath()
      .appending(path: relativePath).standardizedFileURL
    guard lexicalRoot.resolvingSymlinksInPath() == expectedResolvedRoot else {
      throw SessionStorageError.invalidRecord("Session root traverses a symbolic link")
    }
    var metadata = stat()
    guard lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
      throw SessionStorageError.invalidRecord("Session root is unavailable: \(root.path)")
    }
    let identity = try readIdentity(layout.identityURL)
    guard identity.sessionID == sessionID, identity.jobID == jobID else {
      throw SessionStorageError.invalidRecord("Session directory identity mismatch")
    }
    return layout
  }

  private func validateOwnedSessionRoot(
    descriptor: Int32,
    at url: URL,
    expected: StorageClaimSessionRootOwnership?
  ) throws -> StorageClaimSessionRootOwnership {
    var descriptorMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
      descriptorMetadata.st_mode & S_IFMT == S_IFDIR,
      descriptorMetadata.st_uid == geteuid(),
      descriptorMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      lstat(url.path, &pathMetadata) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFDIR,
      pathMetadata.st_dev == descriptorMetadata.st_dev,
      pathMetadata.st_ino == descriptorMetadata.st_ino
    else {
      throw SessionStorageError.invalidRecord(
        "Session root no longer identifies its owned directory: \(url.path)")
    }
    let actual = StorageClaimSessionRootOwnership(metadata: descriptorMetadata)
    if let expected, expected != actual {
      throw SessionStorageError.invalidRecord(
        "Session repair root identity does not match the creating claim")
    }
    return actual
  }

  private func safeRootOwnership(at url: URL) -> StorageClaimSessionRootOwnership? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else { return nil }
    return StorageClaimSessionRootOwnership(metadata: metadata)
  }

  private func ensureIdentity(_ layout: SessionLayout) throws {
    let identity = SessionDirectoryIdentity(sessionID: layout.sessionID, jobID: layout.jobID)
    let data = try SessionStorageValidation.canonicalData(identity)
    var descriptor = Darwin.open(
      layout.identityURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    let created = descriptor >= 0
    if !created {
      guard errno == EEXIST else {
        throw SessionStorageError.writeFailed(path: layout.identityURL.path, errno: errno)
      }
      descriptor = Darwin.open(
        layout.identityURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else {
        throw SessionStorageError.writeFailed(path: layout.identityURL.path, errno: errno)
      }
    }
    var isOpen = true
    defer { if isOpen { Darwin.close(descriptor) } }
    do {
      var shouldWrite = created
      if !created {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_uid == geteuid(), metadata.st_nlink == 1,
          metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
          metadata.st_size >= 0, metadata.st_size <= 4_096
        else { throw SessionStorageError.invalidRecord("invalid Session identity file") }
        if metadata.st_size == 0 {
          shouldWrite = true
        } else {
          do {
            let existing = try readIdentity(descriptor: descriptor, path: layout.identityURL.path)
            guard existing.sessionID == layout.sessionID, existing.jobID == layout.jobID else {
              throw SessionStorageError.invalidRecord("Session directory identity mismatch")
            }
          } catch SessionStorageError.invalidRecord(let message)
            where message == "invalid Session identity file"
            || message == "truncated Session identity file"
          {
            shouldWrite = true
          } catch is StrictJSONError {
            shouldWrite = true
          } catch is DecodingError {
            shouldWrite = true
          }
        }
      }
      if shouldWrite {
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
          throw SessionStorageError.writeFailed(path: layout.identityURL.path, errno: errno)
        }
        try DurableFilePrimitives.writeAll(
          data, descriptor: descriptor, path: layout.identityURL.path)
      }
      try faultInjector.check(.sessionIdentityFileSync)
      try DurableFilePrimitives.fullSync(descriptor, path: layout.identityURL.path)
    } catch let failure as DurableFileError {
      throw mapIdentityDurableError(failure)
    }
    _ = try readIdentity(descriptor: descriptor, path: layout.identityURL.path)
    guard Darwin.close(descriptor) == 0 else {
      isOpen = false
      throw SessionStorageError.writeFailed(path: layout.identityURL.path, errno: errno)
    }
    isOpen = false
  }

  private func readIdentity(_ url: URL) throws -> SessionDirectoryIdentity {
    try DurableFilePrimitives.rejectSymbolicLink(url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    return try readIdentity(descriptor: descriptor, path: url.path)
  }

  private func readIdentity(descriptor: Int32, path: String) throws -> SessionDirectoryIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      metadata.st_size > 0, metadata.st_size <= 4_096
    else { throw SessionStorageError.invalidRecord("invalid Session identity file") }
    var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SessionStorageError.invalidRecord("truncated Session identity file")
      }
      offset += count
    }
    var finalMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &finalMetadata) == 0,
      finalMetadata.st_dev == metadata.st_dev, finalMetadata.st_ino == metadata.st_ino,
      finalMetadata.st_size == metadata.st_size,
      lstat(path, &pathMetadata) == 0, pathMetadata.st_mode & S_IFMT == S_IFREG,
      pathMetadata.st_dev == metadata.st_dev, pathMetadata.st_ino == metadata.st_ino
    else {
      throw SessionStorageError.invalidRecord(
        "Session identity path changed during validation")
    }
    let data = Data(bytes)
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data),
      Set(object.keys) == ["schemaVersion", "sessionId", "jobId"],
      object["schemaVersion"] == .string("1.0.0"),
      case .string(let sessionID)? = object["sessionId"],
      case .string(let jobID)? = object["jobId"]
    else { throw SessionStorageError.invalidRecord("invalid Session identity file") }
    return SessionDirectoryIdentity(sessionID: sessionID, jobID: jobID)
  }
}

private struct SessionDirectoryIdentity: Codable {
  let schemaVersion = "1.0.0"
  let sessionID: String
  let jobID: String

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sessionID = "sessionId"
    case jobID = "jobId"
  }
}

private func mapIdentityDurableError(_ failure: DurableFileError) -> Error {
  switch failure {
  case .openFailed(let path, let code), .writeFailed(let path, let code),
    .syncFailed(let path, let code), .replaceFailed(let path, let code),
    .truncateFailed(let path, let code):
    return SessionStorageError.writeFailed(path: path, errno: code)
  default:
    return failure
  }
}
