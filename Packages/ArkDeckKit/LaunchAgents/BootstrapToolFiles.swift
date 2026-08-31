import ArkDeckCore
import Darwin
import Foundation

/// Owns only an HDC executable and its closed sibling dependency set. Caller
/// paths are used during capture, never retained in the durable tool record.
package enum BootstrapToolFiles {
  private typealias Files = BootstrapBundleFiles
  static let maximumBytes: Int64 = 256 * 1024 * 1024
  static let maximumLibraryBytes: Int64 = 32 * 1024 * 1024

  package struct Dependency: Codable, Equatable {
    package let name: String, sha256: String
    package let byteCount: Int64
    package let quarantineSHA256: String?
    package let trust: BootstrapToolTrust
    var value: JSONValue {
      .object(["name": .string(name), "sha256": .string(sha256), "byteCount": .string(String(byteCount)),
        "quarantineSHA256": quarantineSHA256.map(JSONValue.string) ?? .null, "trust": trust.projection()])
    }
    var isWellFormed: Bool {
      name == BootstrapToolMachO.usb && BootstrapToolTrust.digest(sha256) &&
        byteCount > 0 && byteCount <= maximumLibraryBytes &&
        (quarantineSHA256.map(BootstrapToolTrust.digest) ?? true) && trust.isWellFormed
    }
  }

  struct Content {
    let digest: String, sha256: String
    let byteCount: Int64
    let quarantineSHA256: String?
    let dependencies: [Dependency]
    let trust: BootstrapToolTrust
    let relocatable: Bool
  }

  static func capture(file: URL, into stage: Int32, at stageURL: URL,
    inspectTrust: (URL) throws -> BootstrapToolTrust, fault: (String) throws -> Void) throws -> Content {
    let sourceURL = URL(filePath: try Files.physicalPath(file))
    let parentURL = sourceURL.deletingLastPathComponent()
    let parent = try Files.openDirectory(parentURL); defer { close(parent) }
    var sources: [(fd: Int32, name: String, copyName: String, tree: Files.Tree)] = []
    defer { for source in sources { close(source.fd) } }
    func captureChild(_ name: String, as copyName: String, library: Bool) throws -> [BootstrapToolMachO.Slice] {
      let fd = try openNative(parent, name, library: library)
      var retained = false
      defer { if !retained { close(fd) } }
      let slices = try BootstrapToolMachO.inspect(fd)
      guard slices.allSatisfy({ $0.fileType == (library ? 6 : 2) }) else {
        throw Files.failure("invalidInput", "host tool entry has the wrong native executable or library kind")
      }
      guard try Files.status(fd).st_size <= maximumBytes - sources.reduce(0, { $0 + $1.tree.byteCount }) else {
        throw Files.failure("inputTooLarge", "HDC and dependencies exceed the aggregate byte bound")
      }
      let executable = try Files.status(fd).st_mode & 0o111 != 0
      let copy = openat(stage, copyName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, executable ? 0o700 : 0o600)
      guard copy >= 0 else { throw Files.failure("ioFailure", "cannot create private host tool entry") }
      defer { close(copy) }
      let tree = try Files.scan(fd, copyingTo: copy)
      sources.append((fd, name, copyName, tree)); retained = true
      return slices
    }
    let main = try captureChild(sourceURL.lastPathComponent, as: "hdc", library: false)
    if BootstrapToolMachO.needsUSB(main) {
      _ = try captureChild(BootstrapToolMachO.usb, as: BootstrapToolMachO.usb, library: true)
    }
    try Files.sync(stage)
    try fault("copied")
    func revalidateSources() throws {
      try Files.requireLinkedDirectory(parent, url: parentURL)
      for source in sources {
        try requireLinkedFile(source.fd, parent: parent, name: source.name)
        guard try Files.scan(source.fd) == source.tree else { throw Files.failure("tool source or dependency changed during registration") }
        let copied = openat(stage, source.copyName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard copied >= 0 else { throw Files.failure("copied tool entry disappeared") }
        defer { close(copied) }
        guard try Files.scan(copied).entries == source.tree.entries else { throw Files.failure("tool copy differs from its source") }
      }
    }
    try revalidateSources()
    let content = try inspect(stage, at: stageURL, inspectTrust: inspectTrust)
    try revalidateSources()
    return content
  }

  static func inspect(_ directory: Int32, at url: URL, inspectTrust: (URL) throws -> BootstrapToolTrust) throws -> Content {
    let before = try Files.scan(directory)
    let names = try Files.names(directory)
    guard names == ["hdc"] || names == ["hdc", BootstrapToolMachO.usb], before.byteCount <= maximumBytes else {
      throw Files.failure("invalidInput", "HDC tool content exceeds its closed entry or size bounds")
    }
    let main = try openNative(directory, "hdc", library: false); defer { close(main) }
    let slices = try BootstrapToolMachO.inspect(main)
    guard BootstrapToolMachO.needsUSB(slices) == names.contains(BootstrapToolMachO.usb) else {
      throw Files.failure("invalidInput", "HDC dependency content is incomplete")
    }
    var relocatable = BootstrapToolMachO.relocatable(slices, library: false)
    var dependencies: [Dependency] = []
    if names.contains(BootstrapToolMachO.usb) {
      let fd = try openNative(directory, BootstrapToolMachO.usb, library: true); defer { close(fd) }
      let librarySlices = try BootstrapToolMachO.inspect(fd)
      relocatable = relocatable && BootstrapToolMachO.relocatable(librarySlices, library: true)
      let entry = try fields(before, path: BootstrapToolMachO.usb)
      let trust = try inspectTrust(url.appending(path: BootstrapToolMachO.usb))
      let dependency = Dependency(name: BootstrapToolMachO.usb, sha256: entry.sha256,
        byteCount: entry.byteCount, quarantineSHA256: entry.quarantine, trust: trust)
      guard dependency.isWellFormed else { throw Files.failure("admissionDenied", "host dependency identity is invalid") }
      dependencies.append(dependency)
      try requireLinkedFile(fd, parent: directory, name: BootstrapToolMachO.usb)
    }
    let trust = try inspectTrust(url.appending(path: "hdc"))
    try requireLinkedFile(main, parent: directory, name: "hdc")
    try Files.requireLinkedDirectory(directory, url: url)
    guard trust.isWellFormed, try Files.scan(directory) == before else { throw Files.failure("tool content or trust changed during inspection") }
    let executable = try fields(before, path: "hdc")
    let digest = try SHA256Hex.string(of: PortableCanonicalJSON.canonicalBytes(.object([
      "schemaVersion": .string("arkdeck.tool-content/1"), "kind": .string("hdc"),
      "layout": .string("hdc-sibling-libusb/1"), "entries": .array(before.entries),
    ])))
    return Content(digest: digest, sha256: executable.sha256, byteCount: before.byteCount,
      quarantineSHA256: executable.quarantine, dependencies: dependencies, trust: trust, relocatable: relocatable)
  }

  private static func fields(_ tree: Files.Tree, path: String) throws -> (sha256: String, byteCount: Int64, quarantine: String?) {
    for case .object(let entry) in tree.entries where entry["path"] == .string(path) {
      guard case .string(let sha256)? = entry["sha256"], case .string(let raw)? = entry["byteCount"], let bytes = Int64(raw) else { break }
      let quarantine: String? = { if case .string(let value)? = entry["quarantineSHA256"] { return value }; return nil }()
      return (sha256, bytes, quarantine)
    }
    throw Files.failure("invalidInput", "host tool entry has no bounded file identity")
  }

  private static func openNative(_ parent: Int32, _ name: String, library: Bool) throws -> Int32 {
    let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      throw Files.failure(errno == ELOOP ? "fileIdentityChanged" : "ioFailure", "host tool or required dependency cannot be opened without following links")
    }
    do {
      let status = try Files.status(fd)
      guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1, library || status.st_mode & 0o111 != 0, status.st_size > 0 else {
        throw Files.failure("invalidInput", "host tool must contain regular native files, not directories, scripts or links")
      }
      guard status.st_size <= (library ? maximumLibraryBytes : maximumBytes) else { throw Files.failure("inputTooLarge", "host tool entry exceeds its byte bound") }
      return fd
    } catch { close(fd); throw error }
  }

  private static func requireLinkedFile(_ fd: Int32, parent: Int32, name: String) throws {
    var linked = stat()
    guard fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
      Files.Identity(try Files.status(fd)) == Files.Identity(linked) else { throw Files.failure("tool pathname no longer names the same file") }
  }
}
