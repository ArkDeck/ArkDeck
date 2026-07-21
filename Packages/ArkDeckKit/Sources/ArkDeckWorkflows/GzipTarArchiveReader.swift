import Compression
import CryptoKit
import Foundation

// TASK-RF-002. Streaming `images.tar.gz` inventory for REQ-FLASH-003 validation.
// Implemented in-process on purpose: the CLI must never spawn an external tool to read an
// unvalidated archive, and hashing must be streaming (REQ-FLASH-011) because the pinned
// archive holds multi-gigabyte members.

public enum GzipTarArchiveReaderError: Error, Equatable, Sendable {
  case unreadableFile(String)
  case notGzip
  case unsupportedCompressionMethod
  case corruptGzipHeader
  case decompressionFailed
  case truncatedArchive
  case corruptTarHeader(String)
}

public struct GzipTarMemberSummary: Equatable, Sendable {
  public let name: String
  public let sizeBytes: Int64
  public let sha256: String
}

public struct GzipTarArchiveSummary: Equatable, Sendable {
  public let archiveSizeBytes: Int64
  public let archiveSHA256: String
  public let members: [GzipTarMemberSummary]

  public func archiveObservation() -> RockchipImagesArchiveObservation {
    RockchipImagesArchiveObservation(
      archiveSizeBytes: archiveSizeBytes,
      archiveSHA256: archiveSHA256,
      members: members.map {
        RockchipArchiveMemberObservation(name: $0.name, sizeBytes: $0.sizeBytes, sha256: $0.sha256)
      })
  }
}

public enum GzipTarArchiveReader {
  static let chunkSizeBytes = 1 << 20
  /// Any sane gzip header (fixed part plus optional name/comment/extra) fits well within
  /// this bound; exceeding it is treated as corruption rather than buffered indefinitely.
  static let maximumGzipHeaderBytes = 1 << 16

  public static func summarize(fileAt url: URL) throws -> GzipTarArchiveSummary {
    let fileHandle: FileHandle
    do {
      fileHandle = try FileHandle(forReadingFrom: url)
    } catch {
      throw GzipTarArchiveReaderError.unreadableFile(url.path)
    }
    defer { try? fileHandle.close() }

    var archiveHasher = SHA256()
    var archiveSizeBytes: Int64 = 0
    var headerPending = Data()
    var headerConsumed = false
    let decompressor = try RawDeflateDecompressor()
    var tar = TarStreamSummarizer()

    while true {
      let chunk = (try? fileHandle.read(upToCount: chunkSizeBytes)) ?? nil
      guard let chunk, !chunk.isEmpty else { break }
      archiveHasher.update(data: chunk)
      archiveSizeBytes += Int64(chunk.count)

      var deflatePayload = chunk
      if !headerConsumed {
        headerPending.append(chunk)
        guard let headerLength = try Self.gzipHeaderLength(of: headerPending) else {
          guard headerPending.count <= maximumGzipHeaderBytes else {
            throw GzipTarArchiveReaderError.corruptGzipHeader
          }
          continue
        }
        headerConsumed = true
        deflatePayload = headerPending.subdata(in: headerLength..<headerPending.count)
        headerPending = Data()
      }
      try decompressor.feed(deflatePayload, finalize: false) { produced in
        try tar.consume(produced)
      }
    }

    guard headerConsumed else {
      throw headerPending.isEmpty
        ? GzipTarArchiveReaderError.unreadableFile(url.path)
        : GzipTarArchiveReaderError.corruptGzipHeader
    }
    try decompressor.feed(Data(), finalize: true) { produced in
      try tar.consume(produced)
    }
    let members = try tar.finish()
    let archiveSHA256 = archiveHasher.finalize().map { String(format: "%02x", $0) }.joined()
    return GzipTarArchiveSummary(
      archiveSizeBytes: archiveSizeBytes, archiveSHA256: archiveSHA256, members: members)
  }

