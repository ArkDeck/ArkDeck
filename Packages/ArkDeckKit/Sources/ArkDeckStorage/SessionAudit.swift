import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum SessionAuditCategory: String, Codable, CaseIterable, Sendable {
  case preview
  case confirmation
  case intent
  case outcome
}

public struct SessionAuditRecord: Codable, Equatable, Sendable {
  public static let schemaVersion = "1.0.0"
  public static let maximumCanonicalDetailBytes = 64 * 1_024
  public static let maximumCanonicalRecordBytes = maximumCanonicalDetailBytes + 8 * 1_024
  public static let maximumTimestampUTF8Bytes = 64

  public let recordID: String
  public let auditID: String
  public let correlationID: String
  public let sessionID: String
  public let jobID: String
  public let category: SessionAuditCategory
  public let timestamp: String
  public let details: [String: JSONValue]

  public init(
    recordID: String,
    auditID: String,
    correlationID: String,
    sessionID: String,
    jobID: String,
    category: SessionAuditCategory,
    timestamp: String,
    details: [String: JSONValue]
  ) throws {
    try SessionStorageValidation.identifier(recordID, field: "recordId")
    try SessionStorageValidation.identifier(auditID, field: "auditId")
    try SessionStorageValidation.identifier(correlationID, field: "correlationId")
    try SessionStorageValidation.identifier(sessionID, field: "sessionId")
    try SessionStorageValidation.identifier(jobID, field: "jobId")
    guard timestamp.utf8.count <= Self.maximumTimestampUTF8Bytes else {
      throw SessionStorageError.invalidTimestamp("timestamp exceeds 64 UTF-8 bytes")
    }
    try SessionStorageValidation.timestamp(timestamp, field: "timestamp")
    guard !details.isEmpty,
      try SessionStorageValidation.canonicalData(JSONValue.object(details)).count
        <= Self.maximumCanonicalDetailBytes
    else { throw SessionStorageError.invalidRecord("audit details are empty or exceed 64 KiB") }
    self.recordID = recordID
    self.auditID = auditID
    self.correlationID = correlationID
    self.sessionID = sessionID
    self.jobID = jobID
    self.category = category
    self.timestamp = timestamp
    self.details = details
    guard try SessionAuditCodec.encode(self).count <= Self.maximumCanonicalRecordBytes else {
      throw SessionStorageError.invalidRecord("Session audit record exceeds bound")
    }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case recordID = "recordId"
    case auditID = "auditId"
    case correlationID = "correlationId"
    case sessionID = "sessionId"
    case jobID = "jobId"
    case category, timestamp, details
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: SessionAuditAnyCodingKey.self)
    guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw SessionStorageError.invalidRecord("unknown or missing Session audit field")
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .schemaVersion) == Self.schemaVersion else {
      throw SessionStorageError.invalidRecord("unsupported Session audit schemaVersion")
    }
    try self.init(
      recordID: container.decode(String.self, forKey: .recordID),
      auditID: container.decode(String.self, forKey: .auditID),
      correlationID: container.decode(String.self, forKey: .correlationID),
      sessionID: container.decode(String.self, forKey: .sessionID),
      jobID: container.decode(String.self, forKey: .jobID),
      category: container.decode(SessionAuditCategory.self, forKey: .category),
      timestamp: container.decode(String.self, forKey: .timestamp),
      details: container.decode([String: JSONValue].self, forKey: .details))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(recordID, forKey: .recordID)
    try container.encode(auditID, forKey: .auditID)
    try container.encode(correlationID, forKey: .correlationID)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(jobID, forKey: .jobID)
    try container.encode(category, forKey: .category)
    try container.encode(timestamp, forKey: .timestamp)
    try container.encode(details, forKey: .details)
  }
}

public enum SessionAuditCodec {
  public static func encode(_ record: SessionAuditRecord) throws -> Data {
    try SessionStorageValidation.canonicalData(record)
  }

  public static func decode(_ data: Data) throws -> SessionAuditRecord {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    return try JSONDecoder().decode(SessionAuditRecord.self, from: data)
  }

}

