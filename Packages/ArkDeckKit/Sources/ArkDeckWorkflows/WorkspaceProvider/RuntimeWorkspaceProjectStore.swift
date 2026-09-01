import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public struct RuntimeWorkspaceProjectResource: Equatable, Sendable {
  public let projectRef: String
  public let generation: UInt64
  public let kind: String
  public let registeredAtUTC: String
  public let updatedAtUTC: String
  public let configurationStatus: String

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.workspace-project/1"),
      "projectRef": .string(projectRef),
      "generation": .string(String(generation)),
      "kind": .string(kind),
      "registeredAtUtc": .string(registeredAtUTC),
      "updatedAtUtc": .string(updatedAtUTC),
      "configurationStatus": .string(configurationStatus),
    ])
  }
}

public struct RuntimeWorkspaceProjectFailure: Error, Equatable, Sendable {
  public let code: String
  public let message: String

  package init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

package struct RuntimeWorkspaceProjectUseToken: Sendable {
  fileprivate let id: UUID
  fileprivate let projectRef: String
}

/// The private half of one registered workspace project.
///
/// A control response can receive `resource`; `rootPath` and its file identity
/// stay inside the production composition root and provider. Keeping the two
/// projections as different types prevents an encoder call from accidentally
/// publishing the grant.
package struct RuntimeWorkspaceProjectComposition: Sendable, Equatable {
  package let resource: RuntimeWorkspaceProjectResource
  package let rootPath: String
  package let rootDevice: UInt64
  package let rootInode: UInt64
}

package struct RuntimeWorkspaceProjectStartupRecord: Sendable, Equatable {
  package let resource: RuntimeWorkspaceProjectResource
  package let composition: RuntimeWorkspaceProjectComposition?
  package let failure: RuntimeWorkspaceProjectFailure?
}

/// Runtime-owned workspace root registrations.
///
/// Registration is the sole place a caller path enters this owner. The path is
/// opened without following the leaf, every ancestor is checked with `lstat`,
/// and the durable grant pins the opened directory's device/inode identity.
/// Public projections contain only the generated reference and generation.
///
/// The process lock also closes the acquire/update race. A workspace Job holds
/// a token until its SQLite admission row is durable; update/remove hold the
/// same lock while checking both tokens and durable active Jobs.
public final class RuntimeWorkspaceProjectStore: @unchecked Sendable {
  private struct RootIdentity: Codable, Equatable, Hashable {
    let path: String
    let device: UInt64
    let inode: UInt64
  }

  private struct Record: Codable, Equatable {
    let projectRef: String
    var generation: UInt64
    var kind: String
    var root: RootIdentity
    let registrationRequestID: String
    let registrationKind: String
    let registrationRoot: RootIdentity
    let registrationDigest: String
    let registeredAtUTC: String
    var updatedAtUTC: String
  }

  private struct Document: Codable, Equatable {
    var schemaVersion = "arkdeck.workspace-project-store/1"
    var records: [Record] = []
  }

  private static let documentName = "projects.json"
  private static let lockName = ".projects.lock"
  private static let maximumDocumentBytes = 1 * 1_024 * 1_024
  private static let maximumProjects = 64
  private static let kinds: Set<String> = ["arkdeck", "openharmony"]

  private let directoryURL: URL
  private let nowUTC: @Sendable () -> String
  private let processLock = NSLock()
  private var uses: [String: Set<UUID>] = [:]
  private var appliedGenerations: [String: UInt64]

  package init(
    rootURL: URL,
    appliedGenerations: [String: UInt64] = [:],
    nowUTC: @escaping @Sendable () -> String = {
      ISO8601Timestamps.string(from: Date(), includingFractionalSeconds: true)
    }
  ) throws {
    directoryURL = rootURL.appending(path: "workspace-projects", directoryHint: .isDirectory)
    self.appliedGenerations = appliedGenerations
    self.nowUTC = nowUTC
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Self.validateOwnerDirectory(directoryURL)
  }

  package func markApplied(_ generations: [String: UInt64]) {
    processLock.withLock { appliedGenerations = generations }
  }

