import Darwin
import Foundation

/// Xcode's `xcode-select` tool shims, and the tools they stand for.
///
/// `/usr/bin/git`, `clang`, `make`, `python3` and the other developer tools
/// in `/usr/bin` are one file, hard-linked under every name. It picks the
/// tool it runs by the path the kernel reports for the process, never by
/// `argv[0]`. Started from its retained inode (`/.vol/<device>/<inode>`), it
/// reports whichever of its names the kernel last recorded for the file, so
/// a pinned `/usr/bin/git` can run clang, or `make -C <root> stash create` in
/// a project's root, and the digest pinned for it covers no tool at all: the
/// tool it would start lives in the developer directory.
///
/// A shim is told by the identifier its code signature carries
/// (`com.apple.dt.xcode_select.tool-shim-public` today), never by its name or
/// its link count: `/usr/bin/grep` is linked three times and is no shim.
/// Such a file is never launched; the tool it names is pinned instead, as
/// `xcrun --find` resolves it with a cleared environment, and that must be a
/// regular Mach-O file that is not a shim itself.
public enum XcodeToolShim {
  /// What every `xcode-select` tool shim's signing identifier starts with.
  public static let identifierPrefix = "com.apple.dt.xcode_select.tool-shim"

  private static let fatMagic: UInt32 = 0xcafe_babe
  private static let fatMagic64: UInt32 = 0xcafe_babf
  private static let machMagic: UInt32 = 0xfeed_face
  private static let machMagic64: UInt32 = 0xfeed_facf
  private static let machCigam: UInt32 = 0xcefa_edfe
  private static let machCigam64: UInt32 = 0xcffa_edfe
  private static let codeSignatureCommand: UInt32 = 0x1d
  private static let embeddedSignatureMagic: UInt32 = 0xfade_0cc0
  private static let codeDirectoryMagic: UInt32 = 0xfade_0c02
  private static let codeDirectorySlot: UInt32 = 0
  private static let maximumArchitectures: UInt32 = 64
  private static let maximumLoadCommandBytes: UInt64 = 16 << 20
  private static let maximumSignatureSlots: UInt64 = 1_024
  private static let maximumIdentifierBytes: UInt64 = 1_024
  private static let resolver = "/usr/bin/xcrun"

  /// One thin image's signature, when its bytes are well formed.
  private enum Architecture {
    case unsigned
    case signed(String)

    var identifier: String? {
      switch self {
      case .unsigned: nil
      case .signed(let identifier): identifier
      }
    }
  }

  /// The signing identifier of every architecture a Mach-O file holds, in
  /// the order the file lists them, `nil` for one that carries no code
  /// directory; `nil` altogether when the bytes are not a well-formed Mach-O
  /// file.
  public static func signingIdentifiers(of bytes: Data) -> [String?]? {
    let length = UInt64(bytes.count)
    return identifiers(length: length) { offset, count in
      guard offset <= length, count <= length - offset else { return nil }
      let start = bytes.startIndex + Int(offset)
      return [UInt8](bytes[start..<start + Int(count)])
    }
  }

  /// Whether any architecture is signed as an `xcode-select` tool shim.
  public static func isToolShim(_ identifiers: [String?]) -> Bool {
    identifiers.contains { $0?.hasPrefix(identifierPrefix) == true }
  }

  /// Whether `bytes` are an `xcode-select` tool shim.
  public static func isToolShim(bytes: Data) -> Bool {
    signingIdentifiers(of: bytes).map(isToolShim) ?? false
  }

  /// Whether the file behind a retained descriptor is an `xcode-select` tool
  /// shim, read through that descriptor.
  package static func isToolShim(fileDescriptor: Int32) -> Bool {
    var information = stat()
    guard unsafe fstat(fileDescriptor, &information) == 0, information.st_size >= 0 else {
      return false
    }
    let length = UInt64(information.st_size)
    let found = identifiers(length: length) { offset, count -> [UInt8]? in
      guard offset <= length, count <= length - offset else { return nil }
      var result: [UInt8] = []
      while UInt64(result.count) < count {
        var chunk = [UInt8](repeating: 0, count: Int(count) - result.count)
        let read = chunk.withUnsafeMutableBytes { bytes in
          unsafe pread(
            fileDescriptor, bytes.baseAddress, bytes.count, off_t(offset) + off_t(result.count))
        }
        if read < 0, errno == EINTR { continue }
        guard read > 0 else { return nil }
        result += chunk.prefix(read)
      }
      return result
    }
    return found.map(isToolShim) ?? false
  }

