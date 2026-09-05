import ArkDeckCore
import ArkDeckStorage
import Darwin
import Foundation

/// Immutable, private snapshots for bounded resource discovery. Cursors name
/// an unpredictable stored page, never a filesystem offset or a live query.
/// The latest 32 snapshots (up to 64 MiB) survive Runtime restart; a reclaimed
/// snapshot is invalidCursor, never an invitation to restart the query silently.
package final class RuntimeSnapshotPager: @unchecked Sendable {
  private struct Snapshot: Codable {
    let schemaVersion: String
    let revision: String
    let queryDigest: String
    let order: String
    let tokens: [String]
    let pages: [[JSONValue]]
  }

  private let directory: URL
  private static let maximumSnapshotBytes = 16 * 1024 * 1024
  private static let maximumPageBytes = 1024 * 1024

  package init(directory: URL) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(directory)
    try DurableFilePrimitives.rejectSymbolicLink(directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    self.directory = directory
    try validateDirectory()
  }

  private func validateDirectory() throws {
    var status = stat()
    guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else {
      throw AgentExecutionControlFailure("recordUnreadable", "snapshot store is not a private Runtime directory")
    }
  }

  private func file(_ revision: String) -> URL { directory.appending(path: "snapshot-\(revision).json") }

  package func page(
    method: String, filters: [String: JSONValue], order: String, pageSize: Int,
    cursor: String?, items: () throws -> [JSONValue]
  ) throws -> JSONValue {
    guard (1...1000).contains(pageSize) else {
      throw AgentExecutionControlFailure("invalidInput", "pageSize must be between 1 and 1000")
    }
    try validateDirectory()
    let query = try PortableCanonicalJSON.canonicalBytes(.object([
      "method": .string(method), "filters": .object(filters), "order": .string(order),
      "pageSize": .integer(Int64(pageSize)),
    ]))
    let digest = RuntimeAgentExecutionStore.fingerprint(query)
    if let cursor {
      let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
        id.uuidString.lowercased() == parts[0], UUID(uuidString: String(parts[1])) != nil else {
        throw invalidCursor()
      }
      let snapshot = try read(String(parts[0]))
      guard snapshot.queryDigest == digest, snapshot.order == order,
        let index = snapshot.tokens.firstIndex(of: cursor) else { throw invalidCursor() }
      return projection(snapshot, index: index)
    }
    let rows = try items()
    let revision = UUID().uuidString.lowercased()
    var pages: [[JSONValue]] = []
    var current: [JSONValue] = []
    var bytes = 2
    var total = 0
    for row in rows {
      let size = try CanonicalJSONEncoders.canonical().encode(row).count + 1
      guard size <= Self.maximumPageBytes else {
        throw AgentExecutionControlFailure("inputTooLarge", "resource projection exceeds its page bound")
      }
      if current.count == pageSize || bytes + size > Self.maximumPageBytes {
        pages.append(current)
        current = []
        bytes = 2
      }
      total += size
      guard total <= Self.maximumSnapshotBytes else {
        throw AgentExecutionControlFailure("operationUnavailable", "snapshot exceeds its storage bound")
      }
      current.append(row)
      bytes += size
    }
    if !current.isEmpty || pages.isEmpty { pages.append(current) }
    let snapshot = Snapshot(
      schemaVersion: "arkdeck.runtime-snapshot/1", revision: revision, queryDigest: digest,
      order: order, tokens: pages.map { _ in "\(revision).\(UUID().uuidString.lowercased())" }, pages: pages)
    let data = try CanonicalJSONEncoders.canonical().encode(snapshot)
    guard data.count <= Self.maximumSnapshotBytes else {
      throw AgentExecutionControlFailure("operationUnavailable", "snapshot exceeds its encoded storage bound")
    }
    try retainSpace(for: data.count)
    try DurableFileWriter.createOrReplaceAtomically(destination: file(revision), data: data)
    return projection(snapshot, index: 0)
  }

  private func projection(_ snapshot: Snapshot, index: Int) -> JSONValue {
    let more = index + 1 < snapshot.pages.count
    return .object([
      "schemaVersion": .string("arkdeck.cli.page/1"), "pageKind": .string("snapshot"),
      "items": .array(snapshot.pages[index]), "order": .string(snapshot.order),
      "snapshotRevision": .string(snapshot.revision), "hasMore": .bool(more),
      "nextCursor": more ? .string(snapshot.tokens[index + 1]) : .null,
    ])
  }

  private func invalidCursor() -> AgentExecutionControlFailure {
    AgentExecutionControlFailure("invalidCursor", "cursor is invalid, belongs to another query or its snapshot was reclaimed")
  }

  private func read(_ revision: String) throws -> Snapshot {
    let fd = open(file(revision).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0, errno == ENOENT { throw invalidCursor() }
    guard fd >= 0 else { throw AgentExecutionControlFailure("recordUnreadable", "snapshot cannot be opened") }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_mode & 0o077 == 0, status.st_nlink == 1,
      status.st_size > 0, status.st_size <= Self.maximumSnapshotBytes else {
      throw AgentExecutionControlFailure("recordUnreadable", "snapshot failed file identity or size validation")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw AgentExecutionControlFailure("recordUnreadable", "snapshot read failed") }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= Self.maximumSnapshotBytes else {
        throw AgentExecutionControlFailure("recordUnreadable", "snapshot grew beyond its bound")
      }
    }
    do {
      let object = try ControlFrameJSON.decodeObject(data, maximumBytes: Self.maximumSnapshotBytes)
      guard Set(object.keys) == ["schemaVersion", "revision", "queryDigest", "order", "tokens", "pages"] else { throw invalidCursor() }
      let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
      guard snapshot.schemaVersion == "arkdeck.runtime-snapshot/1", snapshot.revision == revision,
        !snapshot.pages.isEmpty, snapshot.pages.count == snapshot.tokens.count,
        Set(snapshot.tokens).count == snapshot.tokens.count,
        snapshot.tokens.allSatisfy({ $0.hasPrefix("\(revision).") }) else { throw invalidCursor() }
      return snapshot
    } catch {
      throw AgentExecutionControlFailure("recordUnreadable", "stored snapshot failed validation")
    }
  }

  private func retainSpace(for bytes: Int) throws {
    let values = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
      .filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.pathExtension == "json" }
    guard values.count <= 32 else {
      throw AgentExecutionControlFailure("recordUnreadable", "snapshot store exceeds its resource bound")
    }
    var records: [(url: URL, size: Int64, modified: Date)] = []
    var total = Int64(bytes)
    for url in values {
      var status = stat()
      guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0,
        status.st_size > 0, status.st_size <= Self.maximumSnapshotBytes else {
        throw AgentExecutionControlFailure("recordUnreadable", "snapshot retention found an unsafe file")
      }
      let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
      records.append((url, status.st_size, date))
      total += status.st_size
    }
    records.sort { $0.modified == $1.modified ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified < $1.modified }
    while records.count >= 32 || total > 64 * 1024 * 1024 {
      let first = records.removeFirst()
      try FileManager.default.removeItem(at: first.url)
      total -= first.size
    }
  }
}
