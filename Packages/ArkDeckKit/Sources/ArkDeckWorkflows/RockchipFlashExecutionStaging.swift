import Compression
import CryptoKit
import Darwin
import Foundation

enum RockchipFlashStagingError: Error, Equatable, Sendable {
  case invalidSessionRoot
  case stagingPathExists
  case unsafeMemberName(String)
  case duplicateMember(String)
  case undeclaredMember(String)
  case unsupportedMemberType(String)
  case memberSetMismatch
  case memberSizeMismatch(String)
  case memberHashMismatch(String)
  case archiveSizeMismatch
  case archiveHashMismatch
  case writeFailed(String, Int32)
  case descriptorIdentityChanged(String)
  case decompressionFailed
  case truncatedArchive
  case corruptTarHeader
}

final class StagedRockchipImage: @unchecked Sendable {
  let memberName: String
  let partitionName: String
  let sizeBytes: Int64
  let sha256: String
  let stableDescriptorPath: String
  let device: UInt64
  let inode: UInt64
  let mode: UInt32

  private let descriptor: Int32
  private let stagedURL: URL

  fileprivate init(
    memberName: String,
    partitionName: String,
    sizeBytes: Int64,
    sha256: String,
    stagedURL: URL,
    descriptor: Int32,
    metadata: stat
  ) {
    self.memberName = memberName
    self.partitionName = partitionName
    self.sizeBytes = sizeBytes
    self.sha256 = sha256
    self.stagedURL = stagedURL
    self.descriptor = descriptor
    device = UInt64(UInt32(bitPattern: metadata.st_dev))
    inode = UInt64(metadata.st_ino)
    mode = UInt32(metadata.st_mode)
    stableDescriptorPath = "/.vol/\(device)/\(inode)"
  }

  deinit { Darwin.close(descriptor) }

  func revalidate() throws {
    var descriptorMetadata = stat()
    var pathMetadata = stat()
    var stableMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
      lstat(stagedURL.path, &pathMetadata) == 0,
      lstat(stableDescriptorPath, &stableMetadata) == 0,
      descriptorMetadata.st_dev == pathMetadata.st_dev,
      descriptorMetadata.st_ino == pathMetadata.st_ino,
      descriptorMetadata.st_dev == stableMetadata.st_dev,
      descriptorMetadata.st_ino == stableMetadata.st_ino,
      descriptorMetadata.st_size == sizeBytes,
      descriptorMetadata.st_mode & S_IFMT == S_IFREG,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      stableMetadata.st_mode & S_IFMT == S_IFREG
    else { throw RockchipFlashStagingError.descriptorIdentityChanged(memberName) }
  }
}

