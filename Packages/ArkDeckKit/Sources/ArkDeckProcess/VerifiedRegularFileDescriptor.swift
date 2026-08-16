import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum VerifiedRegularFileError: Error, Equatable {
  case invalidPath
  case openFailed(Int32)
  case unsafeFile
  case identityChanged
  case hashMismatch
  case inodePathUnavailable
  case descriptorInvalid
}

/// Retains the exact owner-private directory generation that gives a signed
/// bundle its canonical namespace. The directory path is re-opened through an
/// `openat(O_NOFOLLOW)` component walk before spawn and again while the child
/// is suspended; a whole-App replacement therefore cannot mix executable
/// bytes from one generation with Bundle resources from another.
public final class VerifiedDirectoryDescriptor: @unchecked Sendable {
  package let authorizedPath: String
  private var descriptor: Int32
  private let openedDevice: dev_t
  private let openedInode: ino_t
  private let openedOwner: uid_t
  private let openedMode: mode_t

  private init(
    authorizedPath: String,
    descriptor: Int32,
    metadata: stat
  ) {
    self.authorizedPath = authorizedPath
    self.descriptor = descriptor
    self.openedDevice = metadata.st_dev
    self.openedInode = metadata.st_ino
    self.openedOwner = metadata.st_uid
    self.openedMode = metadata.st_mode
  }

