import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation

package struct RuntimeImportChunk: Codable, Equatable, Sendable {
  let offset: Int
  let byteCount: Int
  let sha256: String
}

package struct RuntimeImportRecord: Codable, Sendable {
  package let schemaVersion: String
  package let importID: String
  package let intent: ArtifactImportIntent
  package let intentFingerprint: String
  package let binding: ArtifactBindingSnapshot
  package let createdAtUTC: String
  package var updatedAtUTC: String
  package var generation: Int
  package var state: String
  package var nextOffset: Int
  package var chunks: [RuntimeImportChunk]
  package var receipt: JSONValue?
  package var validation: [String: JSONValue]?
  package var releaseReceipt: JSONValue?

  package var projection: JSONValue {
    .object(["schemaVersion": .string("arkdeck.import/1"), "importId": .string(importID),
      "importRequestId": .string(intent.importRequestID), "metadata": intent.projection,
      "metadataFingerprint": .string(intentFingerprint), "generation": .string(String(generation)),
      "state": .string(state), "nextOffset": .string(String(nextOffset)),
      "maximumChunkBytes": .string(String(ArtifactImportIntent.maximumChunkBytes)),
      "createdAtUtc": .string(createdAtUTC), "updatedAtUtc": .string(updatedAtUTC),
      "receipt": receipt ?? .null])
  }
}