public protocol DurableSessionAuditAppending: Sendable {
  var layout: SessionLayout { get }
  func storageVolumeIdentity(using resolver: any VolumeIdentityResolving) throws -> VolumeIdentity
  func appendAndSynchronize(_ record: SessionAuditRecord) throws
  func replay(correlationID: String) throws -> [SessionAuditRecord]
}

public final class FileDurableSessionAuditStore: DurableSessionAuditAppending, @unchecked Sendable {
  public static let maximumLogBytes = 16 * 1_024 * 1_024
  public static let maximumRecordCount = 65_536

  public let layout: SessionLayout
  public let url: URL
  public let sessionID: String
  public let jobID: String
  private let lock = NSLock()
  private let faultInjector: SessionStorageFaultInjector
  private let rootDescriptor: Int32
  private let rootDevice: dev_t
  private let rootInode: ino_t
  private let auditDirectoryDescriptor: Int32
  private let auditDirectoryDevice: dev_t
  private let auditDirectoryInode: ino_t
  private let descriptorDevice: dev_t
  private let descriptorInode: ino_t
  private let descriptor: Int32
  private var recordFingerprintsByID: [String: String]
  private var durableLength: Int
  private var poisoned = false

  public init(
    layout: SessionLayout,
    faultInjector: SessionStorageFaultInjector = .none
  ) throws {
    self.layout = layout
    let expectedSessionID = layout.sessionID
    let expectedJobID = layout.jobID
    url = layout.sessionAuditURL
    sessionID = layout.sessionID
    jobID = layout.jobID
    self.faultInjector = faultInjector
    recordFingerprintsByID = [:]
    durableLength = 0
    do {
      try SessionStorageValidation.secureDirectory(layout.root)
      try SessionStorageValidation.secureDirectory(url.deletingLastPathComponent())
    } catch {
      throw SessionStorageValidation.storageDomainError(error)
    }

    let openedRoot = Darwin.open(
      layout.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard openedRoot >= 0 else {
      throw SessionStorageError.writeFailed(path: layout.root.path, errno: errno)
    }
    var openedAuditDirectory: Int32 = -1
    var openedDescriptor: Int32 = -1
    do {
      openedAuditDirectory = Darwin.openat(
        openedRoot, "audit", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard openedAuditDirectory >= 0 else {
        throw SessionStorageError.writeFailed(
          path: url.deletingLastPathComponent().path, errno: errno)
      }
      var existingMetadata = stat()
      let existed =
        fstatat(
          openedAuditDirectory, "session.jsonl", &existingMetadata, AT_SYMLINK_NOFOLLOW) == 0
      if !existed, errno != ENOENT {
        throw SessionStorageError.writeFailed(path: url.path, errno: errno)
      }
      openedDescriptor = Darwin.openat(
        openedAuditDirectory, "session.jsonl",
        O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard openedDescriptor >= 0 else {
        throw SessionStorageError.writeFailed(path: url.path, errno: errno)
      }
      guard flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw SessionStorageError.invalidRecord(
          "Session audit already has an active writer:errno=\(errno)")
      }

      let hierarchy = try Self.validateHierarchy(
        rootDescriptor: openedRoot, rootURL: layout.root,
        expectedRootDevice: nil, expectedRootInode: nil,
        auditDirectoryDescriptor: openedAuditDirectory,
        expectedAuditDevice: nil, expectedAuditInode: nil,
        fileDescriptor: openedDescriptor, fileURL: url,
        expectedFileDevice: nil, expectedFileInode: nil)
      if !existed {
        try DurableFilePrimitives.fullSync(openedDescriptor, path: url.path)
        try Self.synchronizeDirectory(openedAuditDirectory, path: url.deletingLastPathComponent())
      }
      var inspection = try Self.scan(
        descriptor: openedDescriptor, url: url,
        expectedSessionID: expectedSessionID, expectedJobID: expectedJobID,
        correlationID: nil)
      if inspection.hasTornTail {
        guard Darwin.ftruncate(openedDescriptor, off_t(inspection.durableLength)) == 0 else {
          throw SessionStorageError.writeFailed(path: url.path, errno: errno)
        }
        try DurableFilePrimitives.fullSync(openedDescriptor, path: url.path)
        try Self.synchronizeDirectory(openedAuditDirectory, path: url.deletingLastPathComponent())
        inspection = try Self.scan(
          descriptor: openedDescriptor, url: url,
          expectedSessionID: expectedSessionID, expectedJobID: expectedJobID,
          correlationID: nil)
      }
      _ = try Self.validateHierarchy(
        rootDescriptor: openedRoot, rootURL: layout.root,
        expectedRootDevice: hierarchy.root.st_dev,
        expectedRootInode: hierarchy.root.st_ino,
        auditDirectoryDescriptor: openedAuditDirectory,
        expectedAuditDevice: hierarchy.auditDirectory.st_dev,
        expectedAuditInode: hierarchy.auditDirectory.st_ino,
        fileDescriptor: openedDescriptor, fileURL: url,
        expectedFileDevice: hierarchy.file.st_dev,
        expectedFileInode: hierarchy.file.st_ino)
      rootDescriptor = openedRoot
      rootDevice = hierarchy.root.st_dev
      rootInode = hierarchy.root.st_ino
      auditDirectoryDescriptor = openedAuditDirectory
      auditDirectoryDevice = hierarchy.auditDirectory.st_dev
      auditDirectoryInode = hierarchy.auditDirectory.st_ino
      descriptor = openedDescriptor
      descriptorDevice = hierarchy.file.st_dev
      descriptorInode = hierarchy.file.st_ino
      recordFingerprintsByID = inspection.fingerprintsByID
      durableLength = inspection.durableLength
    } catch {
      if openedDescriptor >= 0 {
        _ = flock(openedDescriptor, LOCK_UN)
        _ = Darwin.close(openedDescriptor)
      }
      if openedAuditDirectory >= 0 { _ = Darwin.close(openedAuditDirectory) }
      _ = Darwin.close(openedRoot)
      throw SessionStorageValidation.storageDomainError(error)
    }
  }

  public func storageVolumeIdentity(using resolver: any VolumeIdentityResolving) throws
    -> VolumeIdentity
  {
    lock.lock()
    defer { lock.unlock() }
    try validateHierarchy()
    let descriptorIdentity = try resolver.resolve(openFileDescriptor: descriptor)
    let rootIdentity = try resolver.resolve(openFileDescriptor: rootDescriptor)
    guard descriptorIdentity == rootIdentity else {
      throw SessionStorageError.volumeIdentityChanged(
        expected: descriptorIdentity, actual: rootIdentity)
    }
    try validateHierarchy()
    return descriptorIdentity
  }

  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
    Darwin.close(auditDirectoryDescriptor)
    Darwin.close(rootDescriptor)
  }

  public func appendAndSynchronize(_ record: SessionAuditRecord) throws {
    guard record.sessionID == sessionID, record.jobID == jobID else {
      throw SessionStorageError.invalidRecord("Session audit identity mismatch")
    }
    try SessionStorageValidation.mappingDurableFileErrors {
      try faultInjector.check(.auditAppend)
    }
    var data = try SessionAuditCodec.encode(record)
    guard data.count <= SessionAuditRecord.maximumCanonicalRecordBytes else {
      throw SessionStorageError.invalidRecord("Session audit record exceeds bound")
    }
    let fingerprint = Self.fingerprint(data)
    data.append(0x0A)

    lock.lock()
    defer { lock.unlock() }
    guard !poisoned else {
      throw SessionStorageError.invalidRecord("Session audit writer is poisoned")
    }
    try validateHierarchy()
    if let existing = recordFingerprintsByID[record.recordID] {
      guard existing == fingerprint else {
        throw SessionStorageError.invalidRecord("conflicting duplicate audit recordId")
      }
      do {
        // The prior append may have reached page cache before its sync failed. An idempotent retry
        // is successful only after it re-establishes both file and directory durability barriers.
        try faultInjector.check(.auditFileSync)
        try DurableFilePrimitives.fullSync(descriptor, path: url.path)
        try faultInjector.check(.auditDirectorySync)
        try Self.synchronizeDirectory(
          auditDirectoryDescriptor, path: url.deletingLastPathComponent())
        try validateHierarchy()
        return
      } catch {
        throw SessionStorageValidation.storageDomainError(error)
      }
    }
    var currentMetadata = stat()
    guard fstat(descriptor, &currentMetadata) == 0, currentMetadata.st_size == durableLength,
      recordFingerprintsByID.count < Self.maximumRecordCount,
      data.count <= Self.maximumLogBytes - durableLength
    else {
      throw SessionStorageError.invalidRecord("Session audit log exceeds bounded capacity")
    }
    var writeAttempted = false
    do {
      try faultInjector.check(.auditWrite)
      writeAttempted = true
      try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: url.path)
      try faultInjector.check(.auditFileSync)
      try DurableFilePrimitives.fullSync(descriptor, path: url.path)
      try faultInjector.check(.auditDirectorySync)
      try Self.synchronizeDirectory(auditDirectoryDescriptor, path: url.deletingLastPathComponent())
      try validateHierarchy()
      durableLength += data.count
      recordFingerprintsByID[record.recordID] = fingerprint
    } catch {
      if writeAttempted { poisoned = true }
      throw SessionStorageValidation.storageDomainError(error)
    }
  }

