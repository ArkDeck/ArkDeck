import ArkDeckCore
import Darwin
import Foundation

package struct RuntimeTargetDisplayName: Equatable, Sendable {
  package let targetID: String
  package let generation: UInt64
  package let name: String?
  package let updatedAtUTC: String?

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.target-display-name/1"),
      "targetId": .string(targetID),
      "generation": .string(String(generation)),
      "name": name.map(JSONValue.string) ?? .null,
      "updatedAtUtc": updatedAtUTC.map(JSONValue.string) ?? .null,
    ])
  }
}

package struct RuntimeTargetDisplayNameFailure: Error, Equatable, Sendable {
  package let code: String
  package let message: String

  package init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// A bounded local presentation resource kept outside target identity and
/// alias records. App and CLI reach this owner through the Runtime protocol;
/// neither process writes UserDefaults or the target binding document.
package final class RuntimeTargetDisplayNameStore: @unchecked Sendable {
  private struct Record: Codable, Equatable {
    let targetID: String
    var generation: UInt64
    var name: String?
    var updatedAtUTC: String

    var resource: RuntimeTargetDisplayName {
      .init(
        targetID: targetID, generation: generation, name: name,
        updatedAtUTC: updatedAtUTC)
    }
  }

  private struct Document: Codable, Equatable {
    var schemaVersion = "arkdeck.target-display-names/1"
    var records: [Record] = []
  }

  private static let documentName = "target-display-names.json"
  private static let lockName = ".target-display-names.lock"
  private static let maximumBytes = 512 * 1024
  private static let maximumRecords = 4096

  private let rootURL: URL
  private let nowUTC: @Sendable () -> String

  package init(
    rootURL: URL,
    nowUTC: @escaping @Sendable () -> String = {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.string(from: Date())
    }
  ) {
    self.rootURL = rootURL
    self.nowUTC = nowUTC
  }

  package func read(targetID: String) throws -> RuntimeTargetDisplayName {
    try withLockedDocument { _, document in
      try validateTargetID(targetID)
      return document.records.first(where: { $0.targetID == targetID })?.resource
        ?? RuntimeTargetDisplayName(
          targetID: targetID, generation: 1, name: nil, updatedAtUTC: nil)
    }
  }

  package func read(targetIDs: [String]) throws -> [String: RuntimeTargetDisplayName] {
    guard targetIDs.count <= Self.maximumRecords, Set(targetIDs).count == targetIDs.count else {
      throw RuntimeTargetDisplayNameFailure(
        "invalidInput", "target display-name read contains duplicate or excessive identities")
    }
    return try withLockedDocument { _, document in
      let records = Dictionary(uniqueKeysWithValues: document.records.map { ($0.targetID, $0.resource) })
      return try Dictionary(uniqueKeysWithValues: targetIDs.map { targetID in
        try validateTargetID(targetID)
        return (
          targetID,
          records[targetID]
            ?? RuntimeTargetDisplayName(
              targetID: targetID, generation: 1, name: nil, updatedAtUTC: nil))
      })
    }
  }

  package func set(
    targetID: String, expectedGeneration: UInt64, name: String
  ) throws -> RuntimeTargetDisplayName {
    try validateName(name)
    return try mutate(
      targetID: targetID, expectedGeneration: expectedGeneration, name: name)
  }

  package func clear(
    targetID: String, expectedGeneration: UInt64
  ) throws -> RuntimeTargetDisplayName {
    try mutate(targetID: targetID, expectedGeneration: expectedGeneration, name: nil)
  }

  private func mutate(
    targetID: String, expectedGeneration: UInt64, name: String?
  ) throws -> RuntimeTargetDisplayName {
    try withLockedDocument { root, document in
      try validateTargetID(targetID)
      guard expectedGeneration > 0, expectedGeneration <= UInt64(Int64.max) else {
        throw RuntimeTargetDisplayNameFailure(
          "invalidInput", "expected generation must be a canonical positive integer")
      }
      var document = document
      let index = document.records.firstIndex { $0.targetID == targetID }
      let currentGeneration = index.map { document.records[$0].generation } ?? 1
      guard expectedGeneration == currentGeneration else {
        throw RuntimeTargetDisplayNameFailure(
          "resourceConflict", "target display-name generation changed")
      }
      let next = currentGeneration.addingReportingOverflow(1)
      guard !next.overflow, next.partialValue <= UInt64(Int64.max) else {
        throw RuntimeTargetDisplayNameFailure(
          "resourceConflict", "target display-name generation is exhausted")
      }
      let timestamp = nowUTC()
      guard ISO8601Timestamps.parse(timestamp) != nil else {
        throw RuntimeTargetDisplayNameFailure(
          "recordUnreadable", "target display-name clock is unavailable")
      }
      let record = Record(
        targetID: targetID, generation: next.partialValue, name: name,
        updatedAtUTC: timestamp)
      if let index { document.records[index] = record }
      else {
        guard document.records.count < Self.maximumRecords else {
          throw RuntimeTargetDisplayNameFailure(
            "quotaExceeded", "target display-name resource count exceeds its bound")
        }
        document.records.append(record)
      }
      document.records.sort { $0.targetID.utf8.lexicographicallyPrecedes($1.targetID.utf8) }
      try save(document, root: root)
      return record.resource
    }
  }

  private func withLockedDocument<T>(
    _ body: (Int32, Document) throws -> T
  ) throws -> T {
    let root = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "target display-name directory cannot be opened")
    }
    defer { Darwin.close(root) }
    try validateDirectory(root)
    let lock = Darwin.openat(
      root, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "target display-name lock cannot be opened")
    }
    defer { Darwin.close(lock) }
    try validateRegularFile(lock, label: "target display-name lock")
    while flock(lock, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw RuntimeTargetDisplayNameFailure(
        "resourceConflict", "target display-name lock cannot be acquired")
    }
    defer { _ = flock(lock, LOCK_UN) }
    return try body(root, load(root: root))
  }

  private func load(root: Int32) throws -> Document {
    let descriptor = Darwin.openat(
      root, Self.documentName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT { return Document() }
    guard descriptor >= 0 else {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "target display-name document cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateRegularFile(descriptor, label: "target display-name document")
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_size > 0,
      status.st_size <= Self.maximumBytes
    else {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "target display-name document size is invalid")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < Int(status.st_size) {
      let count = Darwin.read(
        descriptor, &buffer, min(buffer.count, Int(status.st_size) - data.count))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw RuntimeTargetDisplayNameFailure(
          "recordUnreadable", "target display-name document is truncated")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    do {
      let document = try JSONDecoder().decode(Document.self, from: data)
      try validate(document)
      return document
    } catch let failure as RuntimeTargetDisplayNameFailure {
      throw failure
    } catch {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "target display-name document failed schema validation")
    }
  }

  private func save(_ document: Document, root: Int32) throws {
    try validate(document)
    var data = try CanonicalJSONEncoders.canonical().encode(document)
    data.append(0x0A)
    guard data.count <= Self.maximumBytes else {
      throw RuntimeTargetDisplayNameFailure(
        "quotaExceeded", "target display-name document exceeds its byte bound")
    }
    let temporaryName = ".target-display-names.\(UUID().uuidString.lowercased()).part"
    let descriptor = Darwin.openat(
      root, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeTargetDisplayNameFailure(
        "ioFailure", "target display-name transaction cannot be created")
    }
    var descriptorOpen = true
    defer {
      if descriptorOpen { Darwin.close(descriptor) }
      _ = unlinkat(root, temporaryName, 0)
    }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw RuntimeTargetDisplayNameFailure(
          "ioFailure", "target display-name transaction cannot be written")
      }
      offset += count
    }
    guard fchmod(descriptor, 0o600) == 0, Darwin.fsync(descriptor) == 0,
      Darwin.close(descriptor) == 0
    else {
      throw RuntimeTargetDisplayNameFailure(
        "ioFailure", "target display-name transaction cannot be synchronized")
    }
    descriptorOpen = false
    guard renameat(root, temporaryName, root, Self.documentName) == 0,
      Darwin.fsync(root) == 0
    else {
      throw RuntimeTargetDisplayNameFailure(
        "outcomeUnknown", "target display-name publication outcome is unknown")
    }
  }

  private func validate(_ document: Document) throws {
    guard document.schemaVersion == "arkdeck.target-display-names/1",
      document.records.count <= Self.maximumRecords,
      document.records.map(\.targetID)
        == document.records.map(\.targetID).sorted(by: {
          $0.utf8.lexicographicallyPrecedes($1.utf8)
        }),
      Set(document.records.map(\.targetID)).count == document.records.count
    else {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "target display-name index is invalid")
    }
    for record in document.records {
      try validateTargetID(record.targetID)
      guard record.generation >= 2, record.generation <= UInt64(Int64.max),
        ISO8601Timestamps.parse(record.updatedAtUTC) != nil
      else {
        throw RuntimeTargetDisplayNameFailure(
          "recordUnreadable", "target display-name record is invalid")
      }
      if let name = record.name { try validateName(name) }
    }
  }

  private func validateTargetID(_ targetID: String) throws {
    guard AgentExecutionIntent.validIdentifier(targetID) else {
      throw RuntimeTargetDisplayNameFailure(
        "invalidInput", "target display-name requires a valid target identity")
    }
  }

  private func validateName(_ name: String) throws {
    guard name == name.precomposedStringWithCanonicalMapping,
      name == name.trimmingCharacters(in: .whitespacesAndNewlines),
      (1...256).contains(name.utf8.count),
      name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw RuntimeTargetDisplayNameFailure(
        "invalidInput", "display name must be normalized, nonblank text of at most 256 UTF-8 bytes")
    }
  }

  private func validateDirectory(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0
    else {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "target display-name directory is unsafe")
    }
  }

  private func validateRegularFile(_ descriptor: Int32, label: String) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
      status.st_nlink == 1, status.st_mode & 0o077 == 0
    else {
      throw RuntimeTargetDisplayNameFailure(
        "recordUnreadable", "\(label) ownership or permissions are unsafe")
    }
  }
}