  /// Returns the total gzip header length once enough bytes are buffered, nil when more
  /// input is required. RFC 1952 layout: fixed 10 bytes plus optional FEXTRA/FNAME/
  /// FCOMMENT/FHCRC fields.
  static func gzipHeaderLength(of data: Data) throws -> Int? {
    let bytes = [UInt8](data.prefix(maximumGzipHeaderBytes))
    guard bytes.count >= 10 else { return nil }
    guard bytes[0] == 0x1f, bytes[1] == 0x8b else {
      throw GzipTarArchiveReaderError.notGzip
    }
    guard bytes[2] == 8 else {
      throw GzipTarArchiveReaderError.unsupportedCompressionMethod
    }
    let flags = bytes[3]
    guard flags & 0xe0 == 0 else {
      throw GzipTarArchiveReaderError.corruptGzipHeader
    }
    var index = 10
    if flags & 0x04 != 0 {
      guard bytes.count >= index + 2 else { return nil }
      let extraLength = Int(bytes[index]) | Int(bytes[index + 1]) << 8
      index += 2 + extraLength
      guard bytes.count >= index else { return nil }
    }
    for terminatedField in [flags & 0x08 != 0, flags & 0x10 != 0] where terminatedField {
      guard let terminator = bytes[index...].firstIndex(of: 0) else { return nil }
      index = terminator + 1
    }
    if flags & 0x02 != 0 {
      index += 2
      guard bytes.count >= index else { return nil }
    }
    return index
  }
}

// MARK: - Raw DEFLATE decompression (gzip payload)

private final class RawDeflateDecompressor {
  private let streamPointer: UnsafeMutablePointer<compression_stream>
  private let destinationCapacity = GzipTarArchiveReader.chunkSizeBytes
  private let destinationBuffer: UnsafeMutablePointer<UInt8>
  private var ended = false

  init() throws {
    streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
    guard
      compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
    else {
      streamPointer.deallocate()
      destinationBuffer.deallocate()
      throw GzipTarArchiveReaderError.decompressionFailed
    }
  }

  deinit {
    compression_stream_destroy(streamPointer)
    streamPointer.deallocate()
    destinationBuffer.deallocate()
  }

  func feed(
    _ data: Data,
    finalize: Bool,
    emit: (UnsafeRawBufferPointer) throws -> Void
  ) throws {
    guard !ended else { return }
    var scratch: UInt8 = 0
    try withUnsafeMutablePointer(to: &scratch) { scratchPointer in
      try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        if let base = input.baseAddress {
          streamPointer.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
          streamPointer.pointee.src_size = input.count
        } else {
          streamPointer.pointee.src_ptr = UnsafePointer(scratchPointer)
          streamPointer.pointee.src_size = 0
        }
        var stalledIterations = 0
        while true {
          streamPointer.pointee.dst_ptr = destinationBuffer
          streamPointer.pointee.dst_size = destinationCapacity
          let status = compression_stream_process(
            streamPointer, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
          let produced = destinationCapacity - streamPointer.pointee.dst_size
          if produced > 0 {
            try emit(UnsafeRawBufferPointer(start: destinationBuffer, count: produced))
          }
          switch status {
          case COMPRESSION_STATUS_END:
            // The gzip trailer (CRC32/ISIZE) after the deflate stream is intentionally
            // ignored: member and archive SHA-256 are the integrity authority here.
            ended = true
            return
          case COMPRESSION_STATUS_OK:
            if streamPointer.pointee.src_size == 0 {
              if !finalize && produced < destinationCapacity { return }
              stalledIterations = produced == 0 ? stalledIterations + 1 : 0
              if stalledIterations > 2 {
                throw GzipTarArchiveReaderError.truncatedArchive
              }
            }
          default:
            throw GzipTarArchiveReaderError.decompressionFailed
          }
        }
      }
    }
  }
}

// MARK: - Tar stream summarization

private struct TarStreamSummarizer {
  private enum State {
    case header
    case memberContent
    case skipContent
    case finished
  }

  private var state = State.header
  private var headerBuffer = Data()
  private var memberName = ""
  private var memberSizeBytes: Int64 = 0
  private var remainingBytes: Int64 = 0
  private var paddingAfterContent: Int64 = 0
  private var memberHasher = SHA256()
  private var members: [GzipTarMemberSummary] = []
  private var zeroBlockCount = 0

  mutating func consume(_ input: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < input.count {
      switch state {
      case .finished:
        return
      case .header:
        let take = min(512 - headerBuffer.count, input.count - offset)
        headerBuffer.append(
          contentsOf: UnsafeRawBufferPointer(rebasing: input[offset..<offset + take]))
        offset += take
        if headerBuffer.count == 512 {
          try parseHeaderBlock()
        }
      case .memberContent, .skipContent:
        let take = Int(min(remainingBytes, Int64(input.count - offset)))
        if state == .memberContent && take > 0 {
          memberHasher.update(
            bufferPointer: UnsafeRawBufferPointer(rebasing: input[offset..<offset + take]))
        }
        offset += take
        remainingBytes -= Int64(take)
        if remainingBytes == 0 {
          if state == .memberContent {
            finishMember()
            // The 512-byte alignment padding after the content must not enter the digest.
            remainingBytes = paddingAfterContent
            paddingAfterContent = 0
            state = remainingBytes == 0 ? .header : .skipContent
          } else {
            state = .header
          }
        }
      }
    }
  }