  public func replay(correlationID: String) throws -> [SessionAuditRecord] {
    try SessionStorageValidation.identifier(correlationID, field: "correlationId")
    lock.lock()
    defer { lock.unlock() }
    guard !poisoned else {
      throw SessionStorageError.invalidRecord("Session audit writer is poisoned")
    }
    do {
      try validateHierarchy()
      let inspection = try Self.scan(
        descriptor: descriptor, url: url,
        expectedSessionID: sessionID, expectedJobID: jobID,
        correlationID: correlationID)
      guard !inspection.hasTornTail else {
        throw SessionStorageError.invalidRecord("Session audit has a torn tail")
      }
      try validateHierarchy()
      recordFingerprintsByID = inspection.fingerprintsByID
      durableLength = inspection.durableLength
      return inspection.matchingRecords
    } catch {
      throw SessionStorageValidation.storageDomainError(error)
    }
  }

  private func validateHierarchy() throws {
    _ = try Self.validateHierarchy(
      rootDescriptor: rootDescriptor, rootURL: layout.root,
      expectedRootDevice: rootDevice, expectedRootInode: rootInode,
      auditDirectoryDescriptor: auditDirectoryDescriptor,
      expectedAuditDevice: auditDirectoryDevice, expectedAuditInode: auditDirectoryInode,
      fileDescriptor: descriptor, fileURL: url,
      expectedFileDevice: descriptorDevice, expectedFileInode: descriptorInode)
  }

