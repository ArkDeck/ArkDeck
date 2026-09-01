import ArkDeckCore
import Darwin
import Foundation

/// The complete query represented by History's one saved local preset.
///
/// Every enum-like field is validated by the Runtime owner before it is
/// persisted. Optional Session and target identities mean "all"; the App's
/// historical private sentinel strings never cross this contract.
public struct RuntimeHistoryFilterQuery: Codable, Equatable, Sendable {
  public let search: String
  public let status: String
  public let mode: String
  public let sessionID: String?
  public let targetID: String?
  public let timeRange: String
  public let activity: String

  public init(
    search: String = "",
    status: String = "all",
    mode: String = "all",
    sessionID: String? = nil,
    targetID: String? = nil,
    timeRange: String = "anyTime",
    activity: String = "all"
  ) {
    self.search = search
    self.status = status
    self.mode = mode
    self.sessionID = sessionID
    self.targetID = targetID
    self.timeRange = timeRange
    self.activity = activity
  }

  package var projection: JSONValue {
    .object([
      "search": .string(search),
      "status": .string(status),
      "mode": .string(mode),
      "sessionId": sessionID.map(JSONValue.string) ?? .null,
      "targetId": targetID.map(JSONValue.string) ?? .null,
      "timeRange": .string(timeRange),
      "activity": .string(activity),
    ])
  }
}

/// One versioned local resource. A nil query is the durable empty/tombstone
/// state; its generation still advances so delete followed by save cannot
/// reuse an old generation.
public struct RuntimeHistoryFilterResource: Equatable, Sendable {
  public let generation: UInt64
  public let query: RuntimeHistoryFilterQuery?
  public let updatedAtUTC: String?

  public init(
    generation: UInt64,
    query: RuntimeHistoryFilterQuery?,
    updatedAtUTC: String?
  ) {
    self.generation = generation
    self.query = query
    self.updatedAtUTC = updatedAtUTC
  }

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.history-filter/1"),
      "generation": .string(String(generation)),
      "query": query.map(\.projection) ?? .null,
      "updatedAtUtc": updatedAtUTC.map(JSONValue.string) ?? .null,
    ])
  }

  package var listProjection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.history-filter-list/1"),
      "generation": .string(String(generation)),
      "filters": .array(query == nil ? [] : [projection]),
      "updatedAtUtc": updatedAtUTC.map(JSONValue.string) ?? .null,
    ])
  }
}

public struct RuntimeHistoryFilterFailure: Error, Equatable, Sendable {
  public let code: String
  public let message: String

  package init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// Runtime-owned persistence for History's one saved query preset.
///
/// The file is bounded, owner-only, symlink-resistant and published with an
/// atomic rename under a process lock. App and CLI can only reach it through
/// typed control methods; neither knows its path.
public final class RuntimeHistoryFilterStore: @unchecked Sendable {
  private struct Document: Codable, Equatable {
    var schemaVersion = "arkdeck.history-filter-store/1"
    var generation: UInt64 = 1
    var query: RuntimeHistoryFilterQuery?
    var updatedAtUTC: String?
  }

  private static let documentName = "history-filter.json"
  private static let lockName = ".history-filter.lock"
  private static let maximumBytes = 64 * 1024
  private static let maximumSearchBytes = 512
  private static let maximumIdentifierBytes = 256
  private static let statuses: Set<String> = [
    "all", "active", "needsAttention", "succeeded", "failed", "interrupted", "cancelled",
  ]
  private static let modes: Set<String> = ["all", "execute", "planned", "simulated", "unknown"]
  private static let timeRanges: Set<String> = ["anyTime", "lastHour", "lastDay", "lastWeek"]
  private static let activities: Set<String> = [
    "all", "flash", "viewer", "trace", "diagnostics", "debug", "device", "other",
  ]

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

  package func read() throws -> RuntimeHistoryFilterResource {
    try withLockedDocument { _, document in resource(document) }
  }

  package func save(
    expectedGeneration: UInt64,
    query: RuntimeHistoryFilterQuery
  ) throws -> RuntimeHistoryFilterResource {
    try validate(query)
    return try mutate(expectedGeneration: expectedGeneration, query: query)
  }

  package func delete(
    expectedGeneration: UInt64
  ) throws -> RuntimeHistoryFilterResource {
    try withLockedDocument { root, loaded in
      guard loaded.query != nil else {
        throw RuntimeHistoryFilterFailure(
          "resourceNotFound", "no saved History filter exists")
      }
      return try publishMutation(
        root: root, loaded: loaded,
        expectedGeneration: expectedGeneration, query: nil)
    }
  }

  private func mutate(
    expectedGeneration: UInt64,
    query: RuntimeHistoryFilterQuery?
  ) throws -> RuntimeHistoryFilterResource {
    try withLockedDocument { root, loaded in
      try publishMutation(
        root: root, loaded: loaded,
        expectedGeneration: expectedGeneration, query: query)
    }
  }

