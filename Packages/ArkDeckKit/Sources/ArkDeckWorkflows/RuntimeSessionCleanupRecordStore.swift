import ArkDeckCore
import ArkDeckStorage
import Darwin
import Foundation

package final class RuntimeSessionCleanupRecordStore: @unchecked Sendable {
  package enum State: String, Codable, Sendable {
    case ready
    case applying
    case applied
  }

  package struct Record: Codable, Sendable {
    let schemaVersion: String
    let previewID: String
    let previewDigest: String
    let expiresAtUTC: String
    var state: State
    let preview: JSONValue
    var result: JSONValue
  }

  private static let maximumRecordBytes = 16 * 1_024 * 1_024
  private static let maximumRecordCount = 64
  private let directory: URL

  package init(directory: URL) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(directory)
    try DurableFilePrimitives.rejectSymbolicLink(directory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.directory = directory.standardizedFileURL
    try validateDirectory()
  }

  package func create(
    previewID: String,
    previewDigest: String,
    expiresAtUTC: String,
    preview: JSONValue,
    now: Date
  ) throws {
    try validateIdentity(previewID, digest: previewDigest, expiry: expiresAtUTC)
    try retainSpace(now: now)
    var metadata = stat()
    let destination = file(previewID)
    guard lstat(destination.path, &metadata) != 0, errno == ENOENT else {
      throw RuntimeSessionStorageFailure(
        "resourceConflict", "Session cleanup preview identity already exists")
    }
    try save(
      Record(
        schemaVersion: "arkdeck.session-cleanup-record/1",
        previewID: previewID, previewDigest: previewDigest,
        expiresAtUTC: expiresAtUTC, state: .ready,
        preview: preview, result: .null))
  }

  package func load(_ previewID: String) throws -> Record {
    guard canonicalUUID(previewID) else {
      throw RuntimeSessionStorageFailure("invalidInput", "cleanup preview identity is malformed")
    }
    let descriptor = Darwin.open(
      file(previewID).path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT {
      throw RuntimeSessionStorageFailure(
        "resourceNotFound", "Session cleanup preview is not present")
    }
    guard descriptor >= 0 else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup preview cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & 0o077 == 0,
      metadata.st_size > 0, metadata.st_size <= Self.maximumRecordBytes
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup preview failed file validation")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session cleanup preview read failed")
      }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= Self.maximumRecordBytes else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session cleanup preview exceeds its byte bound")
      }
    }
    do {
      let payload = data.last == 0x0A ? Data(data.dropLast()) : data
      let object = try ControlProtocolNegotiation.decodeObject(
        payload, maximumBytes: Self.maximumRecordBytes)
      guard Set(object.keys) == [
        "schemaVersion", "previewID", "previewDigest", "expiresAtUTC", "state",
        "preview", "result",
      ] else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session cleanup preview schema drifted")
      }
      let record = try JSONDecoder().decode(Record.self, from: data)
      try validate(record)
      var canonical = try CanonicalJSONEncoders.canonical().encode(record)
      canonical.append(0x0A)
      guard canonical == data, record.previewID == previewID else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session cleanup preview is not canonical")
      }
      return record
    } catch let failure as RuntimeSessionStorageFailure {
      throw failure
    } catch {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup preview failed decoding")
    }
  }

  package func markApplying(_ record: Record) throws -> Record {
    guard record.state == .ready, record.result == .null else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup preview transition is invalid")
    }
    var updated = record
    updated.state = .applying
    try save(updated)
    return updated
  }

  package func markApplied(_ record: Record, result: JSONValue) throws -> Record {
    guard record.state == .applying, record.result == .null else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup result transition is invalid")
    }
    var updated = record
    updated.state = .applied
    updated.result = result
    try save(updated)
    return updated
  }

  package func restoreReady(_ record: Record) throws -> Record {
    guard record.state == .applying, record.result == .null else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup retry transition is invalid")
    }
    var updated = record
    updated.state = .ready
    try save(updated)
    return updated
  }

  private func file(_ previewID: String) -> URL {
    directory.appending(path: "cleanup-\(previewID).json")
  }

  private func save(_ record: Record) throws {
    try validate(record)
    var data = try CanonicalJSONEncoders.canonical().encode(record)
    data.append(0x0A)
    guard data.count <= Self.maximumRecordBytes else {
      throw RuntimeSessionStorageFailure(
        "quotaExceeded", "Session cleanup preview exceeds its byte bound")
    }
    do {
      try DurableFileWriter.createOrReplaceAtomically(
        destination: file(record.previewID), data: data)
    } catch {
      throw RuntimeSessionStorageFailure(
        "outcomeUnknown", "Session cleanup record publication is uncertain")
    }
  }

  private func validate(_ record: Record) throws {
    guard record.schemaVersion == "arkdeck.session-cleanup-record/1" else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup record version is unsupported")
    }
    try validateIdentity(
      record.previewID, digest: record.previewDigest, expiry: record.expiresAtUTC)
    guard case .object(let previewFields) = record.preview,
      previewFields["previewId"] == .string(record.previewID),
      previewFields["previewDigest"] == .string(record.previewDigest),
      previewFields["expiresAtUtc"] == .string(record.expiresAtUTC),
      (record.state == .applied) == (record.result != .null)
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup record identity is inconsistent")
    }
  }

  private func validateIdentity(
    _ previewID: String, digest: String, expiry: String
  ) throws {
    guard canonicalUUID(previewID), SHA256Hex.isLowercaseSHA256(digest),
      ISO8601Timestamps.parseCanonicalPlain(expiry) != nil
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup record identity is malformed")
    }
  }

  private func canonicalUUID(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value) else { return false }
    return uuid.uuidString.lowercased() == value
  }

  private func validateDirectory() throws {
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup store is not a private Runtime directory")
    }
  }

  private func retainSpace(now: Date) throws {
    try validateDirectory()
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [])
    guard files.count <= Self.maximumRecordCount else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup store exceeds its resource bound")
    }
    let descriptor = Darwin.open(
      directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeSessionStorageFailure(
        "ioFailure", "Session cleanup store cannot be synchronized")
    }
    defer { Darwin.close(descriptor) }
    var retained = 0
    for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let name = url.lastPathComponent
      guard name.hasPrefix("cleanup-"), name.hasSuffix(".json") else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session cleanup store contains an unknown record")
      }
      let id = String(name.dropFirst("cleanup-".count).dropLast(".json".count))
      let record = try load(id)
      let expired = ISO8601Timestamps.parseCanonicalPlain(record.expiresAtUTC)
        .map { $0 <= now } ?? false
      if expired && record.state != .applying {
        guard Darwin.unlinkat(descriptor, name, 0) == 0, Darwin.fsync(descriptor) == 0 else {
          throw RuntimeSessionStorageFailure(
            "ioFailure", "Session cleanup record retention failed")
        }
      } else {
        retained += 1
      }
    }
    guard retained < Self.maximumRecordCount else {
      throw RuntimeSessionStorageFailure(
        "quotaExceeded", "Session cleanup preview capacity is exhausted")
    }
  }
}