  private static func validateHierarchy(
    rootDescriptor: Int32,
    rootURL: URL,
    expectedRootDevice: dev_t?,
    expectedRootInode: ino_t?,
    auditDirectoryDescriptor: Int32,
    expectedAuditDevice: dev_t?,
    expectedAuditInode: ino_t?,
    fileDescriptor: Int32,
    fileURL: URL,
    expectedFileDevice: dev_t?,
    expectedFileInode: ino_t?
  ) throws -> (root: stat, auditDirectory: stat, file: stat) {
    var root = stat()
    var rootPath = stat()
    var auditDirectory = stat()
    var auditLink = stat()
    var file = stat()
    var fileLink = stat()
    guard fstat(rootDescriptor, &root) == 0, Darwin.lstat(rootURL.path, &rootPath) == 0,
      fstat(auditDirectoryDescriptor, &auditDirectory) == 0,
      fstatat(rootDescriptor, "audit", &auditLink, AT_SYMLINK_NOFOLLOW) == 0,
      fstat(fileDescriptor, &file) == 0,
      fstatat(auditDirectoryDescriptor, "session.jsonl", &fileLink, AT_SYMLINK_NOFOLLOW) == 0,
      root.st_mode & S_IFMT == S_IFDIR, rootPath.st_mode & S_IFMT == S_IFDIR,
      auditDirectory.st_mode & S_IFMT == S_IFDIR, auditLink.st_mode & S_IFMT == S_IFDIR,
      file.st_mode & S_IFMT == S_IFREG, fileLink.st_mode & S_IFMT == S_IFREG,
      root.st_uid == geteuid(), rootPath.st_uid == geteuid(),
      auditDirectory.st_uid == geteuid(), auditLink.st_uid == geteuid(),
      file.st_uid == geteuid(), fileLink.st_uid == geteuid(),
      root.st_nlink >= 1, auditDirectory.st_nlink >= 1, file.st_nlink == 1,
      root.st_dev == rootPath.st_dev, root.st_ino == rootPath.st_ino,
      auditDirectory.st_dev == auditLink.st_dev,
      auditDirectory.st_ino == auditLink.st_ino,
      file.st_dev == fileLink.st_dev, file.st_ino == fileLink.st_ino,
      root.st_dev == auditDirectory.st_dev, auditDirectory.st_dev == file.st_dev,
      expectedRootDevice.map({ root.st_dev == $0 }) ?? true,
      expectedRootInode.map({ root.st_ino == $0 }) ?? true,
      expectedAuditDevice.map({ auditDirectory.st_dev == $0 }) ?? true,
      expectedAuditInode.map({ auditDirectory.st_ino == $0 }) ?? true,
      expectedFileDevice.map({ file.st_dev == $0 }) ?? true,
      expectedFileInode.map({ file.st_ino == $0 }) ?? true
    else {
      throw SessionStorageError.invalidRecord(
        "Session audit descriptor ancestry is no longer bound to \(fileURL.path)")
    }
    return (root, auditDirectory, file)
  }