enum RockchipFlashExecutionStager {
  static func stage(
    archiveURL: URL,
    sessionRoot: URL,
    profile: RockchipFlashProfile = .dayu200
  ) throws -> [String: StagedRockchipImage] {
    guard archiveURL.isFileURL, archiveURL.path.hasPrefix("/"),
      sessionRoot.isFileURL, sessionRoot.path.hasPrefix("/")
    else { throw RockchipFlashStagingError.invalidSessionRoot }
    var rootMetadata = stat()
    guard lstat(sessionRoot.path, &rootMetadata) == 0,
      rootMetadata.st_mode & S_IFMT == S_IFDIR,
      rootMetadata.st_mode & 0o077 == 0
    else { throw RockchipFlashStagingError.invalidSessionRoot }

    let stagingURL = sessionRoot.appending(path: "staging", directoryHint: .isDirectory)
    guard Darwin.mkdir(stagingURL.path, 0o700) == 0 else {
      if errno == EEXIST { throw RockchipFlashStagingError.stagingPathExists }
      throw RockchipFlashStagingError.writeFailed(stagingURL.path, errno)
    }
    let stagingDescriptor = Darwin.open(
      stagingURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard stagingDescriptor >= 0 else {
      throw RockchipFlashStagingError.writeFailed(stagingURL.path, errno)
    }
    defer { Darwin.close(stagingDescriptor) }

    let archiveDescriptor = Darwin.open(archiveURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard archiveDescriptor >= 0 else {
      throw RockchipFlashStagingError.writeFailed(archiveURL.path, errno)
    }
    defer { Darwin.close(archiveDescriptor) }
    var archiveMetadata = stat()
    guard fstat(archiveDescriptor, &archiveMetadata) == 0,
      archiveMetadata.st_mode & S_IFMT == S_IFREG
    else { throw RockchipFlashStagingError.invalidSessionRoot }

    let mappedByMember = Dictionary(
      uniqueKeysWithValues: profile.mappedPartitions.map { ($0.imageMemberName, $0) })
    let declaredByName = Dictionary(uniqueKeysWithValues: profile.members.map { ($0.name, $0) })
    var tar = RockchipStagingTarConsumer(
      stagingURL: stagingURL,
      stagingDescriptor: stagingDescriptor,
      declaredByName: declaredByName,
      mappedByMember: mappedByMember)
    var archiveHasher = SHA256()
    var archiveSize: Int64 = 0
    var headerPending = Data()
    var headerConsumed = false
    let decompressor = try RockchipRawDeflateDecoder()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
      let count = Darwin.read(archiveDescriptor, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw RockchipFlashStagingError.writeFailed(archiveURL.path, errno)
      }
      let chunk = Data(buffer[0..<count])
      archiveHasher.update(data: chunk)
      archiveSize += Int64(count)
      var payload = chunk
      if !headerConsumed {
        headerPending.append(chunk)
        let headerLength: Int?
        do { headerLength = try GzipTarArchiveReader.gzipHeaderLength(of: headerPending) } catch {
          throw RockchipFlashStagingError.decompressionFailed
        }
        guard let headerLength else {
          guard headerPending.count <= GzipTarArchiveReader.maximumGzipHeaderBytes else {
            throw RockchipFlashStagingError.decompressionFailed
          }
          continue
        }
        headerConsumed = true
        payload = headerPending.subdata(in: headerLength..<headerPending.count)
        headerPending.removeAll()
      }
      try decompressor.feed(payload, finalize: false) { output in
        try tar.consume(output)
      }
    }
    guard headerConsumed else { throw RockchipFlashStagingError.decompressionFailed }
    try decompressor.feed(Data(), finalize: true) { output in
      try tar.consume(output)
    }
    let images = try tar.finish()
    guard archiveSize == profile.archiveSizeBytes else {
      throw RockchipFlashStagingError.archiveSizeMismatch
    }
    let archiveHash = archiveHasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard archiveHash == profile.archiveSHA256 else {
      throw RockchipFlashStagingError.archiveHashMismatch
    }
    guard fsync(stagingDescriptor) == 0 else {
      throw RockchipFlashStagingError.writeFailed(stagingURL.path, errno)
    }
    for image in images.values {
      try image.revalidate()
    }
    return images
  }
}

private final class RockchipRawDeflateDecoder {
  private let stream: UnsafeMutablePointer<compression_stream>
  private let output: UnsafeMutablePointer<UInt8>
  private let capacity = 1 << 20
  private var ended = false

  init() throws {
    stream = .allocate(capacity: 1)
    output = .allocate(capacity: capacity)
    guard
      compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
    else {
      stream.deallocate()
      output.deallocate()
      throw RockchipFlashStagingError.decompressionFailed
    }
  }

  deinit {
    compression_stream_destroy(stream)
    stream.deallocate()
    output.deallocate()
  }

  func feed(_ data: Data, finalize: Bool, emit: (UnsafeRawBufferPointer) throws -> Void) throws {
    guard !ended else { return }
    var scratch: UInt8 = 0
    try withUnsafeMutablePointer(to: &scratch) { scratchPointer in
      try data.withUnsafeBytes { input in
        stream.pointee.src_ptr =
          input.baseAddress?.assumingMemoryBound(to: UInt8.self)
          ?? UnsafePointer(scratchPointer)
        stream.pointee.src_size = input.count
        var stalls = 0
        while true {
          stream.pointee.dst_ptr = output
          stream.pointee.dst_size = capacity
          let status = compression_stream_process(
            stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
          let produced = capacity - stream.pointee.dst_size
          if produced > 0 {
            try emit(UnsafeRawBufferPointer(start: output, count: produced))
          }
          switch status {
          case COMPRESSION_STATUS_END:
            ended = true
            return
          case COMPRESSION_STATUS_OK:
            if stream.pointee.src_size == 0 {
              if !finalize && produced < capacity { return }
              stalls = produced == 0 ? stalls + 1 : 0
              if stalls > 2 { throw RockchipFlashStagingError.truncatedArchive }
            }
          default:
            throw RockchipFlashStagingError.decompressionFailed
          }
        }
      }
    }
  }
}

private struct RockchipStagingTarConsumer {
  private enum State { case header, content, padding, finished }

