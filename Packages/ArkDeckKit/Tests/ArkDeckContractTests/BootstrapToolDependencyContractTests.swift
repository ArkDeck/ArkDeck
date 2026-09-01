import Darwin
import Foundation
import XCTest
@testable import ArkDeckBootstrap
@testable import ArkDeckCore
@testable import ArkDeckLaunchAgent

/// Synthetic load commands exercise hostile input boundaries. These files
/// contain no program and are never executed; signature checks are explicitly
/// injected only in these parser/copy tests. The SDK integration uses Security.
final class BootstrapToolDependencyContractTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/tool-dependency-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  private func word(_ value: UInt32) -> Data {
    Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
  }
  private func macho(library: Bool = false, dependency: String = "@rpath/libusb_shared.dylib", rpath: String = "@loader_path/.") -> Data {
    func command(_ kind: UInt32, _ text: String, header: Int) -> Data {
      let size = (header + text.utf8.count + 1 + 7) / 8 * 8
      var data = word(kind) + word(UInt32(size)) + word(UInt32(header))
      data.append(Data(repeating: 0, count: header - data.count)); data.append(Data(text.utf8))
      data.append(Data(repeating: 0, count: size - data.count)); return data
    }
    let commands = command(0xc, dependency, header: 24) + command(0x8000001c, rpath, header: 12)
    return word(0xfeedfacf) + word(0x0100000c) + word(0) + word(library ? 6 : 2) + word(2) + word(UInt32(commands.count)) + word(0) + word(0) + commands
  }
  private func file(_ name: String, data: Data) throws -> URL {
    let url = root.appending(path: name)
    try data.write(to: url); XCTAssertEqual(chmod(url.path, 0o700), 0); return url
  }
  private func inspect(_ data: Data) throws -> [BootstrapToolMachO.Slice] {
    let path = try file(UUID().uuidString, data: data)
    let fd = open(path.path, O_RDONLY); defer { close(fd) }
    return try BootstrapToolMachO.inspect(fd)
  }
  private func registry(fault: @escaping (String) throws -> Void = { _ in }) -> BootstrapToolRegistry {
    BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: root.appending(path: "registry")),
      inspectTrust: { _ in BootstrapToolTrust(signature: "unsigned", identifier: nil, teamIdentifier: nil, codeDirectorySHA256: nil) }, fault: fault)
  }
  private func fields(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw CocoaError(.fileReadCorruptFile) }; return fields
  }
  private func reference(_ value: JSONValue) throws -> String {
    guard case .string(let value)? = try fields(value)["toolRef"] else { throw CocoaError(.fileReadCorruptFile) }; return value
  }

  func testBoundedMachORejectsMalformedCommandsAndUnrelocatableSearchPaths() throws {
    let valid = macho()
    XCTAssertTrue(BootstrapToolMachO.needsUSB(try inspect(valid)))
    XCTAssertTrue(BootstrapToolMachO.relocatable(try inspect(valid), library: false))
    XCTAssertFalse(BootstrapToolMachO.relocatable(try inspect(macho(rpath: "/tmp/caller")), library: false))
    XCTAssertFalse(BootstrapToolMachO.relocatable(try inspect(macho(library: true, dependency: "@rpath/other.dylib")), library: true))
    XCTAssertFalse(BootstrapToolMachO.relocatable(try inspect(macho(library: true, dependency: "/usr/lib/../../tmp/other.dylib")), library: true))
    var oversized = valid; oversized.replaceSubrange(20..<24, with: word(UInt32.max))
    var noProgress = valid; noProgress.replaceSubrange(36..<40, with: word(0))
    var invalidString = valid; invalidString.replaceSubrange(40..<44, with: word(UInt32.max))
    var excessiveCount = valid; excessiveCount.replaceSubrange(16..<20, with: word(4097))
    for data in [Data(), valid.prefix(30), valid.dropLast(), oversized, noProgress, invalidString, excessiveCount,
      Data([0xca, 0xfe, 0xba, 0xbe, 0xff, 0xff, 0xff, 0xff])] {
      XCTAssertThrowsError(try inspect(Data(data)))
    }
    // Two non-overlapping fat slices must both pass; corrupting the second
    // cannot be hidden by a valid first architecture.
    func big(_ value: UInt32) -> Data { Data(word(value).reversed()) }
    let first: UInt32 = 48, second = first + UInt32(valid.count)
    var fat = big(0xcafebabe) + big(2)
    for offset in [first, second] { fat.append(big(0x0100000c) + big(0) + big(offset) + big(UInt32(valid.count)) + big(0)) }
    fat.append(valid); fat.append(valid)
    XCTAssertEqual(try inspect(fat).count, 2)
    fat.replaceSubrange((Int(second) + 20)..<(Int(second) + 24), with: word(UInt32.max))
    XCTAssertThrowsError(try inspect(fat))
  }

  func testDependencyIsRequiredBoundedAndIncludedInContentAddress() throws {
    let main = try file("hdc", data: macho())
    XCTAssertThrowsError(try registry().register(file: main))
    let library = try file("libusb_shared.dylib", data: macho(library: true, dependency: "/usr/lib/libSystem.B.dylib"))
    let first = try registry().register(file: main)
    var changed = try Data(contentsOf: library); changed.append(0)
    try changed.write(to: library)
    let second = try registry().register(file: main)
    XCTAssertNotEqual(try reference(first), try reference(second))
    XCTAssertEqual(try fields(first)["executableSHA256"], try fields(second)["executableSHA256"])
    XCTAssertNotEqual(try fields(first)["dependencies"], try fields(second)["dependencies"])
    try FileManager.default.removeItem(at: library)
    try FileManager.default.createSymbolicLink(at: library, withDestinationURL: main)
    XCTAssertThrowsError(try registry().register(file: main))
    try FileManager.default.removeItem(at: library)
    XCTAssertEqual(link(main.path, library.path), 0)
    XCTAssertThrowsError(try registry().register(file: main))
    try FileManager.default.removeItem(at: library)
    let fd = open(library.path, O_RDWR | O_CREAT | O_EXCL, 0o700); defer { close(fd) }
    XCTAssertEqual(ftruncate(fd, 32 * 1024 * 1024 + 1), 0)
    XCTAssertThrowsError(try registry().register(file: main))
    XCTAssertEqual(try registry().inspect(reference(first)), first)
  }

  func testDependencyChangedAndRestoredDuringCopyCannotPublish() throws {
    let main = try file("hdc", data: macho())
    let library = try file("libusb_shared.dylib", data: macho(library: true, dependency: "/usr/lib/libSystem.B.dylib"))
    let owner = registry { point in
      if point == "copied" {
        XCTAssertEqual(chmod(library.path, 0o600), 0)
        XCTAssertEqual(chmod(library.path, 0o700), 0)
      }
    }
    XCTAssertThrowsError(try owner.register(file: main))
    XCTAssertEqual(try registry().list { _, rows in rows.count }, 0)
  }
}