  private func publishMutation(
    root: Int32,
    loaded: Document,
    expectedGeneration: UInt64,
    query: RuntimeHistoryFilterQuery?
  ) throws -> RuntimeHistoryFilterResource {
    guard expectedGeneration > 0, expectedGeneration <= UInt64(Int64.max) else {
      throw RuntimeHistoryFilterFailure(
        "invalidInput", "expected generation must be a canonical positive integer")
    }
    guard loaded.generation == expectedGeneration else {
      throw RuntimeHistoryFilterFailure(
        "resourceConflict", "History filter generation changed")
    }
    let next = loaded.generation.addingReportingOverflow(1)
    guard !next.overflow, next.partialValue <= UInt64(Int64.max) else {
      throw RuntimeHistoryFilterFailure(
        "resourceConflict", "History filter generation is exhausted")
    }
    let timestamp = nowUTC()
    guard ISO8601Timestamps.parse(timestamp) != nil else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter clock is unavailable")
    }
    let document = Document(
      generation: next.partialValue, query: query, updatedAtUTC: timestamp)
    try save(document, root: root)
    return resource(document)
  }

  private func resource(_ document: Document) -> RuntimeHistoryFilterResource {
    RuntimeHistoryFilterResource(
      generation: document.generation,
      query: document.query,
      updatedAtUTC: document.updatedAtUTC)
  }

  private func withLockedDocument<T>(
    _ body: (Int32, Document) throws -> T
  ) throws -> T {
    let root = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter directory cannot be opened")
    }
    defer { Darwin.close(root) }
    try validateDirectory(root)
    let lock = Darwin.openat(
      root, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter lock cannot be opened")
    }
    defer { Darwin.close(lock) }
    try validateRegularFile(lock, label: "History filter lock")
    while flock(lock, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw RuntimeHistoryFilterFailure(
        "resourceConflict", "History filter lock cannot be acquired")
    }
    defer { _ = flock(lock, LOCK_UN) }
    return try body(root, load(root: root))
  }

  private func load(root: Int32) throws -> Document {
    let descriptor = Darwin.openat(
      root, Self.documentName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT { return Document() }
    guard descriptor >= 0 else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter document cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateRegularFile(descriptor, label: "History filter document")
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_size > 0,
      status.st_size <= Self.maximumBytes
    else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter document size is invalid")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < Int(status.st_size) {
      let count = Darwin.read(
        descriptor, &buffer, min(buffer.count, Int(status.st_size) - data.count))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw RuntimeHistoryFilterFailure(
          "recordUnreadable", "History filter document is truncated")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    do {
      let document = try JSONDecoder().decode(Document.self, from: data)
      try validate(document)
      return document
    } catch let failure as RuntimeHistoryFilterFailure {
      throw failure
    } catch {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter document failed schema validation")
    }
  }

  private func save(_ document: Document, root: Int32) throws {
    try validate(document)
    var data = try CanonicalJSONEncoders.canonical().encode(document)
    data.append(0x0A)
    guard data.count <= Self.maximumBytes else {
      throw RuntimeHistoryFilterFailure(
        "quotaExceeded", "History filter document exceeds its byte bound")
    }
    let temporaryName = ".history-filter.\(UUID().uuidString.lowercased()).part"
    let descriptor = Darwin.openat(
      root, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeHistoryFilterFailure(
        "ioFailure", "History filter transaction cannot be created")
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
        throw RuntimeHistoryFilterFailure(
          "ioFailure", "History filter transaction cannot be written")
      }
      offset += count
    }
    guard fchmod(descriptor, 0o600) == 0, Darwin.fsync(descriptor) == 0,
      Darwin.close(descriptor) == 0
    else {
      throw RuntimeHistoryFilterFailure(
        "ioFailure", "History filter transaction cannot be synchronized")
    }
    descriptorOpen = false
    guard renameat(root, temporaryName, root, Self.documentName) == 0,
      Darwin.fsync(root) == 0
    else {
      throw RuntimeHistoryFilterFailure(
        "outcomeUnknown", "History filter publication outcome is unknown")
    }
  }

  private func validate(_ document: Document) throws {
    guard document.schemaVersion == "arkdeck.history-filter-store/1",
      document.generation > 0, document.generation <= UInt64(Int64.max),
      document.generation > 1 || document.query == nil,
      (document.updatedAtUTC == nil) == (document.generation == 1),
      document.updatedAtUTC.map({ ISO8601Timestamps.parse($0) != nil }) ?? true
    else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter record is invalid")
    }
    if let query = document.query { try validate(query) }
  }

  private func validate(_ query: RuntimeHistoryFilterQuery) throws {
    guard query.search == query.search.precomposedStringWithCanonicalMapping,
      query.search.utf8.count <= Self.maximumSearchBytes,
      query.search.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0) || $0 == "\t"
      }),
      Self.statuses.contains(query.status),
      Self.modes.contains(query.mode),
      Self.timeRanges.contains(query.timeRange),
      Self.activities.contains(query.activity)
    else {
      throw RuntimeHistoryFilterFailure(
        "invalidInput", "History filter query contains an unsupported value")
    }
    try validateOptionalIdentifier(query.sessionID, label: "session")
    try validateOptionalIdentifier(query.targetID, label: "target")
  }

  private func validateOptionalIdentifier(_ value: String?, label: String) throws {
    guard let value else { return }
    guard value == value.precomposedStringWithCanonicalMapping,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      (1...Self.maximumIdentifierBytes).contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw RuntimeHistoryFilterFailure(
        "invalidInput", "History filter \(label) must be one bounded identity")
    }
  }

  private func validateDirectory(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0
    else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "History filter directory is unsafe")
    }
  }

  private func validateRegularFile(_ descriptor: Int32, label: String) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
      status.st_nlink == 1, status.st_mode & 0o077 == 0
    else {
      throw RuntimeHistoryFilterFailure(
        "recordUnreadable", "\(label) ownership or permissions are unsafe")
    }
  }
}
