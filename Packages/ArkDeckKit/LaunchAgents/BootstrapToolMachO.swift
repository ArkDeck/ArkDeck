import ArkDeckCore
import Darwin
import Foundation

/// Bounded, read-only load-command inspection. No candidate or system tool is
/// launched. Only the HDC sibling libusb layout is eligible for relocation;
/// this is not a general dyld search-path resolver.
package enum BootstrapToolMachO {
  package struct Slice: Equatable {
    let fileType: UInt64
    let libraries: [String]
    let rpaths: [String]
    let hasEnvironment: Bool
  }
  static let usb = "libusb_shared.dylib"
  static let usbLoadName = "@rpath/" + usb

  static func inspect(_ fd: Int32) throws -> [Slice] {
    let size = try BootstrapBundleFiles.status(fd).st_size
    guard size >= 4 else { throw invalid() }
    func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
      guard count >= 0, count <= 4 * 1024 * 1024, offset <= UInt64(size), UInt64(count) <= UInt64(size) - offset else { throw invalid() }
      var bytes = [UInt8](repeating: 0, count: count), consumed = 0
      while consumed < count {
        let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: consumed), count - consumed, off_t(offset) + off_t(consumed)) }
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw invalid() }; consumed += n
      }
      return bytes
    }
    func number(_ bytes: [UInt8], _ start: Int, _ width: Int = 4, little: Bool) -> UInt64 {
      let range = bytes[start..<(start + width)]
      return (little ? Array(range.reversed()) : Array(range)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
    func slice(_ offset: UInt64, _ length: UInt64) throws -> Slice {
      guard length >= 28 else { throw invalid() }
      let header = try read(offset, 28)
      let magic = Array(header.prefix(4))
      let little = magic == [0xcf, 0xfa, 0xed, 0xfe] || magic == [0xce, 0xfa, 0xed, 0xfe]
      let wide = magic == [0xcf, 0xfa, 0xed, 0xfe] || magic == [0xfe, 0xed, 0xfa, 0xcf]
      guard little || magic == [0xfe, 0xed, 0xfa, 0xcf] || magic == [0xfe, 0xed, 0xfa, 0xce] else { throw invalid() }
      let headerSize: UInt64 = wide ? 32 : 28
      let count = number(header, 16, little: little), commandBytes = number(header, 20, little: little)
      guard count > 0, count <= 4096, commandBytes <= 4 * 1024 * 1024,
        length >= headerSize, commandBytes <= length - headerSize else { throw invalid() }
      let commands = try read(offset + headerSize, Int(commandBytes))
      var cursor = 0, libraries: [String] = [], rpaths: [String] = [], environment = false
      for _ in 0..<count {
        guard cursor <= commands.count - 8 else { throw invalid() }
        let kind = number(commands, cursor, little: little)
        let length = Int(number(commands, cursor + 4, little: little))
        guard length >= 8, length % (wide ? 8 : 4) == 0, length <= commands.count - cursor else { throw invalid() }
        // LC_LOAD_DYLIB, WEAK, REEXPORT, LAZY and UPWARD all affect closure.
        let library = [UInt64(0xc), 0x80000018, 0x8000001f, 0x20, 0x80000023].contains(kind)
        let rpath = kind == 0x8000001c
        if library || rpath {
          let minimum = library ? 24 : 12
          guard length >= minimum else { throw invalid() }
          let start = Int(number(commands, cursor + 8, little: little))
          guard start >= minimum, start < length,
            let end = commands[(cursor + start)..<(cursor + length)].firstIndex(of: 0),
            end - cursor - start <= 4096,
            let value = String(bytes: commands[(cursor + start)..<end], encoding: .utf8), !value.isEmpty,
            value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { throw invalid() }
          if library { libraries.append(value) } else { rpaths.append(value) }
        }
        // LC_DYLD_ENVIRONMENT is never accepted for a relocatable tool.
        if kind == 0x27 { environment = true }
        cursor += length
      }
      guard cursor == commands.count else { throw invalid() }
      return Slice(fileType: number(header, 12, little: little), libraries: libraries, rpaths: rpaths, hasEnvironment: environment)
    }
    let magic = try read(0, 4)
    let fatLittle = magic == [0xbe, 0xba, 0xfe, 0xca] || magic == [0xbf, 0xba, 0xfe, 0xca]
    let fatWide = magic == [0xca, 0xfe, 0xba, 0xbf] || magic == [0xbf, 0xba, 0xfe, 0xca]
    if fatLittle || fatWide || magic == [0xca, 0xfe, 0xba, 0xbe] {
      let count = number(try read(4, 4), 0, little: fatLittle)
      guard count > 0, count <= 16 else { throw invalid() }
      let stride = fatWide ? 32 : 20
      let table = try read(8, Int(count) * stride)
      var ranges: [Range<UInt64>] = [], slices: [Slice] = []
      for i in 0..<Int(count) {
        let start = number(table, i * stride + 8, fatWide ? 8 : 4, little: fatLittle)
        let length = number(table, i * stride + (fatWide ? 16 : 12), fatWide ? 8 : 4, little: fatLittle)
        guard start >= UInt64(8 + table.count), start <= UInt64(size), length > 0,
          length <= UInt64(size) - start, !ranges.contains(where: { $0.overlaps(start..<(start + length)) }) else { throw invalid() }
        ranges.append(start..<(start + length)); slices.append(try slice(start, length))
      }
      return slices
    }
    return [try slice(0, UInt64(size))]
  }

  static func needsUSB(_ slices: [Slice]) -> Bool { slices.contains { $0.libraries.contains(usbLoadName) } }

  static func relocatable(_ slices: [Slice], library: Bool) -> Bool {
    !slices.isEmpty && slices.allSatisfy { slice in
      slice.fileType == (library ? 6 : 2) && !slice.hasEnvironment && slice.libraries.allSatisfy {
        systemLibrary($0) || (!library && $0 == usbLoadName)
      } && (library || !slice.libraries.contains(usbLoadName) || slice.rpaths.first == "@loader_path/.")
    }
  }

  private static func systemLibrary(_ path: String) -> Bool {
    (path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/Frameworks/")) &&
      !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
  }
  private static func invalid() -> AgentExecutionControlFailure {
    BootstrapBundleFiles.failure("invalidInput", "host tool has malformed or unbounded Mach-O load commands")
  }
}
