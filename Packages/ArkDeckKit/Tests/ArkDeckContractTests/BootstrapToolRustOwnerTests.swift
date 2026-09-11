import ArkDeckCore
import Foundation
import XCTest
@testable import ArkDeckBootstrap

final class BootstrapToolRustOwnerTests: XCTestCase {
  func testActualSwiftRegisteredContentMatchesRustReadOwner() throws {
    guard let binary = ProcessInfo.processInfo.environment["ARKDECK_TOOL_OWNER_BINARY"] else {
      throw XCTSkip("set ARKDECK_TOOL_OWNER_BINARY to the Rust tool_registry_read example")
    }
    let root = URL(filePath: "/private/tmp/arkdeck-tool-owner-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    // Fresh fixture files are retained. Neither owner executes the copied tool.
    let source = root.appending(path: "fixture-hdc")
    try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: source)
    let registryRoot = root.appending(path: "registry")
    let store = BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: registryRoot),
      nowUTC: { "2026-09-11T00:00:00Z" })
    let registered = try store.register(file: source)
    let expected = JSONValue.array(try store.list { _, rows in rows })
    let process = Process(), output = Pipe(), error = Pipe()
    process.executableURL = URL(filePath: binary)
    process.arguments = [registryRoot.path]
    process.standardOutput = output; process.standardError = error
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    let errors = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors, as: UTF8.self))
    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: bytes), expected)
    guard case .object(let fields) = registered,
      case .string(let reference)? = fields["toolRef"] else { return XCTFail("missing tool reference") }
    XCTAssertEqual(try store.inspect(reference), registered)
    XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: URL(filePath: "/usr/bin/true")))
  }
}