  private static func synchronizeDirectory(_ descriptor: Int32, path: URL) throws {
    guard Darwin.fsync(descriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: path.path, errno: errno)
    }
  }

  private static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func scan(
    descriptor: Int32,
    url: URL,
    expectedSessionID: String,
    expectedJobID: String,
    correlationID: String?
  ) throws -> (
    fingerprintsByID: [String: String], matchingRecords: [SessionAuditRecord],
    hasTornTail: Bool, durableLength: Int
  ) {
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size >= 0, before.st_size <= Self.maximumLogBytes
    else { throw SessionStorageError.invalidRecord("Session audit file exceeds bounded capacity") }
    let snapshotLength = Int(before.st_size)
    var fingerprints: [String: String] = [:]
    var matching: [SessionAuditRecord] = []
    var line = Data()
    line.reserveCapacity(min(SessionAuditRecord.maximumCanonicalRecordBytes, 64 * 1_024))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var offset = 0
    var lastNewlineOffset = 0
    while offset < snapshotLength {
      let requested = min(buffer.count, snapshotLength - offset)
      let count = Darwin.pread(descriptor, &buffer, requested, off_t(offset))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SessionStorageError.writeFailed(path: url.path, errno: count < 0 ? errno : EIO)
      }
      for byte in buffer[0..<count] {
        offset += 1
        if byte == 0x0A {
          guard !line.isEmpty, line.count <= SessionAuditRecord.maximumCanonicalRecordBytes else {
            throw SessionStorageError.invalidRecord("Session audit record exceeds bound")
          }
          let record = try SessionAuditCodec.decode(line)
          let canonical = try SessionAuditCodec.encode(record)
          guard canonical == line, record.sessionID == expectedSessionID,
            record.jobID == expectedJobID,
            fingerprints.count < Self.maximumRecordCount,
            fingerprints.updateValue(fingerprint(canonical), forKey: record.recordID) == nil
          else { throw SessionStorageError.invalidRecord("invalid durable Session audit record") }
          if correlationID == record.correlationID { matching.append(record) }
          line.removeAll(keepingCapacity: true)
          lastNewlineOffset = offset
        } else {
          guard line.count < SessionAuditRecord.maximumCanonicalRecordBytes else {
            throw SessionStorageError.invalidRecord("Session audit record exceeds bound")
          }
          line.append(byte)
        }
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev,
      before.st_ino == after.st_ino, before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw SessionStorageError.invalidRecord("Session audit changed during replay") }
    let hasTornTail = !line.isEmpty
    return (
      fingerprints, matching, hasTornTail,
      hasTornTail ? lastNewlineOffset : snapshotLength
    )
  }
}

private struct SessionAuditAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
