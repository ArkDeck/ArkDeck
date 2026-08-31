import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

/// Descriptor-relative IO for the pre-daemon bundle registry. No candidate is
/// executed, no symbolic link is followed, and copying never removes quarantine.
package enum BootstrapBundleFiles {
  static let maximumBytes: Int64 = 1_073_741_824
  static let maximumEntries = 4096
  static let maximumMetadataBytes = 4 * 1024 * 1024

  struct Identity: Equatable {
    let device: dev_t, inode: ino_t, size: off_t, mode: mode_t, uid: uid_t, links: nlink_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ value: stat) {
      device = value.st_dev; inode = value.st_ino; size = value.st_size
      mode = value.st_mode; uid = value.st_uid; links = value.st_nlink
      modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
      changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
  }

  struct Tree: Equatable {
    let entries: [JSONValue]
    let identities: [String: Identity]
    let byteCount: Int64
    var digest: String {
      get throws {
        try SHA256Hex.string(of: PortableCanonicalJSON.canonicalBytes(.object([
          "schemaVersion": .string("arkdeck.bundle-content/1"), "entries": .array(entries),
        ])))
      }
    }
  }

  static func failure(_ code: String, _ message: String) -> AgentExecutionControlFailure {
    .init(code, message)
  }
  static func failure(_ message: String) -> AgentExecutionControlFailure { failure("fileIdentityChanged", message) }

  static func physicalPath(_ url: URL) throws -> String {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
      throw failure("invalidInput", "bundle and registry locations must be absolute local paths")
    }
    let path = url.path
    guard !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else {
      throw failure("invalidInput", "relative path components are not accepted")
    }
    for prefix in ["/tmp", "/var", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
      return "/private" + path
    }
    return path
  }

  static func status(_ fd: Int32) throws -> stat {
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw failure("ioFailure", "cannot read file identity") }
    return value
  }

  static func openDirectory(_ url: URL, create: Bool = false, privateLeaf: Bool = false) throws -> Int32 {
    let path = try physicalPath(url)
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else { throw failure("ioFailure", "cannot open filesystem root") }
    do {
      for part in path.split(separator: "/") {
        let name = String(part)
        if create, mkdirat(current, name, 0o700) != 0, errno != EEXIST {
          throw failure("ioFailure", "cannot create private registry directory")
        }
        let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else {
          var entry = stat()
          if fstatat(current, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 {
            if entry.st_mode & S_IFMT == S_IFLNK { throw failure("directory is symbolic") }
            if entry.st_mode & S_IFMT != S_IFDIR { throw failure("invalidInput", "location must be a directory") }
          }
          throw failure("ioFailure", "directory is absent or inaccessible")
        }
        close(current); current = next
        let value = try status(current)
        let safeSharedRoot = value.st_uid == 0 && value.st_mode & S_ISVTX != 0
        guard value.st_uid == geteuid() || value.st_uid == 0,
          value.st_mode & 0o022 == 0 || safeSharedRoot else {
          throw failure("directory ownership or permissions are unsafe")
        }
      }
      if privateLeaf {
        let value = try status(current)
        guard value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else {
          throw failure("registry must be owned by the current user with private permissions")
        }
      }
      return current
    } catch { close(current); throw error }
  }

  static func requireLinkedDirectory(_ fd: Int32, url: URL) throws {
    let reopened = try openDirectory(url)
    defer { close(reopened) }
    let before = try status(fd), after = try status(reopened)
    guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
      throw failure("directory was replaced during registration")
    }
  }

  static func names(_ fd: Int32) throws -> [String] {
    // openat, not dup: fdopendir/readdir must not share an enumeration offset
    // with a previous scan of the same directory descriptor.
    let iteratorFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard iteratorFD >= 0 else { throw failure("ioFailure", "cannot open directory iterator") }
    guard let iterator = fdopendir(iteratorFD) else { close(iteratorFD); throw failure("ioFailure", "cannot enumerate bundle") }
    defer { closedir(iterator) }
    var result: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(iterator) else {
        guard errno == 0 else { throw failure("ioFailure", "bundle enumeration failed") }
        break
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
      }
      guard let name else { throw failure("invalidInput", "bundle filenames must be valid UTF-8") }
      if name == "." || name == ".." { continue }
      guard !name.isEmpty, !name.contains("/"), name.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else {
        throw failure("invalidInput", "bundle contains an unsafe filename")
      }
      result.append(name)
      guard result.count <= maximumEntries else { throw failure("inputTooLarge", "bundle entry limit exceeded") }
    }
    guard Set(result).count == result.count else { throw failure("invalidInput", "bundle filenames are ambiguous") }
    return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  static func read(_ fd: Int32, maximum: Int) throws -> Data {
    var output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw failure("ioFailure", "bounded file read failed") }
      if count == 0 { return output }
      guard output.count <= maximum - count else { throw failure("inputTooLarge", "file exceeds its size bound") }
      output.append(contentsOf: buffer.prefix(count))
    }
  }

  static func write(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw failure(errno == ENOSPC ? "quotaExceeded" : "ioFailure", "registry write failed") }
        offset += count
      }
    }
  }

  static func sync(_ fd: Int32) throws {
    let directory = try status(fd).st_mode & S_IFMT == S_IFDIR
    guard (directory ? fsync(fd) : fcntl(fd, F_FULLFSYNC)) == 0 else { throw failure("ioFailure", "registry durable flush failed") }
  }

  static func removeStaging(_ name: String, from directory: Int32, expected: Int32) throws {
    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard child >= 0 else { throw failure("staging directory disappeared") }
    defer { close(child) }
    let found = try status(child), original = try status(expected)
    guard found.st_dev == original.st_dev, found.st_ino == original.st_ino else { throw failure("staging directory was replaced") }
    func removeChildren(_ fd: Int32) throws {
      for name in try names(fd) {
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("staging cleanup cannot inspect an entry") }
        if value.st_mode & S_IFMT == S_IFDIR {
          let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
          guard next >= 0 else { throw failure("staging cleanup refuses changed directories") }
          defer { close(next) }
          try removeChildren(next)
          guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw failure("staging cleanup failed") }
        } else {
          guard unlinkat(fd, name, 0) == 0 else { throw failure("staging cleanup failed") }
        }
      }
    }
    try removeChildren(child)
    guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw failure("staging cleanup failed") }
  }

  private static func quarantine(_ fd: Int32) throws -> Data? {
    let size = fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0)
    if size < 0, errno == ENOATTR { return nil }
    guard size >= 0, size <= 16 * 1024 else { throw failure("cannot read bounded quarantine metadata") }
    var data = Data(count: size)
    let count = data.withUnsafeMutableBytes { fgetxattr(fd, "com.apple.quarantine", $0.baseAddress, size, 0, 0) }
    guard count == size else { throw failure("quarantine metadata changed") }
    return data
  }

  static func scan(_ root: Int32, copyingTo destination: Int32? = nil) throws -> Tree {
    var entries: [JSONValue] = [], identities: [String: Identity] = [:]
    var total: Int64 = 0
    func visit(_ fd: Int32, destination: Int32?, path: String, depth: Int) throws {
      guard depth <= 24, entries.count < maximumEntries else { throw failure("inputTooLarge", "bundle depth or entry limit exceeded") }
      let before = try status(fd)
      guard before.st_uid == geteuid() || before.st_uid == 0,
        before.st_mode & 0o6022 == 0 else { throw failure("bundle permissions or owner are unsafe") }
      let kind = before.st_mode & S_IFMT
      guard kind == S_IFDIR || (kind == S_IFREG && before.st_nlink == 1) else {
        throw failure("invalidInput", "bundle contains a link or a non-regular entry")
      }
      let attribute = try quarantine(fd)
      if let destination, let attribute {
        let result = attribute.withUnsafeBytes { fsetxattr(destination, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
        guard result == 0 else { throw failure("cannot preserve bundle quarantine") }
      }
      let identity = Identity(before)
      identities[path] = identity
      var entry: [String: JSONValue] = ["path": .string(path), "kind": .string(kind == S_IFDIR ? "directory" : "file"),
        "executable": .bool(kind == S_IFREG && before.st_mode & 0o111 != 0),
        "quarantineSHA256": attribute.map { .string(SHA256Hex.string(of: $0)) } ?? .null]
      let position = entries.count
      entries.append(.null)
      if kind == S_IFDIR {
        let children = try names(fd)
        for name in children {
          var childStatus = stat()
          guard fstatat(fd, name, &childStatus, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("bundle entry disappeared") }
          let directory = childStatus.st_mode & S_IFMT == S_IFDIR
          guard directory || childStatus.st_mode & S_IFMT == S_IFREG else { throw failure("invalidInput", "bundle links and special files are not accepted") }
          let child = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
          guard child >= 0 else { throw failure("bundle entry cannot be opened safely") }
          defer { close(child) }
          guard Identity(try status(child)) == Identity(childStatus) else { throw failure("bundle entry was replaced") }
          var copy: Int32?
          if let destination {
            if directory {
              guard mkdirat(destination, name, 0o700) == 0 else { throw failure("cannot create copied bundle directory") }
              copy = openat(destination, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            } else {
              copy = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                childStatus.st_mode & 0o111 == 0 ? 0o600 : 0o700)
            }
            guard let copy, copy >= 0 else { throw failure("cannot create private bundle copy") }
          }
          defer { if let copy { close(copy) } }
          try visit(child, destination: copy, path: path.isEmpty ? name : path + "/" + name, depth: depth + 1)
        }
        guard try names(fd) == children else { throw failure("bundle membership changed during copy") }
        entry["byteCount"] = .string("0"); entry["sha256"] = .null
      } else {
        guard before.st_size >= 0, before.st_size <= maximumBytes - total else { throw failure("inputTooLarge", "bundle size limit exceeded") }
        var hasher = SHA256(), consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
          let count = Darwin.read(fd, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          guard count >= 0 else { throw failure("ioFailure", "cannot read bundle content") }
          if count == 0 { break }
          consumed += Int64(count)
          guard consumed <= before.st_size else { throw failure("bundle file grew during copy") }
          let bytes = Data(buffer.prefix(count)); hasher.update(data: bytes)
          if let destination { try write(bytes, to: destination) }
        }
        guard consumed == before.st_size else { throw failure("bundle file shrank during copy") }
        total += consumed
        entry["byteCount"] = .string(String(consumed)); entry["sha256"] = .string(SHA256Hex.hexString(hasher.finalize()))
      }
      guard Identity(try status(fd)) == identity, try quarantine(fd) == attribute else { throw failure("bundle identity changed during copy") }
      entries[position] = .object(entry)
      if let destination { try sync(destination) }
    }
    try visit(root, destination: destination, path: "", depth: 0)
    return Tree(entries: entries, identities: identities, byteCount: total)
  }
}
