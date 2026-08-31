import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

/// A read-only projection of the existing WAL, never a recovery/admission input.
/// Reads share the writer's publication lock, so a visible line has completed its
/// durability barrier. Paging reads bounded chunks, not a replay of all history.
package enum JournalEventPages {
  private static let maximumRecordBytes = 16 * 1024 * 1024
  private static let maximumPageBytes = 1024 * 1024
  private static let associatedData = Data("arkdeck.job.events.cursor/1:streamPositionAsc".utf8)

  private struct Cursor: Codable {
    let jobID: String
    let device: Int64
    let inode: UInt64
    let generation: UInt32
    let originHash: String
    let offset: Int64
    let position: Int64
    let previousOffset: Int64
    let previousHash: String
    let highWaterPosition: Int64
    let highWaterOffset: Int64
  }

  package static func page(
    directory: URL, jobID: String, sessionID: String,
    afterCursor: String?, pageSize: Int
  ) throws -> JSONValue {
    guard (1...1000).contains(pageSize) else {
      throw AgentExecutionControlFailure("invalidInput", "pageSize must be between 1 and 1000")
    }
    do {
      var directoryMetadata = stat()
      guard lstat(directory.path, &directoryMetadata) == 0,
        directoryMetadata.st_mode & S_IFMT == S_IFDIR,
        directoryMetadata.st_uid == geteuid(), directoryMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
      else { throw unreadable() }
      return try SessionTerminalPublicationLock.withExclusive(in: directory) {
        let key = try cursorKey(directory: directory, resuming: afterCursor != nil)
        let cursor = try afterCursor.map { try decode($0, key: key, jobID: jobID) }
        let url = directory.appending(path: "journal.jsonl")
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw unreadable() }
        defer { Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_uid == geteuid(), metadata.st_nlink == 1,
          metadata.st_mode & (S_IWGRP | S_IWOTH) == 0, metadata.st_size >= 0
        else { throw unreadable() }
        let end = Int64(metadata.st_size)
        var originReader = Reader(fd: fd, offset: 0, limit: end)
        guard let origin = try originReader.next(), origin.event.sequence == 0,
          origin.event.kind == .jobCreated, origin.event.jobID == jobID,
          origin.event.sessionID == sessionID
        else { throw unreadable() }
        let originHash = digest(origin.bytes)
        let tail = try lastCompleteRecord(fd: fd, end: end)
        guard let tail, tail.event.jobID == jobID, tail.event.sessionID == sessionID,
          tail.event.sequence >= 0, tail.event.sequence < Int.max
        else { throw unreadable() }
        let highWater = Int64(tail.event.sequence) + 1
        let durableEnd = tail.end
        var offset: Int64 = 0
        var position: Int64 = 0
        var previousOffset: Int64 = 0
        var previousHash = ""
        if let cursor {
          // There is no independently expiring history cache. A complete Job
          // whose WAL was replaced/truncated is corrupt, not summary-only and
          // not permission to skip to a new origin. No implicit gap recovery.
          guard cursor.device == Int64(metadata.st_dev), cursor.inode == UInt64(metadata.st_ino),
            cursor.generation == metadata.st_gen, cursor.originHash == originHash,
            cursor.highWaterPosition <= highWater, cursor.highWaterOffset <= durableEnd,
            cursor.offset <= durableEnd
          else { throw unreadable() }
          if cursor.position > 0 {
            var prior = Reader(fd: fd, offset: cursor.previousOffset, limit: cursor.offset)
            guard let row = try prior.next(), row.end == cursor.offset,
              row.event.jobID == jobID, row.event.sessionID == sessionID,
              Int64(row.event.sequence) == cursor.position - 1,
              digest(row.bytes) == cursor.previousHash
            else { throw unreadable() }
          }
          offset = cursor.offset
          position = cursor.position
          previousOffset = cursor.previousOffset
          previousHash = cursor.previousHash
        }
        func token() throws -> String {
          try encode(Cursor(
            jobID: jobID, device: Int64(metadata.st_dev), inode: UInt64(metadata.st_ino),
            generation: metadata.st_gen, originHash: originHash, offset: offset,
            position: position, previousOffset: previousOffset, previousHash: previousHash,
            highWaterPosition: highWater, highWaterOffset: durableEnd), key: key)
        }
        var reader = Reader(fd: fd, offset: offset, limit: durableEnd)
        var items: [JSONValue] = []
        var bytes = 0
        var identities: Set<String> = []
        while items.count < pageSize, let row = try reader.next() {
          guard row.event.jobID == jobID, row.event.sessionID == sessionID,
            Int64(row.event.sequence) == position,
            identities.insert(row.event.eventID).inserted
          else { throw unreadable() }
          guard let type = JobEventProjectionContract.eventType(forJournalKind: row.event.kind.rawValue) else {
            throw unreadable()
          }
          let projection = try project(row.event)
          // Each metadata-only item is bounded independently of raw payload.
          // Stop before the response cap; a nonempty page always advances.
          let estimate = try PortableCanonicalJSON.canonicalBytes(projection).count + 2048
          if !items.isEmpty && bytes + estimate > maximumPageBytes { break }
          previousOffset = offset
          previousHash = digest(row.bytes)
          offset = row.end
          position += 1
          items.append(.object([
            "eventId": .string(row.event.eventID), "streamPosition": .string(String(position)),
            "runtimeRevision": .string(String(highWater)), "cursor": .string(try token()),
            "type": .string(type),
            "data": projection,
          ]))
          bytes += estimate
        }
        guard position <= highWater, (offset < durableEnd) == (position < highWater) else {
          throw unreadable()
        }
        return .object([
          "schemaVersion": .string("arkdeck.cli.page/1"), "pageKind": .string("eventStream"),
          "items": .array(items), "order": .string("streamPositionAsc"),
          "snapshotRevision": .string(String(highWater)), "hasMore": .bool(offset < durableEnd),
          "nextCursor": .string(try token()),
        ])
      }
    } catch let error as AgentExecutionControlFailure { throw error }
    catch { throw unreadable() }
  }

  private static func project(_ event: JournalEvent) throws -> JSONValue {
    // No arbitrary payload, reason prose, executable, path, output or inputs.
    guard [event.eventID, event.jobID, event.sessionID, event.timestamp, event.stepID ?? ""]
      .allSatisfy({ $0.utf8.count <= 512 }), event.sequence >= 0
    else { throw unreadable() }
    var data: [String: JSONValue] = [
      "jobId": .string(event.jobID), "sessionId": .string(event.sessionID),
      "journalKind": .string(event.kind.rawValue), "timestamp": .string(event.timestamp),
      "stepId": event.stepID.map(JSONValue.string) ?? .null,
      "attempt": event.attempt.map { .string(String($0)) } ?? .null,
      "bindingRevision": event.bindingRevision.map { .string(String($0)) } ?? .null,
    ]
    if let transition = event.stateTransition {
      data["fromState"] = .string(transition.from.rawValue)
      data["toState"] = .string(transition.to.rawValue)
    }
    return .object(data)
  }

  private struct Row {
    let bytes: Data
    let end: Int64
    let event: JournalEvent
  }

  /// At most one journal record plus a 64 KiB read buffer is retained. A torn
  /// final line is withheld until completed; a malformed completed line fails.
  private struct Reader {
    let fd: Int32
    var offset: Int64
    let limit: Int64
    private var buffer = Data()
    private var consumed = 0
    private var readOffset: Int64

    init(fd: Int32, offset: Int64, limit: Int64) {
      self.fd = fd; self.offset = offset; self.limit = limit; self.readOffset = offset
    }

    mutating func next() throws -> Row? {
      var line = Data()
      while true {
        if consumed < buffer.count {
          let remaining = buffer[consumed...]
          let newline = remaining.firstIndex(of: 10)
          let end = newline ?? buffer.endIndex
          guard line.count + end - consumed <= maximumRecordBytes else { throw unreadable() }
          line.append(buffer[consumed..<end])
          offset += Int64(end - consumed)
          consumed = end
          if newline != nil {
            consumed += 1; offset += 1
            guard !line.isEmpty else { throw unreadable() }
            return Row(bytes: line, end: offset, event: try JournalEventCodec.decode(line))
          }
        }
        guard readOffset < limit else { return nil }
        buffer = try read(fd: fd, offset: readOffset, count: Int(min(65536, limit - readOffset)))
        readOffset += Int64(buffer.count)
        consumed = 0
      }
    }
  }

  private static func lastCompleteRecord(fd: Int32, end: Int64) throws -> Row? {
    var start = end
    var lastLF: Int64?
    while start > 0 {
      let count = Int(min(65536, start))
      start -= Int64(count)
      let chunk = try read(fd: fd, offset: start, count: count)
      guard end - start <= maximumRecordBytes * 2 + 65536 else { throw unreadable() }
      for index in chunk.indices.reversed() where chunk[index] == 10 {
        if let lastLF {
          let recordStart = start + Int64(index) + 1
          let length = lastLF - recordStart
          guard length > 0, length <= maximumRecordBytes else { throw unreadable() }
          let line = try read(fd: fd, offset: recordStart, count: Int(length))
          return Row(bytes: line, end: lastLF + 1, event: try JournalEventCodec.decode(line))
        }
        lastLF = start + Int64(index)
      }
    }
    guard let lastLF else { return nil }
    guard lastLF > 0, lastLF <= maximumRecordBytes else { throw unreadable() }
    let line = try read(fd: fd, offset: 0, count: Int(lastLF))
    return Row(bytes: line, end: lastLF + 1, event: try JournalEventCodec.decode(line))
  }

  private static func read(fd: Int32, offset: Int64, count: Int) throws -> Data {
    var data = Data(count: count)
    var readCount = 0
    while readCount < count {
      let n = data.withUnsafeMutableBytes {
        Darwin.pread(fd, $0.baseAddress!.advanced(by: readCount), count - readCount, off_t(offset) + off_t(readCount))
      }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { throw unreadable() }
      readCount += n
    }
    return data
  }

  private static func cursorKey(directory: URL, resuming: Bool) throws -> SymmetricKey {
    let url = directory.appending(path: "event-cursor-key.v1")
    let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      guard errno == ENOENT else { throw unreadable() }
      guard !resuming else { throw invalidCursor() }
      let key = SymmetricKey(size: .bits256)
      try DurableFileWriter.createOrReplaceAtomically(destination: url, data: key.withUnsafeBytes { Data($0) })
      return key
    }
    defer { Darwin.close(fd) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & 0o777 == 0o600, metadata.st_size == 32
    else { throw unreadable() }
    return SymmetricKey(data: try read(fd: fd, offset: 0, count: 32))
  }

  private static func encode(_ cursor: Cursor, key: SymmetricKey) throws -> String {
    let bytes = try JSONEncoder().encode(cursor)
    let sealed = try AES.GCM.seal(bytes, using: key, authenticating: associatedData)
    guard let combined = sealed.combined else { throw unreadable() }
    return "jec1." + combined.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  private static func decode(_ text: String, key: SymmetricKey, jobID: String) throws -> Cursor {
    do {
      guard text.hasPrefix("jec1."), text.utf8.count <= 2048 else { throw invalidCursor() }
      let encoded = String(text.dropFirst(5))
      guard !encoded.isEmpty, encoded.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
      }) else { throw invalidCursor() }
      let base = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      guard let combined = Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)),
        combined.base64EncodedString().replacingOccurrences(of: "=", with: "") == base
      else { throw invalidCursor() }
      let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: associatedData)
      let cursor = try JSONDecoder().decode(Cursor.self, from: bytes)
      guard cursor.jobID == jobID, cursor.offset >= 0, cursor.position >= 0,
        cursor.highWaterPosition >= cursor.position, cursor.highWaterOffset >= cursor.offset,
        cursor.previousOffset >= 0, cursor.previousOffset <= cursor.offset,
        (cursor.position == 0) == (cursor.offset == 0)
      else { throw invalidCursor() }
      return cursor
    } catch { throw invalidCursor() }
  }

  private static func digest(_ data: Data) -> String { SHA256Hex.string(of: data) }
  private static func unreadable() -> AgentExecutionControlFailure {
    .init("recordUnreadable", "the retained Job event history or cursor key is unreadable; no history was skipped")
  }
  private static func invalidCursor() -> AgentExecutionControlFailure {
    .init("invalidCursor", "the opaque cursor does not belong to this Job event stream")
  }
}