  package static func openOwnerOnly(path: URL) throws -> VerifiedDirectoryDescriptor {
    guard path.isFileURL, path.path.hasPrefix("/") else {
      throw VerifiedRegularFileError.invalidPath
    }
    let descriptor = try openPhysicalAbsoluteDirectory(path.path)
    do {
      var metadata = stat()
      guard unsafe fstat(descriptor, &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid(),
        metadata.st_mode & 0o022 == 0
      else { throw VerifiedRegularFileError.unsafeFile }
      return VerifiedDirectoryDescriptor(
        authorizedPath: path.path, descriptor: descriptor, metadata: metadata)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  package func revalidate() throws {
    guard descriptor >= 0 else { throw VerifiedRegularFileError.descriptorInvalid }
    var retained = stat()
    guard unsafe fstat(descriptor, &retained) == 0,
      retained.st_dev == openedDevice,
      retained.st_ino == openedInode,
      retained.st_uid == openedOwner,
      retained.st_mode == openedMode,
      retained.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      retained.st_mode & 0o022 == 0
    else { throw VerifiedRegularFileError.identityChanged }
    let current = try Self.openPhysicalAbsoluteDirectory(authorizedPath)
    defer { Darwin.close(current) }
    var linked = stat()
    guard unsafe fstat(current, &linked) == 0,
      linked.st_dev == openedDevice,
      linked.st_ino == openedInode,
      linked.st_uid == openedOwner,
      linked.st_mode == openedMode
    else { throw VerifiedRegularFileError.identityChanged }
  }

  package func close() {
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
  }

  deinit { close() }

  private static func openPhysicalAbsoluteDirectory(_ path: String) throws -> Int32 {
    let physicalPath: String
    if path == "/var" || path.hasPrefix("/var/") {
      physicalPath = "/private" + path
    } else if path == "/tmp" || path.hasPrefix("/tmp/") {
      physicalPath = "/private" + path
    } else if path == "/etc" || path.hasPrefix("/etc/") {
      physicalPath = "/private" + path
    } else {
      physicalPath = path
    }
    let components = physicalPath.split(
      separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw VerifiedRegularFileError.invalidPath }
    var directory = unsafe Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw VerifiedRegularFileError.openFailed(errno) }
    do {
      for component in components {
        let next = unsafe component.withCString {
          unsafe Darwin.openat(
            directory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard next >= 0 else { throw VerifiedRegularFileError.openFailed(errno) }
        Darwin.close(directory)
        directory = next
      }
      return directory
    } catch {
      Darwin.close(directory)
      throw error
    }
  }
}

/// Retains one verified regular-file inode while a child opens it. Callers
/// put `inodePath` in argv instead of the mutable pathname; the descriptor is
/// held until the child completes and is revalidated in the final pre-spawn
/// critical section.
public final class VerifiedRegularFileDescriptor: @unchecked Sendable {
  package let authorizedPath: String
  package let inodePath: String
  package let sha256: String
  package let byteCount: Int

  private var descriptor: Int32
  private let openedDevice: dev_t
  private let openedInode: ino_t
  private let openedOwner: uid_t
  private let openedMode: mode_t
  private let openedSize: off_t
  private let openedModificationTime: timespec
  private let openedChangeTime: timespec
  private let requireExecutable: Bool

  private init(
    authorizedPath: String,
    inodePath: String,
    sha256: String,
    byteCount: Int,
    descriptor: Int32,
    openedDevice: dev_t,
    openedInode: ino_t,
    openedOwner: uid_t,
    openedMode: mode_t,
    openedSize: off_t,
    openedModificationTime: timespec,
    openedChangeTime: timespec,
    requireExecutable: Bool
  ) {
    self.authorizedPath = authorizedPath
    self.inodePath = inodePath
    self.sha256 = sha256
    self.byteCount = byteCount
    self.descriptor = descriptor
    self.openedDevice = openedDevice
    self.openedInode = openedInode
    self.openedOwner = openedOwner
    self.openedMode = openedMode
    self.openedSize = openedSize
    self.openedModificationTime = openedModificationTime
    self.openedChangeTime = openedChangeTime
    self.requireExecutable = requireExecutable
  }

  package static func open(
    path: URL,
    expectedSHA256: String,
    maximumBytes: Int = 512 * 1_024 * 1_024,
    requireExecutable: Bool = false
  ) throws -> VerifiedRegularFileDescriptor {
    guard path.isFileURL, path.path.hasPrefix("/"),
      expectedSHA256.count == 64,
      expectedSHA256.utf8.allSatisfy({
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      })
    else { throw VerifiedRegularFileError.invalidPath }

    let descriptor = try openPhysicalAbsolutePath(
      path.path, flags: O_RDONLY | O_NONBLOCK)
    do {
      var metadata = stat()
      guard unsafe fstat(descriptor, &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        (metadata.st_uid == geteuid() || metadata.st_uid == 0),
        metadata.st_mode & 0o022 == 0,
        (!requireExecutable || metadata.st_mode & 0o111 != 0),
        metadata.st_size > 0,
        metadata.st_size <= maximumBytes
      else { throw VerifiedRegularFileError.identityChanged }
      let observedSHA256 = try hash(
        descriptor, expectedByteCount: Int(metadata.st_size), initial: metadata)
      guard observedSHA256 == expectedSHA256 else {
        throw VerifiedRegularFileError.hashMismatch
      }
      let device = UInt64(UInt32(bitPattern: metadata.st_dev))
      let inode = UInt64(metadata.st_ino)
      let inodePath = "/.vol/\(device)/\(inode)"
      var inodeMetadata = stat()
      guard unsafe inodePath.withCString({ unsafe lstat($0, &inodeMetadata) }) == 0,
        inodeMetadata.st_dev == metadata.st_dev,
        inodeMetadata.st_ino == metadata.st_ino,
        inodeMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
      else { throw VerifiedRegularFileError.inodePathUnavailable }
      return VerifiedRegularFileDescriptor(
        authorizedPath: path.path, inodePath: inodePath,
        sha256: observedSHA256, byteCount: Int(metadata.st_size),
        descriptor: descriptor, openedDevice: metadata.st_dev,
        openedInode: metadata.st_ino, openedOwner: metadata.st_uid,
        openedMode: metadata.st_mode, openedSize: metadata.st_size,
        openedModificationTime: metadata.st_mtimespec,
        openedChangeTime: metadata.st_ctimespec,
        requireExecutable: requireExecutable)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  package func revalidate() throws {
    guard descriptor >= 0 else { throw VerifiedRegularFileError.descriptorInvalid }
    var metadata = stat()
    guard unsafe fstat(descriptor, &metadata) == 0 else {
      throw VerifiedRegularFileError.descriptorInvalid
    }
    guard
      matchesOpenedIdentity(metadata),
      metadata.st_mode & 0o022 == 0,
      (!requireExecutable || metadata.st_mode & 0o111 != 0)
    else { throw VerifiedRegularFileError.identityChanged }
    let pathDescriptor = try Self.openPhysicalAbsolutePath(
      authorizedPath, flags: O_RDONLY | O_NONBLOCK)
    defer { Darwin.close(pathDescriptor) }
    var pathMetadata = stat()
    guard unsafe fstat(pathDescriptor, &pathMetadata) == 0,
      matchesOpenedIdentity(pathMetadata),
      pathMetadata.st_mode & 0o022 == 0,
      (!requireExecutable || pathMetadata.st_mode & 0o111 != 0)
    else { throw VerifiedRegularFileError.identityChanged }
    var inodeMetadata = stat()
    guard unsafe inodePath.withCString({ unsafe lstat($0, &inodeMetadata) }) == 0,
      inodeMetadata.st_dev == openedDevice,
      inodeMetadata.st_ino == openedInode,
      inodeMetadata.st_uid == openedOwner,
      inodeMetadata.st_mode == openedMode,
      inodeMetadata.st_size == openedSize,
      inodeMetadata.st_mtimespec.tv_sec == openedModificationTime.tv_sec,
      inodeMetadata.st_mtimespec.tv_nsec == openedModificationTime.tv_nsec,
      inodeMetadata.st_ctimespec.tv_sec == openedChangeTime.tv_sec,
      inodeMetadata.st_ctimespec.tv_nsec == openedChangeTime.tv_nsec,
      inodeMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else { throw VerifiedRegularFileError.inodePathUnavailable }
    guard try Self.hash(
      descriptor, expectedByteCount: byteCount, initial: metadata) == sha256
    else {
      throw VerifiedRegularFileError.hashMismatch
    }
  }

  private func matchesOpenedIdentity(_ metadata: stat) -> Bool {
    metadata.st_dev == openedDevice
      && metadata.st_ino == openedInode
      && metadata.st_uid == openedOwner
      && metadata.st_mode == openedMode
      && metadata.st_size == openedSize
      && metadata.st_mtimespec.tv_sec == openedModificationTime.tv_sec
      && metadata.st_mtimespec.tv_nsec == openedModificationTime.tv_nsec
      && metadata.st_ctimespec.tv_sec == openedChangeTime.tv_sec
      && metadata.st_ctimespec.tv_nsec == openedChangeTime.tv_nsec
      && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
  }

  package func close() {
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
  }

  deinit { close() }

  /// Opens an absolute path one component at a time below a descriptor for
  /// `/`. Every parent and the leaf use `O_NOFOLLOW`, so an ancestor cannot be
  /// exchanged for a symlink between a lexical preflight and the actual open.
  private static func openPhysicalAbsolutePath(
    _ path: String,
    flags: Int32
  ) throws -> Int32 {
    guard path.hasPrefix("/") else {
      throw VerifiedRegularFileError.invalidPath
    }
    // Darwin exposes three immutable namespace aliases at the filesystem
    // root. Foundation's temporaryDirectory commonly returns `/var/...` even
    // though its physical name is `/private/var/...`. Normalize only these
    // OS-owned aliases before the descriptor walk; every caller-controlled
    // ancestor below them still uses O_NOFOLLOW.
    let physicalPath: String
    if path == "/var" || path.hasPrefix("/var/") {
      physicalPath = "/private" + path
    } else if path == "/tmp" || path.hasPrefix("/tmp/") {
      physicalPath = "/private" + path
    } else if path == "/etc" || path.hasPrefix("/etc/") {
      physicalPath = "/private" + path
    } else {
      physicalPath = path
    }
    let components = physicalPath.split(
      separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw VerifiedRegularFileError.invalidPath }

    var directory = unsafe Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw VerifiedRegularFileError.openFailed(errno) }
    do {
      for component in components.dropLast() {
        let next = unsafe component.withCString {
          unsafe Darwin.openat(
            directory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard next >= 0 else { throw VerifiedRegularFileError.openFailed(errno) }
        Darwin.close(directory)
        directory = next
      }
      let descriptor = unsafe components.last!.withCString {
        unsafe Darwin.openat(directory, $0, flags | O_CLOEXEC | O_NOFOLLOW)
      }
      guard descriptor >= 0 else { throw VerifiedRegularFileError.openFailed(errno) }
      Darwin.close(directory)
      directory = -1
      return descriptor
    } catch {
      if directory >= 0 { Darwin.close(directory) }
      throw error
    }
  }

  private static func hash(
    _ descriptor: Int32,
    expectedByteCount: Int,
    initial: stat
  ) throws -> String {
    guard expectedByteCount > 0 else {
      throw VerifiedRegularFileError.descriptorInvalid
    }
    var hasher = SHA256()
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, expectedByteCount))
    while offset < off_t(expectedByteCount) {
      let count = unsafe buffer.withUnsafeMutableBytes { bytes in
        unsafe pread(
          descriptor, bytes.baseAddress,
          min(bytes.count, expectedByteCount - Int(offset)), offset)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw VerifiedRegularFileError.descriptorInvalid
      }
      guard count > 0 else { throw VerifiedRegularFileError.descriptorInvalid }
      hasher.update(data: Data(buffer.prefix(count)))
      offset += off_t(count)
    }
    var extra: UInt8 = 0
    guard unsafe pread(descriptor, &extra, 1, offset) == 0 else {
      throw VerifiedRegularFileError.identityChanged
    }
    var final = stat()
    guard unsafe fstat(descriptor, &final) == 0,
      final.st_dev == initial.st_dev,
      final.st_ino == initial.st_ino,
      final.st_uid == initial.st_uid,
      final.st_mode == initial.st_mode,
      final.st_size == initial.st_size,
      final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
      final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
      final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
      final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec
    else { throw VerifiedRegularFileError.identityChanged }
    return SHA256Hex.hexString(hasher.finalize())
  }
}
