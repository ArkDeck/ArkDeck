import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckBootstrap
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Source-created non-executable fixtures exercise the Swift producer and frozen
/// owner shape. Injected fixture trust is neither native nor hardware acceptance.
final class BootstrapBundleRegistrationControlContractTests: XCTestCase {
  private var root: URL!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/bundle-register-control-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: RuntimeAgentExecutionContractTests.Dispatcher(),
      capabilityStore: capabilities, nowUTC: { "2026-09-12T00:00:00Z" })
  }
  override func tearDownWithError() throws {
    engine = nil; capabilities = nil
    try? FileManager.default.removeItem(at: root)
  }
  private func owner(_ directory: URL) -> BootstrapBundleRegistry {
    Self.ownerAt(directory)
  }
  private static func ownerAt(_ directory: URL) -> BootstrapBundleRegistry {
    .init(root: directory, validateBundle: { _ in }, nowUTC: { "2026-09-12T00:00:00Z" })
  }
  private func wire(_ params: [String: JSONValue], configured: Bool = true,
    injected: String? = nil, record: Bool = true) async throws -> AgentWireProtocol.Response {
    let directory = root.appending(path: "registry")
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: [], nowUTC: { "2026-09-12T00:00:00Z" }, targetStore: nil, bootstrap: nil,
      bootstrapBundleRegistrar: configured ? { @Sendable path in
        if let injected { throw AgentExecutionControlFailure(injected, "fixture publication failure") }
        return try Self.ownerAt(directory).register(file: URL(filePath: path))
      } : nil,
      artifactStore: nil, flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil, frameObserver: record ? nil : { @Sendable _ in })
    let request: JSONValue = .object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("bundle-register-fixture"), "method": .string("runtime.bundle.register"), "params": .object(params),
    ])
    let response = await handler.handleLine(try CanonicalJSONEncoders.canonical().encode(request))
    return try JSONDecoder().decode(AgentWireProtocol.Response.self, from: response)
  }
  func testProducerPersistsExactFixtureAndReadsItAfterReopening() async throws {
    for version in ["fixture-1", ""] {
      let source = root.appending(path: "Source\(version).app")
      try FileManager.default.createDirectory(at: source.appending(path: "Contents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let info = version.isEmpty ? [:] : ["CFBundleShortVersionString": version]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: source.appending(path: "Contents/Info.plist"))
      try Data("non-executable test fixture".utf8).write(to: source.appending(path: "Contents/payload"))
      let params: [String: JSONValue] = ["kind": .string("daemon-bundle"), "file": .string(source.path)]
      let first = try await wire(params)
      XCTAssertTrue(first.ok)
      let repeated = try await wire(params)
      XCTAssertEqual(repeated.result, first.result)
      let result = try XCTUnwrap(first.result)
      guard case .object(let fields) = result, case .string(let reference)? = fields["bundleRef"] else { return XCTFail("missing Bundle reference") }
      XCTAssertEqual(fields["generation"], .string("1")); XCTAssertEqual(fields["contentRetained"], .bool(true))
      XCTAssertEqual(try owner(root.appending(path: "registry")).inspect(reference), result)
    }
  }
  func testClosedParametersUnavailableOwnerAndPublicationFailures() async throws {
    for params: [String: JSONValue] in [[:], ["kind": .string("hdc"), "file": .string("/unused.app")],
      ["kind": .string("daemon-bundle"), "file": .string("relative.app")],
      ["kind": .string("daemon-bundle"), "file": .string("/unused.app"), "digest": .string("caller")]] {
      let result = try await wire(params, record: false)
      XCTAssertEqual(result.error?.code, "invalidParams")
    }
    let params: [String: JSONValue] = ["kind": .string("daemon-bundle"), "file": .string("/unused.app")]
    let unavailable = try await wire(params, configured: false)
    XCTAssertEqual(unavailable.error?.code, "operationUnavailable")
    for code in ["invalidInput", "fileIdentityChanged", "resourceConflict", "admissionDenied", "recordUnreadable", "quotaExceeded", "inputTooLarge", "ioFailure", "outcomeUnknown"] {
      let result = try await wire(params, injected: code)
      XCTAssertEqual(result.error?.code, code)
      XCTAssertEqual(result.error?.details?["newDispatchCount"], .integer(0))
    }
    let unclassified = try await wire(params, injected: "unclassified")
    XCTAssertEqual(unclassified.error?.code, "outcomeUnknown")
  }
}
