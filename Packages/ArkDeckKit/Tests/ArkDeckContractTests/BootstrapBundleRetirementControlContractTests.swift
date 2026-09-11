import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckBootstrap
@testable import ArkDeckCore
@testable import ArkDeckLaunchAgent
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Fresh private host fixtures are retained. No helper is selected or executed.
final class BootstrapBundleRetirementControlContractTests: XCTestCase {
  private var root: URL!
  private var registryRoot: URL!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/bundle-retirement-rpc-\(UUID().uuidString.lowercased())")
    registryRoot = root.appending(path: "bootstrap")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-11T00:00:00Z" })
  }

  private static func owner(_ root: URL) -> BootstrapBundleRegistry {
    BootstrapBundleRegistry(root: root, validateBundle: { candidate in
      do { _ = try LaunchAgentService.validateProductionDaemonBundle(candidate, fileManager: .default) }
      catch { throw AgentExecutionControlFailure("admissionDenied", "bundle failed native helper trust") }
    })
  }
  private func wire(_ fields: [String: JSONValue], configured: Bool = true,
    record: Bool = true) async throws -> AgentWireProtocol.Response {
    let directory = registryRoot!
    let retire: (@Sendable (String, String) async throws -> JSONValue)? = configured ? { @Sendable reference, generation in
      try Self.owner(directory).remove(reference, expectedGeneration: generation)
    } : nil
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: [], nowUTC: { "2026-09-11T00:00:00Z" }, targetStore: nil, bootstrap: nil,
      bootstrapBundleRetirer: retire,
      artifactStore: nil, flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil, frameObserver: record ? nil : { @Sendable _ in })
    let request: JSONValue = .object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("bundle-retirement-fixture"), "method": .string("runtime.bundle.remove"),
      "params": .object(fields),
    ])
    return try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await handler.handleLine(
      try CanonicalJSONEncoders.canonical().encode(request)))
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let result) = value else { throw AgentExecutionControlFailure("fixture", "expected object") }
    return result
  }
  private func failure(_ value: AgentWireProtocol.Response, _ code: String,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value.ok, file: file, line: line)
    XCTAssertNil(value.result, file: file, line: line)
    XCTAssertEqual(value.error?.code, code, file: file, line: line)
    XCTAssertEqual(value.error?.details?["phase"], .string("bootstrapRegistryOwner"), file: file, line: line)
    XCTAssertEqual(value.error?.details?["newDispatchCount"], .integer(0), file: file, line: line)
    XCTAssertEqual(dispatcher.dispatchCount, 0, file: file, line: line)
  }

  private func fields(_ reference: String, _ generation: String = "1") -> [String: JSONValue] {
    ["bundle": .string(reference), "expectedGeneration": .string(generation)]
  }
  func testStructuralRefusalsAndUnavailableDoNotOpenOwner() async throws {
    for input: [String: JSONValue] in [[:], ["bundle": .null, "expectedGeneration": .string("1")],
      ["bundle": .string("invalid"), "expectedGeneration": .integer(1)],
      ["bundle": .string("invalid"), "expectedGeneration": .string("1"), "path": .string("/private/tmp")]] {
      failure(try await wire(input, configured: false, record: false), "invalidParams")
    }
    failure(try await wire(fields("invalid"), configured: false), "operationUnavailable")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
  }
  func testIndexLookupAndLockPrecedeGenerationValidation() async throws {
    failure(try await wire(fields("invalid", "2")), "invalidInput")
    failure(try await wire(fields("bundle:sha256:" + String(repeating: "0", count: 64), "2")), "resourceNotFound")
    let index = registryRoot.appending(path: "bundles.json")
    let before = try Data(contentsOf: index)
    let lock = open(registryRoot.appending(path: ".lock").path, O_RDWR | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(lock, 0)
    defer { close(lock) }
    XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
    failure(try await wire(fields("invalid", "2")), "resourceConflict")
    XCTAssertEqual(flock(lock, LOCK_UN), 0)
    XCTAssertEqual(try Data(contentsOf: index), before)
    try Data("{corrupt fixture".utf8).write(to: index)
    failure(try await wire(fields("invalid", "2")), "recordUnreadable")
    XCTAssertEqual(try Data(contentsOf: index), Data("{corrupt fixture".utf8))
  }
  func testNativeRefusalRetainsMetadataAndGenerationMismatchPrecedesTrust() async throws {
    let source = root.appending(path: "UnsignedFixture.app")
    try FileManager.default.createDirectory(at: source.appending(path: "Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "fixture-1"],
      format: .xml, options: 0).write(to: source.appending(path: "Contents/Info.plist"))
    try Data("negative fixture".utf8).write(to: source.appending(path: "Contents/payload"))
    // Adversarial bytes only; the wire owner still performs real native trust.
    let seeded = try object(BootstrapBundleRegistry(root: registryRoot, validateBundle: { _ in }).register(file: source))
    guard case .string(let reference)? = seeded["bundleRef"] else { return XCTFail("missing reference") }
    let before = try Data(contentsOf: registryRoot.appending(path: "bundles.json"))
    failure(try await wire(fields(reference, "2")), "resourceConflict")
    failure(try await wire(fields(reference)), "admissionDenied")
    XCTAssertEqual(try Data(contentsOf: registryRoot.appending(path: "bundles.json")), before)
  }
  func testActualNativeRetirementRetainsContentAndRepeatDoesNotPublish() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let sourceA = env["ARKDECK_BUNDLE_RETIRE_SOURCE_A"], let sourceB = env["ARKDECK_BUNDLE_RETIRE_SOURCE_B"],
      let output = env["ARKDECK_BUNDLE_RETIRE_OUTPUT_ROOT"] else {
      throw XCTSkip("requires two real signed helpers and a fresh private temporary output root")
    }
    guard output.hasPrefix("/private/tmp/"), !output.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      !FileManager.default.fileExists(atPath: output) else { throw AgentExecutionControlFailure("fixture", "fresh temporary output required") }
    registryRoot = URL(filePath: output)
    let owner = Self.owner(registryRoot)
    let originalA = try owner.register(file: URL(filePath: sourceA))
    let originalB = try owner.register(file: URL(filePath: sourceB))
    guard case .string(let a)? = try object(originalA)["bundleRef"],
      case .string(let b)? = try object(originalB)["bundleRef"] else { return XCTFail("missing real references") }
    XCTAssertNotEqual(a, b)
    let response = try await wire(fields(a))
    let retired = try XCTUnwrap(response.result)
    var expected = try object(originalA); expected["state"] = .string("removed"); expected["generation"] = .string("2")
    XCTAssertEqual(retired, .object(expected))
    let index = registryRoot.appending(path: "bundles.json")
    let bytes = try Data(contentsOf: index)
    let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
    let retry = try await wire(fields(a))
    XCTAssertEqual(retry.result, retired)
    failure(try await wire(fields(a, "2")), "resourceConflict")
    XCTAssertEqual(try Data(contentsOf: index), bytes)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date,
      attributes[.modificationDate] as? Date)
    XCTAssertEqual(try owner.inspect(a), retired)
    XCTAssertEqual(try owner.inspect(b), originalB)
    // A separate available bundle is retained for the independent Rust native retirement.
    let receipt: JSONValue = .object(["swiftRetired": retired, "rustAvailable": originalB])
    let receiptPath = root.appending(path: "actual-native-retirement.json")
    try CanonicalJSONEncoders.canonical().encode(receipt).write(to: receiptPath)
    print("nativeBundleRetirementRegistry=\(registryRoot.path)")
    print("nativeBundleRetirementReceipt=\(receiptPath.path)")
  }
  func testExplicitRustRetirementReceiptReadsBackWithoutPublication() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let directory = env["ARKDECK_BUNDLE_RETIRE_RUST_ROOT"], let receipt = env["ARKDECK_BUNDLE_RETIRE_RUST_RECEIPT"] else {
      throw XCTSkip("requires a real Rust retirement receipt")
    }
    guard directory.hasPrefix("/private/tmp/"), receipt.hasPrefix("/private/tmp/") else {
      throw AgentExecutionControlFailure("fixture", "temporary input required")
    }
    registryRoot = URL(filePath: directory)
    let expected = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(filePath: receipt)))
    guard case .string(let reference)? = try object(expected)["bundleRef"] else { return XCTFail("missing Rust reference") }
    let before = try Data(contentsOf: registryRoot.appending(path: "bundles.json"))
    XCTAssertEqual(try Self.owner(registryRoot).inspect(reference), expected)
    let retry = try await wire(fields(reference))
    XCTAssertEqual(retry.result, expected)
    XCTAssertEqual(try Data(contentsOf: registryRoot.appending(path: "bundles.json")), before)
  }
}