  package func list() throws -> [RuntimeWorkspaceProjectResource] {
    try processLock.withLock {
      try withDocument { _, document in
        try document.records.map { try resource($0) }
          .sorted { $0.projectRef < $1.projectRef }
      }
    }
  }

  package func inspect(_ projectRef: String) throws -> RuntimeWorkspaceProjectResource {
    try validateProjectRef(projectRef)
    return try processLock.withLock {
      try withDocument { _, document in
        guard let record = document.records.first(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        return try resource(record)
      }
    }
  }

  package func compositionRecords() throws -> [RuntimeWorkspaceProjectComposition] {
    try processLock.withLock {
      try withDocument { _, document in
        try document.records.map { record in
          let current = try Self.inspectRoot(record.root.path)
          guard current == record.root else {
            throw RuntimeWorkspaceProjectFailure(
              "factsDrifted", "workspace root identity changed after registration")
          }
          return RuntimeWorkspaceProjectComposition(
            resource: try resource(record), rootPath: record.root.path,
            rootDevice: record.root.device, rootInode: record.root.inode)
        }.sorted { $0.resource.projectRef < $1.resource.projectRef }
      }
    }
  }

  /// A changed root is an unavailable project, not a corrupt owner store.
  /// Production startup uses this projection so the daemon can still expose
  /// and repair/remove the failed registration while every Job acquisition
  /// continues to revalidate the same pinned identity.
  package func startupRecords() throws -> [RuntimeWorkspaceProjectStartupRecord] {
    try processLock.withLock {
      try withDocument { _, document in
        try document.records.map { record in
          let publicResource = try resource(record)
          do {
            let current = try Self.inspectRoot(record.root.path)
            guard current == record.root else {
              throw RuntimeWorkspaceProjectFailure(
                "factsDrifted", "workspace root identity changed after registration")
            }
            return RuntimeWorkspaceProjectStartupRecord(
              resource: publicResource,
              composition: RuntimeWorkspaceProjectComposition(
                resource: publicResource, rootPath: record.root.path,
                rootDevice: record.root.device, rootInode: record.root.inode),
              failure: nil)
          } catch let failure as RuntimeWorkspaceProjectFailure {
            return RuntimeWorkspaceProjectStartupRecord(
              resource: publicResource, composition: nil, failure: failure)
          }
        }.sorted { $0.resource.projectRef < $1.resource.projectRef }
      }
    }
  }

  package func register(
    requestID: String, kind: String, rootPath: String,
    projectRef suppliedProjectRef: String? = nil
  ) throws -> RuntimeWorkspaceProjectResource {
    try validateRequestID(requestID)
    try validateKind(kind)
    let root = try Self.inspectRoot(rootPath)
    let digest = Self.registrationDigest(kind: kind, root: root)
    let projectRef = suppliedProjectRef ?? Self.projectRef(requestID: requestID)
    try validateProjectRef(projectRef)
    return try processLock.withLock {
      try withDocument { rootFD, document in
        var next = document
        if let existing = next.records.first(where: { $0.registrationRequestID == requestID }) {
          guard existing.registrationDigest == digest, existing.projectRef == projectRef else {
            throw RuntimeWorkspaceProjectFailure(
              "idempotencyConflict", "registration request identity belongs to another project")
          }
          return try resource(existing)
        }
        guard next.records.count < Self.maximumProjects else {
          throw RuntimeWorkspaceProjectFailure(
            "quotaExceeded", "workspace project registration limit is reached")
        }
        guard !next.records.contains(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project reference is already registered")
        }
        guard !next.records.contains(where: { $0.root == root }) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace root is already registered")
        }
        let timestamp = try validTimestamp()
        let record = Record(
          projectRef: projectRef, generation: 1, kind: kind, root: root,
          registrationRequestID: requestID,
          registrationKind: kind, registrationRoot: root,
          registrationDigest: digest,
          registeredAtUTC: timestamp, updatedAtUTC: timestamp)
        next.records.append(record)
        next.records.sort { $0.projectRef < $1.projectRef }
        try save(next, rootFD: rootFD)
        return try resource(record)
      }
    }
  }