  let stagingURL: URL
  let stagingDescriptor: Int32
  let declaredByName: [String: RockchipImagesArchiveMember]
  let mappedByMember: [String: RockchipMappedPartition]

  private var state = State.header
  private var header = Data()
  private var seen = Set<String>()
  private var remaining: Int64 = 0
  private var padding: Int64 = 0
  private var currentName = ""
  private var expectedMember: RockchipImagesArchiveMember?
  private var currentPartition: RockchipMappedPartition?
  private var currentHasher = SHA256()
  private var currentDescriptor: Int32 = -1
  private var currentTemporaryName = ""
  private var images: [String: StagedRockchipImage] = [:]
  private var zeroBlocks = 0

  init(
    stagingURL: URL,
    stagingDescriptor: Int32,
    declaredByName: [String: RockchipImagesArchiveMember],
    mappedByMember: [String: RockchipMappedPartition]
  ) {
    self.stagingURL = stagingURL
    self.stagingDescriptor = stagingDescriptor
    self.declaredByName = declaredByName
    self.mappedByMember = mappedByMember
  }

  mutating func consume(_ input: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < input.count {
      switch state {
      case .finished:
        guard input[offset...].allSatisfy({ $0 == 0 }) else {
          throw RockchipFlashStagingError.corruptTarHeader
        }
        return
      case .header:
        let count = min(512 - header.count, input.count - offset)
        header.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[offset..<offset + count]))
        offset += count
        if header.count == 512 { try parseHeader() }
      case .content:
        let count = Int(min(remaining, Int64(input.count - offset)))
        if count > 0 {
          let bytes = UnsafeRawBufferPointer(rebasing: input[offset..<offset + count])
          if currentDescriptor >= 0 { try writeAll(bytes, descriptor: currentDescriptor) }
          currentHasher.update(bufferPointer: bytes)
        }
        offset += count
        remaining -= Int64(count)
        if remaining == 0 { try finishMember() }
      case .padding:
        let count = Int(min(remaining, Int64(input.count - offset)))
        offset += count
        remaining -= Int64(count)
        if remaining == 0 { state = .header }
      }
    }
  }

  mutating func finish() throws -> [String: StagedRockchipImage] {
    guard currentDescriptor < 0 else {
      Darwin.close(currentDescriptor)
      currentDescriptor = -1
      throw RockchipFlashStagingError.truncatedArchive
    }
    guard state == .finished || (state == .header && header.isEmpty),
      seen == Set(declaredByName.keys),
      Set(images.keys) == Set(mappedByMember.keys)
    else { throw RockchipFlashStagingError.memberSetMismatch }
    return images
  }