  mutating func finish() throws -> [GzipTarMemberSummary] {
    switch state {
    case .finished:
      return members
    case .header where headerBuffer.isEmpty:
      // Tolerate archives whose trailing zero blocks were trimmed by the writer.
      return members
    default:
      throw GzipTarArchiveReaderError.truncatedArchive
    }
  }

  private mutating func parseHeaderBlock() throws {
    defer { headerBuffer.removeAll(keepingCapacity: true) }
    let block = [UInt8](headerBuffer)
    if block.allSatisfy({ $0 == 0 }) {
      zeroBlockCount += 1
      if zeroBlockCount >= 2 {
        state = .finished
      }
      return
    }
    zeroBlockCount = 0

    let storedChecksum = try Self.parseNumericField(block[148..<156], field: "checksum")
    var computedChecksum: Int64 = 0
    for (index, byte) in block.enumerated() {
      computedChecksum += Int64((148..<156).contains(index) ? 0x20 : byte)
    }
    guard storedChecksum == computedChecksum else {
      throw GzipTarArchiveReaderError.corruptTarHeader("header checksum mismatch")
    }

    var name = Self.nulTerminatedString(block[0..<100])
    let isPOSIXFormat =
      block[257..<262].elementsEqual("ustar".utf8) && block[262] == 0
      && block[263..<265].elementsEqual("00".utf8)
    if isPOSIXFormat {
      let prefix = Self.nulTerminatedString(block[345..<500])
      if !prefix.isEmpty {
        name = prefix + "/" + name
      }
    }
    guard !name.isEmpty else {
      throw GzipTarArchiveReaderError.corruptTarHeader("empty member name")
    }

    let size = try Self.parseNumericField(block[124..<136], field: "size")
    let typeFlag = block[156]
    let padding = (512 - size % 512) % 512
    // Regular files only. pax/global/long-name extension records are skipped as opaque
    // content: an archive relying on them cannot name a Profile member and therefore fails
    // validation downstream, which is the intended fail-closed behavior.
    if typeFlag == 0x30 || typeFlag == 0x00 {
      memberName = name
      memberSizeBytes = size
      memberHasher = SHA256()
      remainingBytes = size
      paddingAfterContent = padding
      if remainingBytes == 0 {
        finishMember()
        remainingBytes = paddingAfterContent
        paddingAfterContent = 0
        state = remainingBytes == 0 ? .header : .skipContent
      } else {
        state = .memberContent
      }
    } else {
      remainingBytes = size + padding
      state = remainingBytes == 0 ? .header : .skipContent
    }
  }

  private mutating func finishMember() {
    members.append(
      GzipTarMemberSummary(
        name: memberName,
        sizeBytes: memberSizeBytes,
        sha256: memberHasher.finalize().map { String(format: "%02x", $0) }.joined()))
  }

  private static func nulTerminatedString(_ bytes: ArraySlice<UInt8>) -> String {
    let content = bytes.prefix { $0 != 0 }
    return String(decoding: content, as: UTF8.self)
  }

  private static func parseNumericField(
    _ bytes: ArraySlice<UInt8>, field: String
  ) throws -> Int64 {
    guard let first = bytes.first else {
      throw GzipTarArchiveReaderError.corruptTarHeader("empty numeric field \(field)")
    }
    if first & 0x80 != 0 {
      // GNU base-256 encoding for values that do not fit octal.
      var value = Int64(first & 0x7f)
      for byte in bytes.dropFirst() {
        guard value <= Int64.max >> 8 else {
          throw GzipTarArchiveReaderError.corruptTarHeader("numeric overflow in \(field)")
        }
        value = value << 8 | Int64(byte)
      }
      return value
    }
    var value: Int64 = 0
    var seenDigit = false
    for byte in bytes {
      if byte == 0x20 || byte == 0 {
        if seenDigit { break }
        continue
      }
      guard (0x30...0x37).contains(byte) else {
        throw GzipTarArchiveReaderError.corruptTarHeader("invalid octal digit in \(field)")
      }
      guard value <= (Int64.max - 7) / 8 else {
        throw GzipTarArchiveReaderError.corruptTarHeader("numeric overflow in \(field)")
      }
      seenDigit = true
      value = value * 8 + Int64(byte - 0x30)
    }
    return value
  }
}