  /// The tool an `xcode-select` shim named `tool` runs, as `/usr/bin/xcrun
  /// --find` resolves it with a cleared environment — the developer
  /// directory `xcode-select` chose, which is what the shim itself uses for a
  /// child given no `DEVELOPER_DIR`. The answer is its physical path, a
  /// regular Mach-O file that is not a shim.
  public static func resolve(tool: String) throws -> String {
    guard !tool.isEmpty, tool.utf8.count <= 255, !tool.hasPrefix("-"),
      !tool.contains("/"), !tool.contains("\0")
    else {
      throw XcodeToolShimError.invalidToolName(tool)
    }
    // The resolver is Xcode's own, never a shim or another tool.
    let resolverBytes = try Data(contentsOf: URL(filePath: resolver))
    guard let resolverIdentifiers = signingIdentifiers(of: resolverBytes),
      resolverIdentifiers.allSatisfy({ $0 == "com.apple.xcrun" })
    else {
      throw XcodeToolShimError.resolverUnavailable
    }
    let process = Process()
    process.executableURL = URL(filePath: resolver)
    process.arguments = ["--find", tool]
    process.environment = [:]
    process.currentDirectoryURL = URL(filePath: "/")
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    // Waited for by polling: `waitUntilExit` can hang off the main thread.
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning {
      if Date() >= deadline {
        process.terminate()
        while process.isRunning { usleep(5_000) }
        throw XcodeToolShimError.unresolved(tool)
      }
      usleep(5_000)
    }
    let answer = output.fileHandleForReading.readDataToEndOfFile().prefix(4_097)
    guard process.terminationReason == .exit, process.terminationStatus == 0,
      let text = String(data: answer, encoding: .utf8), text.hasSuffix("\n")
    else {
      throw XcodeToolShimError.unresolved(tool)
    }
    let line = String(text.dropLast())
    guard line.hasPrefix("/"), !line.contains("\n") else {
      throw XcodeToolShimError.unresolved(tool)
    }
    let physical = URL(filePath: line).resolvingSymlinksInPath().path
    var information = stat()
    guard physical.withCString({ unsafe lstat($0, &information) }) == 0,
      (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      let identifiers = signingIdentifiers(of: try Data(contentsOf: URL(filePath: physical))),
      !isToolShim(identifiers)
    else {
      throw XcodeToolShimError.notATool(tool: tool, path: physical)
    }
    return physical
  }

  private static func big(_ bytes: [UInt8], _ at: Int) -> UInt32? {
    guard at >= 0, at + 4 <= bytes.count else { return nil }
    return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }

  private static func bigWide(_ bytes: [UInt8], _ at: Int) -> UInt64? {
    guard at >= 0, at + 8 <= bytes.count else { return nil }
    return bytes[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) }
  }

  private static func little(_ bytes: [UInt8], _ at: Int) -> UInt32? {
    guard at >= 0, at + 4 <= bytes.count else { return nil }
    return bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
  }

  private static func identifiers(
    length: UInt64, read: (UInt64, UInt64) -> [UInt8]?
  ) -> [String?]? {
    guard let head = read(0, 8), let magic = big(head, 0) else { return nil }
    guard magic == fatMagic || magic == fatMagic64 else {
      return architecture(base: 0, size: length, read: read).map { [$0.identifier] }
    }
    guard let count = big(head, 4), count > 0, count <= maximumArchitectures else { return nil }
    let entry = magic == fatMagic ? 20 : 32
    guard let table = read(8, UInt64(Int(count) * entry)) else { return nil }
    var result: [String?] = []
    for index in 0..<Int(count) {
      let at = index * entry
      let offset: UInt64
      let size: UInt64
      if magic == fatMagic {
        guard let rawOffset = big(table, at + 8), let rawSize = big(table, at + 12) else {
          return nil
        }
        (offset, size) = (UInt64(rawOffset), UInt64(rawSize))
      } else {
        guard let rawOffset = bigWide(table, at + 8), let rawSize = bigWide(table, at + 16)
        else { return nil }
        (offset, size) = (rawOffset, rawSize)
      }
      guard offset <= length, size <= length - offset,
        let image = architecture(base: offset, size: size, read: read)
      else { return nil }
      result.append(image.identifier)
    }
    return result
  }