/// Synchronous owner-local persistence, called only inside RuntimeArtifactStore.
/// Payload bytes precede the durable checkpoint. Recovery truncates an
/// uncommitted suffix before exposing nextOffset and verifies the committed
/// prefix. A timeout never deletes an owner or advances its checkpoint.
package final class RuntimeImportStore: @unchecked Sendable {
  package enum FaultPoint { case afterPartialChunk, afterChunkSync, afterCommitIntent, afterPublication, afterReleaseIntent, afterUnpin }
  package typealias Fault = @Sendable (FaultPoint) throws -> Void
  private let root: URL
  private let fault: Fault
  private var verified: [String: String] = [:]
  private let maximumRecords = 4096
  private let maximumRecordBytes = 4 * 1024 * 1024
  private let maximumChunks = 16_384

  package init(directory: URL, fault: @escaping Fault = { _ in }) throws {
    root = directory; self.fault = fault
    try DurableFilePrimitives.requireAbsoluteFileURL(directory)
    try Self.directory(directory)
    for child in ["records", "identities", "payloads"] { try Self.directory(directory.appending(path: child)) }
  }
  private static func directory(_ url: URL) throws {
    try DurableFilePrimitives.rejectSymbolicLink(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
      st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else { throw error("recordUnreadable", "Import store is not a private Runtime directory") }
  }
  private static func error(_ code: String, _ message: String) -> AgentExecutionControlFailure { .init(code, message) }
  private func validateDirectories() throws {
    for url in [root, root.appending(path: "records"), root.appending(path: "identities"), root.appending(path: "payloads")] {
      var value = stat()
      guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
        value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else {
        throw Self.error("recordUnreadable", "Import directory identity changed")
      }
    }
  }
  private func key(_ request: String) throws -> String {
    guard AgentExecutionIntent.validIdentifier(request) else { throw Self.error("invalidInput", "invalid Import request identity") }
    return SHA256Hex.string(of: Data(request.utf8))
  }
  private func recordURL(_ request: String) throws -> URL { root.appending(path: "records/\(try key(request)).json") }
  package func payloadURL(_ record: RuntimeImportRecord) -> URL { root.appending(path: "payloads/\(record.importID).stage") }

  private func identityURL(_ id: String) throws -> URL {
    guard id.hasPrefix("imp-"), let uuid = UUID(uuidString: String(id.dropFirst(4))),
      "imp-" + uuid.uuidString.lowercased() == id else { throw Self.error("invalidInput", "invalid Import identity") }
    return root.appending(path: "identities/\(id).json")
  }
  private func read(_ url: URL, maximum: Int) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Self.error("recordUnreadable", "Import record cannot be opened") }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
      before.st_nlink == 1, before.st_mode & 0o077 == 0, before.st_size > 0, before.st_size <= maximum else {
      throw Self.error("recordUnreadable", "Import record failed its file or size bound")
    }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let n = Darwin.read(fd, &buffer, buffer.count)
      if n < 0, errno == EINTR { continue }
      guard n >= 0, data.count <= maximum - n else { throw Self.error("recordUnreadable", "Import record read failed") }
      if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
    }
    var after = stat(); var named = stat()
    guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0, named.st_mode & S_IFMT == S_IFREG,
      fingerprint(before) == fingerprint(after), fingerprint(after) == fingerprint(named), data.count == before.st_size else {
      throw Self.error("recordUnreadable", "Import record changed during read")
    }
    return data
  }
  private func exists(_ url: URL) throws -> Bool {
    var value = stat()
    if lstat(url.path, &value) == 0 { return true }
    guard errno == ENOENT else { throw Self.error("recordUnreadable", "Import file identity cannot be read") }
    return false
  }
  private func namedPayload(_ record: RuntimeImportRecord, matches value: stat) throws {
    var named = stat()
    guard lstat(payloadURL(record).path, &named) == 0,
      named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(), named.st_nlink == 1,
      named.st_mode & 0o077 == 0, fingerprint(named) == fingerprint(value) else {
      throw Self.error("recordUnreadable", "Import staging pathname no longer names its verified payload")
    }
  }
  private func decode(_ url: URL) throws -> RuntimeImportRecord {
    let data = try read(url, maximum: maximumRecordBytes)
    let object = try ControlFrameJSON.decodeObject(data, maximumBytes: maximumRecordBytes)
    guard Set(object.keys).isSubset(of: ["schemaVersion", "importID", "intent", "intentFingerprint", "binding", "createdAtUTC", "updatedAtUTC", "generation", "state", "nextOffset", "chunks", "receipt", "validation", "releaseReceipt"]) else {
      throw Self.error("recordUnreadable", "Import record has unknown fields")
    }
    let record = try JSONDecoder().decode(RuntimeImportRecord.self, from: data)
    guard case .object(let intent) = record.intent.projection,
      try ArtifactImportIntent(intent) == record.intent,
      record.schemaVersion == "arkdeck.runtime-import/1", record.intentFingerprint == (try record.intent.fingerprint),
      url.standardizedFileURL.path == (try recordURL(record.intent.importRequestID)).standardizedFileURL.path, record.generation > 0,
      ["inProgress", "committing", "committed", "aborted", "released"].contains(record.state),
      ISO8601Timestamps.parse(record.createdAtUTC) != nil, ISO8601Timestamps.parse(record.updatedAtUTC) != nil,
      record.binding.targetID == record.intent.targetID,
      record.nextOffset >= 0, record.nextOffset <= record.intent.byteCount, record.chunks.count <= maximumChunks,
      (["committed", "released"].contains(record.state)) == (record.receipt != nil),
      (["committing", "committed", "released"].contains(record.state)) == (record.validation != nil),
      (record.state == "released") == (record.releaseReceipt != nil),
      record.validation == nil || record.validation?["kind"] == .string(record.intent.kind)
    else { throw Self.error("recordUnreadable", "Import record failed validation") }
    _ = try identityURL(record.importID)
    _ = try ArtifactImportProjection(record.projection)
    if let release = record.releaseReceipt {
      let receipt = try ArtifactImportReleaseProjection(release)
      guard receipt.importID == record.importID, case .object(let committed)? = record.receipt,
        committed["artifactId"] == .string(receipt.artifactID), committed["lease"] == .string(receipt.lease),
        case .object(let released) = release, released["importRequestId"] == .string(record.intent.importRequestID),
        released["releasedAtUtc"] == .string(record.updatedAtUTC) else {
        throw Self.error("recordUnreadable", "Import release does not match its committed owner")
      }
    }
    var offset = 0
    for chunk in record.chunks {
      guard chunk.offset == offset, (1...ArtifactImportIntent.maximumChunkBytes).contains(chunk.byteCount),
        chunk.byteCount <= record.intent.byteCount - offset, SHA256Hex.isLowercaseSHA256(chunk.sha256) else {
        throw Self.error("recordUnreadable", "Import chunk checkpoint is unreadable")
      }
      offset += chunk.byteCount
    }
    guard offset == record.nextOffset, !["committing", "committed", "released"].contains(record.state) || offset == record.intent.byteCount else {
      throw Self.error("recordUnreadable", "Import checkpoint does not match its state")
    }
    return record
  }
  private func save(_ record: RuntimeImportRecord) throws {
    let bytes = try CanonicalJSONEncoders.canonical().encode(record)
    guard bytes.count <= maximumRecordBytes else { throw Self.error("inputTooLarge", "Import checkpoint exceeds its metadata bound") }
    try DurableFileWriter.createOrReplaceAtomically(destination: recordURL(record.intent.importRequestID), data: bytes)
  }
  private func index(_ record: RuntimeImportRecord) throws {
    let data = try PortableCanonicalJSON.canonicalBytes(.object(["importRequestId": .string(record.intent.importRequestID)]))
    let url = try identityURL(record.importID)
    if try exists(url) {
      guard try read(url, maximum: 1024) == data else { throw Self.error("recordUnreadable", "Import identity mapping changed") }
    } else { try DurableFileWriter.createOrReplaceAtomically(destination: url, data: data) }
  }
  package func visit(_ body: (RuntimeImportRecord) throws -> Void) throws {
    try validateDirectories()
    let entries = try FileManager.default.contentsOfDirectory(at: root.appending(path: "records"), includingPropertiesForKeys: nil)
    let files = try entries.filter { entry in
      if entry.lastPathComponent.hasPrefix("."), entry.pathExtension == "tmp" {
        // Atomic checkpoint writes never publish their temporary name. A
        // killed writer can leave it behind without making it a record.
        var value = stat()
        guard lstat(entry.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
          value.st_uid == geteuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0 else {
          throw Self.error("recordUnreadable", "Import temporary checkpoint is unsafe")
        }
        try FileManager.default.removeItem(at: entry)
        return false
      }
      return true
    }
    guard files.count <= maximumRecords else { throw Self.error("recordUnreadable", "Import store exceeds its record bound") }
    for file in files { try body(decode(file)) }
  }
  package func byRequest(_ request: String) throws -> RuntimeImportRecord? {
    try validateDirectories()
    let url = try recordURL(request)
    guard try exists(url) else { return nil }
    let record = try decode(url); try index(record); try recover(record)
    return record
  }
  package func byID(_ id: String) throws -> RuntimeImportRecord {
    try validateDirectories()
    let url = try identityURL(id)
    if try exists(url) {
      let fields = try ControlFrameJSON.decodeObject(read(url, maximum: 1024), maximumBytes: 1024)
      guard Set(fields.keys) == ["importRequestId"], case .string(let request)? = fields["importRequestId"],
        let record = try byRequest(request), record.importID == id else { throw Self.error("recordUnreadable", "Import identity mapping is unreadable") }
      return record
    }
    var recovered: RuntimeImportRecord?
    try visit { if $0.importID == id { recovered = $0 } }
    guard let record = recovered else { throw Self.error("resourceNotFound", "Import does not exist") }
    try index(record); try recover(record); return record
  }
  package func begin(_ intent: ArtifactImportIntent, binding: ArtifactBindingSnapshot, now: String) throws -> RuntimeImportRecord {
    if let existing = try byRequest(intent.importRequestID) {
      guard existing.intent == intent else { throw Self.error("idempotencyConflict", "Import request identity already names different metadata") }
      return existing
    }
    var count = 0; var staged = 0
    try visit { record in
      count += 1
      if ["inProgress", "committing"].contains(record.state) { staged += record.intent.byteCount }
    }
    guard count < maximumRecords, staged <= 8 * 1024 * 1024 * 1024 - intent.byteCount else {
      throw Self.error("quotaExceeded", "Import staging capacity is exhausted")
    }
    let record = RuntimeImportRecord(schemaVersion: "arkdeck.runtime-import/1", importID: "imp-" + UUID().uuidString.lowercased(),
      intent: intent, intentFingerprint: try intent.fingerprint, binding: binding, createdAtUTC: now, updatedAtUTC: now,
      generation: 1, state: "inProgress", nextOffset: 0, chunks: [], receipt: nil, validation: nil)
    try save(record); try index(record); try recover(record)
    return record
  }
  private func fingerprint(_ value: stat) -> String {
    "\(value.st_dev):\(value.st_ino):\(value.st_gen):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
  }
  private func checkpoint(_ record: RuntimeImportRecord, stat value: stat) throws -> String {
    fingerprint(value) + ":" + SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(record.chunks))
  }
  private func openPayload(_ record: RuntimeImportRecord) throws -> Int32 {
    let url = payloadURL(record)
    if try !exists(url), record.nextOffset == 0 {
      let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw Self.error("recordUnreadable", "Import staging cannot be created") }
      do { try DurableFilePrimitives.fullSync(fd, path: url.path) }
      catch { close(fd); throw error }
      close(fd)
      try DurableFilePrimitives.syncDirectory(url.deletingLastPathComponent())
    }
    let fd = open(url.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Self.error("recordUnreadable", "Import staging is missing or unreadable") }
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
      value.st_nlink == 1, value.st_mode & 0o077 == 0 else {
      close(fd); throw Self.error("recordUnreadable", "Import staging file identity is unsafe")
    }
    return fd
  }
  package func recover(_ record: RuntimeImportRecord) throws {
    if ["aborted", "committed", "released"].contains(record.state) { try removeStaging(record); return }
    let fd = try openPayload(record); defer { close(fd) }
    try verifyPrefix(record, descriptor: fd)
  }
  private func verifyPrefix(_ record: RuntimeImportRecord, descriptor fd: Int32) throws {
    var initial = stat()
    guard fstat(fd, &initial) == 0, initial.st_size >= record.nextOffset else { throw Self.error("recordUnreadable", "Import committed prefix is missing") }
    try namedPayload(record, matches: initial)
    if initial.st_size > record.nextOffset {
      guard ftruncate(fd, off_t(record.nextOffset)) == 0 else {
        throw Self.error("recordUnreadable", "Import uncommitted suffix could not be rolled back")
      }
      try DurableFilePrimitives.fullSync(fd, path: payloadURL(record).path)
      guard fstat(fd, &initial) == 0 else { throw Self.error("recordUnreadable", "Import rollback identity is unreadable") }
      try namedPayload(record, matches: initial)
    }
    let key = try checkpoint(record, stat: initial)
    if verified[record.importID] == key { return }
    for chunk in record.chunks {
      let bytes = try range(fd, offset: chunk.offset, count: chunk.byteCount)
      guard SHA256Hex.string(of: bytes) == chunk.sha256 else { throw Self.error("recordUnreadable", "Import committed prefix failed digest verification") }
    }
    var final = stat()
    guard fstat(fd, &final) == 0, fingerprint(initial) == fingerprint(final) else {
      throw Self.error("recordUnreadable", "Import committed prefix changed during verification")
    }
    try namedPayload(record, matches: final)
    verified[record.importID] = key
  }
  private func range(_ fd: Int32, offset: Int, count: Int) throws -> Data {
    var bytes = Data(count: count)
    try bytes.withUnsafeMutableBytes { buffer in
      var read = 0
      while read < count {
        let n = pread(fd, buffer.baseAddress!.advanced(by: read), count - read, off_t(offset + read))
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw Self.error("recordUnreadable", "Import prefix read failed") }
        read += n
      }
    }
    return bytes
  }
  package func append(id: String, generation: Int, offset: Int, chunk: Data, sha256: String, now: String) throws -> RuntimeImportRecord {
    var record = try byID(id)
    guard generation == record.generation, record.state == "inProgress" else { throw Self.error("resourceConflict", "Import generation or state changed") }
    guard (1...ArtifactImportIntent.maximumChunkBytes).contains(chunk.count), SHA256Hex.string(of: chunk) == sha256 else {
      throw Self.error("artifactIntegrityFailed", "Import chunk size or digest is invalid")
    }
    if offset < record.nextOffset {
      guard record.chunks.contains(.init(offset: offset, byteCount: chunk.count, sha256: sha256)) else {
        throw Self.error("resourceConflict", "Import chunk overlaps different committed bytes")
      }
      return record
    }
    guard offset == record.nextOffset, chunk.count <= record.intent.byteCount - offset else {
      throw Self.error("resourceConflict", "Import chunk does not start at the committed offset")
    }
    guard record.chunks.count < maximumChunks else { throw Self.error("quotaExceeded", "Import upload exceeds its chunk metadata quota") }
    let fd = try openPayload(record); defer { close(fd) }
    try verifyPrefix(record, descriptor: fd)
    let first = max(1, chunk.count / 2)
    try chunk.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let limit = written < first ? first : bytes.count
        let n = pwrite(fd, bytes.baseAddress!.advanced(by: written), limit - written, off_t(offset + written))
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw Self.error("recordUnreadable", "Import append write failed") }
        written += n
        if written == first { try fault(.afterPartialChunk) }
      }
    }
    try DurableFilePrimitives.fullSync(fd, path: payloadURL(record).path)
    try fault(.afterChunkSync)
    record.chunks.append(.init(offset: offset, byteCount: chunk.count, sha256: sha256))
    record.nextOffset += chunk.count; record.updatedAtUTC = now
    // Generation identifies this upload lifetime, not a moving byte offset;
    // otherwise exact retry after a lost append response would conflict.
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_size == record.nextOffset else { throw Self.error("recordUnreadable", "Import append checkpoint is unreadable") }
    try namedPayload(record, matches: value)
    guard SHA256Hex.string(of: try range(fd, offset: offset, count: chunk.count)) == sha256 else {
      throw Self.error("recordUnreadable", "Import appended bytes failed verification")
    }
    var afterRead = stat()
    guard fstat(fd, &afterRead) == 0, fingerprint(value) == fingerprint(afterRead) else {
      throw Self.error("recordUnreadable", "Import appended bytes changed during verification")
    }
    try namedPayload(record, matches: afterRead)
    try save(record)
    verified[id] = try checkpoint(record, stat: afterRead)
    return record
  }
  private func removeStaging(_ record: RuntimeImportRecord) throws {
    let url = payloadURL(record)
    var value = stat()
    if lstat(url.path, &value) != 0, errno == ENOENT { return }
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
      value.st_mode & 0o077 == 0, unlink(url.path) == 0 else {
      throw Self.error("recordUnreadable", "Import staging cleanup could not finish")
    }
    try DurableFilePrimitives.syncDirectory(url.deletingLastPathComponent())
  }

  package func verifiedCompleteFile(_ record: RuntimeImportRecord) throws -> URL {
    guard record.nextOffset == record.intent.byteCount else { throw Self.error("resourceConflict", "Import is incomplete") }
    let fd = try openPayload(record); defer { close(fd) }
    try verifyPrefix(record, descriptor: fd)
    var initial = stat()
    guard fstat(fd, &initial) == 0, initial.st_size == record.intent.byteCount else { throw Self.error("recordUnreadable", "Import payload size changed") }
    var hasher = SHA256(); var offset = 0
    while offset < record.intent.byteCount {
      let count = min(1024 * 1024, record.intent.byteCount - offset)
      hasher.update(data: try range(fd, offset: offset, count: count)); offset += count
    }
    var final = stat(); var named = stat()
    guard fstat(fd, &final) == 0, lstat(payloadURL(record).path, &named) == 0,
      named.st_mode & S_IFMT == S_IFREG, named.st_ino == initial.st_ino, named.st_dev == initial.st_dev,
      fingerprint(initial) == fingerprint(final) else { throw Self.error("recordUnreadable", "Import payload changed during hashing") }
    guard SHA256Hex.hexString(hasher.finalize()) == record.intent.sha256 else { throw Self.error("artifactIntegrityFailed", "Import source digest does not match its metadata") }
    return payloadURL(record)
  }

  package func startCommit(id: String, generation: Int, validation: [String: JSONValue], now: String) throws -> RuntimeImportRecord {
    var record = try byID(id)
    if record.state == "committed", generation == record.generation - 1 { return record }
    guard generation == record.generation, ["inProgress", "committing"].contains(record.state), record.nextOffset == record.intent.byteCount else {
      throw Self.error("resourceConflict", "Import is incomplete or its generation/state changed")
    }
    guard validation["kind"] == .string(record.intent.kind), record.validation == nil || record.validation == validation else {
      throw Self.error("recordUnreadable", "Import commit validation changed")
    }
    if record.state != "committing" {
      record.state = "committing"; record.validation = validation; record.updatedAtUTC = now; try save(record)
    }
    try fault(.afterCommitIntent)
    return record
  }
  package func finishCommit(_ original: RuntimeImportRecord, receipt: JSONValue, now: String) throws -> RuntimeImportRecord {
    try fault(.afterPublication)
    var record = original
    guard record.state == "committing", record.generation < Int.max else { throw Self.error("resourceConflict", "Import commit is not current") }
    record.state = "committed"; record.receipt = receipt; record.generation += 1; record.updatedAtUTC = now
    try save(record)
    verified.removeValue(forKey: record.importID)
    try removeStaging(record)
    return record
  }
  package func release(id: String, generation: Int, deadline: String, now: String) throws -> RuntimeImportRecord {
    var record = try byID(id)
    if record.state == "released", generation == 2 { return record }
    guard record.state == "committed", generation == record.generation, generation == 2,
      case .object(let committed)? = record.receipt else {
      throw Self.error("resourceConflict", "only the exact committed Import generation can be released")
    }
    let receipt: JSONValue = .object(["schemaVersion": .string("arkdeck.import-release/1"),
      "importId": .string(record.importID), "importRequestId": .string(record.intent.importRequestID),
      "owner": .object(["kind": .string("import"), "id": .string(record.importID)]),
      "artifactId": committed["artifactId"]!, "lease": committed["lease"]!,
      "releasedGeneration": .string("2"), "generation": .string("3"), "state": .string("released"),
      "releasedAtUtc": .string(now), "retention": .object(["class": .string("default"), "pinned": .bool(false), "deadlineUtc": .string(deadline)])])
    _ = try ArtifactImportReleaseProjection(receipt)
    record.state = "released"; record.generation = 3; record.updatedAtUTC = now; record.releaseReceipt = receipt
    // Closing the lease is durable before any unpin. A crash can leave an
    // extra pin to finish, never a usable input whose bytes may be collected.
    try save(record)
    try fault(.afterReleaseIntent)
    return record
  }
  package func afterImportUnpin() throws { try fault(.afterUnpin) }

  package func abort(requestID: String, generation: Int, now: String) throws -> RuntimeImportRecord {
    guard var record = try byRequest(requestID) else { throw Self.error("resourceNotFound", "Import does not exist") }
    if record.state == "aborted", generation == record.generation - 1 { try removeStaging(record); return record }
    guard record.state == "inProgress", record.generation == generation, generation < Int.max else {
      throw Self.error("resourceConflict", "Import commit or another generation owns this upload")
    }
    record.state = "aborted"; record.generation += 1; record.updatedAtUTC = now
    try save(record)
    verified.removeValue(forKey: record.importID)
    try removeStaging(record)
    return record
  }
}
