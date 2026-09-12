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
final class BootstrapToolRetirementControlContractTests: XCTestCase {
  private var root: URL!
  private var registryRoot: URL!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/tool-retirement-rpc-\(UUID().uuidString.lowercased())")
    registryRoot = root.appending(path: "bootstrap")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-11T00:00:00Z" })
  }

  private static func owner(_ root: URL) throws -> BootstrapToolRegistry {
    BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: root))
  }
  private static func remove(_ root: URL, _ reference: String, _ generation: String) throws -> JSONValue {
    let tool = try owner(root)
    if reference.hasPrefix("toolchain:sha256:") {
      return try BootstrapDevEcoToolchainRegistry(owner: tool.sharedOwner).remove(reference, expectedGeneration: generation)
    }
    return try tool.remove(reference, expectedGeneration: generation)
  }
  private func wire(_ fields: [String: JSONValue], configured: Bool = true,
    record: Bool = true) async throws -> AgentWireProtocol.Response {
    let directory = registryRoot!
    let retire: (@Sendable (String, String) async throws -> JSONValue)? = configured ? { @Sendable reference, generation in
      try Self.remove(directory, reference, generation)
    } : nil
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: [], nowUTC: { "2026-09-11T00:00:00Z" }, targetStore: nil, bootstrap: nil,
      bootstrapToolRetirer: retire,
      artifactStore: nil, flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil, frameObserver: record ? nil : { @Sendable _ in })
    let request: JSONValue = .object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("tool-retirement-fixture"), "method": .string("runtime.tool.remove"),
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
    ["tool": .string(reference), "expectedGeneration": .string(generation)]
  }
  func testStructuralRefusalsAndUnavailableDoNotOpenOwner() async throws {
    for input: [String: JSONValue] in [[:], ["tool": .null, "expectedGeneration": .string("1")],
      ["tool": .string("invalid"), "expectedGeneration": .integer(1)],
      ["tool": .string("invalid"), "expectedGeneration": .string("1"), "path": .string("/private/tmp")]] {
      failure(try await wire(input, configured: false, record: false), "invalidParams")
    }
    failure(try await wire(fields("invalid"), configured: false), "operationUnavailable")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
  }
  func testIndexLookupAndLockPrecedeGenerationValidation() async throws {
    failure(try await wire(fields("invalid", "2")), "invalidInput")
    failure(try await wire(fields("tool:sha256:" + String(repeating: "0", count: 64), "2")), "resourceNotFound")
    let index = registryRoot.appending(path: "tools.json")
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
  func testActualSystemNativeToolRetirementAndRepeatRetainContent() async throws {
    let owner = try Self.owner(registryRoot)
    // Actual native signed system content exercises registry semantics only;
    // it is never executed and is not claimed as an HDC device-acceptance result.
    let original = try owner.register(file: URL(filePath: "/usr/bin/true"))
    guard case .string(let reference)? = try object(original)["toolRef"] else { return XCTFail("reference") }
    let reply = try await wire(fields(reference))
    var expected = try object(original); expected["state"] = .string("removed"); expected["generation"] = .string("2")
    XCTAssertEqual(reply.result, .object(expected))
    let index = registryRoot.appending(path: "tools.json")
    let before = try Data(contentsOf: index)
    let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
    let repeated = try await wire(fields(reference))
    XCTAssertEqual(repeated.result, reply.result)
    failure(try await wire(fields(reference, "2")), "resourceConflict")
    XCTAssertEqual(try Data(contentsOf: index), before)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date,
      attributes[.modificationDate] as? Date)
    XCTAssertEqual(try owner.inspect(reference), reply.result)
  }
  func testExplicitNativeFamiliesProduceCrossOwnerRetirementInputs() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let devecoSource = env["ARKDECK_TOOL_RETIRE_DEVECO_SOURCE"], let output = env["ARKDECK_TOOL_RETIRE_OUTPUT_ROOT"] else {
      throw XCTSkip("requires actual DevEco content and a fresh private temporary registry")
    }
    guard output.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: output),
      !output.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw AgentExecutionControlFailure("fixture", "fresh temporary output required")
    }
    registryRoot = URL(filePath: output)
    let tool = try Self.owner(registryRoot)
    let a = try tool.register(file: URL(filePath: "/usr/bin/true"))
    let b = try tool.register(file: URL(filePath: "/usr/bin/false"))
    guard case .string(let ar)? = try object(a)["toolRef"] else { return XCTFail("reference") }
    let retirementResponse = try await wire(fields(ar))
    let retired = try XCTUnwrap(retirementResponse.result)
    let deveco = BootstrapDevEcoToolchainRegistry(owner: tool.sharedOwner)
    let availableDevEco = try deveco.register(root: URL(filePath: devecoSource))
    guard case .string(let dr)? = try object(availableDevEco)["toolRef"] else { return XCTFail("reference") }
    let availableRoot = registryRoot!
    registryRoot = root.appending(path: "deveco-producer")
    let separate = try Self.owner(registryRoot)
    _ = try BootstrapDevEcoToolchainRegistry(owner: separate.sharedOwner).register(root: URL(filePath: devecoSource))
    let devecoResponse = try await wire(fields(dr))
    let retiredDevEco = try XCTUnwrap(devecoResponse.result)
    registryRoot = availableRoot
    let receipt: JSONValue = .object(["swiftRetiredHDC": retired, "rustAvailableHDC": b,
      "swiftRetiredDevEco": retiredDevEco, "rustAvailableDevEco": availableDevEco])
    let receiptPath = root.appending(path: "actual-native-retirement.json")
    try CanonicalJSONEncoders.canonical().encode(receipt).write(to: receiptPath)
    print("nativeToolRetirementRegistry=\(registryRoot.path)")
    print("nativeToolRetirementReceipt=\(receiptPath.path)")
  }
  func testExplicitRustReceiptsReadBackWithoutPublication() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let directory = env["ARKDECK_TOOL_RETIRE_RUST_ROOT"], let receipt = env["ARKDECK_TOOL_RETIRE_RUST_RECEIPT"] else {
      throw XCTSkip("requires actual Rust retirement receipts")
    }
    guard directory.hasPrefix("/private/tmp/"), receipt.hasPrefix("/private/tmp/") else {
      throw AgentExecutionControlFailure("fixture", "temporary input required")
    }
    registryRoot = URL(filePath: directory)
    let receipts = try object(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(filePath: receipt))))
    let owner = try Self.owner(registryRoot)
    let deveco = BootstrapDevEcoToolchainRegistry(owner: owner.sharedOwner)
    let before = try ["bundles.json", "tools.json", "deveco-toolchains.json"].map { name in
      try Data(contentsOf: registryRoot.appending(path: name))
    }
    for key in ["rustRetiredHDC", "rustRetiredDevEco"] {
      let expected = try XCTUnwrap(receipts[key])
      guard case .string(let reference)? = try object(expected)["toolRef"] else { return XCTFail("reference") }
      XCTAssertEqual(try reference.hasPrefix("toolchain:sha256:") ? deveco.inspect(reference) : owner.inspect(reference), expected)
      let repeated = try await wire(fields(reference))
      XCTAssertEqual(repeated.result, expected)
      failure(try await wire(fields(reference, "2")), "resourceConflict")
    }
    let after = try ["bundles.json", "tools.json", "deveco-toolchains.json"].map { name in
      try Data(contentsOf: registryRoot.appending(path: name))
    }
    XCTAssertEqual(after, before)
  }
}