  /// One thin Mach-O image at `base`: its code directory's identifier, or
  /// `.unsigned` when it is not signed.
  private static func architecture(
    base: UInt64, size: UInt64, read: (UInt64, UInt64) -> [UInt8]?
  ) -> Architecture? {
    guard let header = read(base, 28), let magic = little(header, 0) else { return nil }
    let isLittle: Bool
    let headerSize: UInt64
    switch magic {
    case machMagic: (isLittle, headerSize) = (true, 28)
    case machMagic64: (isLittle, headerSize) = (true, 32)
    case machCigam: (isLittle, headerSize) = (false, 28)
    case machCigam64: (isLittle, headerSize) = (false, 32)
    default: return nil
    }
    func word(_ bytes: [UInt8], _ at: Int) -> UInt32? {
      isLittle ? little(bytes, at) : big(bytes, at)
    }
    guard let count = word(header, 16), let rawCommandsSize = word(header, 20) else {
      return nil
    }
    let commandsSize = UInt64(rawCommandsSize)
    guard commandsSize <= maximumLoadCommandBytes, headerSize + commandsSize <= size,
      let commands = read(base + headerSize, commandsSize)
    else { return nil }
    var at = 0
    var signature: (offset: UInt64, length: UInt64)?
    for _ in 0..<count {
      guard let command = word(commands, at), let rawSize = word(commands, at + 4) else {
        return nil
      }
      let commandSize = Int(rawSize)
      guard commandSize >= 8, at + commandSize <= commands.count else { return nil }
      if command == codeSignatureCommand {
        guard commandSize >= 16, let offset = word(commands, at + 8),
          let length = word(commands, at + 12)
        else { return nil }
        signature = (UInt64(offset), UInt64(length))
      }
      at += commandSize
    }
    guard let signature else { return .unsigned }
    guard signature.length >= 12, signature.offset <= size,
      signature.length <= size - signature.offset
    else { return nil }
    let start = base + signature.offset
    guard let superblob = read(start, 12), big(superblob, 0) == embeddedSignatureMagic,
      let rawSlots = big(superblob, 8)
    else { return nil }
    let slots = UInt64(rawSlots)
    guard slots <= maximumSignatureSlots, 12 + slots * 8 <= signature.length,
      let index = read(start + 12, slots * 8)
    else { return nil }
    for slot in 0..<Int(slots) {
      guard let kind = big(index, slot * 8) else { return nil }
      guard kind == codeDirectorySlot else { continue }
      guard let rawDirectoryOffset = big(index, slot * 8 + 4) else { return nil }
      let directoryOffset = UInt64(rawDirectoryOffset)
      guard directoryOffset + 24 <= signature.length,
        let directory = read(start + directoryOffset, 24),
        big(directory, 0) == codeDirectoryMagic,
        let rawDirectoryLength = big(directory, 4), let rawIdentifierOffset = big(directory, 20)
      else { return nil }
      let (directoryLength, identifierOffset) = (
        UInt64(rawDirectoryLength), UInt64(rawIdentifierOffset)
      )
      guard directoryOffset + directoryLength <= signature.length,
        identifierOffset < directoryLength,
        let text = read(
          start + directoryOffset + identifierOffset,
          min(directoryLength - identifierOffset, maximumIdentifierBytes)),
        let end = text.firstIndex(of: 0),
        let identifier = String(bytes: text[..<end], encoding: .utf8)
      else { return nil }
      return .signed(identifier)
    }
    return .unsigned
  }
}

/// Why a shim resolved to no tool the Runtime may pin.
public enum XcodeToolShimError: Error, Equatable {
  case invalidToolName(String)
  case resolverUnavailable
  case unresolved(String)
  case notATool(tool: String, path: String)
}
