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
  case insufficientStagingCapacity(requiredBytes: Int64, availableBytes: Int64)
  case writeFailed(String, Int32)
  case descriptorIdentityChanged(String)
  case decompressionFailed
  case truncatedArchive
  case corruptTarHeader
}

enum RockchipFlashStagingCapacity {
  /// Leave enough space for Job state, capability lineage and filesystem
  /// metadata to become durable after the image set has been staged. Filling
  /// the volume exactly to the image byte count makes a confirmed pre-write
  /// refusal itself impossible to record.
  static let durableMetadataReserveBytes: Int64 = 64 * 1_024 * 1_024

  static func requiredBytes(for profile: RockchipFlashProfile) throws -> Int64 {
    var required = durableMetadataReserveBytes
    for mapping in profile.mappedPartitions {
      guard let member = profile.member(named: mapping.imageMemberName) else {
        throw RockchipFlashStagingError.memberSetMismatch
      }
      let addition = required.addingReportingOverflow(member.sizeBytes)
      guard !addition.overflow else {
        throw RockchipFlashStagingError.memberSizeMismatch(mapping.imageMemberName)
      }
      required = addition.partialValue
    }
    return required
  }

  static func availableBytes(at root: URL) throws -> Int64 {
    var filesystem = statfs()
    guard statfs(root.path, &filesystem) == 0 else {
      throw RockchipFlashStagingError.writeFailed(root.path, errno)
    }
    let available = UInt64(filesystem.f_bavail).multipliedReportingOverflow(
      by: UInt64(filesystem.f_bsize))
    guard !available.overflow else { return Int64.max }
    return Int64(clamping: available.partialValue)
  }

  static func require(profile: RockchipFlashProfile, availableBytes: Int64) throws {
    let required = try requiredBytes(for: profile)
    guard availableBytes >= required else {
      throw RockchipFlashStagingError.insufficientStagingCapacity(
        requiredBytes: required, availableBytes: max(0, availableBytes))
    }
  }

  static func require(profile: RockchipFlashProfile, at root: URL) throws {
    try require(profile: profile, availableBytes: try availableBytes(at: root))
  }
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

    // Recheck on the exact staging filesystem immediately before allocation.
    // The engine also performs this check during its host-only verification
    // step, before Loader transition, but free space can drift meanwhile.
    try RockchipFlashStagingCapacity.require(profile: profile, at: sessionRoot)

    let stagingURL = sessionRoot.appending(path: "staging", directoryHint: .isDirectory)
    guard Darwin.mkdir(stagingURL.path, 0o700) == 0 else {
      if errno == EEXIST { throw RockchipFlashStagingError.stagingPathExists }
      throw RockchipFlashStagingError.writeFailed(stagingURL.path, errno)
    }
    var preserveCompletedStaging = false
    defer {
      if !preserveCompletedStaging {
        // `staging` is an owner-only directory created by this invocation.
        // Every byte is derived from the still-pinned archive, so a failed
        // stage must release it before Runtime persists the refusal.
        try? FileManager.default.removeItem(at: stagingURL)
      }
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
    preserveCompletedStaging = true
    return images
  }