  private mutating func parseHeader() throws {
    defer { header.removeAll(keepingCapacity: true) }
    let block = [UInt8](header)
    if block.allSatisfy({ $0 == 0 }) {
      zeroBlocks += 1
      if zeroBlocks >= 2 { state = .finished }
      return
    }
    zeroBlocks = 0
    let stored = try numeric(block[148..<156])
    let computed = block.enumerated().reduce(Int64(0)) { result, pair in
      result + Int64((148..<156).contains(pair.offset) ? 0x20 : pair.element)
    }
    guard stored == computed else { throw RockchipFlashStagingError.corruptTarHeader }
    var name = nulString(block[0..<100])
    if block[257..<262].elementsEqual("ustar".utf8), block[262] == 0,
      block[263..<265].elementsEqual("00".utf8)
    {
      let prefix = nulString(block[345..<500])
      if !prefix.isEmpty { name = prefix + "/" + name }
    }
    guard isSafeMemberName(name) else {
      throw RockchipFlashStagingError.unsafeMemberName(name)
    }
    guard seen.insert(name).inserted else {
      throw RockchipFlashStagingError.duplicateMember(name)
    }
    guard let declared = declaredByName[name] else {
      throw RockchipFlashStagingError.undeclaredMember(name)
    }
    let type = block[156]
    guard type == 0 || type == UInt8(ascii: "0") else {
      throw RockchipFlashStagingError.unsupportedMemberType(name)
    }
    let size = try numeric(block[124..<136])
    guard size == declared.sizeBytes else {
      throw RockchipFlashStagingError.memberSizeMismatch(name)
    }
    currentName = name
    expectedMember = declared
    currentPartition = mappedByMember[name]
    currentHasher = SHA256()
    remaining = size
    padding = (512 - size % 512) % 512
    if currentPartition != nil {
      currentTemporaryName = ".\(name).part"
      currentDescriptor = Darwin.openat(
        stagingDescriptor, currentTemporaryName,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard currentDescriptor >= 0 else {
        throw RockchipFlashStagingError.writeFailed(currentTemporaryName, errno)
      }
    }
    state = .content
    if remaining == 0 { try finishMember() }
  }

  private mutating func finishMember() throws {
    guard let expectedMember else { throw RockchipFlashStagingError.corruptTarHeader }
    let digest = currentHasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == expectedMember.sha256 else {
      if currentDescriptor >= 0 {
        Darwin.close(currentDescriptor)
        currentDescriptor = -1
      }
      throw RockchipFlashStagingError.memberHashMismatch(currentName)
    }
    if let partition = currentPartition {
      guard Darwin.fchmod(currentDescriptor, S_IRUSR) == 0, fsync(currentDescriptor) == 0 else {
        let code = errno
        Darwin.close(currentDescriptor)
        currentDescriptor = -1
        throw RockchipFlashStagingError.writeFailed(currentName, code)
      }
      guard Darwin.close(currentDescriptor) == 0 else {
        currentDescriptor = -1
        throw RockchipFlashStagingError.writeFailed(currentName, errno)
      }
      currentDescriptor = -1
      guard
        renameatx_np(
          stagingDescriptor, currentTemporaryName, stagingDescriptor, currentName,
          UInt32(RENAME_EXCL)) == 0
      else { throw RockchipFlashStagingError.writeFailed(currentName, errno) }
      let finalURL = stagingURL.appending(path: currentName)
      let descriptor = Darwin.openat(
        stagingDescriptor, currentName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else {
        throw RockchipFlashStagingError.writeFailed(currentName, errno)
      }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_size == expectedMember.sizeBytes,
        metadata.st_nlink == 1
      else {
        Darwin.close(descriptor)
        throw RockchipFlashStagingError.descriptorIdentityChanged(currentName)
      }
      let image = StagedRockchipImage(
        memberName: currentName, partitionName: partition.partitionName,
        sizeBytes: expectedMember.sizeBytes, sha256: digest, stagedURL: finalURL,
        descriptor: descriptor, metadata: metadata)
      do { try image.revalidate() } catch {
        throw RockchipFlashStagingError.descriptorIdentityChanged(currentName)
      }
      images[currentName] = image
    }
    currentName = ""
    self.expectedMember = nil
    currentPartition = nil
    currentTemporaryName = ""
    remaining = padding
    padding = 0
    state = remaining == 0 ? .header : .padding
  }

  private func writeAll(_ bytes: UnsafeRawBufferPointer, descriptor: Int32) throws {
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(
        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if count > 0 {
        offset += count
        continue
      }
      if count < 0, errno == EINTR { continue }
      throw RockchipFlashStagingError.writeFailed(currentName, errno)
    }
  }

  private func isSafeMemberName(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.contains("/")
      && !value.contains("\\") && value != "." && value != ".."
      && !value.utf8.contains(0)
  }

  private func nulString(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }

  private func numeric(_ bytes: ArraySlice<UInt8>) throws -> Int64 {
    guard let first = bytes.first else { throw RockchipFlashStagingError.corruptTarHeader }
    if first & 0x80 != 0 {
      var value = Int64(first & 0x7f)
      for byte in bytes.dropFirst() {
        guard value <= Int64.max >> 8 else { throw RockchipFlashStagingError.corruptTarHeader }
        value = value << 8 | Int64(byte)
      }
      return value
    }
    var value: Int64 = 0
    var seenDigit = false
    for byte in bytes {
      if byte == 0 || byte == 0x20 {
        if seenDigit { break }
        continue
      }
      guard (0x30...0x37).contains(byte), value <= (Int64.max - 7) / 8 else {
        throw RockchipFlashStagingError.corruptTarHeader
      }
      seenDigit = true
      value = value * 8 + Int64(byte - 0x30)
    }
    return value
  }
}