  package func update(
    projectRef: String, expectedGeneration: UInt64, kind: String, rootPath: String,
    requireNoActiveReference: (String) throws -> Void
  ) throws -> RuntimeWorkspaceProjectResource {
    try validateProjectRef(projectRef)
    try validateGeneration(expectedGeneration)
    try validateKind(kind)
    let root = try Self.inspectRoot(rootPath)
    return try processLock.withLock {
      try requireNoUse(projectRef)
      try requireNoActiveReference(projectRef)
      return try withDocument { rootFD, document in
        var next = document
        guard let index = next.records.firstIndex(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        guard next.records[index].generation == expectedGeneration else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project generation changed")
        }
        guard !next.records.enumerated().contains(where: { offset, record in
          offset != index && record.root == root
        }) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace root is already registered")
        }
        let advanced = expectedGeneration.addingReportingOverflow(1)
        guard !advanced.overflow, advanced.partialValue <= UInt64(Int64.max) else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project generation is exhausted")
        }
        next.records[index].generation = advanced.partialValue
        next.records[index].kind = kind
        next.records[index].root = root
        next.records[index].updatedAtUTC = try validTimestamp()
        try save(next, rootFD: rootFD)
        return try resource(next.records[index])
      }
    }
  }

  package func remove(
    projectRef: String, expectedGeneration: UInt64,
    requireNoActiveReference: (String) throws -> Void
  ) throws -> RuntimeWorkspaceProjectResource {
    try validateProjectRef(projectRef)
    try validateGeneration(expectedGeneration)
    return try processLock.withLock {
      try requireNoUse(projectRef)
      try requireNoActiveReference(projectRef)
      return try withDocument { rootFD, document in
        var next = document
        guard let index = next.records.firstIndex(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        let removed = next.records[index]
        guard removed.generation == expectedGeneration else {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace project generation changed")
        }
        next.records.remove(at: index)
        try save(next, rootFD: rootFD)
        appliedGenerations.removeValue(forKey: projectRef)
        return try resource(removed, forcedStatus: "removed")
      }
    }
  }

  package func acquireUse(projectRef: String) throws -> RuntimeWorkspaceProjectUseToken {
    try validateProjectRef(projectRef)
    return try processLock.withLock {
      try withDocument { _, document in
        guard let record = document.records.first(where: { $0.projectRef == projectRef }) else {
          throw RuntimeWorkspaceProjectFailure(
            "workspaceReferenceNotFound", "workspace project is not registered")
        }
        let currentRoot = try Self.inspectRoot(record.root.path)
        guard currentRoot == record.root else {
          throw RuntimeWorkspaceProjectFailure(
            "factsDrifted", "workspace root identity changed after registration")
        }
        guard appliedGenerations[projectRef] == record.generation else {
          throw RuntimeWorkspaceProjectFailure(
            "operationUnavailable",
            "workspace project configuration changed; restart the Runtime before submitting a Job")
        }
      }
      let token = RuntimeWorkspaceProjectUseToken(id: UUID(), projectRef: projectRef)
      uses[projectRef, default: []].insert(token.id)
      return token
    }
  }

  package func endUse(_ token: RuntimeWorkspaceProjectUseToken) {
    processLock.withLock {
      uses[token.projectRef]?.remove(token.id)
      if uses[token.projectRef]?.isEmpty == true { uses.removeValue(forKey: token.projectRef) }
    }
  }

  private func requireNoUse(_ projectRef: String) throws {
    guard uses[projectRef]?.isEmpty != false else {
      throw RuntimeWorkspaceProjectFailure(
        "resourceConflict", "workspace project is being materialized by a Job")
    }
  }

  private func resource(
    _ record: Record, forcedStatus: String? = nil
  ) throws -> RuntimeWorkspaceProjectResource {
    guard ISO8601Timestamps.parse(record.registeredAtUTC) != nil,
      ISO8601Timestamps.parse(record.updatedAtUTC) != nil
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project timestamps are invalid")
    }
    return RuntimeWorkspaceProjectResource(
      projectRef: record.projectRef, generation: record.generation, kind: record.kind,
      registeredAtUTC: record.registeredAtUTC, updatedAtUTC: record.updatedAtUTC,
      configurationStatus: forcedStatus
        ?? (appliedGenerations[record.projectRef] == record.generation
          ? "active" : "runtimeRestartRequired"))
  }

  private func validTimestamp() throws -> String {
    let timestamp = nowUTC()
    guard ISO8601Timestamps.parse(timestamp) != nil else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project clock is unavailable")
    }
    return timestamp
  }

  private func withDocument<T>(_ body: (Int32, Document) throws -> T) throws -> T {
    let rootFD = Darwin.open(
      directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootFD >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store cannot be opened")
    }
    defer { Darwin.close(rootFD) }
    try Self.validateDirectoryDescriptor(rootFD)
    let lockFD = Darwin.openat(
      rootFD, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store lock cannot be opened")
    }
    defer { Darwin.close(lockFD) }
    try Self.validateRegularDescriptor(lockFD, label: "workspace project store lock")
    while flock(lockFD, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw RuntimeWorkspaceProjectFailure(
        "resourceConflict", "workspace project store lock cannot be acquired")
    }
    defer { _ = flock(lockFD, LOCK_UN) }
    return try body(rootFD, load(rootFD: rootFD))
  }

  private func load(rootFD: Int32) throws -> Document {
    let descriptor = Darwin.openat(
      rootFD, Self.documentName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return Document() }
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try Self.validateRegularDescriptor(descriptor, label: "workspace project store document")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0,
      metadata.st_size <= Self.maximumDocumentBytes
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document exceeds its bound")
    }
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    try data.withUnsafeMutableBytes { buffer in
      while offset < buffer.count {
        let count = Darwin.read(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count > 0 { offset += count; continue }
        if count < 0, errno == EINTR { continue }
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace project store document cannot be read")
      }
    }
    do {
      var duplicateValidator = StrictJSONDuplicateValidator(data: data)
      try duplicateValidator.validate()
      let document = try JSONDecoder().decode(Document.self, from: data)
      guard document.schemaVersion == "arkdeck.workspace-project-store/1",
        document.records.count <= Self.maximumProjects,
        Set(document.records.map(\.projectRef)).count == document.records.count,
        Set(document.records.map(\.registrationRequestID)).count == document.records.count
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace project store document has an invalid shape")
      }
      for record in document.records {
        try validateProjectRef(record.projectRef)
        try validateGeneration(record.generation)
        try validateKind(record.kind)
        try validateRequestID(record.registrationRequestID)
        try validateKind(record.registrationKind)
        guard Self.isCanonicalAbsoluteRootPath(record.root.path), record.root.inode > 0,
          Self.isCanonicalAbsoluteRootPath(record.registrationRoot.path),
          record.registrationRoot.inode > 0,
          record.registrationDigest == Self.registrationDigest(
            kind: record.registrationKind, root: record.registrationRoot),
          let registeredAt = ISO8601Timestamps.parse(record.registeredAtUTC),
          let updatedAt = ISO8601Timestamps.parse(record.updatedAtUTC),
          updatedAt >= registeredAt
        else {
          throw RuntimeWorkspaceProjectFailure(
            "recordUnreadable", "workspace project store record is inconsistent")
        }
      }
      guard Set(document.records.map(\.root)).count == document.records.count else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace project store contains duplicate roots")
      }
      return document
    } catch let failure as RuntimeWorkspaceProjectFailure {
      throw failure
    } catch {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document is malformed")
    }
  }

  private func save(_ document: Document, rootFD: Int32) throws {
    let data: Data
    do { data = try CanonicalJSONEncoders.canonical().encode(document) }
    catch {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store document cannot be encoded")
    }
    guard data.count <= Self.maximumDocumentBytes else {
      throw RuntimeWorkspaceProjectFailure(
        "quotaExceeded", "workspace project store document exceeds its bound")
    }
    let temporaryName = ".projects.\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      rootFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "ioFailure", "workspace project store staging file cannot be created")
    }
    var renamed = false
    defer {
      Darwin.close(descriptor)
      if !renamed { _ = unlinkat(rootFD, temporaryName, 0) }
    }
    try Self.validateRegularDescriptor(descriptor, label: "workspace project store staging file")
    var offset = 0
    try data.withUnsafeBytes { buffer in
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count > 0 { offset += count; continue }
        if count < 0, errno == EINTR { continue }
        throw RuntimeWorkspaceProjectFailure(
          "ioFailure", "workspace project store staging file cannot be written")
      }
    }
    guard fsync(descriptor) == 0,
      renameat(rootFD, temporaryName, rootFD, Self.documentName) == 0,
      fsync(rootFD) == 0
    else {
      throw RuntimeWorkspaceProjectFailure(
        "outcomeUnknown", "workspace project store publication could not be verified")
    }
    renamed = true
  }

  private static func inspectRoot(_ path: String) throws -> RootIdentity {
    // `standardizedFileURL` resolves macOS's `/var -> /private/var` system
    // link for an existing path. Using it here would make the lexical check
    // demand `/var/...` and the next no-follow check correctly reject the same
    // path. `standardized` only removes lexical `.`/`..`; the descriptor and
    // `lstat` checks below own physical canonicalization.
    guard isCanonicalAbsoluteRootPath(path) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace root must be a canonical absolute directory")
    }
    var cursor = URL(filePath: "/", directoryHint: .isDirectory)
    for component in path.split(separator: "/") {
      cursor.append(path: String(component))
      var metadata = stat()
      guard lstat(cursor.path, &metadata) == 0,
        metadata.st_mode & S_IFMT != S_IFLNK
      else {
        throw RuntimeWorkspaceProjectFailure(
          "invalidInput", "workspace root ancestry cannot contain a symbolic link")
      }
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace root cannot be opened as a directory")
    }
    defer { Darwin.close(descriptor) }
    var opened = stat()
    var named = stat()
    guard fstat(descriptor, &opened) == 0, lstat(path, &named) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino
    else {
      throw RuntimeWorkspaceProjectFailure(
        "factsDrifted", "workspace root changed while it was being registered")
    }
    return RootIdentity(
      path: path, device: UInt64(bitPattern: Int64(opened.st_dev)),
      inode: UInt64(opened.st_ino))
  }

  private static func isCanonicalAbsoluteRootPath(_ path: String) -> Bool {
    path.hasPrefix("/") && path != "/" && path.utf8.count <= 4_096
      && !path.utf8.contains(0) && URL(filePath: path).standardized.path == path
  }

  private static func registrationDigest(kind: String, root: RootIdentity) -> String {
    let bytes = Data("\(kind)\u{0}\(root.path)\u{0}\(root.device)\u{0}\(root.inode)".utf8)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func projectRef(requestID: String) -> String {
    let digest = SHA256.hash(data: Data(requestID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "project-" + String(digest.prefix(24))
  }

  private func validateProjectRef(_ value: String) throws {
    guard Self.validIdentifier(value, maximumBytes: 128) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace project reference is malformed")
    }
  }

  private func validateRequestID(_ value: String) throws {
    guard Self.validIdentifier(value, maximumBytes: 128) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "registration request identity is malformed")
    }
  }

  private func validateKind(_ value: String) throws {
    guard Self.kinds.contains(value) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace project kind must be arkdeck or openharmony")
    }
  }

  private func validateGeneration(_ value: UInt64) throws {
    guard value > 0, value <= UInt64(Int64.max) else {
      throw RuntimeWorkspaceProjectFailure(
        "invalidInput", "workspace project generation must be a canonical positive integer")
    }
  }

  private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && value.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
          || scalar == "-" || scalar == "_" || scalar == ".")
      }
  }

  private static func validateOwnerDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store directory cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateDirectoryDescriptor(descriptor)
  }

  private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(),
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "workspace project store directory is not owner-private")
    }
  }

  private static func validateRegularDescriptor(_ descriptor: Int32, label: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0, metadata.st_nlink == 1
    else {
      throw RuntimeWorkspaceProjectFailure(
        "recordUnreadable", "\(label) is not an owner-only regular file")
    }
  }
}