  /// Reopens a completed, content-addressed image set without expanding the
  /// archive again. Every file is hashed from an owner-only descriptor before
  /// it is returned; the cache key alone is never treated as proof that the
  /// bytes still match the immutable archive profile.
  static func reopen(
    stagingURL: URL,
    profile: RockchipFlashProfile
  ) throws -> [String: StagedRockchipImage] {
    guard stagingURL.isFileURL, stagingURL.path.hasPrefix("/") else {
      throw RockchipFlashStagingError.invalidSessionRoot
    }
    var directoryMetadata = stat()
    guard lstat(stagingURL.path, &directoryMetadata) == 0,
      directoryMetadata.st_mode & S_IFMT == S_IFDIR,
      directoryMetadata.st_mode & 0o077 == 0
    else { throw RockchipFlashStagingError.invalidSessionRoot }
    let directoryDescriptor = Darwin.open(
      stagingURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryDescriptor >= 0 else {
      throw RockchipFlashStagingError.writeFailed(stagingURL.path, errno)
    }
    defer { Darwin.close(directoryDescriptor) }

    let expectedNames = Set(profile.mappedPartitions.map(\.imageMemberName))
    let actualNames: Set<String>
    do {
      actualNames = Set(try FileManager.default.contentsOfDirectory(atPath: stagingURL.path))
    } catch {
      throw RockchipFlashStagingError.writeFailed(stagingURL.path, errno)
    }
    guard actualNames == expectedNames else {
      throw RockchipFlashStagingError.memberSetMismatch
    }

    var images: [String: StagedRockchipImage] = [:]
    for mapping in profile.mappedPartitions {
      guard let member = profile.member(named: mapping.imageMemberName) else {
        throw RockchipFlashStagingError.memberSetMismatch
      }
      let descriptor = Darwin.openat(
        directoryDescriptor, member.name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else {
        throw RockchipFlashStagingError.writeFailed(member.name, errno)
      }
      var descriptorIsOpen = true
      defer {
        if descriptorIsOpen { Darwin.close(descriptor) }
      }
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_mode & 0o7777 == 0o400,
        metadata.st_size == member.sizeBytes,
        metadata.st_nlink == 1
      else {
        throw RockchipFlashStagingError.descriptorIdentityChanged(member.name)
      }
      var hasher = SHA256()
      var remaining = member.sizeBytes
      var buffer = [UInt8](repeating: 0, count: 1 << 20)
      while remaining > 0 {
        let requested = min(Int64(buffer.count), remaining)
        let count = Darwin.read(descriptor, &buffer, Int(requested))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw RockchipFlashStagingError.memberSizeMismatch(member.name)
        }
        hasher.update(data: Data(buffer[0..<count]))
        remaining -= Int64(count)
      }
      var trailing: UInt8 = 0
      guard Darwin.read(descriptor, &trailing, 1) == 0 else {
        throw RockchipFlashStagingError.memberSizeMismatch(member.name)
      }
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      guard digest == member.sha256 else {
        throw RockchipFlashStagingError.memberHashMismatch(member.name)
      }
      let image = StagedRockchipImage(
        memberName: member.name, partitionName: mapping.partitionName,
        sizeBytes: member.sizeBytes, sha256: member.sha256,
        stagedURL: stagingURL.appending(path: member.name),
        descriptor: descriptor, metadata: metadata)
      descriptorIsOpen = false
      try image.revalidate()
      images[member.name] = image
    }
    return images
  }
}

/// A bounded, process-owned cache for the expanded Rockchip image set.
///
/// The archive SHA-256 is already the immutable identity pinned by the
/// Artifact lease and Runtime capability. Keeping one fully verified entry
/// avoids producing another ~3.7 GB copy for each retry while pruning older
/// firmware and interrupted temporary expansions before a miss is staged.
final class RockchipFlashImageCache: @unchecked Sendable {
  private let rootURL: URL
  private let lock = NSLock()

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  func images(
    archiveURL: URL,
    profile: RockchipFlashProfile
  ) throws -> [String: StagedRockchipImage] {
    try lock.withLock {
      try prepareRoot()
      let digest = profile.archiveSHA256
      guard digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
        throw RockchipFlashStagingError.archiveHashMismatch
      }
      let entryURL = rootURL.appending(path: digest, directoryHint: .isDirectory)
      try prune(except: digest)
      if FileManager.default.fileExists(atPath: entryURL.path) {
        do {
          return try RockchipFlashExecutionStager.reopen(
            stagingURL: entryURL, profile: profile)
        } catch {
          // A cache is derived and carries no authority. Drifted or incomplete
          // bytes are removed and rebuilt from the still-pinned archive.
          do { try FileManager.default.removeItem(at: entryURL) } catch {
            throw RockchipFlashStagingError.writeFailed(entryURL.path, errno)
          }
        }
      }

      let temporaryURL = rootURL.appending(
        path: ".tmp-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
      do {
        try FileManager.default.createDirectory(
          at: temporaryURL, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw RockchipFlashStagingError.writeFailed(temporaryURL.path, errno)
      }
      defer { try? FileManager.default.removeItem(at: temporaryURL) }

      var expanded = try RockchipFlashExecutionStager.stage(
        archiveURL: archiveURL, sessionRoot: temporaryURL, profile: profile)
      // Close every validation descriptor before moving the directory. New
      // descriptors are opened against the final content-addressed paths.
      expanded.removeAll()
      let expandedURL = temporaryURL.appending(path: "staging", directoryHint: .isDirectory)
      guard Darwin.rename(expandedURL.path, entryURL.path) == 0 else {
        throw RockchipFlashStagingError.writeFailed(entryURL.path, errno)
      }
      try synchronizeRoot()
      return try RockchipFlashExecutionStager.reopen(
        stagingURL: entryURL, profile: profile)
    }
  }

  private func prepareRoot() throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw RockchipFlashStagingError.invalidSessionRoot
    }
    do {
      try FileManager.default.createDirectory(
        at: rootURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw RockchipFlashStagingError.writeFailed(rootURL.path, errno)
    }
    var metadata = stat()
    guard lstat(rootURL.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o077 == 0
    else { throw RockchipFlashStagingError.invalidSessionRoot }
  }

  private func prune(except retainedName: String) throws {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: rootURL, includingPropertiesForKeys: nil)
    } catch {
      throw RockchipFlashStagingError.writeFailed(rootURL.path, errno)
    }
    for entry in entries where entry.lastPathComponent != retainedName {
      do { try FileManager.default.removeItem(at: entry) } catch {
        throw RockchipFlashStagingError.writeFailed(entry.path, errno)
      }
    }
  }

  private func synchronizeRoot() throws {
    let descriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RockchipFlashStagingError.writeFailed(rootURL.path, errno)
    }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw RockchipFlashStagingError.writeFailed(rootURL.path, errno)
    }
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
